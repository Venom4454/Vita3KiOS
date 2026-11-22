#!/usr/bin/env bash
# Hinoki (formerly Vita3KiOS): builds an unsigned IPA with a plain Xcode project.
#   1. CMake generates Vita3K.xcodeproj
#   2. xcodebuild builds it (no signing)
#   3. the .app is zipped into Payload/ as an .ipa
# Sign/install it with AltStore, SideStore, LiveContainer, TrollStore, etc.
#
# Usage: .ci/build-ios.sh <output-dir>
set -euo pipefail

output_dir="${1:-artifacts}"
config="${BUILD_CONFIG:-Release}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${repo_root}/build/ios"

: "${VCPKG_ROOT:?VCPKG_ROOT must point at a bootstrapped vcpkg checkout}"

# Results of CMake's feature checks from an earlier build (see ios.yml). With the Xcode generator
# every check is a slow try-compile, so reusing them cuts configuring from ~10 minutes to seconds.
seed="${CMAKE_CHECKS_SEED:-}"
seed_args=()
if [[ -n "$seed" && -s "$seed" && ! -f "$build_dir/CMakeCache.txt" ]]; then
    echo "Reusing $(grep -c '^set(' "$seed") CMake check results"
    seed_args=(-C "$seed")
fi

cmake ${seed_args[@]+"${seed_args[@]}"} -S "$repo_root" -B "$build_dir" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_TOOLCHAIN_FILE="${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" \
    -DVCPKG_TARGET_TRIPLET=arm64-ios \
    -DUSE_LTO=NEVER \
    -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

if [[ -n "$seed" ]]; then
    # Keep only check results (HAVE_FOO=1 and the like): no paths, no CMake or vcpkg state,
    # no project options, so a stale seed can never change how the project is set up
    mkdir -p "$(dirname "$seed")"
    python3 - "$build_dir/CMakeCache.txt" "$seed" <<'PY'
import re, sys
entries = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = re.match(r"^([A-Za-z][A-Za-z0-9_]*):INTERNAL=(.*)$", line.rstrip("\n"))
    if not m:
        continue
    name, value = m.groups()
    if name.startswith(("CMAKE_", "Z_VCPKG", "VCPKG", "FETCHCONTENT")) or "/" in value or "$" in value:
        continue
    value = value.replace("\\", "\\\\").replace('"', '\\"')
    entries.append(f'set({name} "{value}" CACHE INTERNAL "")')
open(sys.argv[2], "w").write("\n".join(entries) + "\n")
print(f"Saved {len(entries)} CMake check results")
PY
fi

# Route C/C++/Objective-C compiles through ccache when it is installed (CI restores its cache).
# Precompiled headers are off above: a rebuilt PCH never matches the cache, so every file using it
# would miss.
ccache_args=()
if command -v ccache > /dev/null; then
    ccache_args=(
        C_COMPILER_LAUNCHER="$(command -v ccache)"
        CLANG_USE_RESPONSE_FILE=NO
        COMPILER_INDEX_STORE_ENABLE=NO
    )
fi

xcodebuild \
    -project "$build_dir/Vita3K.xcodeproj" \
    -target vita3k \
    -configuration "$config" \
    -sdk iphoneos \
    -parallelizeTargets \
    -jobs "$(sysctl -n hw.ncpu)" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    ${ccache_args[@]+"${ccache_args[@]}"} \
    build

app_path="$(find "$build_dir" -name 'Vita3K.app' -type d -path "*${config}-iphoneos*" | head -n 1)"
if [[ -z "$app_path" ]]; then
    echo "Vita3K.app not found under $build_dir" >&2
    exit 1
fi
echo "Built: $app_path"

# ---- RAM helper extension (V3KRamHelper.appex) ----
# CMake embeds it in PlugIns; copy it there if this Xcode didn't
if [[ ! -d "$app_path/PlugIns/V3KRamHelper.appex" ]]; then
    appex_path="$(find "$build_dir" -name 'V3KRamHelper.appex' -type d -path "*${config}-iphoneos*" -not -path "*/PlugIns/*" | head -n 1)"
    if [[ -n "$appex_path" ]]; then
        mkdir -p "$app_path/PlugIns"
        cp -R "$appex_path" "$app_path/PlugIns/"
        echo "Embedded $appex_path"
    else
        echo "V3KRamHelper.appex was not built" >&2
        exit 1
    fi
fi

# ---- 3DS core (Azahar, built by .ci/build-azahar-ios.sh) ----
if [[ -n "${AZAHAR_DYLIB:-}" && -f "$AZAHAR_DYLIB" ]]; then
    mkdir -p "$app_path/Frameworks"
    cp "$AZAHAR_DYLIB" "$app_path/Frameworks/libazahar_hinoki.dylib"
    echo "Embedded the 3DS core ($(du -h "$AZAHAR_DYLIB" | cut -f1))"
else
    echo "No 3DS core to embed: 3DS games won't run in this build"
fi

# ---- App icon: Hinoki ----
icon_work="$(mktemp -d)"
plist="$app_path/Info.plist"
pb=/usr/libexec/PlistBuddy

# 1. Liquid Glass icon compiled from the Icon Composer file (dist/image/Hinoki.icon)
if xcrun actool "$repo_root/dist/image/Hinoki.icon" \
        --compile "$app_path" \
        --platform iphoneos \
        --minimum-deployment-target 17.4 \
        --target-device iphone --target-device ipad \
        --app-icon Hinoki \
        --output-partial-info-plist "$icon_work/partial.plist" > "$icon_work/actool.log" 2>&1; then
    "$pb" -c "Merge $icon_work/partial.plist" "$plist" || true
    echo "Compiled Hinoki.icon"
else
    echo "actool could not compile Hinoki.icon, using PNG icons only:"
    cat "$icon_work/actool.log"
fi

# 2. PNG fallbacks (LiveContainer, older iOS): the mark on cypress green, pre-rendered
cp "$repo_root/dist/image/hinoki-icon-1024.png" "$icon_work/icon-1024.png"
if [[ -f "$icon_work/icon-1024.png" ]]; then
    for spec in "120:AppIcon60x60@2x.png" "180:AppIcon60x60@3x.png" "152:AppIcon76x76@2x~ipad.png" "167:AppIcon83.5x83.5@2x~ipad.png"; do
        sips -z "${spec%%:*}" "${spec%%:*}" "$icon_work/icon-1024.png" --out "$app_path/${spec#*:}" > /dev/null
    done
    "$pb" -c "Add :CFBundleIcons dict" "$plist" 2> /dev/null || true
    "$pb" -c "Add :CFBundleIcons:CFBundlePrimaryIcon dict" "$plist" 2> /dev/null || true
    "$pb" -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" "$plist" 2> /dev/null || true
    "$pb" -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0 string AppIcon60x60" "$plist"
    "$pb" -c "Add :CFBundleIcons~ipad dict" "$plist" 2> /dev/null || true
    "$pb" -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon dict" "$plist" 2> /dev/null || true
    "$pb" -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles array" "$plist" 2> /dev/null || true
    "$pb" -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles:0 string AppIcon76x76" "$plist"
    "$pb" -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles:0 string AppIcon83.5x83.5" "$plist"
    echo "Added PNG icons"
else
    echo "Could not render the PNG icons"
fi
rm -rf "$icon_work"

# ---- Version ----
# Marketing version: VITA3KIOS_VERSION, else a v1.2.3 tag being built, else the default in ios_bundle.cmake.
# Build number: the CI run number, so every IPA installs over the previous one as an update.
version="${VITA3KIOS_VERSION:-}"
if [[ -z "$version" && "${GITHUB_REF_TYPE:-}" == tag && "${GITHUB_REF_NAME:-}" == v* ]]; then
    version="${GITHUB_REF_NAME#v}"
fi
if [[ -n "$version" ]]; then
    "$pb" -c "Set :CFBundleShortVersionString $version" "$plist"
fi
version="$("$pb" -c "Print :CFBundleShortVersionString" "$plist")"
build_number="${GITHUB_RUN_NUMBER:-$(git -C "$repo_root" rev-list --count HEAD)}"
"$pb" -c "Set :CFBundleVersion $build_number" "$plist"
# The extension's versions must match the app's
for appex_plist in "$app_path"/PlugIns/*.appex/Info.plist; do
    [[ -f "$appex_plist" ]] || continue
    "$pb" -c "Set :CFBundleVersion $build_number" "$appex_plist"
    "$pb" -c "Set :CFBundleShortVersionString $version" "$appex_plist"
done
commit="$(git -C "$repo_root" rev-parse --short HEAD)"
"$pb" -c "Delete :V3KCommit" "$plist" 2> /dev/null || true
"$pb" -c "Add :V3KCommit string $commit" "$plist"
# The in-app updater compares version numbers in releases, commits in test builds
"$pb" -c "Delete :V3KRelease" "$plist" 2> /dev/null || true
if [[ "${VITA3KIOS_RELEASE:-0}" == 1 ]]; then
    "$pb" -c "Add :V3KRelease bool true" "$plist"
else
    "$pb" -c "Add :V3KRelease bool false" "$plist"
fi
echo "Version $version ($build_number), commit $commit"

mkdir -p "$output_dir"
staging="$(mktemp -d)"
mkdir -p "$staging/Payload"
cp -R "$app_path" "$staging/Payload/"
if [[ "${VITA3KIOS_RELEASE:-0}" == 1 ]]; then
    ipa_name="Hinoki-${version}.ipa"
else
    ipa_name="Hinoki-${version}-${commit}.ipa"
fi
(cd "$staging" && zip -qry "$ipa_name" Payload)
mv "$staging/$ipa_name" "$output_dir/"
rm -rf "$staging"

echo "IPA: $output_dir/$ipa_name"
if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "IPA_PATH=$output_dir/$ipa_name" >> "$GITHUB_ENV"
    echo "IPA_NAME=${ipa_name%.ipa}" >> "$GITHUB_ENV"
    echo "IPA_VERSION=$version" >> "$GITHUB_ENV"
    echo "IPA_BUILD=$build_number" >> "$GITHUB_ENV"
fi
