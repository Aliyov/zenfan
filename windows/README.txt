ZENFAN FOR WINDOWS 11 - ASUS Zenbook UX535QE
=============================================

What it does
  - CPU fan full speed on/off
  - Fan profile: Quiet / Balanced / Performance (also changes GPU fan curve)
  - Auto-boost: CPU fan full speed at 80 C, automatic below 65 C (editable)
  - Shows CPU fan RPM, GPU fan RPM, CPU temperature
  - Lives in the tray, starts at logon, no UAC prompt

What it can NOT do on Windows
  - GPU fan full speed. The BIOS GPU-fan command writes the CPU fan byte
    (ASUS bug). Linux Zenfan fixes this with its own kernel driver; Windows
    would need an unsigned kernel driver, so it is left out.

Needs
  - "ASUS System Control Interface" driver (comes with MyASUS, or download
    it from asus.com -> Support -> UX535QE -> Driver & Tools -> Software).
    Check: Device Manager -> System devices -> "ASUS System Control Interface".

STEP 1 - read-only check (changes nothing)
  Open "Terminal (Admin)" in this folder and run:
      powershell -ExecutionPolicy Bypass -File .\Zenfan.ps1 -Diagnose
  You should see "ATKACPI : OK", fan RPMs, profile and CPU temp.

STEP 2 - try it without installing
      powershell -ExecutionPolicy Bypass -File .\Zenfan.ps1
  Tick "CPU fan full speed" -> CPU fan should go to ~5500 RPM.

STEP 3 - install (starts at logon, Start Menu entry "Zenfan")
      powershell -ExecutionPolicy Bypass -File .\Install.ps1

Uninstall
      powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall

Notes
  - Closing the window (X) hides it to the tray; auto-boost keeps running.
    Tray icon -> right-click -> "Exit" turns the fan back to automatic.
  - MyASUS / Armoury Crate may also change the fan profile. If the profile
    jumps back by itself, set it in MyASUS too, or close MyASUS.
  - Settings: C:\ProgramData\Zenfan\settings.json
