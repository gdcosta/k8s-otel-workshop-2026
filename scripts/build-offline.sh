#!/usr/bin/env bash
# Builds a fully self-contained HTML copy that works by double-clicking index.html.
#
# The normal `mkdocs build` output MUST be served over HTTP — directory-style URLs,
# a search web worker, and instant navigation all fail on file://. This variant fixes
# all three and vendors every external asset, so it can be zipped and emailed.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=site-offline

./.venv/bin/mkdocs build -f mkdocs-offline.yml -d "$OUT" --strict

# Material's offline plugin pulls an iframe-worker shim from unpkg.com. Vendor it,
# otherwise an "offline" build still needs the internet.
mkdir -p "$OUT/assets/javascripts/shim"
curl -sfL https://unpkg.com/iframe-worker/shim -o "$OUT/assets/javascripts/shim/iframe-worker.js"

python3 - "$OUT" <<'PY'
import os, re, sys
root = sys.argv[1]; n = 0
for d, _, fs in os.walk(root):
    for f in fs:
        if not f.endswith('.html'): continue
        p = os.path.join(d, f)
        s = open(p, encoding='utf8').read()
        if 'unpkg.com/iframe-worker' not in s: continue
        depth = len(os.path.relpath(p, root).split(os.sep)) - 1
        s = s.replace('https://unpkg.com/iframe-worker/shim',
                      '../' * depth + 'assets/javascripts/shim/iframe-worker.js')
        open(p, 'w', encoding='utf8').write(s); n += 1
print(f"  vendored iframe-worker shim into {n} pages")
PY

ext=$(grep -rohE '(src|href)="https?://[^"]*"' "$OUT" --include='*.html' \
      | grep -vE 'github\.com' | sort -u | wc -l | tr -d ' ')
echo "  remaining external asset refs: $ext  (GitHub edit links excluded — they're just links)"
echo
echo "  Built: $OUT/  — open $OUT/index.html directly, or zip and send it."
