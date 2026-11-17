#!/usr/bin/env bash
# Hinoki's 3DS core: Azahar (pinned below) built for iOS as libazahar_hinoki.dylib with the frontend
# in vita3k/ios/n3ds/azahar. build-ios.sh puts it in the app's Frameworks folder.
#
# Usage: .ci/build-azahar-ios.sh <output-dir>
set -euo pipefail

AZAHAR_REPO="https://github.com/azahar-emu/azahar.git"
AZAHAR_COMMIT="11eceda5e0e682a1f44e396bf954a1b9137097ca"

output_dir="${1:-artifacts}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work="${AZAHAR_WORK_DIR:-$repo_root/build/azahar}"
source_dir="$work/src"
build_dir="$work/build"

mkdir -p "$work" "$output_dir"
if [[ ! -d "$source_dir/.git" ]]; then
    git init -q "$source_dir"
    git -C "$source_dir" remote add origin "$AZAHAR_REPO"
fi
if [[ "$(git -C "$source_dir" rev-parse HEAD 2> /dev/null || true)" != "$AZAHAR_COMMIT" ]]; then
    git -C "$source_dir" fetch -q --depth 1 origin "$AZAHAR_COMMIT"
    git -C "$source_dir" checkout -q --force FETCH_HEAD
fi
git -C "$source_dir" submodule update --init --recursive --depth 1 --jobs 8

# Undo earlier edits, then apply Hinoki's (idempotent anyway)
git -C "$source_dir" checkout -q -- src 2> /dev/null || true
git -C "$source_dir" submodule foreach -q --recursive 'git checkout -q -- . 2> /dev/null || true'
python3 "$repo_root/vita3k/ios/n3ds/azahar/apply.py" "$source_dir"

launcher=()
if command -v ccache > /dev/null; then
    launcher=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

cmake -S "$source_dir" -B "$build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="-DHAVE_HINOKI_SINK" \
    -DCMAKE_CXX_FLAGS="-DHAVE_HINOKI_SINK" \
    -DCITRA_USE_PRECOMPILED_HEADERS=OFF \
    -DCITRA_WARNINGS_AS_ERRORS=OFF \
    -DENABLE_LTO=OFF \
    -DENABLE_QT=OFF -DENABLE_QT_TRANSLATION=OFF \
    -DENABLE_SDL2=OFF \
    -DENABLE_WEB_SERVICE=OFF \
    -DENABLE_SCRIPTING=OFF \
    -DENABLE_GDBSTUB=OFF \
    -DENABLE_OPENAL=OFF \
    -DENABLE_CUBEB=OFF \
    -DENABLE_LIBUSB=OFF \
    -DENABLE_TESTS=OFF \
    -DENABLE_ROOM=OFF \
    -DENABLE_DISCORD_RPC=OFF \
    -DENABLE_VULKAN=ON \
    -DENABLE_SOFTWARE_RENDERER=ON \
    -DUSE_SYSTEM_MOLTENVK=ON -DMOLTENVK_LIBRARY=unused \
    "${launcher[@]}"

cmake --build "$build_dir" --target azahar_hinoki -- -j "$(sysctl -n hw.ncpu 2> /dev/null || nproc)"

dylib="$(find "$build_dir" -name 'libazahar_hinoki.dylib' -type f | head -n 1)"
if [[ -z "$dylib" ]]; then
    echo "libazahar_hinoki.dylib was not built" >&2
    exit 1
fi
cp "$dylib" "$output_dir/libazahar_hinoki.dylib"
strip -x "$output_dir/libazahar_hinoki.dylib"
install_name_tool -id "@rpath/libazahar_hinoki.dylib" "$output_dir/libazahar_hinoki.dylib"
echo "3DS core: $output_dir/libazahar_hinoki.dylib ($(du -h "$output_dir/libazahar_hinoki.dylib" | cut -f1))"
