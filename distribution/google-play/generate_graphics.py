"""Store artwork from the owner's existing logo and sanitized real captures.

Run from any directory. Pillow is required. No device access or remote uploads.
The native captures stay outside Git; pass their directory with --captures-dir.
"""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent / 'graphics'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--captures-dir', type=Path, required=True)
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    icon = ROOT / 'branding/deckos-icon-512.png'
    Image.open(icon).convert('RGB').save(OUT / 'icon-512.png', optimize=True)

    graphic = Image.new('RGB', (1024, 500))
    draw = ImageDraw.Draw(graphic)
    for y in range(500):
        for x in range(1024):
            glow = max(0, 1 - (((x - 840) / 700) ** 2 + ((y - 180) / 600) ** 2))
            graphic.putpixel((x, y), (int(12 + 7 * glow), int(15 + 15 * glow), int(23 + 25 * glow)))
    font = str(ROOT / 'app/assets/fonts/InterVariable.ttf')
    draw = ImageDraw.Draw(graphic)
    draw.text((56, 52), 'DeckOS', font=ImageFont.truetype(font, 32), fill='#8CB7FF')
    draw.text((56, 132), 'Your PC.', font=ImageFont.truetype(font, 58), fill='#F5F7FC')
    draw.text((56, 201), 'One touch away.', font=ImageFont.truetype(font, 52), fill='#F5F7FC')
    draw.text((58, 306), 'Custom buttons · Audio · AI usage', font=ImageFont.truetype(font, 23), fill='#BBC6D8')
    draw.text((58, 408), 'Requires the DeckOS PC companion', font=ImageFont.truetype(font, 20), fill='#BBC6D8')
    logo = Image.open(ROOT / 'branding/deckos-logo.png').convert('RGBA')
    logo.thumbnail((315, 315), Image.Resampling.LANCZOS)
    graphic.paste(logo, (676, 87), logo)
    graphic.save(OUT / 'feature-1024x500.png', optimize=True)

    captures = [
        (ROOT / 'website/docs/assets/screenshots/readme-phone-deck-landscape-dark.png',
         '01-custom-deck.png', 'Existing real project deck screenshot; deck-only mode and custom tiles.'),
        (args.captures_dir / 'controls-new-native.png',
         '02-ai-overview.png', 'Actual Android capture; account masking is enabled in the app.'),
        (args.captures_dir / 'reactive-masked-details-new-native.png',
         '03-ai-source-status.png', 'Actual Android capture; masked labels and genuine unavailable source states.'),
    ]
    provenance = []
    for source, name, note in captures:
        capture = Image.open(source).convert('RGB')
        width, height = capture.size
        # Preserve every content pixel. Play screenshot aspect ratios must not
        # exceed 2:1, so add plain margins rather than crop or change app data.
        width, height = max(width, (height + 1) // 2), max(height, (width + 1) // 2)
        color = '#000000' if name.startswith('01') else '#F1F1F7'
        canvas = Image.new('RGB', (width, height), color)
        canvas.paste(capture, ((width - capture.width) // 2, (height - capture.height) // 2))
        canvas.save(OUT / name, optimize=True)
        assert min(canvas.size) >= 320 and max(canvas.size) <= 3840
        assert max(canvas.size) <= min(canvas.size) * 2
        provenance.append(dict(file=name, source=source.name, sourceSha256=digest(source),
                               outputSha256=digest(OUT / name), sourceSize=capture.size,
                               outputSize=canvas.size, changes='Plain margins only; no UI text/data edits.', note=note))
    (OUT / 'provenance.json').write_text(json.dumps(dict(
        status='DRAFT_NOT_UPLOADED',
        iconSource='branding/deckos-icon-512.png', iconSourceSha256=digest(icon),
        featureGraphic='Original text composition using the supplied DeckOS logo; no new logo or generated photography.',
        screenshotCaptureNote='Captures predate candidate 10 release hardening; unchanged main deck/AI UI. No privacy/security screens are represented.',
        privacyReview='Visually reviewed: no personal names, emails, keys, QR codes or private host addresses. Current source states, not quota guarantees.',
        screenshots=provenance), indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
