$ErrorActionPreference = 'Stop'
$taskName = 'Margin-Vision-Separated-20260913b'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Task exists; inspect rather than replace.' }
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\wsl.exe' -Argument '-d Ubuntu-24.04 -- /home/oluyi/.venvs/margin-empero-lora/bin/python -u /mnt/c/Users/oluyi/Documents/Projects/Margin-Vision-Pilot/separated-20260913b/supervisor.py'
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Description 'Authorized serial comparison: unadapted and epochs 1, 2, 3; no automatic trigger.' | Select-Object TaskName,State
Start-ScheduledTask -TaskName $taskName
Get-ScheduledTask -TaskName $taskName | Select-Object TaskName,State
