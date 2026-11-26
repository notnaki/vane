"""Enums, constants and events of each stable namespace, from Chromium's schemas.
Usage: python3 -I build_shape.py <dir>: reads <dir>/inventory.json (build_inventory.py) and the
schemas under <dir>/src, writes <dir>/shape.json. ExtensionChromiumShape.swift embeds its
scalar constants, enums and events (devtools and mimeHandler left out)."""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
A = sys.argv[1]
inv = json.load(open(os.path.join(A, "inventory.json")))["namespaces"]

def strip(text):
    out, i, n, s = [], 0, len(text), False
    while i < n:
        c = text[i]
        if s:
            out.append(c)
            if c == "\\": out.append(text[i+1]); i += 2; continue
            if c == '"': s = False
        elif c == '"': s = True; out.append(c)
        elif text.startswith("//", i):
            while i < n and text[i] != "\n": i += 1
            continue
        elif text.startswith("/*", i): i = text.index("*/", i) + 2; continue
        else: out.append(c)
        i += 1
    return "".join(out)

def key(value):  # Chromium's enum key: camelCase → CAMEL_CASE, other separators → _
    v = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", str(value))
    return re.sub(r"[^A-Za-z0-9]", "_", v).upper()

def from_json(path, ns):
    data = json.loads(strip(open(path).read()))
    for entry in data:
        if entry.get("namespace") != ns: continue
        enums, consts, events = {}, {}, [e["name"] for e in entry.get("events", [])]
        for t in entry.get("types", []):
            if "enum" in t:
                enums[t["id"].split(".")[-1]] = {key(v["name"] if isinstance(v, dict) else v): (v["name"] if isinstance(v, dict) else v) for v in t["enum"]}
        for name, p in (entry.get("properties") or {}).items():
            if "value" in p: consts[name] = p["value"]
        return enums, consts, events
    return None

def from_idl(path, ns):
    text = strip(open(path).read())
    enums = {}
    for m in re.finditer(r"enum\s+(\w+)\s*\{([^}]*)\}", text):
        values = [v.strip() for v in m.group(2).split(",")]
        values = [re.sub(r"^\[[^\]]*\]\s*", "", v) for v in values if v]
        enums[m.group(1)] = {key(v): v for v in values if re.fullmatch(r"[\w-]+", v)}
    events = []
    em = re.search(r"interface\s+Events\s*\{(.*?)\n\s*\};", text, re.S)
    if em: events = re.findall(r"static\s+\w+\s+(\w+)\s*\(", em.group(1))
    consts = {}
    pm = re.search(r"interface\s+Properties\s*\{(.*?)\n\s*\};", text, re.S)
    for m in re.finditer(r"const\s+\w+\s+(\w+)\s*=\s*([^;]+);", text):
        v = m.group(2).strip()
        try: consts[m.group(1)] = json.loads(v)
        except ValueError: pass
    return enums, consts, events

# Placeholders in the WebIDL whose real values Chrome sets elsewhere.
OVERRIDES = {"DYNAMIC_RULESET_ID": "_dynamic", "SESSION_RULESET_ID": "_session"}

def from_webidl(path, ns):
    text = strip(open(path).read())
    enums = {}
    for m in re.finditer(r"\benum\s+(\w+)\s*\{([^}]*)\}", text):
        values = re.findall(r'"([^"]+)"', m.group(2))
        enums[m.group(1)] = {key(v): v for v in values}
    events = re.findall(r"static\s+attribute\s+\w+\s+(on\w+)\s*;", text)
    consts = {}
    for m in re.finditer(r"const\s+\w+\s+(\w+)\s*=\s*([^;]+);", text):
        if m.group(1) in OVERRIDES: consts[m.group(1)] = OVERRIDES[m.group(1)]; continue
        try: consts[m.group(1)] = json.loads(m.group(2).strip())
        except ValueError: pass
    return enums, consts, events

shape = {}
for n in inv:
    ns, schema = n["namespace"], n.get("schema")
    if not schema: continue
    path = os.path.join(A, "src", schema)
    if not os.path.exists(path): continue
    try: got = from_webidl(path, ns) if path.endswith(".webidl") else from_idl(path, ns) if path.endswith(".idl") else from_json(path, ns)
    except ValueError as error: print("skip", ns, path, error); continue
    if not got: continue
    enums, consts, events = got
    names = {m["name"] for m in n["members"]}
    perm = n.get("permission")
    shape[ns] = {"permission": perm if isinstance(perm, list) else ([perm] if perm else []),
                 "enums": {k: v for k, v in enums.items() if v},
                 "constants": consts,
                 "events": [e for e in events if e in names]}
json.dump(shape, open(os.path.join(A, "shape.json"), "w"), indent=1, sort_keys=True)
print(len(shape), "namespaces;", sum(len(v["enums"]) for v in shape.values()), "enums;", sum(len(v["constants"]) for v in shape.values()), "constants;", sum(len(v["events"]) for v in shape.values()), "events")

# The form ExtensionChromiumShape.swift embeds: scalar constants only (others are setting
# descriptors), no devtools or mimeHandler (their pages are not Vane's), empty parts dropped.
compact = {}
for ns, v in sorted(shape.items()):
    if ns.startswith("devtools") or ns == "mimeHandler": continue
    part = {"enums": v["enums"], "constants": {k: c for k, c in v["constants"].items() if isinstance(c, (int, float, str, bool))},
            "events": v["events"]}
    part = {k: x for k, x in part.items() if x}
    if part: compact[ns] = part
open(os.path.join(A, "shape-compact.json"), "w").write(json.dumps(compact, separators=(",", ":"), sort_keys=True))
