#!/usr/bin/env python3
"""Apply small WoowTech static-brand changes to the locked official frontend.

The upstream 2026.9.1 JavaScript and backend stay intact. This is deliberately
limited to HTML titles and the loading image; a full rebrand needs a port of its
2026.7.2 frontend and Core patches.
"""

from pathlib import Path
import sys

frontend = Path(sys.argv[1])
for name in ("index.html", "authorize.html", "onboarding.html"):
    path = frontend / name
    text = path.read_text(encoding="utf-8")
    title = "<title>Home Assistant</title>"
    if text.count(title) != 1:
        raise SystemExit(f"{name}: unexpected upstream title; review this patch")
    text = text.replace(title, "<title>woowtech</title>")
    if name == "index.html":
        logo = ('class="ha-logo" '
                'src="/static/images/home-assistant-logo-loading.svg" '
                'alt="Home Assistant"')
        if text.count(logo) != 1:
            raise SystemExit("index.html: unexpected loading image; review this patch")
        text = text.replace(
            logo,
            'class="ha-logo" src="/static/icons/favicon-512x512.png" alt="woowtech"',
        )
        text = text.replace('color="#18bcf2"', 'color="#6183fc"')
    path.write_text(text, encoding="utf-8")
