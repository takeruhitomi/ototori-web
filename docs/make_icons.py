"""Web icons from the app icon (assets/icon/png/icon_full_1024.png).

favicon.png is cropped closer so the bird stays legible at 16-32 px; the
home-screen and maskable icons use the full square (the bird lies inside
the 80% maskable safe zone). Run from apps/choir_mobile with Pillow:
  python web/make_icons.py
"""
from pathlib import Path
from PIL import Image

HERE = Path(__file__).resolve().parent
source = Image.open(HERE.parent / 'assets' / 'icon' / 'png' / 'icon_full_1024.png').convert('RGB')

def save(image, size, name):
    image.resize((size, size), Image.LANCZOS).save(HERE / name, optimize=True)

save(source.crop((170, 150, 870, 850)), 64, 'favicon.png')
for size in (192, 512):
    save(source, size, f'icons/Icon-{size}.png')
    save(source, size, f'icons/Icon-maskable-{size}.png')
save(source, 180, 'icons/apple-touch-icon.png')
print('ok')
