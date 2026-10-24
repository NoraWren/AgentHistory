# local-agent-history-sync

本机多客户端历史聚合、导出与同步的 macOS 原生工具

## 验证记录

- 2026-10-23：Codex → WorkBuddy 同步 50 个会话、13,220 条消息，写入
  `~/.workbuddy/projects/<slug>/<sid>.jsonl` 并在 `workbuddy.db` 的 `sessions`
  表登记。退出并重新启动 WorkBuddy 后，侧边栏「任务 (54)」里能看到这批会话，
  点开后正文、表格和链接都能正常渲染。重复同步时预览显示 50 条重复、0 条待写入。
