#!/usr/bin/env python3
"""Regenerate Vane's editable material treatments for Icon Composer."""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "AppIcons"
FLUTE_PITCH = 64
FLUTED_PALETTES = {
    "Cool": {
        "bloom": ["#7197D6", "#9DAFD2", "#C2D9EE"],
        "light-mark": ["#35467C", "#5367A0", "#334476"],
        "dark-mark": ["#C6DDF5", "#9EB9E9", "#DBE7F6"],
        "light-halo": ["#8FAAD8", "#A9BCE2", "#D8E5F3"],
        "dark-halo": ["#93B9F0", "#B5CCEE", "#DFEBF8"],
        "glint": "#B6CBE9",
    },
    "Silver": {
        "bloom": ["#ADB8C6", "#CDD3DD", "#FFFFFF"],
        "light-mark": ["#36435E", "#52617E", "#35435F"],
        "dark-mark": ["#DFE6EF", "#BAC7D9", "#F5F7FA"],
        "light-halo": ["#B3BDCC", "#D0D7E2", "#FFFFFF"],
        "dark-halo": ["#D2DBE8", "#E5EAF2", "#FFFFFF"],
        "glint": "#DAE0E8",
    },
    "Champagne": {
        "bloom": ["#C6B799", "#E1CEAB", "#FFF1D5"],
        "light-mark": ["#3E435D", "#656883", "#3D435D"],
        "dark-mark": ["#F0E4D0", "#D8CAA9", "#FFF4DE"],
        "light-halo": ["#CFC1A7", "#E6D5B8", "#FFF4DF"],
        "dark-halo": ["#E4CFAB", "#F0DFC2", "#FFF4DF"],
        "glint": "#EADCC4",
    },
}
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


def fluted_mark(dark=False, outline=False, palette="Cool"):
    """Each flute refracts five narrow bands; overlapping vector samples soften edges."""
    colors = FLUTED_PALETTES[palette]["dark-mark" if dark else "light-mark"]
    mark = path(fill="none" if outline else "url(#mark)",
                extra=('stroke="url(#mark)" stroke-width="34" stroke-linejoin="round" ' if outline else '') +
                'transform="translate(512,512) scale(1.15) translate(-512,-512)"')
    definitions = [gradient("mark", colors), mark.replace('<path ', '<path id="mark-shape" ')]
    bands = []
    pitch = FLUTE_PITCH
    for rib in range(math.ceil(1024 / pitch)):
        for band in range(5):
            x = rib * pitch + band * pitch / 5
            clip = f"lens-{rib}-{band}"
            definitions.append(f'<clipPath id="{clip}"><rect x="{x:.2f}" y="0" '
                               f'width="{pitch / 5 + .12:.2f}" height="1024"/></clipPath>')
            # A cylindrical lens displaces the image most on its shoulders.
            shift = 9 * math.sin((band + .5) / 5 * math.tau)
            samples = ''.join(f'<use href="#mark-shape" transform="translate({shift + blur:.2f},0)" '
                              f'opacity="{opacity}"/>' for blur, opacity in
                              [(-6, .06), (-3, .10), (0, .64), (3, .10), (6, .06)])
            bands.append(f'<g clip-path="url(#{clip})">{samples}</g>')
    return svg(''.join(bands), ''.join(definitions))


def fluted_pane(dark=False, palette="Cool"):
    # Wide cylindrical ribs: bright shoulder, clear center, soft shaded edge, hairline glint.
    definitions = ('<linearGradient id="rib"><stop stop-color="#FFFFFF" stop-opacity=".40"/>'
                   '<stop offset=".18" stop-color="#FFFFFF" stop-opacity=".20"/>'
                   '<stop offset=".43" stop-color="#F2EDE4" stop-opacity=".08"/>'
                   '<stop offset=".78" stop-color="#65708E" stop-opacity=".17"/>'
                   '<stop offset=".91" stop-color="#FFFFFF" stop-opacity=".36"/>'
                   '<stop offset="1" stop-color="#FFFFFF" stop-opacity=".56"/></linearGradient>')
    if dark:
        definitions = ('<linearGradient id="rib"><stop stop-color="#A6B7E6" stop-opacity=".19"/>'
                       '<stop offset=".18" stop-color="#91A6D8" stop-opacity=".06"/>'
                       '<stop offset=".43" stop-color="#172039" stop-opacity=".04"/>'
                       '<stop offset=".78" stop-color="#020611" stop-opacity=".27"/>'
                       '<stop offset=".91" stop-color="#8196D4" stop-opacity=".12"/>'
                       '<stop offset="1" stop-color="#B4C4EF" stop-opacity=".25"/></linearGradient>')
    glint = FLUTED_PALETTES[palette]["glint"] if dark else "#FFFFFF"
    if dark:
        # Neutral and warm studies tint the glass shoulders as well as the bloom.
        for tint in ["#A6B7E6", "#91A6D8", "#8196D4", "#B4C4EF"]:
            definitions = definitions.replace(tint, glint)
    glint_opacity = ".23" if dark else ".54"
    ribs = ''.join(f'<rect x="{x}" width="{FLUTE_PITCH}" height="1024" fill="url(#rib)"/>'
                   f'<rect x="{x+FLUTE_PITCH-1.5}" width="1.5" height="1024" fill="{glint}" opacity="{glint_opacity}"/>'
                   for x in range(0, 1024, FLUTE_PITCH))
    return svg(ribs, definitions)


def fluted_bloom(dark=False, palette="Cool"):
    """Broad colored light remains visible between ribs at Dock sizes."""
    colors = FLUTED_PALETTES[palette]["bloom"]
    pools = [("left", .30, .43, .49, colors[0], .50 if dark else .42),
             ("right", .60, .46, .46, colors[1], .42 if dark else .32),
             ("base", .57, .70, .42, colors[2], .30 if dark else .38)]
    definitions = ''.join(
        f'<radialGradient id="{name}" cx="{cx}" cy="{cy}" r="{radius}">'
        f'<stop stop-color="{color}" stop-opacity="{opacity}"/>'
        f'<stop offset=".42" stop-color="{color}" stop-opacity="{opacity * .64:.3f}"/>'
        f'<stop offset="1" stop-color="{color}" stop-opacity="0"/></radialGradient>'
        for name, cx, cy, radius, color, opacity in pools)
    return svg(''.join(f'<rect width="1024" height="1024" fill="url(#{name})"/>'
                       for name, *_ in pools), definitions)


def fluted_halo(dark=False, palette="Cool"):
    colors = FLUTED_PALETTES[palette]["dark-halo" if dark else "light-halo"]
    return svg(''.join(path(extra=f'stroke="url(#halo)" stroke-width="{width}" '
                                  f'stroke-linejoin="round" opacity="{opacity}" '
                                  'transform="translate(512,512) scale(1.15) translate(-512,-512)"')
                       for width, opacity in [(180, .025), (128, .04), (80, .07), (44, .12)]),
               gradient("halo", colors))


production_finishes = ["Candy", "Neon", "FlutedGlass", "FlutedGlassDark", "Schoolbook", "Luminous"]
fluted_studies = ["FlutedGlassOutline", "FlutedGlassDarkOutline"] + [
    "FlutedGlass" + tone + palette + style
    for palette in ["Silver", "Champagne"]
    for tone in ["", "Dark"] for style in ["", "Outline"]]
for finish in production_finishes + fluted_studies:
    # Palette and outline studies stay outside production until visually approved.
    parent = ROOT if finish in production_finishes else ROOT / "Experiments"
    folder = parent / ("AppIcon-" + finish + ".icon")
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
    elif finish.startswith("FlutedGlass"):
        dark = "Dark" in finish
        outline = finish.endswith("Outline")
        palette = next((name for name in ["Silver", "Champagne"] if name in finish), "Cool")
        backgrounds = {"Cool": "srgb:0.950,0.955,0.965,1", "Silver": "srgb:0.960,0.960,0.960,1",
                       "Champagne": "srgb:0.965,0.950,0.920,1"}
        config["fill"] = {"solid": "srgb:0.047,0.061,0.112,1" if dark else backgrounds[palette]}
        content["refracted-v"] = fluted_mark(dark, outline=outline, palette=palette)
        content["fluted-pane"] = fluted_pane(dark, palette=palette)
        content["diffused-light"] = fluted_bloom(dark, palette=palette)
        content["logo-halo"] = fluted_halo(dark, palette=palette)
        pane = group("fluted-pane", True, .06)
        # These properties are saved by Icon Composer's native material controls.
        pane["blur-material"] = .025 if outline else .07
        pane["refractivity"] = {"enabled": True, "strength": .45, "depth": .20}
        pane["translucency"] = {"enabled": True, "value": .78}
        config["features"] = ["refractivity"]
        config["groups"] = [pane, group("refracted-v", False, 0), group("logo-halo", False, 0),
                            group("diffused-light", False, 0)]
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
