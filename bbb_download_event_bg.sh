#!/usr/bin/env bash
# Télécharge automatiquement l'image de fond / bannière depuis une page
# d'événement Rencontres Linux Québec (ou autre page similaire).
#
# Usage:
#   ./bbb_download_event_bg.sh <event_url> [output_file]
#
# Exemples:
#   ./bbb_download_event_bg.sh "https://www.rencontres-linux.quebec/en_CA/event/.../register"
#   ./bbb_download_event_bg.sh "https://www.rencontres-linux.quebec/..."      # -> 2026-07-14/intro.jpg
#   ./bbb_download_event_bg.sh "https://www.rencontres-linux.quebec/..." 2026-07-14/intro.jpg

set -euo pipefail

usage() {
  echo "Usage: $0 <event_url> [output_file]" >&2
  echo "Ex: $0 \"https://www.rencontres-linux.quebec/en_CA/event/.../register\"" >&2
  echo "Ex: $0 \"https://www.rencontres-linux.quebec/en_CA/event/.../register\" 2026-07-14/intro.jpg" >&2
  exit 1
}

[ "${1:-}" = "" ] && usage

event_url="$1"

infer_event_date_from_url() {
  local url="$1" lower day month year mm
  lower="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lower" =~ ([0-9]{1,2})-(janvier|fevrier|février|mars|avril|mai|juin|juillet|aout|août|septembre|octobre|novembre|decembre|décembre|january|february|march|april|may|june|july|august|september|october|november|december)-([0-9]{4}) ]]; then
    day="${BASH_REMATCH[1]}"
    month="${BASH_REMATCH[2]}"
    year="${BASH_REMATCH[3]}"

    case "$month" in
      janvier|january) mm="01" ;;
      fevrier|février|february) mm="02" ;;
      mars|march) mm="03" ;;
      avril|april) mm="04" ;;
      mai|may) mm="05" ;;
      juin|june) mm="06" ;;
      juillet|july) mm="07" ;;
      aout|août|august) mm="08" ;;
      septembre|september) mm="09" ;;
      octobre|october) mm="10" ;;
      novembre|november) mm="11" ;;
      decembre|décembre|december) mm="12" ;;
      *) return 1 ;;
    esac

    printf '%04d-%02d-%02d\n' "$year" "$((10#$mm))" "$((10#$day))"
    return 0
  fi

  return 1
}

if [ -n "${2:-}" ]; then
  output_file="$2"
else
  event_date="$(infer_event_date_from_url "$event_url" || true)"
  if [ -z "$event_date" ]; then
    echo "Erreur: impossible d'inférer la date de l'événement depuis l'URL." >&2
    echo "Donnez un fichier de sortie explicite, ex: ./bbb_download_event_bg.sh \"$event_url\" 2026-07-14/intro.jpg" >&2
    exit 1
  fi
  output_file="$event_date/intro.jpg"
fi

mkdir -p "$(dirname "$output_file")"

tmp_html="$(mktemp)"
trap 'rm -f "$tmp_html"' EXIT

echo "Page     : $event_url"
echo "Sortie   : $output_file"

curl -fLsS "$event_url" -o "$tmp_html"

resolve_url() {
  local base="$1" candidate="$2"

  # Déjà absolue
  if [[ "$candidate" =~ ^https?:// ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  # Protocole implicite (//cdn.example/...)
  if [[ "$candidate" == //* ]]; then
    printf '%s\n' "https:$candidate"
    return 0
  fi

  # Racine du site
  if [[ "$candidate" == /* ]]; then
    local root
    root="$(echo "$base" | sed -E 's#^(https?://[^/]+).*$#\1#')"
    printf '%s\n' "$root$candidate"
    return 0
  fi

  # Relative
  local dir
  dir="${base%/*}"
  printf '%s\n' "$dir/$candidate"
}

pick_candidate() {
  local html="$1"

  # Priorité 1: OpenGraph/Twitter image (souvent la bannière principale)
  local meta
  meta="$(grep -Eio '<meta[^>]+(property|name)="(og:image|twitter:image)"[^>]+>' "$html" | \
    sed -nE 's/.*content="([^"]+)".*/\1/p' | head -n1 || true)"
  if [ -n "$meta" ]; then
    printf '%s\n' "$meta"
    return 0
  fi

  # Priorité 2: style inline contenant background-image:url(...)
  local bg
  bg="$(grep -Eio 'background-image:[^;]*url\([^)]*\)' "$html" | \
    sed -nE 's/.*url\(["'"'"']?([^"'"'"')]+)["'"'"']?\).*/\1/p' | head -n1 || true)"
  if [ -n "$bg" ]; then
    printf '%s\n' "$bg"
    return 0
  fi

  # Priorité 3: première image "hero/banner/cover/background"
  local hero
  hero="$(grep -Eio '<img[^>]+(hero|banner|cover|background)[^>]*>' "$html" | \
    sed -nE 's/.*src="([^"]+)".*/\1/p' | head -n1 || true)"
  if [ -n "$hero" ]; then
    printf '%s\n' "$hero"
    return 0
  fi

  # Priorité 4: toute première image
  local any
  any="$(grep -Eio '<img[^>]+src="[^"]+"[^>]*>' "$html" | \
    sed -nE 's/.*src="([^"]+)".*/\1/p' | head -n1 || true)"
  if [ -n "$any" ]; then
    printf '%s\n' "$any"
    return 0
  fi

  return 1
}

candidate="$(pick_candidate "$tmp_html" || true)"
[ -z "$candidate" ] && { echo "Erreur: impossible de trouver une image sur la page." >&2; exit 1; }

image_url="$(resolve_url "$event_url" "$candidate")"

echo "Image URL: $image_url"
curl -fL "$image_url" -o "$output_file"

echo "Téléchargement terminé: $output_file"
