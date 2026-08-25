#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
build_dir="${TOKEN_MONITOR_BUILD_DIR:-$project_dir/.product-build}"
dist_dir="${TOKEN_MONITOR_DIST_DIR:-$project_dir/dist}"
app_path="$dist_dir/Token监测.app"
binary_path="$build_dir/TokenUsageMonitor"

mkdir -p "$build_dir" "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
rm -f "$app_path/Contents/Resources/AppIcon.icns"

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
install -m 644 "$project_dir/../../scripts/token_monitor.py" "$app_path/Contents/Resources/token_monitor.py"
install -m 644 "$project_dir/../../scripts/api_usage_server.py" "$app_path/Contents/Resources/api_usage_server.py"

icon_source="$project_dir/Assets/AppIcon-master.png"
if [[ -f "$icon_source" ]]; then
  install -m 644 "$icon_source" "$app_path/Contents/Resources/AppLogo.png"
  iconset="$build_dir/AppIcon.iconset"
  mkdir -p "$iconset"
  sips -z 16 16 "$icon_source" --out "$iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 "$icon_source" --out "$iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$icon_source" --out "$iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 "$icon_source" --out "$iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$icon_source" --out "$iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$icon_source" --out "$iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$icon_source" --out "$iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$icon_source" --out "$iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$icon_source" --out "$iconset/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$icon_source" --out "$iconset/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$iconset" -o "$build_dir/AppIcon-v2.icns"
  install -m 644 "$build_dir/AppIcon-v2.icns" "$app_path/Contents/Resources/AppIcon-v2.icns"
fi

plutil -lint "$app_path/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
print "$app_path"
