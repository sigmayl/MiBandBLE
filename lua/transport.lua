-- Shared-memory client for the persistent native task. No Lua callback escapes.
local M={}
local function check(ok,msg) if not ok then error(msg,0) end end
local function signed(n) return n>=0x80000000 and n-0x100000000 or n end
function M.new(native,profile,image,io)
 local self={pending=nil,closed=false}
 local path='/tmp/o66-ble-read.txt'
 local lock='/tmp/o66-native-ble-lock'
 local function read(address,count)
  check(math.type(address)=='integer' and address%4==0 and count>=1 and count<=64,'invalid BLE memory read')
  io.remove(path)
  check(io.run(string.format('mw %08x %x > %s',address,count*4,path)),'BLE memory read failed')
  local text=io.read(path);check(type(text)=='string' and #text<=16384,'missing BLE memory response')
  local out={}
  for line in text:gmatch('[^\r\n]+') do
   local a,v=line:match('^%s*([%xxX]+)%s*=%s*0[xX](%x+)%s*$')
   check(a and tonumber(a:gsub('^0[xX]',''),16)==address+#out*4 and v and #v<=8,'invalid BLE memory response')
   out[#out+1]=tonumber(v,16)
  end
  check(#out==count,'short BLE memory response');return out
 end
 local function bytes(address,n)
  local parts={};local words=(n+3)//4
  for i=0,words-1,64 do
   local w=read(address+i*4,math.min(64,words-i))
   for _,v in ipairs(w)do parts[#parts+1]=string.pack('<I4',v)end
  end
  return table.concat(parts):sub(1,n)
 end
 local function write(offset,value)
  check(self.base and ((offset>=56 and offset<=628 and offset%4==0)or offset==648),'invalid BLE write')
  check(io.run(string.format('mw %08x=%08x',self.base+offset,value&0xffffffff)),'BLE memory write failed')
 end
 function self.start(progress)
  progress=progress or function()end
  local saved=io.read(lock..'/owner')
  if not saved then
   check(io.run('mkdir '..lock),'BLE 启动记录不完整，请重启手环后重试')
   local ok,r=native.run(profile,image,#image,io,progress)
   check(ok,r)
   saved=string.format('%08x %08x %d\n',r.output,profile.image_crc,#image)
   check(io.write(lock..'/owner',saved),'BLE owner record failed; reboot required')
  end
  local ptr,crc,size=saved:match('^(%x+) (%x+) (%d+)\n$')
  ptr,crc,size=tonumber(ptr,16),tonumber(crc,16),tonumber(size)
  check(ptr and crc==profile.image_crc and size==#image,'BLE 驻留版本不同，请重启后使用此版本')
  check(ptr%4==0 and ptr-size>profile.heap_start and ptr+18872<profile.heap_end,'BLE owner out of bounds')
  check(read(profile.umem_slot,1)[1]==profile.umem_descriptor,'BLE heap mismatch')
  local header=read(ptr+32,4)
  check(header[1]==0x36424c45 and header[2]==0x10004 and header[3]==size and header[4]==crc,'BLE owner mismatch')
  local code=bytes(ptr-size,size)
  check(string.unpack('<I4',code,5)==ptr,'BLE resident pointer mismatch')
  code=code:sub(1,4)..string.rep('\0',4)..code:sub(9)
  check(code==image,'BLE resident code mismatch')
  self.base=ptr;self.seq=read(ptr+56,1)[1];self.beat=read(ptr+596,1)[1]
  self.drop_base=read(ptr+620,1)[1]
  local counters=read(ptr+636,2)
  self.notify_cursor=counters[1];self.notify_drop_base=counters[2];self.notify_skipped=0
  self.closed=false
  write(600,1);write(648,0);self.heartbeat()
  return true
 end
 function self.heartbeat()
  self.beat=(self.beat+1)&0xffffffff;write(596,self.beat)
 end
 function self.suspend()
  if self.base and not self.closed then write(648,1)end
 end
 function self.resume()
  if self.base and not self.closed then self.heartbeat();write(648,0)end
 end
 function self.send(op,a,b,data)
  check(not self.closed and not self.pending,'BLE request busy or closed')
  check(math.type(op)=='integer' and op>=1 and op<=12,'invalid BLE operation')
  a,b,data=a or 0,b or 0,data or ''
  check(a>=0 and a<=65535 and b>=0 and b<=65535 and #data<=514,'invalid BLE arguments')
  local h=read(self.base+56,2);check(h[1]==h[2],'previous BLE request still pending')
  write(64,op);write(68,a);write(72,b);write(76,#data)
  data=data..string.rep('\0',-#data%4)
  for i=1,#data,4 do
   if (i-1)%64==0 then self.heartbeat()end
   write(80+i-1,string.unpack('<I4',data,i))
  end
  self.heartbeat();self.seq=(self.seq+1)&0xffffffff
  write(56,self.seq);self.pending={seq=self.seq,op=op,a=a,b=b};return self.seq
 end
 function self.poll()
  check(self.base,'BLE not started')
  if not self.closed then self.heartbeat()end
  local h=read(self.base+48,4)
  local q=read(self.base+596,12)
  local result={status=h[1],error=signed(h[2]),request=h[3],ack=h[4],closing=q[2],connected=q[3],scanning=q[4],dropped=(q[7]-self.drop_base)&0xffffffff,generation=q[8],events={}}
  if self.pending and h[4]==self.pending.seq then
   result.completed=self.pending;result.completed.rc=signed(q[10]);self.pending=nil
  end
  local head,tail=q[5],q[6]
  check(((head-tail)&0xffffffff)<=16,string.format('BLE event queue corrupted head=%08x tail=%08x state=%08x',head,tail,self.base))
  for _=1,math.min(6,(head-tail)&0xffffffff) do
   self.heartbeat()
   local address=self.base+1024+(tail%16)*544
   local e=read(address,6);check(e[5]<=514,'BLE event length corrupted')
   result.events[#result.events+1]={kind=e[1],status=signed(e[2]),a=e[3],b=e[4],generation=e[6],data=e[5]>0 and bytes(address+24,e[5]) or ''}
   tail=(tail+1)&0xffffffff;write(616,tail)
  end
  -- Sample at most the six newest notifications. The independent control FIFO
  -- above remains lossless until an actual control overflow (still fatal).
  -- Each notification slot is read under a sequence check; never accept torn
  -- payloads or block a callback while Lua is descheduled.
  local available=(q[11]-self.notify_cursor)&0xffffffff
  if available>6 then
   self.notify_skipped=self.notify_skipped+available-6
   self.notify_cursor=(q[11]-6)&0xffffffff;available=6
  end
  for _=1,available do
   self.heartbeat()
   local index=self.notify_cursor
   local address=self.base+10104+(index%16)*548
   local expected=((index+1)*2)&0xffffffff
   local e=read(address,16) -- stamp + header + first 36 bytes, one shell read
   if e[1]~=expected then break end
   local n=e[6];local data=''
   if n<=514 then
    local parts={};for i=8,16 do parts[#parts+1]=string.pack('<I4',e[i])end
    data=table.concat(parts):sub(1,n)
    if n>36 then data=data..bytes(address+64,n-36)end
   end
   if read(address,1)[1]~=expected then break end
   check(e[2]==10 and n<=514,'BLE notification slot corrupted')
   result.events[#result.events+1]={kind=10,status=signed(e[3]),a=e[4],b=e[5],generation=e[7],data=data}
   self.notify_cursor=(index+1)&0xffffffff
  end
  result.notification_skipped=self.notify_skipped+((q[12]-self.notify_drop_base)&0xffffffff)
  return result
 end
 function self.close()
  if self.base then write(600,1);write(648,0)end
  self.closed=true
 end
 return self
end
return M
