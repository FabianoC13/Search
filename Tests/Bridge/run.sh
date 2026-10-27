#!/bin/bash
# Tests/Bridge/run.sh — Search's DevTools bridge tested with no Search
# built: DevToolsBridge.swift, Launch.swift and PlaywrightSwitches.swift as
# they are, built with FakeSearch.swift for the rest of Search, in front of
# Playwright's own headless Chromium. Tests/Playwright's specs go through it
# both ways in (Playwright starting it, and connectOverCDP to its port), and
# safety.mjs checks what a tool attached to your Search must never see or do.
# On macOS with Xcode's Swift; on Linux with a Swift toolchain, Linux/
# standing in for AppKit, Network and CryptoKit.
#
#   Tests/Bridge/run.sh          build, then both ways in, then the probe
#   Tests/Bridge/run.sh build    only build .build/harness
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
specs="$root/Tests/Playwright"
out="$here/.build"
bridge="$root/Sources/Search/Chromium"
sources=(main.swift FakeSearch.swift "$bridge/DevToolsBridge.swift" "$bridge/Launch.swift" "$bridge/PlaywrightSwitches.swift")
port="${HARNESS_PORT:-9339}"

mkdir -p "$out"
cd "$here"
if [ "$(uname)" = Darwin ]; then
  xcrun swiftc -swift-version 5 -module-name Search "${sources[@]}" -o "$out/harness"
else
  for module in AppKit Network CryptoKit; do
    swiftc -emit-module -emit-library -static -parse-as-library -swift-version 5 -module-name $module \
      "Linux/$module.swift" -emit-module-path "$out/$module.swiftmodule" -o "$out/lib$module.a"
  done
  swiftc -swift-version 5 -module-name Search -I "$out" -L "$out" -lAppKit -lNetwork -lCryptoKit \
    "${sources[@]}" Linux/PosixNet.swift -o "$out/harness"
fi
[ "${1:-}" = build ] && exit 0

cd "$specs"
[ -d node_modules ] || npm ci
# Playwright's own Chromium, unless HARNESS_CHROME names another.
HARNESS_CHROME="${HARNESS_CHROME:-$(node -e "console.log(require('playwright-core').chromium.executablePath())")}"
[ -x "$HARNESS_CHROME" ] || npx playwright install chromium
export HARNESS_CHROME

status=0
echo "== launch: Playwright starts the bridge, as it starts Chrome"
SEARCH_MODE=launch SEARCH_APP="$out/harness" SEARCH_HEADLESS=1 npx playwright test || status=1

echo "== attach: connectOverCDP to the bridge's port"
if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
  echo "127.0.0.1:$port is taken: HARNESS_PORT=<another> $0" >&2
  exit 1
fi
HARNESS_PORT=$port "$out/harness" 2> "$out/attach.log" &
harness=$!
trap 'kill $harness 2>/dev/null || true' EXIT
for _ in $(seq 150); do grep -q '^private ' "$out/attach.log" 2>/dev/null && break; sleep 0.2; done
SEARCH_MODE=attach SEARCH_CDP="http://127.0.0.1:$port" npx playwright test || status=1

echo "== safety: what a tool attached to your Search must never see or do"
node "$here/safety.mjs" "$port" "$(awk '/^private /{print $2}' "$out/attach.log")" || status=1
exit $status
