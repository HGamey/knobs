#!/bin/bash
# build_layer.sh — NDK 直编灰档只读层 libVkLayer_refknobs.so (arm64-v8a), 零交互。
# 依赖同 refbench: brew android-commandlinetools 的 ndk;28.2.13676358。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # gray/
SDK="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"
NDK="${REFBENCH_NDK:-$SDK/ndk/28.2.13676358}"
HOST_TAG=darwin-x86_64
[ -d "$NDK/toolchains/llvm/prebuilt/$HOST_TAG" ] || HOST_TAG=linux-x86_64
CXX="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/aarch64-linux-android30-clang++"
[ -x "$CXX" ] || { echo "缺 NDK clang++: $CXX" >&2; exit 1; }

OUT="$ROOT/build/out"
mkdir -p "$OUT"
# -static-libstdc++ 是硬要求, 不是优化: 层被宿主应用的 Vulkan 加载器 dlopen, 而宿主
# 应用的 lib 目录里通常没有 libc++_shared.so。动态链 STL 会在真机上直接
#   dlopen failed: library "libc++_shared.so" not found
# (2026-09-23 refbench 实测过这个失败)。静态进去 → .so 自包含, 任意目标都能挂。
# --exclude-libs ALL 把静态进来的 STL 符号藏起来, 不污染宿主的符号表。
"$CXX" -O2 -Wall -fPIC -std=c++17 -fno-exceptions -fno-rtti \
    -static-libstdc++ -Wl,--exclude-libs,ALL \
    -shared -o "$OUT/libVkLayer_refknobs.so" "$ROOT/layer/vk_layer_refknobs.cpp" \
    -llog
cp "$ROOT/layer/VkLayer_refknobs.json" "$OUT/"
echo "layer: $OUT/libVkLayer_refknobs.so ($(wc -c < "$OUT/libVkLayer_refknobs.so" | tr -d ' ') B)"
"$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/llvm-nm" -D "$OUT/libVkLayer_refknobs.so" \
    | grep -E "vkNegotiateLoaderLayerInterfaceVersion|vkGetInstanceProcAddr|vkGetDeviceProcAddr" \
    | sed 's/^/  export: /'

# 自检: 任何残留的 DT_NEEDED 动态依赖都必须是宿主进程一定已加载的系统库。
# libc++_shared 出现在这里 = 上机必炸, 当场失败而不是等真机报。
NEEDED=$("$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/llvm-readelf" -d "$OUT/libVkLayer_refknobs.so" \
    | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p')
echo "  needed: $(echo "$NEEDED" | tr '\n' ' ')"
if echo "$NEEDED" | grep -q "libc++_shared"; then
    echo "自检失败: 仍依赖 libc++_shared.so, 宿主应用 lib 目录里没有它, 上机会 dlopen 失败" >&2
    exit 1
fi
