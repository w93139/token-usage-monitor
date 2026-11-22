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
cp "$project_dir/../../scripts/"{context_snapshot,api_usage_server,token_monitor}.py "$app/Resources/"
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
cat > "$test_dir/codex-fixture" <<'PYTHON'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    result = {}
    if request["method"] == "account/usage/read":
        result = {"summary": {"lifetimeTokens": 99}}
    if request["method"] == "account/rateLimits/read" and (Path(os.environ["CODEX_HOME"]) / "valid-quota").exists():
        result = {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 20}}}
    print(json.dumps({"id": request["id"], "result": result}), flush=True)
PYTHON
chmod +x "$test_dir/codex-fixture"
test_port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
CODEX_BINARY="$test_dir/codex-fixture" CFFIXED_USER_HOME="$test_dir" CODEX_HOME="$test_dir/codex" CODEX_STATE_DB="$test_dir/codex/state_5.sqlite" \
  "$app/MacOS/PanelChecks" "$test_dir/codex" "$test_port"
