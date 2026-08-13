# Running work outside the container

Every registry write, scheduled-task change, and verification in this skill must run
outside the packaged-app container. Pick the first channel that exists on the machine.

## Channel A: a queue-polling elevated helper (preferred if you have one)

A scheduled task running as the user at `RunLevel Highest`, polling a queue directory.
Root: `C:\dev\ClaudeElevatedHelper` (task name `ClaudeElevatedDevHelper`).

Scripts must live under a trusted root — `C:\dev\`, `%USERPROFILE%\Documents\Claude\`,
`%USERPROFILE%\.claude\`, or `%USERPROFILE%\AppData\Local\Temp\ClaudeElevatedHelper\`.

```powershell
$jobId = "job-$(Get-Date -Format 'HHmmss')"
@{ action = 'RunTrustedPowerShellScript'
   scriptPath = "$env:TEMP\ClaudeElevatedHelper\myscript.ps1" } |
  ConvertTo-Json | Set-Content "C:\dev\ClaudeElevatedHelper\queue\$jobId.json" -Encoding UTF8
Start-ScheduledTask -TaskName 'ClaudeElevatedDevHelper'
foreach ($i in 1..60) {
  Start-Sleep -Seconds 3
  $ok  = "C:\dev\ClaudeElevatedHelper\done\$jobId.result.json"
  $bad = "C:\dev\ClaudeElevatedHelper\failed\$jobId.error.json"
  if (Test-Path $ok)  { (Get-Content $ok -Raw | ConvertFrom-Json).result.stdout; break }
  if (Test-Path $bad) { Get-Content $bad -Raw; break }
}
```

Notes: the helper processes the queue once per trigger and exits; a run takes ~15-90s.
Poll for the result file rather than assuming immediate completion. Capture both
`stdout` and `stderr` from the result JSON.

## Channel B: a one-shot scheduled task (works anywhere)

```powershell
$act = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\dev\tmp\fix.ps1"'
$pri = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
Register-ScheduledTask -TaskName 'ClaudeOneShot' -Action $act -Principal $pri -Force
Start-ScheduledTask -TaskName 'ClaudeOneShot'
# poll for an output file the script writes, then:
Unregister-ScheduledTask -TaskName 'ClaudeOneShot' -Confirm:$false
```

Have the script write its own transcript to a file; you cannot read the task's console.

## Channel C: ask the user

If no out-of-container channel exists, do not apply registry fixes in-session and
claim success. Give the user the exact steps or a `.ps1` to run from an ordinary
elevated PowerShell window, and have them paste back the audit output.

## Writing scripts for these channels

- Write the file with the `Write` tool, then reference it by path — do not try to pass
  long inline script text through the job JSON.
- Print a `=== BEFORE ===` / `=== AFTER ===` block for every value you change; that
  output is your only evidence.
- Make everything idempotent and safe to re-run.
- Avoid non-ASCII in printed strings (console encoding).
