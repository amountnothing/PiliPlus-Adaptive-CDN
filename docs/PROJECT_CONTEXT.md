# PiliPlus Adaptive CDN 项目上下文

更新时间：2026-10-28
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
- 使用本地 Range Relay，让播放器面对稳定的本地 URL，上游 CDN 可以切换，尽量保留已有缓冲。视频 CDN 切换时同步中断但不改选健康音频 CDN 的当前 Range，让 MPV 用新 Range 将音视频重新挂接到同一 EDL 时间线，避免换源后音轨脱落。
- 自动播放的数据源在 `Player.open` 阶段直接启动，不再先以暂停状态打开并等待完整目标缓存回填；自适应模式把 MPV 前向队列限制在 1–4 MiB、时间前瞻限制在 4 秒（不再按 30 秒码率膨胀到 16–96 MiB），并使用 `cache-pause-initial=no`，限制首播/重新打开的预取。此配置不是首帧门槛，实际出帧仍受格式探测、关键帧和解码初始化影响，尚无真机首帧流量/延迟对照。显式 seek 会立即下发到 MPV，不再先等待不可重放的 `stream.buffer.first` 最多 2 秒，避免大跨度拖动期间旧位置继续下载。手动暂停代次仍可阻止迟到的自动播放。
- 2026-09-09 已合并 PiliPlus 上游 `9730d29a8a34e0d07fec0afb06155711961a0509`；冲突采用“保留上游新 API/网络编码选择，同时保留 Adaptive CDN Relay、恢复检查点、播放意图和 seek 保护”的组合解。项目工具链基线随上游升级到 Flutter 3.47.2。
- 2026-10-01 已合并 PiliPlus 上游 `a30fcc310`（Release 2.1.5，87 提交）；5 个冲突（pl_player/controller、member_home/video/season_series、settings.gradle.kts）按“保留我们全部修复 + 吸收上游 playerStatus/_updatePlaybackState/seek 重构”解决，AGP 9.1.1 + Kotlin 2.4.0。工具链升到 Flutter 3.47.5（`.tooling/flutter-3.47.5`，本地框架补丁与 material_ui 补丁已迁移），定向 analyze 0 issue、全项目 41→38（剩余为合并前既有）。详见 `docs/plans/2026-10-01-upstream-2.1.5-merge.md`。合并提交未推送（gh 令牌缺 `workflow` 作用域，推送前需 `gh auth refresh`）。
- 2026-10-12 已合并 PiliPlus 上游 `56ad46af4`（Release 2.1.6，66 提交，merge-base `a30fcc310`）；2 个冲突（`README.md`、`lib/pages/setting/models/extra_settings.dart`）解决为“保留我们的仓库徽章/徽标链接与本地行为，吸收上游改动”，上游合并本身 210 文件（6531+/2690-），另含本次文档与索引更新。版本号随上游升到 `2.1.6+1`，工具链升到 Flutter 3.47.7（`.tooling/flutter-3.47.7`，本地框架 36 个已改文件与 material_ui 1.6.0 的 9 个补丁全部 reverse-check 通过）。验证：全项目 `flutter analyze` 38 issues（与基线一致）、定向 analyze 0 issue、全量 `flutter test` 106/106 通过。详见 `docs/plans/2026-10-12-upstream-2.1.6-merge.md`。合并提交未推送。
- 处理过的误判：
  - 视频结尾没有新内容可下载不算 CDN 超时。
  - 片尾保护窗口对短视频按总时长缩小，不再用固定 5 秒覆盖短视频的启动阶段；新 CID 也不继承上一视频“播放完成”产生的暂停状态。推荐页连续打开视频时，只有最后一次媒体打开事务可以接管播放器，旧视频在替换期间迟到的 completed/paused/position/error 事件不得覆盖新视频的启播意图和状态。
  - 手动暂停不算 CDN 超时或 PTS 冻结；健康监测同时要求“请求播放”和“播放器实际播放”。
  - 拖动进度条导致缓冲减少时，按“视频刚开始”类似逻辑处理，避免误判。
  - 网络整体很差时可暂停/放宽 CDN 切换，避免断网时把所有 CDN 都判坏。
  - 每次实际切换 CDN 前并行探测 `1.1.1.1` 和阿里 DNS `223.5.5.5`；两者都不可达时保持当前 CDN 5 秒再切换，默认启用且没有开关。
- 后台播放与中继下载以“用户是否请求播放”为准；播放器在切网或缓冲时短暂报告暂停不会主动停掉中继。playurl 查询、后台重连、CDN/Relay 重建和播放器异步打开均绑定开始时的手动暂停代次，完成前若用户明确暂停，恢复流程必须保持暂停，不能按旧的自动播放意图续播；已暂停状态进入后台时再次向原生播放器下发暂停并禁用后台重连。生命周期临时暂停恢复也校验该代次；回到前台 5 秒仍无有效进度时只重开同一播放器数据源并保留检查点。
- 本地 Relay 的 loopback TCP 连接超时按 Relay 故障处理；用户明确暂停时只消费该错误、不重建或续播，重新请求播放后才恢复。`Invalid OBU: fragment too short` 与其他 AV1 结构损坏统一走安全重建。
- 从云端历史或页面参数恢复到非零位置时，该起播位置在 MPV 实际时钟到达附近前保持为可靠检查点；启播阶段短暂上报的 0 或早期位置不得覆盖它。此时发生首次 CDN/Relay 重建仍从历史位置恢复，用户主动 seek（包括拖回 0）则立即取消这层保护。
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
- 启动快速失败（0.2.20）：候选 5 秒无任何字节即自动切换，且不依赖请求终态——即使播放器在超时前主动 abort 全部媒体请求，每秒看门狗也会按同一恢复事务提交切换。

### 自动构建 / Release

- `.github/workflows/pr-check.yml`：PR 只读门禁——`flutter test`（`test/` 下现有全部用例，不筛选）为必过项，
  `flutter analyze` 为咨询性（全项目基线本就不干净），Android dev split APK 作为 artifact 上传。
- `.github/workflows/adaptive_release.yml` 仅手动 `workflow_dispatch`；**没有定时任务**，
  也没有任何 workflow 会 `git push` 到 `main`。release 构建你 dispatch 的那个提交。
- 上游同步改为 PR 流程（`ops/piliplus-bridge` 在 VPS 上建 worktree/branch 交给 OpenCode，
  再由人合并）；bridge 只认「open、base=main、head=本任务分支且 head sha=worktree HEAD、
  check-runs 全绿」的 PR。详见 `docs/CI_AND_SYNC.md`。
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
    - `adaptiveLowBufferSec`: 持久化兼容默认 10；自适应开启时有效上限 2 秒。
    - `adaptiveStallTimeoutSec`: 5。
    - `adaptiveSegmentToleranceSec`: 10。
    - `adaptiveLowBufferStutterMinGrowthSec`: 1。
    - `adaptiveCdnCooldownSec`: 60。
    - `adaptiveMaxCdnSwitches`: 3。
    - `adaptiveTraverseAllCdns`: true。
  - `initBuffer()` 自适应模式全程限制 4 秒、1–4 MiB 预取，hysteresis 为 2 秒；目标/容差持久值保留兼容，实际回填观察线不超过 2 秒，不能再沿用 30/10 秒大缓存检测。
- `lib/pages/setting/models/video_settings.dart`
  - Adaptive CDN 二级设置菜单。
  - 开关联动手动 CDN / 测速 / 缓冲 / 解码相关设置。
- `lib/utils/video_utils.dart`
  - CDN host 处理、失败标记、候选展开/过滤等工具逻辑。

### 浏览器扩展核心文件

- `browser-extension/core.js`
  - 评分、冷却、候选排序、编码族判断、参数校验。
  - 当前版本 0.2.20；前向缓冲回填观察 5 秒、净增长不足 1 秒时申请切换，实际自动切换受网页候选观察窗口约束（候选未收字节 5 秒快速失败并有每秒看门狗兜底，收过字节 15 秒观察），画面冻结观察 8 秒且要求至少 10 秒前向缓冲，故障 CDN 冷却 60 秒；疑似整体断网时暂停切换 20 秒。只有收到 `playing` 或首个视频帧后才开始卡顿观察，网页自身取消的 XHR 不计为 CDN 故障。
  - 后台标签页暂停健康检测，返回后重新建立画面帧观察基线；HTTP/网络失败在终态暴露前重试故障轨道的同一 Range，缓冲停滞中断并重试停滞的视频请求，保留另一轨和已有 MSE 缓冲，避免切屏误判及换源黑屏。画面帧冻结与 App 一样进入播放器恢复，不再消耗 CDN 切换次数。
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
- 解码错误恢复会先保存有效播放进度并停止旧源，再切换 CDN 和重建；播放器瞬时回报的 0 不覆盖已有检查点。初次按历史进度打开但 MPV 尚未完成 seek 时，历史起播位置本身也属于有效检查点。
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
  - 安装包、油猴脚本等交付文件只放在坚果云界面路径 `Files > My Nutstore > PiliplusAdaptiveCDN`；VPS 对应目录为 `/home/Nutstore/PiliplusAdaptiveCDN`。
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

### 2026-08-26 首播与暂停/后台续播优化

- 自适应模式继续保留 30 秒目标缓存和大前向缓存，但明确设置 MPV `cache-pause-initial=no`，首次播放不等待目标缓存；真实断流后的 `cache-pause-wait` 降为 0.5 秒。目标缓存只负责后续弱网余量，不再兼任首帧门槛。
- 播放器使用 MPV 的毫秒级真实 buffer 状态判断前向缓存，不再只用取整到秒的 UI 值。每次请求播放后启动轻量看门狗：时间轴连续 2 秒不动且已有至少 500ms 前向缓存时，先做一次不丢缓存的原生 pause/play 唤醒；再过 3 秒仍不前进才按同一 CID 和检查点重开当前数据源。没有可用缓存的网络饥饿不重开，仍由 CDN/弱网逻辑处理。
- 手动暂停或禁止后台播放时，Relay 不再主动截断正在工作的下游 Range 响应。它最多暂存一个已在途 chunk，再依靠 Dart/MPV 背压停止继续读取；恢复后沿同一响应和精确字节位置继续，避免 MPV 因暂停期间的 premature close 卡死或误罚 CDN。连接若在暂停期间自行失效，也不计 CDN 故障。
- 生命周期进入 `hidden` / `paused` / `detached` 时以 `playbackRequested` 而不是底层瞬时 `playing` 判断是否需要回来续播；因此进入后台瞬间恰好 buffering 的视频也会获得受手动暂停代次保护的恢复。自适应看门狗统一负责前台恢复，避免与旧 5 秒生命周期刷新并发重开。
- 当前云端验证：相关文件静态检查 0 问题，完整 51 项 Flutter 测试通过。尚未构建 APK 或做 Android 真机首帧、长暂停、锁屏和 Wi-Fi/移动网络切换验收。

### 2026-09-09 fix2 修复验证与边界

- Relay 在等待上游连接/响应头/响应体时观察 5 秒静默；不把下游背压算作上游超时。手动暂停停表，恢复重新计时；网络探测返回后重新检查暂停、代次、退役、下游取消和切换预算。字节已输出时仍只关闭旧响应，由后续 Range 换源，绝不在同一响应跨 CDN 拼字节。
- Socket 包装只缓冲最多 64 KiB 请求字节；每次 HTTP 请求结束取消断开监听，避免 keepalive 累积请求闭包；关闭幂等释放 socket/订阅。暂停持有 chunk 时下游取消也立即取消上游，不等用户继续播放。
- 实际 Hive 偏好 → `Pref.initBuffer()` → 健康判定回归已先复现：4 秒满队列被 20 秒回填线误判、10 秒冻结门槛不可达。现将有效回填/冻结缓冲阈值限制到 2 秒，并识别字节上限导致的稳定小队列：观察期播放推进至少 1 秒且缓存净变化不低于 -250ms 时，不仅因未净增长 1 秒就换 CDN。明显耗尽/下降仍可换源，PTS 音画同步保护保留。
- 预取上限不是首帧等待条件，也不是流量或首帧延迟已经改善的实测证明。4 秒是全程策略，不是首帧后自动恢复 30 秒；高码率可先触及字节上限。下方 2026-08-26 的 30 秒/0.5 秒策略是历史记录，已由本节 4 秒/0.25 秒配置取代。
- 本次尚未连接 Android 真机：首帧、连续推荐、跨缓存 seek、长暂停、后台/锁屏、Wi-Fi/移动网络切换及单轨冻结恢复均待真机验收。自动测试和 APK 构建不能替代这些验收。

### 2026-09-13 PC 扩展/油猴 0.2.17

- 仅取 playurl 四种 camel/snake URL 字段的真实签名候选；网页不再调用旧 UPOS 主机扩展工具，设置页移除该开关。
- fetch/XHR 在终态暴露前有限重试同一 Range；HTTP/网络错误不再只改后续 URL 而把首次失败直接交给播放器。主动切换重试与会话退休彻底取消分离，退休同时取消网络保护等待和 XHR 定时重试。
- fatal MediaError 每源只准备一次下一候选并重试在途请求；没有经过验证的网页播放器重载接口，明确提示手动/网页重载。不能宣称已 fatal 的 MSE 因换 URL 恢复，也不自动 play/seek。fatal 状态暂停普通健康监测，避免误改位置。
- 2026-09-13 既有匿名审计（未重复联网）：BV1rp4y1e745 / cid244954665，playurl 200/code0；7 流四字段共存相等，Akamai 音视频和 cos 备用 1024-byte Range 均 206 video/mp4。与 2026-06 主机记录一致，不能证明全局换域名。证据为 `/home/amountnothing/workspace/PiliplusAdaptiveCDN/bilibili-cdn-audit-20260913.json`；不复制签名 URL。
- 最终验证：Node 单测 49/49；Chromium 源文件模式 20/20，生成油猴包模式 20/20；10 个 JS/CJS 文件语法检查及 `git diff --check` 通过。使用现有 PowerShell 脚本真实生成 `dist/PiliPlus-Adaptive-CDN-Web.user.js`，元数据版本 0.2.17。验证与打包入口见 `browser-extension/README.md`；真实 Chromium 传输夹具不替代线上完整 MSE 播放验收。

### PC 扩展/油猴 0.2.18：候选级串行重试

- 修复 0.2.17 收到即时 HTTP 错误便在微任务/零延迟定时器循环内遍历候选的问题；不是调高单请求 timeout。每资源/代次共享恢复 Promise、15 秒观察截止时间和一次切换提交。HTTP 确定失败也等待剩余窗口；原先健康检测的 5 秒只申请恢复，不绕过 15 秒候选窗口。
- fetch/XHR 与并发 Range、fatal、健康检查复用同一协调器；旧代次错误不影响新代次，整体网络保护按候选采样并只追加一次有界等待。音视频失败集合/冷却快照独立，仍保留全局评分和下次会话冷却。重复 playurl 不能依据另一轨的全局冷却旁路变更当前候选。
- 暂停、abort、禁用、换视频立即取消等待；单个 abort 不取消其他并发请求的所有权。XHR 隐藏 DONE 后的取消显式补一次 abort/loadend，最终 HTTP 响应体仍可读取。手动换源可立即生效；不 play/seek、不重建 MSE。
- 真实 RED：4 路 Range 同时 403 在不推进测试时钟的情况下访问 A/B/C 共 12 次。GREEN：访问批次为 0/15/30 秒，45 秒结束，切换计数 2；后续推进时钟不再发请求。音频因视频冷却而漏候选、重注册旁路切换、最后一个请求取消后仍后台切换也均先复现后修复。
- 最终验证：Node 58/58；Chromium 源码 32/32，实际油猴产物 32/32（含 fetch/XHR 混合并发、403/原生超时、取消）。原生网络事件由路由夹具产生，时钟窗口由 Playwright clock 控制；不是线上完整 MSE 播放验收。完整说明见 `browser-extension/RETRY-0.2.18.md`。
- 真实 PowerShell 打包 `dist/PiliPlus-Adaptive-CDN-Web.user.js`，版本 0.2.18、50,893 字节、SHA-256 `72406f2d0a9cc7b4780a0135cbbfd69ae440ed97b28f232f210e71a896e59cb5`。core/page/bridge 逐字及顺序核对通过。

### 2026-09-17 三项修复（方案2/3安卓侧；方案1见 browser-extension/RETRY 文档）

- **碎片化卡顿切 CDN**：新增 `AdaptivePlayback.shouldSwitchForFragmentedStalls`——检测窗口（默认 30 s）内缓冲停顿 ≥3 次、累计 ≥3 s 即触发 `_switchToNextCdn(reason: 'fragmented-stall')`，由 `isBuffering` 的 ever worker 记录停顿起止；排除 seek 后 3 s、手动暂停、内容末尾与切换进行中；复用现有切换预算，切换后清空窗口。参数 `adaptiveFragmentStallWindowSec/Count/TotalSec`（默认 30/3/3）已入设置页。背景：旧判定只有 PTS 冻结 8 s 与持续低缓冲，缓冲一越阈值计时即清零，反复短卡永远不触发。
- **息屏修复**：Wakelock 真值源从原生瞬时 `playing` 事件改为播放意图——`AdaptivePlayback.shouldHoldWakelock` + `WakelockHoldManager`（去重 sync），`PlPlayerController._syncWakelock()` 在换媒体结束、buffering、play/pause/completed、生命周期恢复后统一同步；CDN 切换（`_isReplacingMedia`）期间不再丢锁，后台且未开启后台播放或显式暂停立即释放。通知栏在 buffering 且请求播放时保持 playing/buffering，不误报 paused。
- 验证：完整 `flutter test` 97 项通过（基线 80 + 新增 17），相关 5 文件 `flutter analyze` 无问题。真机息屏/切换行为未验证。
- **方案1 PC 油猴 0.2.19**：确定失败（HTTP 4xx/5xx、TypeError）等 `failCooldownMs`（默认 2 s，options 可配 0–15000）即切下一候选，沉默/超时仍等满 15 s 窗口；pause 不再中止在途重试；XHR 耗尽路径终态分发修复（`recoverCandidate().then` 绕过假时钟直接调度重试）。产物 `dist/PiliPlus-Adaptive-CDN-Web.user.js` 55,856 字节、SHA-256 `c0b88caed37932b9cd9cf51766de04d2a8a8b785c1614fb13073367202a87c16`；node --test 63/63，Chromium 源码与打包产物各 34/34（打包产物连续三轮稳定，测试夹具确定性收尾见 `browser-extension/RETRY-0.2.18.md`）。非登录态线上 MSE 播放未验收。

### 2026-10-02 直播三症状修复

- **A 规则拉取不再阻塞 isLoaded**：`lib/pages/live_room/controller.dart:261-271` 抽出 `@visibleForTesting debugLoadStreamAndRules`（`:449-466`）——屏蔽规则拉取 fire-and-forget（`ignore()`），只 await `initLiveUrl`，成功才 `isLoaded.value = true`；`_fetchBlockRules`（`:468-486`）自带 try/catch（kDebugMode 下 `Utils.reportError`），成功响应才写 `_keywordList/_shieldUids`；“未登录不拉、已拉不重复”条件留在调用点。根因：旧 `Future.wait` 让 `isLoaded` 同时等规则接口，挂起则播放器永不渲染（`live_room/view.dart:259`），抛错则异常外泄到 `queryLiveUrl`。
- **B 直播期间跳过视频自适应检查**：`lib/pages/video/controller.dart:1120`（`_checkCdnHealth` 开头）、`:1306`（`_onIsBufferingChanged` 开头）各加 `if (plPlayerController.isLive) return;`。isLive 仍由现有生命周期维护（`live_room/view.dart:120-123 didPopNext` 置 true、`video/view.dart:407` 置 false），未新增机制；测试钩子 `:1102-1114`。注意 `isLive` 期间 `_checkCdnHealth` 内那处 `_cdnRelaySession?.setPlaybackPaused` 同步被跳过，暂停同步仍由 `_relayPlaybackIntentWorker`（`:425`）在 playbackRequested 变化时执行——压栈时切后台的组合场景未真机验证。
- **C 空关键词不吞弹幕**：`lib/pages/live_room/controller.dart:496` 改为 `_keywordList.any((k) => k.isNotEmpty && text.contains(k))`；`_shieldUids` 是 `Set<int>`，非 int uid 由类型检查天然排除。
- **测试**：`test/live_fixes_test.dart` 9 项（A3/B4 含两项非 live 对照/C2），TDD 先 6 项 RED 再 9 项 GREEN；全量 `flutter test` 106 项通过（基线 97 + 新增 9，`cdn_relay_server_test` 时序 flake 单文件复跑通过）；定向 analyze 0 issue、全量 38 条与基线一致。该测试文件需 `.gitignore` 白名单 `!/test/live_fixes_test.dart`。
- 症状/根因/未验证项详见 `docs/plans/2026-10-02-live-fixes.md`。

### 2026-10-12 上游 2.1.6 同步验证

- 范围：`git merge upstream/main`，上游 `a30fcc310..56ad46af4` 66 提交（Release 2.1.6），210 文件变更；2 个冲突已人工解决，工作树无残留冲突标记。下载页重构（`lib/pages/download/controller.dart`→`lib/pages/download/download/`）、我的页多 Tab（`mine/widgets/item.dart`→`fav_item.dart` 等）、iOS 画中画 `PipPlugin.swift`、OGV 迁移等均为上游改动。
- 工具链：`.fvmrc` / `pubspec.yaml` 随上游 pin Flutter **3.47.7**（`.tooling/flutter-3.47.7`）；本地框架补丁（`lib/scripts/*.patch` 中 android/linux 适用的 24 个）与 material_ui **1.6.0** 的 9 个补丁均已正向应用并通过 `--dry-run -R` 反向核对；3 个 iOS 专用补丁按惯例未应用。
- 依赖：`flutter pub get` 已按合并后的 `pubspec.lock` 同步（`cached_network_image_ce` 上游改回 `bggRGjQaUbCoE` ref `733d4aa`）。新增传递依赖 `cnativeapi 0.5.2` 带 native-assets build hook，Linux 上需要 clang——execution 容器内已 `apt install clang`；`flutter config` 的 `enable-native-assets` 保持默认 `Not set`（未改动，这是预期设置）。
- 验证（2026-10-12，执行容器）：全项目 `flutter analyze` 92.6s / 38 issues（全部为合并前即存在的 vendored `lib/common/widgets/flutter/*` info、`package_names` 等）；`flutter analyze lib/pages/setting/models/extra_settings.dart` 0 issue；全量 `flutter test` **106/106 通过**（含 `cdn_relay_server_test` 时序用例与 `live_fixes_test`）。
- 本地修复核对：`playbackRequested`/`WakelockHoldManager`（pl_player/controller）、`debugLoadStreamAndRules`（live_room）、`debugCheckCdnHealth`/`isLive` 早退（video/controller）、`cdn_relay_server.dart` 均在合并结果中，且合并 diff 未删除这些标记行。
- 索引：`tool/generate_codebase_index.ps1` 已重建 `SOURCE_FILE_INDEX.md` / `SYMBOL_INDEX.md`（files=1672）。
- 遗留：未做 Android 真机验证；未推送（gh 令牌缺 `workflow` 作用域）。
- 2026-10-13 执行容器编 APK 成功（AGP 9.1.1 + Kotlin 2.4.0 + Gradle 9.3.1 首次真实构建）。容器 cgroup 内存上限 3 GiB，`android/gradle.properties` 的 `-Xmx4G` 会 OOM 杀 daemon；不改仓库文件，在容器本地 `~/.gradle/gradle.properties` 设 `org.gradle.jvmargs=-Xmx1000m -XX:MaxMetaspaceSize=420m -XX:ReservedCodeCacheSize=192m`、`kotlin.compiler.execution.strategy=in-process`、`org.gradle.workers.max=2`，并把内存峰值串行化：先单独用 dartvm 调 `flutter_tools.snapshot --quiet assemble … android_aot_bundle_release_android-arm64` 完成 kernel/AOT（`--DartDefines` 必须用 gradle `-Pdart-defines` 的原始 base64 blob——`FLUTTER_GIT_URL=…/flutter.git` 带 `.git`，否则缓存不命中、Gradle 侧重跑 frontend_server 与 daemon 叠加超限），再跑完整 `flutter build apk --release --target-platform android-arm64 --split-per-abi --android-project-arg=kotlin.incremental=false --android-project-arg=kotlin.compiler.execution.strategy=in-process`，Gradle 侧 assemble 命中缓存。产物 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`：24,451,359 字节，SHA-256 `c58f3fa07598d0a44ceebe7204b1e60f906b65c3316c15c55e02f6f193f5fc6c`，versionName 2.1.6 / versionCode 1 / minSdk 24 / targetSdk 37，debug 签名（仓库无 `key.properties`，按 `build.gradle.kts:65` 回退），含上游 `cnativeapi` native-assets 产物 `libcnativeapi.so`（构建环境需 clang 与 NDK）。

### 2026-10-14 浏览器扩展 0.2.20：5 秒首字节快速失败与请求取消看门狗

- 症状（VPS 无头 + live B 站实测）：播放极为容易卡住、无法开始播放。受控 A/B（路由静默阻断首候选）下 0.2.19 与修复前 0.2.20 都 90 秒不切换：B 站播放器启动期自行 abort 每条媒体 XHR（发送后 2.3–5.1 秒，栈在 `player/main/core.js`）轮换 host，脚本按设计把 abort 当 `cancelled` 释放 → `recoverCandidate` 从未进入；改写又把播放器发往备机的请求重写回首候选 → 死锁（备机 0 条请求、`loadstart` ×3、`web_videoload_fail code 4004`）。
- 修复：`candidateDeadline()` 未收字节候选由 15 秒改为 5 秒首字节预算（`FIRST_BYTE_WINDOW_MS`，收过字节仍 15 秒）；新增 `armCandidateWatchdog`（每 1 秒）——未收字节、候选起始超 5 秒、该资源仍有活跃请求时后台 `recoverCandidate("candidate-timeout")`，复用全部既有闸门与一次性提交，不新增切换入口；空闲资源与已收字节资源不触发。
- 测试：`node --test` **63/63**（原 61 + 新增 2 条看门狗回归）；`chromium.cjs` 源码 **34/34**、产物 **34/34**。线上受控 A/B：0.2.19 基线不开播，0.2.20 切到备机 `upos-sz-mirrorcosov.bilivideo.com` 后开播；无阻断回归 0 切换正常开播。`/*DBG*/`→`window.__piliDebug` 诊断插桩已全部回滚（源码 `grep DBG` = 0）。
- 产物：`dist/PiliPlus-Adaptive-CDN-Web.user.js` **0.2.20**，57,533 B，SHA-256 `5cf0045a6f81bfec8dd16968319e0f958f64bdf12df4cefa79823a78964d5316`；验收细节见 `browser-extension/RETRY-0.2.20.md`，探针与线上 JSON 在 `dist/.qa/online/`（gitignored）。
- 遗留：未推送（gh 令牌缺 `workflow` 作用域）；2 个 NXDOMAIN 死域名是否从 `cdn_type.dart` 移除仍待用户确认。

- 同日约定：`AGENTS.md` 的开工必读改为「新会话首次接管全读一次、后续按需读章节」，并新增大文件按需读取全局规则（禁止 `cat` 全文，>200 行/8KB 分段读，结论写回文档）；规则同时要求全局生效于 `~/.hermes/SOUL.md`，其待应用副本在宿主 `/shared/global-context-rules-SOUL.md`。

### 2026-10-17 浏览器扩展 0.2.21：新视频按排名重新遍历全部候选

- 症状：再打开一个新视频，10 秒内即显示“候选 CDN 已遍历完”，之后播放卡住。复现（确定性时钟）：旧视频把 A/B/C 全部失败进 60 秒冷却后，60 秒内打开 BV2（同主机、不同签名路径），新视频只发 1 次请求（2 秒确定失败等待后）即宣布遍历完成并永久 `exhausted`。
- 根因：`registerStream` 给新资源快照继承全局 `cooldowns`（`cooldowns: {...cooldowns}`），`candidatesFor` 用该快照硬排除冷却主机；`cleanExpiredState` 只清理全局表，快照永不过期。跨视频冷却本意是“当前视频内排除”，实际变成了“60 秒内新视频也排除”，与“每次打开新视频按排名重新遍历、逐个尝试”的项目目的偏移。
- 修复（`browser-extension/page.js`，只动扩展相关区域）：新资源不再继承冷却快照（字段删除），同视频排除只看本视频 `failedHosts`；新增 `orderFreshCandidates`——新视频/新资源保留全部候选并逐个尝试，仍在冷却窗口的主机按评分排最后（降级为排序影响，不再硬排除）。跨视频记忆保留在评分（失败 -28 分）和该排序里；`cooldownSec` 设置保留（仍记录/展示/持久化，控制软排序窗口）。
- 测试：`node --test` **64/64**（原 63 + 新增 1 条新视频回归：BV1 全失败耗尽后切 BV2，断言新视频依次尝试 A2/B2/C2、2 次切换、最终才报遍历完）；Chromium 真实传输回归源码模式 34/34、油猴产物模式 34/34（`PLAYWRIGHT_BROWSERS_PATH=dist/.qa/browsers`）。
- 产物：`manifest` 0.2.20→0.2.21，`browser-extension/README.md` 同步更新跨视频冷却语义；`dist/PiliPlus-Adaptive-CDN-Web.user.js` 已用 node 复刻 `package-userscript.ps1` 逻辑重新生成（57,533 B→56,880 B，SHA-256 `920af38e1430670131e4c0e8bd747ed4d1c125205be40f7e111327f823daa654`，bridge 尾部与旧产物逐字节一致、仅版本号与 core/page 变化）。线上完整 MSE 播放仍待真机/真实浏览器验收。
- 遗留：未推送；`PiliPlus-Adaptive-CDN-Web-0.2.6.zip` 为历史产物，本次未重打（扩展 zip 命名停留在 0.2.6，与 manifest 版本无关）。
- 0.2.21 清理（未改行为）：删除 `core.js` 中网页端零调用的 `KNOWN_UPOS_HOSTS`/`expandUposCandidates`/`isAv1Codec`/`isCurrentResourceFailure`（约 1.6KB）及对应 3 条单测；`page.js` 合并排序 helper、补齐 toast 文案。`docs/SYMBOL_INDEX.md` 仅删了对应 6 行，行号类索引以 `tool/generate_codebase_index.ps1`（需 pwsh）重建为准。

### 2026-10-18 安卓番剧未知清晰度崩溃修复

- 症状：动态/番剧下打开《凡人修仙传》（大会员账号）弹错 `Null check operator used on a null value`，栈顶 `VideoQuality.fromCode (video_quality.dart:25)` ← `VideoItem.fromJson (url.dart:333)`。
- 根因已核实：不是账号/权限问题。B 站给该番剧下发了 dash 流 `id=100`（qn=100 “智能修复”，VIP 专享档）；本仓库基线（上游 2.1.6）的清晰度表没有 100，`_codeMap[100]!` 抛异常。上游在 2026-10-16 `refa video/audio/live quality`（936072449）已补 100 并把 `fromCode` 改为未知时动态兜底，本仓库合并基线早于该提交所以中招。上游音频表与本仓库一致，无新增音频 id。
- 修复：`video_quality.dart` 补 `superResolution(100, '智能修复', '智能修复')`（112 与 80 之间，保持降序）；`VideoQuality/AudioQuality.fromCode` 未知 code 保留兜底（回落到小于等于该 code 的最近已知档，否则最低档），已知 code 行为不变。未照搬上游的 class 重构（本仓库多处按枚举使用），改动最小。
- 测试：`test/media_quality_test.dart` 8 项（100 精确解析、未来未知 id 兜底、`VideoItem.fromJson` 不崩）；`.gitignore` 加白名单。全量 `flutter test` **114/114**（基线 106 + 新增 8），定向 `flutter analyze` 0 issue。APK 未构建，真机番剧播放待用户验收。

### 继续项目时先做什么

1. 新会话首次接管时完整读取本文档和根目录 `AGENTS.md` 一次，后续任务按需读取相关章节；大文件一律按 `AGENTS.md` 的「大文件按需读取」规则处理。
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

## 6. 跨会话记忆与日志约定（2026-10-28）

- 长期权威仍是本文档：改变长期行为、默认参数、构建位置或已确认基线时，必须同步更新本文。
- 当前状态/风险/下一步写在 `docs/PROJECT_STATUS.md`（只保留当前真相，状态变化时改写）。
- 每个 session 的流水写在 `docs/SESSION_LOG.md`（只追加；全文历史看 git）。
  两者都是 GitHub 上的长期记忆，不依赖任何单机 memory。
- 项目身份与入口：同一 git 仓库的 clone/worktree 在 OpenCode 里属于同一个 project
  （id `5a699928…`，仓库级、非目录级）。手工任务在 `workspace/piliplus-maintenance` 上建新 worktree，
  定时同步用 bridge 的 `task-*` worktree，分支前缀隔离（`sync/` 与其他）。详见 `docs/OPENCODE_PROJECT.md`。
- 人工合并与 upstream sha ancestry 的要求不变：CI 绿只是必要条件，合并永远由人决定。
