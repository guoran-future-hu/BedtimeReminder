$ErrorActionPreference = 'Stop'

# Config
$Bedtime = "01:00"
$NoClickDelay = "00:10:00"
$SnoozeDelay = "00:10:00"
$MorningCutoff = "7:00"

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StatePath = Join-Path $BaseDir "state.json"

function Get-SessionId {
    return (Get-Process -Id $PID).SessionId
}

function Parse-TimeSpan {
    param([string]$Value)
    return [TimeSpan]::ParseExact($Value, 'hh\:mm', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Parse-Duration {
    param([string]$Value)
    try {
        return [TimeSpan]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        throw "Invalid duration: $Value. Use mm:ss or hh:mm:ss."
    }
}

function Parse-StateDate {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    try {
        return [DateTime]::Parse($Value)
    } catch {
        return $null
    }
}

function New-DefaultState {
    param([int]$SessionId)
    return [ordered]@{
        sessionId   = $SessionId
        ignoreCount = 0
        mutedUntil  = $null
        nextToast   = $null
        lastCutoff  = $null
    }
}

function Load-State {
    param([int]$SessionId)
    $state = New-DefaultState -SessionId $SessionId
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $state
    }
    try {
        $raw = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop
        if (-not $raw) {
            return $state
        }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $data.sessionId) {
            $state.sessionId = [int]$data.sessionId
        }
        if ($null -ne $data.ignoreCount) {
            $state.ignoreCount = [int]$data.ignoreCount
        }
        if ($null -ne $data.mutedUntil) {
            $state.mutedUntil = $data.mutedUntil
        }
        if ($null -ne $data.nextToast) {
            $state.nextToast = $data.nextToast
        }
        if ($null -ne $data.lastCutoff) {
            $state.lastCutoff = $data.lastCutoff
        }
    } catch {
        return $state
    }
    return $state
}

function Save-State {
    param($State)
    if (-not (Test-Path -LiteralPath $BaseDir)) {
        New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
    }
    $json = $State | ConvertTo-Json -Depth 4
    $json | Out-File -LiteralPath $StatePath -Encoding ASCII
}

function Get-BedtimeWindow {
    param(
        [datetime]$Now,
        [TimeSpan]$Bedtime,
        [TimeSpan]$Cutoff
    )

    $result = [ordered]@{
        Start    = $null
        End      = $null
        InWindow = $false
    }

    if ($Bedtime -le $Cutoff) {
        $start = $Now.Date + $Bedtime
        $end = $Now.Date + $Cutoff
        if ($Now -lt $start) {
            $result.Start = $start
            $result.End = $end
            return $result
        }
        if ($Now -ge $end) {
            $result.Start = $start.AddDays(1)
            $result.End = $end.AddDays(1)
            return $result
        }
        $result.Start = $start
        $result.End = $end
        $result.InWindow = $true
        return $result
    }

    if ($Now.TimeOfDay -ge $Bedtime) {
        $result.Start = $Now.Date + $Bedtime
        $result.End = $Now.Date.AddDays(1) + $Cutoff
        $result.InWindow = $true
        return $result
    }
    if ($Now.TimeOfDay -lt $Cutoff) {
        $result.Start = $Now.Date.AddDays(-1) + $Bedtime
        $result.End = $Now.Date + $Cutoff
        $result.InWindow = $true
        return $result
    }

    $result.Start = $Now.Date + $Bedtime
    $result.End = $Now.Date.AddDays(1) + $Cutoff
    return $result
}

function Get-RecentCutoff {
    param(
        [datetime]$Now,
        [TimeSpan]$Cutoff
    )
    $cutoffToday = $Now.Date + $Cutoff
    if ($Now -ge $cutoffToday) {
        return $cutoffToday
    }
    return $cutoffToday.AddDays(-1)
}

function Sleep-Until {
    param([datetime]$Target)
    $seconds = [int][Math]::Ceiling(($Target - (Get-Date)).TotalSeconds)
    if ($seconds -gt 0) {
        Start-Sleep -Seconds $seconds
    }
}

function Initialize-ToastEvents {
    $global:ToastActivationQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    Unregister-Event -SourceIdentifier 'BedtimeReminder_Activated' -ErrorAction SilentlyContinue
    Register-ObjectEvent -InputObject ([Microsoft.Toolkit.Uwp.Notifications.ToastNotificationManagerCompat]) -EventName OnActivated -SourceIdentifier 'BedtimeReminder_Activated' -Action {
        if (-not $global:ToastActivationQueue) {
            return
        }
        $argument = $Event.SourceEventArgs.Argument
        if (-not [string]::IsNullOrWhiteSpace($argument)) {
            $global:ToastActivationQueue.Enqueue($argument)
        }
    } | Out-Null
}

function Show-Toast {
    param(
        [string]$ToastId,
        [int]$IgnoreCount
    )
    $exclaim = ""
    if ($IgnoreCount -gt 0) {
        $exclaim = "!" * ($IgnoreCount * 3)
    }
    $repeat = [Math]::Max(1, $IgnoreCount + 1)
    $bodyLines = @()
    for ($i = 0; $i -lt $repeat; $i += 1) {
        $bodyLines += ("Time to wind down{0}" -f $exclaim)
    }
    $lines = @(
        ("Bedtime reminder{0}" -f $exclaim),
        ($bodyLines -join "`n")
    )
    $snoozeButton = New-BTButton -Content 'Snooze' -Arguments ("snooze|{0}" -f $ToastId) -ActivationType Background
    $muteButton = New-BTButton -Content 'Emergency work (mute tonight)' -Arguments ("mute|{0}" -f $ToastId) -ActivationType Background
    New-BurntToastNotification -Text $lines -Button @($snoozeButton, $muteButton) -UniqueIdentifier 'BedtimeReminder' | Out-Null
}

function Wait-ToastAction {
    param(
        [TimeSpan]$Timeout,
        [string]$ToastId
    )
    $deadline = (Get-Date).Add($Timeout)
    while ((Get-Date) -lt $deadline) {
        $item = $null
        while ($global:ToastActivationQueue.TryDequeue([ref]$item)) {
            $parts = $item -split '\|', 2
            if ($parts.Length -ge 2 -and $parts[1] -eq $ToastId) {
                return $parts[0]
            }
        }
        Start-Sleep -Seconds 1
    }
    return 'timeout'
}

function Lock-Workstation {
    Start-Process -FilePath "rundll32.exe" -ArgumentList "user32.dll,LockWorkStation" -WindowStyle Hidden
}

Import-Module BurntToast -ErrorAction Stop
Initialize-ToastEvents

$bedtimeSpan = Parse-TimeSpan -Value $Bedtime
$cutoffSpan = Parse-TimeSpan -Value $MorningCutoff
$noClickSpan = Parse-Duration -Value $NoClickDelay
$snoozeSpan = Parse-Duration -Value $SnoozeDelay
$sessionId = Get-SessionId

while ($true) {
    $now = Get-Date
    $state = Load-State -SessionId $sessionId
    $stateChanged = $false

    if ($state.sessionId -ne $sessionId) {
        $state.ignoreCount = 0
        $state.sessionId = $sessionId
        $stateChanged = $true
    }

    $recentCutoff = Get-RecentCutoff -Now $now -Cutoff $cutoffSpan
    $lastCutoff = Parse-StateDate -Value $state.lastCutoff
    if (-not $lastCutoff -or $lastCutoff -lt $recentCutoff) {
        $state.ignoreCount = 0
        $state.lastCutoff = $recentCutoff.ToString('o')
        $stateChanged = $true
    }

    $window = Get-BedtimeWindow -Now $now -Bedtime $bedtimeSpan -Cutoff $cutoffSpan
    $mutedUntil = Parse-StateDate -Value $state.mutedUntil
    if ($mutedUntil -and $mutedUntil -le $now) {
        $state.mutedUntil = $null
        $mutedUntil = $null
        $stateChanged = $true
    }

    if (-not $window.InWindow) {
        $state.nextToast = $window.Start.ToString('o')
        Save-State -State $state
        Sleep-Until -Target $window.Start
        continue
    }

    if ($mutedUntil -and $mutedUntil -gt $now) {
        $state.nextToast = $mutedUntil.ToString('o')
        Save-State -State $state
        Sleep-Until -Target $mutedUntil
        continue
    }

    $nextToast = Parse-StateDate -Value $state.nextToast
    if (-not $nextToast -or $nextToast -le $now) {
        $toastId = [Guid]::NewGuid().ToString()
        Show-Toast -ToastId $toastId -IgnoreCount $state.ignoreCount
        $action = Wait-ToastAction -Timeout $noClickSpan -ToastId $toastId

        if ($action -eq 'mute') {
            $state.mutedUntil = $window.End.ToString('o')
            $state.nextToast = $window.End.ToString('o')
        } else {
            $state.ignoreCount = [int]$state.ignoreCount + 1
            # if (($state.ignoreCount % 5) -eq 0) {
            #     Lock-Workstation
            # }
            $next = (Get-Date).Add($snoozeSpan)
            if ($next -gt $window.End) {
                $next = $window.End
            }
            $state.nextToast = $next.ToString('o')
        }

        Save-State -State $state
        continue
    }

    if ($stateChanged) {
        Save-State -State $state
    }
    Sleep-Until -Target $nextToast
}
