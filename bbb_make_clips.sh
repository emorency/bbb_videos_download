#!/usr/bin/env bash
# PHASE 2 — Génère les clips par présentation à importer dans DaVinci Resolve,
# à partir des points de coupe édités dans presentations_cut.txt.
#
# Pour chaque ligne (NUM) de presentations_cut.txt :
#   output/NUM/webcam.mp4     (caméra + audio)
#   output/NUM/deskshare.mp4  (partage d'écran, si présent)
#   output/NUM/slides.mp4     (diapos rendues sur la timeline shapes.svg)
# Les trois couvrent EXACTEMENT la même fenêtre [DEBUT, FIN] : déposés dans
# Resolve au même point, ils sont alignés (deskshare est noir là où personne ne
# partageait ; le clip diapos affiche chaque diapo au moment où elle était à
# l'écran).
#
# SCINDER une présentation : webcam et deskshare sont coupés PAR LE TEMPS, donc
# il suffit d'ajouter une ligne dans presentations_cut.txt avec un NUM unique et
# une sous-plage [DEBUT, FIN]. Les diapos sont automatiquement tirées de la
# présentation d'origine que recouvre cette plage — pas besoin d'indiquer l'ID.
# (Garder chaque coupe à l'intérieur d'une seule présentation d'origine pour que
# les diapos soient correctes.)
#
# Usage: bbb_make_clips.sh [dossier] [mode] [NUM...]
#   dossier : dossier de l'enregistrement (défaut: .)
#   mode    : encode (défaut, bornes exactes + alignement garanti, réencodage
#             matériel rapide) | copy (instantané, sans perte, bornes alignées
#             sur l'image-clé la plus proche)
#   NUM...  : NUM de ligne à traiter (défaut: toutes). Accepte "5" ou "05".
#             ex: bbb_make_clips.sh 2026-07-07 encode 3
#                 bbb_make_clips.sh 2026-07-07 encode 5 6

set -euo pipefail

rec_dir="${1:-.}"
mode="${2:-encode}"
shift $(( $# < 2 ? $# : 2 )) || true
wanted=" $* "   # liste des NUM demandés (vide = toutes)
cd "$rec_dir"

cutfile="presentations_cut.txt"
for f in "$cutfile" webcams.mp4; do
  [ -f "$f" ] || { echo "Erreur: $f introuvable dans $(pwd)." >&2; exit 1; }
done
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
    ffmpeg -y -nostdin -v error -ss "$2" -i "$1" -t "$3" \
      -c:v h264_videotoolbox -b:v 14M "${aopt[@]}" -movflags +faststart "$4"
  fi
}

# Rend un clip vidéo des diapos sur la fenêtre [ss,ee], chaque diapo affichée
# pendant son intervalle in/out (shapes.svg). Les trous (partage d'écran) tiennent
# la diapo précédente. Retourne 1 si aucune diapo dans la fenêtre.
build_slides() {  # <id> <slidedir> <ss> <ee> <out>
  local id="$1" slidedir="$2" ss="$3" ee="$4" out="$5"
  local st segs sn d last dur src
  st="$(mktemp -d)"
  segs="$(grep -oE '<image[^>]*>' shapes.svg | \
    sed -nE "s#.*in=\"([0-9.]+)\".*out=\"([0-9.]+)\".*href=\"presentation/$id/svgs/slide([0-9]+)\.svg\".*#\3 \1 \2#p" | \
    sort -k2 -n | awk -v ss="$ss" -v ee="$ee" '
      BEGIN{cursor=ss; prev=""}
      { sn=$1; ino=$2; outo=$3;
        if(outo<=ss||ino>=ee) next;
        a=(ino<ss)?ss:ino; b=(outo>ee)?ee:outo; if(a<cursor)a=cursor; if(b<=a) next;
        if(a>cursor){ hs=(prev!="")?prev:sn; printf "%s %.3f\n", hs, a-cursor }
        printf "%s %.3f\n", sn, b-a; cursor=b; prev=sn }
      END{ if(cursor<ee&&prev!="") printf "%s %.3f\n", prev, ee-cursor }')"
  [ -z "$segs" ] && { rm -rf "$st"; return 1; }

  for sn in $(echo "$segs" | awk '{print $1}' | sort -un); do
    src=""
    [ -f "$slidedir/slide${sn}.svg" ] && src="$slidedir/slide${sn}.svg"
    [ -z "$src" ] && [ -f "$id/slide${sn}.svg" ] && src="$id/slide${sn}.svg"
    if [ -n "$src" ]; then
      # resvg (et non rsvg-convert) : rend correctement les fonds/tracés à
      # très grandes coordonnées des SVG BBD issus de PDF (rsvg les ignore).
      resvg --width 1920 --height 1080 --background white "$src" "$st/slide${sn}.png" 2>/dev/null
    else
      ffmpeg -y -nostdin -v error -f lavfi -i color=c=black:s=1920x1080 -frames:v 1 "$st/slide${sn}.png"
    fi
  done

  { echo "ffconcat version 1.0"
    last=""
    while read -r sn d; do echo "file '$st/slide${sn}.png'"; echo "duration $d"; last="$sn"; done <<< "$segs"
    echo "file '$st/slide${last}.png'"
  } > "$st/list.txt"

  dur="$(awk -v a="$ss" -v b="$ee" 'BEGIN{printf "%.3f", b-a}')"
  ffmpeg -y -nostdin -v error -f concat -safe 0 -i "$st/list.txt" -t "$dur" \
    -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p" \
    -c:v h264_videotoolbox -b:v 8M -movflags +faststart "$out"
  rm -rf "$st"
}

mkdir -p output
[ -f output/manifest.txt ] || : > output/manifest.txt
echo "Mode: $mode"
[ -n "${wanted// /}" ] && echo "Présentations demandées:${wanted}" || echo "Présentations: toutes"

while IFS='|' read -r num start end info; do
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
  start="$(trim "$start")"; end="$(trim "$end")"; info="$(trim "$info")"

  ss="$(to_sec "$start")"; ee="$(to_sec "$end")"
  dur="$(awk -v a="$ss" -v b="$ee" 'BEGIN{printf "%.3f", b-a}')"
  nn="$num"                       # le NUM sert de nom de dossier de sortie
  outdir="output/${nn}"
  mkdir -p "$outdir"

  cut_video webcams.mp4 "$ss" "$dur" "$outdir/webcam.mp4"
  ds_txt="webcam seulement"

  if [ "$have_deskshare" = "1" ]; then
    overlap=0
    while read -r es ee2; do
      [ -z "$es" ] && continue
      o="$(awk -v ps="$ss" -v pe="$ee" -v s="$es" -v e="$ee2" 'BEGIN{os=(ps>s)?ps:s; oe=(pe<e)?pe:e; print (oe>os)?1:0}')"
      [ "$o" = "1" ] && overlap=1
    done <<< "$deskshare_events"
    if [ "$overlap" = "1" ]; then
      cut_video deskshare.mp4 "$ss" "$dur" "$outdir/deskshare.mp4"
      ds_txt="webcam + deskshare"
    fi
  fi

  # Diapos : présentation source déterminée par la plage horaire de la coupe
  src_txt=""
  if [ "$have_shapes" = "1" ]; then
    src="$(find_src "$ss" "$ee")"
    if [ -n "$src" ]; then
      if build_slides "${orig_id[$src]}" "$(printf '%02d' "$src")" "$ss" "$ee" "$outdir/slides.mp4"; then
        ds_txt="$ds_txt + slides"; src_txt="  (diapos P${src})"
      fi
    fi
  fi

  line="${nn}: ${start}–${end}  [$ds_txt]  — ${info}${src_txt}"
  grep -v "^${nn}: " output/manifest.txt > output/manifest.tmp 2>/dev/null || true
  printf '%s\n' "$line" >> output/manifest.tmp
  sort output/manifest.tmp -o output/manifest.txt
  rm -f output/manifest.tmp
  echo "$line"
done < "$cutfile"

echo
echo "Clips prêts dans output/ (voir manifest.txt)."
