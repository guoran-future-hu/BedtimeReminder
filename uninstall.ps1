$ErrorActionPreference = 'Stop'

$TaskName = "BedtimeReminder"

function Remove-Task {
    param([string]$Name)
    try {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction Stop
        Write-Host "Unregistered: $Name"
        return $true
    } catch {
        Write-Host "Failed to unregister with PowerShell: $_"
    }
    try {
        & schtasks.exe /Delete /TN $Name /F | Out-Null
        Write-Host "schtasks.exe delete attempted."
        try {
            Get-ScheduledTask -TaskName $Name -ErrorAction Stop | Out-Null
            Write-Host "Task still exists. You may need to run as Administrator."
            return $false
        } catch {
            Write-Host "Unregistered: $Name"
            return $true
        }
    } catch {
        Write-Host "Failed to delete with schtasks.exe: $_"
        return $false
    }
}

$ok = Remove-Task -Name $TaskName
if (-not $ok) {
    Write-Host "Press any key to exit..."
    [void][System.Console]::ReadKey($true)
    exit 1
}

Write-Host "Done. Press any key to exit..."
[void][System.Console]::ReadKey($true)
