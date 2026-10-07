# ZTopInc 802.11n NIC (USB `350b:9101`, chip ZT9101) on Linux

**Your USB Wi-Fi adapter shows up in `lsusb` but Linux gives you no Wi-Fi interface?
This repo is the fix.** It is a working Linux driver, an offline installer, and a
DKMS setup so it survives kernel updates. Tested on **Debian 13 (trixie), kernel 6.12**.

```
$ lsusb
Bus 001 Device 003: ID 350b:9101 ZTopInc 802.11n NIC
```

If you see `350b:9101` / `ZTopInc 802.11n NIC`, you are in the right place. You are
not doing anything wrong, and this is solvable.

## Is this you?

- `lsusb` lists **ZTopInc 802.11n NIC** (ID `350b:9101`), but `ip link`, `nmcli` and
  your desktop's Wi-Fi menu show **no wireless interface**.
- `dmesg` shows the device being detected but nothing binds to it.
- The Wi-Fi works on Windows or Android, but on Linux it is a dead stick.
- You searched for `ZT9101`, `zt9101_ztopmac_usb`, `350b:9101` or "ZTop Wi-Fi Linux
  driver" and found only old vendor source that does not compile on a modern kernel.
- You have **no Ethernet cable**, so you cannot just `apt install` your way out.
  (That was exactly my situation, and this repo is built for it: the installer works
  **fully offline** from a USB stick.)

**Why it doesn't work out of the box:** the ZT9101 has no driver in the Linux kernel,
and its firmware is not in Debian's `firmware-*` packages. The vendor's driver exists,
but it fails to build on current kernels and, worse, builds "successfully" with bugs
that crash the kernel. This repo contains the fixed driver, the firmware, and a
prebuilt module for Debian 13 / kernel 6.12.107, so you can skip compiling entirely.

## Start here (pick your path)

| Your situation | Do this |
|---|---|
| **No Ethernet, Debian 13 amd64, kernel 6.12.107** (the t630 case) | [Quick start](#quick-start-install-on-the-t630-or-any-debian-13-amd64-kernel-612107): prebuilt module, offline USB installer |
| **Different kernel version** | [Different kernel](#different-kernel-eg-after-apt-upgrade): rebuild with `make` |
| **Already working, want it to survive `apt upgrade`** | [Surviving kernel updates (DKMS)](#surviving-kernel-updates-dkms) |
| **Kernel 7.x** | Builds and loads, but is experimental. See [Caveats](#caveats--honest-status) |
| **Something broke** | [Troubleshooting](#troubleshooting) |

**Search terms** (for the next person who needs this): ZT9101, ZTopInc 802.11n NIC,
350b:9101, zt9101_ztopmac_usb, ZTop USB Wi-Fi Linux driver, ZTop wifi Debian 13,
USB Wi-Fi adapter detected but no interface, HP t630 Wi-Fi.

**Result (2026-10-05):** an HP t630 thin client running Debian 13 (kernel
`6.12.107+deb13-amd64`), with no Ethernet, loaded this driver and connected to Wi-Fi.
This adapter has been that machine's only network connection since. (The installer's
built-in ping/HTTPS check output was not captured on the first run.)

If it works for you, or doesn't, please open an issue. Reports for other kernels,
distros and adapter brands are the most useful thing you can add.

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
  dkms-install.sh               registers the driver with DKMS (survives kernel updates)
  laptop-test-connect.sh        load + connect on the laptop (see Caveats)
driver/dkms.conf                DKMS configuration
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

## Surviving kernel updates (DKMS)

The prebuilt `.ko` only loads on the exact kernel it was built for. Without DKMS, an
`apt upgrade` that installs a new kernel **silently removes your Wi-Fi at the next
reboot**, which is a real problem if the adapter is your only connection.
**DKMS** stores the driver source and rebuilds the module automatically for every new
kernel.

```bash
# after install.sh has worked once (it provides the firmware + wifi.cfg in /opt/ztop-wifi)
su -c 'bash scripts/dkms-install.sh'
dkms status        # zt9101/1.0, <kernel>, x86_64: installed
```

`driver/dkms.conf` drives this. The script needs internet, which the working Wi-Fi
provides. It does not unload the running module, so your connection stays up.

- **Gotcha:** DKMS rewrites any `make ...` command to add `KERNELRELEASE=<ver>`, which
  makes the vendor Makefile take its kbuild-only branch and define no targets
  (`make: *** No targets. Stop.`). `dkms.conf` therefore starts the command with
  `env make ...` so DKMS leaves it alone.
- New kernels need their headers. Install the `linux-headers-amd64` metapackage so
  headers arrive together with each kernel.
- Until you have a wired fallback, consider `apt-mark hold linux-image-amd64` (and the
  current `linux-image-$(uname -r)`) so an update cannot take your only connection
  away. Undo with `apt-mark unhold`.
- The module installs to `/lib/modules/<kver>/updates/dkms/` and takes priority over
  the older copy in `extra/`.

**Status:** verified on `6.12.107+deb13`: DKMS build and install succeed, and the
resulting module's `vermagic` matches the running kernel. **Not yet tested:** loading
the DKMS-built module after a reboot, and the automatic rebuild when a *newer* kernel
is installed. If you try either, please report back.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Key was rejected by service` on `modprobe` | Secure Boot is on and the module is unsigned. Disable Secure Boot in firmware setup (HP: **F10**). |
| `lsusb` shows the stick but there is still no interface | The module isn't loaded. Run `sudo modprobe zt9101_ztopmac_usb`, then check `dmesg \| tail -30`. |
| `modprobe: command not found` / `depmod: command not found` | They live in `/usr/sbin`, which Debian leaves out of non-root `PATH`. Use `su -` or `export PATH=$PATH:/usr/sbin:/sbin`. |
| `Exec format error` or `Invalid module format` | The prebuilt `.ko` doesn't match your kernel (`uname -r`). Rebuild: see [Different kernel](#different-kernel-eg-after-apt-upgrade). |
| Module loads but never connects, firmware errors in `dmesg` | Paths in `wifi.cfg` must be **absolute** (`/opt/ztop-wifi/fw/...`). `install.sh` sets this. |
| Wi-Fi vanished after `apt upgrade` and a reboot | New kernel, old module. Boot the old kernel from GRUB's "Advanced options", then set up [DKMS](#surviving-kernel-updates-dkms). |
| `uptime` load average sits at about 3 with an idle CPU | **Harmless.** The driver's three kernel threads (`wlan_mgmt_00`, `ap_00`, `mlme_00`) sleep in uninterruptible state, which Linux counts as load. The connection is fine. |
| `ip` / `nmcli` hang after a crash | A kernel oops inside the driver can leave `rtnl_lock` held. Only a reboot recovers it. |

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
