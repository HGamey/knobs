# 问题 2 实测结果: 目标游戏挂只读空层 —— 部分成立

设备 NX809J / Android 16 / user 版 / Magisk root, 目标 `com.miHoYo.Yuanshen`
版本 `7.0.0_47144228_47194594`, 2026-09-23 20:41–20:46

## 结论一句话

**层挂进了原神, 游戏没崩、没被反作弊杀掉, 连续跑了约 5 分钟 / 5700 帧;
但没能进大世界 —— 被一个"强制更新客户端"的公告挡在登录界面, 与本层无关。**

所以"客户端侧反作弊放行"有证据, "登录后 / 大世界里放行"**没有**证据。

## 成立的部分

层确实加载进了原神进程 (logcat_genshin.vulkan.txt):

    D vulkan  : added global layer 'VK_LAYER_refknobs_readonly' from library
                '/data/app/~~qroZ.../com.miHoYo.Yuanshen-fposm.../lib/arm64/libVkLayer_refknobs.so'
    I vulkan  : Loaded layer VK_LAYER_refknobs_readonly
    I refknobs: rk_CreateInstance entered (pkg=com.miHoYo.Yuanshen)
    I refknobs: next vkCreateInstance -> 0

`Loaded layer` 共 6 次 (两次启动 x 实例/设备)。层的计数一直在涨, 最终:

    {"knob":"gray_readonly_probe","layer_loaded":true,"pkg":"com.miHoYo.Yuanshen",
     "effective":[],"failed":[],"unavailable_reason":null,
     "readonly_stats":{"frames":5700,"render_pass_begins":152196}}

约 26.7 个 render pass / 帧。层能写进原神自己的外部 files 目录, 文件通道可用。

稳定性核查 (按 logcat 优先级字段精确过滤, 不靠关键词猜):
- 原神进程无 F(atal) 级日志、无 tombstone、无 SIGSEGV/SIGABRT
- 无反作杯模块告警。(一次 `tprotect` 命中是误报, 实为 `android.view.contentprotection.flags`)
- 唯一的 FATAL 来自厂商应用 `cn.nubia.gameassist` (`HWUI Assertion failed`),
  不是原神; 该应用 lib 目录里没有本层的 .so, 未确认与本层有因果关系 —— 待复测

## 没成立的部分 (失败原因如实记)

进不了大世界。原神启动 → 用户协议更新弹窗 → 重启 → 登录界面弹**强制更新公告**:

> 发现新版本, 请点击下方按钮下载最新客户端。完成本次更新后登录即可获得 300 原石。

截图 `genshin_update_required.png`。装机版本 7.0.0 已落后于服务端要求版本,
不更新客户端**登录不了**, 因此:

- 没有验证"登录态 + 大世界"下反作弊是否放行 —— 这才是判据最硬的那一环
- 也没拿到大世界负载下的 render pass 归因数据

**没有擅自点"确认"开始下载客户端**: 那是数 GB 的下载, 会占用共享设备,
而且会把游戏版本改掉 —— phonefarm/loop_v1 的基线数据是在当前版本上采的,
换版本等于作废历史基线。这个决定该由人来拍。

## 顺带记录的两件事

1. 启动过程中出现"用户协议和隐私政策更新"弹窗, 必须点「接受」游戏才肯起。
   已点。这是启动游戏的前置条件, 不是本层造成的。
2. 原神自己的 lib 目录里**有** `libc++_shared.so`。也就是说动态链 STL 的层
   在原神上本来能跑 —— 但在 refbench 上不能。静态链仍是正确选择 (与宿主无关)。

## 证据文件

| 文件 | 内容 |
|---|---|
| `step2_enable.txt` | 挂层命令与 status 回读 |
| `logcat_genshin.vulkan.txt` | logcat 中 vulkan/refknobs/GraphicsEnvironment 相关行 |
| `knobs_layer_out.genshin.json` | 层最终计数 |
| `logcat_genshin.fatal.txt` | 全部 F 级日志 (只有厂商 gameassist, 无原神) |
| `genshin_t40s.png` | 用户协议弹窗 |
| `genshin_after_eula.png` | 接受后重启, miHoYo 启动画面 |
| `genshin_update_required.png` | 登录界面的强制更新公告 (卡住的地方) |
