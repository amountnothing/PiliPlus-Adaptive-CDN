# 项目状态快照

更新：2026-11-08
只保留当前真相，状态变化时改写；历史看 `git log -- docs/PROJECT_STATUS.md`。

## 1. 基准

| 项 | 值 |
|---|---|
| 下游 | `amountnothing/PiliPlus-Adaptive-CDN`，`main` 为唯一源码基准 |
| 上游 | `bggRGjQaUbCoE/PiliPlus` `main`；已同步的上游 release 见 `.github/upstream-release.txt` |
| CI 必过 job | `Analyze + unit tests`、`Build Android APK (dev)`（`pr-check.yml`，已在 PR #5 实际跑通） |
| 推送与合并 | 无冲突直接推 `main`；有冲突由人决定（见 `AGENTS.md`） |

## 2. 进行中的任务

- 无。

## 3. 已知风险

1. macOS 构建未验证：PR #5 加入的 CocoaPods `#include?` 只经过 Android/单测 CI，`mac.yml` 未运行。
2. Flutter `analyze` 全项目基线不干净，CI 只作参考；判断改动质量需看相关文件的新增告警。
3. 构建与测试通过只证明对应层；Android 播放、后台暂停、PiP、弱网、CDN 切换和浏览器 MSE 行为需真机或真实浏览器验证。
4. 推送 `.github/workflows/` 需要带 `workflow` 作用域的 GitHub 令牌。

## 4. 下一步

1. 按需检查并合并上游新提交（流程见 `docs/CI_AND_SYNC.md`）。
2. 需要时手动触发 `mac.yml` 验证 macOS 构建。
