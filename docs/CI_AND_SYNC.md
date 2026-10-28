# CI 与上游同步规则（下游定制）

本文件说明本 fork 的 CI/同步边界，供后续 Agent 与人类维护者共用。它与
`AGENTS.md` 的长期边界一致，不覆盖原项目规则（先读 `docs/PROJECT_CONTEXT.md`
与 `docs/CODEBASE_REFERENCE.md` 的要求仍然有效）。

## 1. 两个 workflow 的分工

| 文件 | 触发 | 权限 | 作用 |
|---|---|---|---|
| `.github/workflows/pr-check.yml` | `pull_request`（opened/synchronize/reopened/ready_for_review）、`workflow_dispatch` | `contents: read` | 单测 + 咨询性 analyze + Android dev split APK 产物 |
| `.github/workflows/adaptive_release.yml` | 仅 `workflow_dispatch` | `contents: write` | 手动签名 release（Android APK + 浏览器扩展附件） |

`build.yml` / `ios.yml` / `mac.yml` / `win_x64.yml` / `linux_x64.yml` 保持原样，
不带 `pull_request` 触发，PR 上不会运行，也不会有 `write-all` 令牌落到 PR 代码上。

## 2. 为什么没有定时任务

旧版 `adaptive_release.yml` 带 `17 */6 * * *`：发现新上游 release 就在 Actions 里
`git merge` 后 `git push origin HEAD:main`。这等于让机器人绕过评审直接改主干，且
冲突时静默跳过，Actions 长期红/绿不可信。现已移除：

- 没有任何 workflow 会 `git push` 到 `main`；
- 上游同步必须走 PR（见下），由人合并；
- release 只构建你显式 dispatch 的那个提交。

## 3. 上游同步怎么走

同步由 `ops/piliplus-bridge`（运行在 VPS 上，与本仓库解耦）驱动：

1. `watch` 探测上游新提交 → 建 worktree/branch → 交给 OpenCode 在同一 worktree 内做**有界**单任务；
2. OpenCode 只允许改代码、跑测试、`git commit`/`git push` 到自己的 `sync/*` 分支，不允许改 main；
3. bridge 用 gh 校验：PR 必须是 **open、base=main、head=本任务分支、head sha=worktree HEAD**，
   且该 head 的 check-runs 全绿，才算 `succeeded`。空检查列表、pending、闭 PR、陈旧 head 一律不算成功；
4. `publish`（建 PR）由 `allow_publish` 单独开关，默认关闭；`allow_dispatch` 控制是否允许
   调度器真正调用模型，默认关闭。

也就是说：**同步=PR；合并=人**。CI 绿是必要条件，不是合并许可。

## 4. 下游定制的保留点

PR CI 只做构建与测试，不修改这些定制；同步合并时若上游改动触及它们，按“保留我们全部修复 +
吸收上游结构”的既有原则处理：

- `lib/scripts/patch.ps1`（Android 补丁步骤，PR CI 与 release 都执行）；
- `pili_release.json` / `--android-project-arg dev=1` 的 dev 口味构建；
- Adaptive CDN Relay/拼接、网络暂停保护、音视频整体暂停逻辑（禁止删除）；
- 浏览器扩展 `browser-extension/` 与 `dist/` 产物；
- 日志策略：只记录异常/切换/恢复摘要。

## 5. 已知未验证项

- `pr-check.yml` 尚未在 GitHub 上真实跑过（本地无法安装 Flutter SDK，本轮只做静态校验）。
- `flutter analyze` 设为 `continue-on-error`：本 fork 全项目 analyze 基线本就不干净
  （合并前既有问题），因此它只作提示，真正的门是 `flutter test`。
- Android 构建依赖 `cnativeapi` native-assets（需要 clang/NDK），首次真实运行可能暴露
  环境差异；失败时以日志为准修 workflow，不要放宽测试门。
