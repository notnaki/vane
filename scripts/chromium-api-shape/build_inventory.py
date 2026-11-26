"""Build inventory.json / skipped.json from Chromium extension API schemas.

Usage: python3 -I build_inventory.py <src dir> <out dir> <chromium tag>
"""
import json, os, re, sys

SRC, OUT, TAG = sys.argv[1], sys.argv[2], sys.argv[3]
DIRS = ["chrome_common_extensions_api", "extensions_common_api"]


def strip_comments(text):
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\":
                out.append(text[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True; out.append(c)
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2; continue
        else:
            out.append(c)
        i += 1
    return "".join(out)


def load_json(path):
    return json.loads(strip_comments(open(path).read()))


# ---------- features ----------
def load_features(name):
    merged = {}
    for d in DIRS:
        p = os.path.join(SRC, d, name)
        if os.path.exists(p):
            for k, v in load_json(p).items():
                merged.setdefault(k, []).extend(v if isinstance(v, list) else [v])
    return merged


API = load_features("_api_features.json")
PERM = load_features("_permission_features.json")
MANIFEST = load_features("_manifest_features.json")
DEP_SOURCES = {"permission": PERM, "manifest": MANIFEST, "api": API}


def resolve_entries(entries, seen=()):
    """Expand each entry with fields inherited from its dependencies."""
    result = []
    for e in entries:
        e = dict(e)
        for dep in e.get("dependencies", []):
            kind, _, key = dep.partition(":")
            if dep in seen:
                continue
            dents = resolve_entries(DEP_SOURCES.get(kind, {}).get(key, []), seen + (dep,))
            if not dents:
                continue
            # choose the most permissive dependency entry
            d = sorted(dents, key=lambda x: (x.get("channel", "stable") != "stable", bool(x.get("allowlist")), bool(x.get("location"))))[0]
            for f in ("channel", "command_line_switch", "feature_flag", "platforms", "extension_types", "max_manifest_version", "min_manifest_version", "allowlist", "location", "internal"):
                if f in d and f not in e:
                    e[f] = d[f]
        result.append(e)
    return result


def judge(entries):
    """Return (ok, reason, info) for an API feature's entries."""
    entries = resolve_entries(entries)
    if not entries:
        return None, "no feature entry", {}
    reasons, good = [], []
    for e in entries:
        ctx = e.get("contexts", [])
        ctx = {"privileged_extension", "unprivileged_extension", "content_script"} if ctx == "all" else set(ctx)
        if not ctx & {"privileged_extension", "unprivileged_extension", "content_script", "offscreen_extension", "user_script"}:
            reasons.append("webui/web-page only"); continue
        if e.get("channel", "stable") != "stable":
            reasons.append("channel " + e["channel"]); continue
        if e.get("command_line_switch"):
            reasons.append("needs command-line switch --" + e["command_line_switch"]); continue
        if e.get("internal"):
            reasons.append("internal"); continue
        if e.get("allowlist"):
            reasons.append("allowlisted extensions only"); continue
        if e.get("location"):
            reasons.append("location " + e["location"]); continue
        plats = e.get("platforms")
        if plats and "mac" not in plats:
            reasons.append("platforms " + ",".join(plats)); continue
        types = e.get("extension_types")
        if types and types != "all" and "extension" not in types:
            reasons.append("extension types " + ",".join(types)); continue
        if e.get("max_manifest_version") == 2:
            reasons.append("MV2 only"); continue
        good.append(e)
    if not good:
        return False, "; ".join(sorted(set(reasons))), {}
    perms = sorted({d.split(":", 1)[1] for e in good for d in e.get("dependencies", []) if d.startswith("permission:")})
    manifest = sorted({d.split(":", 1)[1] for e in good for d in e.get("dependencies", []) if d.startswith("manifest:")})
    ctx = set()
    for e in good:
        c = e.get("contexts", [])
        c = {"privileged_extension", "unprivileged_extension", "content_script"} if c == "all" else set(c)
        if c & {"privileged_extension", "offscreen_extension"}:
            ctx |= {"worker", "page"}
        if "unprivileged_extension" in c:
            ctx |= {"page"}
        if "content_script" in c:
            ctx.add("content")
    flags = sorted({e["feature_flag"] for e in good if e.get("feature_flag")}) if all(e.get("feature_flag") for e in good) else []
    return True, "", {"flags": flags, "permissions": perms, "manifest": manifest, "contexts": sorted(ctx)}


def feature_for(ns):
    """Feature entries for ns, walking up the dotted path."""
    parts = ns.split(".")
    for i in range(len(parts), 0, -1):
        key = ".".join(parts[:i])
        if key in API:
            return key, API[key]
    return None, []


# ---------- schema parsing ----------
namespaces = {}  # name -> {members:{name:kind}, nodoc_members:set, nodoc:bool, file}


def add(ns, file, nodoc=False):
    return namespaces.setdefault(ns, {"members": {}, "nodoc_members": set(), "nodoc": nodoc, "file": file})


def parse_json_schema(path):
    data = load_json(path)
    for ns in data if isinstance(data, list) else [data]:
        name = ns.get("namespace")
        if not name or ns.get("internal"):
            continue
        rec = add(name, os.path.relpath(path, SRC), bool(ns.get("nodoc")))
        rec["platforms"] = ns.get("platforms")
        for f in ns.get("functions", []):
            rec["members"][f["name"]] = "function"
            if f.get("nodoc") or f.get("deprecated") and False:
                rec["nodoc_members"].add(f["name"])
        for ev in ns.get("events", []):
            rec["members"][ev["name"]] = "event"
            if ev.get("nodoc"):
                rec["nodoc_members"].add(ev["name"])
        for p, v in (ns.get("properties") or {}).items():
            rec["members"][p] = "property"
            if isinstance(v, dict) and v.get("nodoc"):
                rec["nodoc_members"].add(p)
        for t in ns.get("types", []):
            if "enum" in t and not t.get("nodoc"):
                rec["members"][t["id"]] = "property"


def clean_idl(text):
    return strip_comments(text)


def parse_old_idl(path):
    text = clean_idl(open(path).read())
    m = re.search(r"(\[[^\]]*\]\s*)?namespace\s+([\w.]+)\s*\{", text)
    if not m:
        return
    attrs, name = m.group(1) or "", m.group(2)
    rec = add(name, os.path.relpath(path, SRC), "nodoc" in attrs)
    pm = re.search(r"platforms\s*=\s*\(([^)]*)\)", attrs)
    rec["platforms"] = re.findall(r'"(\w+)"', pm.group(1)) if pm else None
    body = text[m.end():]
    for em in re.finditer(r"(\[[^\]]*\]\s*)?enum\s+(\w+)\s*\{", body):
        if "nodoc" not in (em.group(1) or ""):
            rec["members"][em.group(2)] = "property"
    for block, kind in (("Functions", "function"), ("Events", "event"), ("Properties", "property")):
        bm = re.search(r"interface\s+" + block + r"\s*\{(.*?)\n\s*\};", body, re.S)
        if not bm:
            continue
        for mm in re.finditer(r"((?:\[[^\]]*\]\s*)*)static\s+[\w<>?\[\]]+\s+(\w+)\s*\(", bm.group(1)):
            rec["members"][mm.group(2)] = kind
            if "nodoc" in mm.group(1):
                rec["nodoc_members"].add(mm.group(2))


WEBIDL_INTERFACES = {}  # name -> (attrs, base, body)
WEBIDL_ENUMS = {}       # file -> [enum names]
WEBIDL_ROOTS = []       # (ns, type, file, attrs)


def parse_webidl(path):
    text = clean_idl(open(path).read())
    rel = os.path.relpath(path, SRC)
    for m in re.finditer(r"((?:\[[^\]]*\]\s*)*)(partial\s+)?interface\s+(\w+)\s*(?::\s*(\w+))?\s*\{(.*?)\n\s*\};", text, re.S):
        attrs, partial, name, base, body = m.groups()
        if partial and name == "Browser":
            for am in re.finditer(r"((?:\[[^\]]*\]\s*)*)static\s+attribute\s+(\w+)\s+(\w+)\s*;", body):
                WEBIDL_ROOTS.append((am.group(3), am.group(2), rel, (attrs or "") + am.group(1)))
        else:
            WEBIDL_INTERFACES.setdefault(name, []).append((attrs or "", base, body, rel))
    WEBIDL_ENUMS[rel] = [em.group(2) for em in re.finditer(r"((?:\[[^\]]*\]\s*)*)enum\s+(\w+)\s*\{", text) if "nodoc" not in em.group(1)]


def webidl_walk(ns, typ, rel, attrs):
    rec = add(ns, rel, "nodoc" in attrs)
    if ns.count(".") == 0 or rec["file"] == rel:
        for e in WEBIDL_ENUMS.get(rel, []):
            rec["members"].setdefault(e, "property")
    for iattrs, base, body, irel in WEBIDL_INTERFACES.get(typ, []):
        if "nodoc" in iattrs:
            rec["nodoc"] = True
        for mm in re.finditer(r"((?:\[[^\]]*\]\s*)*)static\s+(?:readonly\s+)?(attribute\s+)?([\w<>?, ]+?)\s+(\w+)\s*[;(]", body):
            mattrs, is_attr, mtype, mname = mm.groups()
            mtype = mtype.strip()
            kind = "function"
            if is_attr:
                ent = WEBIDL_INTERFACES.get(mtype)
                if ent and any(b == "ExtensionEvent" for _, b, _, _ in ent):
                    kind = "event"
                elif ent:
                    webidl_walk(ns + "." + mname, mtype, irel, mattrs)
                    rec["members"][mname] = "namespace"
                    continue
                else:
                    kind = "property"
            rec["members"][mname] = kind
            if "nodoc" in mattrs:
                rec["nodoc_members"].add(mname)


for d in DIRS:
    for root, _, files in os.walk(os.path.join(SRC, d)):
        for f in sorted(files):
            p = os.path.join(root, f)
            if f.startswith("_") or "manifest_types" in f or f in ("types.json", "extension_types.json", "events.json") and False:
                continue
            try:
                if f.endswith(".json"):
                    parse_json_schema(p)
                elif f.endswith(".webidl"):
                    parse_webidl(p)
                elif f.endswith(".idl"):
                    parse_old_idl(p)
            except Exception as ex:  # noqa
                print("parse failed", p, ex, file=sys.stderr)
for ns, typ, rel, attrs in WEBIDL_ROOTS:
    webidl_walk(ns, typ, rel, attrs)

# ---------- classify ----------
NOT_RUNTIME = {"manifestTypes", "extensionsManifestTypes", "types", "events", "test", "contentScripts",
               "webAccessibleResources", "webAccessibleResourcesMv2", "chromeUrlOverrides", "fileHandlers",
               "iconVariants", "mimeHandlers", "protocolHandlers", "sharedModule", "oauth2", "requirements",
               "crossOriginIsolation", "urlHandlers", "commands"}
inventory, skipped = [], []
for ns in sorted(namespaces):
    rec = namespaces[ns]
    members = {k: v for k, v in rec["members"].items() if v != "namespace"}
    if ns in NOT_RUNTIME - {"commands", "types", "events", "test"} or (ns in {"manifestTypes", "extensionsManifestTypes"}):
        skipped.append({"namespace": ns, "reason": "manifest-key / type-only schema, no runtime API", "file": rec["file"]}); continue
    if re.search(r"(Private|Internal)$", ns) or "Private." in ns or "Internal." in ns or "private" in ns.lower().split(".")[-1]:
        skipped.append({"namespace": ns, "reason": "private/internal", "file": rec["file"]}); continue
    if ns.startswith("enterprise.") or ns == "enterprise":
        skipped.append({"namespace": ns, "reason": "enterprise (policy-installed, mostly ChromeOS)", "file": rec["file"]}); continue
    if ns in ("types", "events", "test"):
        skipped.append({"namespace": ns, "reason": {"types": "type definitions (ChromeSetting) only", "events": "declarative event types only", "test": "test harness only"}[ns], "file": rec["file"]}); continue
    key, entries = feature_for(ns)
    if not entries:
        skipped.append({"namespace": ns, "reason": "no _api_features entry (not exposed)", "file": rec["file"]}); continue
    ok, reason, info = judge(entries)
    if not ok:
        skipped.append({"namespace": ns, "reason": reason, "file": rec["file"]}); continue
    if rec.get("platforms") and "mac" not in rec["platforms"]:
        skipped.append({"namespace": ns, "reason": "schema platforms " + ",".join(rec["platforms"]), "file": rec["file"]}); continue
    if rec["nodoc"]:
        skipped.append({"namespace": ns, "reason": "nodoc (undocumented)", "file": rec["file"]}); continue
    if ns.startswith("devtools."):
        info["contexts"] = ["devtools"]
    out_members, ctx_union = [], set(info["contexts"])
    for name, kind in sorted(members.items()):
        if name in rec["nodoc_members"]:
            continue
        mkey = ns + "." + name
        m = {"name": name, "kind": kind}
        if mkey in API:
            parent = resolve_entries(entries)[0] if entries else {}
            ments = [{**{k: v for k, v in parent.items() if k not in ("default_parent",)}, **e} if not e.get("noparent") else e for e in API[mkey]]
            mok, mreason, minfo = judge(ments)
            if not mok:
                continue  # MV2-only, dev channel, etc.
            if minfo["contexts"] != info["contexts"] and not ns.startswith("devtools."):
                m["contexts"] = minfo["contexts"]
                ctx_union |= set(minfo["contexts"])
            if minfo["permissions"] != info["permissions"]:
                m["permission"] = minfo["permissions"]
        out_members.append(m)
    if not out_members:
        skipped.append({"namespace": ns, "reason": "no stable MV3 members", "file": rec["file"]}); continue
    perm = info["permissions"]
    inventory.append({
        "namespace": ns,
        "permission": perm[0] if len(perm) == 1 else (perm or None),
        **({"manifest_key": info["manifest"]} if info["manifest"] else {}),
        **({"feature_flag": info["flags"]} if info["flags"] else {}),
        "members": out_members,
        "contexts": info["contexts"],
        "schema": rec["file"],
    })

os.makedirs(OUT, exist_ok=True)
meta = {"chromium_tag": TAG, "source": "https://chromium.googlesource.com/chromium/src/+/refs/tags/%s/" % TAG}
json.dump({"meta": meta, "namespaces": inventory}, open(os.path.join(OUT, "inventory.json"), "w"), indent=1)
json.dump({"meta": meta, "skipped": skipped}, open(os.path.join(OUT, "skipped.json"), "w"), indent=1)
print(len(inventory), "namespaces,", sum(len(n["members"]) for n in inventory), "members;", len(skipped), "skipped")
