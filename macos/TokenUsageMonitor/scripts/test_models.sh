#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -parse-as-library \
  "$project_dir/Sources/TokenUsageMonitor/Models.swift" "$project_dir/Tests/ModelChecks.swift" -o "$test_dir/ModelChecks"
"$test_dir/ModelChecks"
swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -parse-as-library \
  "$project_dir/Sources/TokenUsageMonitor/SubscriptionModels.swift" \
  "$project_dir/Sources/TokenUsageMonitor/SubscriptionPreferences.swift" \
  "$project_dir/Tests/SubscriptionChecks.swift" -o "$test_dir/SubscriptionChecks"
"$test_dir/SubscriptionChecks"

# Test the real store and bundled reader against disposable SQLite and rollout data.
app="$test_dir/PanelChecks.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources" "$test_dir/codex"
cp "$project_dir/../../scripts/context_snapshot.py" "$app/Resources/"
cat > "$app/Info.plist" <<'PLIST'
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.codex.token-monitor.panel-checks</string>
<key>CFBundleExecutable</key><string>PanelChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
src="$project_dir/Sources/TokenUsageMonitor"
swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -parse-as-library \
  "$src"/{MonitorStore,Models,AppServerClient,SubscriptionPreferences,SubscriptionModels}.swift \
  "$project_dir/Tests/PanelRefreshChecks.swift" -o "$app/MacOS/PanelChecks"
CFFIXED_USER_HOME="$test_dir" CODEX_HOME="$test_dir/codex" CODEX_STATE_DB="$test_dir/codex/state_5.sqlite" \
  "$app/MacOS/PanelChecks" "$test_dir/codex"
