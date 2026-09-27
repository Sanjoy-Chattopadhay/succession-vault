"""Render a captured terminal log as a PNG (terminal style) for the evidence folder.

Usage: python scripts/render_log.py <log file> <png file> [max lines per image]
Long logs are split into several images (<png>-1.png, <png>-2.png, ...).
The image is drawn from the real log text; it is not a screen capture.
"""
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FONT = "C:/Windows/Fonts/consola.ttf"
BG, FG, DIM, OK, BAD, HEAD = (24, 26, 33), (220, 223, 228), (130, 137, 151), (126, 211, 128), (240, 113, 120), (97, 175, 239)
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def colour(line: str):
    if line.startswith("$ ") or line.startswith("# "):
        return HEAD
    if re.search(r"\b(FAIL|Error|error|INVALID|MISMATCH|reverted)\b", line) and "0 failed" not in line:
        return BAD
    if re.search(r"\b(PASS|ok\.|VALID|MATCH|SUCCESSFUL|passed)\b", line):
        return OK
    if line.strip().startswith(("│", "├", "└", "╭", "╰", "|")):
        return DIM
    return FG


def render(lines, out: Path, title: str):
    font = ImageFont.truetype(FONT, 15)
    cw, lh = font.getbbox("M")[2], 19
    width = max(80, min(170, max((len(l) for l in lines), default=80)))
    img = Image.new("RGB", (width * cw + 40, (len(lines) + 2) * lh + 40), BG)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, img.width, lh + 16], fill=(40, 44, 52))
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse([14 + i * 20, 9, 26 + i * 20, 21], fill=c)
    d.text((90, 8), title, font=font, fill=DIM)
    y = lh + 26
    for line in lines:
        d.text((20, y), line[:width], font=font, fill=colour(line))
        y += lh
    img.save(out)


def main():
    log, png = Path(sys.argv[1]), Path(sys.argv[2])
    per = int(sys.argv[3]) if len(sys.argv) > 3 else 70
    text = ANSI.sub("", log.read_text(encoding="utf-8", errors="replace")).replace("\t", "    ")
    lines = text.rstrip("\n").split("\n")
    chunks = [lines[i:i + per] for i in range(0, len(lines), per)] or [[]]
    png.parent.mkdir(parents=True, exist_ok=True)
    for k, chunk in enumerate(chunks, 1):
        out = png if len(chunks) == 1 else png.with_name(f"{png.stem}-{k}{png.suffix}")
        render(chunk, out, f"{log.name}  ({k}/{len(chunks)})")
        print(out)


if __name__ == "__main__":
    main()
