#!/usr/bin/env bash
# Build the dashboard and publish it to the gh-pages branch from a workstation.
#
# GitHub Pages for this repository serves the prebuilt `gh-pages` branch, so this script is all
# that is needed to update the live site — no Actions minutes, no deployment artifact. The
# equivalent CI job lives in .github/workflows/deploy-pages.yml.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
SHA=$(git rev-parse --short HEAD)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "[+] building frontend"
npm --prefix frontend run build >/dev/null

cp -R "$ROOT/frontend/dist/." "$STAGE/"
touch "$STAGE/.nojekyll"
cp "$STAGE/index.html" "$STAGE/404.html"   # Pages serves 404.html for unknown client-side routes

echo "[+] publishing to gh-pages"
cd "$STAGE"
git init -q
git add -A
git commit -q -m "chore: publish dashboard from $SHA"
git push -q --force "$(git -C "$ROOT" remote get-url origin)" HEAD:gh-pages

echo "[ok] pushed. Live at https://elzuzu.github.io/otter-arc/ once GitHub Pages builds."
