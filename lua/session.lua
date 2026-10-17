-- BLE session and product controls. An acknowledgement is not a GATT completion.
local M={}
local names={[1]='scan',[2]='scan_started',[3]='scan_stopped',[4]='connected',[5]='disconnected',[6]='discovered',[7]='read',[8]='written',[9]='subscribed',[10]='notify',[11]='attribute',[12]='control'}
local base='fb349b5f8000008000100000'
local function require_state(value,message)
 if not value then error(message,0)end
 return value
end
local function uuid(data)
 if #data~=20 or data:byte(1)==0 then return nil end
 -- 0x0c4c5a18 / 0x0c4c5a78: type is byte length 2, 4, or 16.
 if data:byte(1)==2 then return string.unpack('<I2',data,5)end
 if data:byte(1)==4 then return string.unpack('<I4',data,5)end
 local h=(data:sub(5):gsub('.',function(c)return string.format('%02x',c:byte())end))
 -- Firmware bttool prints this exact 128-bit little-endian union in reverse.
 if h:sub(1,24)==base and h:sub(29,32)=='0000' then return tonumber(h:sub(27,28)..h:sub(25,26),16)end
 return h
end
local function ad_name(data)
 local i=1
 while i<=#data do
  local n=data:byte(i);if n==0 then break end
  if n<1 or i+n>#data then return nil end
  local t=data:byte(i+1)
  if t==8 or t==9 then return data:sub(i+2,i+n):gsub('[%z\1-\31]',''):sub(1,24)end
  i=i+n+1
 end
end
function M.new(transport,protocol,log,clock)
 local s={phase='starting',message='启动原生 BLE',devices={},selected=1,notifications=0,notification_skipped=0,reads=0,writes=0,attributes=0,queue={},generation=nil,op=nil,closed=false,desired={0,0},confirmed=nil,control_state='unknown',controls_ready=false}
 log=log or function()end;clock=clock or os.time
 local deadline=clock()+20
 local services,attrs={},{}
 local function fail(message)
  s.phase='failed';s.message=message;s.queue={};s.op=nil;s.control_pending=nil;s.controls_ready=false;s.confirmed=nil;s.control_state='unknown';s.closed=true;pcall(transport.close);log('ERROR '..message)
 end
 local function enqueue(cmd,a,b,data,event,done,allow_error)
  s.queue[#s.queue+1]={cmd=cmd,a=a or 0,b=b or 0,data=data or '',event=event,done=done,allow_error=allow_error}
 end
 local function service_for(h)
  for _,v in ipairs(services)do if h>=v.first and h<=v.last then return v.uuid end end
 end
 local function ready()
  s.phase='ready';s.message='已连接，熄屏保持'
 end
 local function finish_discovery()
  if s.notify_handle then
   s.phase='subscribing';enqueue(9,s.notify_handle,1,'',9,ready)
  else ready()end
 end
 local function enumerate()
  local count=0
  for _,v in ipairs(services)do
   if v.last<v.first or v.last-v.first>255 then fail('服务范围异常');return end
   for h=v.first,v.last do
    if not attrs[h] then
     count=count+1;if count>256 then fail('属性过多，详情见日志');return end
     attrs[h]=true;enqueue(6,h,0,'',11,nil,true)
    end
   end
  end
  if count==0 then fail('未发现 GATT 服务');return end
  s.queue[#s.queue].done=finish_discovery
 end
 local function handle(e)
  log(string.format('event=%s status=%d a=%04x b=%04x data=%s',names[e.kind] or e.kind,e.status,e.a,e.b,protocol.hex(e.data)))
  if e.generation~=s.generation then return end
  if e.kind==1 and #e.data>=11 then
   local raw=e.data:sub(1,6);local address={}
   for i=6,1,-1 do address[#address+1]=string.format('%02X',raw:byte(i))end
   address=table.concat(address,':')
   local name=ad_name(e.data:sub(12,11+e.data:byte(11)))
   local found
   for _,d in ipairs(s.devices)do if d.address==address then found=d end end
   if not found and #s.devices<24 then found={raw=raw,address=address};s.devices[#s.devices+1]=found end
   if found then found.name=name or found.name or address;found.rssi=e.data:byte(8);if found.rssi>=128 then found.rssi=found.rssi-256 end end
  elseif e.kind==2 and e.status~=0 then fail('扫描启动失败 '..e.status)
  elseif e.kind==3 then if s.phase=='scanning' or s.phase=='scan_stopping' then s.phase='idle';s.message='扫描结束'end
  elseif e.kind==4 then
   if s.phase=='connecting' then
    s.phase='discovering';s.message='发现 GATT 服务';services,attrs={},{}
    enqueue(5,0,0,'',6,enumerate)
   end
  elseif e.kind==5 then
   s.phase=s.disconnect_requested and 'disconnecting' or 'idle';s.message='连接已断开';s.queue={};s.op=nil;s.target=nil
   s.write_handle,s.notify_handle,s.read_handle=nil,nil,nil
   s.control_pending=nil;s.confirmed=nil;s.controls_ready=false;s.control_state='unknown'
  elseif e.kind==6 and e.status==0 then
   local u=uuid(e.data)
   if u then services[#services+1]={first=e.a,last=e.b,uuid=u}end
  elseif e.kind==11 and e.status==0 and #e.data==32 then
   s.attributes=s.attributes+1
   local h=string.unpack('<I2',e.data);local u=uuid(e.data:sub(5,24))
   local kind=e.data:byte(25);local props=string.unpack('<I4',e.data,29)
   -- bttool's type switch at 0x0c4d5744: 0 PRI, 1 SND, 2 INC, 3 CHR, 4 DES.
   if kind==3 then
    if props&2~=0 and not s.read_handle then s.read_handle=h end
    if service_for(h)==0x1000 then
     if u==0x1001 and props&8~=0 then
      if s.write_handle and s.write_handle~=h then fail('重复的 0x1001 特征');return end
      s.write_handle=h
     elseif u==0x1002 and props&16~=0 then s.notify_handle=h end
    end
   end
  elseif e.kind==7 then
   if e.status==0 then s.reads=s.reads+1;s.last_read=protocol.hex(e.data)end
  elseif e.kind==8 and e.status==0 then s.writes=s.writes+1
  elseif e.kind==10 then
   s.notifications=s.notifications+1;s.last_notify=protocol.hex(e.data)
   local n=protocol.notification(e.data)
   if n then
    if n.battery~=nil then s.battery=n.battery end
    if n.adc~=nil then s.adc=n.adc end
   end
  end
  local op=s.op
  if op and op.event==e.kind and (e.kind==12 and e.b==op.seq or e.kind~=12 and (e.kind<7 or e.a==op.a)) then
   -- Discovery emits one callback per service and a zero-UUID completion.
   if e.kind~=6 or e.status~=0 or not uuid(e.data) then
    op.seen=true;op.event_rc=e.status
   end
  end
 end
 function s.tick()
  if s.closed or s.suspended_at then return end
  local r=transport.poll()
  if s.disconnect_requested and r.connected==0 and r.scanning==0 then
   s.closed=true;s.phase='closed';s.message='已断开';s.target=nil;s.confirmed=nil;s.controls_ready=false;return
  end
  if r.status==2 then fail('原生 BLE 初始化失败 '..r.error);return end
  if r.dropped>0 then fail('BLE 控制事件丢失 '..r.dropped..'，已请求断开');return end
  if r.notification_skipped and r.notification_skipped~=s.notification_skipped then
   s.notification_skipped=r.notification_skipped
   log('notification samples skipped='..s.notification_skipped)
  end
  if s.phase=='starting' and r.status==1 and r.request==r.ack and r.connected==0 and r.scanning==0 and not s.op then
   enqueue(1,0,0,'',nil,function()s.phase='idle';s.message='原生 BLE 就绪'end)
   s.phase='attaching'
  end
  if r.completed and s.op and r.completed.seq==s.op.seq then
   s.op.acked=true;s.op.rc=r.completed.rc
   if s.op.cmd==1 and r.completed.rc==0 then s.generation=r.generation end
  end
  for _,e in ipairs(r.events)do handle(e)end
  local op=s.op
  if op and op.acked and (op.rc~=0 or not op.event or op.seen) then
   s.op=nil
   local rc=op.rc~=0 and op.rc or (op.event_rc or 0)
   if rc~=0 and not op.allow_error then fail('BLE 操作 '..op.cmd..' 失败 '..rc);return end
   if op.done then op.done()end
  elseif op and clock()>op.deadline then fail('BLE 操作 '..op.cmd..' 超时');return end
  if s.closed then return end
  if s.control_pending and not transport.pending and (not s.op or s.op.cmd==11 or s.op.cmd==12) then
   local pending=s.control_pending;s.control_pending=nil
   s.op={cmd=pending.cmd,a=s.write_handle,b=0,data=pending.data,event=12,deadline=clock()+60}
   s.op.done=function()
    if not s.control_pending then
     s.confirmed=pending.levels;s.desired={pending.levels[1],pending.levels[2]};s.control_state='idle';s.controls_ready=true
     s.message=pending.cmd==12 and '已停止' or '强度已更新'
    end
   end
   s.op.seq=transport.send(s.op.cmd,s.op.a,0,s.op.data)
  elseif not s.op and not transport.pending and #s.queue>0 then
   s.op=table.remove(s.queue,1);s.op.seq=transport.send(s.op.cmd,s.op.a,s.op.b,s.op.data);s.op.deadline=clock()+15
  end
  if s.phase=='starting' and clock()>deadline then fail('原生工作线程启动超时')end
 end
 function s.scan()
  require_state(s.phase=='idle' and not s.op,'请等待当前操作完成')
  s.devices={};s.target=nil;s.selected=1;s.phase='scanning';s.message='扫描 10 秒';enqueue(2)
 end
 function s.connect()
  require_state(s.phase=='idle' and not s.op,'请等待扫描结束')
  local d=require_state(s.devices[s.selected],'请先扫描并选择设备')
  s.target=d;s.notifications=0;s.reads=0;s.writes=0;s.attributes=0;s.read_handle=nil;s.write_handle=nil;s.notify_handle=nil;s.adc=nil;s.battery=nil
  s.controls_ready=false;s.confirmed=nil;s.desired={0,0};s.control_state='unknown';s.control_pending=nil
  s.phase='connecting';s.message='连接 '..d.name;enqueue(4,0,0,d.raw,4)
 end
 function s.read()
  require_state(s.phase=='ready' and not s.op and #s.queue==0,'请等待连接和当前操作完成')
  require_state(s.read_handle,'该设备没有可读特征')
  s.message='正在读取特征';enqueue(7,s.read_handle,0,'',7,function()s.message='读取成功\n'..(s.last_read~='' and s.last_read or '空数据')end)
 end
 function s.write_zero()
  require_state(s.phase=='ready' and not s.op and #s.queue==0,'请等待连接和当前操作完成')
  require_state(s.write_handle,'未找到 0x1001 可写特征')
  require_state(s.target and protocol.variants[s.target.name],'零值写入仅支持 QCPW/QCSW/QCVW')
  s.message='正在写入三条零值命令'
  for _,data in ipairs(protocol.stop())do enqueue(8,s.write_handle,0,data,8)end
  s.queue[#s.queue].done=function()s.message='三条零值命令写入完成'end
 end
 function s.close()
  s.closed=true;s.queue={};s.op=nil;s.control_pending=nil;s.controls_ready=false;s.confirmed=nil;s.phase='closed';s.message='已请求停止扫描和断开';transport.close()
 end
 function s.stop_scan()
  if s.phase=='scanning' then s.phase='scan_stopping';enqueue(3)end
 end
 local function require_control()
  require_state(s.phase=='ready' and not s.closed and s.write_handle and s.target and protocol.variants[s.target.name],'设备尚未准备好')
 end
 function s.set_levels(a,b)
  require_control();require_state(s.controls_ready and s.control_state~='stopping','请等待设备停止')
  local frames=protocol.levels(s.target.name,a,b)
  s.desired={a,b};s.control_state='setting'
  s.control_pending={cmd=11,data=table.concat(frames)..table.concat(protocol.stop()),levels={a,b}}
 end
 function s.stop()
  require_control();s.desired={0,0};s.control_state='stopping'
  s.control_pending={cmd=12,data=table.concat(protocol.stop()),levels={0,0}}
 end
 function s.disconnect()
  s.disconnect_requested=true;s.queue={};s.op=nil;s.control_pending=nil;s.controls_ready=false;s.confirmed=nil;s.phase='disconnecting'
  transport.close()
 end
 function s.suspend()
  if s.closed or s.suspended_at then return end
  -- A tap may precede SCREEN_OFF before the next 250 ms UI tick. Hand the
  -- latest batch to native before Lua pauses, including a stop behind an ACK.
  local submit_deadline=clock()+2
  for _=1,64 do
   if not s.control_pending or s.closed then break end
   s.tick()
   if clock()>=submit_deadline then break end
  end
  if s.control_pending then fail('控制指令提交超时，已请求停止并断开');return end
  if s.closed then return end
  transport.suspend();s.suspended_at=clock()
 end
 function s.resume()
  if s.closed or not s.suspended_at then return end
  transport.resume()
  -- Timers measure foreground waiting, not time spent with the Lua VM paused.
  -- Queued native completions are consumed on the first tick after resume.
  local elapsed=math.max(0,clock()-s.suspended_at)
  deadline=deadline+elapsed
  if s.op then s.op.deadline=s.op.deadline+elapsed end
  s.suspended_at=nil
 end
 M.uuid=uuid;M.ad_name=ad_name
 return s
end
return M
