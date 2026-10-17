#!/usr/bin/env python3
"""Extract the flat PIC image from a linked ARM ELF payload.

The bridge payload runs from an address the linker does not know, so the ELF is
only a container: the image that gets copied into PSRAM is the allocatable
sections laid out at their link-time offsets. This module performs that
extraction and checks the invariants the payload must keep, without objcopy.
"""
from __future__ import annotations
import struct
from pathlib import Path

# AArch32 relocation types that stay valid after the image is moved.
PC_RELATIVE_RELOCATIONS = frozenset((3, 10, 23, 30, 42))


def elf_sections(path):
    data = Path(path).read_bytes()
    if data[:7] != b"\x7fELF\x01\x01\x01":
        raise ValueError("not little-endian ELF32")
    offset = struct.unpack_from("<I", data, 32)[0]
    stride, count, names = struct.unpack_from("<HHH", data, 46)
    rows = [struct.unpack_from("<10I", data, offset + i * stride) for i in range(count)]
    strings = data[rows[names][4]:rows[names][4] + rows[names][5]]
    return data, [(strings[r[0]:].split(b"\0", 1)[0].decode(), r) for r in rows]


def linked_binary(path):
    """Check PIC invariants and extract allocatable sections without objcopy."""
    data, sections = elf_sections(path)
    alloc = [(name, r) for name, r in sections if r[2] & 2 and r[5]]
    if any(r[1] == 8 or r[2] & 1 for _, r in alloc):
        raise ValueError("staged PIC image must have no GOT, writable data, or BSS")
    # --emit-relocs preserves link evidence. Absolute link-time addresses would
    # be wrong after moving the binary; only PC-relative relocations are allowed.
    for name, r in sections:
        if r[1] == 9:
            for pos in range(r[4], r[4] + r[5], 8):
                _, info = struct.unpack_from("<II", data, pos)
                if info & 255 not in PC_RELATIVE_RELOCATIONS:
                    raise ValueError(f"non-PIC relocation {info & 255} in {name}")
    end = max(r[3] + r[5] for _, r in alloc)
    result = bytearray(end)
    for _, r in alloc:
        result[r[3]:r[3] + r[5]] = data[r[4]:r[4] + r[5]]
    if struct.unpack_from("<I", data, 24)[0] & ~1:
        raise ValueError("stage entry must be offset zero")
    return bytes(result)
