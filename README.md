# Zenfan: fan control for the ASUS Zenbook UX535QE (Linux)

A small GNOME app, kernel driver and background service that let you control **both fans** on
the ASUS Zenbook 15 UX535QE (Ryzen 7 5800H + RTX 3050 Ti), including the **GPU fan**, which
Linux doesn't support out of the box.

- **CPU fan full speed** on/off
- **GPU fan full speed** on/off
- **Auto-boost:** both fans go to full speed when the CPU reaches 80 °C and back to automatic
  below 65 °C (you can change both thresholds). It keeps running when the window is closed.
- Live CPU/GPU fan RPM and temperatures
- Switching a fan off means **automatic**, the laptop's normal fan curve

## Install (Fedora)

```bash
git clone https://github.com/Aliyov/zenfan.git
cd zenfan
sudo ./install.sh
```

Then open **Zenfan** from Activities.

The installer:
1. checks that the laptop is a UX535QE,
2. installs the dependencies (`dkms`, `kernel-devel`, GTK4/libadwaita for Python),
3. builds the GPU fan driver with DKMS, so it rebuilds by itself on kernel updates,
4. installs the app, a polkit helper and the `zenfan-boostd` service.

To update later, run `git pull` and then `sudo ./install.sh` again.

### Uninstall

```bash
sudo ./install.sh --uninstall
```

This puts both fans back to automatic and removes the app, driver, service and settings.

### Secure Boot

If Secure Boot is on, DKMS signs the driver with its own key. If the GPU switch says
"driver not loaded", enroll the key once and reboot:

```bash
sudo mokutil --import /var/lib/dkms/mok.pub
```

## Command line (optional)

`fan.sh` works with or without the app installed. The GPU part needs the driver.

```bash
./fan.sh               # show fan speeds and modes
sudo ./fan.sh on       # both fans full speed
sudo ./fan.sh off      # both fans automatic
sudo ./fan.sh gpu on   # only the GPU fan (also: cpu on/off, gpu off)
```

After installing, you can also run `sudo app/test_zenfan.sh` for a full self-test of the
driver, both fans and auto-boost.

## How it works

| Fan | Mechanism |
|---|---|
| CPU | kernel `asus_wmi` driver: `pwm1_enable` (0 = full, 2 = auto) |
| GPU | `zenbook_gpufan` driver: `/proc/zenbook_gpufan` (1 = full, 0 = auto) |

The BIOS's own "GPU fan" command has a bug: it changes the CPU fan's control byte (EC RAM
`0x30`). The GPU fan is driven by the embedded controller, not by NVIDIA (`nvidia-smi` shows
no fans). Its real control byte is **EC RAM `0x37`**, and bit `0x40` forces full speed.
`zenbook_gpufan` sets only that one bit. It uses the BIOS's own ACPI methods
(`\_SB.PCI0.SBRG.EC0.RRAM/WRAM`), so there is no raw port poking.

Safety built into the driver:
- it loads only on a UX535QE, and only if EC `0x37` holds the expected value (`0x8b`/`0xcb`),
- the only write it can do is toggling bit `0x40` of `0x37`,
- unloading the driver puts the GPU fan back to automatic.

The full decoded EC map is in [`docs/EC_MAP.md`](docs/EC_MAP.md).

> **No custom fan curves.** Rewriting the EC's fan-curve tables was tried and made the EC
> **stop both fans** while the CPU hit 80 °C. This project deliberately only uses the
> full-speed bits.

## Windows

[`windows/`](windows/) has a PowerShell tray app (CPU fan, profiles, auto-boost) built on
ASUS's ATKACPI driver. GPU fan control on Windows needs a kernel driver and isn't done yet.
See [`docs/WINDOWS_NOTES.md`](docs/WINDOWS_NOTES.md).

## Files

```
install.sh            one-command installer (calls app/install.sh)
fan.sh                command-line fan control
app/                  GTK4 app, root helper, auto-boost service, polkit policy
driver/               zenbook_gpufan kernel module (DKMS)
windows/              Windows 11 PowerShell version (CPU fan only)
docs/                 EC RAM map, Windows porting notes
```

## Disclaimer

Tested on one UX535QE, BIOS 310, Fedora 44. It writes to your laptop's embedded controller.
Use at your own risk. Other models are refused on purpose.

License: GPL-2.0
