#!/bin/bash
# Load the ZTopInc driver and connect it to your_wifi_name on its OWN profile.
# Deliberately does NOT touch the existing wlp8s0 / your_wifi_name connection:
# it clones that profile (so the password never has to be retyped or shown)
# and pins the clone to the ZTop interface only.
#
# Run as: sudo bash ~/ztop-wifi/connect.sh
set -u

SRC=/home/ben/ztop-wifi/fork/src
MOD=zt9101_ztopmac_usb
SRC_PROFILE=your_wifi_name
NEW_PROFILE=your_wifi_name-ztop

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo"; exit 1; fi

echo "== 1. baseline: wlp8s0 must stay up =="
nmcli -t -f DEVICE,STATE,CONNECTION device status | grep '^wlp8s0' || true

echo
echo "== 2. loading module =="
if lsmod | grep -q "^$MOD"; then
    echo "already loaded; reloading"
    rmmod "$MOD" 2>/dev/null || true
    sleep 1
fi
# wifi.local.cfg carries ABSOLUTE fw= paths. The driver reads those paths from
# kernel context, where a relative "./fw/..." resolves against the *caller's*
# CWD -- so an absolute cfg path alone is not enough.
insmod "$SRC/$MOD.ko" cfg="$SRC/wifi.local.cfg" || { echo "insmod FAILED"; exit 1; }
sleep 4
if dmesg | tail -40 | grep -q "zt_fw_download error"; then
    echo "FIRMWARE LOAD FAILED -- aborting before touching the network."
    dmesg | tail -12
    rmmod "$MOD" 2>/dev/null || true
    exit 1
fi
echo "firmware downloaded OK"

echo
echo "== 3. finding the new interface =="
# the ZTop MAC starts b4:04:18 (from its efuse); match on driver-created iface
IFACE=""
for i in $(ls /sys/class/net); do
    drv=$(basename "$(readlink -f /sys/class/net/$i/device/driver 2>/dev/null)" 2>/dev/null)
    if [ "$drv" = "$MOD" ]; then IFACE="$i"; break; fi
done
# fallback: any wlx* interface that isn't the builtin
if [ -z "$IFACE" ]; then
    IFACE=$(ls /sys/class/net | grep -E '^wlx' | head -1)
fi
if [ -z "$IFACE" ]; then
    echo "no interface found. dmesg tail:"; dmesg | tail -20; exit 1
fi
echo "interface: $IFACE"
ip link set "$IFACE" up
sleep 2

echo
echo "== 4. preparing a dedicated profile (clone, keeps existing one intact) =="
nmcli connection delete "$NEW_PROFILE" >/dev/null 2>&1 || true
if ! nmcli connection clone "$SRC_PROFILE" "$NEW_PROFILE" >/dev/null 2>&1; then
    echo "clone of '$SRC_PROFILE' failed -- is that profile present?"
    nmcli -t -f NAME connection show
    exit 1
fi
# pin the clone to this interface only, and don't let it autoconnect elsewhere
nmcli connection modify "$NEW_PROFILE" \
    connection.interface-name "$IFACE" \
    connection.autoconnect no \
    ipv4.route-metric 700 \
    ipv6.route-metric 700
echo "profile '$NEW_PROFILE' pinned to $IFACE (higher metric: won't steal default route)"

echo
echo "== 5. scanning =="
nmcli device wifi rescan ifname "$IFACE" >/dev/null 2>&1 || true
sleep 4
nmcli -f SSID,SIGNAL,SECURITY device wifi list ifname "$IFACE" 2>/dev/null | head -10

echo
echo "== 6. connecting =="
timeout 45 nmcli connection up "$NEW_PROFILE" ifname "$IFACE"
rc=$?
echo "nmcli rc=$rc"

echo
echo "== 7. result =="
nmcli -t -f DEVICE,STATE,CONNECTION device status | grep -E "^($IFACE|wlp8s0)"
ip -br addr show "$IFACE"
echo
echo "== 8. internet test over $IFACE only =="
IP=$(ip -4 -br addr show "$IFACE" | awk '{print $3}' | cut -d/ -f1)
echo "bound source IP: ${IP:-none}"
if [ -n "$IP" ]; then
    ping -c 3 -W 3 -I "$IP" 1.1.1.1 2>&1 | tail -4
    echo "--- DNS/HTTP over $IFACE ---"
    curl --interface "$IP" -s -m 15 -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" https://deb.debian.org/ 2>&1
else
    echo "no IPv4 obtained"
fi
