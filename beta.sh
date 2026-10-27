#!/bin/bash
# beta.sh — builds Search Beta from this checkout and installs it beside
# Search, in /Applications/Search Beta.app. Its folder, settings, sign-ins
# and Chromium profile are its own (Store.beta), so whatever it does leaves
# Search alone. Chromium's add-on is built and copied into the beta's folder
# the first time, and again with --chromium.
#
#   ./beta.sh              build, install, open
#   ./beta.sh --chromium   the same, rebuilding Chromium's add-on too
set -euo pipefail
cd "$(dirname "$0")"

SEARCH_BETA=1 ./build.sh release app

ADDONS="$HOME/Library/Application Support/Search Beta/Chromium"
if [ "${1:-}" = "--chromium" ] || ! ls -d "$ADDONS"/*+chromium-* >/dev/null 2>&1; then
  ./chromium.sh build
  ./chromium.sh install --beta
fi

osascript -e 'quit app id "com.officecommun.search.beta"' >/dev/null 2>&1 || true
rm -rf "/Applications/Search Beta.app"
ditto "build/Search Beta.app" "/Applications/Search Beta.app"
echo "installed /Applications/Search Beta.app"
open "/Applications/Search Beta.app"
