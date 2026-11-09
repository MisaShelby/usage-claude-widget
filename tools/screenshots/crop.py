"""Crops the raw GNOME screenshots (tools/screenshots/linux.sh) for the README."""
import json
import sys

from PIL import Image

shots, out = sys.argv[1], sys.argv[2]
try:
    info = json.load(open(f'{shots}/info.json'))
except FileNotFoundError:
    sys.exit('No screenshots: GNOME Shell did not start (see shell.log).')
if 'error' in info:
    sys.exit(f"Screenshot helper failed: {info['error']}")

top = Image.open(f'{shots}/topbar.png').convert('RGB')
width = top.width
panel = info['panel']
strip = top.crop((panel['x'] - 60, 0, width, panel['h']))
strip.resize((strip.width * 2, strip.height * 2), Image.LANCZOS).save(f'{out}/linux-topbar.png')

menu = info['menu']
Image.open(f'{shots}/menu.png').convert('RGB').crop(
    (menu['x'] - 30, 0, width, menu['y'] + menu['h'] + 24)).save(f'{out}/linux-menu.png')

week = info['week']
Image.open(f'{shots}/week.png').convert('RGB').crop(
    (week['x'] - 16, week['y'] - 16, week['x'] + week['w'] + 16, week['y'] + week['h'] + 16)).save(f'{out}/linux-week.png')

print(f"Saved linux-topbar.png, linux-menu.png, linux-week.png in {out} — {info['labels']}")
