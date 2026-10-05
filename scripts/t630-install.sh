#!/bin/bash
# ============================================================================
#  ZTopInc 350b:9101 (ZT9101) Wi-Fi driver installer for Debian 13 / t630
# ============================================================================
#  Run as:  sudo bash t630-install.sh
#
#  Works fully offline. Order of operations:
#    1. Try the PREBUILT module (built against 6.12.107+deb13-amd64).
#    2. If the kernel doesn't match, install the bundled toolchain + headers
#       and build from source instead.
#    3. Install module permanently + autoload at boot (absolute fw paths).
#    4. Connect to Wi-Fi (NetworkManager if present, else wpa_supplicant).
#    5. Verify internet.
# ============================================================================
set -u

# depmod/modprobe/ip/rfkill/wpa_supplicant live in /usr/sbin, which is often
# absent from the PATH a "sudo bash script.sh" inherits on Debian. Set it
# explicitly rather than relying on sudo's secure_path being configured.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD=zt9101_ztopmac_usb
DEST=/opt/ztop-wifi
KVER="$(uname -r)"
MODDIR="/lib/modules/$KVER/extra"

log()  { echo -e "\n=== $* ==="; }
die()  { echo "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"

log "0. target kernel: $KVER"

# ---------------------------------------------------------------------------
# 1. Obtain a module matching this kernel
# ---------------------------------------------------------------------------
KO=""
PREBUILT="$HERE/prebuilt/$MOD.ko"
if [ -f "$PREBUILT" ]; then
    pv="$(modinfo -F vermagic "$PREBUILT" 2>/dev/null | awk '{print $1}')"
    log "1. prebuilt module found (vermagic: ${pv:-unknown})"
    if [ "$pv" = "$KVER" ]; then
        echo "matches running kernel -- using prebuilt, no compilation needed"
        KO="$PREBUILT"
    else
        echo "prebuilt is for $pv but running $KVER -- will build from source"
    fi
fi

if [ -z "$KO" ]; then
    log "2. installing build toolchain + headers from bundled .debs"
    if [ -d "$HERE/debs" ] && ls "$HERE"/debs/*.deb >/dev/null 2>&1; then
        # apt handles local-file dependency ordering; dpkg alone often can't
        if command -v apt >/dev/null 2>&1; then
            apt install -y --no-install-recommends "$HERE"/debs/*.deb \
                || dpkg -i "$HERE"/debs/*.deb || true
        else
            dpkg -i "$HERE"/debs/*.deb || true
        fi
    else
        echo "no bundled debs; assuming toolchain already present"
    fi
    command -v make >/dev/null 2>&1 || die "make unavailable and no usable prebuilt module"
    [ -d "/lib/modules/$KVER/build" ] || die "kernel headers for $KVER missing"

    log "3. building from source"
    cp -a "$HERE/src" /tmp/ztop-build || die "cannot stage source"
    ( cd /tmp/ztop-build && make clean >/dev/null 2>&1; make ) || die "build failed"
    KO=/tmp/ztop-build/$MOD.ko
    [ -f "$KO" ] || die "build produced no $MOD.ko"
fi

# ---------------------------------------------------------------------------
# 2. Install module + firmware with ABSOLUTE paths
# ---------------------------------------------------------------------------
log "4. installing module and firmware to $DEST"
rmmod "$MOD" 2>/dev/null || true
mkdir -p "$DEST/fw" "$MODDIR"
cp -f "$HERE"/src/fw/*.bin "$DEST/fw/"
# Absolute fw= paths are REQUIRED: the driver opens them from kernel context,
# where a relative "./fw/..." resolves against the caller's CWD -- and at boot
# modprobe runs with CWD=/, so a relative path silently fails there.
sed "s#=\./fw/#=$DEST/fw/#" "$HERE/src/wifi.cfg" > "$DEST/wifi.cfg"
grep '^fw' "$DEST/wifi.cfg"

install -m 644 "$KO" "$MODDIR/$MOD.ko"
depmod -a "$KVER"

echo "$MOD" > /etc/modules-load.d/ztop-wifi.conf
echo "options $MOD cfg=$DEST/wifi.cfg" > /etc/modprobe.d/ztop-wifi.conf
echo "autoload configured (/etc/modules-load.d + /etc/modprobe.d)"

# ---------------------------------------------------------------------------
# 3. Load it
# ---------------------------------------------------------------------------
log "5. loading module"
modprobe "$MOD" || die "modprobe failed (see: dmesg | tail -30)"
sleep 4

if dmesg | tail -40 | grep -q "zt_fw_download error"; then
    dmesg | tail -15
    die "firmware download failed -- check $DEST/fw/ and $DEST/wifi.cfg"
fi
echo "firmware loaded OK"

IFACE=""
for i in $(ls /sys/class/net); do
    d=$(basename "$(readlink -f /sys/class/net/$i/device/driver 2>/dev/null)" 2>/dev/null)
    [ "$d" = "$MOD" ] && { IFACE="$i"; break; }
done
[ -n "$IFACE" ] || IFACE=$(ls /sys/class/net | grep -E '^wl' | head -1)
[ -n "$IFACE" ] || { dmesg | tail -25; die "no wireless interface appeared"; }
echo "interface: $IFACE"
rfkill unblock all 2>/dev/null || true
ip link set "$IFACE" up
sleep 2

# ---------------------------------------------------------------------------
# 4. Connect
# ---------------------------------------------------------------------------
log "6. connecting to Wi-Fi on $IFACE"

# The prebuilt fast-path skips the .deb install above, so a minimal netinst
# could reach here with no way to actually associate. Make sure at least one
# supplicant exists before we ask for credentials.
if ! command -v nmcli >/dev/null 2>&1 && ! command -v wpa_supplicant >/dev/null 2>&1; then
    echo "no nmcli and no wpa_supplicant -- installing from bundled packages"
    if ls "$HERE"/debs/*.deb >/dev/null 2>&1; then
        apt install -y --no-install-recommends \
            "$HERE"/debs/wpasupplicant_*.deb "$HERE"/debs/libpcsclite1_*.deb \
            "$HERE"/debs/libnl-3-200_*.deb "$HERE"/debs/libnl-genl-3-200_*.deb \
            "$HERE"/debs/libnl-route-3-200_*.deb 2>/dev/null \
          || apt install -y --no-install-recommends "$HERE"/debs/*.deb \
          || dpkg -i "$HERE"/debs/*.deb || true
    fi
    command -v wpa_supplicant >/dev/null 2>&1 || command -v nmcli >/dev/null 2>&1 \
        || die "could not provide a supplicant; cannot associate"
fi

read -rp "Wi-Fi network name (SSID): " SSID
[ -n "$SSID" ] || die "no SSID entered"
read -rsp "Wi-Fi password: " PSK; echo

if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
    echo "using NetworkManager"
    nmcli device set "$IFACE" managed yes 2>/dev/null || true
    nmcli device wifi rescan ifname "$IFACE" >/dev/null 2>&1 || true
    sleep 4
    nmcli connection delete "ztop-$SSID" >/dev/null 2>&1 || true
    nmcli connection add type wifi con-name "ztop-$SSID" ifname "$IFACE" \
        ssid "$SSID" connection.autoconnect yes \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" >/dev/null \
        || die "could not create connection profile"
    timeout 60 nmcli connection up "ztop-$SSID" ifname "$IFACE" \
        || echo "WARNING: nmcli up did not report success; checking anyway"
else
    echo "NetworkManager not active -- using wpa_supplicant + dhclient"
    command -v wpa_supplicant >/dev/null 2>&1 || die "wpa_supplicant not installed"
    mkdir -p /etc/wpa_supplicant
    CONF=/etc/wpa_supplicant/wpa_supplicant-$IFACE.conf
    { echo "ctrl_interface=/run/wpa_supplicant"; echo "update_config=1"; } > "$CONF"
    wpa_passphrase "$SSID" "$PSK" >> "$CONF"
    chmod 600 "$CONF"
    pkill -f "wpa_supplicant.*$IFACE" 2>/dev/null || true
    sleep 1
    wpa_supplicant -B -i "$IFACE" -c "$CONF" || die "wpa_supplicant failed to start"
    sleep 8
    if command -v dhclient >/dev/null 2>&1; then dhclient -v "$IFACE" || true
    elif command -v dhcpcd >/dev/null 2>&1; then dhcpcd "$IFACE" || true
    else udhcpc -i "$IFACE" || true; fi
    # persist across boots
    systemctl enable "wpa_supplicant@$IFACE" 2>/dev/null || true
    if [ -f /etc/network/interfaces ] && ! grep -q "$IFACE" /etc/network/interfaces; then
        cat >> /etc/network/interfaces <<EOF

auto $IFACE
iface $IFACE inet dhcp
    wpa-conf $CONF
EOF
        echo "added $IFACE to /etc/network/interfaces for boot-time connection"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
log "7. results"
ip -br addr show "$IFACE"
IP=$(ip -4 -br addr show "$IFACE" | awk '{print $3}' | cut -d/ -f1)
if [ -z "$IP" ]; then
    echo "NO IP ADDRESS obtained."
    echo "link status:"; iw dev "$IFACE" link 2>/dev/null || true
    dmesg | tail -20
    exit 1
fi
echo "IP: $IP"
ping -c 3 -W 3 1.1.1.1 2>&1 | tail -3
echo "--- DNS + HTTPS ---"
if command -v curl >/dev/null 2>&1; then
    curl -s -m 20 -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" https://deb.debian.org/
else
    wget -q -T 20 -O /dev/null https://deb.debian.org/ && echo "HTTPS OK"
fi

log "DONE"
echo "Driver installed at $MODDIR/$MOD.ko"
echo "Loads automatically on every boot; connection reconnects automatically."
