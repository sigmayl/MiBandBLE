local function rpc(kind,arg)io.write(kind,' ',arg,'\n');io.flush();return assert(io.read('l'))end
local function hex(s)return(s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(s)return(s:gsub('..',function(c)return string.char(tonumber(c,16))end))end
debug.upvalueid=function(owner,index)
 local _,v=debug.getupvalue(owner,index);assert(rpc('OWN',hex(v))=='ok');return 'userdata: 0x3c410000'
end
local ioa={}
function ioa.read(p)local r=rpc('READ',p);return r~='-' and unhex(r)or nil end
function ioa.remove(p)rpc('REMOVE',p)end
function ioa.run(c)return rpc('RUN',c)=='ok'end
function ioa.write(p,d)return rpc('WRITE',p..' '..hex(d))=='ok'end
local native=dofile('lua/loader.lua');local profile=dofile('dist/profile.lua')
local f=assert(io.open('dist/payload.bin','rb'));local image=f:read('a');f:close()
local BLE=dofile('lua/transport.lua');local b=BLE.new(native,profile,image,ioa)
assert(b.start())
local r=b.poll();assert(r.status==1)
local function request(op,a,c,data)
 b.send(op,a,c,data)
 for _=1,4 do local p=b.poll();if p.completed then assert(p.completed.rc==0,tostring(p.completed.rc));return p end end
 error('missing ACK')
end
request(1)
request(2)
request(3)
request(4,0,0,'\6\5\4\3\2\1')
request(8,5,0,string.rep('abc',170)..'1234')
local got=false
for _=1,4 do
 local p=b.poll()
 for _,e in ipairs(p.events)do if e.kind==10 then assert(e.data==string.rep('abc',170)..'1234');got=true end end
end
-- Notification may already have been consumed with the request's ACK.
if not got then assert(rpc('NOTIFY','')=='ok');for _,e in ipairs(b.poll().events)do if e.kind==10 then assert(#e.data==514);got=true end end end
assert(got)
local P=dofile('lua/protocol.lua')
local burst={}
for adc=0,74 do
 local plain=string.char(0x23,0x5a,0xb3,0,adc,0,0,0,0,0,0)
 local sum=0;for i=1,#plain do sum=sum+plain:byte(i)end
 burst[#burst+1]=P.encrypt(plain..string.char(sum%256))
end
b.suspend()
assert(rpc('BURST',hex(table.concat(burst)))=='ok')
assert(rpc('SLEEP','3600')=='ok')
b.resume()
local p=b.poll();local notified,write_done,last=0,false,nil
for _,e in ipairs(p.events)do
 if e.kind==10 then notified=notified+1;last=P.notification(e.data).adc end
 if e.kind==8 then write_done=true end
end
assert(p.dropped==0 and p.notification_skipped==69 and p.connected==2)
assert(notified==6 and last==74 and write_done,'burst must retain final ADC and control callbacks')
assert(#b.poll().events==0,'notification snapshots must not be delivered twice')
request(8,5,0,'after screen wake')
local function control(op,frames)
 local seq=b.send(op,5,0,frames)
 for _=1,16 do
  local p=b.poll()
  if p.completed then assert(p.completed.rc==0)end
  for _,e in ipairs(p.events)do
   if e.kind==12 and e.b==seq then assert(e.status==0);return end
  end
 end
 error('missing native control completion')
end
for _,variant in ipairs({'QCPW','QCSW','QCVW'})do
 assert(rpc('CAPTURE','')=='ok')
 control(11,table.concat(P.levels(variant,50,70))..table.concat(P.stop()))
 control(12,table.concat(P.stop()))
 assert(rpc('CHECK',variant)=='ok')
end
b.close()
local again=BLE.new(native,profile,image,ioa);assert(again.start());again.close()
assert(rpc('CORRUPT','')=='ok')
local bad=BLE.new(native,profile,image,ioa);local ok,err=pcall(bad.start)
assert(not ok and tostring(err):find('resident code mismatch',1,true))
io.write('PASS bootstrap, transport, resident reuse, 514 bytes and corruption refusal\n');io.flush()
