#!/bin/zsh
set -euo pipefail
task_test_dir="${0:A:h}"
task_project_dir="${task_test_dir:h}"
task_work_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/chatgpt-backdrop-dom.XXXXXX")"
trap '/bin/rm -rf "$task_work_dir"' EXIT
mkdir -p "$task_work_dir/module-cache"
xcrun swiftc -parse-as-library -module-cache-path "$task_work_dir/module-cache" \
  -framework AppKit -framework WebKit "$task_test_dir/ThemeTests.swift" \
  -o "$task_work_dir/ThemeTests"
"$task_work_dir/ThemeTests" "$task_project_dir/Sources/theme.js"
