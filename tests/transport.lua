-- Exercise the real Lua reader with overwrites BETWEEN its separate mw reads.
local BLE=dofile('lua/transport.lua')
local profile=dofile('dist/profile.lua')
local f=assert(io.open('dist/payload.bin','rb'));local image=f:read('a');f:close()
local tests=0
local function check(value,message)assert(value,message);tests=tests+1 end
local function fixture(initial_head)
 local code=0x3c800000;local base=code+#image
 local memory,files={},{}
 local function put_bytes(a,data)for i=1,#data do memory[a+i-1]=data:byte(i)end end
 local function get_bytes(a,n)local b={};for i=0,n-1 do b[#b+1]=string.char(memory[a+i]or 0)end;return table.concat(b)end
 local function put(a,v)put_bytes(a,string.pack('<I4',v))end
 local function word(a)return string.unpack('<I4',get_bytes(a,4))end
 put_bytes(code,image);put(code+4,base)
 put(profile.umem_slot,profile.umem_descriptor)
 put(base+32,0x36424c45);put(base+36,0x10004);put(base+40,#image);put(base+44,profile.image_crc)
 put(base+48,1);put(base+604,2);put(base+624,1)
 put(base+636,initial_head or 0)
 put(base+620,59) -- An old failed session must not poison this new attachment.
 files['/tmp/o66-native-ble-lock/owner']=string.format('%08x %08x %d\n',base,profile.image_crc,#image)
 local a={after_read=nil}
 function a.read(path)return files[path]end
 function a.remove(path)files[path]=nil end
 function a.write(path,data)files[path]=data;return true end
 function a.run(cmd)
  local address,value=cmd:match('^mw (%x+)=(%x+)$')
  if address then put(tonumber(address,16),tonumber(value,16));return true end
  local address,n,path=cmd:match('^mw (%x+) (%x+) > (.+)$')
  assert(address,cmd);address,n=tonumber(address,16),tonumber(n,16)
  local lines={}
  for offset=0,n-1,4 do lines[#lines+1]=string.format('  0x%08x = 0x%08x',address+offset,word(address+offset))end
  files[path]=table.concat(lines,'\n')..'\n'
  if a.after_read then a.after_read(address,n)end
  return true
 end
 local b=BLE.new({},profile,image,a);assert(b.start());put(base+600,0)
 local function publish(data)
  local h=word(base+636);local slot=base+10104+(h%16)*548
  put_bytes(slot,string.pack('<I4I4I4I4I4I4I4',((h+1)*2)&0xffffffff,10,0,7,0,#data,1)..data)
  put(base+636,(h+1)&0xffffffff)
 end
 return b,a,publish,put,base,word
end
local b,a,publish,put,base=fixture()
publish(string.rep('A',514))
local first_slot=base+10104
a.after_read=function(address,n)
 if address==first_slot and n==64 then
  a.after_read=nil
  for i=1,16 do publish(string.rep(string.char(65+i),514))end
 end
end
local r=b.poll();check(#r.events==0 and r.dropped==0,'Reject payload torn by concurrent overwrite')
r=b.poll();check(#r.events==6 and r.notification_skipped==11 and r.dropped==0)
for i,e in ipairs(r.events)do check(e.data==string.rep(string.char(75+i),514),'Accept only complete newer frames')end
check(#b.poll().events==0,'Do not replay sampled notifications')

b,a,publish,put,base=fixture()
publish('latest');put(base+10104,3)
r=b.poll();check(#r.events==0 and r.dropped==0,'Do not read a busy slot')
put(base+10104,2);r=b.poll();check(#r.events==1 and r.events[1].data=='latest')
put(base+620,60);r=b.poll();check(r.dropped==1,'Control loss remains visible relative to attach')
put(base+640,2);r=b.poll();check(r.notification_skipped==2 and r.dropped==1)

b,a,publish,put,base=fixture(0xfffffffe)
for _,s in ipairs({'before wrap','at wrap','after wrap'})do publish(s)end
r=b.poll();check(#r.events==3 and r.notification_skipped==0)
check(r.events[1].data=='before wrap' and r.events[2].data=='at wrap' and r.events[3].data=='after wrap')
check(#b.poll().events==0)
local word
b,a,publish,put,base,word=fixture()
b.suspend();check(word(base+648)==1 and word(base+600)==0)
local heartbeat=word(base+596)
b.resume();check(word(base+648)==0 and word(base+596)==heartbeat+1 and word(base+600)==0)
b.suspend();b.close();check(word(base+600)==1 and word(base+648)==0)
b.resume();check(word(base+600)==1 and word(base+648)==0,'Resume cannot resurrect an explicitly closed transport')
print('BLE transport concurrency: '..tests..' assertions passed')
