#!/bin/sh
# Builds the Reader's writing page from web/reader-editor into the TotalityReader bundle.
# Every package version is pinned in package-lock.json, and `npm ci` installs exactly those.
# The built files are committed, so the app builds without Node. Run this after changing the page.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
page="$root/web/reader-editor"
out="$root/Sources/TotalityReader/Resources/Editor"

cd "$page"
npm ci --no-audit --no-fund
npm test
npm run build
mkdir -p "$out"
cp dist/editor.js "$out/editor.js"
cp src/editor.css "$out/editor.css"
# The page is put inline in one document by Swift, so it must never close its own script tag.
if grep -q '</script' "$out/editor.js"; then
  echo "editor.js contains </script, which would end the page's script early" >&2
  exit 1
fi
echo "Built $(wc -c < "$out/editor.js" | tr -d ' ') bytes into $out"
