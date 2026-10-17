#!/usr/bin/env python3
"""Render UI test snapshots through a 212 x 520 capsule mask (not a device capture).

lua5.4 tests/display.lua /tmp/o66-ui.json
python3 preview.py /tmp/o66-ui.json
Requires Pillow and a CJK font; --font can select the local font file.
"""
import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('snapshots', type=Path)
parser.add_argument('--font', default='/usr/share/fonts/harmonyos-sans/HarmonyOS_Sans_SC.ttf')
parser.add_argument('--output', type=Path, default=Path(__file__).parent / 'dist/ui-preview-r8.png')
args = parser.parse_args()
pages = {p['name']: p for p in json.loads(args.snapshots.read_text())}
selected = ['首页', '选择设备', '双通道调节']
canvas = Image.new('RGB', (244 * len(selected), 592), '#080c0d')
mask = Image.new('L', (212, 520))
ImageDraw.Draw(mask).rounded_rectangle((0, 0, 211, 519), radius=106, fill=255)

def font(size):
    return ImageFont.truetype(args.font, size)

def color(value):
    return f'#{value:06x}'

for index, name in enumerate(selected):
    panel = Image.new('RGB', (212, 520), '#101416')
    draw = ImageDraw.Draw(panel)
    for item in pages[name]['items']:
        x, y, w, h = (item[k] for k in ('x', 'y', 'w', 'h'))
        is_button = item['kind'] == 'object'
        if is_button:
            draw.rounded_rectangle((x, y, x+w-1, y+h-1), radius=item['radius'], fill=color(item['bg']))
        for part in item.get('parts', []):
            px, py = x+part['x'], y+part['y']
            draw.rounded_rectangle((px, py, px+part['w']-1, py+part['h']-1), radius=part['radius'], fill=color(part['bg']))
        if 'text' not in item:
            continue
        face = font(item['font'])
        lines = item['text'].split('\n')
        line_height = item['font'] + 4
        # Fail visibly when copy is too wide/tall with the preview font.
        assert len(lines)*line_height <= h, (name, item['text'], 'height')
        top = y + (h-len(lines)*line_height)/2 if is_button else y
        for line in lines:
            length = draw.textlength(line, font=face)
            assert length <= w, (name, line, 'width')
            draw.text((x+(w-length)/2, top), line, font=face, fill=color(item['color']), anchor='lt')
            top += line_height
    ox = index*244+16
    ImageDraw.Draw(canvas).text((ox+106, 20), name, font=font(18), fill='#d0ded6', anchor='mt')
    canvas.paste(panel, (ox, 56), mask)
args.output.parent.mkdir(parents=True, exist_ok=True)
canvas.save(args.output)
print(args.output)
