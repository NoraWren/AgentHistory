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

## 副本合并与血缘

把会话交给别的客户端继续用之后，两边的历史库里都会留下一份内容。AgentHistory 按内容把重复会话归进同一个「内容族」：同步过的（能在 `handoffs` 表里对上的）标记为同步记录，其他按「标题 + 项目 + 条目数 + 总字数」四项相等推断。每个族选最早创建的会话当代表，会话列表默认只显示代表，副本收进「另有 N 处副本」标注里，点开能跳到对应会话。

合并开关在会话列表顶部，默认开，状态栏会同时显示合并前后两个会话数。第一次升级到这个版本后跑一次 `AgentHistory rebuild-lineage` 建立血缘表，之后每次同步增量维护。本机 2,302 个会话重建出 759 个族、折叠 1,502 份副本，耗时 0.4 秒。

## 主题汇编

找得到之外还得看得完。库里有二十一万条记录，一周下来光 Codex 就上千轮对话，写周报、写复盘时真正想要的是「这周做了什么」。工具栏点「汇编」（或按 ⌘D），选时间范围和要覆盖的来源、项目，点「生成汇编」，系统会先按天把每轮的提问和答复整理成材料，再交给本机模型压成结论，最后写成一份带日期分节的 Markdown。

结果不搬原文，分「这周做了什么」「关键结论」「数字与单号」「未决事项」这类小节。生成完可以复制全文、在访达中显示或直接打开文件，产物默认落在 `~/.agent-history/digests/`，文件名带日期、标题和覆盖范围。

提炼有两条通路，任选一条就能用。第一条是模型命令行：打开面板时按 `claude` → `codex` → `gemini` → `ollama` → `llm` 的顺序探测本机装了什么，取第一个可用的填进输入框，命令也能自己改，提示词走标准输入、正文从标准输出读回，任何命令行工具都能接。第二条是 OpenAI 兼容接口：填上地址（到 `/v1`）和模型名就行，不需要装任何命令行工具，密钥留空会依次读 `AGENT_HISTORY_LLM_API_KEY`、`OPENAI_API_KEY`。两条都填了走接口。都空着时面板上会直接写「没有可用的模型通路」并给出两种填法，不会留一个跑不起来的按钮。取消勾选「接模型提炼」就只出按天摘要。

探测是在登录 shell 里跑的 `command -v`，从访达启动也认得到用户自己装的 Node 全局命令。探测结果在进程内缓存，装完新工具重启应用即可，面板上的「探测本机」按钮会重新扫一遍。

探测出来的命令只在当前这次用，不写进配置。写进去就等于把「这台机器装了什么」存成了固定值，换台电脑会拿着一条不存在的命令去跑；自己手改过的命令才保存。旧版本存下来的预设命令启动时会自动清掉。

地址、模型名、密钥都是改一个字就存，不用等到点「生成汇编」，下次打开自动带出来。地址和模型名在应用的偏好设置里；密钥单独放在 `~/.agent-history/llm.json`，权限 0600。偏好目录下那个 plist 是明文，密钥不该躺在那里，旧版本写进去的会在启动时搬过来并删掉。`AgentHistory models` 会把已存的地址、模型名和密钥是否设置一起列出来。

换一台电脑不用改代码。没装 Claude Code 的机器上，装个 Codex 或 Gemini CLI 就直接走命令；什么都没装的，填接口地址也能出汇编。这两条路径在真实库上都验过：把 `PATH` 缩到系统目录、模拟一台干净的 Mac，命令行空着时提示「没有可用的模型通路：填一个接口地址和模型名，或者写一条命令行」，填上接口后照样跑出 4 次调用、两周范围的汇编。

`--no-session-persistence` 是必须的。不加的时候每次调用都会在 `~/.claude/projects` 留一份会话，同步时会被当成真实对话收进库，甚至被下一次汇编当成素材喂回自己。升级前遗留的这类假会话用 `AgentHistory digest-clean` 清掉，它只认工作目录在汇编临时目录下的会话。

加了 `--no-session-persistence` 也不是完全没有痕迹：每次调用仍会在 `~/.claude/projects` 建一个对应工作目录的项目文件夹，里面只有一个空的 `memory`。跑一天的汇编能留下十几个空壳。`digest-clean` 会顺带扫这个目录，只删「一个 jsonl 都没有、里面也没有任何文件」的项目文件夹，有会话的项目一个不碰，再扫一次什么都不动。

汇编每次提炼还会在 `~/.agent-history/digests/work/` 留一份 `prompt.md`，里面是那一段对话材料的副本。成品已经落到 `digests` 了，这些中间件没有保留价值，`digest-clean` 一并收掉，下次汇编按需重建。本机第一次清出 15 个目录、453 KB。

汇编按天分段，每天一次提炼，天数多的时候并发跑；某天的材料超过单次上限就在天内再拆段，按轮次边界切，不会丢掉最早的轮次。模型跑不通时逐级降级到按天摘要并在结果里说明原因，不会只留一个空白面板。总耗时主要取决于模型排队：本机七天汇编 15 次调用实测 463 秒，面板上写的是「通常要几十秒」，不会假装有进度。

提炼结果按段缓存在 `~/.agent-history/digests/cache/`，默认开着。缓存键是那一段材料正文加通路标识的指纹，材料一个字没变就直接读回上次的结果，连最后那次合并也吃同一套缓存：第二次跑同样的窗口是一次模型都不调的。换了命令行或换了接口/模型，指纹里带的通路变了，旧结果不会被拿来充数。不确定结果是否过时时用 `--no-cache` 强跑一遍；`digest-clean` 会把缓存一起清掉。缓存最多留 600 份，每轮跑完顺手按修改时间收拾，改过的会话对不上旧指纹，不会把目录撑大。指纹用的是自己算的 FNV-1a，不能用 `String.hashValue`，那个每个进程都不一样，落盘第二天就全失效。

面板上把命令那一行清空、接口也没填的时候，不会偷偷拿开机时探测到的命令去跑，而是照实提示「没有可用的模型通路」。探测出来的命令只当这次用，自己手写的那条才存下来。

同步仍然由你手动点「同步」，没有加定时。自动同步意味着后台随时读写四百兆的库，也和「写入动作都要你按一次」的约定冲突。

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
AgentHistory rebuild-lineage              # 重建会话血缘，把同步产生的副本归进内容族
AgentHistory lineage <会话ID>             # 查看某会话的双向血缘（原创与副本）
AgentHistory search 止损线 --days 7 --asked --source codex  # 带筛选的会话级检索
AgentHistory search 表格 --all            # 关闭副本合并，命中副本也单独返回
AgentHistory export <会话ID> --out 目录    # 把会话导出成 Markdown
AgentHistory digest --days 7 --title 本周   # 把最近七天汇编成结论（命令自动探测）
AgentHistory digest --days 7 --no-llm      # 只出按天摘要，不调外部模型
AgentHistory digest --days 7 --no-cache    # 不读提炼缓存，强制重跑
AgentHistory digest --days 7 --api https://api.openai.com/v1 gpt-4o-mini   # 改用接口，不依赖任何命令行
AgentHistory models                        # 看本机探测到哪些模型命令行、密钥环境变量是否设置
AgentHistory digest-clean                  # 清掉汇编留下的临时会话和空项目目录
AgentHistory mcp                          # 以 stdio MCP 服务运行
AgentHistory mcp-status                   # 六个客户端谁接上了、握手拿不拿得到工具
AgentHistory mcp-status --json            # 同上，给脚本解析
AgentHistory mcp-connect claude           # 接入某个客户端，--dry-run 只看改动
AgentHistory mcp-disconnect claude        # 移除本服务的登记
AgentHistory mcp-repair                   # 应用挪了位置，把失效路径一次改回来
AgentHistory mcp-snippet codex            # 打出可粘贴的配置片段
```

`search` 是会话级聚合：同一内容族的多份副本只返回代表会话，结果里标注族内命中数和「另有 N 处副本」。短语命中排在前，单字宽命中补在后。检索命中后用 `items <会话ID> @序号` 能直接跳到那条记录，不用从头翻页。

`export` 每次导出都会生成带序号的独立文件，不会覆盖旧的；批量导出时附带 `index.md` 清单，文件头写明来源、项目、时间范围、记录数和脱敏条数，工具输出折叠成引用块。

应用包里的可执行文件路径是 `~/Applications/AgentHistory.app/Contents/MacOS/AgentHistory`，在终端里可以直接带参数运行。

## 数据位置

- 统一库：`~/.agent-history/history.db`
- 交接包：`~/.agent-history/handoffs/`
- 汇编产物：`~/.agent-history/digests/`（临时材料在 `digests/work/`）
- 写入前备份：`~/.agent-history/backups/`
- OpenCode 导入的临时文件：`~/.agent-history/outbox/`

来源库只读打开，同步不会改动 Codex、Claude Code、OpenCode、WorkBuddy、Kimi Code、DeepSeek Harness 的原始历史。写入目标客户端前会把相关文件或数据库复制一份到 `backups`，带时间戳。

Kimi Code 的会话放在 `~/.kimi-code/sessions/<工作区ID>/<会话ID>/`，`state.json` 存标题、项目路径和时间，正文在 `agents/main/wire.jsonl`，按行追加。适配器按文件偏移增量读取，只收录 `context.append_message` 里的用户消息、助手回复、推理和工具调用。

DeepSeek Harness 的会话放在 `~/.dsh/sessions/<项目目录>/<会话ID>/session.v4.jsonl.zstd`，旧版本目录 `~/Library/Application Support/dsh-desktop/harness/sessions` 也会一起扫描。它是 zstd 压缩的 JSONL，第一行是 `session` 头，后面按 `seq` 追加事件；标题来自 `session/title`，用户消息只认 `source.kind == "user"`，插件注入和技能目录会被跳过。读取需要本机有 `zstd` 命令，Homebrew 安装的默认路径会被自动找到。写入时按 DSH 的格式要求做：会话头单独一帧、正文一帧，事件 `seq` 从 0 连续递增，用户和助手消息带 `surfaceOp: append`，标题事件放在最后并用 `messageSeqs` 指向更早的用户消息；同时把会话 ID 登记到 `storages/workspace.json`。

删掉 `~/.agent-history` 不会丢原始历史，下次启动会重新全量扫描，代价是重新跑一遍索引。

## 接入 MCP

`AgentHistory mcp` 是一个 stdio 服务，对外提供六个工具：`search_threads`、`get_thread_context`、`stats`、`list_projects`、`list_sources`、`append_handoff`。好处是目标客户端不用导入文件，agent 直接就能查到同一份历史。

`search_threads` 的 `days` 按自然天数向前取，`get_thread_context` 默认给会话结尾（接续时最需要的是最后几轮），要开头用 `scope=head`，要完整顺下来用 `scope=all`。`list_sources` 会说明每个来源上次同步过去多久、是否已过期，agent 拿到旧结果时能自己判断。

参数都夹了范围。`limit` 落在 1 到 200 之间，`max_chars` 落在 500 到 80,000 之间，检索结果整体按一万六千字封顶，超出的只报「只列了前 N 条」。早先 `limit=-5` 会直接在 `prefix` 上触发运行时陷阱，把整个 MCP 进程带走；客户端传个笔误参数，服务就没了。现在一次错参数只是少给几条结果，说明里会写清楚为什么少。

写错值的参数一律报错，不再悄悄退回默认。`source` 只认那六个值，传 `codex-cli` 会直接回「只认这些值」；`days` 传 0 或负数会回「要是正整数，不想按时间筛就别传这个参数」；`query` 是空的也是错，不是「没有命中」。这类参数早先是静默忽略的，结果照样有，但筛没筛、筛了几天全对不上，比报错难查得多。`limit`、`max_chars` 这种只是给多了的，照旧夹住，再在表头说明按多少算。

`list_projects` 会分页。本机 281 个项目拼成文本有两万六千字，一次全返回比一条检索还占上下文，现在默认一页五十个、整体按一万六千字封顶，表头写「只列了第 51 到 100 个，接着看用 offset=100」。项目多的时候先用 `query` 按名字或路径筛，比翻页快。`stats` 里能先看到项目总数。

服务启动时先补一次增量，之后每次工具调用前看水位：哪个来源落后就补哪个，不因为某个来源刚同步过就整体跳过。同一个来源补同步失败后先晾十分钟再试，几个客户端各起一个 MCP 进程也不会同时去撞同一个打不开的目录。`AGENT_HISTORY_MCP_SYNC=0` 可以整个关掉自动补。

Codex 的注册写在 `~/.codex/config.toml`：

```toml
[mcp_servers.agent-history]
command = "/Users/kongqi/Applications/AgentHistory.app/Contents/MacOS/AgentHistory"
args = ["mcp"]
```

WorkBuddy 的注册写在 `~/.workbuddy/connectors/default/mcp.json` 的 `mcpServers` 里，键名 `agent-history`，同样是 command 加 `["mcp"]`。改完重启客户端，新开一个会话就能用。

Kimi Code 也支持 MCP。把 `{"mcpServers": {"agent-history": {"command": "…/AgentHistory", "args": ["mcp"]}}}` 写进 `~/.kimi-code/mcp.json`，重启后新开会话就能让 Kimi 检索全部历史。同步向导里的 Kimi Code 目标是写会话目录，不会改动这个文件。

DeepSeek Harness 也有 MCP 客户端，但只能通过插件安装。仓库里的 `dsh-plugin` 是一个本地插件包，把它安装到 Harness 后会在对话里注册 `search_threads` 等工具。已经装好的副本在 `~/.agent-history/dsh-plugin`，profile 里登记为 `@local/agent-history-mcp`。

### 接入面板

工具栏点「MCP 接入」，六个客户端一行一个：谁已接入、谁没配、谁装了但没接、谁配了却连不上。判断不只看配置文件里有没有这一条，而是真的拉起一次 `AgentHistory mcp`，发 `initialize` 和 `tools/list`，握手通过才算已接入，同时显示拿回来几个工具。配置文件里写着、可执行文件却已经不在了，会单独标成路径失效并给「修好路径」，不会显示成已接入。

每行的「接入」「移除」都先弹差异预览，红色是要删的行、绿色是要加的行；这一步只预览，取消后原文件一个字节都不动，也不留备份。确认之后先备份到 `~/.agent-history/backups/`，再只改本服务这一条登记，同一个文件里别的服务配置逐字节保持原样。WorkBuddy 那份 `mcp.json` 有近百条别的登记，动错一条就会连带坏掉一片。

Claude Code 和 OpenCode 有官方登记命令，走 `claude mcp add/remove` 和 `opencode mcp add`，不直接碰它们的配置文件；命令返回非零就把退出码和输出原样报出来，也不会偷偷改成手改文件。DeepSeek Harness 只能装插件，标成插件式并单独说插件装没装。

未接入是常态，启动和同步都不弹窗。只有「已经接上了、这次握手却失败」才在菜单栏多一行橙色提示，修好之后自己消失。菜单栏平时写「MCP 6/6 个客户端能调用本服务」，扫一眼就知道有没有掉线。

命令行也能查：`mcp-status` 逐行报状态，全可用时退出码 0；`mcp-connect` 和 `mcp-disconnect` 对应面板上的两个动作，`mcp-repair` 修失效路径，`mcp-snippet` 打出片段。写文件之前都支持 `--dry-run`。

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

应用图标在 `Resources/AgentHistory.icns`，源图是 `Resources/AppIcon-1024.png`，和侧栏左上角是同一副：Theme.accent 渐变底 + 白色 brain.head.profile。改图标跑 `python3 Resources/make_icon.py` 一键重生成源图和全套 icns，再重新构建即可。

源码分布：

- `Sources/main.swift`：入口，无参数时进界面，其余是命令行子命令
- `Sources/UI/AppMain.swift`：应用代理、窗口、菜单栏和全局快捷键
- `Sources/UI/RootView.swift`：三栏主界面
- `Sources/UI/SyncWizardView.swift`：同步向导
- `Sources/Core/Adapters.swift`：六个来源的读取适配器
- `Sources/Core/Transfer.swift`：同步计划、写入器和回滚
- `Sources/Core/Store.swift`：统一库的表结构和检索
- `Sources/Core/MCP.swift`：stdio MCP 服务
- `Sources/Core/Digest.swift`：主题汇编的取数、分段、模型调用与降级
- `Sources/Core/LLM.swift`：提炼通路的探测、接口调用与命令调用
- `Sources/UI/DigestView.swift`：主题汇编面板
- `Sources/Core/Onboarding.swift`：六个客户端的登记位置、握手检查与状态判定
- `Sources/Core/OnboardingWriter.swift`：只改本服务一条的 JSON 与 TOML 写入、备份和回滚
- `Sources/UI/MCPOnboardingView.swift`：接入面板、差异预览与片段弹窗

## 常见问题

**同步完了 WorkBuddy 里没看到。** 先确认同步时 WorkBuddy 是退出的。同步只写文件和数据库，WorkBuddy 在启动时读一次列表，所以写完要重新打开。重启后仍然没有，执行 `AgentHistory repair-workbuddy`，它会把已经写好的会话文件补登记到 `sessions` 表，然后再启动一次。

**提示先退出 WorkBuddy。** 这是故意的。WorkBuddy 运行时会对自己的数据库加锁，边跑边写容易让它覆盖掉新记录。

**重复同步会不会导两遍。** 不会。已同步过的会话在预览里算进“重复”，执行时跳过。

**搜索不到某个词。** 中文按字切分检索，先试试更短的关键词，比如“止损”而不是整句。确认 `AgentHistory stats` 里对应来源是“可用”，不可用时旁边会写原因。

**某个来源不出现。** 没安装或还没有会话的客户端不会出现在列表里。装了但目录不同，检查 `~/.codex`、`~/.claude`、`~/.workbuddy`、`~/.local/share/opencode`、`~/.kimi-code/sessions`、`~/Library/Application Support/dsh-desktop/harness/sessions` 是否存在。

**同步到 Claude Code 后找不到会话。** 这条路径是实验性的。Claude Code 的会话列表由它自己维护，外部写的 JSONL 不保证被识别。失败时改用 MCP 直读或交接包。

## 验证记录

2026-10-26 MCP 接入面板。以前接 MCP 要挨个翻文档改配置文件，六个客户端六个位置、三种写法，Claude Code 还有顶层和按项目两层登记，配错了只有等 agent 调不通才发现，而那已经是另一个会话里的事了。现在工具栏「MCP 接入」一屏看完：本机六个客户端 6/6 可用，五行握手各拿到 6 个工具，DeepSeek Harness 显示插件已装。`mcp-status` 同样六行、退出码 0，`--json` 的字段能被 `json.load` 直接读。

写入这块花的力气最多，因为同一个文件里躺着别人家的配置。WorkBuddy 的 `mcp.json` 有 99 条别的登记，测试里 40 条旁证逐字节比对，接入再移除后和原文完全一致；Codex 那边 TOML 的注释、别的 `[mcp_servers.*]` 段也一字不动。中途发现 `JSONSerialization` 会放过尾逗号（`{"a": 1,}` 返回 true），照旧校验等于没校验，带尾逗号做文本手术会切错位置，于是换成手写的递归下降校验，逗号后直接闭合就拒。并发也守住了：写入前后比对修改时间和大小，中间被别的工具插一手就回滚并提示重试，测试用写入钩子在备份之后、落盘之前精确插一刀，确认没覆盖别人写的内容、也没丢备份。顺带修了测试自身的毛病：早先只隔离 `ONBOARD_HOME`，假备份其实写进了真实的 `~/.agent-history/backups/`，现在两个环境变量都隔离。

界面在真机上过了一遍：六行状态、差异预览的增删标色、片段弹窗都正常；对 WorkBuddy 点「移除」看到整段红色删除预览后取消，配置文件 SHA 不变，备份目录也没多出东西。`bash scripts/build.sh` 352 项通过、0 失败。


2026-10-26 备份目录自动收拾，会话列表能翻到底。`~/.agent-history/backups` 只增不减，本机涨到 811 MB，比 388 MB 的口袋库还大，每一份都是传输前 VACUUM 出来的整库副本。现在 `AgentHistory backups` 报份数、体积，并把「能自动清的时间戳目录」和「手写的断点目录」分开数；`backups prune 5` 按修改时间只留最近 5 份自动备份，`pre-digest-clean` 这类手工断点永远不碰；每次传输开始前也自动收一遍，不再等用户想起来。真实库上 `backups` 报 7 份 811.4 MB，其中 2 份是手工断点、5 份是自动备份，`prune 5` 判定无需清理。另一件是会话列表原来写死 `limit: 500`，真实库去重后 759 个会话，后 259 个在界面上永远看不见也没有提示。现在每页 200 个，滚到底出现「加载更多（已显示 N / 总数）」，按 `updated_at` 加 id 的游标续取；只按时间戳不行，真实库 2,329 个会话里有 15 对 `updated_at` 完全相同，落在页边界就会漏或重。450 个会话（含 4 对同时间戳）三页走完，一个不漏、不重复。`bash scripts/build.sh` 235 项通过、0 失败。

2026-10-26 参数写错就直接说，项目列表分页。真实库里 `list_projects` 有 281 个项目，拼成文本两万六千字，一次调用就吃掉大半上下文，而且越用越多。现在默认一页五十个、按关键词过滤、整体按一万六千字封顶，表头写清这一页是第几个到第几个、下一页用多少 offset；`offset` 越界和 `limit` 传成字符串都直接报错。顺带把静默退回默认值的地方都改成报错，这类问题比崩溃更难查：`search_threads` 传 `source=codex-cli` 原来跳过筛选照旧回到全库，`days=0` 原来等于不加时间窗，空 `query` 原来显示「没有命中」像是库里没东西，现在分别是「source 只认这些值」、「days 要是正整数」、「query 不能为空」。命令行 `search` 和 `digest` 的 `--source`、`search` 的 `--days` 也一样，写错退出码 2。真实库实测：项目列表 4139 字（原 25903 字），`query=易得广场` 74 字只回 1 个，翻页第 51 到 60 个正常，`offset=9999` 报越界。`bash scripts/build.sh` 214 项通过、0 失败。

2026-10-26 汇编缓存与 MCP 参数加固。主题汇编加了按段缓存，键是材料正文加通路标识的 FNV-1a 指纹，各天提炼和最后一次合并都走同一套：真实库上 `digest --days 3` 第一次 6 次调用 6 秒，第二次 0 次调用 1 秒、5 段复用，产物一字不差。缓存目录 6 份 24 KB，每轮跑完按修改时间只留最近 600 份，`--no-cache` 绕过，`digest-clean` 顺手清空。同时修掉 MCP 的两个真问题。一是 `get_thread_context` 遇到单条超长记录（本机有多条 25 万字）时，原来会 `break` 掉整段、只回一个省略号，现在截到还剩的长度；二是 `search_threads` 的 `limit=-5` 会直接在 `prefix` 上触发运行时陷阱，把整个 MCP 进程带走（exit=133、零输出），客户端一个笔误参数服务就没了。现在 `limit` 夹在 1..200、`max_chars` 夹在 500..80,000，检索结果整体按一万六千字封顶并说明「只列了前 N 条」；`--days 0`、`--limit -5`、`--parallel 0` 这类命令行笔误也会在标准错误里说明按什么值算了，不再静默退回默认。MCP 补了 `stats` 工具，共六个。`bash scripts/build.sh` 202 项通过、0 失败。

2026-10-26 提炼通路不再绑死 Claude Code。原来命令写死 `claude -p --no-session-persistence`，换一台没装 Claude Code 的机器就直接不可用。现在拆成两条通路：命令按 `claude` → `codex` → `gemini` → `ollama` → `llm` 探测，取第一个能跑的；另一条是 OpenAI 兼容接口，填地址和模型名即可，密钥留空读 `AGENT_HISTORY_LLM_API_KEY` 或 `OPENAI_API_KEY`，两条都在时走接口。本机探测到 Claude Code、Codex、Gemini CLI 三条（Gemini 缺 key）。真实库上把 `PATH` 缩到系统目录模拟干净机器（库副本 405 MB、2,329 会话）：`models` 报「没探测到模型命令行」并给出两种办法；直接 `digest --days 3` 出按天摘要，说明是「没有可用的模型通路：填一个接口地址和模型名，或者写一条命令行」，不再出现「找不到 claude」；同一份库加 `--api` 指到本地 mock 接口，2 天窗口 3 次调用、12 个会话、50 轮，产物按天分节带未决事项。接口返回 401/500、地址拼 `/chat/completions`、密钥来源、缺一半不算配、接口失败降级都有用例覆盖，全量 `bash scripts/build.sh` 通过。
2026-10-26 接口配置改成随改随存。原来只在点「生成汇编」时把地址、模型名、密钥一起写进 UserDefaults，只填不跑就不保存，密钥还是明文躺在偏好的 plist 里。现在三个输入框改一个字就落盘，关掉重开自动带出来；密钥改到 `~/.agent-history/llm.json`，权限 0600，旧版本写进偏好的启动时自动迁移并删除。实际验证：界面上键入地址后偏好里立刻出现，杀掉进程重开面板三项都在，提示行变成「走接口 接口 · deepseek-chat · api.deepseek.com，命令那一行不生效」。存取往返、缺一半不算配、清空不留旧值、0600 权限、旧密钥迁移都有用例，`bash scripts/build.sh` 全绿。`AgentHistory models` 现在会顺带列出已存的接口配置，命令行也能确认上次填了什么。

2026-10-26 主题汇编上线。在真实库上走界面跑七天汇编：覆盖 8 天、45 个会话、323 轮，15 次调用用 396 秒，产物 16,276 字，按天分节，数字和 MR 号都在，末尾带未决事项。七天窗口里 77 轮是自动化心跳或模板消息，被挡在材料外；三十天档覆盖 15 天、101 个会话、722 轮，再挡掉 148 轮。取数耗时从三分钟降到 1.6 秒，差别在于给 `turns(thread_id)` 和 `items(turn_id)` 加了索引。并发、分段覆盖、噪音过滤与降级路径都有用例覆盖。同时发现并修掉两个问题：`claude -p` 每次调用都会在会话目录落一份记录，同步时被当成真实对话收进库；加上 `--no-session-persistence` 之后不再落会话，但仍会留空的项目文件夹。真实库清理前备份到 `backups/pre-digest-clean` 和 `backups/pre-probe-clean`，两次合计清掉 41 条假会话，会话数 2,370 降到 2,329，临时路径下的会话为 0；`digest-clean` 顺带清空项目目录和汇编工作目录，在真实目录上删掉 20 个空壳、15 个工作目录（453 KB），复扫全部为空，有会话的 4 个项目原样保留。

2026-10-26 大会话与异常来源验收。本机最大的单条会话有 5,443 个条目，达不到压测目标，于是在隔离快照里把同会话条目复制一份扩到 10,886 条：取一页 1.2 毫秒，滚动更新间隔中位 25 毫秒、最慢 79 毫秒，8.1 秒内滚动位置变化 324 次没有卡顿。Claude Code 到 Codex 的交接包实测 1,649 行，给出的 `codex exec` 命令在目标工程目录里跑通，能读出标题、来源项目与待办。来源目录全部缺失时只剩 Codex 可用，其余来源在界面上显示真实路径和原因；把 OpenCode 的库切成非 WAL 模式后独占持锁，同步只报这一条来源被占用，其余来源照常完成。只装 Codex 与 WorkBuddy 的环境下同步 1,524 个会话、53,849 条记录用 4.8 秒，向导从预览到完成全程可用。

2026-10-26 会话血缘与检索聚合上线。在 2,302 个会话的真实库上重建血缘：759 个内容族、折叠 1,502 份副本（同步记录 1,500 条、按内容推断 3 条），耗时 0.37 秒，条目和检索索引行数前后不变，重复重建幂等。检索改会话级聚合后，同一关键词「易得广场」下 60 条命中旧口径只覆盖 36 个会话、约四成名额被副本占掉，新口径 60 条全部落在不同会话上，58 条带「另有 N 处副本」标注；短语命中排前、单字宽命中补后。导出实测 5,443 条的大会话 0.4 秒出 3.1 MB Markdown，文件头带来源、时间范围、记录数与遮蔽条数，工具输出折叠成引用块；重复导出两次生成两份带序号文件，互不覆盖。空库环境（无族数据）下列表、检索、导出全部正常退出。

2026-10-23 在只装 Codex 和 WorkBuddy 的环境里跑了一遍完整流程：Codex 同步 50 个会话、13,220 条消息到 WorkBuddy，写入 12.4 MB，重复执行时预览显示 50 条重复、0 条待写入。重启 WorkBuddy 后侧边栏“任务 (54)”里能看到这批会话，点开正文、表格和文档链接都能正常渲染。`swift build` 和 `bash scripts/build.sh` 均通过。

2026-10-24 增加 Kimi Code 来源和原生导入。适配器测试覆盖解析、增量与检索；写入器把一条 WorkBuddy 会话导进 `~/.kimi-code/sessions/`，重启 Kimi Code 后侧边栏出现“你好”，点开能看到两轮完整对话。来源和目标的归拢都在这台机器上实测过。

2026-10-24 增加 DeepSeek Harness 来源。用构造的会话文件验证了真实用户消息筛选、标题、项目路径、推理与工具调用，以及 zstd 压缩文件的读取和去重；本机 6 段 Harness 会话已纳入统一库（桌面版 2 段、`~/.dsh` 4 段）。另外给 Harness 装了 MCP 插件，在对话里调用 `search_threads` 搜「止损线」返回了 5 条命中标题；重启后插件仍会自动拉起。原生导入也跑通了：把一条 271 条消息的 Claude Code 会话写进 `~/.dsh/sessions`，重启 DSH 后侧边栏出现「config.yaml 中文文档设置」，点开两轮内容都正常。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。只依赖系统框架与 libsqlite3，没有第三方库。
 ## 验证记录

- 2026-10-26 应用图标最终与界面统一。侧栏左上角本来就是「Theme.accent 渐变圆角方块 + 白色 brain.head.profile 符号」，界面和 Dock 两个记忆点理应一致，所以图标改成同一副：4096 画布上先画和侧栏一致的 45 度渐变底，再用 AppKit 渲染同一个 SF Symbol 白色符号缩放到 62% 居中，缩到 1024 后打包 icns。make_icon.py 之外新增 make_icon.swift 作为符号渲染一环，整套仍可一键重生成。235 项测试全过、0 失败。


