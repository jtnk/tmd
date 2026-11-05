#!/usr/bin/env python3
"""Draws the artwork in this folder. tmd's SVG renderer has no <text>, so wording becomes outlines.

Needs fontTools. Usage: generate.py path/to/Bold.ttf [output-dir]
"""
import os
import sys

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

font = TTFont(sys.argv[1])
glyphs = font.getGlyphSet()
cmap = font.getBestCmap()
upem = font["head"].unitsPerEm
out_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(__file__))


def text(s, x, y, size, fill, anchor="start"):
    """A <path> drawing s with its baseline at (x, y)."""
    scale = size / upem
    widths = [glyphs[cmap[ord(c)]].width for c in s]
    total = sum(widths) * scale
    if anchor == "middle":
        x -= total / 2
    pen = SVGPathPen(glyphs, ntos=lambda v: f"{v:.1f}".rstrip("0").rstrip("."))
    at = x
    for c, w in zip(s, widths):
        glyphs[cmap[ord(c)]].draw(TransformPen(pen, (scale, 0, 0, -scale, at, y)))
        at += w * scale
    return f'<path d="{pen.getCommands()}" fill="{fill}"/>'


def rect(x, y, w, h, fill, r=0):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" ry="{r}" fill="{fill}"/>'


def svg(name, w, h, body):
    doc = f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">\n'
    doc += "\n".join(body) + "\n</svg>\n"
    with open(os.path.join(out_dir, name), "w") as f:
        f.write(doc)


# The palettes in src/theme.zig: bg, text, heading, muted, dim, link, code, code bg, accent.
PALETTES = [
    ("dracula", "#282A36 #F8F8F2 #BD93F9 #8C98C4 #6272A4 #8BE9FD #50FA7B #383A4A #FFB86C"),
    ("nord", "#2E3440 #D8DEE9 #88C0D0 #8F9AB0 #616E88 #81A1C1 #A3BE8C #3B4252 #EBCB8B"),
    ("gruvbox", "#282828 #EBDBB2 #FABD2F #A89984 #7C6F64 #83A598 #B8BB26 #3C3836 #FE8019"),
    ("tokyo-night", "#1A1B26 #C0CAF5 #BB9AF7 #8990B3 #565F89 #7AA2F7 #9ECE6A #24283B #FF9E64"),
    ("catppuccin", "#1E1E2E #CDD6F4 #CBA6F7 #9399B2 #6C7086 #89B4FA #A6E3A1 #313244 #FAB387"),
    ("solarized-dark", "#002B36 #93A1A1 #B58900 #839496 #586E75 #268BD2 #2AA198 #073642 #CB4B16"),
    ("solarized-light", "#FDF6E3 #586E75 #CB4B16 #839496 #93A1A1 #268BD2 #859900 #EEE8D5 #B58900"),
    ("one-light", "#FAFAFA #383A42 #A626A4 #696C77 #A0A1A7 #4078F2 #50A14F #ECECED #C18401"),
]


def hero():
    bg, ink, purple, muted, dim, cyan, green, panel, orange = PALETTES[4][1].split()
    b = [rect(0, 0, 960, 300, bg, 18)]
    b.append(text("tmd", 56, 150, 120, purple))
    b.append(rect(278, 66, 56, 92, green, 4))
    b.append(text("Markdown, rendered in your terminal", 60, 206, 24, ink))
    # A sketch of a rendered page.
    x, y = 610, 44
    b.append(rect(x, y, 300, 212, panel, 12))
    b.append(rect(x + 24, y + 26, 150, 18, purple, 4))
    b.append(rect(x + 24, y + 54, 252, 3, purple))
    for i, w in enumerate((236, 252, 190)):
        b.append(rect(x + 24, y + 74 + i * 18, w, 7, ink if i != 1 else muted, 3))
    b.append(rect(x + 24, y + 134, 252, 54, bg, 6))
    for i, (w, c) in enumerate(((70, cyan), (120, green), (92, orange))):
        b.append(rect(x + 38, y + 145 + i * 13, w, 6, c, 3))
    svg("hero.svg", 960, 300, b)


def palettes():
    cw, ch, gap = 226, 130, 12
    b = []
    for i, (name, colors) in enumerate(PALETTES):
        bg, ink, head, muted, dim, link, code, panel, accent = colors.split()
        x, y = (i % 4) * (cw + gap), (i // 4) * (ch + gap)
        b.append(rect(x, y, cw, ch, bg, 10))
        b.append(text(name, x + 16, y + 32, 19, head))
        b.append(rect(x + 16, y + 42, cw - 32, 2, dim))
        b.append(rect(x + 16, y + 56, 120, 6, ink, 3))
        b.append(rect(x + 142, y + 56, 68, 6, link, 3))
        b.append(rect(x + 16, y + 70, 150, 6, muted, 3))
        b.append(rect(x + 16, y + 88, cw - 32, 28, panel, 5))
        b.append(rect(x + 26, y + 94, 90, 6, code, 3))
        b.append(rect(x + 26, y + 105, 60, 6, accent, 3))
    svg("palettes.svg", 4 * cw + 3 * gap, 2 * ch + gap, b)


def pipeline():
    bg, ink, purple, muted, dim, cyan, green, panel, orange = PALETTES[4][1].split()
    steps = [
        ("Markdown", "the document", purple),
        ("Rows", "wrapped for this width", cyan),
        ("Diff", "hash each row", orange),
        ("Terminal", "changed rows only", green),
    ]
    w, h, gap = 189, 112, 48
    b = [rect(0, 0, 960, 176, bg, 14)]
    for i, (title, sub, color) in enumerate(steps):
        x = 30 + i * (w + gap)
        b.append(rect(x, 32, w, h, panel, 10))
        b.append(rect(x, 32, w, 6, color, 3))
        b.append(text(title, x + w / 2, 84, 25, color, "middle"))
        b.append(text(sub, x + w / 2, 116, 13.5, muted, "middle"))
        if i < 3:
            ax = x + w + 8
            b.append(f'<path d="M{ax} 88 L{ax + 24} 88 M{ax + 16} 80 L{ax + 25} 88 L{ax + 16} 96" '
                     f'stroke="{dim}" stroke-width="4" fill="none"/>')
    svg("pipeline.svg", 960, 176, b)


hero()
palettes()
pipeline()
