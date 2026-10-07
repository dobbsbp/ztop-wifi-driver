#!/bin/bash
# Register the ZT9101 driver with DKMS so it is rebuilt automatically on every
# kernel update. Run as root from the repo root:  su -c 'bash scripts/dkms-install.sh'
# Run AFTER scripts/t630-install.sh (it provides firmware + wifi.cfg in /opt/ztop-wifi).
# Does not unload the running module, so an active Wi-Fi connection stays up.
set -euo pipefail
export PATH=$PATH:/usr/sbin:/sbin
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

REPO=$(cd "$(dirname "$0")/.." && pwd)
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$REPO/driver/dkms.conf")
DEST=/usr/src/zt9101-$VER

apt-get install -y dkms build-essential "linux-headers-$(uname -r)"

rm -rf "$DEST"; mkdir -p "$DEST"
cp -a "$REPO/driver/." "$DEST/"
rm -rf "$DEST/doc"            # vendor manuals are not needed to build

dkms remove "zt9101/$VER" --all 2>/dev/null || true
dkms add "zt9101/$VER"
dkms build "zt9101/$VER"
dkms install "zt9101/$VER" --force
dkms status
