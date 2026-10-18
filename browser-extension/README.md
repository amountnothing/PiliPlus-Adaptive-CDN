# PiliPlus Adaptive CDN for Web

Chromium / Edge 111+ 扩展与 Tampermonkey 油猴脚本，当前版本 **0.2.21**。

## 工作方式

- 仅取当前 playurl 的 `baseUrl`、`base_url`、`backupUrl`、`backup_url` 实际签名候选，合并四字段，不猜测或替换 UPOS 主机。旧 `expandKnownUpos` 设置不参与网页候选生成。
- 视频/音频分别映射，分别限制切换预算。评分排序、失败扣 28 分、同视频排除失败主机；新视频按评分重新遍历全部候选、逐个尝试，上个视频留下的冷却主机只排最后、不直接排除（冷却窗口默认 60 秒，仅影响新视频初始排序）。
- 每个资源/CDN 代次共享一个 15 秒候选观察窗口，从首次请求或切入候选开始计时；HTTP 403/404/5xx 等确定失败也等待剩余窗口，不能立即遍历。启动快速失败（0.2.21）：候选尚未收到任何字节（首帧/首片之前，含切源后的首字节之前）时，“沉默/超时”只等 5 秒首字节预算即切下一候选，不再等满 15 秒；一旦候选交付过字节，仍保留完整 15 秒观察窗口。每秒看门狗兜底（0.2.21）：即使播放器在超时前主动 abort 全部媒体请求（B 站播放器启动期自行轮换 host，终态事件不会到达），未收字节的候选仍在 5 秒预算到期时经同一恢复事务切换；播放器已放弃且无在途请求的资源、已收字节的资源均不触发。并发 fetch/XHR、多 Range、fatal 和健康监测合并到同一恢复事务，只有一次切换提交；旧代次错误不扣新候选预算。候选失败集合按资源（视频）隔离，全局评分保留跨视频记忆，冷却只影响新视频初始排序、不再硬排除。
- HTTP 错误、网络拒绝、响应头超时在向播放器暴露终态前，有限重试同一 GET/Range 到下一候选。保留请求头、XHR responseType/credentials；不拼接跨 CDN 响应字节。
- 主动换源重启在途请求；网页主动 abort 和视频会话退休则彻底取消，包括等待中的重试定时器。手动暂停立即取消候选/网络保护等待，不自动播放或 seek；单个请求 abort 只释放自己的等待所有权，最后一个请求取消后不留下后台切换。迟到的旧请求不处罚新会话。
- 首次真正播放后才监测回填；默认目标 30 秒、回填观察 5 秒、净增长不足 1 秒时申请换源，但仍受统一 15 秒候选窗口约束。整体网络故障暂停切换 20 秒。后台标签页不监测冻结。
- 画面冻结走已有 seek/重新缓冲保护，不消耗 CDN 预算。常规换源不重建 video/MSE，也不调用 play() 或更改手动暂停和位置。
- 首选 HEVC，可选 AVC/AV1/网页默认；只在 MediaSource 报告支持时调整同清晰度编码顺序。

## 致命错误边界

`video.error` 每个源只处理一次，并与请求/健康检测共享候选窗口而非旁路扣预算：准备下一候选并实际重试仍在途的请求；后续网页请求也使用该候选。所有候选用尽即停止。已进入 fatal 的 MSE **不会**因改 URL 或成功取得字节而恢复。本项目尚无经验证的 B 站播放器重载接口，因此明确提示“需网页播放器或手动重载”，不调用猜测的私有 API、不强行自动播放、不重置进度。若网页已停止请求且没有在途请求，不会伪造下载或宣称恢复成功。

响应头已交给播放器后的 fetch 响应体失败不在本层重新拼接/重放；需要网页播放器重试。Service Worker / WebTransport 等绕过 fetch/XHR 的路径也不保证覆盖。仅一个 API 候选时无法切换到第二个主机。

## 网络审计记录

2026-09-13 既有匿名审计：BV1rp4y1e745 / cid244954665，playurl HTTP 200、code 0；7 条流四 URL 字段共存且同名语义值相等。Akamai 视频/音频及 cos 备用的 1024 字节 Range 均为 206、video/mp4。地址与 2026-06 文档一致，不能证明 B 站全局换域名或某固定节点对所有签名有效。本次没有重复网络审计，也不在文档复制带签名 URL。

## 安装

- 扩展：Chrome/Edge 开发者模式 → 加载已解压扩展 → 选择本目录 → 刷新视频页。
- 油猴：安装 `dist/PiliPlus-Adaptive-CDN-Web.user.js`，适用视频页和番剧播放页，document-start 注入。
- 工具栏提供 CDN/缓冲状态、手动换源和扩展设置；浏览器阈值不能强制网页播放器下载满缓存。

## 测试与打包（仓库根目录）

```sh
node --test browser-extension/test/*.test.cjs
node browser-extension/test/chromium.cjs
USERSCRIPT_FILE=dist/PiliPlus-Adaptive-CDN-Web.user.js node browser-extension/test/chromium.cjs
.tooling/powershell/pwsh -NoProfile -File browser-extension/package-userscript.ps1
```

Chromium 测试需要 `dist/.qa/node_modules/playwright` 及已安装浏览器（可用 `PLAYWRIGHT_MODULE` 指定模块路径）。测试使用路由夹具，不是线上完整 B 站 MSE 播放验收。产物由 manifest/core/page 与打包脚本内 bridge 生成，输出到 `dist/`。
