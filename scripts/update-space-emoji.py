#!/usr/bin/env python3
"""Generate the offline Space picker catalog from pinned Unicode 16 emoji-test data."""
import argparse
import hashlib
import json
from pathlib import Path

SHA256 = "24f0c534e86cf142e2496953e8f0e46a3e702392911eddcd29c6cced85139697"
GROUPS = {"Smileys & Emotion": "people", "People & Body": "people",
          "Animals & Nature": "nature", "Food & Drink": "food", "Activities": "activities",
          "Travel & Places": "travel", "Objects": "objects", "Symbols": "symbols", "Flags": "flags"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    data = args.source.read_bytes()
    if hashlib.sha256(data).hexdigest() != SHA256:
        parser.error("source is not the pinned Unicode 16.0 emoji-test.txt")
    category = None
    entries = []
    for line in data.decode().splitlines():
        if line.startswith("# group: "):
            category = GROUPS.get(line.removeprefix("# group: "))
        if "; fully-qualified" not in line or category is None:
            continue
        codepoints, description = line.split("#", 1)
        emoji = "".join(chr(int(value, 16)) for value in codepoints.split(";", 1)[0].split())
        name = description.strip().split(" ", 2)[2]
        entries.append({"emoji": emoji, "name": name, "category": category})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("[\n" + ",\n".join(json.dumps(row, ensure_ascii=False) for row in entries) + "\n]\n")
    print(f"Generated {len(entries)} emoji in {len(GROUPS) - 1} picker categories")


if __name__ == "__main__":
    main()
