#!/bin/sh
# Builds the miku theme package from the default theme plus themes/miku/.
#
# The miku theme is not a front end of its own: it is the default one with a
# background video behind it. Three lines go into index.html and two files go
# beside it into dist/assets.
#
# Rebuilt from the default theme rather than kept as a copy of it. A copy would
# go stale the first time the default theme changed, and the staleness would be
# invisible -- the panel it serves would simply be missing whatever the default
# theme learned since.
#
#   sh scripts/theme-miku.sh [out.tar.gz]     (default target/theme-miku.tar.gz)
#
# Needs target/theme/ in place; build.rs puts it there, or run scripts/theme.sh.
set -eu

cd "$(dirname "$0")/.."
SRC=target/theme
MIKU=themes/miku
OUT=${1:-target/theme-miku.tar.gz}

[ -f "$SRC/theme.json" ] || { echo "$SRC/theme.json 不在：先跑 scripts/theme.sh" >&2; exit 1; }
[ -f "$SRC/dist/index.html" ] || { echo "$SRC/dist/index.html 不在" >&2; exit 1; }
[ -f "$MIKU/miku-bg.mp4" ] || { echo "$MIKU/miku-bg.mp4 不在" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -r "$SRC/dist" "$STAGE/dist"
cp "$MIKU/theme.json" "$STAGE/theme.json"
cp "$MIKU/miku-bg.css" "$STAGE/dist/assets/miku-bg.css"
cp "$MIKU/miku-bg.mp4" "$STAGE/dist/assets/miku-bg.mp4"
[ -f "$SRC/preview.png" ] && cp "$SRC/preview.png" "$STAGE/preview.png"

# The three insertions, anchored on strings the default theme always emits --
# `</head>` and `<div id="root">`. Not on the asset names: those carry a hash
# and change on every rebuild of the default theme, so a stored copy of this
# file would break the first time they did.
#
#   is-admin   the stylesheet keys off `body:not(.is-admin)` so the admin page
#              keeps its own look, and the default theme does not set that class
#   the css    draws the background and clears the cards
#   the video  the element the stylesheet positions; without it the page is the
#              default theme with transparent cards and nothing behind them
python3 "$(dirname "$0")/theme-miku-html.py" "$STAGE/dist/index.html"

# Packed with -C into the staging directory, so the archive holds relative
# paths and theme.json sits at its root -- which is where `frontend::install`
# looks for it.
tar -czf "$OUT" -C "$STAGE" .
echo "built $OUT ($(wc -c <"$OUT") bytes)"
