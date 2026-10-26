# 提案：MCP 接入面板

## 为什么

README 已经用一整节写清六个客户端各自怎么接 MCP，本机仍然只接上了四个：Codex、WorkBuddy、Kimi Code、DeepSeek Harness 可用，Claude Code 与 OpenCode 未接。文档写得对，用户照样会漏，因为写错的方式都不报错——WorkBuddy 少一个 `"disabled": false` 配置存在但永不启动，Claude Code 写到错误的项目层级完全不生效，应用挪了位置六份配置一起指向失效路径，症状只是「本来好好的，突然不记得了」。写进去和真能用是两件事，缺的是验证，不是更多说明。

记忆能力能发挥多大作用，取决于有多少客户端在读它。现在四接二未，「换个客户端它就不知道」只解决了一半，所以先把这个前提补齐。

## 改什么

- 新增「接入」面板，按客户端逐行列出：是否已配置、握手是否通过、可见工具数、配置路径。
- 新增握手检查：直接拉起一次 `AgentHistory mcp` 子进程，走 `initialize` 与 `tools/list`，确认返回的工具集合完整。这一步只读，不写任何客户端文件。
- 新增「接入」与「移除」动作。有官方 CLI 的用 CLI（`claude mcp add`、`opencode mcp add`），没有的才写配置文件；写前给差异预览并备份，只增删 `agent-history` 这一条。
- 新增失效路径修复：检测到配置指向的可执行文件不存在时，一键改写成当前路径。
- 新增配置片段复制，给未支持的客户端手工粘贴。
- DeepSeek Harness 的接入方式是安装插件，面板如实区分「插件已装」与「配置已写」，不把它伪装成一次文件写入。
- 不新增自动弹窗催促；状态挂在面板与菜单栏，只有检查失败时才提示一句。

## 能力

### 新增能力

- `mcp-onboarding`：把本机各 Agent 客户端的 MCP 接入做成可检查、可执行、可修复的一件事，包含配置状态识别、握手验证、接入与移除、失效路径修复和配置片段导出。

### 修改能力

无。既有七项能力的行为不变，接入面板是并行新增的入口。

## 影响

- 界面：新增接入面板；`Sources/UI/AppMain.swift` 的菜单栏状态需要展示接入检查结果。
- 新增模块：客户端注册表的识别与写入、握手检查，建议落在 `Sources/Core/`。
- 命令行：新增 `AgentHistory mcp-status` 与 `AgentHistory mcp-connect <客户端>`，便于脚本与排查，也是面板的后端。
- 会被读写的用户文件：`~/.codex/config.toml`、`~/.workbuddy/connectors/default/mcp.json`、`~/.kimi-code/mcp.json`、`~/.claude.json`、`~/.config/opencode/opencode.json`。全部走「预览 + 备份 + 只改本服务一条」。
- 不触碰会话历史与来源库，也不改动 `history.db` 结构。
