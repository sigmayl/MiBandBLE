local Session=dofile('lua/session.lua')
local P=dofile('lua/protocol.lua')
local tests=0
local function check(v,msg)assert(v,msg);tests=tests+1 end
local function fixture()
 local t={pending=nil,seq=0,closed=false,events={},connected=0,scanning=0,generation=0,now=0}
 function t.send(op,a,b,data)t.seq=t.seq+1;t.pending={seq=t.seq,op=op,a=a,b=b,data=data};return t.seq end
 function t.poll()
  local c=t.completed;t.completed=nil;local e=t.events;t.events={}
  return {status=1,error=0,request=t.seq,ack=t.pending and t.seq-1 or t.seq,connected=t.connected,scanning=t.scanning,dropped=t.dropped or 0,notification_skipped=t.notification_skipped or 0,generation=t.generation,events=e,completed=c}
 end
 function t.close()t.closed=true end
 function t.suspend()t.suspended=true end
 function t.resume()t.suspended=false end
 function t.ack(rc)
  assert(t.pending);t.completed=t.pending;t.pending=nil;t.completed.rc=rc or 0
  if t.completed.op==1 and t.completed.rc==0 then t.generation=t.generation+1 end
 end
 function t.event(kind,a,b,data,status,gen)t.events[#t.events+1]={kind=kind,a=a or 0,b=b or 0,data=data or '',status=status or 0,generation=gen or t.generation}end
 local s=Session.new(t,P,nil,function()return t.now end)
 s.tick();t.ack();s.tick();check(s.phase=='idle');return s,t
end
local function u16(u)return string.pack('<I4I2',2,u)..string.rep('\0',14)end
local function u128(u)return string.pack('<I4',16)..P.unhex('FB 34 9B 5F 80 00 00 80 00 10 00 00')..string.pack('<I4',u)end
-- Firmware bttool's actual type switch at 0x0c4d5744: 2=INC, 3=CHR, 4=DES.
local function attr(h,u,props,kind)return string.pack('<I2I2',h,0)..u16(u)..string.pack('<I4I4',kind or 3,props)end
local s,t=fixture()
check(Session.uuid(u16(0x1000))==0x1000)
check(Session.uuid(u128(0x1001))==0x1001)
check(Session.uuid(string.pack('<I4I4',4,0x180f)..string.rep('\0',12))==0x180f)
check(not Session.ad_name('\7\9abc'))
s.scan();s.tick();check(t.pending.op==2);t.ack();s.tick()
t.event(1,0,0,string.char(6,5,4,3,2,1,0,200,0,0,6)..'\5\9QCPW');s.tick()
check(s.devices[1].name=='QCPW' and s.devices[1].address=='01:02:03:04:05:06')
t.event(3);s.tick();check(s.phase=='idle')
s.connect();s.tick();check(t.pending.data==string.char(6,5,4,3,2,1))
-- Completion can arrive before the synchronous request ack.
t.event(4,0,0,string.char(6,5,4,3,2,1));s.tick();check(s.op.cmd==4 and s.op.seen)
t.ack();s.tick();check(t.pending.op==5)
t.event(6,1,7,u16(0x1000));s.tick();check(not s.op.seen)
t.ack();t.event(6,0,0,string.rep('\0',20));s.tick();check(t.pending.op==6 and t.pending.a==1)
for h,kind in ipairs({0,1,2,4,3,3,3})do
 t.ack();t.event(11,h,0,attr(h,h<=5 and 0x1001 or h==6 and 0x1002 or 0x2a19,h<=4 and 26 or h==5 and 8 or h==6 and 16 or 2,kind));s.tick()
 if h<=4 then check(not s.read_handle and not s.write_handle and not s.notify_handle,'Only CHR may bind handles')end
end
check(t.pending.op==9 and t.pending.a==6)
t.ack();t.event(9,6,1);s.tick();check(s.phase=='ready' and s.write_handle==5 and s.read_handle==7)
s.write_zero()
local ok,err=pcall(s.write_zero);check(not ok and err=='请等待连接和当前操作完成' and #s.queue==3)
s.tick()
for i,data in ipairs(P.stop())do
 check(t.pending.op==8 and t.pending.data==data)
 t.ack();s.tick();check(s.op~=nil) -- Ack alone must not count as success.
 t.event(8,5);s.tick()
end
check(s.writes==3 and not s.op)
s.read();s.tick();check(t.pending.op==7 and t.pending.a==7)
t.ack();t.event(7,7,0,'\88');s.tick();check(s.reads==1 and s.message=='读取成功\n58')
t.event(10,6,0,string.rep('\0',12));s.tick();check(s.notifications==1)
local plain=string.char(0x23,0x5a,0xb3,0,0,4,0,0,0,0,0)
local sum=0;for i=1,#plain do sum=sum+plain:byte(i)end
t.notification_skipped=69;t.event(10,6,0,P.encrypt(plain..string.char(sum%256)));s.tick()
check(s.phase=='ready' and not t.closed and s.notification_skipped==69 and s.adc==1024)
s.read();s.tick();t.ack();t.event(7,7,0,'\89');s.tick();check(s.reads==2)
s.write_zero();s.tick()
for _=1,3 do t.ack();t.event(8,5);s.tick()end
check(s.writes==6 and s.phase=='ready' and not t.closed)
-- Preserve an in-flight read across hours with the UI timer stopped.
s.read();s.tick();s.suspend();t.now=3600;s.suspend()
t.ack();t.event(7,7,0,'\90');s.tick()
check(t.suspended and s.reads==2 and not t.closed and t.completed~=nil)
s.resume();s.tick();check(not t.suspended and s.reads==3 and s.phase=='ready' and not s.op)
-- Missing completion still times out after the remaining foreground deadline.
s.read();s.tick();s.suspend();t.now=7200;s.resume();s.tick()
check(s.phase=='ready' and not t.closed and s.op.deadline==7215)
t.ack();t.event(7,7,0,'\91');s.tick();check(s.reads==4)
-- Remote disconnect while asleep must clear handles and cancel queued writes.
s.write_zero();s.tick();s.suspend();t.now=10800;t.event(5);s.resume();s.tick()
check(s.phase=='idle' and not s.op and #s.queue==0 and not s.write_handle and not s.read_handle)
s.close();check(t.closed and s.closed)
local s2,t2=fixture();s2.scan();s2.tick();t2.ack(5);s2.tick();check(s2.phase=='failed' and t2.closed)
local s3,t3=fixture();s3.scan();s3.tick();t3.now=16;s3.tick();check(s3.phase=='failed' and t3.closed)
local asleep,ta=fixture();asleep.scan();asleep.tick();asleep.suspend();ta.now=3600;asleep.resume();ta.now=3616;asleep.tick()
check(asleep.phase=='failed' and ta.closed,'Foreground timeout must still work after resume')
local s4,t4=fixture();t4.dropped=1;s4.tick();check(s4.phase=='failed' and t4.closed)
local s5,t5=fixture();s5.phase='ready'
ok,err=pcall(s5.read);check(not ok and err=='该设备没有可读特征' and #s5.queue==0)
ok,err=pcall(s5.write_zero);check(not ok and err=='未找到 0x1001 可写特征' and #s5.queue==0)
s5.write_handle=5;s5.target={name='unknown'}
ok,err=pcall(s5.write_zero);check(not ok and err=='零值写入仅支持 QCPW/QCSW/QCVW' and #s5.queue==0)
local sc,tc=fixture();sc.phase='ready';sc.target={name='QCPW'};sc.write_handle=5
sc.stop();sc.tick();local seq=tc.pending.seq
check(tc.pending.op==12 and tc.pending.data==table.concat(P.stop()) and not sc.controls_ready)
tc.ack();sc.tick();check(not sc.controls_ready,'ACK must not announce stopped')
tc.event(12,5,seq);sc.tick();check(sc.controls_ready and sc.confirmed[1]==0)
sc.set_levels(10,20);sc.set_levels(30,40);sc.tick()
check(tc.pending.op==11 and tc.pending.data==table.concat(P.levels('QCPW',30,40))..table.concat(P.stop()))
local oldseq=tc.pending.seq;tc.ack();sc.tick();sc.stop();sc.tick();seq=tc.pending.seq
check(tc.pending.op==12 and sc.control_state=='stopping')
local accepted=pcall(sc.set_levels,50,60);check(not accepted)
tc.event(12,5,oldseq,'',-125);sc.tick();check(sc.phase=='ready' and sc.op.seq==seq)
tc.ack();tc.event(12,5,seq);sc.tick();check(sc.control_state=='idle' and sc.confirmed[1]==0 and sc.confirmed[2]==0)
sc.set_levels(100,0);sc.tick();seq=tc.pending.seq;tc.ack();tc.event(12,5,seq);sc.tick()
check(sc.confirmed[1]==100 and sc.confirmed[2]==0)
check(not pcall(sc.set_levels,101,0))
-- A tap followed immediately by screen off must reach native before pausing.
sc.set_levels(30,40);sc.suspend()
check(tc.suspended and tc.pending.op==11 and not sc.control_pending)
seq=tc.pending.seq;tc.ack();tc.event(12,5,seq);sc.resume();sc.tick()
sc.set_levels(70,80);sc.tick();oldseq=tc.pending.seq;sc.stop()
local poll=tc.poll;local polls=0
tc.poll=function()
 polls=polls+1
 if polls==3 then tc.ack()end
 return poll()
end
sc.suspend();seq=tc.pending.seq
check(polls==3 and tc.suspended and tc.pending.op==12 and not sc.control_pending and sc.control_state=='stopping')
tc.poll=poll;tc.ack();tc.event(12,5,oldseq,'',-125);tc.event(12,5,seq);sc.resume();sc.tick()
check(sc.controls_ready and sc.confirmed[1]==0 and sc.confirmed[2]==0)
sc.disconnect();check(tc.closed and sc.phase=='disconnecting');sc.tick();check(sc.closed and sc.phase=='closed')
local blocked,tb=fixture();blocked.phase='ready';blocked.target={name='QCVW'};blocked.write_handle=5;blocked.controls_ready=true
blocked.set_levels(20,30);blocked.tick();blocked.stop();blocked.suspend()
check(blocked.phase=='failed' and tb.closed and not tb.suspended,'Unsubmitted stop must request native shutdown instead of silently pausing')
print('BLE session: '..tests..' assertions passed')
