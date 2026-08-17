#!/usr/bin/env bash
# PHASE 2b (optionnel) — Sépare le clip webcam d'une présentation en flux caméra
# isolés, par détection d'image (BBB ne publie aucune métadonnée de webcams).
#
# Travaille sur output/NN/webcam.mp4 (déjà produit par bbb_make_clips.sh) : on
# n'analyse que les présentations demandées, pas toute la session.
#
# Méthode : échantillonne le clip, détecte les vraies tuiles webcam BBB (vidéos
# pleines de tailles/proportions variées sur fond blanc, parfois accolées) par
# découpe récursive — gouttières blanches puis sauts de couverture — sans supposer
# de grille régulière. Segmente en plages de disposition stable, puis recadre
# chaque tuile au plus juste (les bandes blanches de pillarbox sont retirées).
#
# Sortie : output/NN/webcams/segSSSs_camK-of-N.mp4  (+ manifest.txt)
# En analyse auto, les segments à 1 seule caméra ne sont pas découpés
# (utiliser webcam.mp4). En mode manuel, une seule cellule active est extraite.
#
# Prérequis : ffmpeg, python3 avec numpy et Pillow (pip3 install numpy pillow).
# Usage : bbb_split_webcams.sh <dossier> NUM...
#   ex : bbb_split_webcams.sh 2026-07-07 04 05
#
# Modes manuels (bypass analyse):
#   FORCE_GRID=2x2 FORCE_ACTIVE=1,2,3 ./bbb_split_webcams.sh <dossier> <NUM>
#   MANUAL_PLAN=webcams_plan.txt ./bbb_split_webcams.sh <dossier> <NUM>
#
# Override YAML optionnel par présentation:
#   webcams_grid: RxC (ex: 2x3 = 2 rangées, 3 colonnes)
#   webcams_grid: N (raccourci: 1->1x1, 2->1x2, 3->1x3, 4->2x2, 6->2x3)
#   webcams_plan:
#     - start: "0:00"
#       end: "10:00"
#       grid: "2x3"
#       active: [1, 2, 3, 4, 5]
#     - start: "10:00"
#       end: "end"
#       grid: "2x2"
#       active: [1, 2, 3]
#
# Format MANUAL_PLAN (temps en secondes, MM:SS, HH:MM:SS, ou "end"):
#   # start end grid active [bbox]
#   0:00  3:20  2x2  1,2,3
#   3:20  end   3x2  1,3,4,5  0:0:1920:1080
#
# active: indices de cellules ligne par ligne, 1..(cols*rows), ou "-" / "all".
# bbox: x:y:w:h de la zone grille, optionnel (défaut: image entière).

set -euo pipefail

[ $# -lt 2 ] && { echo "Usage: $0 <dossier> NUM..." >&2; exit 1; }
caller_pwd="$PWD"
rec_dir="$1"; shift
cd "$rec_dir"

STEP="${STEP:-4}"   # secondes entre images échantillonnées (env STEP=... pour changer)
VERBOSE="${VERBOSE:-0}"
DRY_RUN="${DRY_RUN:-0}"
FORCE_GRID="${FORCE_GRID:-}"
FORCE_ACTIVE="${FORCE_ACTIVE:-}"
FORCE_BBOX="${FORCE_BBOX:-}"
MANUAL_PLAN="${MANUAL_PLAN:-}"
MANUAL_SEGMENTS="${MANUAL_SEGMENTS:-}"
VENC="${BBB_VENC:-${VIDEO_CODEC:-h264_videotoolbox}}"
STRICT_HW="${BBB_STRICT_HW:-0}"
PARTIAL_SPLIT="${PARTIAL_SPLIT:-0}"
VIDEO_BITRATE="${VIDEO_BITRATE:-8M}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"

# Interpréteur Python : doit avoir numpy et Pillow. Le python3 par défaut du PATH
# peut être un pyenv/venv qui ne les a pas ; PYTHON=... impose un autre.
PYTHON="${PYTHON:-python3}"
if ! "$PYTHON" -c "import numpy, PIL" 2>/dev/null; then
  echo "Erreur : l'interpréteur '$PYTHON' n'a pas numpy et/ou Pillow (PIL)." >&2
  echo "  → installez-les : pip3 install numpy pillow" >&2
  echo "  → ou pointez PYTHON vers un interpréteur qui les a :" >&2
  for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 \
           /Library/Frameworks/Python.framework/Versions/*/bin/python3; do
    [ -x "$c" ] && "$c" -c "import numpy, PIL" 2>/dev/null \
      && { echo "      relancez avec :  PYTHON=$c $0 ..." >&2; break; }
  done
  exit 1
fi

log() { [ "$VERBOSE" = "1" ] && echo "$*"; }

append_video_codec_args() {  # <codec> appends ffmpeg args to global cmd array
    local codec="$1"

    case "$codec" in
        h264_videotoolbox)
            cmd+=(-c:v h264_videotoolbox -b:v "$VIDEO_BITRATE" -pix_fmt yuv420p -r 30 -profile:v high -prio_speed 1)
            ;;
        libx264)
            cmd+=(-c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -r 30)
            ;;
        *)
            cmd+=(-c:v "$codec" -b:v "$VIDEO_BITRATE")
            ;;
    esac
}

build_segment_cmd() {  # <codec> <start> <dur> <input> <cams_tmp> <outdir>
    local codec="$1" start="$2" dur="$3" input="$4" cams_file="$5" outdir="$6"
    local fc="" idx=0 out kcam K grid x y w h _s _e _K _grid

    cmd=(ffmpeg -y -nostdin -v error -ss "$start" -i "$input")
    while read -r _s _e x y w h kcam _K _grid; do
        idx=$((idx+1))
        fc+="[0:v]crop=${w}:${h}:${x}:${y}[v${idx}];"
    done < "$cams_file"
    fc="${fc%;}"
    cmd+=(-filter_complex "$fc")

    idx=0
    while read -r _s _e x y w h kcam K grid; do
        idx=$((idx+1))
        out="$outdir/seg$(printf '%04d' "${start%.*}")s_cam${kcam}-of-${K}.mp4"
        cmd+=(-map "[v${idx}]" -map 0:a? -t "$dur")
        append_video_codec_args "$codec"
        cmd+=(-c:a aac -b:a "$AUDIO_BITRATE" -movflags +faststart "$out")
    done < "$cams_file"
}

even_dim() {
    local v="$1"
    v=$((v - (v % 2)))
    [ "$v" -lt 2 ] && v=2
    echo "$v"
}

even_coord() {
    local v="$1"
    v=$((v - (v % 2)))
    [ "$v" -lt 0 ] && v=0
    echo "$v"
}

time_to_seconds() {  # <time> <duration>
    awk -v t="$1" -v dur="$2" '
    BEGIN {
        if (tolower(t) == "end") { printf "%.3f", dur; exit }
        n = split(t, a, ":")
        if (n == 1) s = t + 0
        else if (n == 2) s = (a[1] * 60) + a[2]
        else if (n == 3) s = (a[1] * 3600) + (a[2] * 60) + a[3]
        else exit 2
        if (s < 0) exit 3
        printf "%.3f", s
    }'
}

validate_grid() {  # <grid>
    local grid="$1" rows cols
    rows="${grid%x*}"
    cols="${grid#*x}"
    [[ "$rows" =~ ^[0-9]+$ && "$cols" =~ ^[0-9]+$ && "$rows" -ge 1 && "$cols" -ge 1 ]]
}

normalize_grid() {  # <token> -> RxC
    local token="$1"
    token="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')"
    token="${token//\*/x}"
    token="${token// /}"

    if [[ "$token" =~ ^[0-9]+$ ]]; then
        case "$token" in
            1) echo "1x1" ;;
            2) echo "1x2" ;;
            3) echo "1x3" ;;
            4) echo "2x2" ;;
            6) echo "2x3" ;;
            *) return 1 ;;
        esac
        return 0
    fi

    if validate_grid "$token"; then
        echo "$token"
        return 0
    fi

    return 1
}

resolve_manual_plan() {  # <requested_path> <nn>
    local requested="$1" nn="$2"

    if [ -f "$requested" ]; then
        printf '%s\n' "$requested"
        return 0
    fi

    case "$requested" in
        /*) return 1 ;;
    esac

    if [ -f "$caller_pwd/$requested" ]; then
        printf '%s\n' "$caller_pwd/$requested"
        return 0
    fi

    if [ -f "output/${nn}/${requested}" ]; then
        printf '%s\n' "output/${nn}/${requested}"
        return 0
    fi

    return 1
}

yaml_webcams_grid() {  # <nn> -> RxC|vide
    local nn="$1"
    python3 - "$nn" <<'PY'
import re, sys

target = sys.argv[1]
current = None
capture = False

def strip_comment(value):
    out = []
    quote = None
    prev_space = True
    for ch in value:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
            prev_space = False
        elif ch in ('"', "'"):
            quote = ch
            out.append(ch)
            prev_space = False
        elif ch == '#' and prev_space:
            break
        else:
            out.append(ch)
            prev_space = ch.isspace()
    return ''.join(out).strip()

with open('presentations_cut.yaml', encoding='utf-8') as fh:
    for raw in fh:
        line = raw.rstrip('\n')
        m = re.match(r'^\s*-\s*num\s*:\s*(.+?)\s*$', line)
        if m:
            value = strip_comment(m.group(1))
            if len(value) >= 2 and ((value[0] == '"' and value[-1] == '"') or (value[0] == "'" and value[-1] == "'")):
                value = value[1:-1]
            current = value
            capture = current == target
            continue
        if not capture:
            continue
        if re.match(r'^\s*-\s*num\s*:', line):
            break
        m = re.match(r'^\s*webcams_grid\s*:\s*(.*?)\s*$', line)
        if m:
            value = strip_comment(m.group(1))
            if len(value) >= 2 and ((value[0] == '"' and value[-1] == '"') or (value[0] == "'" and value[-1] == "'")):
                value = value[1:-1]
            if value and value not in ('""', "''"):
                print(value)
            break
PY
}

yaml_webcams_plan() {  # <nn> -> plan segments string or empty
    local nn="$1"
    python3 - "$nn" <<'PY'
import re, sys

target = sys.argv[1]
capture = False
in_plan = False
plan_indent = None
scalar_plan = None
items = []
current = None
presentation_start = ''

def strip_comment(value):
    out = []
    quote = None
    prev_space = True
    for ch in value:
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
            prev_space = False
        elif ch in ('"', "'"):
            quote = ch
            out.append(ch)
            prev_space = False
        elif ch == '#' and prev_space:
            break
        else:
            out.append(ch)
            prev_space = ch.isspace()
    return ''.join(out).strip()

def dequote(value):
    value = value.strip()
    if len(value) >= 2 and ((value[0] == '"' and value[-1] == '"') or (value[0] == "'" and value[-1] == "'")):
        return value[1:-1]
    return value

def parse_active(value):
    value = dequote(strip_comment(value))
    if not value or value in ('-', 'all'):
        return 'all'
    if value.startswith('[') and value.endswith(']'):
        inside = value[1:-1].strip()
        if not inside:
            return 'all'
        parts = [p.strip() for p in inside.split(',') if p.strip()]
        return ','.join(parts) if parts else 'all'
    return value

def parse_end(value):
    value = dequote(strip_comment(value)).strip()
    if value in ('', '-', 'null', 'NULL', '~'):
        return ''
    return value

def parse_time_token(value):
    value = dequote(strip_comment(value)).strip()
    if not value:
        return None
    if value.lower() == 'end':
        return 'end'
    parts = value.split(':')
    try:
        if len(parts) == 1:
            return float(parts[0])
        if len(parts) == 2:
            return float(parts[0]) * 60.0 + float(parts[1])
        if len(parts) == 3:
            return float(parts[0]) * 3600.0 + float(parts[1]) * 60.0 + float(parts[2])
    except ValueError:
        return None
    return None

def fmt_seconds(value):
    value = max(0.0, float(value))
    return f"{value:.3f}".rstrip('0').rstrip('.')

def normalize_plan_time(value, base_seconds):
    token = dequote(strip_comment(value)).strip()
    if not token:
        return ''
    if token.lower() == 'end':
        return 'end'
    seconds = parse_time_token(token)
    if seconds is None:
        return token
    if base_seconds is not None and seconds >= base_seconds:
        return fmt_seconds(seconds - base_seconds)
    # Compatibilité: si l'horodatage est déjà relatif (plus petit que start), on le garde.
    return fmt_seconds(seconds)

def flush_item():
    global current
    if not current:
        return
    start = dequote(str(current.get('start', '')).strip())
    end = parse_end(str(current.get('end', '')))
    grid = dequote(str(current.get('grid', '')).strip())
    if not grid:
        # Alias de compatibilité: webcam_grid -> grid.
        grid = dequote(str(current.get('webcam_grid', '')).strip())
    if not start or not grid:
        return
    active = current.get('active', 'all')
    if isinstance(active, list):
        active = ','.join(str(x).strip() for x in active if str(x).strip())
        active = active or 'all'
    else:
        active = parse_active(str(active))
    bbox = dequote(str(current.get('bbox', '')).strip())
    items.append({
        'start': start,
        'end': end,
        'grid': grid,
        'active': active,
        'bbox': bbox,
    })
    current = None

with open('presentations_cut.yaml', encoding='utf-8') as fh:
    for raw in fh:
        line = raw.rstrip('\n')
        m = re.match(r'^\s*-\s*num\s*:\s*(.+?)\s*$', line)
        if m:
            if capture and in_plan:
                flush_item()
                break
            value = strip_comment(m.group(1))
            value = dequote(value)
            capture = value == target
            in_plan = False
            plan_indent = None
            scalar_plan = None
            items = []
            current = None
            presentation_start = ''
            continue
        if not capture:
            continue
        if re.match(r'^\s*-\s*num\s*:', line):
            break

        m = re.match(r'^\s*start\s*:\s*(.*?)\s*$', line)
        if m and not in_plan:
            presentation_start = dequote(strip_comment(m.group(1)))
            continue

        if in_plan:
            indent = len(line) - len(line.lstrip(' '))
            stripped = line.strip()
            if not stripped:
                continue
            if indent <= plan_indent:
                flush_item()
                break
            if stripped.startswith('#'):
                continue

            content = line[indent:]
            if content.startswith('- '):
                flush_item()
                current = {}
                rest = content[2:].strip()
                if rest and ':' in rest:
                    k, v = rest.split(':', 1)
                    key = k.strip()
                    value = v.strip()
                    current[key] = parse_active(value) if key == 'active' else dequote(strip_comment(value))
                continue

            if current is not None and ':' in content:
                k, v = content.split(':', 1)
                key = k.strip()
                value = v.strip()
                current[key] = parse_active(value) if key == 'active' else dequote(strip_comment(value))
            continue

        m = re.match(r'^(\s*)webcams_plan\s*:\s*(.*?)\s*$', line)
        if m:
            plan_indent = len(m.group(1))
            raw_value = strip_comment(m.group(2))
            raw_value = dequote(raw_value)
            if not raw_value or raw_value in ('[]',):
                in_plan = True
                continue
            scalar_plan = raw_value
            break

if capture and in_plan:
    flush_item()

base_seconds = parse_time_token(presentation_start)

if scalar_plan and scalar_plan not in ('""', "''", '[]'):
    segs = []
    for seg in [s.strip() for s in scalar_plan.split(';') if s.strip()]:
        parts = seg.split()
        if len(parts) < 4:
            segs.append(seg)
            continue
        parts[0] = normalize_plan_time(parts[0], base_seconds)
        parts[1] = normalize_plan_time(parts[1], base_seconds)
        segs.append(' '.join(parts))
    print('; '.join(segs))
elif items:
    segs = []
    for i, item in enumerate(items):
        start = normalize_plan_time(item['start'], base_seconds)
        end = normalize_plan_time(item['end'], base_seconds)
        if not end:
            if i + 1 < len(items):
                end = normalize_plan_time(items[i + 1]['start'], base_seconds)
            else:
                end = 'end'
        seg = f"{start} {end} {item['grid']} {item['active']}"
        bbox = item['bbox']
        if bbox and bbox != '-':
            seg += f" {bbox}"
        segs.append(seg)
    print('; '.join(segs))
PY
}

build_manual_plan() {  # <W> <H> <DUR> <nn>, reads plan lines on stdin
    local W="$1" H="$2" DUR="$3" nn="$4"
    local line start_raw end_raw grid grid_norm active bbox extra start end cols rows bx by bw bh total active_list
    local idx k c r x y w h segment_lines

    while IFS= read -r line; do
        line="${line%%#*}"
        [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] && continue

        start_raw=""; end_raw=""; grid=""; active=""; bbox=""; extra=""
        read -r start_raw end_raw grid active bbox extra <<< "$line"
        if [ -n "${extra:-}" ] || [ -z "${start_raw:-}" ] || [ -z "${end_raw:-}" ] || [ -z "${grid:-}" ]; then
            echo "[${nn}] ligne MANUAL_PLAN invalide: ${line}" >&2
            return 1
        fi

        if ! grid_norm="$(normalize_grid "$grid")"; then
            echo "[${nn}] grille invalide dans MANUAL_PLAN: ${grid} (format attendu: RxC ou N parmi 1,2,3,4,6)." >&2
            return 1
        fi
        rows="${grid_norm%x*}"
        cols="${grid_norm#*x}"
        total=$((cols * rows))

        start="$(time_to_seconds "$start_raw" "$DUR")" || { echo "[${nn}] début invalide: ${start_raw}" >&2; return 1; }
        end="$(time_to_seconds "$end_raw" "$DUR")" || { echo "[${nn}] fin invalide: ${end_raw}" >&2; return 1; }
        if ! awk -v s="$start" -v e="$end" -v d="$DUR" 'BEGIN{exit !(s < e && e <= d + 0.001)}'; then
            echo "[${nn}] plage invalide: ${start_raw}..${end_raw} (durée clip ${DUR}s)." >&2
            return 1
        fi

        if [ -z "${active:-}" ] || [ "$active" = "-" ] || [ "$active" = "all" ]; then
            active_list="$(seq 1 "$total" | tr '\n' ',' | sed 's/,$//')"
        else
            active_list="$active"
        fi

        bx=0; by=0; bw="$W"; bh="$H"
        if [ -n "${bbox:-}" ] && [ "$bbox" != "-" ]; then
            oldIFS="$IFS"; IFS=':'; set -- $bbox; IFS="$oldIFS"
            bx="${1:-0}"; by="${2:-0}"; bw="${3:-$W}"; bh="${4:-$H}"
        fi

        bx=$(even_coord "$bx"); by=$(even_coord "$by"); bw=$(even_dim "$bw"); bh=$(even_dim "$bh")
        if [ $((bx + bw)) -gt "$W" ]; then bw=$(even_dim $((W - bx))); fi
        if [ $((by + bh)) -gt "$H" ]; then bh=$(even_dim $((H - by))); fi

        k=0
        segment_lines=""
        for idx in $(echo "$active_list" | tr ',;' ' '); do
            [ -z "$idx" ] && continue
            if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$total" ]; then
                echo "[${nn}] index caméra invalide dans MANUAL_PLAN: ${idx} (1..${total})" >&2
                return 1
            fi
            k=$((k+1))
            c=$(((idx - 1) % cols))
            r=$(((idx - 1) / cols))
            x=$(even_coord $((bx + (c * bw) / cols)))
            y=$(even_coord $((by + (r * bh) / rows)))
            w=$(even_dim $((((c + 1) * bw) / cols - (c * bw) / cols)))
            h=$(even_dim $((((r + 1) * bh) / rows - (r * bh) / rows)))
            if [ $((x + w)) -gt "$W" ]; then w=$(even_dim $((W - x))); fi
            if [ $((y + h)) -gt "$H" ]; then h=$(even_dim $((H - y))); fi
            segment_lines+="${start} ${end} ${x} ${y} ${w} ${h} ${k} X ${rows}x${cols}"$'\n'
        done
        if [ "$k" -eq 0 ]; then
            echo "[${nn}] aucune caméra active valide dans MANUAL_PLAN: ${line}" >&2
            return 1
        fi
        printf '%s' "$segment_lines" | awk -v K="$k" '{ $8=K; print }'
    done
}

sample_frames() {  # <input_webcam> <tmp_dir> <step> <duration>
    local in="$1" outdir="$2" step="$3" dur="$4"

    # Avec un STEP élevé, extraire quelques images par seeks successifs est
    # souvent bien plus rapide que décoder tout le clip en continu.
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

for nn in "$@"; do
    grid_norm=""
  wc="output/${nn}/webcam.mp4"
  if [ ! -f "$wc" ]; then
    echo "[${nn}] $wc introuvable — lancez d'abord bbb_make_clips.sh ${nn}"; continue
  fi
  W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$wc")
  H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$wc")
  DUR=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$wc")
    echo "[${nn}] analyse de $wc (${W}x${H}, ${DUR}s) …"
        grid_override="$(yaml_webcams_grid "$nn" || true)"
        yaml_plan_override="$(yaml_webcams_plan "$nn" || true)"
                if [ -n "$grid_override" ]; then
                    if ! grid_norm="$(normalize_grid "$grid_override")"; then
                                                echo "[${nn}] webcams_grid invalide dans presentations_cut.yaml: ${grid_override} (format attendu: RxC ex: 2x3, ou N parmi 1,2,3,4,6)" >&2
                                continue
                        fi
                    grid_override="$grid_norm"
                fi

        if [ -n "$MANUAL_PLAN" ] || [ -n "$MANUAL_SEGMENTS" ] || [ -n "$FORCE_GRID" ] || [ -n "$yaml_plan_override" ]; then
        if [ -n "$MANUAL_PLAN" ] || [ -n "$MANUAL_SEGMENTS" ]; then
            plan_path=""
            if [ -n "$MANUAL_PLAN" ] && ! plan_path="$(resolve_manual_plan "$MANUAL_PLAN" "$nn")"; then
                echo "[${nn}] MANUAL_PLAN introuvable: ${MANUAL_PLAN}" >&2
                continue
            fi
            if [ -n "$MANUAL_PLAN" ]; then
                plan=$(build_manual_plan "$W" "$H" "$DUR" "$nn" < "$plan_path") || continue
                echo "  plan manuel: ${plan_path}"
            else
                plan=$(printf '%s\n' "$MANUAL_SEGMENTS" | tr ';' '\n' | build_manual_plan "$W" "$H" "$DUR" "$nn") || continue
            fi
            echo "  mode manuel: plan de durées fourni, analyse auto ignorée"
        elif [ -n "$yaml_plan_override" ]; then
            plan=$(printf '%s\n' "$yaml_plan_override" | tr ';' '\n' | build_manual_plan "$W" "$H" "$DUR" "$nn") || continue
            echo "  mode YAML: webcams_plan appliqué, analyse auto ignorée"
        else
        if ! grid_norm="$(normalize_grid "$FORCE_GRID")"; then
            echo "[${nn}] FORCE_GRID invalide (${FORCE_GRID}). Format attendu: RxC (ex: 2x2) ou N parmi 1,2,3,4,6." >&2
            continue
        fi
        FORCE_GRID="$grid_norm"
        rows="${FORCE_GRID%x*}"
        cols="${FORCE_GRID#*x}"

        bx=0; by=0; bw="$W"; bh="$H"
        if [ -n "$FORCE_BBOX" ]; then
            oldIFS="$IFS"; IFS=':'; set -- $FORCE_BBOX; IFS="$oldIFS"
            bx="${1:-0}"; by="${2:-0}"; bw="${3:-$W}"; bh="${4:-$H}"
        fi

        bx=$(even_coord "$bx"); by=$(even_coord "$by"); bw=$(even_dim "$bw"); bh=$(even_dim "$bh")
        if [ $((bx + bw)) -gt "$W" ]; then bw=$(even_dim $((W - bx))); fi
        if [ $((by + bh)) -gt "$H" ]; then bh=$(even_dim $((H - by))); fi

        total=$((cols * rows))
        active_list="${FORCE_ACTIVE}"
        [ -z "$active_list" ] && active_list="$(seq 1 "$total" | tr '\n' ',' | sed 's/,$//')"

        plan=""
        k=0
        for idx in $(echo "$active_list" | tr ',;' ' '); do
            [ -z "$idx" ] && continue
            if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$total" ]; then
                echo "[${nn}] index caméra invalide dans FORCE_ACTIVE: ${idx} (1..${total})" >&2
                continue
            fi
            k=$((k+1))
            c=$(((idx - 1) % cols))
            r=$(((idx - 1) / cols))
            x=$(even_coord $((bx + (c * bw) / cols)))
            y=$(even_coord $((by + (r * bh) / rows)))
            w=$(even_dim $((((c + 1) * bw) / cols - (c * bw) / cols)))
            h=$(even_dim $((((r + 1) * bh) / rows - (r * bh) / rows)))
            plan+="0.00 ${DUR} ${x} ${y} ${w} ${h} ${k} X ${rows}x${cols}"$'\n'
        done

        if [ "$k" -eq 0 ]; then
            echo "[${nn}] aucune caméra active valide (FORCE_ACTIVE=${FORCE_ACTIVE})." >&2
            continue
        fi

        # Remplace le marqueur K total (X) par la valeur finale k.
        plan="$(printf '%s' "$plan" | awk -v K="$k" '{ $8=K; print }')"
        echo "  mode manuel: grille ${rows}x${cols}, ${k} caméra(s) active(s), analyse auto ignorée"
        fi
    else

  tmp=$(mktemp -d)
    sample_frames "$wc" "$tmp" "$STEP" "$DUR"
    echo "  analyse Python …"

    export WEBCAMS_GRID_OVERRIDE="$grid_override"
    plan=$("$PYTHON" - "$tmp" "$STEP" "$W" "$H" "$DUR" <<'PY'
import sys, glob, numpy as np, PIL.Image as I
import os
frames_dir, step, W, H, DUR = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
files = sorted(glob.glob(f"{frames_dir}/f*.png"))
if not files: sys.exit(0)
grays = np.stack([np.asarray(I.open(f).convert("RGB")).mean(2) for f in files])
N, rh, rw = grays.shape; sx, sy = W/rw, H/rh
# Les webcams BBB sont des tuiles vidéo PLEINES posées sur fond blanc, de tailles
# et de proportions différentes (portrait, paysage, etc.), parfois accolées sans
# gouttière. On ne suppose donc PAS une grille régulière : on détecte les vraies
# tuiles par découpe récursive (gouttières blanches + sauts de couverture), puis
# on recadre chaque tuile au plus juste (sans les bandes blanches de pillarbox).
MINT   = max(8, int(0.045 * rw))   # côté minimal d'une tuile (px échantillonnés)
MINGAP = max(2, int(0.004 * rw))   # largeur minimale d'une gouttière blanche
MINSTEP = 0.15                     # saut de couverture séparant deux tuiles accolées
CELL_OCCUPANCY_THRESHOLD = 0.02    # fraction minimale de pixels non blancs pour garder une cellule
GRID_OVERRIDE = os.environ.get("WEBCAMS_GRID_OVERRIDE", "").strip()

def parse_layout(text):
    text = text.strip().lower().replace('*', 'x')
    if text.isdigit():
        n = int(text)
        mapping = {1: (1, 1), 2: (2, 1), 3: (3, 1), 4: (2, 2), 6: (3, 2)}
        if n not in mapping:
            raise ValueError(f"unsupported webcam count: {text}")
        return mapping[n]
    if 'x' not in text:
        raise ValueError(f"unsupported grid layout: {text}")
    rows_s, cols_s = text.split('x', 1)
    rows = int(rows_s)
    cols = int(cols_s)
    if cols < 1 or rows < 1:
        raise ValueError(f"unsupported grid layout: {text}")
    return (cols, rows)

def grid_cells(layout):
    cols, rows = layout
    xcuts = [int(round(i * rw / cols)) for i in range(cols + 1)]
    ycuts = [int(round(i * rh / rows)) for i in range(rows + 1)]
    cells = []
    for row in range(rows):
        for col in range(cols):
            cells.append((xcuts[col], ycuts[row], xcuts[col + 1], ycuts[row + 1]))
    return cells

def cell_score(gs, cell):
    x0, y0, x1, y1 = cell
    sub = gs[:, y0:y1, x0:x1]
    if sub.size == 0:
        return 0.0
    return (sub < 248).mean()

def detect_grid(gs):
    if GRID_OVERRIDE:
        layout = parse_layout(GRID_OVERRIDE)
        cells = grid_cells(layout)
        active = [cell for cell in cells if cell_score(gs, cell) >= CELL_OCCUPANCY_THRESHOLD]
        return active or cells[:1], layout

    # On évalue les 3 grilles supportées sur l'ensemble du clip, puis on garde
    # celle qui contient le plus de cellules actives. En cas d'égalité, on
    # préfère la grille la plus simple (1x1, puis 2x1) plutôt que 2x2.
    best_cells=[]; best_layout=(1,1)
    best_count=-1
    best_cells_total=999
    for layout in ((1,1), (2,1), (2,2)):
        cells = grid_cells(layout)
        active = [cell for cell in cells if cell_score(gs, cell) >= CELL_OCCUPANCY_THRESHOLD]
        count = len(active)
        total_cells = len(cells)
        if count > best_count or (count == best_count and total_cells < best_cells_total):
            best_count = count
            best_cells_total = total_cells
            best_cells = active or cells[:1]
            best_layout = layout
    return best_cells, best_layout

def content(gs):
    # Tuile = pixel non-blanc dans une FRACTION des trames (vote majoritaire, donc
    # robuste aux transitoires et au bruit d'encodage) OU structure spatiale
    # persistante. La gouttière blanche (plate + fixe) ne remplit aucun des deux.
    dark = (gs < 248).mean(0)
    g = gs.mean(0)
    gx = np.abs(np.diff(g, axis=1, prepend=g[:, :1]))
    gy = np.abs(np.diff(g, axis=0, prepend=g[:1, :]))
    return (dark > 0.40) | ((gx + gy) > 8.0)

def zero_runs(cov, minrun):     # plages où la couverture est nulle (gouttières)
    out=[]; s=None
    for i,v in enumerate(cov):
        if v<=1e-9 and s is None: s=i
        elif v>1e-9 and s is not None:
            if i-s>=minrun: out.append((s,i))
            s=None
    if s is not None and len(cov)-s>=minrun: out.append((s,len(cov)))
    return out

def best_step(cov, minband, minstep):   # meilleur point de rupture de plateau
    # N'accepte une coupure que si les DEUX côtés sont des plateaux PLATS (écart-type
    # absolu faible) : une vraie frontière de cellule est une marche nette entre deux
    # niveaux stables. Une bande de letterbox/pillarbox blanche À L'INTÉRIEUR d'une
    # cellule produit au contraire une « bosse » (niveau A → B → A) : tout point de
    # coupe y laisse un côté non plat, donc elle est rejetée (plus de fausses tranches).
    n=len(cov)
    if n < 2*minband: return None
    ps =np.concatenate([[0.0], np.cumsum(cov)])
    ps2=np.concatenate([[0.0], np.cumsum(cov*cov)])
    best=None; bestd=minstep
    for p in range(minband, n-minband+1):
        lm=(ps[p]-ps[0])/p; rm=(ps[n]-ps[p])/(n-p)
        d=abs(lm-rm)
        if d<=bestd: continue
        lv=max(0.0,(ps2[p]-ps2[0])/p - lm*lm)**0.5
        rv=max(0.0,(ps2[n]-ps2[p])/(n-p) - rm*rm)**0.5
        if lv>0.12 or rv>0.12: continue
        bestd=d; best=p
    if best is not None:
        return best

    # Fallback: quand le profil n'a pas deux plateaux assez nets, on coupe sur
    # la plus forte rupture locale. C'est utile pour les webcams adjacentes sans
    # gouttière marquée dans une grille 2x2.
    diffs=np.abs(np.diff(cov))
    if len(diffs) == 0:
        return None
    lo=max(0, minband-1)
    hi=max(lo+1, len(diffs)-minband+1)
    if hi <= lo:
        return None
    p=lo + int(np.argmax(diffs[lo:hi])) + 1
    if diffs[p-1] >= minstep * 0.35:
        return p
    return None

def decompose(M, x0,x1,y0,y1, out, depth=0):
    sub=M[y0:y1, x0:x1]
    ys=np.where(sub.any(1))[0]; xs=np.where(sub.any(0))[0]
    if len(xs)==0 or len(ys)==0: return
    x0,x1 = x0+int(xs[0]), x0+int(xs[-1])+1      # recadrage serré sur le contenu
    y0,y1 = y0+int(ys[0]), y0+int(ys[-1])+1
    w,h = x1-x0, y1-y0
    if depth>12 or (w<MINT and h<MINT): out.append((x0,y0,x1,y1)); return
    colcov=M[y0:y1, x0:x1].mean(0); rowcov=M[y0:y1, x0:x1].mean(1)
    vg=[g for g in zero_runs(colcov,MINGAP) if g[0]>0 and g[1]<w]   # gouttière verticale
    if vg:
        cuts=[0]+[(s+e)//2 for s,e in vg]+[w]
        for i in range(len(cuts)-1): decompose(M,x0+cuts[i],x0+cuts[i+1],y0,y1,out,depth+1)
        return
    hg=[g for g in zero_runs(rowcov,MINGAP) if g[0]>0 and g[1]<h]   # gouttière horizontale
    if hg:
        cuts=[0]+[(s+e)//2 for s,e in hg]+[h]
        for i in range(len(cuts)-1): decompose(M,x0,x1,y0+cuts[i],y0+cuts[i+1],out,depth+1)
        return
    ps=best_step(rowcov, max(MINT//2,3), MINSTEP)    # tuiles empilées, largeurs ≠
    if ps is not None:
        decompose(M,x0,x1,y0,y0+ps,out,depth+1); decompose(M,x0,x1,y0+ps,y1,out,depth+1); return
    pv=best_step(colcov, max(MINT//2,3), MINSTEP)    # tuiles côte à côte, hauteurs ≠
    if pv is not None:
        decompose(M,x0,x0+pv,y0,y1,out,depth+1); decompose(M,x0+pv,x1,y0,y1,out,depth+1); return
    out.append((x0,y0,x1,y1))

def detect(M):
    out=[]; decompose(M,0,M.shape[1],0,M.shape[0],out)
    out=[t for t in out if (t[2]-t[0])>=MINT and (t[3]-t[1])>=MINT]
    out.sort(key=lambda t:(round(t[1]/(0.22*M.shape[0])), t[0]))   # ordre lecture: rangées puis colonnes
    return out

def ev(v): v=int(round(v)); return v-(v%2)
# La grille est fixe sur tout le clip : on la détecte une seule fois sur l'ensem-
# ble des trames échantillonnées, puis on découpe des cellules égales sur toute
# la durée. Les cellules quasi vides sont ignorées.
active_cells, layout = detect_grid(grays)
cols, rows = layout
layout_name = f"{cols}x{rows}"
start=0.00
end=DUR
K=len(active_cells)
if K<1:
    print(f"{start:.2f} {end:.2f} 0 0 0 0 0 0 {layout_name}cam")
else:
    for k,(tx0,ty0,tx1,ty1) in enumerate(active_cells, start=1):
        x=ev(tx0*sx); y=ev(ty0*sy); w=ev((tx1-tx0)*sx); h=ev((ty1-ty0)*sy)
        if x+w>W: w=ev(W-x)
        if y+h>H: h=ev(H-y)
        print(f"{start:.2f} {end:.2f} {x} {y} {w} {h} {k} {K} {layout_name}cam")
PY
)
  rm -rf "$tmp"
    fi

    outdir="output/${nn}/webcams"; mkdir -p "$outdir"
    if [ "$PARTIAL_SPLIT" = "1" ]; then
        {
            echo ""
            echo "# --- partial split $(date '+%Y-%m-%d %H:%M:%S') ---"
        } >> "$outdir/manifest.txt"
    else
        : > "$outdir/manifest.txt"
        # Purge les clips d'une exécution précédente : sinon un ancien découpage
        # (plus de segments/caméras) resterait mélangé au nouveau et polluerait la
        # phase 3 (qui prend tous les seg*_cam*.mp4 du dossier).
        rm -f "$outdir"/seg*_cam*.mp4
    fi
  hms(){ awk -v s="$1" 'BEGIN{printf "%d:%02d", s/60, int(s)%60}'; }
  made=0
    planf="$outdir/.split_plan.tmp"
    segf="$outdir/.split_segments.tmp"
    printf '%s\n' "$plan" > "$planf"

    # Segments uniques qui ont au moins une tuile à extraire. En auto, les
    # segments à 1 caméra restent sans crop; en manuel, une seule tuile active
    # doit quand même être encodée.
    awk '$7>0 && $5>0 && $6>0{print $1" "$2" "$8" "$9}' "$planf" | awk '!seen[$0]++' > "$segf"
    seg_count=$(wc -l < "$segf" | tr -d ' ')
    echo "  segments à encoder: ${seg_count}"

    # Notes informatives pour les segments à 1 caméra.
    awk '$7==0{print "  "$1" "$2" "$9}' "$planf" | while read -r start end grid; do
        echo "  $(hms "$start")–$(hms "$end")  1 cam (${grid}) — utiliser webcam.mp4" | tee -a "$outdir/manifest.txt"
    done

    # Optimisation majeure: un seul décodage par segment, crops en parallèle via filter_complex.
    seg_idx=0
    while read -r start end K grid; do
        [ -z "${start:-}" ] && continue
        seg_idx=$((seg_idx+1))
        dur=$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.3f", b-a}')
        echo "  encodage segment ${seg_idx}/${seg_count}: $(hms "$start")–$(hms "$end") (${K} cam)"

        cams_tmp="$outdir/.cams_${start//./_}_${end//./_}.tmp"
        awk -v s="$start" -v e="$end" -v k="$K" '$1==s && $2==e && $8==k {print}' "$planf" > "$cams_tmp"

        build_segment_cmd "$VENC" "$start" "$dur" "$wc" "$cams_tmp" "$outdir"

        while read -r _s _e x y w h kcam _K _grid; do
            out="$outdir/seg$(printf '%04d' "${start%.*}")s_cam${kcam}-of-${K}.mp4"
            made=$((made+1))
            echo "  $(hms "$start")–$(hms "$end")  cam ${kcam}/${K} (${grid})  crop ${w}x${h}+${x}+${y} -> ${out##*/}" | tee -a "$outdir/manifest.txt"
        done < "$cams_tmp"

        if [ "$DRY_RUN" = "1" ]; then
            echo "  DRY_RUN=1 — encodage ffmpeg ignoré"
        else
            if ! "${cmd[@]}"; then
                if [ "$VENC" = "h264_videotoolbox" ] && [ "$STRICT_HW" != "1" ]; then
                    echo "  (h264_videotoolbox indisponible, fallback libx264)" >&2
                    build_segment_cmd "libx264" "$start" "$dur" "$wc" "$cams_tmp" "$outdir"
                    "${cmd[@]}"
                else
                    rm -f "$cams_tmp"
                    exit 1
                fi
            fi
        fi
        rm -f "$cams_tmp"
    done < "$segf"

    rm -f "$planf" "$segf"
  echo "[${nn}] ${made} clip(s) caméra dans $outdir"
done
