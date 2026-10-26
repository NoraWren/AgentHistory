# 记忆召回

## Why

库里的读写现在是单向的：交接包写进 `~/.agent-history/handoffs/` 之后，六个 MCP 工具都搜不到；主题汇编产物落在 `digests/` 下，agent 同样读不到；`handoffs` 表里那条记录也没有任何读回接口。结果是 agent 让系统「记住」一件事之后，下一次会话里问它，它答不出来——写进去的东西没有一条路能被检索到。今天那份汇编里就有「Nexus 升级是公司服务器的事，和开源项目没关系」这种明确结论，但它躺在磁盘上，谁也召不回。

现在补这一步的时机是：索引、血缘、检索、交接包、接入面板都已经上线，会话这一侧已经闭环；缺的只是「非会话文档」和「跨会话结论」两类内容进不进索引。再不补，agent 主动写下来的记忆就是一个只写不读的黑洞。

## What Changes

- 新增「记忆文档」索引：把交接包（`handoffs/*.md`）、主题汇编产物（`digests/*.md`）、结论条目统一收进一张独立的全文索引，与现有会话条目索引分开存放，互不干扰。
- 新增「结论条目」：从会话里记下决策、偏好、事实三类结论，每条带出处（会话 ID 加条目序号）、写入时间和写入方，可被新结论取代或在写错时作废。
- 结论的写入方是 agent 自己：做事过程中判断值得记住，就主动调用工具写入，不做定时批量提炼。
- MCP 工具新增五个，从六个扩到十一个：`remember`、`recall`、`forget`、`list_handoffs`、`get_handoff`。
- `search_threads` 增加检索范围参数，一次检索可以同时命中会话条目与记忆文档，结果里标明命中来自哪一类。
- 修正 `handoffs` 表里的语义混用：传输记录与交接包的状态标记分开，交接包不再是未被识别的 `draft` 残行。
- 界面上检索页增加范围切换，并给出一份可查看、可作废的结论清单。
- 修正接入检查的一个盲区：升级后装了新版、旧包还留在原地时，`mcp-repair` 不做任何事，客户端一直拿着旧版本的工具集，界面上却显示「已接入」。现在「路径失效」与「指向旧版本」都算待修，并支持只列清单不写入。

## Capabilities

### New Capabilities

- `memory-recall`: 非会话文档（交接包、汇编、结论）进索引后可被检索与按会话取回，以及结论条目的写入、取代、作废与出处追溯。

### Modified Capabilities

- `history-recall`: 检索范围从「仅会话条目」扩展到「会话条目与记忆文档」，结果需要标注命中类别。
- `history-transfer`: 交接包写入后必须可被检索、可被按会话与按标识取回，状态标记与传输记录区分开。
- `mcp-onboarding`: 修复动作的判定从「文件是否存在」扩展到「是否指向当前程序」，并支持只列待修清单。

## Impact

- 数据：只新增表（`memory_docs`、`memory_docs_fts`、`memory_facts`），不改动 `threads` / `items` / `search_docs` 的既有结构与内容；`handoffs` 表只做状态取值收敛，不删行。
- 代码：`Sources/Core/MCP.swift` 新增工具定义与调用分支；`Sources/Core/Search.swift` 增加记忆文档检索通道；`Sources/Core/Store.swift` 只在 `migrate()` 里追加建表与索引；`Sources/Core/Transfer.swift` 与 `Sources/Core/Digest.swift` 的产物写入点补一次索引登记。
- 界面：`Sources/UI/RootView.swift` 检索页增加范围切换，新增结论清单视图。
- 兼容：现有六个工具的入参与输出保持不变，`search_threads` 新增参数有默认值，旧调用方行为不变。
