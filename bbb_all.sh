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
#   ./bbb_all.sh --preview <config.yaml> [NUM...]             # aperçu rapide
#   ./bbb_all.sh --preview <meeting_id | playback_url> <config.yaml> [NUM...]
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
# Review optionnelle webcams (entre 2b et 3) : REVIEW_WEBCAMS=1 génère
# output/NN/webcams/review/{contact-sheet.jpg,webcams-review.mp4}.
# REVIEW_WEBCAMS_PAUSE=1 arrête le pipeline après cette review (avant phase 3).
# Mode preview : PREVIEW=1 (ou --preview), PREVIEW_SECONDS=10, CLIP_LIMIT,
# COMPOSE_LIMIT, COMPOSE_CRF, COMPOSE_PRESET, COMPOSE_BITRATE.
# PREVIEW_ASSEMBLE=1 concatène les aperçus en une seule vidéo.
# PREVIEW_FROM_WEBCAMS_PLAN=1 : si un seul NUM est demandé et qu'il contient un
# webcams_plan, génère 1 mini-cut de preview (10 s) par entrée du plan.

set -euo pipefail

restore_cut_backup=""
preview_cfg_tmp=""
cut=""
cleanup() {
  if [ -n "$restore_cut_backup" ] && [ -n "$cut" ] && [ -f "$restore_cut_backup" ]; then
    cp "$restore_cut_backup" "$cut" || true
    rm -f "$restore_cut_backup" || true
  fi
  [ -n "$preview_cfg_tmp" ] && rm -f "$preview_cfg_tmp" || true
}
trap cleanup EXIT

usage() {
  echo "Usage: $0 [--preview] <config.yaml> [NUM...]" >&2
  echo "       $0 [--preview] <meeting_id | playback_url> <config.yaml> [NUM...]" >&2
  echo "Usage: $0 <config.yaml> [NUM...]" >&2
  echo "       $0 <meeting_id | playback_url> <config.yaml> [NUM...]" >&2
  echo "  Forme courte: le config.yaml contient 'recording_id:' (ou 'meeting_id:')." >&2
  echo "  ex: $0 rlq-20260715.yaml" >&2
  echo "      $0 0fd9362b…-1784147446537 rlq-20260715.yaml" >&2
  exit 1
}
[ "${1:-}" = "--preview" ] && { preview_flag=1; shift; } || preview_flag=0
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

preview="${PREVIEW:-$preview_flag}"
if [ "$preview" = "1" ]; then
  preview_seconds="${PREVIEW_SECONDS:-10}"
  preview_assemble="${PREVIEW_ASSEMBLE:-1}"
  preview_from_webcams_plan="${PREVIEW_FROM_WEBCAMS_PLAN:-1}"
  mode="${MODE:-copy}"
  export CLIP_LIMIT="${CLIP_LIMIT:-$preview_seconds}"
  export COMPOSE_LIMIT="${COMPOSE_LIMIT:-$preview_seconds}"
  export COMPOSE_CRF="${COMPOSE_CRF:-33}"
  export COMPOSE_PRESET="${COMPOSE_PRESET:-ultrafast}"
  export COMPOSE_BITRATE="${COMPOSE_BITRATE:-1800k}"
  export BBB_AUDIO_TRACK="${BBB_AUDIO_TRACK:-0}"
  export STEP="${STEP:-8}"
else
  preview_assemble="0"
  preview_from_webcams_plan="0"
  mode="${MODE:-encode}"
fi

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
if [ "$preview" = "1" ]; then
  echo "   Mode           : PREVIEW rapide"
  echo "   Paramètres     : CLIP_LIMIT=${CLIP_LIMIT}s, COMPOSE_LIMIT=${COMPOSE_LIMIT}s, COMPOSE_CRF=${COMPOSE_CRF}, COMPOSE_PRESET=${COMPOSE_PRESET}, COMPOSE_BITRATE=${COMPOSE_BITRATE}, STEP=${STEP}"
  echo "   Assemblage     : PREVIEW_ASSEMBLE=${preview_assemble}"
  echo "   Webcams plan   : PREVIEW_FROM_WEBCAMS_PLAN=${preview_from_webcams_plan}"
fi

preview_parts=()

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

# Aperçu spécialisé webcams_plan : pour un NUM unique, crée des sous-cuts
# (10 s par entrée du plan, ou PREVIEW_SECONDS) et les compose/assemble.
if [ "$preview" = "1" ] && [ "$preview_from_webcams_plan" = "1" ] && [ "${#nums[@]}" -eq 1 ]; then
  preview_cfg_tmp="$(mktemp "${dossier}/presentations_cut.preview.XXXXXX.yaml")"
  expanded_nums="$(python3 - "$config" "${nums[0]}" "$preview_seconds" "$preview_cfg_tmp" <<'PY'
import copy, sys, yaml

src, target, secs, out_path = sys.argv[1], str(sys.argv[2]), float(sys.argv[3]), sys.argv[4]

def to_s(v):
  if v is None:
    return 0.0
  t = str(v).strip()
  if ':' in t:
    p = [float(x) for x in t.split(':')]
    if len(p) == 3:
      return p[0] * 3600 + p[1] * 60 + p[2]
    if len(p) == 2:
      return p[0] * 60 + p[1]
  return float(t)

def fmt(sec):
  sec = max(0.0, float(sec))
  h = int(sec // 3600)
  m = int((sec % 3600) // 60)
  s = sec - h * 3600 - m * 60
  if h > 0:
    return f"{h}:{m:02d}:{s:06.3f}".rstrip('0').rstrip('.')
  return f"{m}:{s:06.3f}".rstrip('0').rstrip('.')

with open(src, encoding='utf-8') as fh:
  doc = yaml.safe_load(fh) or {}

presentations = doc.get('presentations') or []
pres = None
for p in presentations:
  if str(p.get('num', '')).strip() == target:
    pres = p
    break

if not pres:
  print('', end='')
  sys.exit(0)

plan = pres.get('webcams_plan') or []
if not isinstance(plan, list) or not plan:
  print('', end='')
  sys.exit(0)

pres_end = to_s(pres.get('end', 0))
expanded = []
for i, item in enumerate(plan):
  if not isinstance(item, dict) or 'start' not in item:
    continue
  s = to_s(item.get('start'))
  next_s = pres_end
  if i + 1 < len(plan) and isinstance(plan[i + 1], dict) and 'start' in plan[i + 1]:
    next_s = min(next_s, to_s(plan[i + 1].get('start')))
  e = min(s + secs, next_s, pres_end)
  if e <= s:
    continue
  np = copy.deepcopy(pres)
  np['num'] = f"{target}-w{i+1:02d}"
  np['start'] = fmt(s)
  np['end'] = fmt(e)
  one = {k: v for k, v in item.items() if k in ('grid', 'active', 'bbox', 'webcam_grid')}
  one['start'] = fmt(s)
  np['webcams_plan'] = [one]
  expanded.append(np)

if not expanded:
  print('', end='')
  sys.exit(0)

out_doc = dict(doc)
out_doc['presentations'] = expanded
with open(out_path, 'w', encoding='utf-8') as fh:
  yaml.safe_dump(out_doc, fh, allow_unicode=True, sort_keys=False)

print(' '.join(str(p.get('num')) for p in expanded), end='')
PY
)"

  if [ -n "$expanded_nums" ]; then
  echo "   Preview webcams_plan: expansion de ${nums[0]} -> ${expanded_nums}"
  restore_cut_backup="$(mktemp)"
  cp "$cut" "$restore_cut_backup"
  cp "$preview_cfg_tmp" "$cut"
  nums=($expanded_nums)
  config="$preview_cfg_tmp"
  fi
fi

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

  if [ "${REVIEW_WEBCAMS:-0}" = "1" ]; then
    echo "--- Phase 2c : review webcams ---"
    "$here/bbb_review_webcams.sh" "$dossier" "$num"
    if [ "${REVIEW_WEBCAMS_PAUSE:-0}" = "1" ]; then
      echo "--- Pause demandée: REVIEW_WEBCAMS_PAUSE=1 (phase 3 non exécutée) ---"
      continue
    fi
  fi

  if [ "${SKIP_COMPOSE:-0}" = "1" ]; then
    echo "--- Phase 3 : sautée (SKIP_COMPOSE=1) ---"
  else
    echo "--- Phase 3 : composition ---"
    "$here/bbb_compose.sh" "$dossier" "$num"
    if [ "$preview" = "1" ]; then
      shopt -s nullglob
      pfiles=("$dossier/output/$num"/*.preview.mp4)
      shopt -u nullglob
      if [ "${#pfiles[@]}" -gt 0 ]; then
        preview_parts+=("${pfiles[0]}")
      else
        echo "   (aperçu introuvable pour $num, assemblage ignorera cette section)"
      fi
    fi
  fi
done

if [ "$preview" = "1" ] && [ "$preview_assemble" = "1" ] && [ "${#preview_parts[@]}" -gt 0 ]; then
  echo
  echo "########## Assemblage preview ##########"
  out_preview="$dossier/output/preview-assembled.mp4"
  ff_inputs=()
  fc=""
  i=0
  for f in "${preview_parts[@]}"; do
    ff_inputs+=("-i" "$f")
    fc+="[$i:v:0][$i:a:0]"
    i=$((i+1))
  done
  fc+="concat=n=${#preview_parts[@]}:v=1:a=1[outv][outa]"
  ffmpeg -nostdin -v error -y "${ff_inputs[@]}" \
    -filter_complex "$fc" -map "[outv]" -map "[outa]" \
    -c:v libx264 -preset veryfast -crf 28 -c:a aac -b:a 128k \
    -movflags +faststart "$out_preview"
  echo "✓ Aperçu assemblé: $out_preview"
fi

echo
echo "== bbb_all terminé : $dossier/output/ (présentations : ${nums[*]}) =="
