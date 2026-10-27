#!/bin/bash
# chromium.sh — builds the Chromium add-on: CEF's framework and the helper
# app Chromium starts its other processes from, which Search downloads
# into Store.folder/Chromium/<version>/ when somebody switches engines (see
# Sources/Search/Chromium).
#
#   ./chromium.sh                    build build/chromium/addon/<version>/ and its zip
#   ./chromium.sh install [world]    copy it into the test world "Search (<world>)",
#                                    "test" unless named; --real for your own Search,
#                                    --beta for Search Beta
#   ./chromium.sh test [port]        run the smoke test against the test world's copy
#
# From CEF's minimal distribution for macOS arm64, at one pinned version,
# fetched here and checked against its SHA-1. The vendored headers in
# Sources/CChromium/cef must be the distribution's own, and the API version
# Package.swift pins is the one the helper is compiled for. The helper
# (Chromium/helper.c) is built with the same loader as Search, its bundle
# gets Chromium/Helper.plist, and everything is signed inside out — the
# framework's libraries, the framework, then the helper with its
# entitlements (Chromium/helper.entitlements, which says why there is only
# the one) — with the hardened runtime and SEARCH_SIGN_IDENTITY when it is
# set, ad hoc otherwise, which only a build of Search signed ad hoc
# accepts. CHROMIUM_CACHE says where the
# distribution is kept, build/chromium unless set. Notarizing and
# publishing are the release's, not this script's.
set -euo pipefail
cd "$(dirname "$0")"

CEF_FILE="cef_binary_156.0.8+g426920c+chromium-156.0.8078.48_macosarm64_minimal"
CEF_URL="https://cef-builds.spotifycdn.com/cef_binary_156.0.8%2Bg426920c%2Bchromium-156.0.8078.48_macosarm64_minimal.tar.bz2"
CEF_SHA1="58510b0c4b4bfd5f02b3d2e027a02266168a7ce3"
CACHE="${CHROMIUM_CACHE:-build/chromium}"
OUT="build/chromium"
HEADERS="Sources/CChromium/cef"
VERSION=$(sed -n 's/^#define CEF_VERSION "\(.*\)"$/\1/p' "$HEADERS/include/cef_version.h")
SHORT=$(sed -nE 's/^#define CEF_VERSION_(MAJOR|MINOR|PATCH) ([0-9]+)$/\2/p' "$HEADERS/include/cef_version.h" | paste -sd. -)
API=$(grep -o 'CEF_API_VERSION_[0-9]*' Package.swift | head -1)
ADDON="$OUT/addon/$VERSION"
FRAMEWORK="Chromium Embedded Framework.framework"
HELPER="Search Helper"

[ -n "$VERSION" ] && [ -n "$API" ] || { echo "can't read the pinned versions" >&2; exit 1; }

build() {
  mkdir -p "$CACHE" "$OUT"
  local tarball="$CACHE/$CEF_FILE.tar.bz2" dist="$CACHE/$CEF_FILE"
  if [ ! -f "$tarball" ]; then
    curl --fail --location --proto '=https' --output "$tarball.part" "$CEF_URL"
    mv "$tarball.part" "$tarball"
  fi
  local have
  have=$(shasum -a 1 "$tarball" | cut -d' ' -f1)
  if [ "$have" != "$CEF_SHA1" ]; then
    echo "$tarball has SHA-1 $have, not the pinned $CEF_SHA1 — delete it and run again" >&2
    exit 1
  fi
  [ -d "$dist" ] || tar -xjf "$tarball" -C "$CACHE"

  # The headers Search is compiled against must be this distribution's.
  local file
  while IFS= read -r file; do
    cmp -s "$HEADERS/$file" "$dist/$file" || { echo "$HEADERS/$file differs from CEF $VERSION's" >&2; exit 1; }
  done < <(cd "$HEADERS" && find include -type f)
  cmp -s "$HEADERS/LICENSE.txt" "$dist/LICENSE.txt" || { echo "CEF's licence differs" >&2; exit 1; }

  rm -rf "$ADDON"
  local bundle="$ADDON/$HELPER.app"
  mkdir -p "$bundle/Contents/MacOS"
  ditto "$dist/Release/$FRAMEWORK" "$ADDON/$FRAMEWORK"
  clang -std=c11 -O2 -arch arm64 -mmacosx-version-min=14.0 -Wall \
    -DCEF_API_VERSION="$API" -I"$HEADERS" -ISources/CChromium/include \
    Chromium/helper.c Sources/CChromium/src/loader.c -o "$bundle/Contents/MacOS/$HELPER"
  strip -x "$bundle/Contents/MacOS/$HELPER"
  sed -e "s/@NAME@/$HELPER/g" -e "s/@IDENTIFIER@/com.officecommun.search.helper/g" -e "s/@VERSION@/$SHORT/g" \
    Chromium/Helper.plist > "$bundle/Contents/Info.plist"
  printf 'APPL????' > "$bundle/Contents/PkgInfo"

  sign
  local zip="$OUT/search-chromium-$SHORT-arm64.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$ADDON" "$zip"
  local sha size
  sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
  size=$(stat -f %z "$zip")
  printf '%s  %s bytes (%s unpacked)  sha256 %s\n' "$zip" "$size" "$(du -sh "$ADDON" | cut -f1)" "$sha"
  printf '"chromium": {"version": "%s", "url": "https://…/%s", "sha256": "%s", "size": %s}\n' \
    "$VERSION" "$(basename "$zip")" "$sha" "$size"
}

sign() {
  local identity="${SEARCH_SIGN_IDENTITY:-}" library adhoc=1
  local options=(--force --sign -)
  if [ -n "$identity" ] && [ "$identity" != "-" ]; then
    options=(--force --timestamp --options runtime --sign "$identity")
    adhoc=0
  fi
  for library in "$ADDON/$FRAMEWORK/Libraries/"*.dylib; do
    codesign "${options[@]}" "$library"
  done
  codesign "${options[@]}" "$ADDON/$FRAMEWORK"
  codesign "${options[@]}" --entitlements Chromium/helper.entitlements "$ADDON/$HELPER.app"
  codesign --verify --strict --deep "$ADDON/$FRAMEWORK"
  codesign --verify --strict "$ADDON/$HELPER.app"
  [ "$adhoc" = 1 ] && echo "note: signed ad hoc — only a build of Search signed ad hoc will load it"
  return 0
}

place() {
  local world="test" real=0 beta=0 argument
  for argument in "$@"; do
    case "$argument" in
      --real) real=1 ;;
      --beta) beta=1 ;;
      -*) echo "usage: ./chromium.sh install [world] [--real | --beta]" >&2; exit 1 ;;
      *) world="$argument" ;;
    esac
  done
  [ -d "$ADDON" ] || { echo "no add-on in $ADDON — run ./chromium.sh first" >&2; exit 1; }
  local support="$HOME/Library/Application Support" folder
  if [ "$beta" = 1 ]; then
    folder="$support/Search Beta/Chromium"
  elif [ "$real" = 1 ]; then
    folder="$support/Search/Chromium"
  else
    # As Store.world spells it: letters, digits and dashes, lower case.
    world=$(printf '%s' "$world" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
    [ -n "$world" ] && [ "$world" != 1 ] || world="test"
    folder="$support/Search ($world)/Chromium"
  fi
  mkdir -p "$folder"
  rm -rf "$folder/$VERSION.part"
  ditto "$ADDON" "$folder/$VERSION.part"
  rm -rf "$folder/$VERSION"
  mv "$folder/$VERSION.part" "$folder/$VERSION"
  # Older versions go, as when Search installs one; the profile stays.
  local old
  for old in "$folder"/*+chromium-*; do
    [ -d "$old" ] && [ "$old" != "$folder/$VERSION" ] && rm -rf "$old"
  done
  echo "installed $folder/$VERSION"
}

smoke() {
  local port="${1:-9333}" app="$OUT/smoke/ChromiumSmoke.app"
  swift build --product ChromiumSmoke
  # Inside an app of its own, as Search runs, with a bundle and an
  # identifier of its own.
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$(swift build --show-bin-path)/ChromiumSmoke" "$app/Contents/MacOS/"
  sed -e "s/@NAME@/ChromiumSmoke/g" -e "s/@IDENTIFIER@/com.officecommun.search.chromium-smoke/g" \
    -e "s/@VERSION@/$SHORT/g" Chromium/Helper.plist > "$app/Contents/Info.plist"
  codesign --force --sign - "$app"
  "$app/Contents/MacOS/ChromiumSmoke" --port "$port"
}

case "${1:-build}" in
  build) build ;;
  install) shift; place "$@" ;;
  test) shift; smoke "$@" ;;
  *) echo "usage: ./chromium.sh [build | install [world] [--real | --beta] | test [port]]" >&2; exit 1 ;;
esac
