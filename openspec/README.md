# agent 记忆共享 OpenSpec 规格库

本目录是 `agent记忆共享` 项目的 OpenSpec 规格与变更归档，采用 spec-driven 工作流：规格描述当前事实，变更提案记录一次改动的完整上下文。

## 目录结构

- `config.yaml`：工作区配置，定义项目上下文与各产物的撰写规则。
- `specs/<capability>/spec.md`：当前能力规格，按 kebab-case 能力名组织。
- `changes/<change-name>/`：进行中的变更，包含 proposal、specs 增量、design 与 tasks。
- `changes/archive/<YYYY-MM-DD-change-name>/`：已完成并归档的变更。

## 常用命令

在项目根目录执行，OpenSpec 会以最近的 `openspec/` 目录作为根：

```bash
openspec list
openspec list --specs
openspec new change <name>
openspec status --change <name> --json
openspec validate --strict <name>
openspec archive <name>
```

## 约定

- 所有文档使用中文撰写。
- 规格按能力划分，不按文件目录机械拆分。
- 能力名使用 kebab-case，并保持稳定。
- 归档时先同步 specs 增量，再移入 `changes/archive/`。
