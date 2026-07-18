#!/usr/bin/env bash
# Re-coupe toutes les videos d'une presentation en appliquant le MEME decoupage
# a chaque piste (webcam/deskshare/slides/webcams/final), pour conserver la
# synchro entre elles.
#
# Deux modes selon le nombre d'arguments :
#
#   3 args (historique) — retire les N premieres secondes, garde [N, fin] :
#     ./bbb_recut_sync.sh 2026-07-14 01 1
#
#   4 args (nouveau) — retire le segment [start, end] AU MILIEU et raccorde
#   la partie avant et la partie apres :
#     ./bbb_recut_sync.sh 2026-07-15 01 0:50:58 0:53:13
#
# start/end acceptent des secondes, MM:SS ou H:MM:SS.
# Le raccord est reencode (coupe nette a l'image pres, sans dependance aux
# images-cles). DRY_RUN=1 affiche le plan sans rien ecrire.
#
# XFADE=<secondes> ajoute un fondu enchaine (cross dissolve) au raccord du mode
# milieu, video et audio. Le fondu consomme XFADE s de part et d'autre du
# raccord (la video finale est donc raccourcie d'autant en plus du segment
# retire). Ignore si l'une des deux parties est plus courte que XFADE.
#     XFADE=0.5 ./bbb_recut_sync.sh 2026-07-15 01 0:50:58 0:53:13
#
# La coupe s'applique a la timeline INTERNE de chaque fichier. Les pistes
# principales (webcam/deskshare/slides/final) partagent la meme fenetre, donc la
# coupe les garde alignees. Le sous-dossier webcams/ est EXCLU : ces segments
# camera ont une timeline partielle et seraient desynchronises. Apres un recut,
# relancez la phase 2b (bbb_split_webcams.sh) pour les regenerer.

set -euo pipefail

[ $# -lt 3 ] && { echo "Usage: $0 <dossier> <NUM> <start> [end]" >&2; exit 1; }

rec_dir="$1"
num="$2"
dry_run="${DRY_RUN:-0}"
xfade="${XFADE:-0}"

to_sec() {  # secondes | MM:SS | H:MM:SS -> secondes (float)
  local t="$1"
  case "$t" in
    *:*:*) awk -F: '{printf "%.3f", $1*3600+$2*60+$3}' <<<"$t" ;;
    *:*)   awk -F: '{printf "%.3f", $1*60+$2}' <<<"$t" ;;
    *)     printf "%.3f" "$t" ;;
  esac
}

start="$(to_sec "$3")"
if [ $# -ge 4 ]; then
  mode="middle"
  end="$(to_sec "$4")"
  awk -v s="$start" -v e="$end" 'BEGIN{exit !(e>s)}' \
    || { echo "Erreur: end ($4) doit etre > start ($3)." >&2; exit 1; }
else
  mode="head"     # comportement historique : garde [start, fin]
fi

base="$rec_dir/output/$num"
[ -d "$base" ] || { echo "Erreur: dossier introuvable: $base" >&2; exit 1; }

files=()
while IFS= read -r f; do
  files+=("$f")
done < <(find "$base" -type f -name '*.mp4' -not -path "$base/webcams/*" | sort)
# On exclut webcams/ : ces segments camera ont une timeline PARTIELLE (offset
# encode dans le nom), pas la fenetre complete du clip. Y appliquer la meme
# coupe les desynchroniserait. Apres un recut, refaites la phase 2b pour les
# regenerer depuis le webcam.mp4 deja coupe.
[ ${#files[@]} -gt 0 ] || { echo "Aucune video .mp4 dans $base"; exit 0; }

echo "Presentation: $num"
if [ "$mode" = "middle" ]; then
  echo "Mode        : retrait du segment [$3 .. $4] (${start}s .. ${end}s)"
else
  echo "Mode        : retrait des ${start}s de tete (garde [${start}s, fin])"
fi
echo "Fichiers    : ${#files[@]}"

VENC=(-c:v h264_videotoolbox -b:v 10M)
AENC=(-c:a aac -b:a 160k)

probe_dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
has_audio() {
  ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" \
    | grep -q .
}

for f in "${files[@]}"; do
  rel="${f#$rec_dir/}"
  d="$(probe_dur "$f")"
  tmp="${f%.mp4}.recut.tmp.mp4"

  # Construire la liste des plages a GARDER.
  keep=()   # "a b" par plage
  if [ "$mode" = "head" ]; then
    # Garde [start, fin] (si le fichier est plus court que start, rien a faire).
    awk -v s="$start" -v d="$d" 'BEGIN{exit !(s<d-0.0005)}' && keep+=("$start $d")
  else
    # Retire [start, end] : garde [0,start] puis [end,fin], bornes clampees.
    s="$(awk -v x="$start" -v d="$d" 'BEGIN{if(x<0)x=0; if(x>d)x=d; printf "%.3f",x}')"
    e="$(awk -v x="$end"   -v d="$d" 'BEGIN{if(x<0)x=0; if(x>d)x=d; printf "%.3f",x}')"
    awk -v s="$s" 'BEGIN{exit !(s>0.0005)}'            && keep+=("0.000 $s")
    awk -v e="$e" -v d="$d" 'BEGIN{exit !(e<d-0.0005)}' && keep+=("$e $d")
  fi

  if [ ${#keep[@]} -eq 0 ]; then
    echo "  -> $rel  (SAUTE : la coupe couvre tout le fichier)"
    continue
  fi

  # Fondu enchaine : seulement au raccord du mode milieu (2 plages), et
  # seulement si chaque partie est plus longue que la duree du fondu.
  use_xf=0; off="0"
  if [ ${#keep[@]} -eq 2 ] && awk -v x="$xfade" 'BEGIN{exit !(x>0)}'; then
    read -r a0 b0 <<<"${keep[0]}"
    read -r a1 b1 <<<"${keep[1]}"
    lenA="$(awk -v a="$a0" -v b="$b0" 'BEGIN{printf "%.3f", b-a}')"
    lenB="$(awk -v a="$a1" -v b="$b1" 'BEGIN{printf "%.3f", b-a}')"
    if awk -v x="$xfade" -v A="$lenA" -v B="$lenB" 'BEGIN{exit !(A>x && B>x)}'; then
      use_xf=1
      off="$(awk -v A="$lenA" -v x="$xfade" 'BEGIN{printf "%.3f", A-x}')"
    else
      xf_skip=1   # trop court : signale plus bas
    fi
  fi

  # Affichage du plan.
  plan=""
  for r in "${keep[@]}"; do plan+="[${r% *}..${r#* }] "; done
  new_dur="$(awk -v xf="$xfade" -v u="$use_xf" 'BEGIN{t=0} {t+=$2-$1} END{if(u==1)t-=xf; printf "%.1f",t}' < <(printf '%s\n' "${keep[@]}"))"
  xf_note=""; [ "$use_xf" = "1" ] && xf_note="  +fondu ${xfade}s"
  [ "${xf_skip:-0}" = "1" ] && xf_note="  (fondu ignore : partie < ${xfade}s)"
  echo "  -> $rel  ${d%.*}s -> ~${new_dur}s  garde: $plan$xf_note"
  unset xf_skip
  [ "$dry_run" = "1" ] && continue

  if [ ${#keep[@]} -eq 1 ]; then
    # Une seule plage : coupe simple -ss/-t (reencodee).
    read -r a b <<<"${keep[0]}"
    len="$(awk -v a="$a" -v b="$b" 'BEGIN{printf "%.3f", b-a}')"
    ffmpeg -y -nostdin -v error -ss "$a" -i "$f" -t "$len" \
      -map 0:v:0 -map 0:a? "${VENC[@]}" "${AENC[@]}" \
      -movflags +faststart "$tmp"
  else
    # Deux plages. Raccord : coupe nette (concat) ou fondu enchaine (xfade).
    read -r a0 b0 <<<"${keep[0]}"
    read -r a1 b1 <<<"${keep[1]}"
    fc="[0:v]trim=start=${a0}:end=${b0},setpts=PTS-STARTPTS[v0];"
    fc+="[0:v]trim=start=${a1}:end=${b1},setpts=PTS-STARTPTS[v1];"
    if [ "$use_xf" = "1" ]; then
      fc+="[v0][v1]xfade=transition=fade:duration=${xfade}:offset=${off}[v]"
    else
      fc+="[v0][v1]concat=n=2:v=1:a=0[v]"
    fi
    if has_audio "$f"; then
      fc+=";[0:a]atrim=start=${a0}:end=${b0},asetpts=PTS-STARTPTS[a0];"
      fc+="[0:a]atrim=start=${a1}:end=${b1},asetpts=PTS-STARTPTS[a1];"
      if [ "$use_xf" = "1" ]; then
        fc+="[a0][a1]acrossfade=d=${xfade}[a]"
      else
        fc+="[a0][a1]concat=n=2:v=0:a=1[a]"
      fi
      ffmpeg -y -nostdin -v error -i "$f" -filter_complex "$fc" \
        -map "[v]" -map "[a]" "${VENC[@]}" "${AENC[@]}" \
        -movflags +faststart "$tmp"
    else
      ffmpeg -y -nostdin -v error -i "$f" -filter_complex "$fc" \
        -map "[v]" "${VENC[@]}" \
        -movflags +faststart "$tmp"
    fi
  fi
  mv "$tmp" "$f"
done

[ "$dry_run" = "1" ] && echo "DRY_RUN=1: aucune modification ecrite." || echo "Termine."
