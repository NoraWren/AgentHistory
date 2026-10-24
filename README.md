# Agent 记忆

AgentHistory collects the session history of local AI coding clients into one searchable library, and hands a selected session over to another client. Source files are opened read-only; every write happens after an explicit confirmation and a backup.

把本机 Codex、Claude Code、WorkBuddy、OpenCode、Kimi Code、DeepSeek Harness 的会话历史收进一个可检索的库，把选中的会话交给另一个客户端继续用。数据只从各客户端读取，写入动作都要你在界面上按一次“开始同步”。

## 双击打开

应用在 `~/Applications/AgentHistory.app`，双击图标就能用。第一次打开如果系统拦了一下，右键选“打开”即可，之后正常双击。

重新构建后，把 `dist/AgentHistory.app` 拖到 `~/Applications` 覆盖旧版本就行。旧版本可以先挪到一边，确认新版正常再删。

## 界面怎么用

主窗口分三栏。左栏是来源和项目：全部来源、Codex、Claude Code、OpenCode、WorkBuddy、Kimi Code、DeepSeek Harness，下面是按工作目录聚合的项目，点一下只看这个项目的会话。中间是会话列表，按最近活动排序，每条显示标题、来源和项目。右栏是详情，按轮次展开，推理和工具调用默认折叠，长会话首屏 200 条、往下滚动继续加载。
顶部的搜索框支持中文检索，“止损线”这种词能直接命中正文。菜单栏有常驻图标，显示今天的会话数和最近几条；在其他应用前台时按 ⌥⌘H 也能唤起窗口并聚焦搜索框。

## 同步向导

工具栏点“同步”，按三步走：

1. 选来源和目标。来源和目标是同一个客户端时，向导会提示改用 MCP 直读。
2. 点“预览”。这一步只读，不写任何文件，会列出会话数、消息数、重复数、脱敏条数、预计写入体积和目标路径。重复数表示目标里已经同步过、这次会跳过的会话。
3. 点“开始同步”。进度条按读取、归一化、遮蔽、写入、校验五段推进，结束后给出成功、跳过、失败的数量和写入位置。

默认带这个来源的全部会话，不做时间筛选。要只带某一个会话，用命令行的 `transfer` 并带上会话 ID。

## 同步到各客户端

| 目标 | 方式 | 需要知道的事 |
| --- | --- | --- |
| WorkBuddy | 原生导入 | 同步前必须先退出 WorkBuddy。会话文件写到 `~/.workbuddy/projects/<项目 slug>/`，同时登记到 `workbuddy.db` 的 `sessions` 表。同步后重新打开 WorkBuddy，侧边栏“任务”里能看到。 |
| OpenCode | 原生导入 | 调用官方 `opencode import`，导入后会查目标库确认。 |
| Claude Code | 原生导入（实验） | 写到 `~/.claude/projects/` 下的 JSONL。能不能出现在 `claude --resume` 列表里取决于版本，第一次用完请自己确认。 |
| Codex | 交接包 | Codex 不接受外部伪造的 rollout。这里生成 Markdown 交接包放在 `~/.agent-history/handoffs/`，并给出 `codex exec "读取 … 并接着做"` 的命令。 |
| Kimi Code | 原生导入 | 写入 `~/.kimi-code/sessions/<工作区ID>/<会话ID>/`，包含 `state.json` 和 `agents/main/wire.jsonl`。Kimi Code 启动时扫描这个目录，写完重启客户端，侧边栏就能看到会话。 |
| DeepSeek Harness | 原生导入 | 写入 `~/.dsh/sessions/<项目目录>/<会话ID>/session.v4.jsonl.zstd`：会话头 v4、事件序号连续、标题放最后并带来源。重启 DSH 后侧边栏可见。 |

同步过的会话会记在 `handoffs` 表里，重复执行时自动跳过，不会在目标端堆出重复会话。

## 命令行

不打开界面也能用，适合脚本和排查。

```bash
AgentHistory                              # 打开界面
AgentHistory sync                         # 同步全部可用来源
AgentHistory stats                        # 会话数、条目数、库体积、各来源状态
AgentHistory search 止损线                 # 中文检索
AgentHistory plan codex workbuddy         # 只看预览，不写文件
AgentHistory transfer codex workbuddy     # 执行同步
AgentHistory transfer codex workbuddy <会话ID>   # 只同步一条
AgentHistory verify                       # 适配器契约检查
AgentHistory repair-workbuddy             # 把已写入的会话补登记到 WorkBuddy 的会话表
AgentHistory items <会话ID> [序号]         # 查看某个会话的条目
AgentHistory mcp                          # 以 stdio MCP 服务运行
```

应用包里的可执行文件路径是 `~/Applications/AgentHistory.app/Contents/MacOS/AgentHistory`，在终端里可以直接带参数运行。

## 数据位置

- 统一库：`~/.agent-history/history.db`
- 交接包：`~/.agent-history/handoffs/`
- 写入前备份：`~/.agent-history/backups/`
- OpenCode 导入的临时文件：`~/.agent-history/outbox/`

来源库只读打开，同步不会改动 Codex、Claude Code、OpenCode、WorkBuddy、Kimi Code、DeepSeek Harness 的原始历史。写入目标客户端前会把相关文件或数据库复制一份到 `backups`，带时间戳。

Kimi Code 的会话放在 `~/.kimi-code/sessions/<工作区ID>/<会话ID>/`，`state.json` 存标题、项目路径和时间，正文在 `agents/main/wire.jsonl`，按行追加。适配器按文件偏移增量读取，只收录 `context.append_message` 里的用户消息、助手回复、推理和工具调用。

DeepSeek Harness 的会话放在 `~/.dsh/sessions/<项目目录>/<会话ID>/session.v4.jsonl.zstd`，旧版本目录 `~/Library/Application Support/dsh-desktop/harness/sessions` 也会一起扫描。它是 zstd 压缩的 JSONL，第一行是 `session` 头，后面按 `seq` 追加事件；标题来自 `session/title`，用户消息只认 `source.kind == "user"`，插件注入和技能目录会被跳过。读取需要本机有 `zstd` 命令，Homebrew 安装的默认路径会被自动找到。写入时按 DSH 的格式要求做：会话头单独一帧、正文一帧，事件 `seq` 从 0 连续递增，用户和助手消息带 `surfaceOp: append`，标题事件放在最后并用 `messageSeqs` 指向更早的用户消息；同时把会话 ID 登记到 `storages/workspace.json`。

删掉 `~/.agent-history` 不会丢原始历史，下次启动会重新全量扫描，代价是重新跑一遍索引。

## 接入 MCP

`AgentHistory mcp` 是一个 stdio 服务，对外提供四个工具：`search_threads`、`get_thread_context`、`list_projects`、`append_handoff`。好处是目标客户端不用导入文件，agent 直接就能查到同一份历史。

Codex 的注册写在 `~/.codex/config.toml`：

```toml
[mcp_servers.agent-history]
command = "/Users/kongqi/Applications/AgentHistory.app/Contents/MacOS/AgentHistory"
args = ["mcp"]
```

WorkBuddy 的注册写在 `~/.workbuddy/connectors/default/mcp.json` 的 `mcpServers` 里，键名 `agent-history`，同样是 command 加 `["mcp"]`。改完重启客户端，新开一个会话就能用。

Kimi Code 也支持 MCP。把 `{"mcpServers": {"agent-history": {"command": "…/AgentHistory", "args": ["mcp"]}}}` 写进 `~/.kimi-code/mcp.json`，重启后新开会话就能让 Kimi 检索全部历史。同步向导里的 Kimi Code 目标是写会话目录，不会改动这个文件。

DeepSeek Harness 也有 MCP 客户端，但只能通过插件安装。仓库里的 `dsh-plugin` 是一个本地插件包，把它安装到 Harness 后会在对话里注册 `search_threads` 等工具。已经装好的副本在 `~/.agent-history/dsh-plugin`，profile 里登记为 `@local/agent-history-mcp`。

## 从源码打开和构建

工程根目录有 `Package.swift`，可以直接用 Xcode 打开：

```bash
open -a Xcode Package.swift
```

选 `AgentHistory` scheme 按 ⌘R 运行，或者终端里 `swift run AgentHistory`。

要生成可双击的应用包用脚本：

```bash
bash scripts/build.sh
```

脚本会先编译并跑测试，再编译应用，最后组装 `dist/AgentHistory.app` 并做 ad-hoc 签名。最低系统版本 macOS 14.0。

应用图标在 `Resources/AgentHistory.icns`，源图是 `Resources/AppIcon-1024.png`。改图标就跑 `python3 Resources/make_icon.py` 重新生成源图，再按 `iconutil` 打出 icns 并重新构建。

源码分布：

- `Sources/main.swift`：入口，无参数时进界面，其余是命令行子命令
- `Sources/UI/AppMain.swift`：应用代理、窗口、菜单栏和全局快捷键
- `Sources/UI/RootView.swift`：三栏主界面
- `Sources/UI/SyncWizardView.swift`：同步向导
- `Sources/Core/Adapters.swift`：六个来源的读取适配器
- `Sources/Core/Transfer.swift`：同步计划、写入器和回滚
- `Sources/Core/Store.swift`：统一库的表结构和检索
- `Sources/Core/MCP.swift`：stdio MCP 服务

## 常见问题

**同步完了 WorkBuddy 里没看到。** 先确认同步时 WorkBuddy 是退出的。同步只写文件和数据库，WorkBuddy 在启动时读一次列表，所以写完要重新打开。重启后仍然没有，执行 `AgentHistory repair-workbuddy`，它会把已经写好的会话文件补登记到 `sessions` 表，然后再启动一次。

**提示先退出 WorkBuddy。** 这是故意的。WorkBuddy 运行时会对自己的数据库加锁，边跑边写容易让它覆盖掉新记录。

**重复同步会不会导两遍。** 不会。已同步过的会话在预览里算进“重复”，执行时跳过。

**搜索不到某个词。** 中文按字切分检索，先试试更短的关键词，比如“止损”而不是整句。确认 `AgentHistory stats` 里对应来源是“可用”，不可用时旁边会写原因。

**某个来源不出现。** 没安装或还没有会话的客户端不会出现在列表里。装了但目录不同，检查 `~/.codex`、`~/.claude`、`~/.workbuddy`、`~/.local/share/opencode`、`~/.kimi-code/sessions`、`~/Library/Application Support/dsh-desktop/harness/sessions` 是否存在。

**同步到 Claude Code 后找不到会话。** 这条路径是实验性的。Claude Code 的会话列表由它自己维护，外部写的 JSONL 不保证被识别。失败时改用 MCP 直读或交接包。

## 验证记录

2026-10-23 在只装 Codex 和 WorkBuddy 的环境里跑了一遍完整流程：Codex 同步 50 个会话、13,220 条消息到 WorkBuddy，写入 12.4 MB，重复执行时预览显示 50 条重复、0 条待写入。重启 WorkBuddy 后侧边栏“任务 (54)”里能看到这批会话，点开正文、表格和文档链接都能正常渲染。`swift build` 和 `bash scripts/build.sh` 均通过。

2026-10-24 增加 Kimi Code 来源和原生导入。适配器测试覆盖解析、增量与检索；写入器把一条 WorkBuddy 会话导进 `~/.kimi-code/sessions/`，重启 Kimi Code 后侧边栏出现“你好”，点开能看到两轮完整对话。来源和目标的归拢都在这台机器上实测过。

2026-10-24 增加 DeepSeek Harness 来源。用构造的会话文件验证了真实用户消息筛选、标题、项目路径、推理与工具调用，以及 zstd 压缩文件的读取和去重；本机 6 段 Harness 会话已纳入统一库（桌面版 2 段、`~/.dsh` 4 段）。另外给 Harness 装了 MCP 插件，在对话里调用 `search_threads` 搜「止损线」返回了 5 条命中标题；重启后插件仍会自动拉起。原生导入也跑通了：把一条 271 条消息的 Claude Code 会话写进 `~/.dsh/sessions`，重启 DSH 后侧边栏出现「config.yaml 中文文档设置」，点开两轮内容都正常。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。只依赖系统框架与 libsqlite3，没有第三方库。
