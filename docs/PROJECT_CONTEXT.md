# PiliPlus Adaptive CDN 项目上下文

更新时间：2026-08-24
用途：给人和 Codex 快速恢复项目上下文，避免长对话压缩后丢失关键记忆。

- 唯一源码基准：GitHub `amountnothing/PiliPlus-Adaptive-CDN` 的 `main` 分支。
- 本机工作目录示例：`H:/kongbai/Documents/Codex/MiniProgramm/PiliplusAdaptiveCDN/PiliPlus-Adaptive-CDN-repo`；云端 clone 不依赖此绝对路径。
- 本机 APK、油猴脚本等临时交付目录：`H:/kongbai/Documents/Codex/MiniProgramm/PiliplusAdaptiveCDN`；长期交付使用 GitHub Release/Actions artifact。
- 云端迁移、环境初始化、私钥边界和本机目录清单见 `docs/CLOUD_AGENT_HANDOFF.md`。
- 外层 `PiliPlus-Adaptive-CDN-handoff.md` 是历史迁移快照，不作为当前参数或版本依据。

## 0. 每次任务必读的架构基准

- 读取本文后，继续读取 `docs/CODEBASE_REFERENCE.md`，再开始定位或修改代码。
- `CODEBASE_REFERENCE.md` 说明完整框架、模块边界、核心类职责、关键数据流和修改入口。
- `docs/SOURCE_FILE_INDEX.md` 是全部受版本控制及非忽略项目文件的定位表。
- `docs/SYMBOL_INDEX.md` 是手写源代码中类、函数和方法的定位表；生成代码只列顶层类型。
- 新增、删除或移动文件/符号后运行 `tool/generate_codebase_index.ps1` 重建索引；核心架构或播放规则变化时同时更新架构基准。

## 1. 已实现的功能

### App 端 Adaptive CDN

- 新增“自适应播放 / Adaptive CDN”总开关。
- 开启后接管视频播放相关的 CDN、解码、缓冲、切换策略；关闭后恢复 PiliPlus 原本手动设置逻辑。
- 开启后相关手动设置会被灰掉或屏蔽，只展示当前状态，避免多套逻辑互相打架。
- 默认解码优先级：
  - 第一优先：HEVC/H.265。
  - 恢复 / 兼容优先：AVC/H.264。
- 可配置目标缓冲、回填触发容差、低缓冲阈值、缓冲增长观察时间、故障 CDN 冷却、最大切换次数、是否遍历所有 CDN。
- CDN 有持久化稳定性评分，开始播放时按评分降序选择，故障时降分，稳定播放时逐步加分。
- 故障 CDN：
  - App 默认全局冷却 60 秒。
  - 当前视频内不再使用该 CDN。
  - 已失败 CDN 与切换额度跨 Relay/播放器重建保留；视频轨与音频轨分别计数，视频切换不能耗尽音频的恢复额度。单轨额度耗尽后等待该轨当前连接恢复，不再通过重建重新遍历候选。
- 使用本地 Range Relay，让播放器面对稳定的本地 URL，上游 CDN 可以切换，尽量保留已有缓冲。
- 处理过的误判：
  - 视频结尾没有新内容可下载不算 CDN 超时。
  - 片尾保护窗口对短视频按总时长缩小，不再用固定 5 秒覆盖短视频的启动阶段；新 CID 也不继承上一视频“播放完成”产生的暂停状态。推荐页连续打开视频时，只有最后一次媒体打开事务可以接管播放器，旧视频在替换期间迟到的 completed/paused/position/error 事件不得覆盖新视频的启播意图和状态。
  - 手动暂停不算 CDN 超时或 PTS 冻结；健康监测同时要求“请求播放”和“播放器实际播放”。
  - 拖动进度条导致缓冲减少时，按“视频刚开始”类似逻辑处理，避免误判。
  - 网络整体很差时可暂停/放宽 CDN 切换，避免断网时把所有 CDN 都判坏。
  - 每次实际切换 CDN 前并行探测 `1.1.1.1` 和阿里 DNS `223.5.5.5`；两者都不可达时保持当前 CDN 5 秒再切换，默认启用且没有开关。
- 后台播放与中继下载以“用户是否请求播放”为准；播放器在切网或缓冲时短暂报告暂停不会主动停掉中继。playurl 查询、后台重连、CDN/Relay 重建和播放器异步打开均绑定开始时的手动暂停代次，完成前若用户明确暂停，恢复流程必须保持暂停，不能按旧的自动播放意图续播；已暂停状态进入后台时再次向原生播放器下发暂停并禁用后台重连。生命周期临时暂停恢复也校验该代次；回到前台 5 秒仍无有效进度时只重开同一播放器数据源并保留检查点。
- 本地 Relay 的 loopback TCP 连接超时按 Relay 故障处理；用户明确暂停时只消费该错误、不重建或续播，重新请求播放后才恢复。`Invalid OBU: fragment too short` 与其他 AV1 结构损坏统一走安全重建。
- 避免在同一个下游响应里拼接两个 CDN 的字节流；切换 CDN 时关闭当前上游响应，让后续 Range 请求走新 CDN，降低画面卡住、音频继续的风险。
- 音频或视频任一轨道停滞都视为整体播放停滞：音画和进度一起暂停，恢复后一起继续，并进入 CDN/播放器恢复判断。短暂断网后即使前向缓冲低，只要另一轨 PTS 明确继续前进，也按音画分离处理，不再因低缓冲漏检；若此前已经产生有效 PTS 的音轨/视频轨在切网后消失，也按该轨无进展累计冻结时间。播放器启播时尚未产生过 PTS 的轨道不算冻结，避免刚开始播放就误刷新播放器。

### 浏览器扩展

- 提供 Chromium MV3 扩展。
- 不套用 App 固定 CDN 列表，而是读取当前网页 playurl 返回的真实 DASH `baseUrl` / `backupUrl`。
- 对视频、音频资源分别建立候选映射。
- 通过 fetch / XHR 拦截和 Range 请求改写做后续 CDN 切换。
- 浏览器请求错误只标记实际报错资源的 CDN；换源主动中止的并发 fetch / XHR 不再重复触发切换，避免打开视频时连续误切音视频节点。
- 站内切换视频时，在注册新 playurl 前重置上一视频会话；会话路径忽略尾部斜杠，避免 B 站路由规范化时再次清空候选 CDN。
- 保留浏览器 MSE 已有缓冲，不重建 `<video>` 或 `MediaSource`。
- 支持评分、冷却、遍历候选、手动切换、首选编码。
- 默认首选 HEVC；只有浏览器 `MediaSource.isTypeSupported` 表示支持时才调整编码顺序。
- 画面停滞时回退到最后显示的视频帧并保持播放意图，让网页播放器进入 `seeking` / `waiting`；数据恢复后自动继续，并用缓冲观察时间抑制连续误切 CDN。

### 自动构建 / Release

- `.github/workflows/adaptive_release.yml` 定时检查上游 `bggRGjQaUbCoE/PiliPlus` 最新 release。
- 发现新上游版本后尝试 merge，上游无变化则跳过。
- 自动同步先用 `git merge-tree` 做无落盘预检；定时任务遇到真实冲突时以单条 warning 跳过，手动同步仍明确失败，避免同一冲突反复刷红 Actions。
- GitHub release 构建 Android split APK，并把 Chromium/Edge ZIP 与 Tampermonkey `.user.js` 直接作为 Release 附件发布。
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
- 日志必须保持可长期启用和可复制，禁止每帧、每秒及常规预测返回/动画事件日志。
- `PredictiveBack: start/cancel/commit` 调用保留在 `lib/main.dart`，但已注释，不要删除。
- 动画常规采样日志已停用；只保留快照捕获失败等真正异常。
- 播放器只记录异常、CDN 切换、PTS 冻结和恢复动作的简短摘要，不记录健康监测轮询。
- 低缓冲切换与 Relay 重建摘要包含位置、缓冲、PTS、首帧后时间、播放状态和累计切换额度，用于核实“刚开始播放即重建”，但不增加周期日志。
- 手动暂停、纯音频或播放器重建期间产生的可恢复解码尾声由错误入口消费，不重复记原始错误或再次触发恢复；正常播放中的解码错误仍按既有流程恢复。

## 2. 实现方法

### Adaptive CDN 核心文件

- `lib/utils/adaptive_playback.dart`
  - 总开关状态。
  - 控制手动设置是否可用。
- `lib/services/cdn_relay_server.dart`
  - 本地 loopback Range Relay。
  - 下游给播放器稳定 URL，上游实际请求 CDN。
  - CDN 切换时中断当前上游读取，后续 Range 请求走新 CDN。
  - 维护当前视频内失败 host 排除、冷却、切换回调、拉取宽限和换源前公网连通性探测。
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
    - `adaptiveStallTimeoutSec`: 5。
    - `adaptiveSegmentToleranceSec`: 10。
    - `adaptiveLowBufferStutterMinGrowthSec`: 1。
    - `adaptiveCdnCooldownSec`: 60。
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
  - 当前版本 0.2.16；与 App 默认触发参数对齐：前向缓冲回填观察 5 秒、净增长不足 1 秒时切换，画面冻结观察 8 秒且要求至少 10 秒前向缓冲，故障 CDN 冷却 60 秒；疑似整体断网时暂停切换 20 秒。只有收到 `playing` 或首个视频帧后才开始卡顿观察，网页自身取消的 XHR 不计为 CDN 故障。
  - 后台标签页暂停健康检测，返回后重新建立画面帧观察基线；HTTP/网络失败只改写故障轨道的后续请求，缓冲停滞才中断停滞的视频请求，保留另一轨和已有 MSE 缓冲，避免切屏误判及换源黑屏。画面帧冻结与 App 一样进入播放器恢复，不再消耗 CDN 切换次数。
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
- 播放器重建时可短暂保留旧 Relay 收尾，但旧 Relay 不再回调控制器、改写当前 CDN 或触发重复恢复。
- 解码错误恢复会先保存有效播放进度并停止旧源，再切换 CDN 和重建；播放器瞬时回报的 0 不覆盖已有检查点。
- 关闭视频页时必须释放 relay session，避免退出后仍持续下载。

### 动画设计原则

- 用户明确不想为了动画付出明显性能/功耗代价。
- 优先 Flutter / Android 官方能力；不为了动画引入重型库。
- 不要改动现有页面静态显示效果；动画优化尽量只动动画层。
- 用户不喜欢 WebView 套壳方案。
- 打开动画不要再改成“整页快照飞到卡片/播放器”的可见效果；打开只允许封面 Hero + 页面下层滑入。
- 预测返回动画不要再改成“只有封面卡片飞回”或“整页向右隐去”；目标是页面整体缩回来源视频卡片。
- 打开动画与预测返回动画要隔离：修打开动画优先只碰 `videoCoverHero()` / `_openPageSlideAnim` / 封面覆盖层；修预测返回优先只碰 `videoPageHero()` / `videoCardHero()` / `_croppedSnapshotFlight()`。
- 打开阶段应该只有 `cover` 可见参与；如果卡片侧 `page/card` Hero 在当前路由参与 push，就是错误状态。
- 封面消失逻辑不要绑定 pageHero；pageHero 是预测返回载体，不是播放器准备状态。
- 如果要改封面消失，必须保持：封面 Hero 到播放器位置后仍然是同一张封面盖在播放器上，直到播放器开始 loading/loaded，再 100ms 淡出。
- 当前动画调试不要再大范围重写；先区分打开封面 Hero 与预测返回 page/card Hero，不能用一个阶段的现象修改另一个阶段。
- 如确需采样轨迹，只临时记录少量关键点，定位完成后立即注释；判断直线路径应比较 begin/end/current rect 的中心点，`curveProgress` 与 `raw` 不同只是速度曲线。
- 封面轨迹中心点异常时优先检查 `_VideoHeroRectTween`；目标 rect 在打开过程中变化时检查布局或 Transform，不先改播放器 UI。

## 4. 对话历史中的重要记忆

- 项目初衷：在德国网络环境下，原 pilipala 比 piliplus 视频加载更稳定；本项目希望把 piliplus 的 CDN 处理改回更适合海外波动网络的模式，并进一步自适应。
- 用户使用经验：
  - CDN 测速快不代表播放稳定。
  - 编码选择会影响 CDN/播放稳定性。
  - 画面卡住、声音继续，不一定是单纯解码问题，也可能和切 CDN / 替换源有关。
  - 断网、Wi-Fi 信号极差但仍连接时，不应疯狂切 CDN。
- 用户偏好：
  - 能测试就给本地 arm64-v8a APK。
  - 安装包、油猴脚本等交付文件只放在 `PiliplusAdaptiveCDN` 目录内。
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
  - 当前已记录的动画代码基线为 `30eac66c5`；其父提交 `1037daba4` 是自适应播放停滞处理基线。

## 5. 项目暂停分区

### 当前暂停点

日期：2026-07-24
最后完成事项：移除同一播放器响应内的跨 CDN 重叠续接；换源或暂停会关闭当前响应，由 mpv 通过稳定本地 URL 发起新 Range，已有播放器缓冲保留。

最新 APK 按当前提交命名并输出到
`H:/kongbai/Documents/Codex/MiniProgramm/PiliplusAdaptiveCDN`；具体文件名和校验值以每次构建结果为准。

当前没有待修复的动画问题。除非用户提供新的可复现回归，不要继续调整动画目标、比例或页面层级。不要根据本文假定工作树是否干净；任何任务开始前都必须运行 `git status --short` 并保留已有修改。

### 2026-08-08 播放状态与 CDN 切换约束

- “已缓冲到片尾”不等于“已播放结束”。播放位置进入最后 5 秒且缓冲边界距片尾不超过 2 秒时，只暂停 CDN 故障切换、不暂停 Relay；从片尾跳回开头后必须立即恢复正常加载与监控。
- 后台通知、媒体按键等手动暂停即使发生在播放器已经因缓冲而暂停时，也必须写入用户暂停意图；网络中断恢复、音频焦点恢复和 CDN 探测完成后都不得覆盖该意图。
- 卡顿恢复和播放器重建期间保留同一 CID 的最后有效进度；底层播放器短暂上报 0 时不清空界面进度，明确 seek 才能覆盖恢复检查点。
- App 内视频、音频 Relay 分别维护切换次数预算，重建 Relay 时继承各自已使用次数；失败主机集合只用于候选排除，不再兼任次数统计。
- 延迟退役的 Relay 在短暂交接窗口内仍可读取当前 CDN，但不再切换 CDN、修改评分/冷却或触发控制器重建；窗口结束后才真正关闭，避免新播放器接管前本地 URL 瞬间 404。
- 浏览器扩展 0.2.15 忽略旧 CDN 的迟到并发请求错误，并在 SPA 复用 `<video>` 时注销旧帧回调和事件监听；末尾判断与 App 保持一致。
- 浏览器扩展 0.2.16 修复启播阶段误触发和原生 XHR 取消误判：`play()` 已接受但尚未真正出帧时不启动 CDN 卡顿计时，暂停后恢复也重新计算 5 秒观察窗；播放器主动取消旧请求不会推进 CDN 候选。

### 2026-08-17 播放器恶性回归修复

- 底层播放器的迟到 `playing` 事件不得覆盖 `playbackRequested=false`；手动暂停后即使生命周期、音频焦点或旧异步操作返回，也会立即保持原生播放器暂停。
- 播放按钮、双击中央、视频页大按钮和投稿片段预览不得再直接调用底层 `play()` / `playOrPause()`；这些入口统一经过 `PlPlayerController.play()` / `pause()`，同步播放意图、手动暂停代次、后台恢复和音频焦点。播放按钮的图标与无障碍标签也统一跟随同一个原生 `playing` 事件。
- 本地 Relay 使用期间出现 `Failed to recognize file format`，按 Relay 启播/空响应故障恢复，不再同时进入第二套码流损坏重建，避免连续重建风暴。
- Release 5144 已通过完整 48 项测试；MuMu 初测确认正常视频音画工作、从正在播放的视频打开第二个推荐视频后可正常启播，手动暂停后位置保持 01:38，进入后台 12 秒并返回仍保持暂停且音频轨为 stopped。测试期间未出现 Relay 打不开、格式识别失败、OBU/NAL/temporal unit 或播放器重建错误。
- MuMu 的 Wi-Fi 与本机 ADB 桥绑定，关闭 Wi-Fi 会同时断开测试控制链；短暂断网恢复由 Relay 自动测试覆盖，真机仍需继续观察基站/Wi-Fi 切换。

### 2026-08-18 音频继续但画面冻结修复

- 5145/5146 曾错误地仅凭“用户仍要求播放”就在首帧前启动健康监控，并把从未初始化的 PTS 当成冻结；这会在正常启播期间触发 CDN 切换/播放器重建，属于禁止恢复的错误实现。
- 正确规则：每次 `setDataSource` 都清除“已启播”标记，只有当前媒体收到真实 `playing` 事件后才允许启动 CDN/PTS 健康监控。此后即使解码器卡住并令底层 `playing` 变为 false，监控仍保持工作。
- 生命周期和音频焦点造成的临时暂停单独记录，避免把正常后台暂停误判为画面冻结；手动暂停仍以 `playbackRequested=false` 为最高优先级，恢复事件不得自动续播。
- 某些设备/编码不会提供某一轨的 PTS，因此“从未获得 PTS”不能作为冻结证据。只有该轨至少出现过一个有效 PTS 后，后续 PTS 停滞才允许触发音画冻结恢复。
- PTS 音画同步保护不再依赖“至少有两个 CDN 候选”；即使当前没有可切换 CDN，也必须阻止单轨继续播放。
- Release 5147 通过完整 50 项测试。MuMu 冷启动视频后连续播放，00:16 与 00:39 的画面不同，期间没有冻结重建、Relay 打不开或 OBU/NAL/temporal unit 错误；媒体键暂停在 02:33，后台停留 12 秒并返回仍为 02:33 和暂停状态。模拟器无法稳定注入真机解码器单轨冻结，OnePlus 真机仍需观察日志模式下的 `pts-freeze` 恢复记录。

### 继续项目时先做什么

1. 完整读取本文档和根目录 `AGENTS.md`。
2. 看 `git status --short`，确认用户未提交改动和当前工作树。
3. 如果出现动画回归，先与 `30eac66c5` 对比相关文件，只改最小必要点。
4. 改完跑：

```powershell
..\.tooling\flutter\bin\flutter.bat analyze lib\utils\page_utils.dart lib\pages\video\view.dart lib\pages\dynamics\widgets\dynamic_panel.dart
```

5. 用户要测试包时编译：

```powershell
..\.tooling\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --split-per-abi --android-project-arg=kotlin.incremental=false --android-project-arg=kotlin.compiler.execution.strategy=in-process
```

### 暂停期间不要忘记

- 不要把临时动画测试 fork 当最终方案同步。
- GitHub 同步/编译需要用户明确要求；用户多次说过“先别编译/先别同步”时要严格区分。
- 如果要发布，先确认：
  - 当前动画是否已被用户认可。
  - Adaptive CDN 逻辑和 README 是否一致。
  - 浏览器扩展是否需要同步 App 端最新 CDN 策略。
  - GitHub Actions 签名 secrets 是否完整。
