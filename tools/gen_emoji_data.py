#!/usr/bin/env python3
"""Generate offline emoji search data for EmojiSearch12.

Inputs : emoji-test.txt (Unicode), cldr-annotations-full, cldr-annotations-derived-full (cldr-json)
Output : <out>/<locale>.json  ->  [[emoji, name, keyword, ...], ...] in Unicode emoji order
         <out>/index.json     ->  {"emoji": "18.0", "cldr": "48.2.0", "locales": [...]}
"""
import json, os, sys

test_txt, ann_dir, der_dir, out_dir = sys.argv[1:5]
SKIN = set(range(0x1F3FB, 0x1F400))

# ---------- emoji order (fully-qualified, no components, no skin-tone variants)
order, version = [], "?"
group = None
for line in open(test_txt, encoding="utf-8"):
    if line.startswith("# Version:"):
        version = line.split(":", 1)[1].strip()
    if line.startswith("# group:"):
        group = line.split(":", 1)[1].strip()
    if not line.strip() or line.startswith("#") or group == "Component":
        continue
    cps, rest = line.split(";", 1)
    if "fully-qualified" not in rest.split("#")[0]:
        continue
    cps = [int(c, 16) for c in cps.split()]
    if any(c in SKIN for c in cps):
        continue
    order.append("".join(map(chr, cps)))

def load(path, top):
    try:
        d = json.load(open(path, encoding="utf-8"))[top].get("annotations", {})
    except FileNotFoundError:
        return {}
    return d

def parent(loc):
    special = {"en-001": "en", "es-419": "es", "zh-Hant": None, "pt-PT": "pt"}
    if loc in special:
        return special[loc]
    if loc.startswith("en-") and loc != "en-001":
        return "en-001"
    if loc.startswith("es-") and loc != "es-419":
        return "es-419"
    if loc.startswith("zh-Hant-"):
        return "zh-Hant"
    return loc.rsplit("-", 1)[0] if "-" in loc else None

locales = sorted(os.listdir(os.path.join(ann_dir, "annotations")))
raw = {}
for loc in locales:
    a = load(os.path.join(ann_dir, "annotations", loc, "annotations.json"), "annotations")
    a.update(load(os.path.join(der_dir, "annotationsDerived", loc, "annotations.json"), "annotationsDerived"))
    raw[loc] = a

def merged(loc):
    chain, l = [], loc
    while l:
        chain.append(l)
        l = parent(l)
    m = {}
    for l in reversed(chain):
        m.update(raw.get(l, {}))
    return m

def entries(ann):
    out = []
    for e in order:
        v = ann.get(e) or ann.get(e.replace("️", ""))
        if not v:
            continue
        name = [t for t in v.get("tts", []) if t != "↑↑↑"]
        kws = [k for k in v.get("default", []) if k != "↑↑↑"]
        if not name and not kws:
            continue
        name = name[0] if name else kws[0]
        seen, row = {name.lower()}, [e, name]
        for k in kws:
            if k.lower() not in seen:
                seen.add(k.lower())
                row.append(k)
        out.append(row)
    return out

os.makedirs(out_dir, exist_ok=True)
written, total = [], 0
cache = {}
for loc in locales:
    if loc == "und":
        continue
    rows = entries(merged(loc))
    if len(rows) < 500:          # skip locales with only token coverage
        continue
    p = parent(loc)
    if p and p in cache and cache[p] == rows:
        continue                 # identical to parent -> lookup falls back anyway
    cache[loc] = rows
    data = json.dumps(rows, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    open(os.path.join(out_dir, loc + ".json"), "wb").write(data)
    written.append(loc)
    total += len(data)
json.dump({"emoji": version, "cldr": os.environ.get("CLDR_VERSION", "?"), "count": len(order), "locales": written},
          open(os.path.join(out_dir, "index.json"), "w"), ensure_ascii=False)
print(f"emoji {version}: {len(order)} emoji, {len(written)} locales, {total/1e6:.1f} MB")
