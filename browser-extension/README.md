# PiliPlus Adaptive CDN for Web

面向 Chrome / Edge 111+ 的 Manifest V3 扩展。它把 PiliPlus Adaptive CDN 的核心策略移植到哔哩哔哩网页版，但不会照搬 App 端 CDN 名单。

## 工作方式

- 从当前视频网页 `playurl` 响应里的 `baseUrl` / `backupUrl` 动态取得候选。
- 对标准 `/upgcxcode/` 地址，可选扩展到已验证接受相同签名、Range 与网页 CORS 的 UPOS 主机。
- 对视频和音频 DASH 请求分别建立候选映射，不把某个固定域名当成“海外最优”。
- 按持久化稳定性评分排序；故障扣 28 分，稳定播放逐步加分。
- 默认目标缓冲 30 秒：低于“目标缓冲 - 回填触发容差”后开始观察；任何回填场景观察 5 秒，净增长不足 1 秒时切换。
- 换源时只中断当前媒体请求，后续 Range 请求改走新 CDN；不会重建 `<video>` 或 `MediaSource`，已有 MSE 缓冲会保留。
- 已失败主机在当前视频内不再使用，并进入默认 30 秒冷却。
- 首选编码可选 AV1、HEVC/H.265、AVC/H.264 或网页默认；仅在浏览器通过 `MediaSource.isTypeSupported` 报告支持时调整同清晰度顺序。

2026-06-24 在德国网络环境抽样当前热门视频时，普通网页接口主要只主动返回：

- `upos-sz-mirrorcosov.bilivideo.com`
- `upos-hz-mirrorakam.akamaized.net`

同日对一条有效网页签名做 1KB Range 验证后，下列额外节点均返回 HTTP 206，并允许 B 站网页 Origin：

- 阿里：`ali`、`alib`、`alio1`、`aliov`
- 腾讯：`cos`、`cosb`、`coso1`、`cosov`
- 华为：`hw`、`hwb`、`hwo1`
- Akamai：`mirrorakam`

`hwov` 在本次验证中不可用，因此没有加入扩展列表。不同视频、清晰度和编码的首选顺序仍可能变化；扩展不会用单次测速决定优先级，而是用持续播放评分排序。若希望严格只使用接口原始候选，可在设置里关闭“扩展 UPOS 候选”。

## 安装

1. 解压发布包。
2. Chrome / Edge 打开扩展管理页。
3. 开启“开发者模式”。
4. 选择“加载已解压的扩展程序”，指向本目录。
5. 刷新已经打开的哔哩哔哩视频页面。

点击工具栏图标可查看当前 CDN、缓冲和切换原因，也可手动换源。完整阈值与首选编码在扩展设置页中调整。浏览器端不能像 mpv 一样直接设置 demuxer 回填阈值，因此“回填触发容差”用于更早判断和切 CDN，不强制网页播放器拉满缓冲。

## 边界

- 目前针对 Chromium 的哔哩哔哩原生 DASH/MSE 播放器。
- 如果网页播放器改为 Service Worker、WebTransport 或私有二进制协议，需要跟随网页实现更新拦截层。
- 非 `/upgcxcode/` 地址不会进行主机扩展；如果接口只返回一个不可扩展地址，此时无法换源。
- 换源依赖播放器在被中断后重试 Range 请求。扩展不会通过重新加载视频来伪造“切换成功”。

## 测试与打包

```powershell
node --test test/core.test.cjs
.\package.ps1
```

压缩包会输出到仓库的 `dist` 目录。
