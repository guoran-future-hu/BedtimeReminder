$ErrorActionPreference = 'Stop'

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = Join-Path $BaseDir "bedtime.ps1"
$TaskName = "BedtimeReminder"

function Test-IsAdmin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$existingTask = $null
try {
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
} catch {
    $existingTask = $null
}

if ($existingTask) {
    Write-Host "Existing task found. Unregistering: $TaskName"
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "Unregistered: $TaskName"
    } catch {
        Write-Host "Failed to unregister with PowerShell: $_"
        Write-Host "Attempting schtasks.exe deletion..."
        try {
            & schtasks.exe /Delete /TN $TaskName /F | Out-Null
            Write-Host "schtasks.exe delete attempted. Re-checking..."
            $check = $null
            try {
                $check = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            } catch {
                $check = $null
            }
            if ($check) {
                Write-Host "Task still exists. You likely need to run this installer as Administrator once to remove it."
                Write-Host "Press any key to exit..."
                [void][System.Console]::ReadKey($true)
                exit 1
            }
            Write-Host "Unregistered: $TaskName"
        } catch {
            Write-Host "Failed to delete with schtasks.exe: $_"
            Write-Host "Press any key to exit..."
            [void][System.Console]::ReadKey($true)
            exit 1
        }
    }
}

if (-not (Test-Path -LiteralPath $BaseDir)) {
    New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
    Write-Host "Created directory: $BaseDir"
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Missing script: $ScriptPath"
}
Write-Host "Found script: $ScriptPath"

if (-not (Get-Module -ListAvailable -Name BurntToast)) {
    Write-Host "BurntToast not found; installing for current user..."
    Install-Module -Name BurntToast -Scope CurrentUser -Force -AllowClobber
} else {
    Write-Host "BurntToast is installed."
}

$action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" -WorkingDirectory $BaseDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Bedtime reminder toast loop"
Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force
Write-Host "Scheduled task registered: $TaskName"

try {
    $info = Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
    Write-Host ("Task state: {0}, last run: {1}, last result: {2}" -f $info.State, $info.LastRunTime, $info.LastTaskResult)
} catch {
    Write-Host "Unable to query task info: $_"
}
Write-Host "Done. Press any key to exit..."
[void][System.Console]::ReadKey($true)
