#!/usr/bin/env python3
"""Minimaler dpkg-deb-Ersatz: mkdeb.py <stage-dir> <out-dir>  (stage enthält DEBIAN/control)"""
import io, os, sys, tarfile, lzma, gzip, time

stage, out = sys.argv[1:3]
ctrl = open(os.path.join(stage, "DEBIAN", "control"), encoding="utf-8").read()
fields = dict(l.split(": ", 1) for l in ctrl.strip().splitlines() if ": " in l)
size_kb = 0

def add_tree(tar, root, skip_debian):
    global size_kb
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel = os.path.relpath(dirpath, root)
        if skip_debian and (rel == "DEBIAN" or rel.startswith("DEBIAN" + os.sep)):
            continue
        if rel != ".":
            ti = tar.gettarinfo(dirpath, "./" + rel)
            ti.uid = ti.gid = 0; ti.uname = ti.gname = "root"; ti.mode = 0o755
            tar.addfile(ti)
        for f in sorted(filenames):
            if f == ".DS_Store" or (skip_debian and rel == "." and f == "DEBIAN"):
                continue
            p = os.path.join(dirpath, f)
            arc = "./" + (f if rel == "." else os.path.join(rel, f))
            ti = tar.gettarinfo(p, arc)
            ti.uid = ti.gid = 0; ti.uname = ti.gname = "root"
            ti.mode = 0o755 if f.endswith(".dylib") else 0o644
            size_kb += (ti.size + 1023) // 1024
            with open(p, "rb") as fh:
                tar.addfile(ti, fh)

data_buf = io.BytesIO()
with tarfile.open(fileobj=data_buf, mode="w", format=tarfile.GNU_FORMAT) as t:
    add_tree(t, stage, True)
data = gzip.compress(data_buf.getvalue(), compresslevel=9)  # gzip: von jedem iOS-12-dpkg unterstützt

if "Installed-Size" not in fields:
    ctrl = ctrl.rstrip("\n") + f"\nInstalled-Size: {size_kb}\n"
ctrl_buf = io.BytesIO()
with tarfile.open(fileobj=ctrl_buf, mode="w", format=tarfile.GNU_FORMAT) as t:
    b = ctrl.encode("utf-8")
    ti = tarfile.TarInfo("./control"); ti.size = len(b); ti.mode = 0o644; ti.mtime = int(time.time())
    t.addfile(ti, io.BytesIO(b))
control = gzip.compress(ctrl_buf.getvalue())

def member(name, payload):
    hdr = f"{name:<16}{int(time.time()):<12}{0:<6}{0:<6}{'100644':<8}{len(payload):<10}`\n".encode()
    return hdr + payload + (b"\n" if len(payload) % 2 else b"")

deb = b"!<arch>\n" + member("debian-binary", b"2.0\n") + member("control.tar.gz", control) + member("data.tar.gz", data)
name = f"{fields['Package']}_{fields['Version']}_{fields['Architecture']}.deb"
open(os.path.join(out, name), "wb").write(deb)
print(f"{name}: {len(deb)/1e6:.2f} MB, installed {size_kb/1024:.1f} MB")
