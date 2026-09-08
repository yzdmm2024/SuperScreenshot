# -*- coding: utf-8 -*-
from PIL import Image, ImageDraw

BUNDLE = r"C:\Users\10131\Desktop\我自己写的插件\超级截图\SuperScreenshot\layout\Library\ControlCenter\Bundles\SuperScreenshotCCModule.bundle"
WHITE = (255, 255, 255, 255)
TRANS = (0, 0, 0, 0)


def new_img(s):
    return Image.new("RGBA", (s, s), (0, 0, 0, 0))


def camera(d, s):
    w = max(2, int(s * 0.05))
    d.rounded_rectangle([0.16 * s, 0.30 * s, 0.84 * s, 0.80 * s], radius=0.12 * s, fill=WHITE)
    d.rounded_rectangle([0.40 * s, 0.20 * s, 0.58 * s, 0.34 * s], radius=0.03 * s, fill=WHITE)
    # 镜头：在机身中央挖一个透明圆孔，形成“白环+镜头”观感
    d.ellipse([0.37 * s, 0.43 * s, 0.63 * s, 0.69 * s], fill=TRANS)
    d.ellipse([0.37 * s, 0.43 * s, 0.63 * s, 0.69 * s], outline=WHITE, width=w)


def scissors(d, s):
    w = max(2, int(s * 0.06))
    # 两个把手环（描边）
    d.ellipse([0.28 * s, 0.58 * s, 0.48 * s, 0.78 * s], outline=WHITE, width=w)
    d.ellipse([0.52 * s, 0.58 * s, 0.72 * s, 0.78 * s], outline=WHITE, width=w)
    # 两片刀刃交叉
    d.line([(0.38 * s, 0.66 * s), (0.64 * s, 0.22 * s)], fill=WHITE, width=w)
    # （第二片刀刃在下行业已绘制）
    d.line([(0.62 * s, 0.66 * s), (0.36 * s, 0.24 * s)], fill=WHITE, width=w)


def bolt(d, s):
    pts = [
        (0.56 * s, 0.12 * s), (0.34 * s, 0.54 * s), (0.50 * s, 0.54 * s),
        (0.40 * s, 0.88 * s), (0.70 * s, 0.42 * s), (0.52 * s, 0.42 * s),
    ]
    d.polygon(pts, fill=WHITE)


def doc(d, s):
    w = max(2, int(s * 0.045))
    d.rounded_rectangle([0.26 * s, 0.18 * s, 0.74 * s, 0.86 * s], radius=0.06 * s, fill=WHITE)
    # 右上折角
    d.polygon([(0.58 * s, 0.18 * s), (0.74 * s, 0.18 * s), (0.74 * s, 0.38 * s)], fill=TRANS)
    # 文本行（透明挖空）
    for yy in (0.46, 0.56, 0.66):
        d.line([(0.34 * s, yy * s), (0.66 * s, yy * s)], fill=TRANS, width=w)


def star(d, s):
    import math
    cx, cy = 0.5 * s, 0.5 * s
    ro, ri = 0.40 * s, 0.17 * s
    pts = []
    for i in range(10):
        r = ro if i % 2 == 0 else ri
        ang = -math.pi / 2 + i * math.pi / 5
        pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
    d.polygon(pts, fill=WHITE)


BUILDERS = {
    "camera": camera,
    "scissors": scissors,
    "bolt": bolt,
    "doc": doc,
    "star": star,
}

for name, fn in BUILDERS.items():
    for s in (60, 120, 180):
        img = new_img(s)
        d = ImageDraw.Draw(img)
        fn(d, s)
        out = f"{BUNDLE}/{name}.png" if s == 60 else f"{BUNDLE}/{name}@{s//60}x.png"
        img.save(out)
        print("wrote", out, img.size)

# icon.png = camera（默认/老名字兜底），保持三档齐全
for s in (60, 120, 180):
    img = new_img(s)
    d = ImageDraw.Draw(img)
    camera(d, s)
    out = f"{BUNDLE}/icon.png" if s == 60 else f"{BUNDLE}/icon@{s//60}x.png"
    img.save(out)
    print("wrote", out, img.size)
