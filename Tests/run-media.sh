#!/bin/zsh
set -euo pipefail
TEST_ROOT="${0:A:h}"
PROJECT_ROOT="${TEST_ROOT:h}"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/private/tmp}/chatgpt-backdrop-media.XXXXXX")"
trap '/bin/rm -rf "$TEST_BUILD"' EXIT
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TEST_BUILD/module-cache" \
  -framework AppKit -framework SwiftUI -framework ImageIO \
  "$PROJECT_ROOT/Sources/BackdropMedia.swift" "$TEST_ROOT/MediaTests.swift" \
  -o "$TEST_BUILD/media-tests"
"$TEST_BUILD/media-tests" "$TEST_BUILD/fixtures"
