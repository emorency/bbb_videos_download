#!/usr/bin/env bash
# PHASE 2 — Génère les clips par présentation à importer dans un logiciel de
# montage vidéo, à partir des points de coupe édités dans presentations_cut.yaml
# (ou presentations_cut.txt pour compatibilité).
#
# Pour chaque entrée (NUM) de presentations_cut.yaml/.txt :
#   output/NUM/webcam.mp4     (caméra + audio)
#   output/NUM/deskshare.mp4  (partage d'écran, si présent)
#   output/NUM/slides.mp4     (diapos rendues sur la timeline shapes.svg)
# Les trois couvrent EXACTEMENT la même fenêtre [DEBUT, FIN] : déposés sur la
# timeline de montage au même point, ils sont alignés (deskshare est noir là où
# personne ne partageait ; le clip diapos affiche chaque diapo au moment où elle
# était à l'écran).
#
# SCINDER une présentation : webcam et deskshare sont coupés PAR LE TEMPS, donc
# il suffit d'ajouter une entrée dans presentations_cut.yaml (ou ligne dans .txt)
# avec un NUM unique et
# une sous-plage [DEBUT, FIN]. Les diapos sont rendues depuis la timeline
# shapes.svg complète, donc une coupe peut traverser un changement de deck.
#
# Usage: bbb_make_clips.sh [dossier] [mode] [NUM...]
#   dossier : dossier de l'enregistrement (défaut: .)
#   mode    : encode (défaut, bornes exactes + alignement garanti, réencodage
#             matériel rapide) | copy (instantané, sans perte, bornes alignées
#             sur l'image-clé la plus proche). OPTIONNEL — s'il est omis, un NUM
#             peut suivre directement le dossier (ex: « ... 2026-07-07 02 »).
#   NUM...  : NUM de ligne à traiter (défaut: toutes). Accepte "5" ou "05".
#             ex: bbb_make_clips.sh 2026-07-07 encode 3
#                 bbb_make_clips.sh 2026-07-07 5 6      (mode encode implicite)

set -euo pipefail

rec_dir="${1:-.}"
[ $# -ge 1 ] && shift || true          # consomme le dossier
# mode est OPTIONNEL : on ne le consomme que si c'est vraiment 'encode'/'copy'.
# Sinon (ex: « bbb_make_clips.sh 2026-07-16 02 »), l'argument est un NUM, pas le
# mode — évite de traiter TOUTES les présentations quand on en visait une seule.
mode="encode"
if [ "${1:-}" = "encode" ] || [ "${1:-}" = "copy" ]; then
  mode="$1"; shift
fi
wanted=" $* "   # liste des NUM demandés (vide = toutes)
VENC="${BBB_VENC:-h264_videotoolbox}"
STRICT_HW="${BBB_STRICT_HW:-0}"
cd "$rec_dir"

cutfile_yaml="presentations_cut.yaml"
cutfile_txt="presentations_cut.txt"
cutfile=""
tmp_cut=""

if [ -f "$cutfile_yaml" ]; then
  cutfile="$cutfile_yaml"
  tmp_cut="$(mktemp)"
  # YAML -> lignes pipe-delimited: NUM|START|END|PRESENTER|INFO|PRIO
  python3 - "$cutfile_yaml" > "$tmp_cut" <<'PY'
import re, sys

path = sys.argv[1]
entries = []
cur = None

def strip_comment(v):
  # Retire un commentaire « # ... » en fin de ligne, sans toucher un « # »
  # dans une valeur entre guillemets (un « # » n'ouvre un commentaire que
  # s'il est précédé d'un espace ou en début de valeur).
  out = []; quote = None; prev_space = True
  for ch in v:
    if quote:
      out.append(ch)
      if ch == quote: quote = None
      prev_space = False
    elif ch in ('"', "'"):
      quote = ch; out.append(ch); prev_space = False
    elif ch == '#' and prev_space:
      break
    else:
      out.append(ch); prev_space = ch.isspace()
  return ''.join(out).rstrip()

def unquote(v):
  v = strip_comment(v.strip())
  if len(v) >= 2 and ((v[0] == '"' and v[-1] == '"') or (v[0] == "'" and v[-1] == "'")):
    v = v[1:-1]
  return v

for raw in open(path, encoding='utf-8'):
  if not raw.strip() or raw.lstrip().startswith('#'):
    continue
  m_new = re.match(r'^\s*-\s*num\s*:\s*(.+?)\s*$', raw)
  if m_new:
    if cur:
      entries.append(cur)
    cur = {
      'num': unquote(m_new.group(1)),
      'start': '',
      'end': '',
      'presenter': '',
      'info': '',
      'webcams_priority': ''
    }
    continue
  if not cur:
    continue
  m_kv = re.match(r'^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*(.*?)\s*$', raw)
  if not m_kv:
    continue
  k, v = m_kv.group(1), m_kv.group(2)
  if k in ('start', 'end', 'presenter', 'nom', 'info'):
    if k == 'nom':
      k = 'presenter'
    cur[k] = unquote(v)
  elif k == 'webcams_priority':
    v = strip_comment(v.strip())
    if v.startswith('[') and v.endswith(']'):
      vals = [x.strip() for x in v[1:-1].split(',') if x.strip()]
      cur[k] = ','.join(vals)
    else:
      cur[k] = unquote(v)

if cur:
  entries.append(cur)

for e in entries:
  print(f"{e['num']}|{e['start']}|{e['end']}|{e['presenter']}|{e['info']}|{e['webcams_priority']}")
PY
  cutfile="$tmp_cut"
elif [ -f "$cutfile_txt" ]; then
  cutfile="$cutfile_txt"
else
  echo "Erreur: presentations_cut.yaml ou presentations_cut.txt introuvable dans $(pwd)." >&2
  exit 1
fi

[ -f webcams.mp4 ] || { echo "Erreur: webcams.mp4 introuvable dans $(pwd)." >&2; exit 1; }
have_deskshare=0
[ -f deskshare.mp4 ] && [ -f deskshare.xml ] && have_deskshare=1
have_shapes=0
[ -f shapes.svg ] && have_shapes=1

# Fenêtres [début,fin] et id de chaque présentation ORIGINALE (ordre de session
# dans shapes.svg). Sert à retrouver, pour chaque coupe, la présentation source
# des diapos — même quand on scinde une présentation en plusieurs coupes.
declare -a orig_id orig_start orig_end
n_orig=0
if [ "$have_shapes" = "1" ]; then
  _vdur="$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 webcams.mp4)"
  while read -r _pid _s _e; do
    [ -z "$_pid" ] && continue
    n_orig=$((n_orig+1)); orig_id[$n_orig]="$_pid"; orig_start[$n_orig]="$_s"; orig_end[$n_orig]="$_e"
  done <<< "$(grep -oE '<image[^>]*>' shapes.svg | \
    sed -nE 's/.*in="([0-9.]+)".*out="([0-9.]+)".*href="presentation\/([^/]+)\/svgs\/.*/\1 \2 \3/p' | \
    awk -v vdur="$_vdur" '
      { pid=$3; if(!(pid in seen)){seen[pid]=1; order[++n]=pid; st[pid]=$1}
        if($1<st[pid])st[pid]=$1; x=$2; if(x>vdur)x=vdur; if(x>en[pid])en[pid]=x }
      END{ for(i=1;i<=n;i++){p=order[i]; printf "%s %.3f %.3f\n", p, st[p], en[p]} }')"
fi

slide_dir_for_id() {  # <presentation_id> -> NN, ou vide
  local pid="$1" k
  for ((k=1; k<=n_orig; k++)); do
    [ "${orig_id[$k]}" = "$pid" ] && printf '%02d' "$k" && return
  done
}

# Présentation source (indice 1..n_orig) qui recouvre le plus la fenêtre [ss,ee].
find_src() {  # <ss> <ee> -> indice, ou vide
  local ss="$1" ee="$2" k best=0 bestov=0 ov
  for ((k=1; k<=n_orig; k++)); do
    ov="$(awk -v a="$ss" -v b="$ee" -v s="${orig_start[$k]}" -v e="${orig_end[$k]}" \
      'BEGIN{lo=(a>s)?a:s; hi=(b<e)?b:e; d=hi-lo; print (d>0)?d:0}')"
    if awk -v o="$ov" -v bo="$bestov" 'BEGIN{exit !(o>bo)}'; then bestov="$ov"; best="$k"; fi
  done
  [ "$best" -gt 0 ] && echo "$best"
}

# Intervalles de partage (temps de session) pour savoir si une fenêtre en contient
deskshare_events=""
if [ "$have_deskshare" = "1" ]; then
  deskshare_events="$(grep -oE '<event[^>]*>' deskshare.xml | \
    sed -nE 's/.*start_timestamp="([0-9.]+)".*stop_timestamp="([0-9.]+)".*/\1 \2/p')"
fi

# H:MM:SS | MM:SS | SS(.ms) -> secondes
to_sec() {
  local t="$1"
  if [[ "$t" == *:* ]]; then
    awk -F: '{if(NF==3)printf "%.3f",$1*3600+$2*60+$3; else if(NF==2)printf "%.3f",$1*60+$2; else printf "%.3f",$1}' <<<"$t"
  else
    printf "%.3f" "$t"
  fi
}
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

cut_video() {  # <src> <start> <dur> <out>
  if [ "$mode" = "copy" ]; then
    ffmpeg -y -nostdin -v error -ss "$2" -i "$1" -t "$3" \
      -c copy -avoid_negative_ts make_zero "$4"
  else
    local aopt=(-an)
    ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" | grep -q . && \
      aopt=(-c:a aac -b:a 192k)
    if [ "$VENC" = "h264_videotoolbox" ]; then
      if ! ffmpeg -y -nostdin -v error -ss "$2" -i "$1" -t "$3" \
        -c:v h264_videotoolbox -b:v 6M -pix_fmt yuv420p -r 30 \
        -profile:v high -prio_speed 1 "${aopt[@]}" -movflags +faststart "$4"; then
        [ "$STRICT_HW" = "1" ] && return 1
        echo "  (h264_videotoolbox indisponible, fallback libx264)" >&2
        ffmpeg -y -nostdin -v error -ss "$2" -i "$1" -t "$3" \
          -c:v libx264 -preset veryfast -crf 18 "${aopt[@]}" -movflags +faststart "$4"
      fi
    else
      ffmpeg -y -nostdin -v error -ss "$2" -i "$1" -t "$3" \
        -c:v libx264 -preset veryfast -crf 18 "${aopt[@]}" -movflags +faststart "$4"
    fi
  fi
}

# Rend un clip vidéo des diapos sur la fenêtre [ss,ee], chaque diapo affichée
# pendant son intervalle in/out (shapes.svg). Les trous (partage d'écran) tiennent
# la diapo précédente. Retourne 1 si aucune diapo dans la fenêtre.
build_slides() {  # <ss> <ee> <out>
  local ss="$1" ee="$2" out="$3"
  local st segs pid sn d last dur src dir png key
  st="$(mktemp -d)"
  segs="$(grep -oE '<image[^>]*>' shapes.svg | \
    sed -nE 's#.*in="([0-9.]+)".*out="([0-9.]+)".*href="presentation/([^/]+)/svgs/slide([0-9]+)\.svg".*#\1 \2 \3 \4#p' | \
    sort -k1 -n | awk -v ss="$ss" -v ee="$ee" '
      BEGIN{cursor=ss; prev_pid=""; prev_sn=""}
      { ino=$1; outo=$2; pid=$3; sn=$4;
        if(outo<=ss||ino>=ee) next;
        a=(ino<ss)?ss:ino; b=(outo>ee)?ee:outo; if(a<cursor)a=cursor; if(b<=a) next;
        if(a>cursor && prev_pid!=""){ printf "%s %s %.3f\n", prev_pid, prev_sn, a-cursor }
        printf "%s %s %.3f\n", pid, sn, b-a; cursor=b; prev_pid=pid; prev_sn=sn }
      END{ if(cursor<ee&&prev_pid!="") printf "%s %s %.3f\n", prev_pid, prev_sn, ee-cursor }')"
  [ -z "$segs" ] && { rm -rf "$st"; return 1; }

  while read -r pid sn; do
    src=""
    dir="$(slide_dir_for_id "$pid")"
    [ -n "$dir" ] && [ -f "$dir/slide${sn}.svg" ] && src="$dir/slide${sn}.svg"
    [ -z "$src" ] && [ -f "$pid/slide${sn}.svg" ] && src="$pid/slide${sn}.svg"
    png="$st/${pid}_slide${sn}.png"
    if [ -n "$src" ]; then
      # resvg (et non rsvg-convert) : rend correctement les fonds/tracés à
      # très grandes coordonnées des SVG BBD issus de PDF (rsvg les ignore).
      resvg --width 1920 --height 1080 --background white "$src" "$png" 2>/dev/null
    else
      ffmpeg -y -nostdin -v error -f lavfi -i color=c=black:s=1920x1080 -frames:v 1 "$png"
    fi
  done <<< "$(echo "$segs" | awk '{print $1, $2}' | sort -u)"

  { echo "ffconcat version 1.0"
    last=""
    while read -r pid sn d; do
      key="${pid}_slide${sn}"
      echo "file '$st/${key}.png'"
      echo "duration $d"
      last="$key"
    done <<< "$segs"
    echo "file '$st/${last}.png'"
  } > "$st/list.txt"

  dur="$(awk -v a="$ss" -v b="$ee" 'BEGIN{printf "%.3f", b-a}')"
  if [ "$VENC" = "h264_videotoolbox" ]; then
    if ! ffmpeg -y -nostdin -v error -f concat -safe 0 -i "$st/list.txt" -t "$dur" \
      -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p" \
      -c:v h264_videotoolbox -b:v 8M -pix_fmt yuv420p -r 30 \
      -profile:v high -prio_speed 1 -movflags +faststart "$out"; then
      if [ "$STRICT_HW" = "1" ]; then
        rm -rf "$st"
        return 1
      fi
      echo "  (h264_videotoolbox indisponible, fallback libx264)" >&2
      ffmpeg -y -nostdin -v error -f concat -safe 0 -i "$st/list.txt" -t "$dur" \
        -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p" \
        -c:v libx264 -preset veryfast -crf 20 -movflags +faststart "$out"
    fi
  else
    ffmpeg -y -nostdin -v error -f concat -safe 0 -i "$st/list.txt" -t "$dur" \
      -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p" \
      -c:v libx264 -preset veryfast -crf 20 -movflags +faststart "$out"
  fi
  rm -rf "$st"
}

log() { echo "[$(date +%H:%M:%S)] $*"; }

mkdir -p output
[ -f output/manifest.txt ] || : > output/manifest.txt
log "Mode: $mode"
log "Encodeur vidéo: $VENC$([ "$STRICT_HW" = "1" ] && printf ' (strict)')"
[ -n "${wanted// /}" ] && log "Présentations demandées:${wanted}" || log "Présentations: toutes"

while IFS='|' read -r num start end nom info webcams_priority; do
  num="$(trim "$num")"
  [ -z "$num" ] && continue
  case "$num" in \#*) continue;; esac
  # Ne traiter que les NUM demandés (accepte "5" ou "05")
  if [ -n "${wanted// /}" ]; then
    _m=0
    [[ "$wanted" == *" $num "* ]] && _m=1
    [[ "$num" =~ ^[0-9]+$ ]] && [[ "$wanted" == *" $((10#$num)) "* ]] && _m=1
    [ "$_m" = "1" ] || continue
  fi
  start="$(trim "$start")"; end="$(trim "$end")"; info="$(trim "$info")"   # nom : utilisé en phase 3

  ss="$(to_sec "$start")"; ee="$(to_sec "$end")"
  dur="$(awk -v a="$ss" -v b="$ee" 'BEGIN{printf "%.3f", b-a}')"
  nn="$num"                       # le NUM sert de nom de dossier de sortie
  outdir="output/${nn}"
  mkdir -p "$outdir"
  log "=== Présentation ${nn}  ${start}–${end}  (${info}) ==="

  log "  webcam.mp4 … (${dur%.*}s de source)"
  t0=$SECONDS
  cut_video webcams.mp4 "$ss" "$dur" "$outdir/webcam.mp4"
  log "  webcam.mp4 ✓ ($((SECONDS-t0))s)"
  ds_txt="webcam seulement"

  if [ "$have_deskshare" = "1" ]; then
    overlap=0
    while read -r es ee2; do
      [ -z "$es" ] && continue
      o="$(awk -v ps="$ss" -v pe="$ee" -v s="$es" -v e="$ee2" 'BEGIN{os=(ps>s)?ps:s; oe=(pe<e)?pe:e; print (oe>os)?1:0}')"
      [ "$o" = "1" ] && overlap=1
    done <<< "$deskshare_events"
    if [ "$overlap" = "1" ]; then
      log "  deskshare.mp4 …"
      t0=$SECONDS
      cut_video deskshare.mp4 "$ss" "$dur" "$outdir/deskshare.mp4"
      log "  deskshare.mp4 ✓ ($((SECONDS-t0))s)"
      ds_txt="webcam + deskshare"
    fi
  fi

  # Diapos : rend la timeline complète, même si la coupe traverse plusieurs decks.
  src_txt=""
  if [ "$have_shapes" = "1" ]; then
    src="$(find_src "$ss" "$ee")"
    if [ -n "$src" ]; then
      log "  slides.mp4 … (timeline shapes.svg)"
      t0=$SECONDS
      if build_slides "$ss" "$ee" "$outdir/slides.mp4"; then
        log "  slides.mp4 ✓ ($((SECONDS-t0))s)"
        ds_txt="$ds_txt + slides"; src_txt="  (diapos timeline)"
      fi
    fi
  fi

  # Empreinte de la fenêtre : permet à la phase 3 de repérer des clips périmés
  # (fenêtre du YAML modifiée après la génération des clips).
  { echo "start=${start}"; echo "end=${end}"
    printf 'ss=%s\nee=%s\n' "$ss" "$ee"; } > "$outdir/window.txt"

  line="${nn}: ${start}–${end}  [$ds_txt]  — ${info}${src_txt}"
  grep -v "^${nn}: " output/manifest.txt > output/manifest.tmp 2>/dev/null || true
  printf '%s\n' "$line" >> output/manifest.tmp
  sort output/manifest.tmp -o output/manifest.txt
  rm -f output/manifest.tmp
  log "  ✓ Présentation ${nn} terminée [${ds_txt}]"
done < "$cutfile"

[ -n "$tmp_cut" ] && rm -f "$tmp_cut"

echo
log "Terminé en ${SECONDS}s. Clips dans output/ (voir manifest.txt)."
