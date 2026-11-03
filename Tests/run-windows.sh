#!/bin/zsh
set -euo pipefail
TEST_ROOT="${0:A:h}"
PROJECT_ROOT="${TEST_ROOT:h}"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/private/tmp}/chatgpt-backdrop-windows-tests.XXXXXX")"
trap '/bin/rm -rf "$TEST_BUILD"' EXIT
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TEST_BUILD/module-cache" \
  "$PROJECT_ROOT/Sources/CDPClient.swift" \
  "$PROJECT_ROOT/Sources/BackdropWindows.swift" \
  "$TEST_ROOT/BackdropWindowsTests.swift" \
  -o "$TEST_BUILD/backdrop-windows-tests"
"$TEST_BUILD/backdrop-windows-tests" "$@"
