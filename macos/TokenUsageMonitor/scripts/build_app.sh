#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
build_dir="${TOKEN_MONITOR_BUILD_DIR:-$project_dir/.product-build}"
dist_dir="${TOKEN_MONITOR_DIST_DIR:-$project_dir/dist}"
app_path="$dist_dir/Token Usage Monitor.app"
binary_path="$build_dir/TokenUsageMonitor"

mkdir -p "$build_dir" "$app_path/Contents/MacOS" "$app_path/Contents/Resources"

if (cd "$project_dir" && swift build -c release >/dev/null 2>&1); then
  swift_product="$(cd "$project_dir" && swift build -c release --show-bin-path)/TokenUsageMonitor"
  install -m 755 "$swift_product" "$binary_path"
else
  sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  if [[ -z "$sdk_path" ]]; then
    for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
      [[ -d "$candidate" ]] && sdk_path="$candidate"
    done
  fi
  [[ -n "$sdk_path" && -d "$sdk_path" ]] || { print -u2 "macOS SDK not found"; exit 1; }
  swiftc -O -sdk "$sdk_path" -target arm64-apple-macosx13.0 -parse-as-library \
    "$project_dir"/Sources/TokenUsageMonitor/*.swift -o "$binary_path"
fi

install -m 755 "$binary_path" "$app_path/Contents/MacOS/TokenUsageMonitor"
install -m 644 "$project_dir/AppInfo.plist" "$app_path/Contents/Info.plist"
plutil -lint "$app_path/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
print "$app_path"
