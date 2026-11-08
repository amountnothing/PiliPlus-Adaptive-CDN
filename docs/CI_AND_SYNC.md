# CI 与上游同步规则

推送与合并权限以 `AGENTS.md` 为准，本文只说明工作流和流程细节。

## 1. GitHub Actions 工作流

| 文件 | 触发方式 | 权限 | 用途 |
|---|---|---|---|
| `.github/workflows/pr-check.yml` | `pull_request`、`workflow_dispatch` | `contents: read` | 单元测试、咨询性静态分析、Android dev split APK |
| `.github/workflows/adaptive_release.yml` | `workflow_dispatch` | `contents: write` | 签名并发布 Android APK 与浏览器扩展 |

上游原有的 `build.yml`、`ios.yml`、`mac.yml`、`win_x64.yml`、`linux_x64.yml` 保持原样，除非任务明确要求修改。

## 2. 上游同步

- 拉取 `upstream`（`bggRGjQaUbCoE/PiliPlus`）后合并到 `main`；无冲突直接推送，不要求 PR。
- 有冲突时停止，由人决定解决方式及是否合并；重点检查 Adaptive CDN、播放器、动画和扩展边界。
- 同步用 merge commit，不用 squash/rebase，保留上游提交的 ancestry。
- 同步后更新 `.github/upstream-release.txt`（对应的上游 release 版本）。

直接推到 `main` 不会触发 PR CI。需要验证时走 PR，或手动 `workflow_dispatch` 运行 `pr-check.yml`。

## 3. PR CI 检查内容

- `flutter test`：必须通过。
- `flutter analyze`：`continue-on-error`，历史遗留问题较多，结果仅供参考。
- Android dev split APK：构建并上传为 Actions Artifact，供测试下载。

PR CI 不访问发布 Secrets，不执行 Release，不修改仓库。CI 失败应修复实际问题，不得删除必要检查来规避。

## 4. Release 发布

- 由 `adaptive_release.yml` 负责，仅能 `workflow_dispatch` 手动触发，且需要用户明确要求。
- 构建指定提交的 Android APK 与浏览器扩展，签名 Secrets 只在该工作流中使用。
- 上游同步与 PR CI 都不会自动触发 Release。

## 5. 已知事项

- `pr-check.yml` 已在 PR #5（2026-11-08，run 42489771995）实际跑通两项 job。
- Android 构建依赖 `cnativeapi` native-assets，换 runner 或 NDK 时注意 Clang/NDK 配置。
