#!/usr/bin/env bash
# Builds fully self-contained HTML files — no web server, no assets folder.
# Each .html carries its own CSS, JS and images inline, so it works from
# SharePoint, a network share, a USB stick, or as an email attachment.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf .build-tmp docs-standalone          # stale output would survive otherwise
./.venv/bin/mkdocs build -f mkdocs-offline.yml -d .build-tmp --strict -q
python3 scripts/inline_standalone.py .build-tmp docs-standalone
rm -rf .build-tmp
echo
echo "  → open docs-standalone/index.html directly. No server needed."
