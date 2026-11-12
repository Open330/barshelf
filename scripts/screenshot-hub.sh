#!/usr/bin/env bash
# Renders the BarShelf window, onboarding, popup and menu bar cards to PNGs
# in English and Korean, light and dark, from a development build.
#
#   scripts/screenshot-hub.sh <out-dir> [--live] [--real-data] [--only <prefix>]
#
# --live       approve and refresh the scratch home's widgets first, so cards
#              show readings instead of their empty state
# --real-data  start the scratch home from a copy of your installed widgets,
#              prefs and approvals (read only; nothing is written back)
#
# Output: <out-dir>/{en,ko}-{light,dark}/*.png
set -euo pipefail

out=${1:?usage: scripts/screenshot-hub.sh <out-dir> [--live] [--real-data] [--only <prefix>]}
shift
extra=()
real=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --live) extra+=(--live) ;;
    --real-data) real=1 ;;
    --only) extra+=(--only "$2"); shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$(dirname "$0")/.."
swift build --product barshelf-app >/dev/null
bin=$(swift build --show-bin-path)
xcrun xcstringstool compile Localization/Localizable.xcstrings --output-directory "$bin"
# The source language has no compiled table; without its folder the bundle
# offers only Korean and "-AppleLanguages (en)" falls back to it.
mkdir -p "$bin/en.lproj"

mkdir -p "$out"
out=$(cd "$out" && pwd)
for lang in en ko; do
  home=$(mktemp -d "${TMPDIR:-/tmp}/barshelf-shot-home.XXXXXX")
  if [[ $real == 1 ]]; then
    src="$HOME/Library/Application Support/BarShelf"
    dst="$home/Library/Application Support/BarShelf"
    mkdir -p "$dst"
    cp -R "$src/widgets" "$dst/"
    for f in permissions.json prefs.json app-prefs.json; do
      [[ -f "$src/$f" ]] && cp "$src/$f" "$dst/"
    done
  fi
  for look in light dark; do
    flags=("${extra[@]+"${extra[@]}"}")
    [[ $look == dark ]] && flags+=(--dark)
    CFFIXED_USER_HOME="$home" "$bin/barshelf-app" screenshot-hub "$out/$lang-$look" \
      "${flags[@]+"${flags[@]}"}" -AppleLanguages "($lang)" >/dev/null
    echo "$out/$lang-$look"
  done
  rm -rf "$home"
done
