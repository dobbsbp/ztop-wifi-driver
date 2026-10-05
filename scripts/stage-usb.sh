#!/bin/bash
# Write the FIXED ZTopInc driver payload onto the USB stick.
# Overwrites the old broken ztop_wifi directory IN PLACE (same name on purpose,
# so there is no hyphen/underscore ambiguity).
#
# Run as: sudo bash ~/ztop-wifi/stage.sh
set -eu

PAYLOAD=/home/ben/ztop-wifi/payload
[ "$(id -u)" -eq 0 ] || { echo "run with sudo:  sudo bash $0"; exit 1; }
[ -f "$PAYLOAD/install.sh" ] || { echo "payload missing at $PAYLOAD"; exit 1; }

echo "== locating the DRIVERS partition =="
DEV=$(blkid -L DRIVERS 2>/dev/null || true)
if [ -z "$DEV" ]; then
    echo "Could not find a partition labelled DRIVERS."
    echo "Plugged in? Current block devices:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,TRAN
    exit 1
fi
echo "found: $DEV"

# mount it ourselves if the desktop hasn't
MP=$(findmnt -n -o TARGET "$DEV" 2>/dev/null | head -1 || true)
OURS=0
if [ -z "$MP" ]; then
    MP=/mnt/ztop-stage
    mkdir -p "$MP"
    mount "$DEV" "$MP"
    OURS=1
    echo "mounted at $MP"
else
    echo "already mounted at $MP"
fi

echo
echo "== what is on the stick now =="
ls -la "$MP" | sed 's/^/  /'

echo
echo "== replacing payload (234 MB, takes a minute) =="
rm -rf "$MP/ztop_wifi" "$MP/ztop-wifi"
mkdir -p "$MP/ztop_wifi"
cp -a "$PAYLOAD"/. "$MP/ztop_wifi"/
chmod +x "$MP/ztop_wifi/install.sh"
sync

echo
echo "== verification =="
KO="$MP/ztop_wifi/prebuilt/zt9101_ztopmac_usb.ko"
printf '  install.sh : %s\n' "$([ -f "$MP/ztop_wifi/install.sh" ] && echo present || echo MISSING)"
printf '  prebuilt   : %s\n' "$(modinfo -F vermagic "$KO" 2>/dev/null || echo MISSING)"
printf '  debs       : %s packages\n' "$(ls "$MP/ztop_wifi/debs"/*.deb 2>/dev/null | wc -l)"
printf '  source     : %s\n' "$([ -f "$MP/ztop_wifi/src/Makefile" ] && echo present || echo MISSING)"
printf '  firmware   : %s blobs\n' "$(ls "$MP/ztop_wifi/src/fw"/*.bin 2>/dev/null | wc -l)"
# the decisive check: the old bug must be gone from the staged source
# Check the WHOLE staged tree, not just src/ -- the old layout used driver/,
# so grepping src/ alone silently passed on an old payload.
if grep -rq '#elseif' "$MP/ztop_wifi" 2>/dev/null; then
    echo "  SOURCE STILL BROKEN (#elseif found) -- do not use"
    exit 1
fi
if [ -d "$MP/ztop_wifi/driver" ]; then
    echo "  STALE LAYOUT: old driver/ dir survived -- do not use"
    exit 1
fi
echo "  source patched : yes (no #elseif, no stale driver/)"
du -sh "$MP/ztop_wifi" | sed 's/^/  /'

echo
echo "== unmounting =="
cd /
umount "$MP"
[ "$OURS" = "1" ] && rmdir "$MP" 2>/dev/null || true
echo
echo "DONE -- stick is flushed and safe to unplug."
echo "On the t630 run:  sudo bash /mnt/usb/ztop_wifi/install.sh"
