#!/usr/bin/env python3
"""Regenerate rounded, overlapping V ribbons as editable Icon Composer layers."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "AppIcons"
RIBBONS = {
    "left": ("M 330,302 L 512,718", 130),
    "right": ("M 512,718 Q 666,529 694,302", 130),
    "swoosh": ("M 284,480 C 370,612 574,634 724,470", 82),
}
PALETTES = {
    "Candy": {"left": ["#F2EDE4", "#A5B2DC"], "right": ["#6E7DD2", "#DCE0EF"],
              "swoosh": ["#9CAAD7", "#F2EDE4"]},
    "FlutedGlass": {"left": ["#F2EDE4", "#9DAACF"], "right": ["#BBC5E3", "#F2EDE4"],
                    "swoosh": ["#6E7DD2", "#CCD4E9"]},
    "Schoolbook": {"left": ["#6E7DD2", "#6E7DD2"], "right": ["#333B62", "#333B62"],
                   "swoosh": ["#A6B2D4", "#A6B2D4"]},
    "Luminous": {"left": ["#F2EDE4", "#6E7DD2"], "right": ["#6E7DD2", "#F2EDE4"],
                 "swoosh": ["#A5B2DC", "#6E7DD2"]},
}

def svg(body, definitions=""):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            'viewBox="0 0 1024 1024"><defs>' + definitions + '</defs>' + body + '</svg>\n')

def stroke(path, width, color, extra=""):
    return (f'<path d="{path}" fill="none" stroke="{color}" stroke-width="{width}" '
            f'stroke-linecap="round" stroke-linejoin="round" {extra}/>')

def layer(name, glass=True):
    return {"blend-mode": "normal", "fill": "none", "glass": glass, "hidden": False,
            "image-name": name + ".svg", "name": name,
            "position": {"scale": 1.0, "translation-in-points": [0, 0]}}

def group(name, glass=True, shadow=0.25):
    return {"layers": [layer(name, glass)], "shadow": {"kind": "neutral", "opacity": shadow},
            "translucency": {"enabled": False, "value": 0.25}}

for finish in ["Candy", "Neon", "FlutedGlass", "Schoolbook", "Luminous"]:
    folder = ROOT / ("AppIcon-" + finish + ".icon")
    assets = folder / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    # Only these generated documents are rewritten; Normal and Galaxy are independent.
    for old in assets.glob("*.svg"):
        old.unlink()
    config = {"fill": {"automatic-gradient": "display-p3:0.09239,0.10159,0.19321,1.00000"},
              "groups": [], "supported-platforms": {"squares": "shared"}}
    if finish == "Candy":
        config["fill"] = {"automatic-gradient": "srgb:0.65,0.70,0.82,1"}
    elif finish == "FlutedGlass":
        config["fill"] = {"automatic-gradient": "srgb:0.31,0.34,0.47,1"}
    elif finish == "Schoolbook":
        config["fill"] = {"solid": "srgb:0.949,0.929,0.894,1"}
    for name in ["swoosh", "right", "left"]:  # front to back in Icon Composer
        path, width = RIBBONS[name]
        if finish == "Neon":
            silhouette = stroke(path, width, "white") + stroke(path, width - 14, "black")
            defs = f'<mask id="tube">{silhouette}</mask>'
            body = '<rect width="1024" height="1024" fill="#F2EDE4" mask="url(#tube)"/>'
        else:
            colors = PALETTES[finish][name]
            defs = ('<linearGradient id="ribbon" x1="280" y1="280" x2="730" y2="740" '
                    'gradientUnits="userSpaceOnUse">'
                    f'<stop stop-color="{colors[0]}"/><stop offset="1" stop-color="{colors[1]}"/>'
                    '</linearGradient>')
            border = stroke(path, width + 22, "#FFFCF6") if finish == "Schoolbook" else ""
            body = border + stroke(path, width, "url(#ribbon)")
        (assets / (name + ".svg")).write_text(svg(body, defs))
        config["groups"].append(group(name, glass=finish != "Schoolbook",
                                      shadow=0.16 if finish == "Schoolbook" else 0.28))
    if finish == "Neon":
        halos, masks = [], []
        for index, (spread, opacity) in enumerate([(54, .06), (30, .12), (14, .28)]):
            mask = ''.join(stroke(path, width + spread, "white") for path, width in RIBBONS.values())
            mask += ''.join(stroke(path, width - spread, "black") for path, width in RIBBONS.values())
            masks.append(f'<mask id="halo{index}">{mask}</mask>')
            halos.append(f'<rect width="1024" height="1024" fill="#6E7DD2" '
                         f'opacity="{opacity}" mask="url(#halo{index})"/>')
        (assets / "halo.svg").write_text(svg(''.join(halos), ''.join(masks)))
        config["groups"].append(group("halo", False, 0))
    if finish == "FlutedGlass":
        ribs = ''.join(f'<rect x="{x}" width="5" height="1024" fill="#F2EDE4" opacity=".12"/>'
                       f'<rect x="{x+6}" width="3" height="1024" fill="#151A32" opacity=".12"/>'
                       for x in range(0, 1024, 14))
        (assets / "fluting.svg").write_text(svg(ribs))
        config["groups"].insert(0, group("fluting", False, 0))
    (folder / "icon.json").write_text(json.dumps(config, indent=2) + '\n')
