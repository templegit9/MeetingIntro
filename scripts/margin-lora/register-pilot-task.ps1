$ErrorActionPreference = 'Stop'
$taskName = 'Margin-Empero-LoRA-Pilot-20260912'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Task already exists; inspect before replacing.' }
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\wsl.exe' -Argument '-d Ubuntu-24.04 -- bash /mnt/c/Users/oluyi/Documents/Projects/Margin-Empero-LoRA/scripts/run-pilot.sh'
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Description 'User-authorized Margin LoRA pilot; manually started after export checks; no automatic trigger.' | Select-Object TaskName,State
