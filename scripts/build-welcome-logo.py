#!/usr/bin/env python3
"""Export the shipped SVG's exact V path to a tightly cropped vector PDF for AppKit."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / "AppIcons/AppIcon.icon/Assets/vane-v.svg"
path = ET.parse(source).getroot().find("{http://www.w3.org/2000/svg}path")
tokens = iter(re.findall(r"[MLQZ]|-?\d+(?:\.\d+)?", path.attrib["d"]))
commands = []
x = y = 0.0
for token in tokens:
    if token == "M" or token == "L":
        x, y = float(next(tokens)), float(next(tokens))
        commands.append(f"{x:g} {y:g} {'m' if token == 'M' else 'l'}")
    elif token == "Q":
        cx, cy, ex, ey = (float(next(tokens)) for _ in range(4))
        commands.append(f"{x + (cx-x)*2/3:g} {y + (cy-y)*2/3:g} "
                        f"{ex + (cx-ex)*2/3:g} {ey + (cy-ey)*2/3:g} {ex:g} {ey:g} c")
        x, y = ex, ey
    elif token == "Z":
        commands.append("h")
    else:
        raise ValueError(f"Unsupported SVG command: {token}")
fill = path.attrib["fill"].lstrip("#")
rgb = " ".join(f"{int(fill[i:i+2], 16)/255:.6f}" for i in (0, 2, 4))
stream = (f"q\n1 0 0 -1 -272 806 cm\n{rgb} rg\n" + "\n".join(commands) + "\nf\nQ\n").encode()
objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
           b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
           b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 480 548] /Resources << >> /Contents 4 0 R >>",
           f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"endstream"]
output = bytearray(b"%PDF-1.4\n")
offsets = [0]
for index, obj in enumerate(objects, 1):
    offsets.append(len(output))
    output.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
xref = len(output)
output.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
for offset in offsets[1:]:
    output.extend(f"{offset:010} 00000 n \n".encode())
output.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
(ROOT / "Sources/Vane/WelcomeAssets/VaneLogo.pdf").write_bytes(output)
print("Exported the original Vane V to WelcomeAssets/VaneLogo.pdf")
