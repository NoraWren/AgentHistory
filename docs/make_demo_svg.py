#!/usr/bin/env python3
"""生成 README 顶部的界面演示动画。

动画是自播放的 SVG：不依赖脚本，GitHub 上直接动。布局按界面实际的三栏来画，
时间轴写在下面几个常量里，改完重跑这个脚本就行。

    python3 docs/make_demo_svg.py                     # 写 docs/demo.svg
    python3 docs/make_demo_svg.py --still 5.0 out.svg # 定格在第 5 秒，用来检查排版
"""

import sys

W, H = 1120, 700
DUR = 14.0

# 关键时间点，改这里就能调节奏
T_TYPE = (2.4, 3.0, 3.6)      # 三个字逐个落下
T_HITS = 4.4                  # 会话结果出现
T_SCOPE = 6.6                 # 切到「记忆」范围
T_DETAIL = 8.4                # 右侧换成汇编详情
T_RESET = 11.2                # 回到初始状态，准备下一轮

PRI = "#1D1D1F"
SEC = "#6E6E73"
TER = "#A1A1A6"
LINE = "#E4E4E8"
ACCENT = "#5D66F1"
ACCENT_SOFT = "#EEEFFE"
SIDEBAR_BG = "#F6F6F8"
CARD = "#FFFFFF"

SOURCE = {
    "codex": "#5D66F1",
    "claude": "#EC8B4F",
    "workbuddy": "#25AD9C",
    "opencode": "#8B66E3",
    "kimi": "#416FA2",
    "deepseek": "#2578F5",
}
MEMORY = {"handoff": "#4F85F0", "digest": "#25A39A", "fact": "#DE852E"}

FONT = "'PingFang SC','Hiragino Sans GB','Microsoft YaHei','Noto Sans CJK SC',sans-serif"

els = []          # (svg, 动画 id, 显示区间)


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def add(svg, key=None, show=None):
    els.append((svg, key, show))
    return svg


def rect(x, y, w, h, fill="none", r=0, stroke=None, sw=1, extra=""):
    s = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" '
            f'fill="{fill}"{s}{extra}/>')


def txt(x, y, s, size=12, fill=PRI, weight="normal", anchor="start", extra=""):
    return (f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" '
            f'font-weight="{weight}" text-anchor="{anchor}" font-family="{FONT}"{extra}>'
            f'{esc(s)}</text>')


def pill(x, y, s, color, size=9, h=15):
    w = len(s) * size * 0.92 + 10
    return (rect(x, y, w, h, fill=color + "1F", r=h / 2) +
            txt(x + w / 2, y + h / 2 + size * 0.36, s, size, color, "600", "middle"))


def textw(s, size):
    """估算文本宽度：中日韩按一个字宽，西文按 0.55 个字宽。"""
    return sum(size if ord(ch) > 127 else size * 0.55 for ch in s)


def pct(t):
    return max(0.0, min(100.0, t / DUR * 100.0))


def keyframes(key, segs):
    merged = {}
    for a, b in segs:
        for t, v in ((max(a - 0.28, 0.0), 0.0), (a, 1.0), (max(b - 0.28, a), 1.0),
                     (min(b, DUR), 0.0)):
            merged[round(pct(t), 2)] = v      # 同一时刻以后写的为准
    items = sorted(merged.items())
    if items[0][0] > 0:
        items.insert(0, (0.0, 0.0))
    if items[-1][0] < 100:
        items.append((100.0, items[-1][1]))
    body = "".join(f"{p:g}%{{opacity:{v:g}}}" for p, v in items)
    return f"@keyframes {key}{{{body}}}"


def visible_at(segs, t):
    return 1.0 if any(a <= t < b for a, b in segs) else 0.0


def hide(svg):
    return '<g opacity="0">' + svg + '</g>'


# ---------- 外壳 ----------

def chrome():
    add(rect(0, 0, W, H, fill=CARD, r=14, stroke=LINE))
    add(rect(0, 0, W, 44, fill="#FAFAFC", r=14))
    add(rect(0, 30, W, 14, fill="#FAFAFC"))
    add(rect(0, 43, W, 1, fill=LINE))
    for i, c in enumerate(["#FF5F57", "#FEBC2E", "#28C840"]):
        add(f'<circle cx="{22 + i * 19}" cy="22" r="6" fill="{c}"/>')
    add(txt(W / 2, 26, "Agent 记忆", 13, PRI, "600", "middle"))

    x = 706
    for label in ["汇编", "记忆", "来源状态", "MCP 接入", "同步"]:
        w = len(label) * 10 + (34 if len(label) > 3 else 26)
        add(rect(x, 11, w, 22, fill="#FFFFFF", r=6, stroke=LINE))
        add(txt(x + w / 2, 26, label, 11, SEC, "normal", "middle"))
        x += w + 8


def sidebar():
    add(rect(0, 44, 250, H - 44, fill=SIDEBAR_BG))
    add(rect(249, 44, 1, H - 44, fill=LINE))
    add('<defs><linearGradient id="icn" x1="0" y1="0" x2="1" y2="1">'
        f'<stop offset="0" stop-color="{ACCENT}"/>'
        f'<stop offset="1" stop-color="{ACCENT}" stop-opacity="0.65"/>'
        '</linearGradient></defs>')
    add(rect(14, 56, 32, 32, fill="url(#icn)", r=9))
    add('<g transform="translate(30,72)">'
        '<path d="M-7,-1c-3,-5 1,-9 6,-8c1,-4 7,-3 7,1c4,0 5,5 2,7c1,4 -3,6 -6,4'
        'c-3,3 -8,0 -9,-4z" fill="#FFFFFF" opacity="0.95"/>'
        '<path d="M-1,-7v12M-5,-3h2M2,-2h2" stroke="#5D66F1" stroke-width="1.2" '
        'stroke-linecap="round"/></g>')
    add(txt(56, 66, "Agent 记忆", 13, PRI, "600"))
    add(txt(56, 80, "跨客户端历史", 9, SEC))

    add(txt(22, 114, "来源", 9, TER, "600"))
    rows = [("全部来源", 1231, ACCENT, True), ("Codex", 604, SOURCE["codex"], False),
            ("Claude Code", 218, SOURCE["claude"], False),
            ("WorkBuddy", 202, SOURCE["workbuddy"], False),
            ("OpenCode", 121, SOURCE["opencode"], False),
            ("Kimi Code", 74, SOURCE["kimi"], False),
            ("DeepSeek Harness", 12, SOURCE["deepseek"], False)]
    y = 122
    for name, n, tint, sel in rows:
        if sel:
            add(rect(8, y, 234, 24, fill=CARD, r=6, stroke=LINE))
        add(f'<circle cx="20" cy="{y + 12}" r="3.5" fill="{tint}"/>')
        add(txt(32, y + 16, name, 11, PRI if sel else "#3C3C41"))
        add(txt(234, y + 16, str(n), 9, TER, "normal", "end"))
        y += 26

    add(txt(22, y + 20, "项目", 9, TER, "600"))
    y += 28
    for name, n in [("demo-web", 312), ("api-gateway", 288), ("notes-cli", 260),
                    ("infra-scripts", 154), ("blog", 96), ("mock-service", 41)]:
        add(f'<path d="M18,{y + 4}h5l2,2h5v8h-12z" fill="none" stroke="{TER}" '
            'stroke-width="1.1"/>')
        add(txt(34, y + 13, name, 11, "#3C3C41"))
        add(txt(234, y + 13, str(n), 9, TER, "normal", "end"))
        y += 24


def searchbar():
    add(rect(262, 54, 486, 28, fill="#FFFFFF", r=8, stroke=LINE))
    add(f'<circle cx="276" cy="68" r="3.6" fill="none" stroke="{SEC}" stroke-width="1.3"/>'
        f'<path d="M279,71l3,3" stroke="{SEC}" stroke-width="1.3" stroke-linecap="round"/>')
    add(txt(288, 72, "搜索会话、命令、结论", 11, TER), key="ph",
        show=[(0, T_TYPE[0]), (T_RESET, DUR)])
    xs = [288, 303, 318]
    for i, ch in enumerate("限流器"):
        add(txt(xs[i], 72, ch, 12, PRI), key=f"ty{i}", show=[(T_TYPE[i], T_RESET)])
    caret = ('<animate attributeName="opacity" values="1;1;0;0;1" dur="1.06s" '
             'repeatCount="indefinite"/>')
    add(f'<g><rect x="288" y="61" width="1.4" height="14" fill="{ACCENT}">{caret}</rect></g>',
        key="caretA", show=[(0, T_TYPE[0])])
    add(f'<g><rect x="334" y="61" width="1.4" height="14" fill="{ACCENT}">{caret}</rect></g>',
        key="caretB", show=[(T_TYPE[2], T_RESET)])

    add(rect(262, 90, 150, 20, fill="#EDEDF0", r=5))
    add(rect(263, 91, 48, 18, fill=CARD, r=4, stroke=LINE), key="segA",
        show=[(0, T_SCOPE), (T_RESET, DUR)])
    add(rect(313, 91, 48, 18, fill=CARD, r=4, stroke=LINE), key="segB",
        show=[(T_SCOPE, T_RESET)])
    for i, label in enumerate(["会话", "记忆", "全部"]):
        add(txt(287 + i * 50, 104, label, 10, SEC, "normal", "middle"))

    add(rect(424, 95, 24, 11, fill=ACCENT, r=6))
    add('<circle cx="442" cy="100.5" r="4.5" fill="#FFFFFF"/>')
    add(txt(454, 104, "合并副本", 10, SEC))
    add(f'<path d="M516,104l4,4l4,-4" fill="none" stroke="{SEC}" stroke-width="1.2"/>')
    add(txt(528, 104, "全部", 10, SEC))
    add(rect(562, 96, 9, 9, fill="#FFFFFF", r=2, stroke=TER))
    add(txt(576, 104, "只看提问", 10, SEC))


def divider_detail():
    add(rect(760, 44, 1, H - 44, fill=LINE))


def thread_row(y, title, source, project, time, copies=0):
    out = [txt(268, y + 18, title, 12, PRI), pill(268, y + 26, source[0], source[1])]
    x = 268 + len(source[0]) * 8.6 + 12
    out.append(txt(x, y + 37, project, 9, SEC))
    if copies:
        out.append(txt(x + len(project) * 9 + 8, y + 37, f"另有 {copies} 处副本", 9, TER))
    out.append(txt(744, y + 37, time, 9, TER, "normal", "end"))
    return "".join(out)


def memory_row(y, label, title, detail, meta, color):
    return "".join([txt(268, y + 18, title, 12, PRI),
                    pill(268, y + 26, label, color),
                    txt(268 + len(label) * 9.4 + 12, y + 37, detail, 9, SEC),
                    txt(744, y + 37, meta, 9, TER, "normal", "end")])


# ---------- 右侧面板 ----------

def overview():
    out = [txt(784, 76, "总览", 17, PRI, "600"),
           txt(784, 94, "各客户端的会话、项目和任务记录都在这里", 10, SEC)]
    cards = [("1,231", "会话", ACCENT), ("9.8 万", "记录", "#25A39A"),
             ("96", "项目", "#DE852E"), ("24", "今日新增", "#E2557F")]
    for i, (v, k, c) in enumerate(cards):
        x = 784 + (i % 2) * 168
        y = 110 + (i // 2) * 74
        out += [rect(x, y, 156, 64, fill="#FAFAFC", r=10, stroke=LINE),
                f'<circle cx="{x + 16}" cy="{y + 22}" r="4" fill="{c}"/>',
                txt(x + 40, y + 27, v, 19, PRI, "600"),
                txt(x + 16, y + 50, k, 10, SEC)]
    out += [rect(784, 266, 322, 130, fill="#FAFAFC", r=10, stroke=LINE),
            txt(800, 288, "近 30 天", 10, SEC)]
    heights = [26, 40, 34, 52, 30, 58, 44, 66, 38, 50, 62, 42]
    for i, h in enumerate(heights):
        out.append(rect(800 + i * 24, 380 - h, 13, h, fill=ACCENT, r=3,
                        extra=' opacity="0.85"'))
    return "".join(out)


def digest_detail():
    out = [txt(784, 78, "10 月第 4 周汇编", 15, PRI, "600"),
           pill(784, 88, "汇编", MEMORY["digest"]),
           txt(826, 99, "18 个会话 · 96 轮 · 10-20 至 10-26", 9, SEC)]
    blocks = [("这周做了什么", ["把网关的鉴权重试补上", "导出分页的问题查到了根因"]),
              ("关键结论", ["限流器按 100 次/分钟算，超出排队", "构建缓存放在构建目录外"]),
              ("未决事项", ["压测报告等下周补一版"])]
    y = 124
    for title, lines in blocks:
        out.append(txt(784, y + 6, title, 11, PRI, "600"))
        y += 22
        for line in lines:
            out += [f'<circle cx="788" cy="{y + 4}" r="2" fill="{TER}"/>',
                    txt(798, y + 8, line, 10, "#3C3C41")]
            y += 20
        y += 12
    return "".join(out)


# ---------- 组装 ----------

def build(still=None, paused=None):
    chrome()
    sidebar()
    searchbar()
    divider_detail()

    rows = [("整理一下网关的鉴权链路", ("Codex", SOURCE["codex"]), "api-gateway", "10-29 21:04"),
            ("导出功能的分页没生效", ("Codex", SOURCE["codex"]), "demo-web", "10-29 20:45"),
            ("补一遍日志字段的校验", ("Claude Code", SOURCE["claude"]), "notes-cli", "10-29 18:30"),
            ("限流器上线前的压测记录", ("Codex", SOURCE["codex"]), "infra-scripts", "10-29 16:12"),
            ("周报模板的图表换一版", ("Codex", SOURCE["codex"]), "blog", "10-29 15:40"),
            ("限流器的口径和阈值核对", ("WorkBuddy", SOURCE["workbuddy"]), "demo-web", "10-29 14:05"),
            ("把接入面板的差异预览再过一遍", ("Codex", SOURCE["codex"]), "api-gateway", "10-29 11:26"),
            ("静态站点的构建缓存估算", ("Kimi Code", SOURCE["kimi"]), "blog", "10-29 10:02")]
    body, y = [], 138
    for title, src, project, time in rows:
        body.append(thread_row(y, title, src, project, time))
        y += 56
    add('<g>' + ''.join(body) + '</g>', key="idle", show=[(0, T_HITS), (T_RESET, DUR)])
    add(txt(266, 126, "1231 个会话 · 9.8 万条记录 · 今日 24", 9, SEC),
        key="sumIdle", show=[(0, T_HITS), (T_RESET, DUR)])

    hits = [("限流器的口径和阈值核对", ("WorkBuddy", SOURCE["workbuddy"]), "demo-web", "10-29 14:05", 2),
            ("限流器按 100 次/分钟设置", ("Codex", SOURCE["codex"]), "api-gateway", "10-27 22:10", 0),
            ("复盘：限流触发后的降级顺序", ("Claude Code", SOURCE["claude"]), "notes-cli", "10-24 09:31", 0),
            ("把限流器写进接口文档", ("Codex", SOURCE["codex"]), "api-gateway", "10-22 11:18", 1)]
    body, y = [], 138
    for title, src, project, time, copies in hits:
        body.append(thread_row(y, title, src, project, time, copies))
        y += 56
    add('<g>' + ''.join(body) + '</g>', key="hits", show=[(T_HITS, T_SCOPE)])
    add(txt(266, 126, "找到 4 个会话 · 已合并 3 处副本", 9, SEC), key="sumHits",
        show=[(T_HITS, T_SCOPE)])

    mem = [("10 月第 4 周汇编 · 限流口径", "汇编", "10-26", "digest"),
           ("交接：限流器阈值核对", "交接包", "10-28", "handoff"),
           ("限流器按 100 次/分钟算，超出排队", "结论", "10-27", "fact")]
    body, y = [], 138
    details = {"汇编": "18 个会话 · 96 轮", "交接包": "来源 Codex · 12 轮",
               "结论": "来源 api-gateway"}
    for title, label, meta, kind in mem:
        body.append(memory_row(y, label, title, details[label], meta, MEMORY[kind]))
        y += 56
    add(rect(258, 138, 494, 50, fill=ACCENT_SOFT, r=8), key="sel",
        show=[(T_DETAIL, T_RESET)])
    add('<g>' + ''.join(body) + '</g>', key="mem", show=[(T_SCOPE, T_RESET)])
    add(txt(266, 126, "找到 3 条记忆", 9, SEC), key="sumMem", show=[(T_SCOPE, T_RESET)])

    add(overview(), key="ov", show=[(0, T_DETAIL), (T_RESET, DUR)])
    add(digest_detail(), key="dd", show=[(T_DETAIL, T_RESET)])

    add(rect(0, 678, W, 22, fill="#FBFBFC"))
    add(rect(0, 678, W, 1, fill=LINE))
    add(txt(20, 693, "1231 个会话 · 98,432 条记录 · 今日 24", 9, SEC))
    add(txt(744, 693, "MCP 6/6", 9, ACCENT, "600", "end"))

    out, css = [], []
    for svg, key, show in els:
        if not key:
            out.append(svg)
            continue
        if still is None:
            css.append(keyframes(key, show))
            extra = f";animation-delay:-{paused}s;animation-play-state:paused" if paused is not None else ""
            css.append(f"#{key}{{opacity:0;animation:{key} {DUR}s linear infinite{extra}}}")
            out.append(f'<g id="{key}">{svg}</g>')
        else:
            out.append(svg if visible_at(show, still) else hide(svg))
    if still is None:
        out.insert(0, "<style>" + "".join(css) + "</style>")

    return ('<svg xmlns="http://www.w3.org/2000/svg" '
            f'viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
            'role="img" aria-label="Agent 记忆界面演示">'
            '<title>Agent 记忆：检索会话与记忆</title>' + "".join(out) + "</svg>")


if __name__ == "__main__":
    if "--still" in sys.argv:
        i = sys.argv.index("--still")
        t = float(sys.argv[i + 1])
        path = sys.argv[i + 2] if len(sys.argv) > i + 2 else "/tmp/demo-still.svg"
        svg = build(still=t)
    elif "--pause" in sys.argv:
        i = sys.argv.index("--pause")
        t = float(sys.argv[i + 1])
        path = sys.argv[i + 2] if len(sys.argv) > i + 2 else "/tmp/demo-pause.svg"
        svg = build(paused=t)
    else:
        path = "docs/demo.svg"
        svg = build()
    with open(path, "w", encoding="utf-8") as f:
        f.write(svg)
    print(f"{path}  {len(svg) / 1024:.1f} KB")

