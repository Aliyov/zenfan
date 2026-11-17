#Requires -Version 5.1
<#
  Zenfan for Windows 11 - ASUS Zenbook UX535QE
  ---------------------------------------------
  - CPU fan full speed on/off            (BIOS cmd DEVS 0x00110013)
  - Fan profile quiet/balanced/performance (DEVS 0x00110019)
  - Auto-boost: CPU fan full speed at ON C, automatic below OFF C
  - Shows CPU/GPU fan RPM and CPU temperature
  Talks to the BIOS through ASUS's own driver \\.\ATKACPI (same as MyASUS /
  G-Helper). Needs "ASUS System Control Interface" installed and admin rights.

  GPU fan full speed is NOT possible on Windows: the BIOS GPU-fan command
  writes the CPU fan byte (ASUS bug). On Linux the zenbook_gpufan driver
  fixes that by writing EC 0x37 directly.

  Usage:
    Zenfan.ps1              open window
    Zenfan.ps1 -Tray        start hidden in the tray (used at logon)
    Zenfan.ps1 -Diagnose    read-only self-check, changes nothing
#>
param([switch]$Tray, [switch]$Diagnose)
$ErrorActionPreference = 'Stop'
$DEG = [char]0x00B0

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class Atk {
    const uint CTL  = 0x0022240C;
    const uint DEVS = 0x53564544;   // "DEVS" set device
    const uint DSTS = 0x53545344;   // "DSTS" get status
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, uint inLen,
        byte[] outBuf, uint outLen, out uint returned, IntPtr overlapped);
    static SafeFileHandle h;
    public static bool Open() {
        if (h != null && !h.IsInvalid) return true;
        h = CreateFile(@"\\.\ATKACPI", 0xC0000000, 3, IntPtr.Zero, 3, 0x80, IntPtr.Zero);
        return !h.IsInvalid;
    }
    static int Call(uint method, uint id, uint val) {
        byte[] b = new byte[16];
        BitConverter.GetBytes(method).CopyTo(b, 0);
        BitConverter.GetBytes((uint)8).CopyTo(b, 4);
        BitConverter.GetBytes(id).CopyTo(b, 8);
        BitConverter.GetBytes(val).CopyTo(b, 12);
        byte[] o = new byte[16];
        uint r;
        if (!Open())
            throw new Exception("Cannot open \\\\.\\ATKACPI (install 'ASUS System Control Interface' and run as administrator)");
        if (!DeviceIoControl(h, CTL, b, (uint)b.Length, o, (uint)o.Length, out r, IntPtr.Zero))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return BitConverter.ToInt32(o, 0);
    }
    public static int Get(uint id) { return Call(DSTS, id, 0); }
    public static int Set(uint id, uint val) { return Call(DEVS, id, val); }
}
"@

$ID_CPU_FAN = 0x00110013
$ID_GPU_FAN = 0x00110014
$ID_PROFILE = 0x00110019
$PROFILES   = [ordered]@{ 'Quiet' = 2; 'Balanced' = 0; 'Performance' = 1 }
$DATA       = Join-Path $env:ProgramData 'Zenfan'
$SETTINGS   = Join-Path $DATA 'settings.json'

function Get-Rpm([uint32]$id) {
    $r = [Atk]::Get($id)
    if ($r -band 0x10000) { return ($r -band 0xFFFF) * 100 }   # 0x0001xxxx = present, xxxx = RPM/100
    return 0
}
function Get-Profile { return [Atk]::Get($ID_PROFILE) -band 0xFF }
function Set-CpuFull([bool]$on) { [void][Atk]::Set($ID_CPU_FAN, [uint32]([int]$on)) }

function Get-CpuTemp {
    # ACPI thermal zone = CPU temperature on this laptop (checked on Linux: 41 vs 41.9 C)
    try {
        $z = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop |
             Sort-Object HighPrecisionTemperature -Descending | Select-Object -First 1
        if ($z -and $z.HighPrecisionTemperature) { return [math]::Round($z.HighPrecisionTemperature / 10 - 273.15) }
    } catch {}
    try {
        $z = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop |
             Select-Object -First 1
        if ($z) { return [math]::Round($z.CurrentTemperature / 10 - 273.15) }
    } catch {}
    return $null
}

# ---------------------------------------------------------------- diagnose
if ($Diagnose) {
    Write-Host "Zenfan read-only diagnose (changes nothing)`n"
    $model = (Get-CimInstance Win32_ComputerSystem).Model
    Write-Host "Model         : $model"
    if ($model -notmatch 'UX535QE') { Write-Host "WARNING: made for UX535QE" -ForegroundColor Yellow }
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
    Write-Host "Administrator : $admin"
    if (-not [Atk]::Open()) {
        Write-Host "ATKACPI       : NOT available" -ForegroundColor Red
        Write-Host "Install 'ASUS System Control Interface' (MyASUS or asus.com support page for UX535QE) and run as admin."
        exit 1
    }
    Write-Host "ATKACPI       : OK" -ForegroundColor Green
    Write-Host ("CPU fan       : {0} RPM   (raw 0x{1:X8})" -f (Get-Rpm $ID_CPU_FAN), [Atk]::Get($ID_CPU_FAN))
    Write-Host ("GPU fan       : {0} RPM   (raw 0x{1:X8})" -f (Get-Rpm $ID_GPU_FAN), [Atk]::Get($ID_GPU_FAN))
    $p = Get-Profile
    Write-Host ("Profile       : {0} ({1})" -f $p, (($PROFILES.GetEnumerator() | Where-Object Value -eq $p).Name))
    $t = Get-CpuTemp
    Write-Host ("CPU temp      : {0}" -f $(if ($null -ne $t) { "$t $($DEG)C" } else { 'not available' }))
    exit 0
}

# ---------------------------------------------------------------- single instance
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\ZenfanMutex', [ref]$created)
$showEvt = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Global\ZenfanShow')
if (-not $created) { [void]$showEvt.Set(); exit 0 }    # already running: ask it to show itself

# ---------------------------------------------------------------- settings
function Load-Settings {
    $s = @{ boost = $true; on = 80; off = 65 }
    if (Test-Path $SETTINGS) {
        try {
            $j = Get-Content $SETTINGS -Raw | ConvertFrom-Json
            foreach ($k in 'boost', 'on', 'off') { if ($null -ne $j.$k) { $s[$k] = $j.$k } }
        } catch {}
    }
    return $s
}
function Save-Settings {
    New-Item -ItemType Directory -Force -Path $DATA | Out-Null
    @{ boost = $script:cfg.boost; on = $script:cfg.on; off = $script:cfg.off } |
        ConvertTo-Json | Set-Content -Path $SETTINGS -Encoding UTF8
}
$cfg = Load-Settings

# ---------------------------------------------------------------- fan state
$manual  = $false     # user's CPU switch
$boosted = $false     # auto-boost active
$applied = $null      # what we last sent to the BIOS
function Apply-Cpu {
    $want = $script:manual -or $script:boosted
    if ($want -ne $script:applied) { Set-CpuFull $want; $script:applied = $want }
}
if (-not [Atk]::Open()) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("Cannot open ASUS ATKACPI driver.`n`nInstall 'ASUS System Control Interface' and run Zenfan as administrator.", 'Zenfan') | Out-Null
    exit 1
}
Apply-Cpu   # start from a known state: automatic

# ---------------------------------------------------------------- GUI
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Zenfan'
$form.ClientSize = New-Object System.Drawing.Size(380, 430)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.Icon = [System.Drawing.SystemIcons]::Application

function Add-Group($text, $y, $h) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $text; $g.Location = New-Object System.Drawing.Point(12, $y)
    $g.Size = New-Object System.Drawing.Size(356, $h)
    $form.Controls.Add($g); return $g
}
function Add-Label($parent, $text, $x, $y, $w = 160) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, 22)
    $parent.Controls.Add($l); return $l
}

# status
$gs = Add-Group 'Status' 8 120
Add-Label $gs 'CPU fan' 12 24 | Out-Null;          $lCpu   = Add-Label $gs '...' 190 24
Add-Label $gs 'GPU fan' 12 48 | Out-Null;          $lGpu   = Add-Label $gs '...' 190 48
Add-Label $gs 'CPU temperature' 12 72 | Out-Null;  $lTemp  = Add-Label $gs '...' 190 72
Add-Label $gs 'Auto-boost' 12 96 | Out-Null;       $lBoost = Add-Label $gs '...' 190 96

# full speed
$gf = Add-Group 'Full speed (on = full, off = automatic)' 136 84
$cbCpu = New-Object System.Windows.Forms.CheckBox
$cbCpu.Text = 'CPU fan full speed'; $cbCpu.Location = New-Object System.Drawing.Point(12, 24)
$cbCpu.Size = New-Object System.Drawing.Size(320, 24); $gf.Controls.Add($cbCpu)
$cbGpu = New-Object System.Windows.Forms.CheckBox
$cbGpu.Text = 'GPU fan full speed (Linux only - BIOS bug)'; $cbGpu.Enabled = $false
$cbGpu.Location = New-Object System.Drawing.Point(12, 50)
$cbGpu.Size = New-Object System.Drawing.Size(330, 24); $gf.Controls.Add($cbGpu)

# profile
$gp = Add-Group 'Fan profile (also changes the GPU fan curve)' 228 60
$cbProf = New-Object System.Windows.Forms.ComboBox
$cbProf.DropDownStyle = 'DropDownList'; $cbProf.Location = New-Object System.Drawing.Point(12, 24)
$cbProf.Size = New-Object System.Drawing.Size(200, 24)
$PROFILES.Keys | ForEach-Object { [void]$cbProf.Items.Add($_) }
$gp.Controls.Add($cbProf)

# auto-boost
$gb = Add-Group 'Auto-boost (CPU fan)' 296 120
$cbBoost = New-Object System.Windows.Forms.CheckBox
$cbBoost.Text = 'Use auto-boost'; $cbBoost.Location = New-Object System.Drawing.Point(12, 24)
$cbBoost.Size = New-Object System.Drawing.Size(200, 24); $gb.Controls.Add($cbBoost)
Add-Label $gb "Full speed when CPU reaches ($($DEG)C)" 12 56 240 | Out-Null
$nOn = New-Object System.Windows.Forms.NumericUpDown
$nOn.Minimum = 41; $nOn.Maximum = 100; $nOn.Location = New-Object System.Drawing.Point(270, 54)
$nOn.Size = New-Object System.Drawing.Size(70, 24); $gb.Controls.Add($nOn)
Add-Label $gb "Back to automatic below ($($DEG)C)" 12 86 240 | Out-Null
$nOff = New-Object System.Windows.Forms.NumericUpDown
$nOff.Minimum = 40; $nOff.Maximum = 99; $nOff.Location = New-Object System.Drawing.Point(270, 84)
$nOff.Size = New-Object System.Drawing.Size(70, 24); $gb.Controls.Add($nOff)

$cbBoost.Checked = [bool]$cfg.boost
$nOn.Value = [decimal]$cfg.on
$nOff.Value = [decimal]$cfg.off
$p = Get-Profile
$cbProf.SelectedItem = ($PROFILES.GetEnumerator() | Where-Object Value -eq $p | Select-Object -First 1).Name

# tray
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Application
$tray.Text = 'Zenfan'
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Open Zenfan')
$miExit = $menu.Items.Add('Exit (fans back to automatic)')
$tray.ContextMenuStrip = $menu

function Show-Window { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() }
$miOpen.add_Click({ Show-Window })
$tray.add_DoubleClick({ Show-Window })
$script:exiting = $false
$miExit.add_Click({
    $script:exiting = $true
    $script:manual = $false; $script:boosted = $false; Apply-Cpu
    $tray.Visible = $false
    $form.Close()
    [System.Windows.Forms.Application]::Exit()
})
$form.add_FormClosing({
    param($s, $e)
    if (-not $script:exiting) {   # X = hide to tray, auto-boost keeps running
        $e.Cancel = $true; $form.Hide()
        $tray.ShowBalloonTip(2000, 'Zenfan', 'Still running in the tray (auto-boost active).', 'Info')
    }
})

# handlers
$cbCpu.add_CheckedChanged({ $script:manual = $cbCpu.Checked; Apply-Cpu })
$cbProf.add_SelectionChangeCommitted({ [void][Atk]::Set($ID_PROFILE, [uint32]$PROFILES[$cbProf.SelectedItem]) })
$saveBoost = {
    if ($nOff.Value -ge $nOn.Value) {
        $lBoost.Text = "'Back' must be lower"; return
    }
    $script:cfg.boost = $cbBoost.Checked
    $script:cfg.on = [int]$nOn.Value
    $script:cfg.off = [int]$nOff.Value
    Save-Settings
}
$cbBoost.add_CheckedChanged($saveBoost)
$nOn.add_ValueChanged($saveBoost)
$nOff.add_ValueChanged($saveBoost)

# main loop (every 2 s)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.add_Tick({
    try {
        if ($showEvt.WaitOne(0)) { Show-Window }
        $t = Get-CpuTemp
        $c = $script:cfg
        if (-not $c.boost -or $c.off -ge $c.on -or $null -eq $t) {
            $script:boosted = $false
        } elseif ($t -ge $c.on) {
            $script:boosted = $true
        } elseif ($t -le $c.off) {
            $script:boosted = $false
        }
        Apply-Cpu
        $lCpu.Text  = "$(Get-Rpm $ID_CPU_FAN) RPM" + $(if ($script:applied) { '  (FULL)' } else { '' })
        $lGpu.Text  = "$(Get-Rpm $ID_GPU_FAN) RPM"
        $lTemp.Text = if ($null -ne $t) { "$t $($DEG)C" } else { 'n/a' }
        $lBoost.Text = if (-not $c.boost) { 'Off' } elseif ($script:boosted) { 'Boosting now' } else { 'Watching' }
        $tray.Text = "Zenfan - CPU $($lTemp.Text), $($lBoost.Text)"
    } catch {
        $lBoost.Text = 'Error: ' + $_.Exception.Message
    }
})
$timer.Start()

if (-not $Tray) { $form.Show() }
[System.Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()
