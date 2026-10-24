# 参与开发

AgentHistory 把本机几个 AI 客户端的会话历史读进一个可检索的库，再把选中的会话交给另一个客户端。核心约束有两条：来源只读，写入前备份。

## 环境

- macOS 14 或更新
- Swift 5.9 或更新（只装 Command Line Tools 也能构建）
- 不需要 Xcode

构建、测试、打包一条命令：

```bash
bash scripts/build.sh
```

只跑测试：

```bash
swiftc -swift-version 5 Sources/Core/*.swift Tests/main.swift -o .build/tests -lsqlite3
./.build/tests
```

## 代码结构

| 路径 | 负责 |
|---|---|
| `Sources/Core/Store.swift` | 统一库的表结构与检索 |
| `Sources/Core/Adapters.swift` | 各客户端的读取适配器 |
| `Sources/Core/Transfer.swift` | 同步计划、写入器、回滚 |
| `Sources/Core/MCP.swift` | stdio MCP 服务 |
| `Sources/UI` | 三栏界面、同步向导 |

## 加一个新来源

1. 在 `Adapters.swift` 里实现探测、解析、增量读取，只读打开来源文件。
2. 在 `Tests/main.swift` 补解析与去重的断言，用构造的样本，不依赖本机会话。
3. 在 README 的「来源」表里补一行，写清楚目录、格式和限制。
4. 跑 `bash scripts/build.sh`，确认 `verify` 子命令对适配器契约的检查通过。

## 加一个新目标

写入前必须把目标文件或数据库复制到 `~/.agent-history/backups/`，带时间戳。写入后要能校验，失败时回滚。重复同步靠 `handoffs` 表去重，不能靠猜。

## 提交信息

`type: 中文描述`，type 用 feat、fix、docs、chore、refactor。
