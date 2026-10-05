#!/bin/sh
# Materialises the pinned default theme into target/theme/, where rust-embed
# picks it up. The hub embeds a built theme derived from web-theme.pin, placed
# outside any working tree so nothing can drift from the pin.
#
# Called by build.rs, and by CI before cargo runs so that the download happens
# on the runner rather than inside the cross container, which does not
# necessarily carry curl.
set -eu

cd "$(dirname "$0")/.."
# read returns 1 at EOF, which is also what a pin file without a trailing
# newline produces; the fields are set either way. Unguarded, set -e would exit
# here silently and build.rs would report only the empty output.
read -r TAG SHA <web-theme.pin || true
[ -n "${TAG:-}" ] && [ -n "${SHA:-}" ] ||
  { echo "web-theme.pin must hold '<tag> <sha256>'" >&2; exit 1; }
DEST=target/theme
mkdir -p target
URL="https://github.com/Isyyyue/monitor/releases/download/$TAG/theme.tar.gz"
# 自己的 release 还没有主题包时，回退到上游
if ! curl -fsSL --retry 3 -o target/theme.tar.gz "$URL" 2>/dev/null; then
    echo "fallback to upstream theme"
    URL="https://github.com/monitor-probe/monitor-theme-default/releases/download/$TAG/theme.tar.gz"
    curl -fsSL --retry 3 -o target/theme.tar.gz "$URL"
fi

# Already unpacked at this pin. A theme placed here manually with a matching
# stamp is also left alone, which is how an unreleased theme is built against.
if [ -f "$DEST/.pin" ] && [ "$(cat "$DEST/.pin")" = "$TAG $SHA" ]; then
  exit 0
fi

GOT=$(sha256sum target/theme.tar.gz | cut -d' ' -f1)
if [ "$GOT" != "$SHA" ]; then
  echo "theme $TAG hashes to $GOT, not the $SHA that web-theme.pin names" >&2
  echo "the release asset was replaced or the pin is wrong; neither is safe to build" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
tar xzf target/theme.tar.gz --no-same-owner -C "$DEST"

# The archive is an installable theme directory, the same layout frontend.rs
# reads from disk. Without it the hub would embed nothing.
if [ ! -f "$DEST/dist/index.html" ] || [ ! -f "$DEST/theme.json" ]; then
  echo "theme $TAG unpacked without dist/index.html and theme.json" >&2
  exit 1
fi

printf '%s %s\n' "$TAG" "$SHA" >"$DEST/.pin"
echo "default theme $TAG unpacked into $DEST"
