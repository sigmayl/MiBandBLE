#!/usr/bin/env python3
"""Build the BLE remote watchface: PIC bridge payload, Lua app and install package.

Two inputs are not part of this repository (see README): the target firmware
image, and the stock watchface container the package is repacked from.
"""
import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from elf_image import linked_binary
from watchface import repack

WATCHFACE_ID = '000000399920'
WATCHFACE_TITLE = '迷路遥控'
REVISION = 'r8-minimal-sliders'
PACKAGE_NAME = 'o66cn-3.1.28-native-ble-r8.bin'
# Runtime image of the target: file offset 0 maps here in the code view.
IMAGE_BASE = 0x0c0a0000

# Firmware words fingerprinted into the build manifest in addition to the
# entries listed in native/abi.h: allocator wrappers, BLE callback dispatch
# sites, and the attribute type switch with its labels.
EXTRA_FINGERPRINTS = [
    0x0c121d0c, 0x0c121d1c,
    0x0c4c8320, 0x0c4c8358, 0x0c4c837c, 0x0c4c83ce, 0x0c4c83fe, 0x0c4c843c, 0x0c4c8498,
    0x0c4d573c, 0x0c4d574c, 0x0c4d57f0, 0x0c4d5800, 0x0c4d5834,
]

COMPILE_FLAGS = [
    '--target=arm-none-eabi', '-march=armv8-m.main', '-mthumb', '-mfloat-abi=soft',
    '-ffreestanding', '-fPIC', '-fno-builtin', '-fno-common', '-fno-stack-protector',
    '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-fno-jump-tables',
    '-ffunction-sections', '-fdata-sections', '-fstack-usage',
    '-Os', '-Wall', '-Wextra', '-Werror',
]


def run(*args):
    subprocess.run([str(x) for x in args], check=True)


def lua(value):
    """Serialize a Python value as a Lua literal for the loader profile."""
    if isinstance(value, dict):
        return '{' + ',\n'.join(f'[{json.dumps(k)}]={lua(v)}' for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '{' + ','.join(lua(x) for x in value) + '}'
    if isinstance(value, str):
        return json.dumps(value)
    if type(value) is int:
        return str(value)
    raise ValueError(f'unsupported Lua value {value!r}')


def metadata(firmware):
    """Target profile, plus the firmware words every recovered entry depends on."""
    profile = json.loads((ROOT / 'tools/target-profile.json').read_text())
    if profile['schema'] != 1:
        raise ValueError('unsupported target profile schema')
    if hashlib.sha256(firmware).hexdigest() != profile['firmware_sha256']:
        raise ValueError('firmware SHA-256 mismatch')
    result = {k: v for k, v in profile.items() if k != 'fingerprint_spans'}
    result.update({k: int(v, 16) for k, v in result.items() if isinstance(v, str) and v.startswith('0x')})
    result['fingerprints'] = []
    for item in profile['fingerprint_spans']:
        address, size = int(item['address'], 16), item['size']
        offset = address - IMAGE_BASE
        if address % 4 or size % 4 or not 4 <= size <= 256 or not 0 <= offset <= len(firmware) - size:
            raise ValueError('invalid fingerprint span')
        result['fingerprints'].append(dict(address=address, words=list(struct.unpack_from(f'<{size // 4}I', firmware, offset))))
    return result


def build(out, firmware_path, template_path):
    out, work = Path(out), Path(out) / 'build'
    out.mkdir(parents=True, exist_ok=True)
    work.mkdir(exist_ok=True)
    firmware = Path(firmware_path).read_bytes()
    profile = metadata(firmware)

    abi = (ROOT / 'native/abi.h').read_text()
    addresses = set(int(x, 16) & ~3 for x in re.findall(r'FW\((0x[0-9a-f]+)', abi))
    addresses = sorted(addresses | {a & ~3 for a in EXTRA_FINGERPRINTS})
    evidence = []
    for address in addresses:
        data = firmware[address - IMAGE_BASE:address - IMAGE_BASE + 16]
        profile['fingerprints'].append(dict(address=address, words=list(struct.unpack('<4I', data))))
        evidence.append(dict(address=f'0x{address:08x}', bytes=data.hex(), sha256=hashlib.sha256(data).hexdigest()))

    objects = []
    for source in (ROOT / 'native/entry.S', ROOT / 'native/bridge.c'):
        obj = work / (source.stem + '.o')
        run(os.environ.get('CC', 'clang'), *COMPILE_FLAGS, '-I', ROOT / 'native', '-c', source, '-o', obj)
        objects.append(obj)
    elf = work / 'payload.elf'
    run('ld.lld', '-static', '--gc-sections', '--emit-relocs', '-e', 'o66_entry',
        '-T', ROOT / 'native/payload.ld', '-o', elf, *objects)
    image = linked_binary(elf)
    image += bytes(-len(image) % 4)
    assert 128 <= len(image) <= 32768 and image[4:8] == bytes(4)
    profile.update(image_size=len(image), image_crc=zlib.crc32(image))
    (out / 'payload.bin').write_bytes(image)
    (out / 'profile.lua').write_text('return ' + lua(profile) + '\n')
    (out / 'abi-evidence.json').write_text(
        json.dumps(dict(firmware_sha256=profile['firmware_sha256'], spans=evidence), indent=2) + '\n')

    # The watchface runs as a single Lua chunk: every module is inlined in the
    # order the entry script expects.
    source = 'local native=(function()\n' + (ROOT / 'lua/loader.lua').read_text() + '\nend)()\n'
    source += 'local profile=' + lua(profile) + '\n'
    source += 'local image=(' + json.dumps(image.hex()) + '):gsub("..",function(x)return string.char(tonumber(x,16))end)\n'
    source += 'local BLE=(function()\n' + (ROOT / 'lua/transport.lua').read_text() + '\nend)()\n'
    source += 'local P=(function()\n' + (ROOT / 'lua/protocol.lua').read_text() + '\nend)()\n'
    source += 'local Session=(function()\n' + (ROOT / 'lua/session.lua').read_text() + '\nend)()\n'
    source += 'local Display=(function()\n' + (ROOT / 'lua/display.lua').read_text() + '\nend)()\n'
    source += (ROOT / 'lua/main.lua').read_text()
    (out / 'main.lua').write_text(source)
    run('luac5.4', '-p', out / 'main.lua')
    (out / PACKAGE_NAME).write_bytes(repack(Path(template_path).read_bytes(), source.encode(),
                                           face_id=WATCHFACE_ID, title=WATCHFACE_TITLE))

    names = ['payload.bin', 'profile.lua', 'abi-evidence.json', 'main.lua', PACKAGE_NAME]
    manifest = dict(revision=REVISION, target=profile['target_id'], firmware_sha256=profile['firmware_sha256'],
                    device_status='NOT_PROBED', image_size=len(image), image_crc=zlib.crc32(image),
                    watchface_id=WATCHFACE_ID,
                    files={n: dict(size=(out / n).stat().st_size,
                                   sha256=hashlib.sha256((out / n).read_bytes()).hexdigest()) for n in names})
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--firmware', type=Path,
                        default=Path(os.environ.get('O66_FIRMWARE', ROOT / 'firmware/vela_ap.bin')))
    parser.add_argument('--template', type=Path,
                        default=Path(os.environ.get('O66_WATCHFACE_TEMPLATE', ROOT / 'firmware/watchface-template.bin')))
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    args = parser.parse_args()
    build(args.output.resolve(), args.firmware, args.template)


if __name__ == '__main__':
    main()
