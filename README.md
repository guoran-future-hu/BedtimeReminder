# bedtime-reminder

Windows-only bedtime escalation reminders using PowerShell, Task Scheduler, and BurntToast.

## What It Does
- Runs on user logon (Scheduled Task).
- Shows a bedtime toast during the bedtime window.
- If ignored or snoozed, the next toast escalates:
  - More `!` each cycle.
  - An extra “Time to wind down” line per cycle.
- Ignoring (no click) counts the same as Snooze.
- Locks the workstation every 5 ignores.
- Mutes all toasts until morning if “Emergency work (mute tonight)” is clicked.
- `ignoreCount` resets on logoff/reboot and when morning cutoff passes.

## Files
- `bedtime.ps1` — main loop.
- `install.ps1` — install/update scheduled task.
- `uninstall.ps1` — remove scheduled task.
- `state.json` — persisted state.

## Requirements
- Windows 10/11
- Windows PowerShell 5.1
- BurntToast PowerShell module (installed by `install.ps1` if missing)

## Install / Update
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

If a previous task was created with admin rights, run once as Administrator:
```powershell
Start-Process PowerShell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File .\install.ps1'
```

## Uninstall
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## Verify It’s Running
```powershell
Get-ScheduledTask -TaskName bedtime-reminder | Get-ScheduledTaskInfo
```

To start immediately (without logoff/logon):
```powershell
Start-ScheduledTask -TaskName bedtime-reminder
```

## Configure
Edit the top of `bedtime.ps1`:

```powershell
$Bedtime = "22:30"        # HH:mm
$MorningCutoff = "07:30"  # HH:mm
$NoClickDelay = "00:30"   # mm:ss or hh:mm:ss
$SnoozeDelay = "05:00"    # mm:ss or hh:mm:ss
```

Config meanings:
- `$Bedtime`: When the reminder window starts each night (24‑hour time).
- `$MorningCutoff`: When reminders stop for the night; also resets `ignoreCount`.
- `$NoClickDelay`: How long the toast can sit without interaction before it counts as an ignore.
- `$SnoozeDelay`: How long to wait after a Snooze/ignore before showing the next toast.

## Use Case
Best for personal bedtime routines where you want escalating reminders, with a one-click mute for nights when you must stay up.

## Notes
- The task uses a **Logon** trigger (runs when you log in), so no admin rights are needed to register/update the task after initial cleanup.
- `install.ps1` resolves the absolute path at install time, so the repo can live anywhere.
- Toasts show only during the bedtime window and when not muted.
