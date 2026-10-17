#!/usr/bin/env python3
"""Unicorn harness that runs the real firmware bodies the bridge payload calls.

The target firmware image and the built PIC image are mapped at their real
addresses; only NSH printf and the strto* errno location service are modeled.
RAM aliases share host backing. Physical cache/MPU enforcement is not modeled.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import struct

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_MODE_MCLASS, UC_PROT_ALL, UC_HOOK_CODE, UC_HOOK_MEM_WRITE
from unicorn.arm_const import *

ROOT = Path(__file__).resolve().parents[1]
AP = Path(os.environ.get('O66_FIRMWARE', ROOT / 'firmware/vela_ap.bin')).read_bytes()
PROFILE = json.loads((ROOT / 'tools/target-profile.json').read_text())
PAYLOAD = (ROOT / 'dist/payload.bin').read_bytes()


class Machine:
    def __init__(self):
        assert hashlib.sha256(AP).hexdigest() == PROFILE['firmware_sha256']
        self.uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS)
        self.uc.ctl_set_cpu_model(UC_CPU_ARM_CORTEX_M33)
        self.buffers = []
        self.alias((0x0c0a0000, 0x2c0a0000), (len(AP)+4095)&~4095, AP)
        self.alias((0x1c000000, 0x3c000000), 0x1000000)
        for address, size in [(0x20000000,0x200000),(0xe000e000,0x2000),(0x07ffa000,0x4000),(0x10000,0x1000)]:
            self.uc.mem_map(address,size)
        # Startup copies these instructions to SRAM; strcmp's ROM veneer
        # branches to the code alias, so execute that real body too.
        self.uc.mem_map(0x00260000,0x20000)
        self.uc.mem_write(0x0026be00,AP[0x1b64:0xecfc])
        self.uc.mem_write(0x10000, bytes.fromhex('7047'))
        self.uc.mem_write(0x10020, bytes.fromhex('7047'))
        self.put(0x20001018, 0x10001)
        self.put(0x20001014, 0x10001)
        self.put(0xe000ed94,5)
        self.put(0x07ffa000,1)
        self.put(0x07ffc000,1)
        self.text = ''
        self.writes = []
        self.minimum_sp = 0x2001f000
        self.uc.hook_add(UC_HOOK_CODE,self.step)
        self.write_hook = self.uc.hook_add(UC_HOOK_MEM_WRITE,lambda uc,access,a,size,v,data:self.writes.append((a,size,v)))

    def alias(self, addresses, size, data=b''):
        backing = ctypes.create_string_buffer(size)
        ctypes.memmove(backing,data,len(data))
        self.buffers.append(backing)
        for a in addresses:
            self.uc.mem_map_ptr(a,size,UC_PROT_ALL,ctypes.addressof(backing))

    def put(self,a,v): self.uc.mem_write(a,struct.pack('<I',v))
    def word(self,a): return struct.unpack('<I',self.uc.mem_read(a,4))[0]
    def cstr(self,a):
        result = bytearray()
        while True:
            b=self.uc.mem_read(a,1)[0]
            if not b: return result.decode()
            result.append(b); a+=1
            assert len(result)<1024

    def step(self,uc,a,size,data):
        self.minimum_sp=min(self.minimum_sp,uc.reg_read(UC_ARM_REG_SP))
        if a==0x10020:
            uc.emu_stop()
        elif a==0x0c0e9104: # getpid: task scheduling is outside this emulator
            uc.reg_write(UC_ARM_REG_R0,123)
            uc.reg_write(UC_ARM_REG_PC,uc.reg_read(UC_ARM_REG_LR))
        elif a==0x10000:
            fmt=self.cstr(uc.reg_read(UC_ARM_REG_R1))
            r2,r3=uc.reg_read(UC_ARM_REG_R2),uc.reg_read(UC_ARM_REG_R3)
            if fmt=='  %p = 0x%08lx': text=f'  0x{r2:08x} = 0x{r3:08x}'
            elif fmt==' -> 0x%08lx': text=f' -> 0x{r2:08x}'
            elif fmt=='Calling %p\n': text=f'Calling 0x{r2:08x}\n'
            elif fmt=='\n': text='\n'
            elif fmt=='nsh: %s: argument invalid\n': text='argument invalid\n'
            else: raise AssertionError(fmt)
            self.text+=text
            uc.reg_write(UC_ARM_REG_R0,len(text))
            uc.reg_write(UC_ARM_REG_PC,uc.reg_read(UC_ARM_REG_LR))

    def call(self,pc,*args):
        self.uc.reg_write(UC_ARM_REG_SP,0x2001f000)
        self.uc.reg_write(UC_ARM_REG_LR,0x10021)
        for reg,value in zip((UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_R3),args):
            self.uc.reg_write(reg,value)
        saved={reg:0xabc00000+i for i,reg in enumerate((UC_ARM_REG_R4,UC_ARM_REG_R5,UC_ARM_REG_R6,UC_ARM_REG_R7,
                                                      UC_ARM_REG_R8,UC_ARM_REG_R9,UC_ARM_REG_R10,UC_ARM_REG_R11))}
        for reg,v in saved.items(): self.uc.reg_write(reg,v)
        self.uc.emu_start(pc|1,0,count=getattr(self,'instruction_budget',200000))
        assert self.uc.reg_read(UC_ARM_REG_PC)==0x10020, hex(self.uc.reg_read(UC_ARM_REG_PC))
        assert self.uc.reg_read(UC_ARM_REG_SP)==0x2001f000
        for reg,v in saved.items(): assert self.uc.reg_read(reg)==v
        return self.uc.reg_read(UC_ARM_REG_R0)

    def command(self, command, dispatch=True):
        args=command.split()
        argv,strings=0x20002000,0x20002100
        for i,arg in enumerate(args):
            self.put(argv+i*4,strings)
            self.uc.mem_write(strings,arg.encode()+b'\0')
            strings+=len(arg)+1
        self.put(argv+len(args)*4,0)
        self.text=''
        address=0x0c17e0dc if dispatch else {'mw':0x0c17f048,'exec':0x0c183e0c}[args[0]]
        return self.call(address,0x20001000,len(args),argv)

