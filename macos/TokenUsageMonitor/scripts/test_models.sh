#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -parse-as-library \
  "$project_dir/Sources/TokenUsageMonitor/Models.swift" "$project_dir/Tests/ModelChecks.swift" -o "$test_dir/ModelChecks"
"$test_dir/ModelChecks"
