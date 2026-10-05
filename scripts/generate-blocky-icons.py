#!/usr/bin/env python3
"""Generate editable, Vesta-inspired pixel studies of Vane's existing V."""
import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "AppIcons"


def silhouette():
    """Sample the original V's two quadratic right-arm curves."""
    points = [(272, 258), (512, 806)]
    for start, control, end in [((512, 806), (716, 538), (752, 258)),
                                ((600, 258), (592, 470), (566, 600))]:
        points.append(start)
        for index in range(1, 65):
            t = index / 64
            points.append(tuple((1-t)**2 * start[a] + 2*(1-t)*t * control[a]
                                + t*t * end[a] for a in (0, 1)))
    points.append((424, 258))
    return points


def inside(x, y, points):
    contained = False
    for (ax, ay), (bx, by) in zip(points, points[1:] + points[:1]):
        if (ay > y) != (by > y) and x < (bx-ax) * (y-ay) / (by-ay) + ax:
            contained = not contained
    return contained


def outline(cells, pitch, origin):
    """Cancel shared edges, then trace the union so glass has no internal seams."""
    edges = set()
    for x, y in sorted(cells):
        corners = [(x, y), (x+1, y), (x+1, y+1), (x, y+1)]
        for a, b in zip(corners, corners[1:] + corners[:1]):
            if (b, a) in edges:
                edges.remove((b, a))
            else:
                edges.add((a, b))
    commands = []
    while edges:
        a, b = min(edges)
        start = a
        edges.remove((a, b))
        commands.append(f'M {origin[0]+a[0]*pitch},{origin[1]+a[1]*pitch}')
        while b != start:
            commands.append(f'L {origin[0]+b[0]*pitch},{origin[1]+b[1]*pitch}')
            candidates = sorted(edge for edge in edges if edge[0] == b)
            # Prefer a right turn at diagonal contacts to keep contours separate.
            dx, dy = b[0]-a[0], b[1]-a[1]
            right = (b, (b[0]-dy, b[1]+dx))
            next_edge = right if right in edges else candidates[0]
            edges.remove(next_edge)
            a, b = next_edge
        commands.append('Z')
    return ' '.join(commands)


def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            'viewBox="0 0 1024 1024">' + body + '</svg>\n')


def generate():
    base = json.loads((ROOT / "AppIcon.icon/icon.json").read_text())
    points = silhouette()
    for name, pitch, scattered in [('Pixel', 40, False), ('Block', 64, False),
                                    ('Scatter', 64, True)]:
        origin = (256, 256)
        cells = {(x, y) for y in range(9 if pitch == 64 else 14)
                 for x in range(8 if pitch == 64 else 13)
                 if inside(origin[0]+(x+.5)*pitch, origin[1]+(y+.5)*pitch, points)}
        satellites = []
        if scattered:
            # Displaced chips preserve both arms and the base of the V.
            cells.discard((0, 0))
            cells.discard((6, 2))
            satellites = [(-1, 0, 1), (7, 2, 1), (8, 1, .22),
                          (-1, 1, .16), (6, -1, .20), (5, 9, .14)]
        document = ROOT / 'Experiments' / f'AppIcon-Blocky{name}.icon'
        assets = document / 'Assets'
        assets.mkdir(parents=True, exist_ok=True)
        mark = f'<path d="{outline(cells, pitch, origin)}" fill="#F2EDE4"/>'
        mark += ''.join(f'<rect x="{origin[0]+x*pitch}" y="{origin[1]+y*pitch}" '
                        f'width="{pitch}" height="{pitch}" fill="#F2EDE4" '
                        f'opacity="{opacity}"/>' for x, y, opacity in satellites)
        (assets / 'blocky-v.svg').write_text(svg(mark))
        config = copy.deepcopy(base)
        config['groups'] = config['groups'][:1]
        layer = config['groups'][0]['layers'][0]
        layer['image-name'] = 'blocky-v.svg'
        layer['name'] = f'Blocky {name}'
        (document / 'icon.json').write_text(json.dumps(config, indent=2) + '\n')
        print(document.relative_to(ROOT.parent))


if __name__ == '__main__':
    generate()
