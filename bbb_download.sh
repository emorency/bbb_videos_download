#!/usr/bin/env bash
# PHASE 1 — Télécharge tout ce qu'il faut pour découper un enregistrement BBB.
#
# Récupère dans <dossier> :
#   webcams.mp4, deskshare.mp4        (vidéos de session)
#   shapes.svg, deskshare.xml, presentation_text.json  (timing)
#   <presentation_id>/slideN.svg      (diapos, un sous-dossier par présentation)
# puis génère presentations_cut.txt (points de coupe à éditer).
#
# Ensuite : éditer presentations_cut.txt, puis lancer bbb_make_clips.sh (PHASE 2).
#
# Usage: bbb_download.sh <playback_url | recording_id> [dossier]
#   On peut donner l'URL complète OU juste l'ID d'enregistrement (…-<timestamp>).
#   Sans dossier, il est nommé d'après la date de l'enregistrement (ex: 2026-07-07).
#   Hôte par défaut pour un ID seul : $BBB_HOST.
#   ex: bbb_download.sh <recording_id>
#       bbb_download.sh "https://bbb3.services-conseils-linux.org/playback/presentation/2.3/<id>" 07-Jun-2026

set -euo pipefail

BBB_HOST="${BBB_HOST:-https://bbb3.services-conseils-linux.org}"

usage() {
  echo "Usage: $0 <playback_url | recording_id> [dossier]" >&2
  echo "  Hôte par défaut (ID seul): $BBB_HOST  (override: BBB_HOST=...)" >&2
  exit 1
}
[ "${1:-}" = "" ] && usage

arg="$1"
if [[ "$arg" == *"://"* ]]; then
  url="$arg"
  id_from_url="${url##*/}"
  baseurl="$url"
  if [[ "$baseurl" == *"/playback/"* ]]; then
    baseurl="${baseurl%%/playback/*}"
  elif [[ "$baseurl" == *"/presentation/"* ]]; then
    baseurl="${baseurl%%/presentation/*}"
  else
    baseurl="${baseurl%/*}"
  fi
else
  # Juste un ID d'enregistrement -> on reconstruit l'URL avec l'hôte par défaut
  id_from_url="$arg"
  baseurl="$BBB_HOST"
  url="$BBB_HOST/playback/presentation/2.3/$id_from_url"
fi

# Dossier par défaut : date tirée du timestamp (…-<ms>) de l'ID
if [ -n "${2:-}" ]; then
  dest="$2"
else
  ts="${id_from_url##*-}"
  if [[ "$ts" =~ ^[0-9]{10,}$ ]]; then
    dest="$(date -r "$((ts/1000))" +%Y-%m-%d 2>/dev/null || echo "$id_from_url")"
  else
    dest="$id_from_url"
  fi
fi

echo "Enregistrement : $id_from_url"
echo "Dossier        : $dest"
mkdir -p "$dest"
cd "$dest"
[ -f README.md ] || echo "$url" > README.md
pres="presentation/$id_from_url"

echo "== Vidéos =="
[ -f webcams.mp4 ]   || curl -fSL "$baseurl/$pres/video/webcams.mp4"       -o webcams.mp4
[ -f deskshare.mp4 ] || curl -fSL "$baseurl/$pres/deskshare/deskshare.mp4" -o deskshare.mp4 || \
  echo "  (pas de deskshare.mp4 — aucun partage d'écran dans cette session)"

echo "== Métadonnées de timing =="
for f in shapes.svg deskshare.xml presentation_text.json; do
  [ -f "$f" ] || curl -fsSL "$baseurl/$pres/$f" -o "$f" || echo "  (pas de $f)"
done
[ -f shapes.svg ] || { echo "Erreur: shapes.svg manquant, impossible de continuer." >&2; exit 1; }

echo "== Diapos (SVG) — un dossier numéroté par présentation (ordre de session) =="
# Ordre de session = première apparition dans shapes.svg (identique aux NUM de
# presentations_cut.txt), pour que le dossier NN corresponde à la présentation NN.
ordered_ids="$(grep -oE '<image[^>]*>' shapes.svg | \
  sed -nE 's/.*href="presentation\/([^/]+)\/svgs\/.*/\1/p' | awk '!seen[$0]++')"
seq=0
while read -r pid; do
  [ -z "$pid" ] && continue
  seq=$((seq+1)); nn="$(printf '%02d' "$seq")"
  count="$(jq -r --arg p "$pid" '.[$p]|if (type=="object" or type=="array") then length else 0 end' presentation_text.json)"
  mkdir -p "$nn"
  for ((i=1; i<=count; i++)); do
    out="$nn/slide${i}.svg"
    [ -f "$out" ] || curl -fsSL "$baseurl/$pres/presentation/$pid/svgs/slide${i}.svg" -o "$out" || true
  done
  echo "  $nn ($pid) : $count diapos"
done <<< "$ordered_ids"

if [ -f presentations_cut.txt ]; then
  echo "== presentations_cut.txt déjà présent — CONSERVÉ (vos modifications ne sont pas touchées) =="
else
echo "== Génération de presentations_cut.txt =="
video_dur="$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 webcams.mp4)"
hms() { awk -v s="$1" 'BEGIN{printf "%d:%02d:%02d", s/3600, (s%3600)/60, s%60}'; }

boundaries="$(grep -oE '<image[^>]*>' shapes.svg | \
  sed -nE 's/.*in="([0-9.]+)".*out="([0-9.]+)".*href="presentation\/([^/]+)\/svgs\/.*/\1 \2 \3/p' | \
  awk -v vdur="$video_dur" '
    { pid=$3; if(!(pid in seen)){seen[pid]=1; order[++n]=pid; start[pid]=$1}
      if($1<start[pid])start[pid]=$1; e=$2; if(e>vdur)e=vdur; if(e>end[pid])end[pid]=e }
    END{ for(i=1;i<=n;i++){p=order[i]; printf "%s %.3f %.3f\n", p, start[p], end[p]} }')"

{
  echo "# PHASE 1 terminée. AJUSTEZ les colonnes DEBUT et FIN (format H:MM:SS ou secondes)."
  echo "# Le NUM nomme les sorties (dossier resolve_clips/NUM). Les lignes # sont ignorées."
  echo "# SCINDER une présentation en plusieurs clips : ajoutez une ligne avec un NUM"
  echo "#   unique (ex: 05b) et une sous-plage DEBUT/FIN. Les diapos sont choisies"
  echo "#   automatiquement selon la plage horaire (gardez la coupe dans une seule"
  echo "#   présentation d'origine)."
  echo "# PHASE 2 : ./bbb_make_clips.sh <dossier> encode [NUM...]  (ex: ... encode 5 6)"
  echo "#"
  printf '# %-4s| %-9s| %-9s| %s\n' "NUM" "DEBUT" "FIN" "INFO"
  i=0
  while read -r pid s e; do
    i=$((i+1))
    label="$(jq -r --arg p "$pid" '
      .[$p] as $v | ($v|length) as $n |
      (if ($v|type)=="object" then ($v|to_entries[0].value)
       elif ($v|type)=="array" then $v[0] else "" end) as $t |
      "\($n) diapos — \(($t|tostring)|gsub("[\\n\\r]+";" ")|.[0:45])"' presentation_text.json)"
    printf '%-6s| %-9s| %-9s| %s\n' "$(printf '%02d' "$i")" "$(hms "$s")" "$(hms "$e")" "$label"
  done <<< "$boundaries"
} > presentations_cut.txt
fi

echo
echo "Terminé. Éditez $(pwd)/presentations_cut.txt puis lancez la PHASE 2 (bbb_make_clips.sh)."
