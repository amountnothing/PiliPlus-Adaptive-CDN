# 项目执行约束

每次开始任务前必须：

1. 完整读取 `docs/PROJECT_CONTEXT.md`。
2. 执行 `git status --short`，保留用户已有未提交改动。
3. 再读取任务涉及的当前代码；文档与代码冲突时先核实，不凭旧会话猜测。

长期边界：

- 项目和交付文件只放在 `PiliplusAdaptiveCDN` 内。
- 不删除 Adaptive CDN Relay/拼接、网络暂停保护或音视频任一停滞时整体暂停的逻辑。
- 修复只动相关区域；GitHub 同步、发布和编译仅在用户明确要求时执行。
- 日志模式保持可复制：禁止每帧、每秒或常规动画事件日志，只记录异常、切换与恢复摘要。
- `docs/PROJECT_CONTEXT.md` 是当前权威项目文档；外层 `PiliPlus-Adaptive-CDN-handoff.md` 仅是 2026-06-29 的历史迁移快照。
- 若任务改变长期行为、默认参数、构建位置或已确认基线，同步更新 `docs/PROJECT_CONTEXT.md`。
