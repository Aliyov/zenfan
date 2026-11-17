# Zenfan: notes for the Claude running on Windows

You're on the Windows 11 side of a dual boot. The machine is an **ASUS Zenbook UX535QE**
(Ryzen 7 5800H + RTX 3050 Ti, BIOS 310). On Fedora Linux we built "Zenfan", a fan control
app. This file covers what we found, what works and what failed, and how to get **GPU fan
control** on Windows, which is the part you're stuck on.

Read all of it before you touch hardware. Section 6 has the safety rules and they are not
optional.

---

## 1. What the Linux app does (feature target)

- **CPU fan full speed** on/off.
- **GPU fan full speed** on/off. This is the hard part.
- **Auto-boost.** When the CPU reaches ON °C (default 80), both fans go to full speed. When it
  cools to OFF °C (default 65), they go back to automatic. A fan the user switched on by hand
  is never switched off by auto-boost. Limits are 40 ≤ OFF < ON ≤ 100.
- Shows CPU fan RPM, GPU fan RPM and CPU temperature, refreshed every 2 s.
- Runs as a background service, so auto-boost keeps working when the window is closed.
- Turns everything back to automatic on exit or unload.

There is **no custom fan curve** on purpose (see section 5).

Linux pieces, for reference (in `~/Projects/Fan` on the Linux partition):
| file | role |
|---|---|
| `driver/zenbook_gpufan.c` | kernel module: GPU fan full speed through EC RAM 0x37 |
| `app/zenfan-gui` | GTK4 window |
| `app/zenfan-helper` | root helper, allows only `cpu/gpu/all on/off` and `boost on ON OFF / off` |
| `app/zenfan-boostd` | auto-boost service |
| `ecdump/EC_MAP.md` | decoded EC RAM map |
| `windows/Zenfan.ps1`, `Install.ps1`, `README.txt` | **already-written Windows version: CPU fan only** |

**Start from `windows/Zenfan.ps1`.** It already does CPU full speed, profiles, auto-boost,
RPM, temperature, tray icon and start at logon through ASUS's `\\.\ATKACPI` driver. The only
missing piece is the GPU fan.

---

## 2. The CPU fan path (already working on Windows)

ASUS's driver "ASUS System Control Interface" exposes `\\.\ATKACPI`. Every call is
`DeviceIoControl(h, 0x0022240C, in, 16, out, 16)`:

```
in  = [u32 method][u32 8][u32 device_id][u32 value]
method: 0x53564544 "DEVS" (set)   0x53545344 "DSTS" (get)
```

| device_id | DSTS (read) | DEVS (write) |
|---|---|---|
| `0x00110013` | CPU fan: `0x0001xxxx`, xxxx = RPM/100 | 1 = CPU full speed, 0 = auto. **Works.** |
| `0x00110014` | GPU fan: `0x0001xxxx`, xxxx = RPM/100. **Reading works.** | **Broken (BIOS bug), see below** |
| `0x00110019` | fan profile | 0 Balanced, 1 Performance, 2 Quiet |

CPU temperature: the ACPI thermal zone (`Win32_PerfFormattedData_Counters_ThermalZoneInformation`
or `MSAcpi_ThermalZoneTemperature`) matches the CPU temperature on this laptop.

---

## 3. Why the GPU fan is hard (the key finding)

These are the dead ends. Don't spend time on them again:

1. **NVIDIA doesn't control this fan.** NVML/nvidia-smi report **0 fans**. The EC controls
   the GPU fan, not the GPU.
2. **The BIOS "GPU fan" command is buggy.** In the DSDT, `WMNB` → `DEVS 0x00110014` first
   checks EC RAM `0x10` bit `0x02` (dGPU present), then reads, modifies and writes
   **EC RAM 0x30**. That is the *CPU* fan's control byte, so it's a copy-paste bug from
   `0x00110013`. Through ATKACPI, "GPU fan full speed" only speeds up the CPU fan. That's
   why `Zenfan.ps1` leaves it out.
3. **The normal ACPI EC space (ports 0x62/0x66, `ec_read`) isn't it either.** Reading it
   gives zeros or unrelated data. The fan control bytes live in the EC's **internal RAM**,
   which is a separate address space.
4. **There is no generic "read/write EC RAM" function in ATKACPI/WMNB.** Every
   `RRAM`/`WRAM` call in WMNB uses a fixed address (0x10, 0x30), so ATKACPI can't reach 0x37.

**The real GPU fan control is EC RAM `0x37`, bit `0x40`.**

| EC RAM | CPU fan | EC RAM | GPU fan | meaning |
|---|---|---|---|---|
| 0x30 | 0x85 / 0xC5 | **0x37** | **0x8B / 0xCB** | control flags, **bit 0x40 = force full speed** |
| 0x32 | 1..8 | 0x39 | 1..4 | current curve step |
| 0x33 | °C | 0x3A | °C | temperature fed to the curve |
| 0x34 | 0..255 | 0x3B | 0..255 | PWM duty |
| 0x35-36 | RPM LE16 | 0x3C-3D | RPM LE16 | measured speed |

Verified on 2026-11-17 with the user's approval: writing `0x37 = 0xCB` (0x8B | 0x40) took the
GPU fan from **~1900 to ~5700 RPM in about 2 s**. Writing `0x8B` back returned it to the
automatic curve cleanly.

So the whole GPU feature comes down to one operation: **toggle bit 0x40 of EC RAM 0x37,
and only when the byte currently reads 0x8B or 0xCB.**

---

## 4. How EC RAM is reached (and how to do it on Windows)

### 4.1 What the BIOS does (from DSDT, BIOS 310)

```
\_SB.PCI0.SBRG.EC0.RRAM(0xCC, addr)        -> returns byte
\_SB.PCI0.SBRG.EC0.WRAM(0xCD, addr, value)
```

Both methods take ACPI mutex `MU4T`, fill a 16-byte **shared memory mailbox**, and trigger an
**SMI**. The BIOS SMM handler then talks to the EC:

```
OperationRegion (ECAD, SystemMemory, EGBF, 0x10)   // mailbox, DWordAcc
  +0x00 MFUN u16 = 0x30
  +0x02 SFUN u16 = 0x01
  +0x04 LEN  u16 = 0x10
  +0x06 STAS u8
  +0x07 EROR u8  = 0xFF before the call, 0 = success
  +0x08 CMD  u8  = 0xFF
  +0x09 EDA1 u8  = 0xCC (read) / 0xCD (write);  holds the RESULT after a read
  +0x0A EDA2 u8  = addr >> 8   (0 for us)
  +0x0B EDA3 u8  = addr & 0xFF (0x37)
  +0x0C EDA4 u8  = value to write (write only)
ECAC(): write 0x9C to I/O port 0xB2 (SMCM); retry while EROR != 0, at most 5 tries
```

Where the mailbox lives: `EGBF` is a 32-bit field at offset **0x0C** of the region at `AECB`.
`AECB` is the 32-bit field at offset **0x20** of `RAMW` = SystemMemory **0xBC947000**.
So: `AECB = *(u32*)0xBC947020`, `EGBF = *(u32*)(AECB + 0x0C)`. **These physical addresses are
specific to BIOS 310 and can change with a BIOS update. Dump and check the DSDT on Windows
first** (for example `acpidump` + `iasl -d`, or RWEverything's ACPI tab, read-only), and look
for `Method (RRAM`, `Method (ECAC`, `OperationRegion (ECAD`, `OperationRegion (RAMW` and
`Method (ISMI`.

On Linux we didn't touch any of that by hand. The kernel module calls the BIOS's own method
with `acpi_evaluate_object("\_SB.PCI0.SBRG.EC0.WRAM", {0xCD, 0x37, val})`, which handles the
mutex and the SMI for us. **That's the approach to copy.**

### 4.2 Windows options, best first

User mode can't run ACPI methods or touch port 0xB2 or physical memory, so every working
option needs some kernel-mode code. Explain the trade-offs to the user and let them choose.

**Option A (recommended, faithful port): a small KMDF filter driver that calls `WRAM`/`RRAM`.**
- Install it as an **upper filter on the EC device** (`ACPI\PNP0C09`, Device Manager → System
  devices → "Embedded Controller"). Because the driver then sits in the EC0 device stack,
  it can send `IOCTL_ACPI_EVAL_METHOD` down the stack. Use `ACPI_EVAL_INPUT_BUFFER_COMPLEX`
  with method name `"WRAM"` and 3 integer args (0xCD, 0x37, val), or `"RRAM"` with
  (0xCC, 0x37). These are 4-char names relative to EC0, so no full path is needed.
- ACPI handles the `MU4T` mutex and the SMI, so it never races with the BIOS or MyASUS. This
  is exactly what the Linux driver does.
- Expose one control device (for example `\\.\ZenbookGpuFan`) with two IOCTLs: GET returns
  0/1 and SET takes 0/1. **The driver hard-codes address 0x37 and bit 0x40.** User mode must
  not be able to pass an address or value.
- Mirror the Linux safety checks: on load, check SMBIOS product contains `UX535QE` and that
  `RRAM(0x37)` is 0x8B or 0xCB, otherwise fail to load. Before every write, re-read and refuse
  if `(cur & ~0x40) != 0x8B`. On unload, write 0x8B (back to auto).
- Signing: an unsigned or self-signed driver needs **test-signing mode**
  (`bcdedit /set testsigning on`). That requires **Secure Boot off** in the BIOS and shows a
  "Test Mode" watermark. Tell the user this up front, because it's their decision. (Secure
  Boot off also affects Linux shim/MOK, so ask before suggesting it.)
- Build: Visual Studio + WDK, KMDF. Install with `pnputil` / an INF that adds the filter to
  `ACPI\PNP0C09`. A bad filter INF on the EC can break battery and thermal reporting, so give
  the user a clear uninstall and rollback (remove `UpperFilters` value, reboot) **before**
  installing.

**Option B: a generic signed ring-0 helper (PawnIO, WinRing0, inpoutx64, RwDrv) driving the
mailbox by hand** (write the mailbox at EGBF, `out 0xB2, 0x9C`, poll EROR, read EDA1).
- Works with Secure Boot on (if the helper is signed and not blocklisted), but:
  - It **can't take ACPI mutex MU4T**, so it can race with Windows ACPI using the same mailbox
    (fan RPM reads, MyASUS, WMI). That can corrupt a BIOS EC call.
  - WinRing0 is on Microsoft's vulnerable driver blocklist and Defender flags it. Avoid it.
    PawnIO is the modern signed option. Check whether its module model actually allows
    physical memory and port 0xB2 access before planning around it.
- If the user chooses this option anyway: do one read of 0x37 first and show it to the user.
  Only write if it reads 0x8B, write the full 16-byte mailbox, and always read back to
  confirm. Expect occasional failures and retry.

**Option C: no GPU control** (current `Zenfan.ps1`). This is the safe fallback. As a partial
workaround, profile "Performance" (`DEVS 0x00110019 = 1`) also raises the GPU fan's curve.

### 4.3 How to tell it worked

Read the GPU fan RPM with ATKACPI `DSTS 0x00110014` (low 16 bits × 100). After setting full
speed it should go from roughly 1900–2500 to **~5700 RPM within 2–3 s**. After setting auto it
should drop back to the curve. If the RPM doesn't change, check EC RAM 0x37. If it isn't
0x8B/0xCB, stop and report to the user.

---

## 5. What failed. Do not repeat it.

**Custom fan curves by rewriting EC RAM tables FAILED and were dangerous.** We wrote new values
into the curve tables (CPU 0x40-47 temps, 0x50-57 duty, 0xB0-BF RPM; GPU 0x68-6F, 0x78-7F,
0xC0-CF) while the EC was running. The values were written correctly, but the EC then
**stopped both fans (0 RPM) while the CPU climbed from 43 to 80 °C**, and partly rewrote the
table on its own. The EC has hidden state (checksum or load flag, unmapped tables at 0x48,
0x58, 0x91). Don't offer a fan curve feature. The only EC write this project allows is
**bit 0x40 of 0x37**.

---

## 6. Safety rules from the user (they apply to you too)

1. **Never write EC RAM, or any other hardware state, without the user explicitly approving
   that specific write.** Reads are fine. Before the first real write, describe exactly what
   you'll write (address, old value, new value, how to undo it) and wait for a "yes".
2. The only allowed EC write is `0x37: 0x8B ⇄ 0xCB`. Refuse if the current value is anything
   else.
3. Don't overwrite or delete the user's existing files without asking.
4. Before installing a driver, filter or boot setting (test signing, Secure Boot), explain the
   consequences and the rollback steps, and get approval.
5. Watch temperatures during tests. If a fan reads 0 RPM while the CPU is above ~70 °C, put
   everything back to automatic immediately (CPU: `DEVS 0x00110013 = 0`, GPU: 0x37 = 0x8B).

---

## 7. Suggested plan for Windows

1. Read `windows/Zenfan.ps1`, `README.txt` and `ecdump/EC_MAP.md` (copy them from the Linux
   partition if needed).
2. Run `Zenfan.ps1 -Diagnose` (read-only) and confirm ATKACPI works and GPU RPM is readable.
3. Dump the DSDT on Windows and confirm `RRAM`/`WRAM`/`ECAC`/`ECAD` match section 4.1 (BIOS
   version may differ).
4. Ask the user to choose option A, B or C (section 4.2), with the trade-offs.
5. If A: write the KMDF filter. First version is **read-only** (GET only), confirm it reads
   0x8B. Then, with the user's approval, add SET and test once while watching GPU RPM.
6. Add a "GPU fan full speed" checkbox to `Zenfan.ps1`. Extend auto-boost to drive both fans,
   and never switch off a fan the user turned on manually. On exit, restore auto for both.
