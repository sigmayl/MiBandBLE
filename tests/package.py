#!/usr/bin/env python3
"""Check the install package against its manifest and the inlined Lua source."""
import hashlib,json,struct,sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from watchface import entries,lua_blob
class Package(unittest.TestCase):
 def test_manifest_and_reachable_scripts(self):
  manifest=json.loads((ROOT/'dist/manifest.json').read_text())
  for name,meta in manifest['files'].items():
   data=(ROOT/'dist'/name).read_bytes();self.assertEqual(len(data),meta['size']);self.assertEqual(hashlib.sha256(data).hexdigest(),meta['sha256'])
  data=(ROOT/'dist/o66cn-3.1.28-native-ble-r8.bin').read_bytes();source=(ROOT/'dist/main.lua').read_bytes()
  self.assertEqual(data[0x28:0x34],b'000000399920')
  records=list(entries(data));lookup={r[:3]:r for r in records};scripts=[]
  for style in range(struct.unpack_from('<H',data,0x1c)[0]):
   for r in records:
    if r[:2]==(style,0):
     tag=struct.unpack_from('<I',data,r[4])[0];self.assertEqual(tag>>24,5);scripts.append(lookup[(style,5,tag&0xffffff)])
  self.assertEqual(len(scripts),5)
  # Every normal style starts the same inlined chunk; AOD styles start none.
  for r in scripts:self.assertEqual(lua_blob(data,r)[2],source)
  self.assertEqual(manifest['device_status'],'NOT_PROBED')
if __name__=='__main__':unittest.main(verbosity=2)
