#!/bin/sh
# Records the landing page's videos and stills into site/shots from the real
# app views (see Sources/MenubucketApp/LandingMedia/LandingMediaMode.swift).
#
#   scripts/render-landing-media.sh            # everything
#   scripts/render-landing-media.sh hero popup # only these (hero, popup, stills)
#
# Needs ffmpeg (brew install ffmpeg). Runs offscreen: no window, no screen
# recording, and a throwaway home folder, so it never reads or writes your
# own BarShelf data.
set -eu
cd "$(dirname "$0")/.."
swift build --product barshelf-app
home=$(mktemp -d "${TMPDIR:-/tmp}/barshelf-landing.XXXXXX")
work=$(mktemp -d "${TMPDIR:-/tmp}/barshelf-landing-cwd.XXXXXX")
trap 'rm -rf "$home" "$work"' EXIT
bin="$(pwd)/.build/debug/barshelf-app"
out="$(pwd)/site/shots"
# An empty working directory: the runtime would otherwise also load ./widgets.
cd "$work"
CFFIXED_USER_HOME="$home" "$bin" landing-media "$out" "$@"
