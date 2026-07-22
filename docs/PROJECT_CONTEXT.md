# PiliPlus Adaptive CDN 项目上下文

更新时间：2026-07-01  
用途：给人和 Codex 快速恢复项目上下文，避免长对话压缩后丢失关键记忆。

## 1. 已实现的功能

### App 端 Adaptive CDN

- 新增“自适应播放 / Adaptive CDN”总开关。
- 开启后接管视频播放相关的 CDN、解码、缓冲、切换策略；关闭后恢复 PiliPlus 原本手动设置逻辑。
- 开启后相关手动设置会被灰掉或屏蔽，只展示当前状态，避免多套逻辑互相打架。
- 默认解码优先级：
  - 第一优先：HEVC/H.265。
  - 恢复 / 兼容优先：AVC/H.264。
- 可配置目标缓冲、回填触发容差、低缓冲阈值、CDN 拉取超时、故障 CDN 冷却、最大切换次数、是否遍历所有 CDN。
- CDN 有持久化稳定性评分，开始播放时按评分降序选择，故障时降分，稳定播放时逐步加分。
- 故障 CDN：
  - 默认全局冷却 30 秒。
  - 当前视频内不再使用该 CDN。
- 使用本地 Range Relay，让播放器面对稳定的本地 URL，上游 CDN 可以切换，尽量保留已有缓冲。
- 处理过的误判：
  - 视频结尾没有新内容可下载不算 CDN 超时。
  - 手动暂停不算 CDN 超时。
  - 拖动进度条导致缓冲减少时，按“视频刚开始”类似逻辑处理，避免误判。
  - 网络整体很差时可暂停/放宽 CDN 切换，避免断网时把所有 CDN 都判坏。
- 避免在同一个下游响应里拼接两个 CDN 的字节流；切换 CDN 时关闭当前上游响应，让后续 Range 请求走新 CDN，降低画面卡住、音频继续的风险。

### 浏览器扩展

- 提供 Chromium MV3 扩展。
- 不套用 App 固定 CDN 列表，而是读取当前网页 playurl 返回的真实 DASH `baseUrl` / `backupUrl`。
- 对视频、音频资源分别建立候选映射。
- 通过 fetch / XHR 拦截和 Range 请求改写做后续 CDN 切换。
- 保留浏览器 MSE 已有缓冲，不重建 `<video>` 或 `MediaSource`。
- 支持评分、冷却、遍历候选、手动切换、首选编码。
- 默认首选 HEVC；只有浏览器 `MediaSource.isTypeSupported` 表示支持时才调整编码顺序。

### 自动构建 / Release

- `.github/workflows/adaptive_release.yml` 定时检查上游 `bggRGjQaUbCoE/PiliPlus` 最新 release。
- 发现新上游版本后尝试 merge，上游无变化则跳过。
- GitHub release 构建 Android split APK。
- Release 构建要求稳定签名 secrets，并校验证书 SHA-256，避免普通安卓机安装时报签名问题。

### 动画 / 预测返回

- 给视频卡片打开视频页做了 Hero 动画和页面下层滑入动画。
- 给视频页预测返回做了整页缩放/裁剪/回卡片方向的尝试。
- 首页、历史、稍后再看、动态等视频卡片路径逐步接入 Hero / 预测返回。
- 当前打开动画的产品约定：
  - 视频封面通过封面 Hero 缩放到播放器所在位置。
  - 封面 Hero 开始的同时，视频页面开始加载/渲染。
  - 页面框架一旦渲染出来，就从视频卡片所在一侧的屏幕边缘滑入；其他内容可以边滑入边继续加载。
  - 封面始终盖在播放器上方，不在 Hero 到位后先消失再由播放器重新拉起另一张封面。
  - 播放器准备完成后，封面在 100ms 内淡出。
  - “播放器准备完成”的判定：播放器已创建并进入 `dataStatus.loading` 或 `dataStatus.loaded`；也就是开始加载视频/缓存即算准备完成，不等视频完全 loaded。
- 当前打开动画参数：
  - 时长：360ms。
  - 速度曲线：`cubic-bezier(0.15, 1, 0.2, 1)`。
  - 运动路径：封面 Hero 使用 `Rect.lerp` 做直线路径；速度曲线只影响快慢，不应把路径改成弧线。
  - 页面下层滑入和封面 Hero 分离；不要让整页/整卡 Hero 参与打开阶段的可见飞行动画。
- 当前预测返回约定：
  - 视频页整页 Hero 常驻视频页，保证预测返回开始时 Flutter 能立即匹配到源 Hero。
  - 列表/动态/历史/稍后再看里的 `videoCardHero()` 只在所在路由被上层页面覆盖后启用；所在路由仍是当前页时不启用，避免打开视频页时 `page/card` Hero 参与 push，造成第二层完整视频页。
  - `videoPageHero()` 必须提供原页面 placeholder，Hero 飞行时不能把原页面挖空，否则会出现灰色背景蒙版。
  - push 打开阶段的整页 Hero 飞行动画不可见；打开视觉只由封面 Hero + 页面滑入构成。
- 当前预测返回目标动画效果约定：
  - 手势开始时，视频页当前这一帧作为返回动画主体；不要实时重绘推荐列表来做飞行动画，避免闪烁和掉帧。
  - 如果手势开始时视频正在播放，立即暂停播放；如果预测返回撤销，则恢复播放；如果确认返回离开页面，则不恢复。
  - 返回动画主体整体向来源视频卡片区域缩放/移动，视觉上应接近“整页缩回视频卡片”，而不是整页向右隐去，也不是只有封面单独飞回。
  - 缩放过程中只允许用纵向裁剪/透明渐变调整页面快照高度，让它逐渐符合目标视频卡片比例；不要横向裁剪，不要把快照横向压扁。
  - 动画后半段，目标视频卡片内容（封面 + 封面下方标题/作者等卡片信息）可以逐渐淡入，最终完整盖住缩小后的页面快照。
  - 目标页面就是动画背景；不能新增灰色/黑色半透明背景蒙版。
  - 预测返回过程中，原视频页必须保留 placeholder，不能被 Hero 临时挖空。
  - 快速返回和慢速预测返回都要落到同一个目标视频卡片；如果刚打开视频 0.5 秒内返回，也必须能找到同一套预测返回目标。
  - 预测返回的 `page/card` Hero 只服务返回阶段；不要让它参与打开阶段的可见飞行动画，避免破坏封面打开动画。
  - 如果未来为了修预测返回必须改 `videoPageHero()` / `videoCardHero()`，必须同时确认打开动画仍满足上一节“封面 Hero + 页面滑入”的产品约定。

### 日志

- 使用项目内置日志页，不再保留额外魔改日志系统。
- 关于页有“日志模式”开关。打开后，原本错误日志可作为普通调试日志使用。
- 最近新增打开动画日志：
  - `coverHeroFlight`：来源/目标 size 与 rect。
  - `heroRectSample`：Hero 飞行 0/25/50/75/100% 的 raw、curveProgress、begin/end/current rect。
  - `pageInternalSlide sample`：页面下层滑入 0/25/50/75/100% 的 raw、curve、dxFraction、routeDxPx、routeDyPx、pageHero，以及 player/body/tabBar/tabView/intro/reply/related 的全局 rect；用于确认元素轨迹是否只有 x 变化，y 是否异常上下漂移。

## 2. 实现方法

### Adaptive CDN 核心文件

- `lib/utils/adaptive_playback.dart`
  - 总开关状态。
  - 控制手动设置是否可用。
- `lib/services/cdn_relay_server.dart`
  - 本地 loopback Range Relay。
  - 下游给播放器稳定 URL，上游实际请求 CDN。
  - CDN 切换时中断当前上游读取，后续 Range 请求走新 CDN。
  - 维护当前视频内失败 host 排除、冷却、切换回调、拉取宽限。
- `lib/services/cdn_score_service.dart`
  - CDN host 级持久化评分。
  - 稳定播放加分，故障扣分。
  - 候选 CDN 排序。
- `lib/utils/storage_pref.dart`
  - Adaptive CDN 默认值：
    - `adaptivePreferredDecode`: HEVC。
    - `adaptiveRecoveryDecode`: AVC。
    - `adaptiveTargetBufferSec`: 30。
    - `adaptiveLowBufferSec`: 10。
    - `adaptiveStallTimeoutSec`: 10。
    - `adaptiveSegmentToleranceSec`: 10。
    - `adaptiveCdnCooldownSec`: 30。
    - `adaptiveMaxCdnSwitches`: 3。
    - `adaptiveTraverseAllCdns`: true。
  - `initBuffer()` 在自适应播放开启时扩大缓存并设置回填 hysteresis。
- `lib/pages/setting/models/video_settings.dart`
  - Adaptive CDN 二级设置菜单。
  - 开关联动手动 CDN / 测速 / 缓冲 / 解码相关设置。
- `lib/utils/video_utils.dart`
  - CDN host 处理、失败标记、候选展开/过滤等工具逻辑。

### 浏览器扩展核心文件

- `browser-extension/core.js`
  - 评分、冷却、候选排序、编码族判断、参数校验。
- `browser-extension/page.js`
  - 注入网页侧。
  - 拦截 playurl、fetch、XHR。
  - 维护当前资源候选、活跃请求、切换原因、toast。
- `browser-extension/bridge.js`
  - 页面脚本与扩展 storage 之间同步 settings / scores / cooldowns。
- `browser-extension/options.*`
  - 扩展设置页。
- `browser-extension/popup.*`
  - 当前 CDN、缓冲、手动切换入口。

### 动画核心文件

- `lib/utils/page_utils.dart`
  - `videoCoverHero()`：封面 Hero。
  - `videoCardHero()`：目标卡片整卡 Hero，主要用于返回/预测返回。
  - `videoPageHero()`：视频页整页 Hero，主要用于返回。
  - `_VideoHeroRectTween`：使用 `Rect.lerp` 保证直线路径；`curveProgress` 是速度曲线进度，不代表路径弯曲。
  - `toVideoPage()`：计算 `openSlideFrom`，传入视频页。
- `lib/pages/video/view.dart`
  - `_openPageAnimCtr`：视频页打开时下层滑入动画。
  - `_openPageSlideAnim`：页面下层滑入。
  - `videoPageHero()`：常驻包住视频页；打开阶段不出第二层页面的问题由目标卡片侧 `videoCardHero()` 延迟启用解决。
  - `_initialPlayerCoverReleased`：封面覆盖层只在“页面打开动画完成 + 播放器进入 loading/loaded”后释放，并用 100ms 透明度淡出；打开动画完成时必须触发一次重建，否则会等到 loaded 才重算。
  - 当前结构保留：播放器/header/封面目标位置不跟着根页面滑动；只让播放器下方内容层滑入。
- `lib/pages/dynamics/widgets/dynamic_panel.dart`
  - 动态页普通视频/合集卡片补了 `videoCardHero()`，让预测返回目标与其他视频卡片页面一致。
- `lib/main.dart`
  - `_PredictiveBackGestureDispatcher` 监听系统预测返回手势，写入 `PredictiveBackProgress`。

## 3. 功能细节与注意事项

### Adaptive CDN 设计原则

- 不默认认为“海外 CDN 一定更稳定”；德国网络环境下 CDN 稳定性会波动。
- CDN 测速显示高网速不等于该 CDN 能稳定播放该视频。
- 部分 CDN 在切换编码后会明显改善稳定性，所以解码优先级是策略的一部分。
- 更看重持续播放稳定性，而不是单次测速。
- 一旦某个 CDN 在当前视频失败，不应在同视频内反复重试。
- 全局冷却只是跨视频临时降权，不代表永久封禁。

### Relay 设计边界

- 目标是“保留旧缓冲，后续 Range 走新 CDN”。
- 不应在一个已经发给播放器的响应里拼接不同 CDN 的字节。
- 如果播放器/网络层已接受一个响应，切 CDN 时关闭该响应，让播放器重试 Range。
- 关闭视频页时必须释放 relay session，避免退出后仍持续下载。

### 动画设计原则

- 用户明确不想为了动画付出明显性能/功耗代价。
- 优先 Flutter / Android 官方能力；不为了动画引入重型库。
- 不要改动现有页面静态显示效果；动画优化尽量只动动画层。
- 用户不喜欢 WebView 套壳方案。
- 打开动画不要再改成“整页快照飞到卡片/播放器”的可见效果；打开只允许封面 Hero + 页面下层滑入。
- 预测返回动画不要再改成“只有封面卡片飞回”或“整页向右隐去”；目标是页面整体缩回来源视频卡片。
- 打开动画与预测返回动画要隔离：修打开动画优先只碰 `videoCoverHero()` / `_openPageSlideAnim` / 封面覆盖层；修预测返回优先只碰 `videoPageHero()` / `videoCardHero()` / `_croppedSnapshotFlight()`。
- 如果打开阶段日志出现 `heroRectSample label=page/card`，说明卡片侧 Hero 又在当前路由启用了，是错误状态；打开阶段应该只有 `cover` 可见参与。
- 封面消失逻辑不要绑定 pageHero；pageHero 是预测返回载体，不是播放器准备状态。
- 如果要改封面消失，必须保持：封面 Hero 到播放器位置后仍然是同一张封面盖在播放器上，直到播放器开始 loading/loaded，再 100ms 淡出。
- 当前动画调试不要再大范围重写，先用采样日志确定问题：
  - `heroRectSample label=cover` 才是打开封面轨迹；`card/page` 类日志属于返回/预测返回，不要混为打开封面轨迹。
  - 预测返回看 `heroRectSample label=page/card`，打开动画看 `label=cover`；不要用一个日志结论修另一个动画。
  - `curveProgress` 可以不同于 `raw`，这是速度曲线；判断路径是否直线要看 begin/end/current rect 的中心点是否在线性插值线上。
  - 如果 `heroRectSample label=cover` 的 rect 中心点不是直线，优先修 `_VideoHeroRectTween`。
  - 如果 `toRect` 在打开过程中变化，说明目标 Hero 仍被某个布局/Transform 带动。

## 4. 对话历史中的重要记忆

- 项目初衷：在德国网络环境下，原 pilipala 比 piliplus 视频加载更稳定；本项目希望把 piliplus 的 CDN 处理改回更适合海外波动网络的模式，并进一步自适应。
- 用户使用经验：
  - CDN 测速快不代表播放稳定。
  - 编码选择会影响 CDN/播放稳定性。
  - 画面卡住、声音继续，不一定是单纯解码问题，也可能和切 CDN / 替换源有关。
  - 断网、Wi-Fi 信号极差但仍连接时，不应疯狂切 CDN。
- 用户偏好：
  - 能测试就给本地 arm64-v8a APK。
  - 简洁可维护优先，避免过度工程化。
  - 不要骗“已修好”；不确定就加日志定位。
  - 不希望为了动画牺牲功耗和性能。
  - 不喜欢 WebView 套壳。
  - 动画上更接近 B 站官方客户端，但接受做不到时明确说明原因。
- 已尝试过的动画方向：
  - 纯 Flutter Hero：可用但不完全像官方。
  - MaterialRectArcTween / Material motion：效果不符合预期，已排除。
  - 原生 overlay 局部接管：讨论过，可能增加复杂度/维护成本，暂未采用。
  - 当前方向：封面 Hero + 视频页下层滑入 + 返回时整页/整卡 Hero。
- 最近的动画状态：
  - 2026-07-22 用户确认当前版本动画没有问题，后续改动若产生回归应立即撤回。
  - 已确认 `video-cover-*` 只是封面和整卡共用的关联键：`_videoCoverRects` 保存封面矩形，`_videoCardTargetReaders` / `_videoCardRects` 保存返回动画使用的整卡矩形。
  - `cardRect` 出现全宽比例并不代表误抓封面；当前预测返回按设计将整页缩回整张来源卡片，不要改成只缩回封面。
  - 当前可回退的动画代码基线为 `1037daba4`。

## 5. 项目暂停分区

### 当前暂停点

日期：2026-07-22
最后完成事项：核对并记录当前已认可的打开/预测返回动画实现。

最新 APK 输出路径：

```text
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

当前没有待修复的动画问题。除非用户提供新的可复现回归，不要继续调整动画目标、比例或页面层级。

### 继续项目时先做什么

1. 读取本文档。
2. 看 `git status --short`，确认用户未提交改动和当前工作树。
3. 如果出现动画回归，先与 `1037daba4` 对比相关文件，只改最小必要点。
4. 改完跑：

```powershell
..\.tooling\flutter\bin\flutter.bat analyze lib\utils\page_utils.dart lib\pages\video\view.dart lib\pages\dynamics\widgets\dynamic_panel.dart
```

5. 用户要测试包时编译：

```powershell
..\.tooling\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --split-per-abi
```

### 暂停期间不要忘记

- 不要把临时动画测试 fork 当最终方案同步。
- GitHub 同步/编译需要用户明确要求；用户多次说过“先别编译/先别同步”时要严格区分。
- 如果要发布，先确认：
  - 当前动画是否已被用户认可。
  - Adaptive CDN 逻辑和 README 是否一致。
  - 浏览器扩展是否需要同步 App 端最新 CDN 策略。
  - GitHub Actions 签名 secrets 是否完整。
