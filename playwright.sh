#!/bin/bash
# playwright.sh — how close Search's Chromium mode is to Chrome, as Playwright
# sees it (see PLAYWRIGHT_PLAN.md): Tests/Playwright's specs, Playwright's own
# test suite at the release Search is measured against, and the switch list
# that follows that release. The release is the one Tests/Playwright pins.
#
#   ./playwright.sh attach [args]          the specs against the Search Beta you have open, in
#                                          Chromium mode with "Let Playwright and other tools
#                                          drive Chromium" on (127.0.0.1:9222)
#   ./playwright.sh launch [args]          the specs, Playwright starting Search Beta itself
#   ./playwright.sh baseline [args]        the specs against Playwright's own Chromium: what
#                                          passing means
#   ./playwright.sh bridge                 the bridge alone, no Search built (Tests/Bridge/run.sh)
#   ./playwright.sh suite [args]           Playwright's own tests against Search Beta, headless:
#                                          unseen, every window off every screen
#   ./playwright.sh suite-baseline [args]  the same against Playwright's own full Chromium,
#                                          headless (channel chromium)
#   ./playwright.sh expectations           what passed in the last suite-baseline and failed in
#                                          the last suite, into Tests/Playwright/expectations.txt
#   ./playwright.sh switches               Sources/Search/Chromium/PlaywrightSwitches.swift from
#                                          the pinned release's chromiumSwitches.ts
#
# Args go to `playwright test`: a file, --grep, --workers, --headed (both
# runs, to compare like with like). SEARCH_APP names
# another build than /Applications/Search Beta.app. The suite is cloned and
# built once, into build/playwright-<release>; its reports go to build/.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
SPECS="Tests/Playwright"
APP="${SEARCH_APP:-/Applications/Search Beta.app/Contents/MacOS/Search}"
RELEASE=$(sed -n 's/.*"@playwright\/test": "\([0-9.]*\)".*/\1/p' "$SPECS/package.json")
SUITE="build/playwright-$RELEASE"
[ -n "$RELEASE" ] || { echo "can't read the pinned release from $SPECS/package.json" >&2; exit 1; }

specs() {
  cd "$SPECS"
  [ -d node_modules ] || npm ci
  npx playwright test "$@"
}

suite() {
  local name="$1"
  shift
  mkdir -p build
  if [ ! -d "$SUITE/.git" ]; then
    git clone --depth 1 --branch "v$RELEASE" https://github.com/microsoft/playwright.git "$SUITE"
  fi
  if [ ! -d "$SUITE/packages/playwright-core/lib" ]; then
    (cd "$SUITE" && npm ci && npm run build && npx playwright install chromium ffmpeg)
  fi
  cd "$SUITE"
  # Every test, not the first 200 failures: the two runs are compared.
  PLAYWRIGHT_JSON_OUTPUT_NAME="$ROOT/build/suite-$name.json" \
    npx playwright test --config=tests/library/playwright.config.ts --project='chromium-*' \
    --max-failures=0 --reporter=dot,json "$@"
}

command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
  attach)
    SEARCH_MODE=attach specs "$@" ;;
  launch)
    [ -x "$APP" ] || { echo "no Search at $APP: ./beta.sh builds it" >&2; exit 1; }
    SEARCH_MODE=launch SEARCH_APP="$APP" specs "$@" ;;
  baseline)
    (cd "$SPECS" && { [ -d node_modules ] || npm ci; } && npx playwright install chromium)
    SEARCH_MODE=launch SEARCH_APP=chrome specs "$@" ;;
  bridge)
    exec Tests/Bridge/run.sh ;;
  suite)
    [ -x "$APP" ] || { echo "no Search at $APP: ./beta.sh builds it" >&2; exit 1; }
    CRPATH="$APP" suite search "$@" ;;
  suite-baseline)
    # Full Chromium, as Search is, not the headless shell.
    (unset CRPATH; PWTEST_CHANNEL=chromium suite baseline "$@") ;;
  expectations)
    [ -f build/suite-baseline.json ] || { echo "no build/suite-baseline.json: ./playwright.sh suite-baseline first" >&2; exit 1; }
    [ -f build/suite-search.json ] || { echo "no build/suite-search.json: ./playwright.sh suite first" >&2; exit 1; }
    node "$SPECS/expectations.mjs" build/suite-baseline.json build/suite-search.json "$RELEASE" > "$SPECS/expectations.txt"
    head -4 "$SPECS/expectations.txt" ;;
  switches)
    mkdir -p build
    curl --fail --silent --show-error --location --proto '=https' --output build/chromiumSwitches.ts \
      "https://raw.githubusercontent.com/microsoft/playwright/v$RELEASE/packages/playwright-core/src/server/chromium/chromiumSwitches.ts"
    python3 "$SPECS/switches.py" build/chromiumSwitches.ts "$RELEASE" Sources/Search/Chromium/PlaywrightSwitches.swift ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    exit 1 ;;
esac
