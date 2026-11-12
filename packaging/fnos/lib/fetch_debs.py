#!/usr/bin/env python3
"""从 Debian bookworm（飞牛 fnOS 的基础系统）取指定包里的共享库。

用法: fetch_debs.py --arch amd64|arm64 --cache DIR --out DIR PKG:SONAME [PKG:SONAME ...]

- 索引走 https://deb.debian.org，.deb 按索引里的 SHA256 校验
- 只取 data.tar 里与 SONAME 同名的文件（跟随包内符号链接，输出为普通文件）
- 只依赖 Python 标准库
"""
import argparse
import hashlib
import io
import lzma
import os
import sys
import tarfile
import time
import urllib.request

MIRRORS = [
    ("https://deb.debian.org/debian", "bookworm"),
    ("https://deb.debian.org/debian", "bookworm-updates"),
    ("https://deb.debian.org/debian-security", "bookworm-security"),
]


def log(msg):
    print(f"[fetch_debs] {msg}", file=sys.stderr)


def fetch(url, dest, max_age=None):
    if os.path.exists(dest) and (max_age is None or time.time() - os.path.getmtime(dest) < max_age):
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    log(f"下载 {url}")
    with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    os.replace(tmp, dest)
    return dest


def load_index(cache, base, dist, arch):
    name = f"{base.split('//')[1].replace('/', '_')}_{dist}_{arch}_Packages.xz"
    path = fetch(f"{base}/dists/{dist}/main/binary-{arch}/Packages.xz",
                 os.path.join(cache, "index", name), max_age=6 * 3600)
    recs = {}
    for block in lzma.decompress(open(path, "rb").read()).decode().split("\n\n"):
        fields = {}
        for line in block.splitlines():
            if line and not line[0].isspace() and ":" in line:
                k, v = line.split(":", 1)
                fields[k] = v.strip()
        if "Package" in fields:
            fields["_base"] = base
            recs.setdefault(fields["Package"], []).append(fields)
    return recs


def vercmp(a, b):
    """Debian 版本比较（足够处理 libstdc++6 / libgcc-s1 这类版本号）。"""
    def order(c):
        if c == "~":
            return -1
        if c.isdigit():
            return 0
        if c.isalpha():
            return ord(c)
        return ord(c) + 256

    def cmp_part(x, y):
        while x or y:
            nx = ""
            while x and not x[0].isdigit():
                nx += x[0]; x = x[1:]
            ny = ""
            while y and not y[0].isdigit():
                ny += y[0]; y = y[1:]
            for i in range(max(len(nx), len(ny))):
                cx = order(nx[i]) if i < len(nx) else 0
                cy = order(ny[i]) if i < len(ny) else 0
                if cx != cy:
                    return -1 if cx < cy else 1
            dx = ""
            while x and x[0].isdigit():
                dx += x[0]; x = x[1:]
            dy = ""
            while y and y[0].isdigit():
                dy += y[0]; y = y[1:]
            ix, iy = int(dx or 0), int(dy or 0)
            if ix != iy:
                return -1 if ix < iy else 1
        return 0

    def split(v):
        epoch, _, rest = v.partition(":") if ":" in v else ("0", "", v)
        up, _, rev = rest.rpartition("-") if "-" in rest else (rest, "", "")
        return int(epoch), up, rev

    ea, ua, ra = split(a)
    eb, ub, rb = split(b)
    if ea != eb:
        return -1 if ea < eb else 1
    return cmp_part(ua, ub) or cmp_part(ra, rb)


def deb_data_tar(deb_path):
    data = open(deb_path, "rb").read()
    if not data.startswith(b"!<arch>\n"):
        raise SystemExit(f"{deb_path} 不是 ar 归档")
    pos = 8
    while pos < len(data):
        header = data[pos:pos + 60]
        name = header[:16].decode().strip().rstrip("/")
        size = int(header[48:58].decode().strip())
        body = data[pos + 60:pos + 60 + size]
        if name.startswith("data.tar"):
            return tarfile.open(fileobj=io.BytesIO(body))
        pos += 60 + size + (size & 1)
    raise SystemExit(f"{deb_path} 里没有 data.tar")


def extract_soname(tf, soname, out_dir):
    members = {m.name.lstrip("./"): m for m in tf.getmembers()}
    hits = [n for n in members if os.path.basename(n) == soname]
    if not hits:
        raise SystemExit(f"包里没有 {soname}")
    m = members[hits[0]]
    seen = 0
    while m.issym() and seen < 10:
        target = os.path.normpath(os.path.join(os.path.dirname(m.name.lstrip("./")), m.linkname))
        m = members[target]
        seen += 1
    if not m.isfile():
        raise SystemExit(f"{soname} 不是普通文件")
    dest = os.path.join(out_dir, soname)
    with tf.extractfile(m) as src, open(dest, "wb") as f:
        f.write(src.read())
    os.chmod(dest, 0o755)
    return dest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--cache", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("wants", nargs="+", help="PKG:SONAME")
    a = ap.parse_args()

    index = {}
    for base, dist in MIRRORS:
        for name, recs in load_index(a.cache, base, dist, a.arch).items():
            index.setdefault(name, []).extend(recs)

    os.makedirs(a.out, exist_ok=True)
    for want in a.wants:
        pkg, soname = want.split(":", 1)
        recs = index.get(pkg)
        if not recs:
            raise SystemExit(f"bookworm 索引里没有 {pkg}")
        best = recs[0]
        for r in recs[1:]:
            if vercmp(r["Version"], best["Version"]) > 0:
                best = r
        deb = os.path.join(a.cache, "debs", os.path.basename(best["Filename"]))
        fetch(f"{best['_base']}/{best['Filename']}", deb)
        h = hashlib.sha256(open(deb, "rb").read()).hexdigest()
        if h != best["SHA256"]:
            os.remove(deb)
            raise SystemExit(f"{deb} sha256 不符，已删除")
        extract_soname(deb_data_tar(deb), soname, a.out)
        print(f"{pkg} {best['Version']} {soname}")


if __name__ == "__main__":
    main()
