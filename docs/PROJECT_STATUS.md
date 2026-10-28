# 项目状态快照

更新：2026-10-28（由部署 Agent 建立，不是 OpenCode 任务产物）
用途：任何 session 开工前 30 秒读完的「当前状态 / 风险 / 下一步」。**只保留当前真相**：
历史看 `git log --follow -- docs/PROJECT_STATUS.md`，逐会话流水看 `docs/SESSION_LOG.md`。

## 1. 基准

| 项 | 值 |
|---|---|
| 下游 origin | `amountnothing/PiliPlus-Adaptive-CDN` |
| `origin/main` | `6f69d9c7c51796262192254df9ade0c3eaa7a1d7`（含 PR #1 `ops/hermes-opencode-pr-ci`） |
| 上游 | `bggRGjQaUbCoE/PiliPlus` `main` = `628290b5c760facfdd910195f679362ec0ad9fc7`（2026-10-28 实测） |
| CI 必过 job | `Analyze + unit tests`、`Build Android APK (dev)`（`.github/workflows/pr-check.yml`） |
| 合并策略 | 只能人工合并；同步 PR 用 **merge commit**，禁止 squash（upstream sha 的 ancestry 依赖它） |

## 2. 进行中的任务

- `task-20261028-00741b02`：`prepared`，把上游 `628290b5` 合到 base `6f69d9c7`，分支
  `sync/upstream-628290b5-00741b02`，worktree 在 bridge 运行目录下，attempts/rounds 均为 0，
  尚无 session。它取代了 stale-base 的 `task-20261028-c8b9a05b`（base `30e6c4e9`）。
- bridge `_budget()` 对「无执行痕迹」的行在**派发时**重新起 5400s 窗口（`_start_budget`），
  prepare 阶段记下的 `deadline_epoch` 不会把排队时间算进预算。
- 同一时刻只允许一个 writer：该任务未到终态前不要再派第二个任务。

## 3. 已知风险

1. **OpenCode 的代码能力仍未验证**。现有证据只有静态配置、bridge 的 Python 测试和 Flutter CI，
   都不能证明它能在这个仓库里改对代码。第一次真实派发按事实记录，不做奖励性叙述。
2. gh 令牌缺 `workflow` 作用域：任何触及 `.github/workflows/` 的推送会被拒，需要人执行
   `gh auth refresh -h github.com -s workflow`。
3. 主 checkout `/home/amountnothing/workspace/piliplus-adaptive-db` 的两个
   `macos/Flutter/*.xcconfig` 永久 dirty，本地 `main` 停在 `30e6c4e9`（落后 `origin/main`）。
   永远不要 pull/reset/stash/clean 它。
4. VPS 上没有常规可用的 Flutter SDK；「bridge Python 测试绿」≠「Flutter 测试绿」，两边分别跑、分别报。
5. OpenCode 项目是**仓库级**的：维护 clone、CI worktree、bridge worktree 共享同一个 project
   （实测），session 列表会混在一起。靠分支名、worktree 路径和日志文件区分。

## 4. 下一步（按顺序）

1. 由人决定是否派发 `task-20261028-00741b02`（运行时 `allow_dispatch` / `allow_publish` 均为 true）。
2. 派发后看 `bin/piliplus-bridge status` 的 state/error_class；`partial/awaiting_publish` 时在同一
   tick 内 `bin/piliplus-bridge publish <task-id>`；CI 绿也只算 `awaiting_merge`，合并仍要人做。
3. 手工功能/修复按 `docs/OPENCODE_PROJECT.md`，在维护 clone 上新建 worktree + 新建 session。
