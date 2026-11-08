# CI 与上游同步规则

本文档说明本 Fork 的 GitHub Actions 配置、CI 验证与发布流程。

项目执行约束、上游同步权限及定制功能保护原则统一以 `AGENTS.md` 为准。

## 1. GitHub Actions 工作流

| 文件 | 触发方式 | 权限 | 用途 |
|---|---|---|---|
| `.github/workflows/pr-check.yml` | `pull_request`、`workflow_dispatch` | `contents: read` | 单元测试、静态分析、Android dev split APK |
| `.github/workflows/adaptive_release.yml` | `workflow_dispatch` | `contents: write` | 签名并发布 Android APK 与浏览器扩展 |

原项目的 `build.yml`、`ios.yml`、`mac.yml`、`win_x64.yml`、`linux_x64.yml` 保持原有配置，除非任务明确要求修改。

## 2. 上游同步与 CI

上游同步遵循 `AGENTS.md`：

- 无合并冲突时，允许自动推送至 `main`。
- 发生合并冲突时，由人工决定解决方式及是否合并。
- 普通无冲突同步不要求创建 PR。

CI 分为两种场景：

**PR 检查**

创建或更新 PR 时自动运行 `pr-check.yml`，用于验证代码修改，并提供测试 APK。

**主分支同步**

上游更新直接推送至 `main` 时，不依赖 PR CI。

如需主分支更新后自动运行相同检查，应在对应 Workflow 中配置 `push: main` 触发器。

CI 结果用于验证代码，不改变 `AGENTS.md` 定义的同步与合并权限。

## 3. PR CI 检查内容

- `flutter test`：必须通过。
- `flutter analyze`：使用 `continue-on-error`，结果仅供参考，不阻断 CI。
- Android dev split APK：构建并上传 Actions Artifact，供测试下载。

PR CI 不访问发布 Secrets，不执行 Release，不直接修改仓库代码。

CI 已获长期执行授权，无需逐次确认。

## 4. Release 发布

正式发布由 `adaptive_release.yml` 负责。

- 仅允许通过 `workflow_dispatch` 手动触发。
- 必须得到用户明确授权。
- 构建指定提交对应的 Android APK 与浏览器扩展。
- 签名所需 Secrets 仅在授权的发布工作流中使用。
- 上游同步与 PR CI 均不得自动触发正式 Release。

## 5. 已知未验证项

- `pr-check.yml` 尚未经过 GitHub Actions 实际运行验证。
- Flutter Analyze 存在历史遗留问题，暂不作为强制通过条件。
- Android 构建依赖 `cnativeapi` native-assets，可能涉及 Clang/NDK 环境配置。
- 首次执行时应依据实际日志确认工作流及构建产物正常。

CI 失败应优先修复实际问题，不得通过删除必要检查规避失败。
