#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE
TEST_ROOT="${0:A:h}"
PROJECT_ROOT="${TEST_ROOT:h}"
TEST_BUILD=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/chatgpt-backdrop-tests.XXXXXX")
MOCK_PID=""
cleanup() {
  if [[ -n "$MOCK_PID" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  /bin/rm -rf "$TEST_BUILD"
}
trap cleanup EXIT INT TERM
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TEST_BUILD/module-cache" \
  "$PROJECT_ROOT/Sources/CDPClient.swift" "$TEST_ROOT/CDPClientTests.swift" \
  -o "$TEST_BUILD/cdp-client-tests"

if [[ "${1:-}" == "--offline" ]]; then
  "$TEST_BUILD/cdp-client-tests" --offline
  exit 0
fi

/usr/bin/python3 "$TEST_ROOT/cdp_mock_server.py" --port-file "$TEST_BUILD/port.txt" &
MOCK_PID=$!
for attempt in {1..50}; do
  [[ -s "$TEST_BUILD/port.txt" ]] && break
  if ! kill -0 "$MOCK_PID" 2>/dev/null; then
    print -u2 "The local mock server could not start. Allow loopback networking or run Tests/run.sh --offline."
    exit 1
  fi
  /bin/sleep 0.1
done
if [[ ! -s "$TEST_BUILD/port.txt" ]]; then
  print -u2 "The local mock server did not become ready within five seconds."
  exit 1
fi
"$TEST_BUILD/cdp-client-tests" --port-file "$TEST_BUILD/port.txt"
