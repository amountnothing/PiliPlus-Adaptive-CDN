# PC 0.2.19 收尾验收

## 0.2.19 变更与根因

- **确定失败短冷却**：HTTP 403/404/5xx、`TypeError` 等确定失败不再等满 15 秒候选窗口，改等 `failCooldownMs`（默认 2000ms，可配置 0–15000）后切下一候选；"沉默"（连接建立无字节/超时）仍等满窗口。切换时间点：确定失败 0/2/4s，沉默 0/15/30s。
- **XHR 耗尽路径终态分发修复**（根因，`page.js`）：XHR 403 置 `state.pending` 后，切换提交路径 `switchCdn→abortInflightMedia`（约 `page.js:246`）跳过 pending 请求，重试只由 `recoverCandidate().then`（约 `page.js:661-677`）经 `setTimeout(0)` 调度；该宏任务在 Playwright 虚拟时钟 runFor 窗口边界之后才触发，导致晚一个冷却。修复：`recoverCandidate().then` 提交后不再经假时钟定时器，直接调度 XHR 重试终态分发（`fireXhrRetry`），并在提交后对已推进 generation 的重试不再做反向防护。
- **pause 不再 abort 在途重试**：播放器自动 pause 只阻止新的恢复等待；在途重试存活并在冷却到期后重发下一候选；play 后 300ms 内有重发。

## 0.2.19 执行结果

- `node --test browser-extension/test/*.test.cjs`：61/61。
- `node browser-extension/test/chromium.cjs`（源码）：34/34。
- `USERSCRIPT_FILE=dist/PiliPlus-Adaptive-CDN-Web.user.js`：34/34。
- options 页新增"确定失败冷却"（`failCooldownMs`，0–15000ms，默认 2000）。
- **测试夹具确定性收尾**（仅 `test/chromium.cjs`，未动产物）：非 clock 段加速比 ×100→×10（原 ×100 把 5 s 首字节预算压成 50 ms，与真实 Chromium 网络往返竞争，约 1/40 概率误报超时）；clock 段 `pauseAt` 改为对 install 漂移免疫的 `pauseClock`（Playwright clock 控制器 real-time-sync 启动，>100ms CDP 往返会让 `pauseAt(同一时间点)` 抛 "fast-forward to the past"）；xhr.timeout 仅 timeout 场景保留 50（XHR 原生超时是真实时间，其余场景改 5000 避免 403 回送 >50ms 时把恢复路径变成静默窗口导致预算错位）；403/timeout 段改为切换锚定式预算，±1 tick 调度抖动不再落在错侧；计数应增长的断言改用有界 `settle`，"不得变化"断言仍为纯 flush，早期切换仍会立即失败。验收：打包产物连续三轮 exit=0、34/34 PASS（探针 `test/probe-clock-flake.cjs` 可复现三类 flake）。

# PC 0.2.18 重试修复验收

## 根因与行为

0.2.17 的 fetch 在收到 403 等确定失败后先清理 15 秒响应头计时器，随后直接切换并继续 while；XHR 在 DONE 故障后直接切换并安排零延迟重试。15 秒只覆盖单次未收到响应头，不约束一个 CDN 的观察时间。原有主机检查能挡住一部分迟到失败，但没有统一的候选级事务；fatal 和健康检测另有直接切换入口。不能将并发 12 次请求误解为 12 次切换：最初 RED 确认的是 4 路请求在零测试时间内各遍历 A/B/C。

`page.js` 的 `recoverCandidate` 现在以资源/代次合并恢复 Promise、取消信号、调用者所有权及 15 秒截止时间，`switchCdn` 仅在协调器确认代次后提交自动切换。HTTP 403/404/5xx **也等待候选剩余窗口**，不是收到错误立即换。若候选已经观察超过 15 秒，则无需再额外等完整 15 秒。首次请求启动初代计时，切入下一代重新计时；手动换源可以立即执行。

- 四路同 URL 的不同 Range 共用一个切换事务，原请求各自保留 Range/options 重试；fetch/XHR 混用也一样。
- 原网络保护保留，但按候选而不是每个 Range 采样，每代至多一次额外的有界保护等待。
- 音视频独立预算、失败集合及创建时冷却快照；跨会话仍使用全局冷却，排序仍使用全局评分。重复 playurl 不会因另一轨的全局冷却而旁路改选。
- 暂停、换视频、禁用可立即取消等待；请求 abort 只释放自己的份额，最后一个请求取消后不留后台自动切换。健康/fatal 若另行持有恢复意图，则不因单个网络调用者取消而丢弃；暂停/退休仍取消全部。
- XHR 在隐藏 DONE 故障期间的 abort 显式补发一次 abort/loadend；最终失败只向各原始请求公开一次。fetch 最终 HTTP 响应体保持可读。
- 不调整 Dart/Android，不自动 play/seek，不替换 video/MSE，不猜测网页重载 API。

## 执行结果

- `node --test browser-extension/test/*.test.cjs`：**58 passed，0 failed/cancelled/skipped**。
- `node browser-extension/test/chromium.cjs`：**32 passed**。
- `USERSCRIPT_FILE=dist/PiliPlus-Adaptive-CDN-Web.user.js node browser-extension/test/chromium.cjs`：**32 passed**。
- Node 可控时钟覆盖：HTTP/拒绝/超时、四路并发只推进一次、0/15/30 秒三个请求批次及 45 秒终止、旧代次、剩余窗口、音视频预算、playurl 重注册、pause/reset/abort/disable、所有权独立、fatal/健康合并、整体网络保护有限结束。
- Chromium 每种构建包含原有 20 个原生传输/手动/reset/fatal 场景，以及 fetch、XHR、混合三类各 4 个精确时钟场景（403、超时、暂停、换视频）。HTTP 来自路由响应，超时来自原生 XHR 或中止原生 fetch；检查前 10 秒/14.999 秒未换候选、每代窗口、有限终止和每代 Range 多重集合一致。并发请求到达顺序不被当作逻辑顺序。
- 记录：`dist/.qa/0.2.18-node.log`、`0.2.18-chromium-source.log`、`0.2.18-chromium-userscript.log`（本地忽略目录）。

## 产物

由 `.tooling/powershell/pwsh -NoProfile -File browser-extension/package-userscript.ps1` 真实生成：

- `dist/PiliPlus-Adaptive-CDN-Web.user.js`
- 元数据及 manifest：**0.2.18**
- 大小：**50,893 bytes**
- SHA-256：`72406f2d0a9cc7b4780a0135cbbfd69ae440ed97b28f232f210e71a896e59cb5`
- 已核对源码 core/page 和 PowerShell 内 bridge 逐字内容及拼接顺序；无 CR 字节。

## 限制

这些是实际 Chromium 路由夹具和受控时钟回归，不是登录 B 站后完整真实 MSE 播放验收；没有本次线上签名/CDN 审计。已 fatal 的 MSE 仍需网页播放器或用户重载。已交给播放器的 fetch 响应体失败不重放或跨 CDN 拼接；Service Worker/WebTransport 等旁路未覆盖。后台冻结/系统休眠可能推迟浏览器定时器触发，不保证墙钟恰好 15 秒；不会提早遍历，也未增加无限等待。
