#!/usr/bin/env bash
# Prépare un enregistrement BBB avant le pipeline complet.
#
# Crée le dossier de session, récupère les métadonnées minimales, génère un
# presentations_cut.yaml de base et crée les dossiers output/NN/ pour pouvoir y
# déposer un intro.jpg avant de lancer bbb_all.sh.
#
# Usage: bbb_init.sh <recording_id | playback_url | config.yaml> [dossier]

set -euo pipefail

BBB_HOST="${BBB_HOST:-https://bbb3.services-conseils-linux.org}"

usage() {
  echo "Usage: $0 <recording_id | playback_url | config.yaml> [dossier]" >&2
  echo "  Un config.yaml doit contenir 'recording_id:' (ou 'meeting_id:')." >&2
  echo "  Sans dossier, il est nommé d'après la date de l'enregistrement." >&2
  exit 1
}

yaml_recording_id() {
  grep -E '^[[:space:]]*(recording_id|meeting_id)[[:space:]]*:' "$1" 2>/dev/null \
    | head -n1 \
    | sed -E 's/^[^:]*:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/'
}

arg="${1:-}"
config_src=""
config_abs=""

if [ -n "$arg" ] && [ -f "$arg" ] && { [[ "$arg" == *.yaml ]] || [[ "$arg" == *.yml ]]; }; then
  config_src="$arg"
elif [ -z "$arg" ] && [ -f "presentations_cut.yaml" ]; then
  config_src="presentations_cut.yaml"
fi

if [ -n "$config_src" ]; then
  config_abs="$(cd "$(dirname "$config_src")" && pwd)/$(basename "$config_src")"
  arg="$(yaml_recording_id "$config_abs")"
  [ -n "$arg" ] || { echo "Erreur: aucun 'recording_id:' (ou 'meeting_id:') dans $config_src." >&2; usage; }
fi

[ -n "$arg" ] || usage

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
  id_from_url="$arg"
  baseurl="$BBB_HOST"
  url="$BBB_HOST/playback/presentation/2.3/$id_from_url"
fi

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

download_file() {
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
  return "$rc"
}

echo "== Métadonnées minimales =="
download_file "$baseurl/presentation/$id_from_url/shapes.svg" shapes.svg 0
download_file "$baseurl/presentation/$id_from_url/presentation_text.json" presentation_text.json 1 || true

echo "== Préparation des dossiers =="
ordered_ids="$(grep -oE '<image[^>]*>' shapes.svg | \
  sed -nE 's/.*href="presentation\/([^/]+)\/svgs\/.*/\1/p' | awk '!seen[$0]++')"
seq=0
while read -r pid; do
  [ -z "$pid" ] && continue
  seq=$((seq+1))
  nn="$(printf '%02d' "$seq")"
  mkdir -p "$nn" "output/$nn"
done <<< "$ordered_ids"
mkdir -p output
: > output/manifest.txt

echo "== Génération de presentations_cut.yaml =="
hms() { awk -v s="$1" 'BEGIN{printf "%d:%02d:%02d", s/3600, (s%3600)/60, s%60}'; }

boundaries="$(grep -oE '<image[^>]*>' shapes.svg | \
  sed -nE 's/.*in="([0-9.]+)".*out="([0-9.]+)".*href="presentation\/([^/]+)\/svgs\/.*/\1 \2 \3/p' | \
  sort -k1 -n | awk '
    function flush() {
      if(cur != "" && en > st) printf "%s %.3f %.3f\n", cur, st, en
    }
    {
      s=$1; e=$2; pid=$3
      if(cur == "") { cur=pid; st=s; en=e; next }
      if(pid != cur) { flush(); cur=pid; st=s; en=e; next }
      if(e>en) en=e
    }
    END { flush() }')"

yaml_date="$(echo "$dest" | sed -nE 's/^([0-9]{4})-([0-9]{2})-([0-9]{2})$/\1\2\3/p')"
if [ -z "$yaml_date" ]; then
  ts_guess="${id_from_url##*-}"
  if [[ "$ts_guess" =~ ^[0-9]{10,}$ ]]; then
    yaml_date="$(date -r "$((ts_guess/1000))" +%Y%m%d 2>/dev/null || true)"
  fi
fi
[ -z "$yaml_date" ] && yaml_date="$(date +%Y%m%d)"

if [ -f presentations_cut.yaml ]; then
  echo "== presentations_cut.yaml déjà présent — CONSERVÉ =="
else
  {
    echo "# Préparation initiale. Remplissez DEBUT/FIN, presenter et short_title avant bbb_all.sh."
    echo "# Les dossiers output/NN/ ont déjà été créés pour pouvoir y déposer intro.jpg."
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
      nn="$(printf '%02d' "$i")"
      label="diapos détectées dans shapes.svg"
      if [ -f presentation_text.json ] && command -v jq >/dev/null 2>&1; then
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
      fi
      echo "  - num: \"$nn\""
      echo "    start: \"$(hms "$s")\""
      echo "    end: \"$(hms "$e")\""
      echo "    presenter: \"\""
      echo "    short_title: \"\""
      echo "    info: \"$label\""
      echo "    webcams_grid: \"\""
      echo "    webcams_plan: []"
      echo "    webcams_priority: []"
    done <<< "$boundaries"
  } > presentations_cut.yaml

  {
    echo "# Préparation initiale. Éditez presentations_cut.yaml avant bbb_all.sh."
    printf '# %-4s| %-9s| %-9s| %-20s| %s\n' "NUM" "DEBUT" "FIN" "NOM" "INFO"
    i=0
    while read -r pid s e; do
      [ -z "$pid" ] && continue
      i=$((i+1))
      label="diapos détectées dans shapes.svg"
      if [ -f presentation_text.json ] && command -v jq >/dev/null 2>&1; then
        label="$(jq -r --arg p "$pid" '.[$p]|if (type=="object" or type=="array") then length else 0 end' presentation_text.json) diapos"
      fi
      printf '%-6s| %-9s| %-9s| %-20s| %s\n' "$(printf '%02d' "$i")" "$(hms "$s")" "$(hms "$e")" "" "$label"
    done <<< "$boundaries"
  }
fi

echo
echo "Terminé. Copiez vos intro.jpg dans output/NN/ puis éditez presentations_cut.yaml avant bbb_all.sh."
