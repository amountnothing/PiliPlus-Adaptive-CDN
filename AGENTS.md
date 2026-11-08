# 项目执行约束

## 开工

1. 执行 `git status --short`，保留用户已有未提交改动。
2. 新会话首次接管时完整读一次 `docs/PROJECT_CONTEXT.md`（权威项目文档）和 `docs/PROJECT_STATUS.md`（当前状态）。
3. 架构与定位按需查 `docs/CODEBASE_REFERENCE.md`、`docs/SOURCE_FILE_INDEX.md`、`docs/SYMBOL_INDEX.md`；新环境初始化见 `docs/CLOUD_AGENT_HANDOFF.md`。
4. 读任务涉及的当前代码；文档与代码冲突时以代码和 Git 历史为准，先核实，不凭旧会话猜测。

大文件（约 200 行或 8KB 以上）先用 `grep`/`rg` 定位再按行范围读；日志、诊断 JSON 先用 `jq`/`python` 过滤出结论字段。

## 不可破坏的行为

- 不删除 Adaptive CDN Relay/拼接、网络暂停保护，以及音视频任一停滞时整体暂停的逻辑。
- 修复只动相关区域。
- 日志保持可复制：不记每帧、每秒或常规动画事件，只记异常、切换与恢复摘要。

## Git、CI 与发布

- 改动无合并冲突时可直接推送到 `main`；发生冲突时停止，由人决定如何解决及是否合并。
- 需要 CI 验证或 review 时可走 PR；PR CI（`pr-check.yml`）自动运行，无需逐次确认。
- 正式 Release 只在用户明确要求时手动触发。
- 细则见 `docs/CI_AND_SYNC.md`。

## 文档维护

- 改变长期行为、默认参数、构建位置或已确认基线时，同步更新 `docs/PROJECT_CONTEXT.md`。
- 当前状态、风险和下一步写在 `docs/PROJECT_STATUS.md`，状态变化时改写而不是追加；历史由 Git 保存。
