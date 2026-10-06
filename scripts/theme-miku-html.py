#!/usr/bin/env python3
"""Adds the miku background to a copy of the default theme's index.html.

Called by scripts/theme-miku.sh, which has already copied the default theme
into a staging directory. Edits in place.

Three insertions, each anchored on a string the default theme always emits:

    </head>          the is-admin script and the stylesheet link
    <div id="root">  the video element

Deliberately not anchored on the asset filenames. Those carry a content hash
and change on every rebuild of the default theme, so anything storing them
would break the first time they changed -- and it would break by serving a page
that references files that no longer exist, which reads as a blank screen
rather than as a packaging mistake.
"""
import sys

# Sets `is-admin` on the admin page. The stylesheet keys off
# `body:not(.is-admin)` so the panel keeps its own look, and the default theme
# does not set that class itself.
ADMIN = (
    "<script>(function(){function apply(){"
    'var a=location.pathname.indexOf("/admin")===0;'
    'document.body.classList.toggle("is-admin",a);'
    'if(!a){try{if(!localStorage.getItem("theme"))localStorage.setItem("theme","dark")}catch(e){}}}'
    'apply();addEventListener("popstate",apply);'
    "var p=history.pushState.bind(history);"
    "history.pushState=function(){p.apply(null,arguments);apply()}})();</script>"
)
LINK = '<link rel="stylesheet" href="/assets/miku-bg.css">'
VIDEO = (
    '<video id="miku-bg" autoplay muted loop playsinline preload="auto" '
    'src="/assets/miku-bg.mp4"></video>'
)


def main(path):
    with open(path, encoding="utf-8") as f:
        html = f.read()

    for needle in ("</head>", '<div id="root">'):
        if needle not in html:
            sys.exit("index.html 里没有 %s：默认主题改了结构，组装脚本要跟着改" % needle)

    html = html.replace("</head>", ADMIN + "\n    " + LINK + "\n  </head>", 1)
    html = html.replace('<div id="root">', VIDEO + '\n    <div id="root">', 1)

    with open(path, "w", encoding="utf-8") as f:
        f.write(html)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: theme-miku-html.py <index.html>")
    main(sys.argv[1])
