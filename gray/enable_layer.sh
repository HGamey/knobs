#!/bin/bash
# enable_layer.sh {probe|target <pkg>|status|off} — 挂/摘灰档只读层 (FEASIBILITY 问题 1/2)
#
#   probe            对 refbench 挂层, 验"机制能挂上非 debuggable 应用" (问题 1)
#   target <pkg>     对目标游戏挂空层, 看能否正常进游戏 (问题 2 反作弊)
#   status           只读打印当前挂载状态
#   off              摘层并删掉推进去的 .so, 还原
#
# ── 机制 (2026-09-23 在 NX809J / Android 16 / user 版 + Magisk root 上逐条实测) ──
#
# 生效只需要两件事, 缺一不可:
#   1. libVkLayer_refknobs.so 放进**目标应用自己的 nativeLibraryDir**
#      —— 加载器对每个应用都默认搜这个目录 (实测: 无关的系统应用 cn.nubia.gamelab
#         启动时也在搜它自己的 lib 目录), 所以不需要应用 debuggable
#   2. `setprop debug.vulkan.layers <层名>`
#
# 实测**不需要**的东西 (README 早先写的那套, 在这台 ROM 上一条都不生效):
#   - settings put global enable_gpu_debug_layers / gpu_debug_app /
#     gpu_debug_layers / gpu_debug_layer_app
#     → 框架侧 GraphicsEnvironment 因为应用非 debuggable 且 ro.debuggable=0 直接跳过,
#       logcat 里连 "GPU debug layers enabled" 都不打。全程无效。
#   - ro.debuggable=1 (resetprop 改过再改回, 对本机制无影响)
#   四格对照矩阵见 evidence/01_probe_refbench/matrix.txt
#
# ⚠ debug.vulkan.layers 是**全局**属性: 它对之后启动的每个 Vulkan 应用都生效。
#   实际作用域由 .so 的落点决定 —— 只有 lib 目录里放了这个 .so 的应用才真的加载它。
#   即便如此, off 要尽早做, 别把属性留在设备上影响别人。
#
# 证据双通道: 应用外部 files 目录的 knobs_layer_out.json;
#   以及 `adb shell su -c 'logcat -b main' | grep refknobs`
#   (本机 logcat 只是对 shell uid 不可读, root 读一切正常 —— 立项时记的"logcat 哑掉"不准确)
set -uo pipefail

SERIAL="${REFBENCH_SERIAL:-91253241019A}"
LAYER_NAME="VK_LAYER_refknobs_readonly"
SO="libVkLayer_refknobs.so"
STATE="/data/local/tmp/knobs_layer_state"       # 存"把 .so 推进了哪个包", 供 off 精确回滚
OUT="$(cd "$(dirname "$0")" && pwd)/build/out"
ashell() { adb -s "$SERIAL" shell "$@" </dev/null; }

# 解析一个包的 nativeLibraryDir —— 加载器真正会搜的那个目录
native_lib_dir() {
  local pkg="$1" legacy
  legacy=$(ashell "dumpsys package $pkg | grep -m1 legacyNativeLibraryDir" \
           | sed 's/.*legacyNativeLibraryDir=//' | tr -d '\r')
  [ -n "$legacy" ] || return 1
  if ashell "su -c 'test -d \"$legacy/arm64\"'" >/dev/null 2>&1; then
    echo "$legacy/arm64"
  else
    echo "$legacy"
  fi
}

mount_layer() {
  local pkg="$1" dir
  [ -f "$OUT/$SO" ] || { echo "先跑 build_layer.sh 出 $SO" >&2; exit 1; }
  dir=$(native_lib_dir "$pkg") || { echo "解析不到 $pkg 的 nativeLibraryDir" >&2; exit 1; }
  adb -s "$SERIAL" push "$OUT/$SO" "/data/local/tmp/$SO" >/dev/null || exit 1
  # 属主与 SELinux 上下文对齐同目录既有 .so, 否则应用读不到
  ashell "su -c 'cp /data/local/tmp/$SO \"$dir/\" && chmod 755 \"$dir/$SO\" \
          && chown system:system \"$dir/$SO\" && chcon u:object_r:apk_data_file:s0 \"$dir/$SO\"'"
  ashell "su -c 'echo \"$pkg|$dir\" > $STATE'"
  ashell "su -c 'setprop debug.vulkan.layers $LAYER_NAME'"
  ashell "su -c 'ls -laZ \"$dir/$SO\"'"
  echo "已挂层于 $pkg"
  echo "  .so:  $dir/$SO"
  echo "  prop: debug.vulkan.layers = $(ashell 'getprop debug.vulkan.layers' | tr -d '\r')"
  echo "查证据:"
  echo "  adb -s $SERIAL shell su -c 'cat /storage/emulated/0/Android/data/$pkg/files/knobs_layer_out.json'"
  echo "  adb -s $SERIAL shell su -c 'logcat -b main -d' | grep refknobs"
}

case "${1:-}" in
  probe)   mount_layer "${2:-io.github.hgamey.refbench}" ;;
  target)
    [ -n "${2:-}" ] || { echo "target 要给包名" >&2; exit 2; }
    mount_layer "$2" ;;
  status)
    echo "debug.vulkan.layers = [$(ashell 'getprop debug.vulkan.layers' | tr -d '\r')]"
    st=$(ashell "su -c 'cat $STATE 2>/dev/null'" | tr -d '\r')
    if [ -n "$st" ]; then
      echo "state = $st  (处于施加态)"
      ashell "su -c 'ls -laZ \"${st#*|}/$SO\" 2>&1'"
    else
      echo "state = <无>  (未施加)"
    fi ;;
  off)
    ashell "su -c 'setprop debug.vulkan.layers \"\"'"
    st=$(ashell "su -c 'cat $STATE 2>/dev/null'" | tr -d '\r')
    if [ -n "$st" ]; then
      dir="${st#*|}"
      ashell "su -c 'rm -f \"$dir/$SO\"'"
      ashell "su -c 'test -e \"$dir/$SO\"'" >/dev/null 2>&1 \
        && echo "警告: $dir/$SO 没删掉" || echo "已删除 $dir/$SO"
    fi
    # 兜底扫一遍: state 文件只记得最后一次挂在哪, 手动推过 / 上一次异常退出留下的
    # 副本它不知道。.so 文件名是我们独有的, 按名字全盘清理不会误伤。
    stray=$(ashell "su -c 'find /data/app /data/data /data/local/tmp -name \"$SO\" 2>/dev/null'" | tr -d '\r')
    if [ -n "$stray" ]; then
      echo "$stray" | while read -r f; do
        [ -n "$f" ] && ashell "su -c 'rm -f \"$f\"'" && echo "已清理残留 $f"
      done
    fi
    ashell "su -c 'rm -f $STATE /data/local/tmp/$SO'"
    # 立项时那套 settings 本来就不生效, 但早先版本写过, 一并清干净
    ashell "settings delete global gpu_debug_layers" >/dev/null 2>&1
    ashell "settings delete global gpu_debug_layer_app" >/dev/null 2>&1
    ashell "settings delete global gpu_debug_app" >/dev/null 2>&1
    ashell "settings delete global enable_gpu_debug_layers" >/dev/null 2>&1
    echo "已摘层。回读:"
    echo "  debug.vulkan.layers = [$(ashell 'getprop debug.vulkan.layers' | tr -d '\r')]"
    echo "  state               = [$(ashell "su -c 'cat $STATE 2>/dev/null'" | tr -d '\r')]"
    for K in enable_gpu_debug_layers gpu_debug_app gpu_debug_layer_app gpu_debug_layers; do
      printf '  %-20s = %s\n' "$K" "$(ashell "settings get global $K" | tr -d '\r')"
    done ;;
  *)
    echo "用法: enable_layer.sh {probe|target <pkg>|status|off}" >&2
    exit 2 ;;
esac
