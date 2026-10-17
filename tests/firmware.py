#!/usr/bin/env python3
"""Actual Thumb bridge and firmware wrappers/dispatcher; radio, IPC and OS are modeled."""
import sys,struct,unittest,zlib,subprocess
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
from simulator import Machine,AP,PROFILE
from unicorn import UC_HOOK_CODE
from unicorn.arm_const import *
ROOT=Path(__file__).resolve().parents[1]
IMAGE=(ROOT/'dist/payload.bin').read_bytes()
class BLEMachine(Machine):
 def __init__(self,base=0x3c800000):
  super().__init__();self.uc.hook_del(self.write_hook)
  # R6's larger PIC takes >200k instructions through the real bootstrap CRC.
  self.instruction_budget=400000
  self.put(int(PROFILE['umem_slot'],16),int(PROFILE['umem_descriptor'],16))
  self.heap=base;self.rpc=[];self.freed=[];self.spawn=None;self.callbacks=None;self.worker_context=None
  self.instance=0x3c600000;self.client=0x3c601000;self.scan=0x3c602000
  self.put(self.client,self.instance);self.put(self.client+8,0x12345678)
  self.put(self.instance+168,0x3c603000)
  self.rpc_status=0;self.alloc_fail=False;self.model_create=True;self.added=[]
  self.uc.hook_add(UC_HOOK_CODE,self.ble_hook)
 def ret(self,value=0):
  self.uc.reg_write(UC_ARM_REG_R0,value&0xffffffff);self.uc.reg_write(UC_ARM_REG_PC,self.uc.reg_read(UC_ARM_REG_LR))
 def ble_hook(self,uc,a,size,data):
  r=[uc.reg_read(x) for x in (UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_R3)]
  if a==0x0c121ba4: # Model ONLY mm_malloc; execute both real public wrappers and mm_zalloc.
   assert r[0]==int(PROFILE['umem_descriptor'],16)
   if self.alloc_fail:self.ret(0);return
   p=self.heap;n=(r[1]+7)&~7;self.heap+=n
   uc.mem_write(p,b''.join(struct.pack('<I',(p+i)^0xa5a5a5a5) for i in range(0,n,4)))
   self.ret(p)
  elif a==0x0c112e00:self.ret(0x20003000)
  elif a==0x0c11eee8:self.freed.append(r[0]);self.ret()
  elif a==0x0c11372c:uc.mem_write(r[0],bytes(20));self.ret()
  elif a==0x0c50fce8:
   self.spawn=(r,self.word(uc.reg_read(UC_ARM_REG_SP)),bytes(uc.mem_read(r[3],20)))
   assert self.cstr(r[0])=='o66_ble';self.ret(222)
  elif a==0x0c4cc9b0:self.ret(self.instance)
  elif a==0x0c4c6528 and self.model_create:
   self.callbacks=r[2];self.put(r[1],self.client);self.put(self.client+4,r[2]);self.ret()
  elif a==0x0c4c6038:
   message=bytes(uc.mem_read(r[1],612));self.rpc.append((r[2],message))
   self.put(r[1]+4,self.rpc_status)
   if r[2]==109:self.put(r[1]+8,0x12345678)
   if r[2]==213:self.put(r[1]+4,0x13579)
   if r[2]==114:uc.mem_write(r[1]+8,bytes(range(32)))
   self.ret()
  elif a==0x0c4c55e8:self.added.append((r[0],r[1]));self.ret(1)
  elif a==0x0c4c5474:self.ret(0x3c603100)
  elif a==0x0c4c54b8:self.ret(self.client)
  elif a==0x0c4c5494:self.ret(0)
  elif a==0x0c11ed98:
   self.last_delay=r[0]
   self.ret();self.worker_context=uc.context_save();uc.emu_stop()
 def boot(self):
  p=0x3c400000;self.uc.mem_write(p,struct.pack('<8I',0,0x66310001,len(IMAGE),0,0,0,0,0)+IMAGE)
  self.put(p+36,p);rc=self.call(p+32-0x20000000);self.state=self.word(p+12);return rc
 def tick(self,start=False):
  if start:
   self.uc.reg_write(UC_ARM_REG_SP,0x2002f000);self.uc.reg_write(UC_ARM_REG_LR,0x10021)
   pc=self.spawn[0][1]
  else:
   self.uc.context_restore(self.worker_context);pc=self.uc.reg_read(UC_ARM_REG_PC)|1
  self.uc.emu_start(pc|1,0,count=300000)
  assert self.worker_context is not None
 def request(self,op,a=0,b=0,data=b''):
  s=self.state;self.put(s+64,op);self.put(s+68,a);self.put(s+72,b);self.put(s+76,len(data))
  if data:self.uc.mem_write(s+80,data)
  seq=self.word(s+56)+1;self.put(s+56,seq);self.put(s+596,self.word(s+596)+1);self.tick()
  assert self.word(s+60)==seq
  return self.word(s+632)
 def dispatch(self,kind,body=b'',scan=False):
  e=0x3c610000;self.uc.mem_write(e,bytes(624));self.put(e+8,self.instance)
  self.uc.mem_write(e+12,struct.pack('<H',kind))
  self.put(e+56,self.word(self.state+9728+8) if scan else self.client)
  self.uc.mem_write(e+60,body)
  return self.call(0x0c4c7e0c,e)
 def event(self,index=None):
  if index is None:index=self.word(self.state+612)-1
  p=self.state+1024+(index%16)*544
  h=struct.unpack('<6I',self.uc.mem_read(p,24))
  return h,bytes(self.uc.mem_read(p+24,h[4]))
 def notification(self,index=None):
  if index is None:index=(self.word(self.state+636)-1)&0xffffffff
  p=self.state+10104+(index%16)*548
  assert self.word(p)==((index+1)*2)&0xffffffff
  h=struct.unpack('<6I',self.uc.mem_read(p+4,24))
  return h,bytes(self.uc.mem_read(p+28,h[4]))
class Tests(unittest.TestCase):
 def test_control_batches_continue_in_background_and_close_stops_first(self):
  m=BLEMachine();m.boot();m.tick(True);m.request(1);m.put(m.state+604,2)
  levels=b'A'*12+b'B'*12;stop=b'X'*12+b'Y'*12+b'Z'*12
  self.assertEqual(m.request(11,5,data=levels+stop),0);seq=m.word(m.state+56)
  def writes():return [msg[52:64] for op,msg in m.rpc if op==118]
  self.assertEqual(writes(),[b'A'*12])
  m.put(m.state+648,1)
  for _ in range(2):m.dispatch(263,bytes(2)+struct.pack('<H',5));m.tick()
  self.assertEqual(writes(),[b'A'*12,b'B'*12]);self.assertEqual(m.event()[0][:4],(12,0,5,seq))
  self.assertEqual(m.last_delay,1000000)
  m.put(m.state+600,1);m.tick();self.assertNotIn(112,[op for op,_ in m.rpc])
  for i in range(3):
   self.assertEqual(writes()[-1],bytes([ord('X')+i])*12)
   m.dispatch(263,bytes(2)+struct.pack('<H',5));m.tick()
  m.tick();self.assertEqual(m.rpc[-1][0],112)
  self.assertEqual(writes(),[b'A'*12,b'B'*12,b'X'*12,b'Y'*12,b'Z'*12])
 def test_control_stop_supersedes_queued_levels(self):
  m=BLEMachine();m.boot();m.tick(True);m.request(1);m.put(m.state+604,2)
  stop=b'X'*12+b'Y'*12+b'Z'*12
  m.request(11,5,data=b'A'*24+stop)
  self.assertEqual(m.request(8,5,data=b'legacy'),(-16)&0xffffffff)
  m.request(11,5,data=b'B'*24+stop);m.request(12,5,data=stop);seq=m.word(m.state+56)
  self.assertEqual(len([op for op,_ in m.rpc if op==118]),1)
  # Finish the already-sent A, then all three stop frames; never send B or A2.
  for _ in range(4):m.dispatch(263,bytes(2)+struct.pack('<H',5));m.tick()
  self.assertEqual([msg[52:64] for op,msg in m.rpc if op==118],[b'A'*12,b'X'*12,b'Y'*12,b'Z'*12])
  self.assertEqual(m.event()[0][:4],(12,0,5,seq));self.assertEqual(m.word(m.state+692),0)
 def test_control_failure_and_timeout_never_report_success(self):
  for failure in ('callback','timeout'):
   m=BLEMachine();m.boot();m.tick(True);m.request(1);m.put(m.state+604,2)
   self.assertEqual(m.request(12,5,data=b'X'*36),0);seq=m.word(m.state+56)
   if failure=='callback':m.dispatch(263,bytes([5,0])+struct.pack('<H',5));m.tick()
   else:
    for _ in range(150):m.put(m.state+596,m.word(m.state+596)+1);m.tick()
   self.assertEqual(m.event()[0][:4],(12,5 if failure=='callback' else (-110)&0xffffffff,5,seq))
   self.assertEqual(m.word(m.state+600),1)
  m=BLEMachine();m.boot();m.tick(True);m.request(1);m.put(m.state+604,2)
  self.assertEqual(m.request(11,5,data=b'x'*59),(-22)&0xffffffff)
  self.assertEqual(m.request(12,0,data=b'x'*36),(-22)&0xffffffff)
 def test_attribute_types_from_actual_bttool_switch(self):
  # Execute the original attribute type load, comparison, TBB and format loads.
  # The earlier Lua fixture incorrectly used 2=CHR and hid the device failure.
  m=BLEMachine();attribute=0x3c610000
  m.uc.reg_write(UC_ARM_REG_R7,attribute)
  for kind,label in enumerate(('PRI','SND','INC','CHR','DES')):
   m.uc.mem_write(attribute+24,bytes([kind]))
   m.uc.emu_start(0x0c4d573f,0x0c4d5752,count=30)
   self.assertEqual(m.uc.reg_read(UC_ARM_REG_PC),0x0c4d5752)
   self.assertTrue(m.cstr(m.uc.reg_read(UC_ARM_REG_R0)).endswith('['+label+']'))
 def test_boot_relocation_and_independent_task(self):
  for addr in (0x3c800000,0x3ca00000):
   m=BLEMachine(addr);self.assertEqual(m.boot(),0);s=m.state
   self.assertEqual(m.word(addr+4),s);self.assertEqual(m.word(s+32),0x36424c45)
   self.assertEqual(m.word(s+44),zlib.crc32(IMAGE))
   code=bytearray(m.uc.mem_read(addr,len(IMAGE)));code[4:8]=bytes(4);self.assertEqual(code,IMAGE)
   self.assertTrue(addr-0x20000000<=m.spawn[0][1]<s-0x20000000)
   self.assertEqual(struct.unpack_from('<I',m.spawn[2],12)[0],8192)
   self.assertEqual(m.spawn[2][:2],b'\x04\x64')
   m.tick(True);self.assertEqual(m.word(s+48),1)
   for i in range(1,8):self.assertTrue(addr-0x20000000<=m.word(m.callbacks+i*4)<s-0x20000000)
 def test_scan_start_stop_actual_dispatcher(self):
  m=BLEMachine();m.boot();m.tick(True);self.assertEqual(m.request(1),0);self.assertEqual(m.request(2),0)
  op,msg=m.rpc[-1];self.assertEqual(op,213);self.assertEqual(msg[48:56],bytes([1,0,0,0,1,1,0,0]));self.assertEqual(msg[56:72],bytes(16))
  cookie=struct.unpack_from('<I',msg,44)[0]
  e=0x3c610000;m.uc.mem_write(e,bytes(624));m.put(e+8,m.instance);m.uc.mem_write(e+12,struct.pack('<H',317));m.put(e+328,cookie)
  m.call(0x0c4c7e0c,e);self.assertEqual(m.word(m.state+608),2)
  self.assertEqual(m.event()[0][0],2)
  adv=bytes.fromhex('06050403020100c8000010')+bytes.fromhex('02010605095143505703030010020100')
  # Feed the firmware scan decoder; its AD payload starts at envelope+72.
  adv=adv[:10]+bytes([len(adv)-11])+adv[11:]
  m.uc.mem_write(e,bytes(624));m.put(e+8,m.instance);m.uc.mem_write(e+12,struct.pack('<H',316));m.put(e+56,cookie)
  m.uc.mem_write(e+60,adv[:11]+b'\0'+adv[11:]);m.call(0x0c4c7e0c,e)
  self.assertEqual(m.event()[0][0],1);self.assertEqual(m.event()[1],adv)
  self.assertEqual(m.request(3),0);self.assertEqual(m.rpc[-1][0],214)
  m.uc.mem_write(e,bytes(624));m.put(e+8,m.instance);m.uc.mem_write(e+12,struct.pack('<H',318));m.put(e+336,cookie)
  m.call(0x0c4c7e0c,e);self.assertEqual(m.word(m.state+608),0);self.assertIn(cookie,m.freed)
 def test_gatt_wrappers_and_callback_data(self):
  m=BLEMachine();m.boot();m.tick(True);m.request(1)
  address=bytes.fromhex('060504030201');self.assertEqual(m.request(4,data=address),0)
  op,msg=m.rpc[-1];self.assertEqual(op,111);self.assertEqual(msg[48:54],address);self.assertEqual(msg[54],255)
  m.dispatch(258,address);self.assertEqual(m.word(m.state+604),2)
  self.assertEqual(m.event()[0][0],4)
  self.assertEqual(m.request(5),0);self.assertEqual(m.rpc[-1][0],113)
  uuid=bytes([2,0,0,0])+bytes(16)
  m.dispatch(260,bytes([0,0])+struct.pack('<HH',1,9)+bytes(2)+uuid)
  h,data=m.event();self.assertEqual((h[0],h[2],h[3],data),(6,1,9,uuid))
  self.assertEqual(m.request(6,4),0);self.assertEqual(m.event()[1],bytes(range(32)))
  self.assertEqual(m.request(7,4),0);self.assertEqual(m.rpc[-1][0],116)
  m.dispatch(262,bytes(2)+struct.pack('<HH',4,3)+b'abc');self.assertEqual(m.event()[0][0],7);self.assertEqual(m.event()[1],b'abc')
  self.assertEqual(m.request(8,5,data=b'xyz'),0);op,msg=m.rpc[-1];self.assertEqual(op,118);self.assertEqual(msg[48:55],struct.pack('<HH',5,3)+b'xyz')
  m.dispatch(263,bytes(2)+struct.pack('<H',5));self.assertEqual(m.event()[0][:3],(8,0,5))
  self.assertEqual(m.request(9,7,1),0);self.assertEqual(m.rpc[-1][0],119)
  m.dispatch(264,bytes(2)+struct.pack('<H',7)+b'\1');self.assertEqual(m.event()[0][:4],(9,0,7,1))
  payload=bytes(range(256))*2+b'ab';m.dispatch(265,struct.pack('<HH',7,len(payload))+payload)
  self.assertEqual(m.notification()[0][:3],(10,0,7));self.assertEqual(m.notification()[1],payload)
  self.assertEqual(m.request(10),0);self.assertEqual(m.rpc[-1][0],112)
  m.dispatch(259,address);self.assertEqual(m.word(m.state+604),0)
 def test_lease_queue_and_bad_request(self):
  m=BLEMachine();m.boot();m.tick(True);m.request(1);m.put(m.state+604,2)
  self.assertEqual(m.request(8,5,data=b'x'*515),(-22)&0xffffffff)
  for i in range(20):m.dispatch(263,bytes(2)+struct.pack('<H',5))
  self.assertEqual(m.word(m.state+612),16);self.assertEqual(m.word(m.state+620),4)
  for i in range(51):m.tick()
  self.assertEqual(m.word(m.state+600),1);self.assertEqual(m.rpc[-1][0],112)
  self.assertEqual(m.request(8,5,data=b'x'),(-125)&0xffffffff)
 def test_notification_burst_preserves_control_and_latest_data(self):
  m=BLEMachine();m.boot();m.tick(True);m.request(1);m.put(m.state+604,2)
  for batch in range(4):
   # The R3 shared queue loses exactly 59 events on the first 75-frame burst.
   for i in range(batch*75,(batch+1)*75):
    m.dispatch(265,struct.pack('<HHH',7,2,i))
   self.assertEqual(m.word(m.state+620),0)
   self.assertEqual(m.word(m.state+604),2)
   self.assertEqual(m.notification()[1],struct.pack('<H',(batch+1)*75-1))
   self.assertEqual(m.request(8,5,data=b'zero'),0)
   m.dispatch(263,bytes(2)+struct.pack('<H',5));self.assertEqual(m.event()[0][:3],(8,0,5))
   self.assertEqual(m.request(7,4),0)
   m.dispatch(262,bytes(2)+struct.pack('<HH',4,1)+b'x');self.assertEqual(m.event()[0][0],7)
  m.dispatch(264,bytes(2)+struct.pack('<H',7)+b'\1');self.assertEqual(m.event()[0][0],9)
  m.dispatch(259,bytes(6));self.assertEqual(m.event()[0][0],5)
  self.assertEqual(m.word(m.state+620),0)
 def test_notification_lock_isolation_size_and_counter_wrap(self):
  m=BLEMachine();m.boot();m.tick(True);m.request(1)
  m.put(m.state+9812,1) # Hold CONTROL producer lock; notify must still succeed.
  m.dispatch(265,struct.pack('<HH',7,1)+b'x')
  self.assertEqual(m.notification()[1],b'x');self.assertEqual(m.word(m.state+620),0)
  m.put(m.state+9812,0);m.put(m.state+644,1)
  m.dispatch(265,struct.pack('<HH',7,1)+b'x')
  m.dispatch(263,bytes(2)+struct.pack('<H',5))
  self.assertEqual(m.word(m.state+640),1);self.assertEqual(m.word(m.state+620),0)
  self.assertEqual(m.event()[0][0],8)
  m.put(m.state+644,0)
  m.dispatch(265,struct.pack('<HH',7,515)+bytes(515))
  self.assertEqual(m.word(m.state+640),2);self.assertEqual(m.word(m.state+636),1)
  m.put(m.state+636,0xfffffffe)
  for index in (0xfffffffe,0xffffffff,0):
   data=struct.pack('<I',index)
   m.dispatch(265,struct.pack('<HH',7,4)+data)
   self.assertEqual(m.notification(index)[1],data)
  self.assertEqual(m.word(m.state+636),1)
 def test_screen_off_keeps_link_without_heartbeat_and_resumes(self):
  m=BLEMachine();m.boot();m.tick(True);m.request(1);m.put(m.state+604,2)
  m.put(m.state+648,1)
  # 3600 one-second management sleeps, no Lua heartbeat. Callback dispatch
  # still runs independently and keeps bounded recent notification history.
  for i in range(3600):
   m.tick()
   self.assertEqual(m.last_delay,1000000)
   if i%60==0:m.dispatch(265,struct.pack('<HHI',7,4,i))
  self.assertEqual(m.word(m.state+604),2);self.assertEqual(m.word(m.state+600),0)
  self.assertNotIn(112,[op for op,_ in m.rpc]);self.assertEqual(m.notification()[1],struct.pack('<I',3540))
  # Fresh foreground grace period, not an immediate timeout on waking.
  m.put(m.state+596,m.word(m.state+596)+1);m.put(m.state+648,0);m.tick()
  self.assertEqual(m.last_delay,100000)
  self.assertEqual(m.request(8,5,data=b'zero'),0)
  m.dispatch(263,bytes(2)+struct.pack('<H',5));self.assertEqual(m.event()[0][0],8)
  for _ in range(49):m.tick()
  self.assertEqual(m.word(m.state+600),0)
  m.tick();self.assertEqual(m.word(m.state+600),1);self.assertEqual(m.rpc[-1][0],112)
 def test_background_explicit_close_and_scan_connect_timeouts(self):
  m=BLEMachine();m.boot();m.tick(True);m.request(1);m.put(m.state+604,2);m.put(m.state+648,1);m.tick()
  m.put(m.state+600,1);m.tick() # UI close flag, even if its suspend reset fails.
  self.assertEqual(m.rpc[-1][0],112);self.assertEqual(m.last_delay,100000)
  scan=BLEMachine();scan.boot();scan.tick(True);scan.request(1);scan.request(2)
  scan.put(scan.state+608,2);scan.put(scan.state+648,1);scan.tick()
  self.assertEqual(scan.rpc[-1][0],214);self.assertEqual(scan.word(scan.state+600),0)
  connecting=BLEMachine();connecting.boot();connecting.tick(True);connecting.request(1)
  connecting.request(4,data=bytes(6));connecting.put(connecting.state+648,1)
  for _ in range(151):connecting.tick()
  self.assertEqual(connecting.word(connecting.state+600),1)
  self.assertEqual(connecting.rpc[-1][0],112)
 def test_lua_firmware_transport_integration(self):
  m=BLEMachine();m.put(0xe000edc0,0x00447722);m.put(0xe000ed90,0x800)
  from simulator import PROFILE
  heap=int(PROFILE['umem_descriptor'],16)
  m.put(int(PROFILE['mpu_bitmap'],16),15);m.put(int(PROFILE['umem_slot'],16),heap)
  m.put(heap+0x1c,int(PROFILE['heap_start'],16));m.put(heap+0x20,int(PROFILE['heap_end'],16))
  files={'/etc/build.prop':b'ro.build.version=3.1.28\n'};started=False;rpc_index=0;cookie=0;last_payload=b'';passed=False;boot_count=0;captured=[]
  sys.path.insert(0,str(ROOT/'tests'))
  from protocol_model import parse_command
  def inject_scan(kind):
   e=0x3c610000;m.uc.mem_write(e,bytes(624));m.put(e+8,m.instance);m.uc.mem_write(e+12,struct.pack('<H',kind))
   m.put(e+(328 if kind==317 else 336),cookie);m.call(0x0c4c7e0c,e)
  child=subprocess.Popen(['lua5.4',str(ROOT/'tests/integration.lua')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  try:
   for line in child.stdout:
    kind,arg=line.rstrip('\n').split(' ',1)
    if kind=='OWN':
     boot_count+=1;raw=bytes.fromhex(arg);obj,up=0x3c400000,0x3c410000
     m.put(up+8,up+16);m.put(up+16,obj);m.put(up+24,0x54);m.put(obj+4,0x14);m.put(obj+12,len(raw));m.uc.mem_write(obj+16,raw);reply='ok'
    elif kind=='RUN':
     if arg.startswith('mkdir '):reply='ok'
     else:
      cmd,_,redirect=arg.partition(' > ');rc=m.command(cmd)
      if redirect:files[redirect]=m.text.encode()
      reply='ok' if rc<0x80000000 else 'failed'
     if m.spawn:
      if not started:m.state=m.word(0x3c40001c);m.tick(True);started=True
      else:m.tick()
      while rpc_index<len(m.rpc):
       op,msg=m.rpc[rpc_index];rpc_index+=1
       if op==213:cookie=struct.unpack_from('<I',msg,44)[0];inject_scan(317)
       elif op==214:inject_scan(318)
       elif op==111:m.dispatch(258,msg[48:54])
       elif op==112:m.dispatch(259,bytes(6))
       elif op==118:
        handle,n=struct.unpack_from('<HH',msg,48);last_payload=msg[52:52+n];captured.append(last_payload);m.dispatch(263,bytes(2)+struct.pack('<H',handle))
    elif kind=='READ':reply=files[arg].hex() if arg in files else '-'
    elif kind=='REMOVE':files.pop(arg,None);reply='ok'
    elif kind=='WRITE':
     path,raw=arg.split(' ',1);files[path]=bytes.fromhex(raw);reply='ok'
    elif kind=='NOTIFY':m.dispatch(265,struct.pack('<HH',7,len(last_payload))+last_payload);reply='ok'
    elif kind=='BURST':
     frames=bytes.fromhex(arg)
     for start in range(0,len(frames),12):m.dispatch(265,struct.pack('<HH',7,12)+frames[start:start+12])
     m.dispatch(263,bytes(2)+struct.pack('<H',5));reply='ok'
    elif kind=='SLEEP':
     before=len(m.rpc)
     for _ in range(int(arg)):m.tick()
     self.assertEqual(m.word(m.state+600),0);self.assertEqual(m.word(m.state+604),2)
     self.assertEqual(len(m.rpc),before);self.assertEqual(m.last_delay,1000000);reply='ok'
    elif kind=='CAPTURE':captured=[];reply='ok'
    elif kind=='CHECK':
     decoded=[parse_command(frame) for frame in captured]
     self.assertTrue(all(p['checksum_ok'] and p['header']==0x23 for p in decoded))
     levels=[(0x31,50),(0x32,70)] if arg=='QCVW' else [(0x32,60),(0x31,70)]
     self.assertEqual([(p['cmd'],p['p1']) for p in decoded],levels+[(0x32,0),(0x31,0),(0x71,0)])
     reply='ok'
    elif kind=='CORRUPT':m.uc.mem_write(0x3c800008,b'\0');reply='ok'
    elif kind=='PASS':passed=True;break
    else:raise AssertionError(line)
    child.stdin.write(reply+'\n');child.stdin.flush()
   stdout,stderr=child.communicate(timeout=10)
   self.assertEqual(child.returncode,0,stdout+stderr);self.assertTrue(passed);self.assertEqual(boot_count,1)
  finally:
   if child.poll() is None:child.kill();child.communicate()
 def test_real_client_create_ownership(self):
  m=BLEMachine();m.model_create=False;out=0x3c605000;callbacks=0x3c606000
  self.assertEqual(m.call(0x0c4c6528,m.instance,out,callbacks),0)
  handle=m.word(out);self.assertEqual(m.added[-1],(0x3c603000,handle))
  self.assertEqual([m.word(handle+i*4) for i in range(4)],[m.instance,callbacks,0x12345678,out])
  op,msg=m.rpc[-1];self.assertEqual(op,109);self.assertEqual(struct.unpack_from('<I',msg,44)[0],handle)
 def test_real_malloc_and_zalloc_differ(self):
  m=BLEMachine()
  dirty=m.call(0x0c121dc8,37)
  self.assertNotEqual(bytes(m.uc.mem_read(dirty,37)),bytes(37))
  clean=m.call(0x0c121d74,37)
  self.assertEqual(bytes(m.uc.mem_read(clean,37)),bytes(37))
  self.assertNotEqual(bytes(m.uc.mem_read(clean+37,3)),bytes(3))
 def test_boot_clears_reused_heap_state(self):
  m=BLEMachine();self.assertEqual(m.boot(),0);s=m.state
  # These are read before any BLE command; malloc garbage immediately trips the UI.
  self.assertEqual((m.word(s+612)-m.word(s+616))&0xffffffff,0)
  self.assertEqual(bytes(m.uc.mem_read(s+48,9728-48)),bytes(9728-48))
  self.assertEqual(bytes(m.uc.mem_read(s+9744,360)),bytes(360))
  self.assertEqual(bytes(m.uc.mem_read(s+10104,16*548)),bytes(16*548))
  m.tick(True)
  self.assertEqual(m.word(s+48),1)
  self.assertEqual([m.word(s+i) for i in (604,608,612,616,620,9812)],[0]*6)
  self.assertEqual([m.word(m.callbacks+i*4) for i in range(8,13)],[0]*5)
 def test_allocation_failure(self):
  m=BLEMachine();m.alloc_fail=True;self.assertEqual(m.boot(),(-12)&0xffffffff);self.assertIsNone(m.spawn)
if __name__=='__main__':unittest.main(verbosity=2)
