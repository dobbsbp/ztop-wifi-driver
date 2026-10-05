# ZTopInc 802.11n NIC (USB `350b:9101`, chip ZT9101) on Linux

Working Linux driver + offline installer for the **ZTopInc 802.11n NIC** USB Wi-Fi
adapter, built so an **HP t630 thin client running Debian 13 (trixie)** with no
Ethernet could get on Wi-Fi.

**Result (2026-10-05):** the t630 (kernel `6.12.107+deb13-amd64`) loaded the
driver and connected to `your_wifi_name`. (The user reported the connection up; the
installer's built-in ping/HTTPS check output was not captured here, so internet
through it is assumed rather than separately verified.)

---

## Contents

```
README.md                       this file
driver/                         patched driver source (builds on 6.12 and 7.x)
prebuilt/6.12.107+deb13-amd64/  ready-to-load module for the t630's kernel
patches/ztop-kernel-compat.patch  all source changes vs. the original upstream
scripts/
  t630-install.sh               the installer that runs ON the target machine
  stage-usb.sh                  copies everything onto the USB stick (run on a laptop)
  fetch-debs.sh                 re-downloads the offline .deb package set (229 MB)
  laptop-test-connect.sh        load + connect on the laptop (see Caveats)
```

The 165 offline `.deb` packages are **not** stored here (229 MB) -
`scripts/fetch-debs.sh` regenerates them.

---

## Background: why this was needed

The adapter has **no in-kernel driver**. Linux sees it (`lsusb` shows
`ZTopInc 802.11n NIC`) but creates no network interface. It needs the vendor
driver (`zt9101_ztopmac_usb`) plus firmware, which is **not** in Debian's
`firmware-*` packages. The vendor source targets old kernels, so it also had to
be ported. Upstream:

- https://codeberg.org/sallecta/driver_wifi_ztopinc (base used here)
- https://github.com/jfco-antunes/driver_wifi_ztopinc_Ubuntu26.04 (partial 7.x port; its 6.9 gate breaks Debian 13)

---

## Quick start: install on the t630 (or any Debian 13 amd64, kernel 6.12.107)

### 1. Build the USB stick (on a machine with internet)

```bash
cd ~/Documents/ztop-wifi-driver
bash scripts/fetch-debs.sh 6.12.107+deb13 ./debs     # ~229 MB, one time
```

Lay out a payload folder with exactly this shape:

```
payload/
  install.sh          <- copy of scripts/t630-install.sh
  prebuilt/           <- copy of prebuilt/6.12.107+deb13-amd64/*.ko
  src/                <- copy of driver/
  debs/               <- output of fetch-debs.sh
```

```bash
mkdir -p payload/prebuilt
cp scripts/t630-install.sh payload/install.sh
cp prebuilt/6.12.107+deb13-amd64/*.ko payload/prebuilt/
cp -a driver payload/src
mv debs payload/debs
```

Copy `payload/` to a USB stick (any writable filesystem such as ext4/FAT32, named e.g. `ztop_wifi/`).
`scripts/stage-usb.sh` does this for a partition labelled `DRIVERS` (edit the
`PAYLOAD=` path at the top first).

### 2. On the target machine

1. **Disable Secure Boot** (HP: press **F10** at boot). The module is unsigned;
   with Secure Boot on you get `Key was rejected by service`.
2. Plug in the Wi-Fi adapter and the stick. Find the stick and mount it:
   ```bash
   lsblk                       # e.g. sdb3
   sudo mkdir -p /mnt/usb
   sudo mount /dev/sdb3 /mnt/usb
   ```
3. Run the installer:
   ```bash
   sudo bash /mnt/usb/ztop_wifi/install.sh
   ```
   It asks for your Wi-Fi network name (SSID) and password, then pings `1.1.1.1` and
   fetches `https://deb.debian.org/` to prove it works.

What `install.sh` does: uses the prebuilt module if `vermagic` equals `uname -r`
(otherwise installs the bundled toolchain + headers and builds from source);
copies firmware to `/opt/ztop-wifi/fw` with **absolute** paths; installs the
module to `/lib/modules/$(uname -r)/extra/`; writes
`/etc/modules-load.d/ztop-wifi.conf` and `/etc/modprobe.d/ztop-wifi.conf` so it
loads at every boot; connects via NetworkManager or, if absent, `wpa_supplicant`.

### 3. After it works: apt sources + SSH

A netinst installed without a mirror has no usable apt sources (`openssh-server
has no installation candidate`). Fix:

```bash
sudo sed -i 's/^deb cdrom/#&/' /etc/apt/sources.list
echo "deb http://deb.debian.org/debian trixie main" | sudo tee /etc/apt/sources.list.d/d.list
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
hostname -I                       # then: ssh USER@THAT_IP
```

The IP comes from DHCP and can change; reserve it in the router, or install
`avahi-daemon` and use `HOSTNAME.local`.

---

## Different kernel (e.g. after `apt upgrade`)?

The prebuilt `.ko` only loads on the **exact** kernel it was built for. Rebuild
on the target (needs `build-essential` + `linux-headers-$(uname -r)`):

```bash
cd driver
make                                  # -> zt9101_ztopmac_usb.ko
```

`install.sh` does this automatically when the prebuilt `vermagic` does not match,
using the bundled `.deb`s - so for a new kernel run
`scripts/fetch-debs.sh <new kernel pkg version>` first (e.g. `6.12.120+deb13`)
so the matching headers are on the stick.

To cross-build for the t630 from another machine, extract Debian's
`linux-headers-<v>-amd64`, `linux-headers-<v>-common` and `linux-kbuild-<v>`
`.deb`s, make the `Makefile`/`scripts`/`tools` links point inside the extracted
tree, then `make KSRC=<tree> KVER=<v>-amd64 CONFIG_DEBUG_INFO_BTF_MODULES=`
(the last variable skips BTF, which needs `pahole`).

---

## What was wrong with the original driver (`patches/ztop-kernel-compat.patch`)

Fixes touch four files. Cause → effect:

| # | Problem | Symptom |
|---|---|---|
| 1 | Makefile used `EXTRA_CFLAGS`; modern kbuild reads `ccflags-y` | `common.h: No such file or directory` |
| 2 | `#elseif` typo in `hif/usb.c` (should be `#elif`) | `invalid preprocessing directive`, `no member named drvwrap` |
| 3 | `del_timer()` renamed `timer_delete()` (6.12+) | `modpost: "del_timer" undefined` |
| 4 | `get_tx_power`/`set_tx_power`/`set_wiphy_params` gained `radio_idx`/`link_id` args in **7.x** (not 6.9; 6.12 still has the old form) | **kernel oops** the moment the interface registers |
| 5 | Kernel 7.x passes `wireless_dev *` (not `net_device *`) to `add_key`, `get_key`, `del_key`, `get_station`, `add_station`, `change_station`, `del_station`, `dump_station`; driver did `netdev_priv()` on it | oops at WPA key install (connect time) |
| 6 | `cfg80211_new_sta`/`cfg80211_del_sta` also take `wireless_dev *` on 7.x | compile error once `-w` removed |

All version gates are `>= KERNEL_VERSION(7, 0, 0)`, verified against the real
`cfg80211.h` of both 6.12.107 and 7.1.5.

**Why #4-#6 were invisible:** the vendor Makefile ends with a blanket `-w` that
suppresses `-Werror=incompatible-pointer-types`, so the build "succeeded" with
wrongly-typed callbacks. That line is commented out in `driver/mak/linux/Makefile`.
Keep it that way: it turns future ABI mismatches into build errors instead of crashes.

### Gotchas worth remembering

- **Firmware paths in `wifi.cfg` must be absolute.** The driver `open()`s them
  from kernel context; `./fw/x.bin` resolves against the caller's working
  directory (`/home/ben/fw/...`, then `/` at boot). `install.sh` rewrites them to `/opt/ztop-wifi/fw/`.
- `depmod`/`modprobe` are in `/usr/sbin`, often missing from `sudo`'s PATH on
  Debian. `install.sh` exports PATH itself.
- `/tmp` is wiped on reboot - don't keep work there.
- Ubuntu/Pop!_OS ship `sfdisk` in a separate `fdisk` package; `parted` rejects
  hybrid-ISO sticks ("driver descriptor" warning). The stick's extra partition was made with `sfdisk --append`.

---

## Caveats / honest status

- **Proven:** build on 6.12.107 and 7.1.5 with `-Werror=incompatible-pointer-types`
  clean; t630 connected to your_wifi_name (per user report).
- **Not proven on the laptop (Pop!_OS, kernel 7.1.5):** a full connect was never completed
  there. The first attempts crashed the kernel (bugs #4/#5 above, before they were
  fixed); the fixed module loads and scans but a clean end-to-end connect was not finished. Treat 7.x as
  experimental. Do not test on a machine you can't afford to reboot.
- A kernel oops inside the driver can leave `rtnl_lock` held: `ip`/`nmcli` then hang
  and only a reboot recovers.
- The driver is GPL-2.0, copyright Shandong ZTop Microelectronics. The
  firmware blobs in `driver/fw/` are the vendor's, redistributed from upstream.
- `driver/doc/` contains the vendor's manuals (`.docx`/`.xlsx`).

## Bootable Debian installer used

`debian-13.7.0-amd64-netinst.iso` (SHA256 verified against `SHA256SUMS`, signature
checked with Debian's CD signing key), written to the stick with `dd`. The stick
also has a third `ext4` partition labelled `DRIVERS` holding the payload.
