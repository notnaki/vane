#!/usr/bin/env python3
"""Regenerate Vane's editable material treatments for Icon Composer."""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "AppIcons"
# Rounded corners retain the distinctive curved right arm and tapered Vane silhouette.
V = ("M 289,258 H 410 Q 420,258 424,270 L 551,574 Q 560,599 568,576 "
     "Q 590,444 596,278 Q 596,258 616,258 H 728 Q 752,258 748,282 "
     "Q 708,553 531,785 Q 512,810 501,785 L 270,285 Q 260,258 289,258 Z")
FOLD = ("M 616,258 H 728 Q 752,258 748,282 Q 708,553 531,785 "
        "Q 512,810 501,785 L 550,605 Q 583,511 596,278 Q 596,258 616,258 Z")


def svg(body, definitions=""):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            'viewBox="0 0 1024 1024"><defs>' + definitions + '</defs>' + body + '</svg>\n')


def path(shape=V, fill="none", extra=""):
    return f'<path d="{shape}" fill="{fill}" {extra}/>'


def gradient(name, colors):
    stops = ''.join(f'<stop offset="{i / (len(colors) - 1):.3f}" stop-color="{color}"/>'
                    for i, color in enumerate(colors))
    return (f'<linearGradient id="{name}" x1="280" y1="280" x2="730" y2="790" '
            f'gradientUnits="userSpaceOnUse">{stops}</linearGradient>')


def group(name, glass=True, shadow=0.3):
    return {"layers": [{"blend-mode": "normal", "fill": "none", "glass": glass,
                        "hidden": False, "image-name": name + ".svg", "name": name,
                        "position": {"scale": 1.0, "translation-in-points": [0, 0]}}],
            "shadow": {"kind": "neutral", "opacity": shadow},
            "translucency": {"enabled": False, "value": 0.25}}


def fluted_mark():
    """Each flute refracts five narrow bands; overlapping vector samples soften edges."""
    definitions = [gradient("mark", ["#333B62", "#6E7DD2", "#273052"]),
                   path(fill="url(#mark)", extra='transform="translate(512,512) scale(1.15) translate(-512,-512)"').replace('<path ', '<path id="mark-shape" ')]
    bands = []
    pitch = 24
    for rib in range(43):
        for band in range(5):
            x = rib * pitch + band * pitch / 5
            clip = f"lens-{rib}-{band}"
            definitions.append(f'<clipPath id="{clip}"><rect x="{x:.2f}" y="0" '
                               f'width="{pitch / 5 + .12:.2f}" height="1024"/></clipPath>')
            # A cylindrical lens displaces the image most on its shoulders.
            shift = 13 * math.sin((band + .5) / 5 * math.tau)
            samples = ''.join(f'<use href="#mark-shape" transform="translate({shift + blur:.2f},0)" '
                              f'opacity="{opacity}"/>' for blur, opacity in
                              [(-12, .08), (-6, .12), (0, .46), (6, .12), (12, .08)])
            bands.append(f'<g clip-path="url(#{clip})">{samples}</g>')
    return svg(''.join(bands), ''.join(definitions))


def fluted_pane():
    # Wide cylindrical ribs: bright shoulder, clear center, soft shaded edge, hairline glint.
    definitions = ('<linearGradient id="rib"><stop stop-color="#FFFFFF" stop-opacity=".60"/>'
                   '<stop offset=".18" stop-color="#FFFFFF" stop-opacity=".34"/>'
                   '<stop offset=".43" stop-color="#F2EDE4" stop-opacity=".08"/>'
                   '<stop offset=".78" stop-color="#65708E" stop-opacity=".13"/>'
                   '<stop offset=".91" stop-color="#FFFFFF" stop-opacity=".47"/>'
                   '<stop offset="1" stop-color="#FFFFFF" stop-opacity=".76"/></linearGradient>')
    ribs = ''.join(f'<rect x="{x}" width="24" height="1024" fill="url(#rib)"/>'
                   f'<rect x="{x+22.5}" width="1.5" height="1024" fill="#FFFFFF" opacity=".68"/>'
                   for x in range(0, 1024, 24))
    return svg(ribs, definitions)


for finish in ["Candy", "Neon", "FlutedGlass", "Schoolbook", "Luminous"]:
    folder = ROOT / ("AppIcon-" + finish + ".icon")
    assets = folder / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for old in assets.glob("*.svg"):
        old.unlink()
    config = {"fill": {"automatic-gradient": "display-p3:0.09239,0.10159,0.19321,1.00000"},
              "groups": [], "supported-platforms": {"squares": "shared"}}
    content = {}
    if finish in ["Candy", "Luminous"]:
        candy = finish == "Candy"
        if candy:
            config["fill"] = {"automatic-gradient": "srgb:0.66,0.71,0.84,1"}
        content["body"] = svg(path(fill="url(#body)"), gradient("body",
            ["#F2EDE4", "#BCC8E8", "#8093D3"] if candy else ["#BCC8F2", "#6E7DD2", "#F2EDE4"]))
        content["fold"] = svg(path(FOLD, "url(#fold)"), gradient("fold",
            ["#536AC4", "#879BDF", "#DFE5F6"] if candy else ["#495CAA", "#91A6F0", "#F2EDE4"]))
        if candy:
            content["rim"] = svg(path(extra='stroke="#FFFCF6" stroke-width="16" stroke-linejoin="round" opacity=".9"'))
            config["groups"].append(group("rim", False, 0))
        config["groups"] += [group("fold", True, .30), group("body", True, .40)]
    elif finish == "Neon":
        content["tube"] = svg(path(extra='stroke="#ECF0FF" stroke-width="14" stroke-linejoin="round"'))
        content["halo"] = svg(''.join(path(extra=f'stroke="#8FA7FF" stroke-width="{width}" '
                                                       f'stroke-linejoin="round" opacity="{opacity}"')
                                          for width, opacity in [(88, .025), (60, .05), (38, .12), (22, .35)]))
        content["ambient"] = svg('<rect width="1024" height="1024" fill="url(#bloom)"/>',
            '<radialGradient id="bloom" cx=".5" cy=".80" r=".62">'
            '<stop stop-color="#6E7DD2" stop-opacity=".45"/>'
            '<stop offset="1" stop-color="#6E7DD2" stop-opacity="0"/></radialGradient>')
        config["groups"] = [group("tube", False, 0), group("halo", False, 0), group("ambient", False, 0)]
    elif finish == "FlutedGlass":
        config["fill"] = {"solid": "srgb:0.93,0.925,0.905,1"}
        content["refracted-v"] = fluted_mark()
        content["fluted-pane"] = fluted_pane()
        content["diffused-light"] = svg('<rect width="1024" height="1024" fill="url(#light)"/>',
            '<radialGradient id="light" cx=".37" cy=".49" r=".54">'
            '<stop stop-color="#6E7DD2" stop-opacity=".20"/>'
            '<stop offset="1" stop-color="#6E7DD2" stop-opacity="0"/></radialGradient>')
        pane = group("fluted-pane", True, .12)
        # These properties are saved by Icon Composer's native material controls.
        pane["blur-material"] = .22
        pane["refractivity"] = {"enabled": True, "strength": .65, "depth": .25}
        pane["translucency"] = {"enabled": True, "value": .65}
        config["features"] = ["refractivity"]
        config["groups"] = [pane, group("refracted-v", False, 0), group("diffused-light", False, 0)]
    elif finish == "Schoolbook":
        config["fill"] = {"solid": "srgb:0.949,0.929,0.894,1"}
        content["sticker"] = svg(path(fill="#6E7DD2", extra='stroke="#FFFCF6" stroke-width="24" stroke-linejoin="round"') +
            '<g clip-path="url(#inside)"><path d="M 260,488 L 780,390 L 780,596 L 260,725 Z" fill="#A6B2D4"/>'
            '<path d="M 416,640 L 760,570 L 540,820 Z" fill="#333B62"/></g>',
            f'<clipPath id="inside">{path(fill="white")}</clipPath>')
        config["groups"] = [group("sticker", False, .30)]
    for material_group in config["groups"]:
        artwork = material_group["layers"][0]
        if artwork["name"] in {"body", "fold", "rim", "tube", "halo", "sticker"}:
            artwork["position"]["scale"] = 1.15
    for name, image in content.items():
        (assets / (name + ".svg")).write_text(image)
    (folder / "icon.json").write_text(json.dumps(config, indent=2) + '\n')
