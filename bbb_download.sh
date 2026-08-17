#!/usr/bin/env bash
# PHASE 1 — Télécharge tout ce qu'il faut pour découper un enregistrement BBB.
#
# Récupère dans <dossier> :
#   webcams.mp4, deskshare.mp4        (vidéos de session)
#   shapes.svg, deskshare.xml, presentation_text.json  (timing)
#   <presentation_id>/slideN.svg      (diapos, un sous-dossier par présentation)
# puis génère presentations_cut.yaml.
#
# Ensuite : éditer presentations_cut.yaml, puis lancer bbb_make_clips.sh (PHASE 2).
#
# Usage: bbb_download.sh <playback_url | recording_id | config.yaml> [dossier]
#   On peut donner l'URL complète, juste l'ID d'enregistrement (…-<timestamp>),
#   OU un config.yaml contenant un champ « recording_id: » (alias « meeting_id: »).
#   Sans argument, ./presentations_cut.yaml du dossier courant est utilisé s'il existe.
#   Sans dossier, il est nommé d'après la date de l'enregistrement (ex: 2026-07-07).
#   Hôte par défaut pour un ID seul : $BBB_HOST.
#   ex: bbb_download.sh <recording_id>
#       bbb_download.sh rlq-20260715.yaml
#       bbb_download.sh "https://bbb3.services-conseils-linux.org/playback/presentation/2.3/<id>" 07-Jun-2026

set -euo pipefail

BBB_HOST="${BBB_HOST:-https://bbb3.services-conseils-linux.org}"

usage() {
  echo "Usage: $0 <playback_url | recording_id | config.yaml> [dossier]" >&2
  echo "  Un config.yaml doit contenir 'recording_id:' (ou 'meeting_id:')." >&2
  echo "  Sans argument: ./presentations_cut.yaml est lu s'il existe." >&2
  echo "  Hôte par défaut (ID seul): $BBB_HOST  (override: BBB_HOST=...)" >&2
  exit 1
}

# Extrait la valeur d'un champ recording_id: / meeting_id: en tête d'un YAML.
yaml_recording_id() {
  grep -E '^[[:space:]]*(recording_id|meeting_id)[[:space:]]*:' "$1" 2>/dev/null \
    | head -n1 \
    | sed -E 's/^[^:]*:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/'
}

# --- Résoudre l'ID : argument direct, ou champ recording_id: d'un config YAML ---
arg="${1:-}"
config_abs=""       # chemin absolu du config à installer dans le dossier (si fourni)

if [ -n "$arg" ] && [ -f "$arg" ] && { [[ "$arg" == *.yaml ]] || [[ "$arg" == *.yml ]]; }; then
  config_src="$arg"
elif [ -z "$arg" ] && [ -f "presentations_cut.yaml" ]; then
  config_src="presentations_cut.yaml"
else
  config_src=""
fi

if [ -n "$config_src" ]; then
  config_abs="$(cd "$(dirname "$config_src")" && pwd)/$(basename "$config_src")"
  arg="$(yaml_recording_id "$config_abs")"
  [ -n "$arg" ] || { echo "Erreur: aucun 'recording_id:' (ou 'meeting_id:') dans $config_src." >&2; usage; }
fi

[ -z "$arg" ] && usage
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

# Un config.yaml fourni en argument est installé comme presentations_cut.yaml du
# dossier (sauvegarde horodatée si un fichier différent existe déjà — jamais
# d'écrasement silencieux). Il fait ensuite foi pour les phases suivantes.
if [ -n "$config_abs" ]; then
  target="presentations_cut.yaml"
  if [ ! "$config_abs" -ef "$(pwd)/$target" ]; then
    if [ -f "$target" ] && ! cmp -s "$config_abs" "$target"; then
      bak="$target.$(date +%Y%m%d-%H%M%S).bak"; cp "$target" "$bak"
      echo "   (ancien $target sauvegardé → $bak)"
    fi
    cp "$config_abs" "$target"
    echo "== Config installé : $target (depuis $config_abs) =="
  fi
fi

avail_kb="$(df -Pk . | awk 'NR==2{print $4}')"
if [ "${avail_kb:-0}" -lt 5242880 ]; then
  echo "Avertissement: espace disque faible ($(awk -v k="${avail_kb:-0}" 'BEGIN{printf "%.1f GiB", k/1024/1024}'))." >&2
  echo "  Les vidéos BBB peuvent prendre plusieurs GiB; libérez de l'espace avant de continuer si curl échoue." >&2
fi

download_file() {  # <url> <output> <optional:0|1>
  local src="$1" out="$2" optional="${3:-0}" tmp rc
  [ -f "$out" ] && return 0
  tmp="${out}.part"

  if curl -fSL "$src" -o "$tmp"; then
    mv "$tmp" "$out"
    return 0
  fi

  rc=$?
  if [ "$rc" -eq 22 ] && [ "$optional" = "1" ]; then
    rm -f "$tmp"
    return 1
  fi

  echo "Erreur: téléchargement échoué pour $out (curl rc=$rc)." >&2
  echo "  Si curl affiche 'Failure writing output to destination', libérez de l'espace disque puis relancez." >&2
  return "$rc"
}

echo "== Vidéos =="
download_file "$baseurl/$pres/video/webcams.mp4" webcams.mp4 0
download_file "$baseurl/$pres/deskshare/deskshare.mp4" deskshare.mp4 1 || \
  echo "  (pas de deskshare.mp4 — aucun partage d'écran dans cette session)"

echo "== Métadonnées de timing =="
for f in shapes.svg deskshare.xml presentation_text.json; do
  download_file "$baseurl/$pres/$f" "$f" 1 || echo "  (pas de $f)"
done
[ -f shapes.svg ] || { echo "Erreur: shapes.svg manquant, impossible de continuer." >&2; exit 1; }

echo "== Diapos (SVG) — un dossier numéroté par présentation (ordre de session) =="
# Ordre de session = première apparition dans shapes.svg, pour que le dossier NN
# corresponde à la présentation NN.
ordered_ids="$(grep -oE '<image[^>]*>' shapes.svg | \
  sed -nE 's/.*href="presentation\/([^/]+)\/svgs\/.*/\1/p' | awk '!seen[$0]++')"
seq=0
while read -r pid; do
  [ -z "$pid" ] && continue
  seq=$((seq+1)); nn="$(printf '%02d' "$seq")"
  text_count="0"
  if [ -f presentation_text.json ]; then
    text_count="$(jq -r --arg p "$pid" '.[$p]|if (type=="object" or type=="array") then length else 0 end' presentation_text.json)"
  fi
  shape_count="$(grep -oE '<image[^>]*>' shapes.svg | \
    sed -nE 's/.*href="presentation\/([^/]+)\/svgs\/slide([0-9]+)\.svg".*/\1 \2/p' | \
    awk -v p="$pid" '$1==p && $2>m{m=$2} END{print m+0}')"
  count="$text_count"
  if [ "$shape_count" -gt "$count" ]; then
    count="$shape_count"
  fi
  mkdir -p "$nn"
  for ((i=1; i<=count; i++)); do
    out="$nn/slide${i}.svg"
    download_file "$baseurl/$pres/presentation/$pid/svgs/slide${i}.svg" "$out" 1 || true
  done
  echo "  $nn ($pid) : $count diapos"
done <<< "$ordered_ids"

if [ -f presentations_cut.yaml ]; then
  echo "== presentations_cut.yaml déjà présent — CONSERVÉ (vos modifications ne sont pas touchées) =="
else
echo "== Génération de presentations_cut.yaml =="
video_dur="$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 webcams.mp4)"
hms() { awk -v s="$1" 'BEGIN{printf "%d:%02d:%02d", s/3600, (s%3600)/60, s%60}'; }

boundaries="$(grep -oE '<image[^>]*>' shapes.svg | \
  sed -nE 's/.*in="([0-9.]+)".*out="([0-9.]+)".*href="presentation\/([^/]+)\/svgs\/.*/\1 \2 \3/p' | \
  sort -k1 -n | awk -v vdur="$video_dur" '
    function flush() {
      if(cur != "" && en > st) printf "%s %.3f %.3f\n", cur, st, en
    }
    {
      s=$1; e=$2; pid=$3
      if(e>vdur)e=vdur
      if(cur == "") { cur=pid; st=s; en=e; next }
      if(pid != cur) { flush(); cur=pid; st=s; en=e; next }
      if(e>en) en=e
    }
    END { flush() }')"

# Date par défaut pour le naming YAML (YYYYMMDD)
yaml_date="$(echo "$dest" | sed -nE 's/^([0-9]{4})-([0-9]{2})-([0-9]{2})$/\1\2\3/p')"
if [ -z "$yaml_date" ]; then
  ts_guess="${id_from_url##*-}"
  if [[ "$ts_guess" =~ ^[0-9]{10,}$ ]]; then
    yaml_date="$(date -r "$((ts_guess/1000))" +%Y%m%d 2>/dev/null || true)"
  fi
fi
[ -z "$yaml_date" ] && yaml_date="$(date +%Y%m%d)"

{
  echo "# PHASE 1 terminée. AJUSTEZ les colonnes DEBUT et FIN (format H:MM:SS ou secondes)."
  echo "# NOM = nom du présentateur (bandeau en bas à gauche de la vidéo finale) — à remplir."
  echo "# Le NUM nomme les sorties (dossier output/NUM). Les lignes # sont ignorées."
  echo "# SCINDER une présentation en plusieurs clips : ajoutez une ligne avec un NUM"
  echo "#   unique (ex: 05b) et une sous-plage DEBUT/FIN. Les diapos sont rendues"
  echo "#   depuis la timeline shapes.svg complète, même si la coupe traverse un"
  echo "#   changement de deck."
  echo "# PHASE 2 : ./bbb_make_clips.sh <dossier> encode [NUM...]  (ex: ... encode 5 6)"
  echo "#"
  printf '# %-4s| %-9s| %-9s| %-20s| %s\n' "NUM" "DEBUT" "FIN" "NOM" "INFO"
  i=0
  while read -r pid s e; do
    i=$((i+1))
    label="$(jq -r --arg p "$pid" '
      .[$p] as $v |
      if ($v|type)=="object" or ($v|type)=="array" then
        ($v|length) as $n |
        (if ($v|type)=="object" then ($v|to_entries[0].value)
         elif ($v|type)=="array" then $v[0] else "" end) as $t |
        "\($n) diapos — \(($t|tostring)|gsub("[\\n\\r]+";" ")|.[0:45])"
      else
        "diapos détectées dans shapes.svg"
      end' presentation_text.json)"
    printf '%-6s| %-9s| %-9s| %-20s| %s\n' "$(printf '%02d' "$i")" "$(hms "$s")" "$(hms "$e")" "" "$label"
  done <<< "$boundaries"
{
  echo "# PHASE 1 terminée. Éditez ce fichier YAML puis lancez la PHASE 2."
  echo "# webcams_priority permet de choisir quel flux cam va au slot 1,2,3"
  echo "# en phase 3 (composition), ex: [2,1,3]."
  echo "# recording_id : l'ID BBB (…-<timestamp>) — bbb_download/bbb_all le relisent"
  echo "#   ici, plus besoin de le passer en argument."
  echo "recording_id: \"$id_from_url\""
  echo "brand: \"RLQ\""
  echo "city: \"MTL\""
  echo "date: \"$yaml_date\""
  echo "language: \"FR\""
  echo "format: \"1080p\""
  echo "encoding: \"h264\""
  echo "presentations:"
  i=0
  while read -r pid s e; do
    [ -z "$pid" ] && continue
    i=$((i+1))
    num="$(printf '%02d' "$i")"
    echo "  - num: \"$num\""
    echo "    start: \"$(hms "$s")\""
    echo "    end: \"$(hms "$e")\""
    echo "    presenter: \"\""
    echo "    info: \"diapos détectées dans shapes.svg\""
    echo "    webcams_grid: \"\""
    echo "    webcams_plan: []"
    echo "    webcams_priority: []"
  done <<< "$boundaries"
}
} > presentations_cut.yaml
fi

echo
echo "Terminé. Éditez $(pwd)/presentations_cut.yaml puis lancez la PHASE 2 (bbb_make_clips.sh)."
