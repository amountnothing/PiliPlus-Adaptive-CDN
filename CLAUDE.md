@AGENTS.md

# Claude Code 专用约定

## 子代理分工

- 搜索代码、读日志、批量整理文件等简单任务，交给 `quick-search` 子代理（Haiku，定义在 `.claude/agents/quick-search.md`）。
- 架构设计和复杂调试留在主对话。
