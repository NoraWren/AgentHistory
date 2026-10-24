from PIL import Image, ImageDraw, ImageFilter
import numpy as np, os

S = 4096
def grad(size, c1, c2):
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    t = (x + y) / (2 * (size - 1))
    a = np.array(c1, dtype=np.float32); b = np.array(c2, dtype=np.float32)
    img = a[None, None, :] * (1 - t[..., None]) + b[None, None, :] * t[..., None]
    return Image.fromarray(img.astype(np.uint8), 'RGB')

M = int(S * 0.098)           # 外边距，接近 macOS 图标比例
box = (M, M, S - M, S - M)
w = S - 2 * M
radius = int(w * 0.2237)

art = grad(S, (0x6E, 0x76, 0xFF), (0x43, 0x3A, 0xD6))

# 阴影
shadow = Image.new('L', (S, S), 0)
ImageDraw.Draw(shadow).rounded_rectangle(box, radius=radius, fill=80)
shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.016))
canvas = Image.new('RGBA', (S, S), (0, 0, 0, 0))
sh = Image.new('RGBA', (S, S), (10, 8, 40, 255))
canvas.paste(sh, (0, int(S * 0.004)), shadow)

mask = Image.new('L', (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
canvas.paste(art, (0, 0), mask)

# 顶部柔光
glow = Image.new('L', (S, S), 0)
ImageDraw.Draw(glow).ellipse((-S * 0.3, -S * 0.55, S * 0.85, S * 0.35), fill=90)
glow = glow.filter(ImageFilter.GaussianBlur(S * 0.06))
canvas.paste(Image.new('RGBA', (S, S), (255, 255, 255, 255)), (0, 0), Image.composite(glow, Image.new('L', (S,S), 0), mask))

d = ImageDraw.Draw(canvas)

def rr(x0, y0, x1, y1, r, fill=None, outline=None, width=1):
    d.rounded_rectangle((x0, y0, x1, y1), radius=r, fill=fill, outline=outline, width=width)

u = S / 1024.0
def P(v): return int(v * u)

# 卡片
card = (P(228), P(210), P(664), P(648))
rr(*card, P(54), fill=(255, 255, 255, 246))

# 卡片顶部三个来源圆点
for i, c in enumerate([(0x5D, 0x66, 0xF1, 255), (0x22, 0xB8, 0xA5, 255), (0xF5, 0x9E, 0x0B, 255)]):
    cx = P(292 + i * 44); cy = P(276); r = P(13)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=c)

# 三条消息线
lines = [(P(292), P(378), P(640)), (P(292), P(462), P(614)), (P(292), P(546), P(548))]
for x0, y, x1 in lines:
    rr(x0, y - P(17), x1, y + P(17), P(17), fill=(0x5D, 0x66, 0xF1, 46))

# 放大镜：只画圆环，镜片内部保持透出卡片与底色
cx, cy, ro, rw = P(712), P(704), P(120), P(38)
import math
# 镜片做成“透出底色”的洞，压在白色卡片上也能看清
hole = Image.new('L', (S, S), 0)
ImageDraw.Draw(hole).ellipse((cx - ro + rw / 2, cy - ro + rw / 2, cx + ro - rw / 2, cy + ro - rw / 2), fill=255)
canvas.paste(art, (0, 0), Image.composite(hole, Image.new('L', (S, S), 0), mask))
d = ImageDraw.Draw(canvas)
for i in range(int(rw * 1.2)):
    k = i - rw * 0.6
    rr = ro + k
    d.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), outline=(255, 255, 255, 255), width=1)

# 手柄：从圆环 45 度方向向外，端头是圆角
ang = math.radians(45)
sx, sy = cx + ro * math.cos(ang), cy + ro * math.sin(ang)
ex, ey = cx + ro * 1.62 * math.cos(ang), cy + ro * 1.62 * math.sin(ang)
d.line((sx, sy, ex, ey), fill=(255, 255, 255, 255), width=int(rw * 1.15))
d.ellipse((ex - rw * 0.58, ey - rw * 0.58, ex + rw * 0.58, ey + rw * 0.58), fill=(255, 255, 255, 255))

canvas = canvas.resize((1024, 1024), Image.LANCZOS)
canvas.save('Resources/AppIcon-1024.png')
print('ok')

