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

## 2026-10-29 UTC（精确时分未取到，`date` 被 shell 权限拒绝） · session=ses_e7b3bd9cbffeNXKaQ781PEJTGO · 文档维护/验证基线

- 目标：在 `docs/opencode-project-memory-1` worktree 真实执行扩展基础单测与 `git diff --check`，
  把「本环境可测/不可测」写回状态文档，并追加本会话真实记录。
- 修改范围：仅 `docs/PROJECT_STATUS.md`、`docs/SESSION_LOG.md`；未改代码、测试、manifest、
  `.github/`、`opencode.json`；未新增可选 `scripts/check-extension.sh`（shell 权限无法保证执行，
  避免提交未验证脚本）。
- 真实命令与 exit code：
  - 读记忆文档：`AGENTS.md`、`docs/PROJECT_CONTEXT.md`、`docs/CI_AND_SYNC.md`、
    `docs/PROJECT_STATUS.md`、`docs/SESSION_LOG.md`（文件读取工具，无 exit code）。
  - `git status --short` → 仅 `?? opencode.json`（未跟踪，未纳入提交）。
  - `cd browser-extension && /home/amountnothing/.hermes/node/bin/node --test test/core.test.cjs test/page.test.cjs test/xhr.test.cjs`
    → exit 0；`tests 61` / `pass 61` / `fail 0` / `duration_ms 913.96`。未用 npm、未改测试。
  - `git diff --check` → exit 0（无输出）。
  - `git rev-parse --abbrev-ref HEAD` → `docs/opencode-project-memory-1`。
- 测试与 CI：以上为本地真实结果；未触发 GitHub CI，未 push，无 PR URL。Flutter/APK、
  真实浏览器/MSE、`chromium.cjs`（缺 playwright）均未运行。部署端历史记录的扩展单测约
  **1.8s** 只是部署端历史，不是本环境本次执行。
- 未做与风险：Flutter/Android 工具链与真实浏览器行为未验证，不能由本记录推断 CI 或播放效果；
  `opencode.json` 仍为未跟踪运行环境配置。
- 下一步：由人 review 后决定是否合并本 docs 分支；需要扩展完整覆盖时，在具备 playwright 的环境
  单独运行 `chromium.cjs`，需要 Flutter 验证时走 PR CI。
