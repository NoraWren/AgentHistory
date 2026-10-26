# 提案：本机 Agent 历史同步工具

## 为什么

本机的 Codex（ChatGPT 桌面端）、Claude Code、OpenCode、WorkBuddy 各存一份会话库，同一个项目的上下文被切成四块。实测 Codex 有 758 个会话，其中 633 个的 rollout 原件已经不存在，正文只留在 `thread_history_1.sqlite` 的投影里。历史既搜不到，也没有一份能带走的副本。

现在要做的，是一个能打开、选来源和目标、看预览、点同步、看进度条的本机工具。

## 变更内容

- 新增 macOS 14.0 以上的原生应用，三栏浏览、来源与项目筛选、全局搜索、菜单栏常驻和全局快捷键。
- 新增统一历史库 `~/.agent-history/history.db`，存放会话、轮次、条目、项目映射与同步水位，用 SQLite FTS5 做中文检索。
- 新增四个只读来源适配器：Codex、Claude Code、OpenCode、WorkBuddy。
- 适配器按实际安装情况启用，未安装的客户端不出现、不影响同步。
- 新增同步向导：选择来源与目标、预览将要写入的内容、执行、进度条、结果校验。
- 新增三种交付方式：目标支持导入时写原生格式，支持 MCP 时直读，其余交付交接包。OpenCode 走官方 `opencode import`；WorkBuddy 写会话文件；Codex 走交接包加 `codex exec`。
- 新增 stdio MCP 子命令，让各客户端里的 agent 能检索同一份历史并读写交接包。

## 能力

### 新增能力

- `history-index`：采集本机多个客户端的历史，归一化成统一索引并可检索。
- `history-transfer`：把选定来源的历史预览、导出并交付到目标客户端。
- `history-explorer`：原生 macOS 界面，承载浏览、搜索、预览和同步进度。

### 修改能力

无。项目当前没有任何既有规格。

## 影响

- 新增 Swift 源码与 macOS 应用包，最低系统版本 14.0。
- 只读访问 `~/.codex`、`~/.claude`、`~/.workbuddy`、`~/.local/share/opencode`。
- 写入集中在 `~/.agent-history`，目标客户端写入仅在用户确认后发生。
- 复用系统 SQLite 3.54（已确认启用 FTS5），不引入第三方依赖。
