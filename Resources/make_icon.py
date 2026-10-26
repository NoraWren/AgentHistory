#!/usr/bin/env python3
"""一键重生成应用图标。

先调 make_icon.swift 渲染 4096 母图（和侧栏一致：Theme.accent 渐变 + 白色
brain.head.profile），再缩到 1024 存 AppIcon-1024.png，并打包全套尺寸的
AgentHistory.icns。
"""
import subprocess, sys, os, shutil

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
master_tmp = '/tmp/ah-icon-master.png'
swift = os.path.join(root, 'Resources', 'make_icon.swift')

subprocess.run(['swift', swift, master_tmp], check=True)

from PIL import Image
master = Image.open(master_tmp).convert('RGBA').resize((1024, 1024), Image.LANCZOS)
master.save(os.path.join(root, 'Resources', 'AppIcon-1024.png'))

iconset = '/tmp/AgentHistory.iconset'
if os.path.isdir(iconset):
    shutil.rmtree(iconset)
os.makedirs(iconset)
pairs = [(16, 16), (16, 32), (32, 32), (32, 64), (128, 128), (128, 256),
         (256, 256), (256, 512), (512, 512), (512, 1024)]
for base, px in pairs:
    suffix = '' if px == base else '@2x'
    master.resize((px, px), Image.LANCZOS).save(
        os.path.join(iconset, 'icon_%dx%d%s.png' % (base, base, suffix)))
subprocess.run(['iconutil', '-c', 'icns', iconset, '-o',
                os.path.join(root, 'Resources', 'AgentHistory.icns')], check=True)
shutil.rmtree(iconset)
os.remove(master_tmp)
print('icon ok')

