#!/bin/sh
# Puts the public theme where rust-embed picks it up.
#
# The theme's source lives in web-theme/ beside the hub's own code. It used to
# be downloaded -- from this repository's release, falling back to the upstream
# project's -- which is what this script did before. Keeping the source here is
# what makes the theme changeable at all: it is the page visitors look at, and
# what they ask of it (a way back to the list, a background) are edits to it.
#
# Copies built output rather than building it. web-theme/dist/ is committed,
# because a build needs node and an `npm install`, and this script runs from
# build.rs -- so `cargo build` would otherwise need a JavaScript toolchain to
# produce a Rust binary. Rebuilding the theme is a step of its own:
#
#     cd web-theme && npm install && npm run build
#
# then commit dist/. CI rebuilds it before building the hub and fails if the
# result differs, so a stale dist/ cannot reach a release.
set -eu

cd "$(dirname "$0")/.."
SRC=web-theme
DEST=target/theme

[ -f "$SRC/theme.json" ] || { echo "$SRC/theme.json 不在" >&2; exit 1; }
[ -f "$SRC/dist/index.html" ] ||
  { echo "$SRC/dist/index.html 不在：先 cd web-theme && npm install && npm run build" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$SRC/dist" "$DEST/dist"
cp "$SRC/theme.json" "$DEST/theme.json"
[ -f "$SRC/preview.png" ] && cp "$SRC/preview.png" "$DEST/preview.png"
echo "theme staged from $SRC/dist"
