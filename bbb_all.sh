#!/usr/bin/env bash
# Tout-en-un : à partir d'un ID d'enregistrement BBB et d'un fichier de config
# (coupes + présentateurs), fait TOUT le pipeline :
#   phase 1  (bbb_download.sh)      — télécharge l'enregistrement
#   phase 2  (bbb_make_clips.sh)    — clips alignés webcam/deskshare/slides
#   phase 2b (bbb_split_webcams.sh) — isole les caméras
#   phase 3  (bbb_compose.sh)       — vidéos finales composées
#
# WORKFLOW : visionnez l'enregistrement BBB (via son URL de lecture), notez les
# points de coupe, préparez le fichier de config, puis lancez ce script — il
# télécharge et compose tout, sans autre intervention.
#
# Usage :
#   ./bbb_all.sh <config.yaml> [NUM...]                       # id lu dans le config
#   ./bbb_all.sh <meeting_id | playback_url> <config.yaml> [NUM...]
#   ./bbb_all.sh 0fd9362b…-1784147446537 rlq-20260715.yaml
#
# Forme courte : si le config.yaml contient un champ « recording_id: » (alias
# « meeting_id: »), l'ID n'a pas à être passé en argument.
#
# <config.yaml> est un presentations_cut.yaml (voir le README) : paramètres
# globaux (brand/city/date/language/format/encoding) et une liste de
# présentations (num/start/end/presenter/short_title/info/webcams_priority).
# Il est installé dans le dossier téléchargé comme presentations_cut.yaml.
# Sans NUM, toutes les présentations du config sont traitées.
#
# Variables héritées : MODE=encode|copy (phase 2), SKIP_SPLIT=1 (pas de 2b),
# SKIP_COMPOSE=1 (s'arrête après les clips), PYTHON, BBB_HOST, BBB_VENC, XFADE…

set -euo pipefail

usage() {
  echo "Usage: $0 <config.yaml> [NUM...]" >&2
  echo "       $0 <meeting_id | playback_url> <config.yaml> [NUM...]" >&2
  echo "  Forme courte: le config.yaml contient 'recording_id:' (ou 'meeting_id:')." >&2
  echo "  ex: $0 rlq-20260715.yaml" >&2
  echo "      $0 0fd9362b…-1784147446537 rlq-20260715.yaml" >&2
  exit 1
}
[ $# -lt 1 ] && usage

here="$(cd "$(dirname "$0")" && pwd)"

# Deux formes : <config.yaml> [NUM...]  ou  <id|url> <config.yaml> [NUM...].
# Un ID/URL n'est jamais un fichier .yaml existant : la distinction est sûre.
if [ -f "$1" ] && { [[ "$1" == *.yaml ]] || [[ "$1" == *.yml ]]; }; then
  config="$1"; shift
  id="$(grep -E '^[[:space:]]*(recording_id|meeting_id)[[:space:]]*:' "$config" 2>/dev/null \
        | head -n1 | sed -E 's/^[^:]*:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/')"
  [ -n "$id" ] || { echo "Erreur: aucun 'recording_id:' (ou 'meeting_id:') dans $config." >&2; usage; }
else
  [ $# -lt 2 ] && usage
  id="$1"; config="$2"; shift 2
fi
mode="${MODE:-encode}"

[ -f "$config" ] || { echo "Erreur: config introuvable: $config" >&2; exit 1; }

# Dossier de sortie : même règle que bbb_download.sh (date tirée du timestamp de
# l'ID), pour que bbb_all sache exactement où tout atterrit.
idbase="${id##*/}"           # accepte une URL complète ou un ID nu
ts="${idbase##*-}"
if [[ "$ts" =~ ^[0-9]{10,}$ ]]; then
  dossier="$(date -r "$((ts/1000))" +%Y-%m-%d 2>/dev/null || echo "$idbase")"
else
  dossier="$idbase"
fi

echo "== bbb_all =="
echo "   Enregistrement : $id"
echo "   Config         : $config"
echo "   Dossier        : $dossier"

# Installer le config AVANT le téléchargement : bbb_download.sh conserve un
# presentations_cut.yaml existant, donc le config fait foi. On sauvegarde tout
# fichier de coupe préexistant qui diffèrerait (jamais d'écrasement silencieux).
mkdir -p "$dossier"
cut="$dossier/presentations_cut.yaml"
if [ ! "$config" -ef "$cut" ]; then
  if [ -f "$cut" ] && ! cmp -s "$config" "$cut"; then
    bak="$cut.$(date +%Y%m%d-%H%M%S).bak"
    cp "$cut" "$bak"
    echo "   (ancien presentations_cut.yaml sauvegardé → $bak)"
  fi
  cp "$config" "$cut"
fi

echo
echo "########## Phase 1 : téléchargement ##########"
"$here/bbb_download.sh" "$id" "$dossier"

# Présentations à traiter : celles passées en argument, sinon toutes celles du
# config (champ num:).
if [ "$#" -gt 0 ]; then
  nums=("$@")
else
  # bash 3.2 (macOS) : pas de mapfile — on lit dans une boucle.
  nums=()
  while IFS= read -r n; do
    [ -n "$n" ] && nums+=("$n")
  done < <(
    grep -E '^[[:space:]]*-?[[:space:]]*num:' "$cut" \
      | sed -E 's/.*num:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/'
  )
fi
[ "${#nums[@]}" -gt 0 ] || { echo "Erreur: aucune présentation (num) dans $cut." >&2; exit 1; }
echo
echo "Présentations à composer : ${nums[*]}"

for num in "${nums[@]}"; do
  echo
  echo "########## Présentation $num ##########"

  echo "--- Phase 2 : clips ---"
  "$here/bbb_make_clips.sh" "$dossier" "$mode" "$num"

  if [ "${SKIP_SPLIT:-0}" = "1" ]; then
    echo "--- Phase 2b : sautée (SKIP_SPLIT=1) ---"
  else
    echo "--- Phase 2b : caméras ---"
    "$here/bbb_split_webcams.sh" "$dossier" "$num"
  fi

  if [ "${SKIP_COMPOSE:-0}" = "1" ]; then
    echo "--- Phase 3 : sautée (SKIP_COMPOSE=1) ---"
  else
    echo "--- Phase 3 : composition ---"
    "$here/bbb_compose.sh" "$dossier" "$num"
  fi
done

echo
echo "== bbb_all terminé : $dossier/output/ (présentations : ${nums[*]}) =="
