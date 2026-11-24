#!/usr/bin/env bash
# UI preview: builds the Swift frontend against stubs for the iOS simulator and takes screenshots of
# the PS Vita home screen in several states. Usage: .ci/ui-preview/run.sh <output-dir>
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "${1:-.}"
out="$(cd "${1:-.}" && pwd)"
work="$(mktemp -d)"
app="$work/Preview.app"
mkdir -p "$app" "$out"

python3 "$repo/.ci/ui-preview/gen_stubs.py" "$repo/vita3k/ios/bridge/vita3k_bridge.h" "$repo/vita3k/ios/controls/virtual_pad.h" \
    "$repo/vita3k/ios/ramhelper/ram_helpers.h" "$repo/vita3k/ios/ramhelper/builtin_jit.h" "$repo/vita3k/ios/n3ds/n3ds.h" > "$work/stubs.c"
target=arm64-apple-ios17.4-simulator
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target "$target" -isysroot "$sdk" -c "$work/stubs.c" -o "$work/stubs.o"
xcrun --sdk iphonesimulator swiftc -target "$target" -sdk "$sdk" -swift-version 5 -parse-as-library \
    -import-objc-header "$repo/vita3k/ios/ui/Vita3K-Bridging-Header.h" \
    "$repo"/vita3k/ios/ui/*.swift "$repo/.ci/ui-preview/PreviewApp.swift" "$work/stubs.o" -o "$app/Preview"

cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.vita3k.uipreview</string>
<key>CFBundleExecutable</key><string>Preview</string>
<key>CFBundleName</key><string>Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>17.4</string>
<key>UILaunchScreen</key><dict/>
<key>UIRequiresFullScreen</key><true/>
<key>UIStatusBarHidden</key><true/>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationLandscapeRight</string></array>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
</dict></plist>
PLIST
codesign -s - --force "$app"

udid="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
runtimes = sorted((r for r in devices if "iOS" in r), reverse=True)
for r in runtimes:
    for d in devices[r]:
        if d["name"].startswith("iPhone 1") and "Pro" in d["name"]:
            print(d["udid"]); sys.exit()
for r in runtimes:
    for d in devices[r]:
        if d["name"].startswith("iPhone"):
            print(d["udid"]); sys.exit()
')"
echo "Simulator $udid"
xcrun simctl boot "$udid" 2> /dev/null || true
xcrun simctl bootstatus "$udid" -b > /dev/null
xcrun simctl install "$udid" "$app"

for scenario in ${UI_PREVIEW_SCENARIOS:-home themechange lock many app:PCSA00100 app:PCSA00101 panel:themes panel:settings theme:meadow theme:sunset theme:aurora theme:sakura theme:crimson brand vitapad n3ds:hinoki n3ds:sbs n3ds:sbs-top n3ds-portrait}; do
    xcrun simctl terminate "$udid" org.vita3k.uipreview 2> /dev/null || true
    xcrun simctl launch "$udid" org.vita3k.uipreview -scenario "$scenario" > /dev/null
    sleep "${UI_PREVIEW_WAIT:-5}"
    file="$out/$(echo "$scenario" | tr ':' '-').png"
    xcrun simctl io "$udid" screenshot "$file" > /dev/null
    echo "Screenshot $file"
done
