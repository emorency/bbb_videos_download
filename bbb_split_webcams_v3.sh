#!/usr/bin/env bash
# PHASE 2b v3 — Détection webcam plus robuste (OpenCV),
# génère un webcams_plan de départ, puis délègue le découpage réel à
# bbb_split_webcams.sh via MANUAL_PLAN.
#
# Objectif: préremplir webcams_plan automatiquement avec une meilleure
# reconnaissance des transitions de grille et des caméras actives.
#
# Grilles supportées (format YAML = rangées x colonnes):
#   1x1, 1x2, 2x2, 2x3
#
# Sorties par présentation:
#   output/NN/webcams_plan.auto.txt   # plan manuel relisible par bbb_split_webcams.sh
#   output/NN/webcams_plan.auto.yaml  # snippet YAML à copier / comparer
#
# Variables d'environnement:
#   STEP=10             secondes entre échantillons
#   MIN_SEGMENT_SEC=8   durée mini avant fusion d'un segment isolé
#   APPLY=0             1 = injecte webcams_grid/webcams_plan dans presentations_cut.yaml
#   SPLIT=1             1 = lance bbb_split_webcams.sh avec le plan auto généré
#   VERBOSE=0           1 = logs supplémentaires
#   PYTHON=python3      interpréteur avec numpy + Pillow (+ OpenCV recommandé)
#   DETECTOR=opencv     opencv|classic|auto (defaut: opencv)
#   CV2_REQUIRED=0      1 = échoue si cv2 est indisponible
#   REVIEW=0            1 = revue interactive segment par segment
#   REVIEW_IMAGES=1     1 = extrait une image de référence par segment en review
#   REVIEW_MODE=all     all|changed|low|smart (smart = changed + low confidence)
#   REVIEW_CONFIDENCE=.62 seuil de confiance pour REVIEW_MODE=low|smart
#   REVIEW_LONG_SEGMENT_SEC=120 ignore certains longs segments stables en mode changed
#   REVIEW_STRICT=0      1 = échoue si review requise mais tty indisponible
#
# Usage:
#   ./bbb_split_webcams_v3.sh <dossier> NUM...
#   APPLY=1 ./bbb_split_webcams_v3.sh 2026-08-04 01

set -euo pipefail

[ $# -lt 2 ] && { echo "Usage: $0 <dossier> NUM..." >&2; exit 1; }

caller_pwd="$PWD"
rec_dir="$1"; shift
here="$(cd "$(dirname "$0")" && pwd)"

STEP="${STEP:-10}"
MIN_SEGMENT_SEC="${MIN_SEGMENT_SEC:-8}"
APPLY="${APPLY:-0}"
SPLIT="${SPLIT:-1}"
VERBOSE="${VERBOSE:-0}"
PYTHON="${PYTHON:-python3}"
DETECTOR="${DETECTOR:-opencv}"
CV2_REQUIRED="${CV2_REQUIRED:-0}"
REVIEW="${REVIEW:-0}"
REVIEW_IMAGES="${REVIEW_IMAGES:-1}"
REVIEW_MODE="${REVIEW_MODE:-all}"
REVIEW_CONFIDENCE="${REVIEW_CONFIDENCE:-0.62}"
REVIEW_LONG_SEGMENT_SEC="${REVIEW_LONG_SEGMENT_SEC:-120}"
REVIEW_STRICT="${REVIEW_STRICT:-0}"

log() { [ "$VERBOSE" = "1" ] && echo "$*"; }

if ! "$PYTHON" -c "import numpy, PIL" 2>/dev/null; then
    echo "Erreur : l'interpréteur '$PYTHON' n'a pas numpy et/ou Pillow (PIL)." >&2
    echo "  → installez-les : pip3 install numpy pillow" >&2
  exit 1
fi

if [ "$DETECTOR" = "opencv" ] || [ "$DETECTOR" = "auto" ]; then
    if ! "$PYTHON" -c "import cv2" 2>/dev/null; then
        if [ "$CV2_REQUIRED" = "1" ] || [ "$DETECTOR" = "opencv" ]; then
            echo "Erreur : OpenCV (cv2) est requis mais introuvable avec '$PYTHON'." >&2
            echo "  → installez-le : pip3 install opencv-python" >&2
            exit 1
        fi
        echo "Info : cv2 introuvable, fallback vers detecteur classic." >&2
        DETECTOR="classic"
    fi
fi

cd "$rec_dir"

[ -f presentations_cut.yaml ] || { echo "Erreur: presentations_cut.yaml introuvable dans $rec_dir" >&2; exit 1; }

sample_frames() {  # <input_webcam> <tmp_dir> <step> <duration>
  local in="$1" outdir="$2" step="$3" dur="$4"

  if awk -v s="$step" 'BEGIN{exit !(s>=60)}'; then
    local t=0 idx=1 total
    total=$(awk -v d="$dur" -v s="$step" 'BEGIN{print int(d/s)+1}')
    echo "  échantillonnage rapide: ~${total} image(s) (STEP=${step}s)"
    while awk -v t="$t" -v d="$dur" 'BEGIN{exit !(t<=d+1e-6)}'; do
      [ "$VERBOSE" = "1" ] && echo "    frame ${idx}/${total} @ ${t}s"
      ffmpeg -nostdin -v error -ss "$t" -i "$in" -frames:v 1 -vf "scale=960:-2" "$outdir/f$(printf '%05d' "$idx").png"
      idx=$((idx+1))
      t=$(awk -v a="$t" -v s="$step" 'BEGIN{printf "%.3f", a+s}')
    done
  else
    echo "  échantillonnage continu (STEP=${step}s) …"
    ffmpeg -nostdin -v error -i "$in" -vf "fps=1/${step},scale=960:-2" "$outdir/f%05d.png"
  fi
}

interactive_review_plan() {  # <input_webcam> <plan_txt> <meta_json> <nn>
    local webcam_file="$1" plan_file="$2" meta_file="$3" nn="$4"
    local review_dir="output/${nn}/webcams/review_plan"
    local revised idx accept_all raw start end grid active bbox extra action
    local should_review seg_conf seg_reason flag_line
    local -a review_flags
    local tty_available=0

    mkdir -p "$review_dir"
    revised="$(mktemp "${TMPDIR:-/tmp}/bbb_review_plan.${nn}.XXXXXX")"
    idx=0
    accept_all=0

    if [ -f "$meta_file" ]; then
        while IFS= read -r flag_line; do
            review_flags+=("$flag_line")
        done < <("$PYTHON" - "$meta_file" "$REVIEW_MODE" "$REVIEW_CONFIDENCE" "$REVIEW_LONG_SEGMENT_SEC" <<'PY'
import json
import sys

meta_path = sys.argv[1]
mode = (sys.argv[2] or 'all').strip().lower()
try:
    threshold = float(sys.argv[3])
except Exception:
    threshold = 0.62
try:
    long_seg_sec = float(sys.argv[4])
except Exception:
    long_seg_sec = 120.0

with open(meta_path, encoding='utf-8') as fh:
    meta = json.load(fh)

def parse_time(token):
    token = str(token).strip()
    parts = token.split(':')
    try:
        if len(parts) == 1:
            return float(parts[0])
        if len(parts) == 2:
            return float(parts[0]) * 60.0 + float(parts[1])
        if len(parts) == 3:
            return float(parts[0]) * 3600.0 + float(parts[1]) * 60.0 + float(parts[2])
    except Exception:
        return 0.0
    return 0.0

segments = meta.get('segments', [])
prev = None
for seg in segments:
    start = parse_time(seg.get('start', 0))
    end = parse_time(seg.get('end', start))
    dur = max(0.0, end - start)
    grid = str(seg.get('grid', ''))
    active = ','.join(str(v) for v in seg.get('active', []))
    bbox = str(seg.get('bbox', '') or '')
    conf = float(seg.get('confidence', 0.0))
    grid_changed = prev is None or (grid != prev[0])
    active_changed = prev is None or (active != prev[1])
    bbox_changed = prev is None or (bbox != prev[2])
    transition_window = dur <= 45.0
    changed = prev is None or grid_changed or (active_changed and transition_window) or (bbox_changed and transition_window)
    low = conf < threshold
    very_confident = conf >= (threshold + 0.08)
    long_stable = dur >= long_seg_sec

    if mode == 'all':
        flag = 1
    elif mode == 'changed':
        flag = 1 if changed else 0
        if flag == 1 and long_stable and very_confident and (not grid_changed):
            flag = 0
        if flag == 1 and prev is None and long_stable and very_confident:
            flag = 0
    elif mode == 'low':
        flag = 1 if low else 0
    elif mode == 'smart':
        flag = 1 if (changed or low) else 0
        if flag == 1 and long_stable and very_confident and (not grid_changed) and (not low):
            flag = 0
    else:
        flag = 1

    reasons = []
    if grid_changed:
        reasons.append('grid-change')
    elif active_changed:
        reasons.append('active-change')
    elif bbox_changed:
        reasons.append('bbox-change')
    if transition_window:
        reasons.append('short-seg')
    if low:
        reasons.append('low-confidence')
    reason = '+'.join(reasons) if reasons else 'stable'

    print(f"{flag} {conf:.3f} {reason}")
    prev = (grid, active, bbox)
PY
)
    fi

    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        exec 3<>/dev/tty
        tty_available=1
    fi

    echo "  review interactive activée (REVIEW=1, MODE=${REVIEW_MODE}, TH=${REVIEW_CONFIDENCE})"

    while IFS= read -r raw || [ -n "$raw" ]; do
        if [[ -z "${raw//[[:space:]]/}" ]] || [[ "$raw" =~ ^[[:space:]]*# ]]; then
            echo "$raw" >> "$revised"
            continue
        fi

        start=""; end=""; grid=""; active=""; bbox=""; extra=""
        read -r start end grid active bbox extra <<< "$raw"
        if [ -n "${extra:-}" ] || [ -z "$start" ] || [ -z "$end" ] || [ -z "$grid" ] || [ -z "$active" ]; then
            echo "$raw" >> "$revised"
            continue
        fi

        idx=$((idx + 1))

        should_review=1
        seg_conf="na"
        seg_reason="all"
        if [ "${#review_flags[@]}" -ge "$idx" ]; then
            flag_line="${review_flags[$((idx - 1))]}"
            should_review="${flag_line%% *}"
            flag_line="${flag_line#* }"
            seg_conf="${flag_line%% *}"
            seg_reason="${flag_line#* }"
        fi

        if [ "$REVIEW_IMAGES" = "1" ] && [ "$should_review" = "1" ]; then
            local frame_file="$review_dir/seg$(printf '%02d' "$idx")_${start//:/-}.jpg"
            ffmpeg -nostdin -v error -ss "$start" -i "$webcam_file" -frames:v 1 "$frame_file" || true
            echo "  [seg ${idx}] frame: $frame_file"
        fi

        if [ "$should_review" != "1" ]; then
            if [ "$VERBOSE" = "1" ]; then
                echo "  [seg ${idx}] auto-accept (${seg_reason}, conf=${seg_conf})"
            fi
        elif [ "$accept_all" != "1" ]; then
            if [ "$tty_available" != "1" ]; then
                if [ "$REVIEW_STRICT" = "1" ]; then
                    rm -f "$revised"
                    echo "  review impossible: /dev/tty indisponible (REVIEW_STRICT=1)" >&2
                    return 1
                fi
                echo "  [seg ${idx}] review auto-accept (tty indisponible)"
                should_review=0
            fi
        fi

        if [ "$should_review" = "1" ] && [ "$accept_all" != "1" ]; then
            echo "  [seg ${idx}] ${start} -> ${end} | grid=${grid} active=${active}${bbox:+ bbox=${bbox}} | conf=${seg_conf} (${seg_reason})"
            printf "    action [Enter=ok, e=edit, a=accept-all, q=quit] > "
            if ! IFS= read -r action <&3; then
                rm -f "$revised"
                echo "  review interrompue (tty indisponible)" >&2
                return 1
            fi

            case "$action" in
                ""|y|Y|ok|OK)
                    ;;
                a|A)
                    accept_all=1
                    ;;
                q|Q)
                    rm -f "$revised"
                    echo "  review annulée par utilisateur" >&2
                    return 1
                    ;;
                e|E)
                    printf "      grid [%s] > " "$grid"
                    IFS= read -r action <&3 || true
                    [ -n "${action:-}" ] && grid="$action"

                    printf "      active (ordre) [%s] > " "$active"
                    IFS= read -r action <&3 || true
                    [ -n "${action:-}" ] && active="$action"

                    if [ -n "${bbox:-}" ]; then
                        printf "      bbox x:y:w:h [%s] (mettre '-' pour retirer) > " "$bbox"
                    else
                        printf "      bbox x:y:w:h [none] (laisser vide pour none) > "
                    fi
                    IFS= read -r action <&3 || true
                    if [ -n "${action:-}" ]; then
                        if [ "$action" = "-" ]; then
                            bbox=""
                        else
                            bbox="$action"
                        fi
                    fi
                    ;;
                *)
                    echo "      action inconnue, segment conservé"
                    ;;
            esac
        fi

        if [ -n "${bbox:-}" ] && [ "$bbox" != "-" ]; then
            echo "$start $end $grid $active $bbox" >> "$revised"
        else
            echo "$start $end $grid $active" >> "$revised"
        fi
    done < "$plan_file"

    if [ "$tty_available" = "1" ]; then
        exec 3>&-
    fi

    mv "$revised" "$plan_file"
    echo "  plan revu et sauvegardé: $plan_file"
}

apply_plan_to_yaml() {  # <yaml> <num> <plan_txt>
  local yaml_path="$1" nn="$2" plan_txt="$3"

  "$PYTHON" - "$yaml_path" "$nn" "$plan_txt" <<'PY'
import re
import sys
from pathlib import Path

yaml_path = Path(sys.argv[1])
target = sys.argv[2]
plan_path = Path(sys.argv[3])

def dequote(value):
    value = value.strip()
    if len(value) >= 2 and ((value[0] == '"' and value[-1] == '"') or (value[0] == "'" and value[-1] == "'")):
        return value[1:-1]
    return value

plan_entries = []
dominant_grid = None
with plan_path.open(encoding='utf-8') as fh:
    for raw in fh:
        line = raw.split('#', 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        start, end, grid, active = parts[:4]
        bbox = parts[4] if len(parts) >= 5 else ''
        if dominant_grid is None:
            dominant_grid = grid
        plan_entries.append((start, end, grid, active, bbox))

if not plan_entries:
    raise SystemExit(f"Aucun segment détecté dans {plan_path}")

lines = yaml_path.read_text(encoding='utf-8').splitlines()

blocks = []
start = None
base_indent = None
for idx, line in enumerate(lines):
    m = re.match(r'^(\s*)-\s*num\s*:\s*(.+?)\s*$', line)
    if m:
        if start is not None:
            blocks.append((start, idx))
        start = idx
        base_indent = len(m.group(1))
if start is not None:
    blocks.append((start, len(lines)))

target_block = None
for a, b in blocks:
    m = re.match(r'^\s*-\s*num\s*:\s*(.+?)\s*$', lines[a])
    if m and dequote(m.group(1)) == target:
        target_block = (a, b)
        break

if target_block is None:
    raise SystemExit(f"Présentation {target} introuvable dans {yaml_path}")

a, b = target_block
item_indent = len(re.match(r'^(\s*)-\s*num\s*:', lines[a]).group(1))
prop_indent = ' ' * (item_indent + 2)
plan_indent = ' ' * (item_indent + 4)

new_block = []
insert_at = None
skip_mode = None
skip_indent = None
found_grid = False
found_plan = False

for idx in range(a, b):
    line = lines[idx]
    if idx == a:
        new_block.append(line)
        continue

    if skip_mode == 'plan':
        stripped = line.strip()
        current_indent = len(line) - len(line.lstrip(' '))
        if stripped and current_indent > skip_indent:
            continue
        skip_mode = None
        skip_indent = None

    if re.match(r'^\s*webcams_grid\s*:', line):
        if not found_grid:
            new_block.append(f'{prop_indent}webcams_grid: "{dominant_grid}"')
            found_grid = True
        continue

    if re.match(r'^\s*webcams_plan\s*:', line):
        found_plan = True
        if not found_grid:
            new_block.append(f'{prop_indent}webcams_grid: "{dominant_grid}"')
            found_grid = True
        new_block.append(f'{prop_indent}webcams_plan:')
        for start_v, end_v, grid_v, active_v, bbox_v in plan_entries:
            active_yaml = ', '.join(part.strip() for part in active_v.split(',') if part.strip())
            new_block.append(f'{plan_indent}- start: "{start_v}"')
            new_block.append(f'{plan_indent}  end: "{end_v}"')
            new_block.append(f'{plan_indent}  grid: "{grid_v}"')
            new_block.append(f'{plan_indent}  active: [{active_yaml}]')
            if bbox_v:
                new_block.append(f'{plan_indent}  bbox: "{bbox_v}"')
        skip_mode = 'plan'
        skip_indent = len(line) - len(line.lstrip(' '))
        continue

    if insert_at is None and re.match(r'^\s*webcams_priority\s*:', line):
        insert_at = len(new_block)

    new_block.append(line)

if not found_grid:
    pos = insert_at if insert_at is not None else len(new_block)
    new_block[pos:pos] = [f'{prop_indent}webcams_grid: "{dominant_grid}"']
    if insert_at is not None:
        insert_at += 1

if not found_plan:
    pos = insert_at if insert_at is not None else len(new_block)
    rendered = [f'{prop_indent}webcams_plan:']
    for start_v, end_v, grid_v, active_v, bbox_v in plan_entries:
        active_yaml = ', '.join(part.strip() for part in active_v.split(',') if part.strip())
        rendered.append(f'{plan_indent}- start: "{start_v}"')
        rendered.append(f'{plan_indent}  end: "{end_v}"')
        rendered.append(f'{plan_indent}  grid: "{grid_v}"')
        rendered.append(f'{plan_indent}  active: [{active_yaml}]')
        if bbox_v:
            rendered.append(f'{plan_indent}  bbox: "{bbox_v}"')
    new_block[pos:pos] = rendered

updated = lines[:a] + new_block + lines[b:]
yaml_path.write_text('\n'.join(updated) + '\n', encoding='utf-8')
PY
}

for nn in "$@"; do
  wc="output/${nn}/webcam.mp4"
  outdir="output/${nn}"
  plan_txt="$outdir/webcams_plan.auto.txt"
  plan_yaml="$outdir/webcams_plan.auto.yaml"
    plan_meta="$outdir/webcams_plan.auto.meta.json"

  if [ ! -f "$wc" ]; then
    echo "[${nn}] ${wc} introuvable — lancez d'abord bbb_make_clips.sh ${nn}" >&2
    continue
  fi

  mkdir -p "$outdir"

    meta="$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height:format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$wc" | paste -sd ' ' -)"
    read -r W H DUR <<< "$meta"

  if [ -z "${W:-}" ] || [ -z "${H:-}" ] || [ -z "${DUR:-}" ]; then
    echo "[${nn}] impossible de lire les métadonnées de ${wc}" >&2
    continue
  fi

  echo "[${nn}] analyse auto des webcams"
  echo "  source: ${wc}"
  echo "  clip  : ${W}x${H}, durée ${DUR}s"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/bbb_split_v2.${nn}.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN
  sample_frames "$wc" "$tmp" "$STEP" "$DUR"

    analysis="$($PYTHON - "$tmp" "$STEP" "$DUR" "$MIN_SEGMENT_SEC" "$plan_txt" "$plan_yaml" "$W" "$H" "$DETECTOR" "$CV2_REQUIRED" "$plan_meta" <<'PY'
import glob
import json
import sys
from collections import Counter

import numpy as np
from PIL import Image

detector_mode = sys.argv[9].strip().lower() if len(sys.argv) > 9 else 'opencv'
cv2_required = (sys.argv[10].strip() == '1') if len(sys.argv) > 10 else False
plan_meta = sys.argv[11] if len(sys.argv) > 11 else ''

cv2 = None
if detector_mode in ('opencv', 'auto'):
    try:
        import cv2 as _cv2
        cv2 = _cv2
    except Exception:
        cv2 = None
        if cv2_required or detector_mode == 'opencv':
            raise SystemExit("OpenCV (cv2) requis mais indisponible")

if detector_mode not in ('opencv', 'auto', 'classic'):
    detector_mode = 'opencv'

use_opencv = (cv2 is not None and detector_mode in ('opencv', 'auto'))

frames_dir = sys.argv[1]
step = float(sys.argv[2])
duration = float(sys.argv[3])
min_segment = float(sys.argv[4])
plan_txt = sys.argv[5]
plan_yaml = sys.argv[6]
orig_w = int(sys.argv[7])
orig_h = int(sys.argv[8])

files = sorted(glob.glob(f"{frames_dir}/f*.png"))
if not files:
    raise SystemExit("no frames sampled")

frames = [np.asarray(Image.open(path).convert("L"), dtype=np.uint8) for path in files]

WHITE_THRESHOLD = 245
ACTIVE_THRESHOLD = 0.065
RIM_RATIO = 0.06
CANDIDATES = [(1, 1), (1, 2), (2, 2), (2, 3)]

def normalize_bbox(x0, y0, x1, y1):
    q = 8
    x0 = int(max(0, (x0 // q) * q))
    y0 = int(max(0, (y0 // q) * q))
    x1 = int(max(x0 + q, ((x1 + q - 1) // q) * q))
    y1 = int(max(y0 + q, ((y1 + q - 1) // q) * q))
    return (x0, y0, x1, y1)

def preprocess_frame(gray):
    if use_opencv:
        blur = cv2.GaussianBlur(gray, (5, 5), 0)
        _, mask = cv2.threshold(blur, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
        kernel = np.ones((3, 3), dtype=np.uint8)
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel, iterations=1)
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=1)
        gx = cv2.Sobel(blur, cv2.CV_32F, 1, 0, ksize=3)
        gy = cv2.Sobel(blur, cv2.CV_32F, 0, 1, ksize=3)
        grad = np.abs(gx) + np.abs(gy)
    else:
        mask = (gray < WHITE_THRESHOLD).astype(np.uint8) * 255
        gx = np.abs(np.diff(gray.astype(np.float32), axis=1, prepend=gray[:, :1]))
        gy = np.abs(np.diff(gray.astype(np.float32), axis=0, prepend=gray[:1, :]))
        grad = gx + gy
    return mask, grad

def detect_content_bbox(mask):
    h, w = mask.shape
    dense = mask > 0
    row_density = dense.mean(axis=1)
    col_density = dense.mean(axis=0)
    rows = np.where(row_density > 0.03)[0]
    cols = np.where(col_density > 0.03)[0]
    if rows.size == 0 or cols.size == 0:
        return (0, 0, w, h)

    y0 = int(rows[0])
    y1 = int(rows[-1] + 1)
    x0 = int(cols[0])
    x1 = int(cols[-1] + 1)

    pad_y = max(2, int(0.01 * h))
    pad_x = max(2, int(0.01 * w))
    y0 = max(0, y0 - pad_y)
    y1 = min(h, y1 + pad_y)
    x0 = max(0, x0 - pad_x)
    x1 = min(w, x1 + pad_x)

    if (x1 - x0) < int(0.35 * w) or (y1 - y0) < int(0.25 * h):
        return (0, 0, w, h)
    return normalize_bbox(x0, y0, x1, y1)

def hms(sec):
    sec = max(0.0, float(sec))
    hours = int(sec // 3600)
    minutes = int((sec % 3600) // 60)
    seconds = sec - hours * 3600 - minutes * 60
    if abs(seconds - round(seconds)) < 1e-6:
        seconds = int(round(seconds))
        if hours > 0:
            return f"{hours}:{minutes:02d}:{seconds:02d}"
        return f"{minutes}:{seconds:02d}"
    if hours > 0:
        return f"{hours}:{minutes:02d}:{seconds:06.3f}".rstrip('0').rstrip('.')
    return f"{minutes}:{seconds:06.3f}".rstrip('0').rstrip('.')

def cell_bounds(height, width, rows, cols):
    ycuts = [int(round(i * height / rows)) for i in range(rows + 1)]
    xcuts = [int(round(i * width / cols)) for i in range(cols + 1)]
    out = []
    for row in range(rows):
        for col in range(cols):
            y0, y1 = ycuts[row], ycuts[row + 1]
            x0, x1 = xcuts[col], xcuts[col + 1]
            dy = max(1, int((y1 - y0) * RIM_RATIO))
            dx = max(1, int((x1 - x0) * RIM_RATIO))
            out.append((y0 + dy, y1 - dy, x0 + dx, x1 - dx))
    return out

def seam_strength(mask_bin, grad, rows, cols):
    height, width = mask_bin.shape
    content = (mask_bin > 0).astype(np.float32)
    seam_scores = []
    xcuts = [int(round(i * width / cols)) for i in range(cols + 1)]
    ycuts = [int(round(i * height / rows)) for i in range(rows + 1)]
    band = max(2, int(min(height, width) * 0.004))

    for x in xcuts[1:-1]:
        x0 = max(0, x - band)
        x1 = min(width, x + band)
        m = content[:, x0:x1]
        g = grad[:, x0:x1]
        if m.size == 0:
            continue
        white_score = 1.0 - float(m.mean())
        edge_score = min(1.0, float(g.mean()) / 42.0)
        seam_scores.append((0.85 * white_score) + (0.15 * edge_score))

    for y in ycuts[1:-1]:
        y0 = max(0, y - band)
        y1 = min(height, y + band)
        m = content[y0:y1, :]
        g = grad[y0:y1, :]
        if m.size == 0:
            continue
        white_score = 1.0 - float(m.mean())
        edge_score = min(1.0, float(g.mean()) / 42.0)
        seam_scores.append((0.85 * white_score) + (0.15 * edge_score))

    if not seam_scores:
        return 0.0

    # Exige de la cohérence sur toutes les séparations attendues.
    return (0.85 * min(seam_scores)) + (0.15 * float(np.mean(seam_scores)))

processed = []
for frame in frames:
    mask, grad = preprocess_frame(frame)
    processed.append((frame, mask, grad))

def evaluate_frame(bundle):
    frame, mask, grad = bundle
    full_h, full_w = frame.shape
    bx0, by0, bx1, by1 = detect_content_bbox(mask)
    subframe = frame[by0:by1, bx0:bx1]
    submask = mask[by0:by1, bx0:bx1]
    subgrad = grad[by0:by1, bx0:bx1]
    height, width = subframe.shape
    sx = float(orig_w) / float(full_w)
    sy = float(orig_h) / float(full_h)

    obx0 = int(round(bx0 * sx))
    oby0 = int(round(by0 * sy))
    obx1 = int(round(bx1 * sx))
    oby1 = int(round(by1 * sy))
    obx0, oby0, obx1, oby1 = normalize_bbox(obx0, oby0, obx1, oby1)
    obx0 = max(0, min(orig_w - 2, obx0))
    oby0 = max(0, min(orig_h - 2, oby0))
    obx1 = max(obx0 + 2, min(orig_w, obx1))
    oby1 = max(oby0 + 2, min(orig_h, oby1))

    best = None
    best_score = None
    candidate_scores = []
    for rows, cols in CANDIDATES:
        occupancies = []
        edge_strengths = []
        for y0, y1, x0, x1 in cell_bounds(height, width, rows, cols):
            cell_mask = submask[y0:y1, x0:x1]
            cell_grad = subgrad[y0:y1, x0:x1]
            if cell_mask.size == 0:
                occupancies.append(0.0)
                edge_strengths.append(0.0)
            else:
                occupancies.append(float((cell_mask > 0).mean()))
                edge_strengths.append(min(1.0, float(cell_grad.mean()) / 36.0))

        active = tuple(
            i + 1
            for i, (occ, edge) in enumerate(zip(occupancies, edge_strengths))
            if (occ >= ACTIVE_THRESHOLD and edge >= 0.04) or occ >= 0.12
        )
        if not active:
            fallback = np.asarray(occupancies) + (0.25 * np.asarray(edge_strengths))
            active = (int(np.argmax(fallback)) + 1,)

        occ = np.asarray(occupancies, dtype=float)
        edge = np.asarray(edge_strengths, dtype=float)
        purity = float(np.mean(np.abs(occ - 0.5)) * 2.0)
        active_mass = float(sum(occ[i - 1] for i in active))
        edge_active = float(sum(edge[i - 1] for i in active))
        leakage = float(sum(occ[i] for i in range(len(occ)) if (i + 1) not in active))
        boundary = seam_strength(submask, subgrad, rows, cols)
        model_penalty = {1: 0.0, 2: 0.35, 4: 1.1, 6: 2.3}.get(len(occ), 1.0)
        occ_std = float(np.std(occ))
        oversplit_penalty = max(0.0, 0.95 - (occ_std * 4.0)) * max(0, len(occ) - 4) * 0.9
        complexity_penalty = (0.2 * len(occ)) + model_penalty + oversplit_penalty
        score = (boundary * 4.2) + (purity * 0.9) + (active_mass * 1.2) + (edge_active * 0.45) - (leakage * 1.35) - complexity_penalty
        state = {
            'grid': f"{rows}x{cols}",
            'active': active,
            'score': score,
            'boundary': boundary,
            'bbox': (obx0, oby0, obx1, oby1),
            'full_shape': (orig_w, orig_h),
        }
        candidate_scores.append(score)
        if best is None or score > best_score:
            best = state
            best_score = score

    candidate_scores.sort(reverse=True)
    if len(candidate_scores) >= 2:
        margin = candidate_scores[0] - candidate_scores[1]
    else:
        margin = 1.0
    conf_margin = min(1.0, max(0.0, margin / 1.8))
    conf_boundary = min(1.0, max(0.0, best.get('boundary', 0.0)))
    confidence = 0.2 + (0.55 * conf_margin) + (0.25 * conf_boundary)
    if not use_opencv:
        confidence -= 0.06
    best['confidence'] = max(0.0, min(1.0, confidence))
    return best

states = [evaluate_frame(bundle) for bundle in processed]

def majority_smooth(items, radius=1):
    result = []
    keys = [(item['grid'], item['active'], item['bbox']) for item in items]
    for idx, item in enumerate(items):
        lo = max(0, idx - radius)
        hi = min(len(items), idx + radius + 1)
        counts = Counter(keys[lo:hi])
        best_key, _ = counts.most_common(1)[0]
        if best_key == keys[idx]:
            result.append(item)
        else:
            repl = dict(item)
            repl['grid'], repl['active'], repl['bbox'] = best_key
            result.append(repl)
    return result

states = majority_smooth(states, radius=1)

segments = []
for idx, state in enumerate(states):
    start = idx * step
    end = min(duration, (idx + 1) * step)
    if not segments or segments[-1]['grid'] != state['grid'] or segments[-1]['active'] != state['active'] or segments[-1]['bbox'] != state['bbox']:
        segments.append({
            'start': start,
            'end': end,
            'grid': state['grid'],
            'active': state['active'],
            'bbox': state['bbox'],
            'full_shape': state['full_shape'],
            'confidence_sum': float(state.get('confidence', 0.5)),
            'confidence_count': 1,
            'confidence_min': float(state.get('confidence', 0.5)),
        })
    else:
        segments[-1]['end'] = end
        segments[-1]['confidence_sum'] += float(state.get('confidence', 0.5))
        segments[-1]['confidence_count'] += 1
        segments[-1]['confidence_min'] = min(segments[-1]['confidence_min'], float(state.get('confidence', 0.5)))

def merge_conf(dst, src):
    dst['confidence_sum'] = float(dst.get('confidence_sum', 0.0)) + float(src.get('confidence_sum', 0.0))
    dst['confidence_count'] = int(dst.get('confidence_count', 0)) + int(src.get('confidence_count', 0))
    dst['confidence_min'] = min(float(dst.get('confidence_min', 1.0)), float(src.get('confidence_min', 1.0)))

def merge_short_segments(items, min_len):
    items = [dict(item) for item in items]
    changed = True
    while changed and len(items) > 1:
        changed = False
        for idx, item in enumerate(list(items)):
            dur = item['end'] - item['start']
            if dur + 1e-6 >= min_len:
                continue
            if idx == 0:
                merge_conf(items[1], item)
                items[1]['start'] = item['start']
                del items[0]
            elif idx == len(items) - 1:
                merge_conf(items[-2], item)
                items[-2]['end'] = item['end']
                del items[-1]
            else:
                left = items[idx - 1]['end'] - items[idx - 1]['start']
                right = items[idx + 1]['end'] - items[idx + 1]['start']
                if left >= right:
                    merge_conf(items[idx - 1], item)
                    items[idx - 1]['end'] = item['end']
                    del items[idx]
                else:
                    merge_conf(items[idx + 1], item)
                    items[idx + 1]['start'] = item['start']
                    del items[idx]
            changed = True
            break
    merged = []
    for item in items:
        if merged and merged[-1]['grid'] == item['grid'] and merged[-1]['active'] == item['active'] and merged[-1]['bbox'] == item['bbox']:
            merge_conf(merged[-1], item)
            merged[-1]['end'] = item['end']
        else:
            merged.append(item)
    return merged

def collapse_flapping(items, flap_len):
    out = [dict(item) for item in items]
    changed = True
    while changed and len(out) > 2:
        changed = False
        for idx in range(1, len(out) - 1):
            cur = out[idx]
            prev_seg = out[idx - 1]
            next_seg = out[idx + 1]
            dur = cur['end'] - cur['start']
            if dur > flap_len:
                continue
            if prev_seg['grid'] != next_seg['grid']:
                continue
            if cur['grid'] == prev_seg['grid']:
                continue
            if prev_seg['active'] != next_seg['active']:
                continue
            if prev_seg['bbox'] != next_seg['bbox']:
                continue
            merge_conf(prev_seg, cur)
            merge_conf(prev_seg, next_seg)
            prev_seg['end'] = next_seg['end']
            del out[idx + 1]
            del out[idx]
            changed = True
            break
    return out

def fill_singleton_active(items):
    out = [dict(item) for item in items]
    if len(out) < 3:
        return out
    for idx in range(1, len(out) - 1):
        cur = out[idx]
        prev_seg = out[idx - 1]
        next_seg = out[idx + 1]
        if cur['grid'] != prev_seg['grid'] or cur['grid'] != next_seg['grid']:
            continue
        if prev_seg['active'] != next_seg['active']:
            continue
        if (cur['end'] - cur['start']) > (min_segment * 1.25):
            continue
        cur['active'] = prev_seg['active']
    return out

segments = fill_singleton_active(segments)
segments = merge_short_segments(segments, min_segment)
segments = collapse_flapping(segments, max(min_segment * 4.0, step * 3.0))
segments[-1]['end'] = duration

grid_durations = Counter()
for seg in segments:
    grid_durations[seg['grid']] += seg['end'] - seg['start']
dominant_grid = grid_durations.most_common(1)[0][0]

def downgraded_from_2x3(seg):
    bx0, by0, bx1, by1 = seg['bbox']
    bw = max(1, bx1 - bx0)
    bh = max(1, by1 - by0)
    aspect = float(bw) / float(bh)
    # Une bbox très panoramique correspond en pratique à un layout 1x2.
    if aspect >= 2.35:
        grid = '1x2'
        active = (1, 2)
    else:
        grid = '2x2'
        if len(seg['active']) <= 2:
            active = (1, 2)
        elif len(seg['active']) == 3:
            active = (1, 2, 3)
        else:
            active = (1, 2, 3, 4)
    repl = dict(seg)
    repl['grid'] = grid
    repl['active'] = active
    repl['confidence_sum'] = float(repl.get('confidence_sum', 0.0)) * 0.9
    repl['confidence_min'] = min(float(repl.get('confidence_min', 1.0)), 0.52)
    return repl

# Démotion géométrique forte: un segment 2x3 dans une bbox très panoramique
# est quasi toujours un faux positif (souvent une vraie grille 1x2).
segments = [downgraded_from_2x3(seg) if (seg['grid'] == '2x3' and (float(max(1, seg['bbox'][2]-seg['bbox'][0])) / float(max(1, seg['bbox'][3]-seg['bbox'][1])) >= 2.35)) else seg for seg in segments]
segments = merge_short_segments(segments, min_segment)
segments = collapse_flapping(segments, max(min_segment * 4.0, step * 3.0))
segments[-1]['end'] = duration

grid_durations = Counter()
for seg in segments:
    grid_durations[seg['grid']] += seg['end'] - seg['start']
dominant_grid = grid_durations.most_common(1)[0][0]

if dominant_grid != '2x3':
    two_by_three_total = grid_durations.get('2x3', 0.0)
    demote_limit = max(120.0, duration * 0.12)
    if 0.0 < two_by_three_total <= demote_limit:
        segments = [downgraded_from_2x3(seg) if seg['grid'] == '2x3' else seg for seg in segments]
        segments = merge_short_segments(segments, min_segment)
        segments = collapse_flapping(segments, max(min_segment * 4.0, step * 3.0))
        segments[-1]['end'] = duration

def grid_size(grid_name):
    rows_s, cols_s = grid_name.split('x', 1)
    rows = int(rows_s)
    cols = int(cols_s)
    return rows * cols

# Cas fréquent avec corruption en tête de flux: un court segment initial est
# détecté en 1x2 alors que la grille dominante est 2x2. On promeut ce premier
# segment vers la grille dominante pour éviter un mauvais seg0000.
if segments and segments[0]['grid'] == '1x2' and dominant_grid in ('2x2', '2x3'):
    first_len = segments[0]['end'] - segments[0]['start']
    promote_limit = max(180.0, min_segment * 6.0)
    has_stable_followup = False
    if len(segments) >= 2:
        full_active = tuple(range(1, grid_size(dominant_grid) + 1))
        has_stable_followup = (
            segments[1]['grid'] == dominant_grid
            and tuple(segments[1]['active']) == full_active
        )
    if first_len <= promote_limit and has_stable_followup:
        segments[0]['grid'] = dominant_grid
        segments[0]['active'] = tuple(range(1, grid_size(dominant_grid) + 1))
        segments = merge_short_segments(segments, 0.0)

grid_durations = Counter()
for seg in segments:
    grid_durations[seg['grid']] += seg['end'] - seg['start']
dominant_grid = grid_durations.most_common(1)[0][0]

with open(plan_txt, 'w', encoding='utf-8') as txt:
    txt.write('# auto-generated by bbb_split_webcams_v3.sh\n')
    txt.write('# start end grid active [bbox]\n')
    for seg in segments:
        active = ','.join(str(v) for v in seg['active'])
        fw, fh = seg['full_shape']
        bx0, by0, bx1, by1 = seg['bbox']
        bw = max(2, int(bx1 - bx0))
        bh = max(2, int(by1 - by0))
        bbox = f"{bx0}:{by0}:{bw}:{bh}"
        if bx0 == 0 and by0 == 0 and bw == fw and bh == fh:
            txt.write(f"{hms(seg['start'])} {hms(seg['end'])} {seg['grid']} {active}\n")
        else:
            txt.write(f"{hms(seg['start'])} {hms(seg['end'])} {seg['grid']} {active} {bbox}\n")

with open(plan_yaml, 'w', encoding='utf-8') as yml:
    yml.write(f'webcams_grid: "{dominant_grid}"\n')
    yml.write('webcams_plan:\n')
    for seg in segments:
        active = ', '.join(str(v) for v in seg['active'])
        yml.write(f'  - start: "{hms(seg["start"])}"\n')
        yml.write(f'    end: "{hms(seg["end"])}"\n')
        yml.write(f'    grid: "{seg["grid"]}"\n')
        yml.write(f'    active: [{active}]\n')
        fw, fh = seg['full_shape']
        bx0, by0, bx1, by1 = seg['bbox']
        bw = max(2, int(bx1 - bx0))
        bh = max(2, int(by1 - by0))
        if not (bx0 == 0 and by0 == 0 and bw == fw and bh == fh):
            yml.write(f'    bbox: "{bx0}:{by0}:{bw}:{bh}"\n')

for seg in segments:
    count = max(1, int(seg.get('confidence_count', 1)))
    conf_mean = float(seg.get('confidence_sum', 0.5)) / float(count)
    conf_min = float(seg.get('confidence_min', conf_mean))
    # On privilégie la borne basse pour cibler les segments à vérifier.
    seg['confidence'] = max(0.0, min(1.0, min(conf_mean, conf_min + 0.12)))

if plan_meta:
    with open(plan_meta, 'w', encoding='utf-8') as meta:
        json.dump({
            'detector': detector_mode,
            'opencv_used': bool(use_opencv),
            'dominant_grid': dominant_grid,
            'segments': [
                {
                    'start': hms(seg['start']),
                    'end': hms(seg['end']),
                    'grid': seg['grid'],
                    'active': list(seg['active']),
                    'bbox': f"{seg['bbox'][0]}:{seg['bbox'][1]}:{max(2, int(seg['bbox'][2]-seg['bbox'][0]))}:{max(2, int(seg['bbox'][3]-seg['bbox'][1]))}",
                    'confidence': round(float(seg.get('confidence', 0.5)), 3),
                }
                for seg in segments
            ],
        }, meta, ensure_ascii=False, indent=2)

print(json.dumps({
    'dominant_grid': dominant_grid,
    'segments': [
        {
            'start': hms(seg['start']),
            'end': hms(seg['end']),
            'grid': seg['grid'],
            'active': list(seg['active']),
            'confidence': round(float(seg.get('confidence', 0.5)), 3),
        }
        for seg in segments
    ]
}))
PY
)"

  rm -rf "$tmp"
  trap - RETURN

  dominant_grid="$($PYTHON -c 'import json,sys; print(json.loads(sys.stdin.read())["dominant_grid"])' <<< "$analysis")"
  seg_count="$($PYTHON -c 'import json,sys; print(len(json.loads(sys.stdin.read())["segments"]))' <<< "$analysis")"

  echo "  grille dominante: ${dominant_grid}"
  echo "  segments détectés: ${seg_count}"
  echo "  plan texte : ${plan_txt}"
  echo "  plan YAML  : ${plan_yaml}"
    echo "  plan meta  : ${plan_meta}"

    if [ "$REVIEW" = "1" ]; then
        if ! interactive_review_plan "$wc" "$plan_txt" "$plan_meta" "$nn"; then
            echo "  review non validée: split ignoré pour ${nn}" >&2
            continue
        fi
    fi

  if [ "$APPLY" = "1" ]; then
    apply_plan_to_yaml "presentations_cut.yaml" "$nn" "$plan_txt"
    echo "  YAML mis à jour: presentations_cut.yaml (${nn})"
  fi

  if [ "$SPLIT" = "1" ]; then
    MANUAL_PLAN="$plan_txt" "$here/bbb_split_webcams.sh" "$PWD" "$nn"
  fi
done