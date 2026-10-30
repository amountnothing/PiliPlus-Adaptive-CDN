# OpenCode 专用项目入口（PiliPlus Adaptive CDN）

本文件说明本仓库在 OpenCode 中的**项目身份**、工作区布局和 session 约定，补充
`AGENTS.md` 与 `docs/PROJECT_CONTEXT.md`，不替代它们。

## 1. 项目身份（原生机制，不是自造概念）

OpenCode v2.0.18 **没有** `project` 子命令，也没有注册/重命名项目的 CLI（`opencode --help`
的 SUBCOMMANDS 只有 upgrade/uninstall/acp/api/debug/auth/mcp/plugin/models/stats/mini/run/
session/service/reload/pair/serve）。项目身份由**仓库**决定，由 OpenCode 自己落库到
`~/.local/share/opencode/opencode.db`：

- 同一 git 仓库的不同 clone 和 linked worktree 会归到**同一个 project**；
- `project` 表存 `id / worktree / vcs / name`；`worktree` 表按 `(project_id, directory)` 记录每个
  worktree，`strategy` 为 `git` 表示 git 链接 worktree。

| 项 | 值（2026-10-28 实测） |
|---|---|
| project id | `5a699928a9efb1d0d5ff5488c607b371f5c05906` |
| `project.name` | NULL（无设置入口，显示名即目录名；**不要手改 DB**） |
| origin | `amountnothing/PiliPlus-Adaptive-CDN` |
| 专用干净 clone（手工任务入口） | `/home/amountnothing/workspace/piliplus-maintenance` |
| 专用 worktree 目录约定 | `/home/amountnothing/workspace/piliplus-maintenance-<slug>` |
| 已登记到同一 project 的其他 worktree | `/home/amountnothing/workspace/piliplus-pr-ci`、bridge 的同步 worktree |

实测结论：在主 checkout、CI worktree、维护 clone 里跑 OpenCode，`session list` 看到的都是同一个
project 的 session。要"分开"只能靠 **worktree 路径 + session 选择 + 各自的日志文件**，换目录不等于换项目。

## 2. 三种入口，不要混用

| 入口 | 谁发起 | 工作区 | session |
|---|---|---|---|
| 定时上游同步 | Hermes cron → `piliplus-bridge` | `agent-data/piliplus-bridge/worktrees/task-*` | bridge 建；修复轮用 `--session <id>` 续 |
| 手工功能/修复 | 人或 Hermes 手动 | 维护 clone 上**新建 worktree** | 每个新任务**新建 session** |
| 文档/规则维护 | 人或 Hermes 手动 | 专用 docs worktree（如 `piliplus-maintenance-docs`） | 可续用同一 session |

- 手动任务**不要**复用 bridge 的 `task-*` worktree，也不要借 cron job 跑。
- 同一任务的多轮修复续用同一个 session（`opencode run --session <id>`）；跨任务不复用，
  避免旧任务意图污染新任务。
- 分支隔离：定时 = `sync/upstream-<sha8>-<task8>`；手工 = `<type>/<slug>`，**不得**以 `sync/`
  开头；任何人都不直接推 `main`。

## 3. 每个 session 开头必读（顺序固定）

1. `AGENTS.md`
2. `docs/PROJECT_CONTEXT.md`（首次接管全读一次；之后按章节查）
3. `docs/CI_AND_SYNC.md`
4. `docs/PROJECT_STATUS.md`（全文，很短：当前状态/风险/下一步）
5. `docs/SESSION_LOG.md`（**只读最近 3–5 条**；完整历史用 `git log -- docs/SESSION_LOG.md`）

`docs/CODEBASE_REFERENCE.md` / `docs/SOURCE_FILE_INDEX.md` 不整读，按 `AGENTS.md` 的
「大文件按需读取」用 `grep`/`rg` 定位。

## 4. 每个 session 结束必须写日志

追加一条到 `docs/SESSION_LOG.md`（字段见该文件头），必须包含：日期 / session ID（真实 ID，
不知道写 `pending`）/ 任务目标 / 修改范围 / **真实执行过的命令与 exit code** / 测试与 CI 结果 +
PR URL / 未做事项与风险 / 下一步。

- 不写 secret、token、签名 URL、内网凭据。
- 没跑写「未跑」，失败写失败，**禁止把红写成绿**。
- 长期约束（新增/变更的边界、默认参数、验证基线）写进 `docs/PROJECT_CONTEXT.md`，不要只留在日志里。

## 5. 文档未合并前的 bootstrap（只读快照）

bridge 的定时 worktree 从 `origin/main` 切出，看不到尚未合并的文档。过渡期以运行账户下的只读快照为准
（目录 0700、文件 600，**只读不改**）：

```
/home/amountnothing/agent-data/piliplus-project/SESSION_RULES.md
/home/amountnothing/agent-data/piliplus-project/PROJECT_STATUS.md
/home/amountnothing/agent-data/piliplus-project/SESSION_LOG.md
```

并发保护：每个 session 的日志写**自己 worktree 里**的 `docs/SESSION_LOG.md`；共享快照只读，
不要多个 session 同时追加同一份日志。
