#!/usr/bin/env bash
# Regenerate the diagram assets from docs/pipeline.workflow.json.
#
#   docs/render.sh /path/to/archify   # archify checkout that renders the spec
#
# Produces, in docs/:
#   pipeline.html  interactive, self-contained
#   pipeline.svg   vector, for anywhere that keeps <style> in SVG
#   pipeline.png   raster, for GitHub
#
# The PNG exists because GitHub strips <style> from SVGs embedded in markdown.
# This diagram is styled entirely by CSS classes, so on GitHub the SVG loses
# every fill and stroke and renders unreadable. The PNG is what the README uses.
set -euo pipefail

DOCS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIFY="${1:-$HOME/.claude/skills/archify}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

[ -d "$ARCHIFY" ] || { echo "archify not found at $ARCHIFY (pass its path as \$1)" >&2; exit 1; }

echo "==> rendering HTML"
(cd "$ARCHIFY" && node bin/archify.mjs deliver workflow \
   "$DOCS/pipeline.workflow.json" "$DOCS/pipeline.html" --quality showcase)

echo "==> extracting standalone SVG"
python3 - "$DOCS" <<'PY'
import re, sys
docs = sys.argv[1]
html = open(f'{docs}/pipeline.html', encoding='utf-8').read()
css = re.sub(r'/\*.*?\*/', '', re.search(r'<style[^>]*>(.*?)</style>', html, re.S).group(1), flags=re.S)
svg = re.search(r'(<svg\b.*?</svg>)', html, re.S).group(1)
classes = {c for m in re.finditer(r'class="([^"]+)"', svg) for c in m.group(1).split()}
kept = [f'{s.strip()}{{{b.strip()}}}' for s, b in re.findall(r'([^{}]+)\{([^{}]*)\}', css)
        if s.strip() and not s.strip().startswith('@')
        and (':root' in s or any(f'.{c}' in s for c in classes) or re.match(r'^(svg|text|tspan)\b', s.strip()))]
# Valueless attributes are legal HTML and invalid XML.
for attr in ('data-legend-bridge', 'data-detail-anchor', 'data-legend'):
    svg = re.sub(rf'(\s{attr})(?=[\s/>])(?!\s*=)', r'\1=""', svg)
m = re.match(r'<svg\b[^>]*>', svg)
open_tag = m.group(0)
if 'xmlns=' not in open_tag:
    open_tag = open_tag[:-1] + ' xmlns="http://www.w3.org/2000/svg">'
out = open_tag + '<style><![CDATA[\n' + '\n'.join(kept) + '\n]]></style>' + svg[m.end():]
open(f'{docs}/pipeline.svg', 'w', encoding='utf-8').write(out)

import xml.etree.ElementTree as ET
ET.parse(f'{docs}/pipeline.svg')          # fail loudly rather than ship broken XML
print(f'   svg ok ({len(out)} bytes)')
PY

echo "==> rasterising PNG"
[ -x "$CHROME" ] || { echo "Chrome not found at $CHROME (set CHROME=...)" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
python3 - "$DOCS" "$tmp" <<'PY'
import sys
docs, tmp = sys.argv[1], sys.argv[2]
svg = open(f'{docs}/pipeline.svg', encoding='utf-8').read()
open(f'{tmp}/wrap.html', 'w', encoding='utf-8').write(
    '<!doctype html><meta charset="utf-8"><style>'
    'html,body{margin:0;padding:0;background:#ffffff}svg{display:block;width:1600px;height:auto}'
    f'</style>{svg}')
PY
"$CHROME" --headless=new --disable-gpu --hide-scrollbars \
  --default-background-color=FFFFFF --window-size=1600,1440 \
  --screenshot="$DOCS/pipeline.png" "file://$tmp/wrap.html" >/dev/null 2>&1
[ -s "$DOCS/pipeline.png" ] || { echo "PNG render produced nothing" >&2; exit 1; }
echo "   png ok ($(wc -c < "$DOCS/pipeline.png" | tr -d ' ') bytes)"
echo "done."
