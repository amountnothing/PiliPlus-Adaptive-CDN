# 云端 Agent 接管指南

本文用于把 PiliPlus Adaptive CDN 的日常开发、上游同步和发布工作迁移到云端 Agent。GitHub `main` 是唯一源码基准；不要复制本机的旧工作树、SDK 缓存或历史安装包作为新的源码来源。

## 1. 唯一源码入口

- 仓库：<https://github.com/amountnothing/PiliPlus-Adaptive-CDN>
- 默认分支：`main`
- 上游：<https://github.com/bggRGjQaUbCoE/PiliPlus>
- 当前上游 release 基线：`.github/upstream-release.txt`
- Flutter 版本：`.fvmrc` 和 `pubspec.yaml`，当前为 `3.47.1`
- Java：17（与 `.github/workflows/adaptive_release.yml` 一致）

首次接管按以下顺序读取：

1. `AGENTS.md`
2. `docs/PROJECT_CONTEXT.md`
3. `docs/CODEBASE_REFERENCE.md`
4. `docs/SOURCE_FILE_INDEX.md`
5. `docs/SYMBOL_INDEX.md`
6. 当前任务涉及的源代码、测试和 `git status --short`

文档记录产品约束和架构，当前代码与测试记录实现事实。发生冲突时先核实 Git 历史和调用链，不凭旧会话猜测。

## 2. 云端环境初始化

```bash
git clone https://github.com/amountnothing/PiliPlus-Adaptive-CDN.git
cd PiliPlus-Adaptive-CDN
git remote add upstream https://github.com/bggRGjQaUbCoE/PiliPlus.git
git fetch --all --tags
flutter --version
flutter pub get
```

环境至少需要 Flutter 3.47.1、Dart 3.13、JDK 17、Android SDK，以及 PowerShell 7（仓库维护和打包脚本是 `.ps1`）。本机的 `.tooling` 只是可重建缓存，不是项目依赖，不应上传。

Android 构建前沿用仓库脚本：

```bash
pwsh -File lib/scripts/patch.ps1 android
pwsh -File lib/scripts/build.ps1 android
flutter build apk --release --split-per-abi --dart-define-from-file=pili_release.json --pub
```

若只需要可安装的正式包，优先让 `.github/workflows/adaptive_release.yml` 在 GitHub 执行，避免在云端服务器复制长期签名私钥。

## 3. 最低验证

按改动范围运行；播放器或 Relay 变化至少覆盖相关 Dart 测试，扩展变化至少覆盖 Node 测试。

```bash
flutter analyze
flutter test
node --test browser-extension/test/core.test.cjs
```

扩展分发产物由以下脚本生成：

```bash
pwsh -File browser-extension/package.ps1
pwsh -File browser-extension/package-userscript.ps1
```

新增、删除或移动文件/符号后运行：

```bash
pwsh -File tool/generate_codebase_index.ps1
```

构建和测试成功只证明对应层；Android 播放、后台暂停、PiP、弱网、CDN 切换和浏览器 MSE 行为仍需真机或真实浏览器验证。

## 4. 上游同步与发布

- 定时同步和 Release 由 `.github/workflows/adaptive_release.yml` 管理。
- 自动任务先预检冲突；真实冲突会跳过定时合并，必须人工检查 Adaptive CDN、播放器、动画和扩展边界。
- 人工同步前先拉取 `upstream`，在独立分支处理并运行验证，通过后再合入 `main`。
- 不要在服务器长期保留第二份“永久合并工作树”；Git 分支和临时 worktree 足够。
- Release 资产应直接放在 GitHub Release，普通构建可使用 Actions artifact；APK/ZIP 不提交到源码历史。

GitHub Actions 使用以下 repository secrets。这里只记录名称，不记录值：

- `SIGN_KEYSTORE_BASE64`
- `KEYSTORE_PASSWORD`
- `KEY_ALIAS`
- `KEY_PASSWORD`
- `SIGN_CERT_SHA256`

这些值必须通过 GitHub Secrets 或服务器密钥管理器迁移，禁止写入仓库、日志、Agent 提示词或普通备份。

## 5. 本机重要目录与迁移决策

本机项目根目录为 `H:/kongbai/Documents/Codex/MiniProgramm/PiliplusAdaptiveCDN`。以下内容有用，但不应直接提交到 GitHub：

| 本机位置 | 内容 | 迁移方式 |
|---|---|---|
| `PiliPlus-Adaptive-CDN-repo/` | 唯一有效源码工作树 | 已由 GitHub `main` 承载 |
| `PiliPlus-Adaptive-CDN-repo/signing-private/` | Android 发布证书和凭据 | 私下加密备份；需要时导入密钥管理器，绝不提交 |
| `.tooling/` | Flutter、Android SDK 和构建缓存，约 9.4 GB | 云端按版本重新安装，不上传 |
| `builds/` | 当前本地 APK 交付物 | 可留作本地验收；长期交付转用 GitHub Release/Actions artifact |
| `PiliPlus-upstream-merge-worktree/` | 上游合并临时 worktree | 不迁移；内容已进入 Git 历史，云端按需临时创建 |
| `PiliPlus-main/` | 上游 PiliPlus 本地副本和缓存 | 不迁移；从 `upstream` 重新获取 |
| `pilipala-main/` | 早期参考项目快照 | 仅本地归档；不是当前源码依赖 |
| `adbToolKit/` | Windows 设备调试辅助工具 | 按云端是否连接 Android 设备决定，和项目源码分开管理 |
| `.codex-remote-attachments/` | 历史截图、日志等会话附件 | 可能含设备信息，不上传；只在具体问题需要时脱敏提供 |
| 外层历史 APK、ZIP、`.user.js` | 旧版本交付物 | 不迁移到 Git；最新版由源码和 Release 重新生成 |
| `PiliPlus-Adaptive-CDN-handoff.md` | 2026-06-29 的旧迁移快照 | 仅历史归档，不能作为当前参数或版本依据 |

本机 `.agents/` 和 `.codex/` 当前没有需要迁移的项目规则；有效规则已经进入根目录 `AGENTS.md` 和 `docs/`。

## 6. 交接完成判定

云端 Agent 能完成以下事项时，迁移才算完成：

1. 从全新 clone 读取上述文档并识别项目不变量。
2. 使用固定 Flutter/JDK 版本完成依赖安装、测试和 Android 构建。
3. 运行扩展测试并生成 ZIP 与油猴脚本。
4. 获取 `upstream` 并在临时分支预检合并。
5. 在不接触私钥明文的情况下触发 GitHub Actions Release。
6. 明确区分“构建通过”与“真机/浏览器行为已验证”。
