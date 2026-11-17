# ASUS Zenbook UX535QE - EC RAM fan map (BIOS 310)

Decoded READ-ONLY from `capture2.sh` (142 samples). Access = BIOS ACPI methods:
read `\_SB.PCI0.SBRG.EC0.RRAM(0xCC, addr)`, write `WRAM(0xCD, addr, val)`.
Nothing below has been written yet except 0x30 bit 0x40, which the BIOS
itself writes for "CPU fan full speed".

## Live state
| addr | CPU fan | addr | GPU fan | meaning |
|------|---------|------|---------|---------|
| 0x30 | 85 / c5 | 0x37 | 8b      | control flags. **bit 0x40 = force full speed** (CPU, proven) |
| 0x31 | 87      | 0x38 | 87      | ? (constant) |
| 0x32 | 1..8    | 0x39 | 1..4    | current curve step (level) |
| 0x33 | °C      | 0x3a | °C      | temperature fed to the curve (both = CPU temp, 0x00) |
| 0x34 | 0..255  | 0x3b | 0..255  | PWM duty output (CPU full speed = 0xff) |
| 0x35-36 | RPM (LE16) | 0x3c-3d | RPM (LE16) | measured speed (= hwmon fan1/fan2) |

0x00 = CPU temp, 0x01/0x02 = ? temp (44-59), 0x03/0x04 = GPU temp.
0x10 bit 0x02 = dGPU present/powered (BIOS checks it before GPU fan cmd).

## Fan curves (8 steps)
| CPU addr | GPU addr | content |
|----------|----------|---------|
| 0x40-47  | 0x68-6f  | step-up temps: 43 48 52 55 58 68 99 99 °C |
| 0x48-4f  | 0x70-77  | 08 05 05 05 05 08 04 04 (hysteresis/delay?) |
| 0x50-57  | 0x78-7f  | duty per step: CPU 75 78 91 104 118 139 173 173 / GPU 75 78 88 100 114 133 164 164 |
| 0x58-67  | 0x80-8f  | 0a 14 1e 32 01 02 05 0a / 0a 14 1e 32 01 03 05 0a (ramp timing?) |
| 0xb0-bf  | 0xc0-cf  | target RPM per step (LE16): 2000 2300 2600 2900 3200 3600 4200 4200 |

0x90 / 0x99: status byte (bit 0x40 toggles every few s) + 2b 32 36 3a 3c 43 3f 3f
(second temp table, maybe step-down temps).

## Write tests
1. **WORKS** - GPU full speed = set bit 0x40 in 0x37 (8b -> cb). GPU fan
   1900 -> 5700 RPM in 2 s, restoring 8b returns to the curve. The BIOS
   "GPU fan" command writes 0x30 instead (ASUS bug). Used by driver/.
2. **FAILED - DO NOT REPEAT** - rewriting the curve tables (0x40-47, 0x50-57,
   0x68-6f, 0x78-7f, 0xb0-cf) while the EC runs. Tables were written
   correctly, but the EC then stayed at step 0 (fans 0 RPM) while the CPU
   rose 43 -> 80 °C, and rewrote part of the table by itself once. The EC
   has hidden state (checksum / load flag / the unmapped 0x48, 0x58, 0x91
   tables). Code archived in experiments/fancurve_FAILED/.
