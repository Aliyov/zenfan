#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
  Installs Zenfan for Windows:
   - copies Zenfan.ps1 to C:\Program Files\Zenfan
   - scheduled task "Zenfan": starts in the tray at every logon, as admin,
     without a UAC prompt (needed for the ASUS ATKACPI driver)
   - Start Menu shortcut "Zenfan" (opens the window)
  Uninstall:  .\Install.ps1 -Uninstall
#>
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$dir  = Join-Path $env:ProgramFiles 'Zenfan'
$lnk  = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Zenfan.lnk'
$task = 'Zenfan'

if ($Uninstall) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object CommandLine -match 'Zenfan\.ps1' |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "$task Open" -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $lnk, $dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Zenfan removed. (Fans return to automatic at the next reboot, or toggle in MyASUS.)"
    exit 0
}

# check first
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Zenfan.ps1') -Diagnose
if ($LASTEXITCODE -ne 0) { Write-Host "`nDiagnose failed - not installing." -ForegroundColor Red; exit 1 }

New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'Zenfan.ps1') $dir -Force
$script = Join-Path $dir 'Zenfan.ps1'

$psArgs    = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
# 1) "Zenfan": at logon, hidden in the tray (runs auto-boost)
Register-ScheduledTask -TaskName $task -Principal $principal -Settings $settings -Force `
    -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "$psArgs -Tray") `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME) | Out-Null
# 2) "Zenfan Open": no trigger, used by the Start Menu shortcut. If Zenfan is
#    already in the tray, this short-lived instance tells it to show its window.
Register-ScheduledTask -TaskName "$task Open" -Principal $principal -Settings $settings -Force `
    -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs) | Out-Null

# Start Menu shortcut: runs the elevated task (no UAC prompt)
$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut($lnk)
$s.TargetPath = "$env:SystemRoot\System32\schtasks.exe"
$s.Arguments = "/run /tn `"$task Open`""
$s.WindowStyle = 7
$s.IconLocation = "$env:SystemRoot\System32\imageres.dll,109"
$s.Description = 'Zenfan fan control'
$s.Save()

Start-ScheduledTask -TaskName $task
Write-Host "`nZenfan installed. It is now in the tray (bottom-right, ^ arrow)."
Write-Host "Open it from the Start Menu: 'Zenfan'. It starts automatically at every logon."
