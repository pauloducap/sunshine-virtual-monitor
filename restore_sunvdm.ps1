# Brings the physical displays back when a session was never torn down
# (crash, power loss, reboot while streaming).
#
#   restore_sunvdm.ps1             restore only if a session from before the last boot is pending
#   restore_sunvdm.ps1 -Force      restore now, whatever the session state
#   restore_sunvdm.ps1 -Install    register a scheduled task running this script at logon (needs admin)
#   restore_sunvdm.ps1 -Uninstall  remove that scheduled task (needs admin)
param(
    [switch]$Force,
    [switch]$Install,
    [switch]$Uninstall
)

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

$scriptPath  = $MyInvocation.MyCommand.Source
$filePath    = Split-Path $scriptPath
$sessionFile = Join-Path $filePath "session.lock"
$teardown    = Join-Path $filePath "teardown_sunvdm.ps1"
$logFile     = Join-Path $filePath "sunvdm_restore.log"
$taskName    = "sunvdm-restore"

if ($Install) {
    $user      = "$env:USERDOMAIN\$env:USERNAME"
    $action    = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/C powershell.exe -executionpolicy bypass -windowstyle hidden -file `"$scriptPath`" > `"$logFile`" 2>&1"
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-Host "scheduled task '$taskName' registered, runs at logon of $user"
    exit
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "scheduled task '$taskName' removed"
    exit
}

if (-not (Test-Path $sessionFile)) {
    if (-not $Force) {
        Write-Host "no pending session, nothing to restore"
        exit
    }
    Write-Host "no pending session, restoring anyway (-Force)"
} else {
    $sessionStart = (Get-Item $sessionFile).LastWriteTime
    $lastBoot     = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime

    # with fast startup LastBootUpTime is not updated, the kernel boot event is
    try {
        $bootEvent = Get-WinEvent -FilterHashtable @{ LogName = "System"; ProviderName = "Microsoft-Windows-Kernel-Boot"; Id = 27 } -MaxEvents 1 -ErrorAction Stop
        if ($bootEvent.TimeCreated -gt $lastBoot) { $lastBoot = $bootEvent.TimeCreated }
    } catch {}

    # a session started after the last boot may still be streaming
    if ($sessionStart -gt $lastBoot -and -not $Force) {
        Write-Host "session started $($sessionStart.ToString('s')), after the last boot ($($lastBoot.ToString('s'))): it may still be streaming, nothing done"
        Write-Host "use -Force to restore anyway"
        exit
    }
    Write-Host "session started $($sessionStart.ToString('s')) was never torn down, restoring"
}

& $teardown
