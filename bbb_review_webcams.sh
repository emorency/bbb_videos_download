#!/usr/bin/env bash
# Génère des artefacts de review pour les splits webcam d'une présentation:
# - output/NN/webcams/review/contact-sheet.jpg
# - output/NN/webcams/review/webcams-review.mp4
#
# Usage:
#   ./bbb_review_webcams.sh <dossier> <NUM>
#   ./bbb_review_webcams.sh 2026-08-04 01

set -euo pipefail

[ $# -ne 2 ] && { echo "Usage: $0 <dossier> <NUM>" >&2; exit 1; }

dossier="$1"
num="$2"
base="$dossier/output/$num/webcams"
review="$base/review"
raw="$review/raw"
frames="$review/frames"

[ -d "$base" ] || { echo "Erreur: dossier introuvable: $base" >&2; exit 1; }

shopt -s nullglob
clips=("$base"/seg*_cam*.mp4)
shopt -u nullglob
[ ${#clips[@]} -gt 0 ] || { echo "Erreur: aucun clip webcam split dans $base" >&2; exit 1; }

rm -rf "$raw" "$frames"
mkdir -p "$raw" "$frames"

for f in "${clips[@]}"; do
  bn="$(basename "$f" .mp4)"
  ffmpeg -nostdin -v error -ss 1 -i "$f" -frames:v 1 -y "$raw/${bn}.jpg" || \
  ffmpeg -nostdin -v error -ss 0 -i "$f" -frames:v 1 -y "$raw/${bn}.jpg"
done

python3 - "$raw" "$frames" "$review/contact-sheet.jpg" "$dossier/$num" <<'PY'
from PIL import Image, ImageOps, ImageDraw
from pathlib import Path
import math
import sys

raw = Path(sys.argv[1])
frames = Path(sys.argv[2])
out_sheet = Path(sys.argv[3])
title_suffix = sys.argv[4]

imgs = sorted(raw.glob('seg*_cam*.jpg'))
if not imgs:
    raise SystemExit('No thumbnails found')

thumb_w, thumb_h = 320, 180
label_h = 26
card_h = thumb_h + label_h
pad = 12
bg = (22, 24, 28)
fg = (240, 240, 240)
accent = (66, 133, 244)

cards = []
for i, p in enumerate(imgs, start=1):
    im = Image.open(p).convert('RGB')
    fit = ImageOps.pad(im, (thumb_w, thumb_h), method=Image.Resampling.LANCZOS, color=(0, 0, 0))
    card = Image.new('RGB', (thumb_w, card_h), color=bg)
    card.paste(fit, (0, 0))
    d = ImageDraw.Draw(card)
    d.rectangle((0, thumb_h, thumb_w, card_h), fill=(33, 36, 42))
    d.text((8, thumb_h + 6), p.stem, fill=fg)
    d.rectangle((0, 0, thumb_w - 1, card_h - 1), outline=accent, width=1)
    out = frames / f'{i:03d}.jpg'
    card.save(out, quality=92)
    cards.append(card)

n = len(cards)
cols = min(6, max(3, int(math.ceil(math.sqrt(n)))))
rows = int(math.ceil(n / cols))
sheet_w = cols * thumb_w + (cols + 1) * pad
sheet_h = rows * card_h + (rows + 1) * pad + 46
sheet = Image.new('RGB', (sheet_w, sheet_h), color=(16, 18, 22))
d = ImageDraw.Draw(sheet)
d.text((pad, 12), f'Webcam split review - {title_suffix} ({n} clips)', fill=(245, 245, 245))

for idx, card in enumerate(cards):
    r = idx // cols
    c = idx % cols
    x = pad + c * (thumb_w + pad)
    y = 46 + pad + r * (card_h + pad)
    sheet.paste(card, (x, y))

sheet.save(out_sheet, quality=92)
print(n)
PY

ffmpeg -nostdin -v error -y -framerate 2 -i "$frames/%03d.jpg" \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$review/webcams-review.mp4"

count="$(ls -1 "$base"/seg*_cam*.mp4 | wc -l | tr -d ' ')"
echo "✓ Review webcams générée: $review"
echo "  - clips: $count"
echo "  - image: $review/contact-sheet.jpg"
echo "  - vidéo: $review/webcams-review.mp4"
