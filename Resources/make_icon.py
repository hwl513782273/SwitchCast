#!/usr/bin/env python3
"""SwitchCast 图标生成器
风格：SwitchLink 风格 —— 满铺背景 + 大主体占 75~80% + 逐档 squircle 透明角
主体：Switch 机身（霓虹红/青 Joy-Con）+ 屏幕内的播放三角与投屏弧线
"""
import os
import subprocess

from PIL import Image, ImageDraw, ImageFilter

S = 2
N = 1024
SIZE = N * S
f = lambda v: int(round(v * S))

HERE = os.path.dirname(os.path.abspath(__file__))
ICONSET_DIR = os.path.join(HERE, "AppIcon.iconset")
ICNS_PATH = os.path.join(HERE, "AppIcon.icns")
MASTER_PATH = os.path.join(HERE, "AppIcon_1024.png")

BG_TOP = (26, 30, 62)
BG_BOTTOM = (62, 40, 108)
JOYCON_LEFT = (255, 58, 92)
JOYCON_RIGHT = (0, 199, 255)
SCREEN_FILL = (9, 11, 22)
SCREEN_EDGE = (86, 92, 140)
SYMBOL = (246, 248, 255)


def gradient(w, h, top, bottom):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        t = y / max(1, h - 1)
        row = (
            int(top[0] * (1 - t) + bottom[0] * t),
            int(top[1] * (1 - t) + bottom[1] * t),
            int(top[2] * (1 - t) + bottom[2] * t),
            255,
        )
        for x in range(w):
            px[x, y] = row
    return img


def build_master():
    canvas = gradient(SIZE, SIZE, BG_TOP, BG_BOTTOM)

    # 柔光（左上），必须模糊后再叠，否则会露出硬边圆
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([f(-240), f(-200), f(720), f(660)], fill=(104, 126, 255, 44))
    glow = glow.filter(ImageFilter.GaussianBlur(f(150)))
    canvas = Image.alpha_composite(canvas, glow)
    draw = ImageDraw.Draw(canvas)

    # 横置机身：左右 Joy-Con + 中间 16:9 屏幕
    body_top, body_bottom = f(316), f(708)
    draw.rounded_rectangle([f(62), body_top, f(198), body_bottom], radius=f(48), fill=JOYCON_LEFT)
    draw.rounded_rectangle([f(826), body_top, f(962), body_bottom], radius=f(48), fill=JOYCON_RIGHT)

    draw.rounded_rectangle(
        [f(210), f(342), f(814), f(682)], radius=f(22), fill=SCREEN_FILL,
        outline=SCREEN_EDGE, width=f(5),
    )

    # 屏幕内：播放三角 + 左下角投屏弧线
    cx, cy = f(510), f(512)
    size = f(76)
    draw.polygon(
        [(cx - size * 0.66, cy - size), (cx - size * 0.66, cy + size), (cx + size * 1.02, cy)],
        fill=SYMBOL,
    )

    arc_center = (f(276), f(636))
    for i, radius in enumerate([f(58), f(96), f(134)]):
        draw.arc(
            [arc_center[0] - radius, arc_center[1] - radius,
             arc_center[0] + radius, arc_center[1] + radius],
            start=-74, end=-16, fill=SYMBOL, width=f(14 - i * 2),
        )
    dot = f(13)
    draw.ellipse(
        [arc_center[0] - dot, arc_center[1] - dot, arc_center[0] + dot, arc_center[1] + dot],
        fill=SYMBOL,
    )

    # 左 Joy-Con 摇杆 / 右 Joy-Con 四键
    stick_r = f(20)
    sx, sy = f(130), f(432)
    draw.ellipse([sx - stick_r, sy - stick_r, sx + stick_r, sy + stick_r], fill=(22, 24, 40))
    for dx, dy in [(-25, 0), (25, 0), (0, -25), (0, 25)]:
        bx, by = f(894 + dx), f(432 + dy)
        r = f(10)
        draw.ellipse([bx - r, by - r, bx + r, by + r], fill=(14, 30, 44))

    return canvas.resize((N, N), Image.LANCZOS)


def squircle(img, radius_ratio=0.225):
    w, h = img.size
    mask = Image.new("L", (w, h), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle([0, 0, w - 1, h - 1], radius=int(w * radius_ratio), fill=255)
    out = img.copy()
    out.putalpha(mask)
    return out


def main():
    os.makedirs(ICONSET_DIR, exist_ok=True)
    master = build_master()
    master.save(MASTER_PATH)

    specs = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ("icon_64x64.png", 64),
    ]
    for name, px in specs:
        resized = master.resize((px, px), Image.LANCZOS)
        squircle(resized).save(os.path.join(ICONSET_DIR, name))
        actual = Image.open(os.path.join(ICONSET_DIR, name)).size
        assert actual == (px, px), f"{name} 尺寸错误 {actual}"

    subprocess.run(["iconutil", "-c", "icns", "-o", ICNS_PATH, ICONSET_DIR], check=True)

    # 四角 alpha 自检
    icns_img = Image.open(ICNS_PATH)
    px = icns_img.convert("RGBA").load()
    w, h = icns_img.size
    corners = [px[0, 0], px[w - 1, 0], px[0, h - 1], px[w - 1, h - 1]]
    print(f"master={MASTER_PATH} icns={ICNS_PATH} size={w}x{h}")
    print("corners alpha:", [c[3] for c in corners])


if __name__ == "__main__":
    main()
