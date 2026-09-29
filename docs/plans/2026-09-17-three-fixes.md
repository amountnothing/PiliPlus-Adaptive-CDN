# 三项修复方案（2026-09-17，待实现）

仓库：`/home/hermes-ops/workspace/piliplus-adaptive-db`。实现前按 `AGENTS.md` 读两份必读文档、`git status --short`，保留所有未提交改动；先写失败测试再修；不 commit/push；Android 构建按 `.tooling/fix2-logs/build_release.py` 的低内存方式。

---

## 方案 1：浏览器扩展 / 油猴 0.2.18 难以加载视频

### 现状与怀疑点（代码证据）
- `browser-extension/page.js:48` `CANDIDATE_WINDOW_MS = 15_000`；`:305-337 recoverCandidate` 让**任何**失败（含即时 403/404）都等满 15 秒剩余窗口再切换。这是为修“10 秒遍历完”加的，但副作用是：首个候选即时失败时，播放器要空等 15 秒才拿到下一候选，并且 `:476` 每个 Range 请求也是 15 秒超时——首帧最坏 15 s×候选数。
- `:345-356` `pause` 事件把 `userPaused=true` 并 abort 所有等待中的请求。B 站播放器在起播/换清晰度时会自己触发 `pause`/`play`，可能把正在重试的请求全部打断，且 `play` 后只重置 `candidateStartedAt`，不重新发起请求 → 表现为"卡住不加载"。
- fatal MSE 后只提示手动重载（`:358` 注释），没有主动恢复路径。

### 目标行为
1. **区分"确定失败"和"沉默"**：HTTP 4xx/5xx、`TypeError` 网络错误 → 短冷却（默认 2 s，可配置）后切下一候选；只有"连接建立但无字节"或超时才等满 15 s 窗口。保留"同资源同代次只推进一次"的事务语义（`recoverCandidate` 的 owners/generation 不动）。
2. **`pause` 不 abort 已在重试中的请求**，只暂停新的等待；`play` 时若资源仍有 `pending` 但无在途请求，主动重发最后一次失败的 Range。
3. 起播保护：首个候选在**首字节到达前**允许更短窗口（例如 5 s），首字节到达后再用 15 s。
4. 日志只记录切换/恢复摘要，不加逐请求日志。

### 测试（先 RED）
- `browser-extension/test/page.test.cjs` + `clock.cjs`：
  - 即时 403 ×3 候选：切换时间点应为 0/2/4 s（不再 0/15/30）；沉默超时仍为 0/15/30 s。
  - 播放器自动 `pause`→`play` 期间的在途重试不被 abort，且 `play` 后 300 ms 内有重发请求。
  - 首字节前超时 5 s、首字节后 15 s。
- Chromium 路由场景 `test/chromium.cjs` 各加一项，源码与打包脚本都要过。
- 打包：`browser-extension/package-userscript.ps1`（`.tooling/powershell/pwsh`）→ `dist/PiliPlus-Adaptive-CDN-Web.user.js`，版本 0.2.19，给 sha256。

### 验收
Node、Chromium 源码/打包全部通过；README/`RETRY-0.2.18.md` 更新为新窗口定义；`docs/PROJECT_CONTEXT.md` 同步默认参数。

---

## 方案 2：安卓端连续碎片化卡顿不切换 CDN

### 现状（代码证据）
`lib/pages/video/controller.dart:1090-1244 _checkCdnHealth`（每 1 s）：
- 切换条件只有两类：**PTS 冻结 8 s**（`:1174-1213`）和**持续低缓冲**（`:1267-1305 _shouldSwitchForPersistentLowBuffer`）。
- 低缓冲判定要求前向缓冲在整个 `_bufferStallTimeout` 窗口内始终 ≤ `_refillForwardBuffer`（`:1271-1274` 一旦超过就 `_resetLowBufferWatch` 归零），并且净增长 < `minGrowth`。
- "碎片化卡顿"= 缓冲反复在阈值上下跳、每次卡 0.5–2 s 后又动：每次缓冲越过阈值就把计时器清零，PTS 也从不连续冻结 8 s → 两个条件都永远不满足，因此不切换。`_lowBufferTriggered` 也只允许一次触发。

### 目标行为
新增第三类判定：**滑动窗口内的 rebuffer 计数**。
- 在 `lib/utils/adaptive_playback.dart` 加纯函数  
  `shouldSwitchForFragmentedStalls({required List<DateTime> stallStarts, required DateTime now, required Duration window, required int minStalls, required Duration minTotalStall})`  
  语义：最近 `window`（默认 30 s）内 ≥ `minStalls`（默认 3）次 `isBuffering` 由 false→true，且累计缓冲时长 ≥ `minTotalStall`（默认 3 s）→ 返回 true。
- `VideoDetailController` 用 `plPlayerController.isBuffering` 监听记录 stall 起止（不是每秒轮询写日志），在 `_checkCdnHealth` 里调用；触发后 `_switchToNextCdn(reason: 'fragmented-stall')`，复用现有切换预算 `_videoCdnSwitchCount/_maxCdnSwitches`，切换后清空窗口。
- 排除项：seek 后 3 s 内的 rebuffer（已有 `_lastSeekRebufferAt`）、手动暂停、`hasReachedContentEnd`、`_switchingCdn`。
- 参数放 `Pref`（`adaptiveFragmentStallWindowSec/Count/TotalSec`），设置页可选，不改现有默认 30/10 s 键。

### 测试（先 RED）
- `test/video_utils_test.dart`：纯函数——3 次/30 s 触发；2 次不触发；seek 窗口内的不计；切换后窗口清空。
- `test/adaptive_buffer_policy_test.dart`：用临时 Hive 盒确认默认值与 `lowLatencyBufferOptions`（4 s 前向队列）不冲突：正常播放小缓冲不应被记为 stall（stall 只由 `isBuffering` 事件定义，不由缓冲量定义）。

### 验收
`flutter test` 全通过（当前基线 80）；`flutter analyze` 相关文件无 issue；日志新增一条 `fragmented-stall count=.. windowMs=.. totalStallMs=..` 摘要；`docs/PROJECT_CONTEXT.md` 记录新判定。

---

## 方案 3：安卓端播放时未保持"播放状态"，到时自动息屏

### 现状（代码证据）
`lib/plugin/pl_player/controller.dart:1062-1099`：
- Wakelock 只在 `stream.playing` 事件里 `WakelockPlus.toggle(enable: playing)`（`:1086`）；`_isReplacingMedia` 期间直接 `return`（`:1085`）。
- 自适应 CDN 切换 / Relay 重开 / 冻结恢复会多次替换媒体：mpv 在切换时发 `playing=false`（Wakelock 关），随后重新 `playing=true` 若落在 `_isReplacingMedia==true` 期间就被跳过 → Wakelock 之后一直是关闭，屏幕到系统超时即息屏。
- 另外 `stream.buffering` 长时间 buffering 时 mpv 也可能报 `playing=false`，同样关锁，即使用户意图仍是播放（`playbackRequested==true`）。
- 第一阶段修复只处理了"释放"方向（`:1075`、`:2134`），没有处理"重新获取"。

### 目标行为
Wakelock 的真值来源改为**用户播放意图**，而不是原生瞬时事件：
- 新增纯函数 `AdaptivePlayback.shouldHoldWakelock({required bool playbackRequested, required bool isInBackground, required bool continuePlayInBackground, required bool onlyPlayAudio})`：`playbackRequested && !isInBackground`（后台仅音频不需要亮屏）。
- 在 `PlPlayerController` 增加 `_syncWakelock()`，在以下点调用：`playbackRequested` 变化、`_isReplacingMedia` 置 false 之后、`stream.playing`/`stream.buffering` 事件后、生命周期 resume。`stream.playing` 里的 `toggle(enable: playing)` 改为调用 `_syncWakelock()`。
- 显式 `pause()`、dispose、退到后台仍立即 `disable`（保留现有释放逻辑）。
- 同步 `videoPlayerServiceHandler.onStatusChange`：buffering 且 `playbackRequested` 时通知栏状态保持 playing/buffering，而非 paused（这是用户看到的"没有定义为播放状态"）。

### 测试（先 RED）
- `test/video_utils_test.dart`：`shouldHoldWakelock` 四种组合。
- `PlPlayerController` 逻辑难以单测原生插件，用可注入的 `WakelockGateway` 接口（默认包 `WakelockPlus`），测试用 fake 记录 enable/disable 序列：`play → replaceMedia(begin/end) → 应以 enable 结束`；`play → buffering=true → 仍 enable`；`pause → disable`；`背景无 continuePlayInBackground → disable`。

### 验收
测试通过；`flutter analyze` 干净；真机：播放 >系统息屏时间不熄屏，暂停后正常熄屏，CDN 切换一次后仍不熄屏。

---

## 交付
- 每个方案独立提交为一组改动（不 commit，由用户决定），产物：油猴 0.2.19 `dist/*.user.js`；Android `2.1.3-adaptive-fix3`（`.tooling/pili_release_fix3.json`，`--split-per-abi --target-platform android-arm64`，Gradle 临时 1536m/768m 单 worker，结束恢复）。
- 报告格式：根因代码行、RED→GREEN 测试名与数量、产物路径与 sha256、未真机验证项。
