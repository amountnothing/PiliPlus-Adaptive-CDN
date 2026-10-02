# 直播三症状修复（2026-10-02，TDD 已实现）

仓库 `/home/amountnothing/workspace/piliplus-adaptive-db`（分支 main，基于上游 2.1.5 合并后基线 `b3c82f992`）。
流程：先按旧语义抽 `@visibleForTesting` 测试缝 → 写 RED 测试确认 6 项失败 → 最小修复 → 9 项 GREEN → 全量回归。
测试文件 `test/live_fixes_test.dart`（新建，需 `.gitignore` 白名单 `!/test/live_fixes_test.dart`，否则被 `test*`/`/test/*` 规则忽略）。

---

## 症状 A：直播屏蔽规则拉取挂起/失败 → 播放器不出画面、错误外泄

- **症状**：进入直播间后播放器区域不渲染，或 `queryLiveUrl` 抛出未处理异常。渲染门槛在
  `lib/pages/live_room/view.dart:259`：`_liveRoomController.isLoaded.value && plPlayerController.isLive`。
- **根因**：`lib/pages/live_room/controller.dart:260-269`（旧）用
  `await Future.wait([?initLiveUrl(...), if (!isLoaded.value && Accounts.heartbeat.isLogin) _fetchBlockRules()]); isLoaded.value = true;`
  —— `isLoaded` 同时等“流地址初始化”和“规则拉取”，而旧 `_fetchBlockRules`（旧 :447-457）自身无 catch：
  规则接口挂起 → `isLoaded` 永不置位（播放器永不渲染）；规则接口抛错 → `Future.wait` 失败 →
  `isLoaded` 不置位且异常沿 `queryLiveUrl` 外泄。
- **修复位置**（`lib/pages/live_room/controller.dart`）：
  - 调用点 `:261-271`：改为 `await debugLoadStreamAndRules(() => initLiveUrl(...), 条件 ? _fetchBlockRules : null)`；
    “未登录不拉、已拉不重复”的条件判断留在调用点，规则回调用 tearoff `_fetchBlockRules`。
  - 测试缝 `:449-466` `@visibleForTesting debugLoadStreamAndRules(initLiveUrl, fetchBlockRules)`：
    规则 future `ignore()` fire-and-forget（不阻塞、错误不外泄），只 `await initFuture`，
    成功后 `isLoaded.value = true`（initLiveUrl 抛错仍外传且不置位，保持旧语义）。
  - `_fetchBlockRules` `:468-486`：`try/catch` + `@pragma('vm:notify-debugger-on-exception')`，
    kDebugMode 下 `Utils.reportError`；只在成功响应时写 `_keywordList/_shieldUids`。
- **测试**（`test/live_fixes_test.dart` A 组，3 项）：
  1. 规则拉取挂起（`Completer` 永不完成）时 `isLoaded` 仍会置位 —— RED；
  2. 规则拉取抛错时错误不外泄且 `isLoaded` 置位 —— RED；
  3. `initLiveUrl` 抛错仍向外传播且不置 `isLoaded` —— 对照守卫（新旧语义都绿）。

## 症状 B：直播期间视频控制器仍跑自适应 CDN 健康检查

- **症状**：`PlPlayerController` 是单例，`isLive` 由现有生命周期翻转
  （`lib/pages/live_room/view.dart:120-123 didPopNext` 置 true，`lib/pages/video/view.dart:407` 置 false）；
  直播间压栈期间，视频控制器的 `_cdnHealthTimer`（`lib/pages/video/controller.dart:920`）与
  `isBuffering` worker（`:431`）仍在跑。直播没有有限时长、缓冲停在直播边缘，
  低缓冲/内容结束/碎片化卡顿判定在直播语义下误判 → 可能误触发 CDN 切换、把直播缓冲计入视频的碎片化卡顿窗口。
- **修复位置**（`lib/pages/video/controller.dart`）：
  - `:1120` `_checkCdnHealth()` 开头 `if (plPlayerController.isLive) return;`
    （注意该处同时跳过了 `:1124` 起的 `_cdnRelaySession?.setPlaybackPaused(...)` 同步，
    暂停状态仍由 `_relayPlaybackIntentWorker`（`:425`）在 `playbackRequested` 变化时维护）；
  - `:1306` `_onIsBufferingChanged()` 开头同一条 guard。
  - 测试钩子 `:1102-1114`：`debugCheckCdnHealth` / `debugOnIsBufferingChanged` /
    `debugLowBufferWatchActive` / `debugFragmentStallCount`。
  - 未新增任何生命周期机制（view 层 `didPopNext`/返回置位已足够）。
- **测试**（B 组，4 项）：
  1. `isLive=true` 时 `debugCheckCdnHealth()` 不置 `_lowBufferStutterSince` —— RED；
  2. 非 live 对照：同一调用会置 `_lowBufferStutterSince` —— 守卫生效证明；
  3. `isLive=true` 时 `debugOnIsBufferingChanged(true)` 不写 `_fragmentStallStarts` —— RED；
  4. 非 live 对照：会写入 1 条 —— 守卫生效证明。

## 症状 C：空串关键词吞掉全部弹幕

- **症状**：关键词列表含 `''` 时，`isBlocked` 对任意文本恒真，`prefetch`（`live_room/controller.dart:425`）
  和消息流过滤把所有弹幕都拦掉，直播间弹幕全空。
- **根因**：`lib/pages/live_room/controller.dart:464-465`（旧）
  `_keywordList.any(text.contains)` —— `text.contains('')` 恒为 true。
- **修复位置**：`:493-498`，判断改为
  `_keywordList.any((k) => k.isNotEmpty && text.contains(k)) || _shieldUids.contains(uid)`。
  `_shieldUids` 是 `Set<int>`，空串/非 int 的 uid 由运行时类型检查天然排除，无需额外分支。
- **测试**（C 组，2 项）：`updateBlockRules(['','spam'], {})` 后 `isBlocked('hello',1)==false`
  且 `isBlocked('spam hit',1)==true` —— RED；屏蔽 uid `7` 命中、`8` 不命中 —— 守卫。

---

## 验证结果

- RED：`flutter test test/live_fixes_test.dart` → **6 失败 / 3 通过**（失败项即 A1、A2、B1、B3、C1、C2）。
- GREEN：修复后同文件 **9/9 通过**。
- 全量 `flutter test`：**106 通过**（基线 97 + 新增 9）。首轮 `cdn_relay_server_test`
  出现 1 项时序 flake（`times out silent upstream response headers`，二次单跑换成另一项
  `body silence closes without splicing...` 也 flake，第三次单文件 28/28 全过）——已知既有偶发问题，非本次回归。
- `flutter analyze` 定向三个改动文件（含测试）：**0 issue**；全量 **38 条**，与合并前基线一致。
- 索引：`tool/generate_codebase_index.ps1`（`.tooling/powershell/pwsh`）重生成
  `docs/SOURCE_FILE_INDEX.md`、`docs/SYMBOL_INDEX.md`（上次生成于 2026-09-13，本次一并追平 2.1.5 合并与本次改动）。

## 真机未验证项

1. 真实网络下规则接口挂起/5xx 时，直播间仍正常出画面（需弱网或抓包工具模拟）。
2. 直播间停留期间不再出现误触发的 CDN 切换/重建（需真机开播直播间观察 `AdaptivePlayback` 日志）。
3. 服务端是否会下发空串关键词未知——C 是防御性修复，真实空关键词房间未复现过。
4. `isLive` 期间 `_checkCdnHealth` 内的 relay 暂停同步被跳过：视频页被直播间压栈时切后台，
   `_relayPlaybackIntentWorker` 只监听 `playbackRequested`，不监听 `_isInBackground` 变化——该组合场景未验证。
5. 未构建 APK、未安装真机、未 push。