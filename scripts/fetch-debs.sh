#!/bin/bash
# Re-download the offline package set (build tools, kernel headers, wpa_supplicant,
# NetworkManager and all their dependencies) for Debian 13 "trixie" amd64.
# Needs an internet-connected machine (any distro with curl, xz, python3).
#
#   bash fetch-debs.sh [KERNEL_PKG_VERSION] [OUTPUT_DIR]
#   bash fetch-debs.sh 6.12.107+deb13 ./debs
#
# KERNEL_PKG_VERSION must match `uname -r` on the target WITHOUT the "-amd64"
# suffix (target runs 6.12.107+deb13-amd64 -> pass 6.12.107+deb13).
set -eu
KV="${1:-6.12.107+deb13}"
OUT="${2:-./debs}"
MIRROR=http://deb.debian.org/debian
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "fetching trixie package index..."
curl -fsSL "$MIRROR/dists/trixie/main/binary-amd64/Packages.xz" | xz -d > "$TMP/Packages"

KV="$KV" TMP="$TMP" python3 - <<'EOF'
import os, re, sys
kv, tmp = os.environ["KV"], os.environ["TMP"]
pkgs, prov = {}, {}
for st in open(f"{tmp}/Packages", encoding="utf-8", errors="replace").read().split("\n\n"):
    m = re.search(r"^Package: (\S+)", st, re.M)
    if not m: continue
    n = m.group(1)
    g = lambda k: (re.search(rf"^{k}: (.+)", st, re.M) or [None, None])[1]
    deps = []
    if g("Depends"):
        for alt in g("Depends").split(","):
            deps.append([re.sub(r"\s*\(.*?\)", "", a).strip() for a in alt.split("|")])
    pkgs.setdefault(n, {"f": g("Filename"), "d": deps})
    if g("Provides"):
        for x in g("Provides").split(","):
            prov.setdefault(re.sub(r"\s*\(.*?\)", "", x).strip(), set()).add(n)
seen = set()
def res(n):
    if n in seen: return
    if n not in pkgs:
        for r in prov.get(n, ()): res(r); return
        print("missing:", n, file=sys.stderr); return
    seen.add(n)
    for alt in pkgs[n]["d"]:
        c = next((a for a in alt if a in seen), None) or next((a for a in alt if a in pkgs or a in prov), None)
        if c: res(c)
for s in [f"linux-headers-{kv}-amd64", f"linux-headers-{kv}-common", "build-essential",
          "pahole", "wpasupplicant", "network-manager"]:
    if s not in pkgs: sys.exit(f"package {s} not in trixie main -- kernel version wrong/outdated?")
    res(s)
open(f"{tmp}/urls", "w").write("\n".join(pkgs[n]["f"] for n in sorted(seen) if pkgs.get(n, {}).get("f")) + "\n")
EOF

echo "downloading $(wc -l < "$TMP/urls") packages to $OUT ..."
( cd "$OUT" && sed "s#^#$MIRROR/#" "$TMP/urls" | xargs -n1 -P8 curl -fsSL -O )
echo "done: $(ls "$OUT"/*.deb | wc -l) packages, $(du -sh "$OUT" | cut -f1)"
