# PC 0.2.20 启动快速失败与请求取消看门狗验收

## 0.2.20 变更与根因

- **首字节快速失败窗口**：`page.js` `candidateDeadline()`——候选从未交付任何字节时，"沉默/超时"窗口由 15 秒观察窗改为 5 秒首字节预算（`FIRST_BYTE_WINDOW_MS`）；一旦交付过字节仍保留完整 15 秒观察窗（0.2.19 设计不变）。配套改写旧 15 秒语义断言为 0/5/10：`test/page.test.cjs` ×2、`test/xhr.test.cjs` ×1、`test/chromium.cjs` silence 分支（锚定式预算 ±1 tick 风格）。
- **根因（VPS 无头 Chromium + live B 站 + 路由静默阻断首候选实测）**：只有窗口还不够。B 站播放器启动期自行 abort 每条媒体 XHR 来轮换 host（调用栈 `player/main/core.js` → `Object.abort`，实测每条在发送后 2.3–5.1 秒），脚本按 0.2.18 设计把 abort 当 `cancelled` 立即释放，`timeout/error/load` 终态从未到达 → `recoverCandidate` 一次都没进入（插桩计数为 0）；同时改写规则把播放器发往备选 host 的请求也重写回首候选，形成死锁：90 秒内 45 条媒体请求全在被阻断主机、备机 0 条、切换 0 次、`loadstart` ×3 反复重启，播放器自报 `web_videoload_fail code 4004 downloadError`。**0.2.19 与修复前 0.2.20 都是这个死法**，即"播放极为容易卡住、无法开始播放"的核心。
- **修复**：新增每资源首字节看门狗 `armCandidateWatchdog`（`page.js`，1 秒 tick）：`firstByteAt === null` 且 `candidateStartedAt + 5s` 已过且该资源仍有活跃请求（`hasActiveRequest`：在途 XHR 未取消/未结束，或 fetch 控制器未中止）时，后台 `recoverCandidate("candidate-timeout", ...)`。复用全部既有闸门（会话路径、enable、暂停、耗尽、generation、整体网络保护）与一次性提交语义，不新增切换入口；播放器已放弃且无在途请求的资源、已收字节的资源均不触发。

## 执行结果

- `node --test browser-extension/test/*.test.cjs`：**63/63**（原 61 + 新增 2 条看门狗回归：页面取消型无字节候选在 5 秒边界后切换；空闲与已收字节资源不触发）。
- `node browser-extension/test/chromium.cjs`（源码）：**34/34**。
- `USERSCRIPT_FILE=dist/PiliPlus-Adaptive-CDN-Web.user.js node browser-extension/test/chromium.cjs`：**34/34**。
- **线上受控 A/B**（`dist/.qa/online/probe7.cjs`，路由静默阻断首个媒体主机 `upos-hz-mirrorakam.akamaized.net`，VPS 无头 Chromium，live B 站）：

  | 构建 | 结果 |
  |---|---|
  | 0.2.19 基线（`baseline-0.2.19.user.js`） | 90 秒不切换（48 条全在死主机、备机 0 条），`loadstart` ×3，**始终无法开播** |
  | 0.2.20 + 看门狗（`/*DBG*/` 插桩诊断版） | 看门狗在候选起始 +5s 后提交切换 → 备机 `upos-sz-mirrorcosov.bilivideo.com` 收到响应 → **playing**（首个媒体请求后 7.3 秒完成切换） |
  | 0.2.20 + 看门狗（最终无插桩产物，阻断） | **playing**（dt 44.8s），备机响应正常，死主机仅 10 条挂起 |
  | 0.2.20 + 看门狗（最终无插桩产物，不阻断） | **playing**（dt 22.6s），0 次切换、0 次恢复（健康路径无劣化） |

- 诊断插桩（`/*DBG*/` → `window.__piliDebug`，含 abort 调用栈、恢复闸门逐项值）已全部回滚：源码 `grep DBG` = 0，产物不含 `__piliDebug`。

## 产物

由 `.tooling/powershell/pwsh -NoProfile -File browser-extension/package-userscript.ps1` 真实生成：

- `dist/PiliPlus-Adaptive-CDN-Web.user.js`
- 元数据及 manifest：**0.2.20**
- 大小：**57,533 bytes**
- SHA-256：`5cf0045a6f81bfec8dd16968319e0f958f64bdf12df4cefa79823a78964d5316`

## 限制

- 站点自身"补斜杠"客户端 reload（6.5–30.9 秒大方差，VPS IP 引起，无脚本同样存在）不被扩展消除，A/B 时间戳含该方差。
- 切换墙钟 = 5 秒窗口 + ≤1 秒看门狗 tick；无头环境实测另有约 2 秒定时器节流（首个媒体请求后 7.3 秒提交），真实前台标签页预期 5–6 秒。窗口本身精确为 `candidateStartedAt + 5000ms`（插桩日志 `dl - started = 5000`）。
- 看门狗要求"该资源仍有活跃请求"：播放器彻底放弃且无在途请求的资源不切换，与 0.2.18"最后一个请求取消后不保留后台切换"一致。
- 未做登录态、完整真实 MSE 全流程与 Android 端验证；未推送（gh 令牌缺 `workflow` 作用域）。
