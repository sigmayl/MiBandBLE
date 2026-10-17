"""Patch the known-installable o66cn container without relocating its tables.

Kind 0 is the draw list, including the node that starts Lua. Keep that node
in every normal style, remove native draw references, and replace all five
reachable scripts. Retain the stock assets, previews and descriptor layout.
"""
import hashlib
import struct

TEMPLATE_SHA256 = "5a065e845d4da2478e71f109789bfa1d5bf080b46393a121357045913253602c"
# Do not reuse the stock catalog's 120917... identity namespace. Keep the
# template's 12 ASCII digit layout, with a project-specific custom identity.
# AstroBox rejected the previous 120917399910 candidate as likely official.
FACE_ID = "000000399917"


def entries(data):
    if data[:8] != bytes.fromhex("5a a5 34 12 01 00 01 00"):
        raise ValueError("unsupported watchface header")
    styles = struct.unpack_from("<H", data, 0x1C)[0]
    if not 1 <= styles <= 32 or 0xA0 + styles * 0xA0 > len(data):
        raise ValueError("invalid style count")
    for style in range(styles):
        for kind in range(10):
            count, table = struct.unpack_from("<II", data, 0xB0 + style * 0xA0 + kind * 8)
            if table + count * 16 > len(data):
                raise ValueError("resource table outside container")
            for index in range(count):
                entry = table + index * 16
                tag, flags, offset, size = struct.unpack_from("<4I", data, entry)
                if tag >> 24 != kind or offset + size > len(data):
                    raise ValueError("invalid resource entry")
                yield style, kind, tag & 0xFFFFFF, entry, offset, size


def lua_blob(data, record):
    _, _, _, entry, offset, size = record
    blob = data[offset:offset + size]
    if len(blob) < 20:
        raise ValueError("truncated Lua blob")
    length, name_length = int.from_bytes(blob[:3], "little"), blob[3]
    if len(blob) != 20 + name_length + length or blob[4:20] != bytes(16):
        raise ValueError("unsupported Lua blob layout")
    return entry, blob[20:20 + name_length], blob[20 + name_length:]


def lua_entry(data):
    matches = [e for e in entries(data) if e[:3] == (0, 5, 0)]
    if len(matches) != 1:
        raise ValueError("expected the first style's Lua entry")
    return lua_blob(data, matches[0])


def repack(template, source, *, face_id=FACE_ID, title="迷路遥控"):
    if TEMPLATE_SHA256 and hashlib.sha256(template).hexdigest() != TEMPLATE_SHA256:
        raise ValueError("template differs from the analyzed o66cn firmware")
    if len(source) >= 1 << 24:
        raise ValueError("Lua entry exceeds 24-bit size")
    if len(face_id) != 12 or not face_id.isascii() or not face_id.isdigit():
        raise ValueError("watchface ID must be 12 ASCII digits")
    if len(title.encode()) > 55:
        raise ValueError("watchface title too long")
    records = list(entries(template))
    lookup = {r[:3]: r for r in records}
    result = bytearray(template)
    result[0x28:0x68] = face_id.encode().ljust(64, b"\0")
    result[0x68:0xA0] = title.encode().ljust(56, b"\0")
    styles = struct.unpack_from("<H", template, 0x1C)[0]
    for style in range(styles):
        draws = [r for r in records if r[:2] == (style, 0)]
        scripts = []
        for draw in draws:
            _, _, _, _, offset, size = draw
            if size != 16:
                raise ValueError("unsupported draw node layout")
            tag = struct.unpack_from("<I", template, offset)[0]
            if tag >> 24 == 5:
                scripts.append((draw, lookup[(style, 5, tag & 0xFFFFFF)]))
        if len(scripts) != (0 if style % 2 else 1):
            raise ValueError("unexpected normal/AOD Lua draw nodes")
        # Keep every table at its accepted offset. Only its active draw count
        # changes. AOD is blank; it must not start a second BLE worker.
        struct.pack_into("<I", result, 0xB0 + style * 0xA0, len(scripts))
        for draw, script in scripts:
            _, name, _ = lua_blob(template, script)
            blob = (len(source).to_bytes(3, "little") + bytes([len(name)])
                    + bytes(16) + name + source)
            struct.pack_into("<II", result, script[3] + 8, len(result), len(blob))
            result.extend(blob)
            # First active draw entry is ID 0, pointing at the original Lua
            # node's payload (same style-specific Lua ID and coordinates).
            _, flags, _, _ = struct.unpack_from("<4I", template, draw[3])
            struct.pack_into("<4I", result, draws[0][3], 0, flags, draw[4], draw[5])
    list(entries(result))
    assert lua_entry(result)[2] == source
    return bytes(result)
