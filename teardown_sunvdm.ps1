Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

Import-Module WindowsDisplayManager

$filePath = Split-Path $MyInvocation.MyCommand.source
$displayStateFile = Join-Path -Path $filePath -ChildPath "display_state.json"
$stateFile = Join-Path -Path $filePath -ChildPath "state.json"
$sessionFile = Join-Path -Path $filePath -ChildPath "session.lock"
$vsynctool = Join-Path -Path $filePath -ChildPath "vsynctoggle-1.1.0-x86_64.exe"
$multitool = Join-Path -Path $filePath -ChildPath "multimonitortool-x64\MultiMonitorTool.exe"

# + Choose the exact name of the Virtual Monitor to allow different versions without breaking the script.
$vdd_candidates = @(
    Get-PnpDevice -Class Display |
    Where-Object {
        $_.FriendlyName -like "*idd*" -or
        $_.FriendlyName -like "*mtt*" -or
        $_.FriendlyName -like "Virtual Display*"
    }
)
# several devices can match, e.g. a leftover IddSampleDriver next to VDD by
# MTT, or a ghost of a previous install: prefer present devices (a ghost cannot
# be enabled), then VDD by MTT
$vdd_name = (
    $vdd_candidates |
    Sort-Object @{ Expression = { -not $_.Present } },
                @{ Expression = { -not (($_.HardwareID -match "MttVDD") -or $_.FriendlyName -like "*mtt*" -or $_.FriendlyName -like "Virtual Display*") } } |
    Select-Object -First 1
).FriendlyName
if ($vdd_candidates.Count -gt 1) {
    Write-Host "WARNING: several virtual display devices found ($($vdd_candidates.FriendlyName -join ', ')), using $vdd_name"
}

# Try a couple of times, it can sometimes take a couple of tries.
# Might not work well if you have more than one GPU with displays attached. See https://github.com/patrick-theprogrammer/WindowsDisplayManager/issues/1
#
function Restore-Displays($tries) {
    if (-not (Test-Path $displayStateFile)) { return $false }
    for ($i = 0; $i -lt $tries; $i++) {
        if ($i -gt 0) { Start-Sleep -Seconds 2 }
        try {
            if (WindowsDisplayManager\UpdateDisplaysFromFile -filePath $displayStateFile -disableNotSpecifiedDisplays -validate) { return $true }
        } catch {
            Write-Host "WARNING: restore attempt failed: $_"
        }
    }
    return $false
}

# Bring the physical displays back while the virtual display is still there:
# if the restore fails, at least one display stays usable.
#
if (-not (Test-Path $displayStateFile)) {
    Write-Host "WARNING: $displayStateFile not found, cannot restore the saved display state"
} else {
    Write-Host "Restoring the physical displays."
    if (-not (Restore-Displays 3)) { Write-Host "restore before removing the moonlight display did not converge, will retry after" }
}

if (Test-Path $stateFile) {
    try { & $vsynctool (Get-Content -Raw $stateFile | ConvertFrom-Json).vsync } catch { Write-Host "WARNING: could not restore vsync: $_" }
} else {
    Write-Host "WARNING: $stateFile not found, vsync left untouched"
}

if ($vdd_name) {
    Write-Host "Removing the moonlight display."
    Get-PnpDevice -FriendlyName $vdd_name | Disable-PnpDevice -Confirm:$false
    if ((Get-PnpDevice -FriendlyName $vdd_name).Status -eq "OK") { Write-Host "WARNING: the moonlight display is still enabled" }
} else {
    Write-Host "WARNING: virtual display device not found, nothing to remove"
}

# Removing the virtual display can change the topology again, so check the
# final state against the saved one.
#
if (Restore-Displays 5) {
    Write-Host "Successfully removed the moonlight display."
} else {
    # Last resort: never leave the machine without an active display.
    Write-Host "WARNING: failure restoring display state from file, enabling every display"
    foreach ($d in (WindowsDisplayManager\GetAllPotentialDisplays | Where-Object { -not $_.active })) {
        & $multitool /enable $d.source.name
    }
    Start-Sleep -Seconds 2
    $active = @(WindowsDisplayManager\GetAllPotentialDisplays | Where-Object { $_.active })
    Write-Host "active displays after fallback: $($active.source.name -join ', ')"
}

# the session is over, setup may save a fresh display state next time
Remove-Item $sessionFile -ErrorAction SilentlyContinue
