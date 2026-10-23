#!/usr/bin/env python3
"""Count work in exact production Swift routines, without timing thresholds or app state.

Run: python3 Tests/Probes/native_page_input_bounds.py
The source instrumentation only increments counters; the production algorithm is unchanged.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def function(source, name):
    start = source.index(name)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


preview = (ROOT / "Sources/Vane/Previews.swift").read_text()
media = (ROOT / "Sources/Vane/MediaPlayer.swift").read_text()
entity = function(preview, "static func unescape(").replace("static func", "func", 1)
# Count actual examined suffix elements, including on the old unbounded algorithm.
entity = entity.replace('firstIndex(of: ";")',
                        'firstIndex(where: { visits += 1; return $0 == ";" })')
clean = function(media, "static func clean(").replace("static func", "func", 1)
loop = next(line for line in clean.splitlines() if "for u in raw.unicodeScalars" in line)
clean = clean.replace(loop, loop + "\n visits += 1", 1)
probes = {
    "entities": "import Foundation\nvar visits=0\n" + entity + '''
let malformed=String(repeating:"&",count:2000)
precondition(unescape(malformed)==malformed)
precondition(visits<=2000*12,"entity parser exceeded bounded lookahead")
print("entities: \\(visits) examined characters for 2000 ampersands")
''',
    "media": "import Foundation\nlet maxText=200\nlet maxRawTextBytes=8192\nvar visits=0\n" + clean + '''
precondition(clean(String(repeating:" ",count:100000)+"late").isEmpty)
precondition(visits<=8192,"sanitizer scanned beyond its raw-input budget")
print("media: \\(visits) examined scalars for 100000 leading spaces")
''',
}
with tempfile.TemporaryDirectory(prefix="vane-native-input-probe-") as temporary:
    directory = Path(temporary)
    for name, source in probes.items():
        swift = directory / (name + ".swift")
        binary = directory / name
        swift.write_text(source)
        subprocess.run(["swiftc", "-O", str(swift), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
