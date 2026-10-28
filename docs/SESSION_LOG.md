# 会话日志（唯一的跨 session 流水）

规则：

- 每个 session 完成时**追加到最末尾**，不改写别人的条目。
- 判断上下文只读**最近 3–5 条**；完整历史 `git log -- docs/SESSION_LOG.md`。
- 字段固定：日期 / session / 任务目标 / 修改范围 / 真实命令与 exit code / 测试与 CI / 未做与风险 / 下一步。
- 不写 secret、token、签名 URL、内网凭据。没跑的测试写「未跑」，红的写红，禁止把红写成绿。
- 同一工作树不要被两个 session 并发追加。

---

## 2026-10-28 · session=pending · 部署 Agent（**不是** OpenCode 任务）

- 目标：为 PiliPlus 建立专用 OpenCode 项目入口与跨 session 记忆/日志约定，并接入定时任务的读写规则。
- 修改范围：仅文档与 bridge 提示词 —— 新增 `docs/OPENCODE_PROJECT.md`、`docs/PROJECT_STATUS.md`、
  `docs/SESSION_LOG.md`；`AGENTS.md`、`docs/PROJECT_CONTEXT.md` 各追加一节；
  `ops/piliplus-bridge/bridge.py` 的 `build_prompt` 增加 session 约定。`lib/`、`browser-extension/`、
  `.github/` 未改。
- 真实命令（exit 0 已核对）：`git clone --reference … piliplus-maintenance`（HEAD `6f69d9c7`）、
  `git worktree add -b docs/opencode-project-memory-1 …`、`opencode session list --standalone`
  （维护 clone 与 docs worktree 各一次，无模型调用）、`sqlite3 -readonly` 只读查 project/worktree 表、
  `git diff --check`。
- 测试与 CI：本次文档分支未触发 CI、未 push；Flutter 测试未跑（无代码改动）；
  bridge 侧改动跑了 Python `unittest` 全量：`Ran 137 tests ... OK`（exit 0，153.8s）。
- 未做与风险：文档未合并前，bridge 定时 worktree 从 `origin/main` 切出看不到这些文件，
  过渡期用 `/home/amountnothing/agent-data/piliplus-project/` 的只读快照。
- 下一步：第一次真实 OpenCode 任务结束后，由它在自己的 worktree 里追加一条**真实 session ID**
  的记录，包含真实 exit code 与 CI/PR 结果。
