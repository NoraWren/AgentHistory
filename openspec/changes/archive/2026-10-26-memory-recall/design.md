# 设计：记忆召回

## 上下文

现有库里已经有两条内容通道，但只有一条通。

- 会话通道：`threads` / `items` / `turns` 存正文，`search_docs` 是 contentless FTS5（`content=''`、`contentless_delete=1`），它的 `rowid` 与 `items.rowid` 一一对应。检索在 `Search.run()` 里 `search_docs JOIN items JOIN threads` 完成，再叠加族聚合与 bm25 排序。
- 文档通道：交接包写成 `~/.agent-history/handoffs/<id>.md`，汇编写成 `~/.agent-history/digests/<日期>-<标题>-<范围>.md`，两者的正文只存在于磁盘，索引里没有任何痕迹。

`handoffs` 一张表同时承载三样语义不同的东西：同步过程中的传输记录（`status=transferred`，`payload` 是目标文件路径）、agent 通过 MCP 写的交接包（`status=draft` 且有 title/summary/todos）、界面导出时写出的交接包文件（不进库）。`Lineage.rebuild()` 把整表当传输记录读，不匹配的行只计入 `skippedReasons`。

约束：只允许加法式迁移（`Store.migrate()` 全是 `CREATE TABLE IF NOT EXISTS`）；库内已有 82 万级条目与 1500 多条传输记录，不能重建；MCP 每个客户端各起一个进程，写操作要能并发安全；全部产出中文。

## 目标与非目标

**目标**

- 交接包、汇编、结论三类内容进入同一套检索，agent 在任意客户端都能召回。
- 结论带得出处（会话 ID + 条目序号），能被新结论取代、能被作废，历史保留。
- 迁移只加表，不动已有表的结构与行；老产物通过一次幂等补录跟上。

**非目标**

- 不做向量检索或 embedding：库里没有任何向量设施，中文按字切的 FTS 已经能覆盖关键词召回，加向量要引入模型与索引维护两套成本。
- 不做定时批量提炼结论：结论由 agent 在做事过程中主动写入。
- 不把记忆文档塞进会话列表、不给它造会话血缘、不计入会话数与条目数。

## 决策

### 决策一：新建独立文档表与独立全文索引，不往 `items` 里造伪会话行

记忆文档放在新表 `memory_docs`，配一张自己的 contentless FTS `memory_docs_fts`，`rowid` 与 `memory_docs.rowid` 对应，检索走两条独立通道再合并。

放弃的方案是往 `threads` / `items` 里插伪会话：复用现成检索 SQL 最省事，但代价是把污染扩散到各处——会话数、条目数、今日新增、项目列表、族聚合、血缘重建、备份体积全要重新定义「什么算会话」，而且 `items` 有 `UNIQUE(thread_id, native_item_id)`，还要给每份文档编一个假 native_id。一次改动会牵动十几个既有查询，任何一处漏改都会让「829 个会话」这类数字失真。独立表则是纯加法：老查询一行不用动，新表坏了也只影响记忆检索。

### 决策二：文档与结论共用一张表，用 `kind` 区分

`memory_docs` 同时存 `handoff`、`digest`、`fact` 三类，差异部分用可空列表达：文件类填 `path` 与 `generated_at`，结论类填 `thread_id` / `item_ordinal` / `category` / `superseded_by` / `status`。

另一条路是文档一张表、结论一张表、两张 FTS。分开的代价是检索要写三份近乎相同的 SQL，翻页和排序还得自己归一化分数；而三类内容的召回需求完全一致——按关键词命中、按时间排序、带出处。共用一张表能让 `recall` 只写一次。

### 决策三：结论唯一性用内容指纹，不用正文比对

结论按 `(thread_id, content_hash)` 建唯一索引，`content_hash` 是正文去空白后的 FNV-1a 值（`Digest` 里已有同款实现，`String.hashValue` 每进程不同，不能落盘）。同一会话里同一句话写两遍，第二次命中唯一索引，返回已有条目 ID 并标注重复。

不用「正文完全相等」判重，是因为 agent 复述时常常多一个句号或换行；也不用全局指纹，因为不同会话里同一句「发布走 OpenSpec 归档」可能各自成立，它们不该互相覆盖。

### 决策四：状态收敛而不改写历史行

`append_handoff` 新写的行记 `status='handoff'`，传输记录继续用 `transferred`。读取交接包的条件是 `status IN ('handoff','draft','')`，这样今天库里那条 `draft` 残行和更早没有状态的行都能被正确读出，不需要 UPDATE 任何既有数据。`Lineage.rebuild()` 改为只读 `status='transferred'` 且 `payload` 像文件路径的行，交接口径与血缘口径从此分家。

### 决策五：写入点在产物落盘的同一步，补录作为兜底

三个产物写入点各补一次索引登记：`append_handoff` 写完 md、`Digest.save` 写完汇编、`PocketWriter` 导出交接包。登记与落盘放在同一次调用里，失败时把错误带回给调用方，不留下「文件在、索引没有」的静默状态。

历史产物靠 `memory-backfill` 补：扫描两个目录，按 `(kind, path)` 唯一索引幂等写入；磁盘上已经不存在的文档从索引删除。启动时只跑一次，结果记在 `meta` 的 `memory_backfill_v1`，之后由使用者手动触发。

### 决策六：检索范围作为显式参数，默认行为不变

`SearchOptions` 增加 `memoryScope`，取值 `threads` / `memory` / `all`，默认 `threads`。MCP 的 `search_threads` 暴露成 `scope` 参数，不传就是老行为，六个既有工具的返回格式一个字都不改。命中类别写在每行前缀上，表头给出分类计数。

### 决策七：新增五个 MCP 工具，工具面从六个到十一个

`remember` 写结论（含 `supersedes`）、`recall` 检索记忆（支持 `thread_id`、`kind`、`query`）、`forget` 作废结论、`list_handoffs` 列交接包、`get_handoff` 按标识取回。取名与既有六个保持同一风格：动词开头、全小写下划线。

## 风险与权衡

- [索引与磁盘不一致] → 写入点同事务登记；补录命令按磁盘实际文件删除幽灵条目；检索命中时校验文件是否存在，不在则标注并用索引正文兜底。
- [`memory_docs` 被误当会话统计] → 所有会话统计查询保持只读 `threads` / `items`，新表不进任何既有聚合；用一条测试守住「加完记忆后 `stats` 数字不变」。
- [结论质量参差] → 每条结论强制带类别与出处，`category` 只收三值；无出处的标为无出处而不是拒绝，避免 agent 因查不到来源而干脆不记。
- [MCP 进程并发写] → 结论写入走单条 INSERT + 唯一索引，靠 SQLite 自身串行化；不做「先查后插」。
- [老库首次迁移耗时] → 建表与补录分离：迁移只建表（毫秒级），补录在后台一次性完成并写 marker，中途中断下次继续。

## 迁移计划

1. 发布前把 `history.db` 复制到 `backups/` 带时间戳目录，记录迁移前 `threads` / `items` / `handoffs` 行数。
2. 首次启动执行 `Store.migrate()`：追加 `memory_docs` 表与索引、`memory_docs_fts` 虚表，不触碰既有表。
3. 补录跑完核对三张表行数与迁移前一致，`search_docs` 行数不变。
4. 回滚：删掉两张新表并把 `meta.memory_backfill_v1` 清掉即可回到迁移前状态，既有表未被改动。

## 待决问题

- 汇编产物目录被使用者改到库外（`--out` 参数）时是否也纳入补录：先只补库内两份默认目录，外部目录留给后续按需支持。
- 结论的保留期与条数上限：目前不设上限，等实际写入量出来再定。

