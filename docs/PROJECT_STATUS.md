# 项目状态快照

更新：2026-11-14
只保留当前真相，状态变化时改写；历史看 `git log -- docs/PROJECT_STATUS.md`。

## 1. 基准

| 项 | 值 |
|---|---|
| 下游 | `amountnothing/PiliPlus-Adaptive-CDN`，`main` 为唯一源码基准 |
| 上游 | `bggRGjQaUbCoE/PiliPlus` `main`；已同步到 `4fce4bb5a`（2.2.0.2 之后），见 `.github/upstream-release.txt`。2026-11-14 核对：上游最新 release 标签仍是 2.2.0.2，`main` 另有未打标签的新提交，按“上游发新版本才合并”的指示未合并 |
| CI 必过 job | `Analyze + unit tests`、`Build Android APK (dev)`（`pr-check.yml`，已在 PR #5 实际跑通） |
| 推送与合并 | 无冲突直接推 `main`；有冲突由人决定（见 `AGENTS.md`） |

## 2. 进行中的任务

- 无。最近合入：2026-11-14 PR #7（直播弹幕断线重连、心跳资格逐次判断、`Player.open` 期间丢失的 playing 事件重新同步、`Resume:`/`LiveDm:` 诊断日志；CI 两项通过，快进合入 `main`）；2026-11-08 PR #6（上游 2.2.0.2+ 同步、删除 4 个死 CDN、重打扩展 ZIP）。

## 3. 已知风险

1. macOS 构建未验证：PR #5 加入的 CocoaPods `#include?` 只经过 Android/单测 CI，`mac.yml` 未运行。
2. 上游同步后的播放器（seek、后台暂停恢复、音频中断、多段 durl）需 Android 真机回归。
3. `SOURCE_FILE_INDEX.md`/`SYMBOL_INDEX.md` 未随上游同步重建（`tool/generate_codebase_index.ps1` 需 pwsh）。
4. Flutter `analyze` 全项目基线不干净，CI 只作参考；判断改动质量需看相关文件的新增告警。
5. 构建与测试通过只证明对应层；Android 播放、后台暂停、PiP、弱网、CDN 切换和浏览器 MSE 行为需真机或真实浏览器验证。
6. 推送 `.github/workflows/` 需要带 `workflow` 作用域的 GitHub 令牌。
7. PR #7 的真机验证只覆盖一部分：2026-11-14 OnePlus 日志（4 个视频切换）显示续播起点与服务器进度一致、离开心跳进度与已播时长吻合、无异常或堆栈。但每次点播都出现 `Player: resync playing=true after open (event was dropped)`，且起播后约 1.5–2.3 秒触发 `PlaybackRecovery: kick stalled start/resume`（既有看门狗）；没有合入前基线，未判定是否回归，需要时用同一批视频对比。直播弹幕断线重连未见真机日志验证。

## 4. 下一步

0. 真机确认 PR #7：直播进房几秒内出现弹幕（日志有 `Player: resync playing=true`）；续播若再丢，看 `Resume: leave heartbeat` 的 `login=`/`historyPause=`。

1. 装 APK 真机回归播放器（PR #6 的 dev APK 在其 Actions artifact）。
2. 有 pwsh 的环境重建代码索引。
3. 需要时手动触发 `mac.yml` 验证 macOS 构建。
