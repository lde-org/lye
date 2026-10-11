#!/usr/bin/env python3
"""Draw what the language server says a file should look like.

`tools/semantic-view.mjs` prints the semantic tokens as a terminal draws them; this turns the same
answer into an image, so a change to the colouring can be looked at rather than read.

    JSON=1 node tools/semantic-view.mjs FILE > /tmp/tokens.json
    python3 tools/semantic-shot.py FILE /tmp/tokens.json /tmp/shot.png [LINES]
"""
import json
import sys

from PIL import Image, ImageDraw, ImageFont

COLOUR = {
    "keyword": (203, 166, 247), "string": (166, 227, 161), "number": (250, 179, 135),
    "comment": (108, 112, 134), "operator": (137, 180, 250), "variable": (205, 214, 244),
    "function": (137, 220, 235), "parameter": (249, 226, 175), "type": (249, 226, 175),
    "namespace": (180, 190, 254), "class": (249, 226, 175), "property": (148, 226, 213),
    "method": (245, 194, 231), "regexp": (243, 139, 168),
}
FONT = "/usr/share/fonts/adwaita-mono-fonts/AdwaitaMono-Regular.ttf"


def main():
    path, tokens_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
    height = int(sys.argv[4]) if len(sys.argv) > 4 else 40
    lines = open(path).read().split("\n")[:height]
    kind = {}
    for token in json.load(open(tokens_path)):
        for column in range(token["start"], token["start"] + token["length"]):
            kind[(token["line"], column)] = token["kind"]

    font = ImageFont.truetype(FONT, 19)
    width = font.getlength("M")
    image = Image.new("RGB", (int(width * 74) + 32, 23 * len(lines) + 26), (30, 30, 46))
    draw = ImageDraw.Draw(image)
    for row, text in enumerate(lines):
        for column, char in enumerate(text):
            draw.text((16 + column * width, 13 + row * 23), char, font=font,
                      fill=COLOUR.get(kind.get((row, column)), (88, 91, 112)))
    image.save(out)
    print(f"{out} {image.size[0]}x{image.size[1]}")


main()
