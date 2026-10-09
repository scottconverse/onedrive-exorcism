# Running work outside the container

Every registry write, scheduled-task change, and verification in this skill must run
outside the packaged-app container. Pick the first channel that exists on the machine.

## Channel A: a queue-polling elevated helper (preferred if you have one)

A scheduled task running as the user at `RunLevel Highest`, polling a queue directory.
Root: `C:\dev\ClaudeElevatedHelper` (task name `ClaudeElevatedDevHelper`).

Scripts must live under a trusted root — `C:\dev\`, `%USERPROFILE%\Documents\Claude\`,
`%USERPROFILE%\.claude\`, or `%USERPROFILE%\AppData\Local\Temp\ClaudeElevatedHelper\`.

```powershell
$jobId = "job-$([guid]::NewGuid().ToString('N'))"
@{ action = 'RunTrustedPowerShellScript'
   scriptPath = "$env:TEMP\ClaudeElevatedHelper\myscript.ps1" } |
  ConvertTo-Json | Set-Content "C:\dev\ClaudeElevatedHelper\queue\$jobId.json" -Encoding UTF8
Start-ScheduledTask -TaskName 'ClaudeElevatedDevHelper'
$completed = $false
foreach ($i in 1..60) {
  Start-Sleep -Seconds 3
  $ok  = "C:\dev\ClaudeElevatedHelper\done\$jobId.result.json"
  $bad = "C:\dev\ClaudeElevatedHelper\failed\$jobId.error.json"
  if (Test-Path $ok) {
    $result = Get-Content $ok -Raw | ConvertFrom-Json
    if ($result.result.stderr) { Write-Error $result.result.stderr }
    $result.result.stdout
    $completed = $true
    break
  }
  if (Test-Path $bad) { throw (Get-Content $bad -Raw) }
}
if (-not $completed) { throw "Elevated helper timed out after 180 seconds: $jobId" }
```

Notes: the helper processes the queue once per trigger and exits; a run takes ~15-90s.
Poll for the result file rather than assuming immediate completion. Capture both
`stdout` and `stderr` from the result JSON.

## Channel B: a one-shot scheduled task (portable fallback)

Use a unique task name and a wrapper script under a trusted, ACL-checked directory. The
wrapper must write a result JSON atomically containing its execution identity, exit code,
stdout, and stderr. Register the task for the **same interactive user** with `RunLevel
Highest`, start it, and poll both the task state and result file with a finite timeout.
Reject a missing/malformed result, unexpected identity, or nonzero exit code. Always remove
the task in `finally`. Do not use SYSTEM: this skill intentionally modifies the target
user's `HKCU`.

This channel is only "works anywhere" when the operator can approve task registration and
the runner validates all of the properties above. Otherwise use Channel C.

## Channel C: ask the user

If no out-of-container channel exists, do not apply registry fixes in-session and
claim success. Give the user the exact steps or a `.ps1` to run from an ordinary
elevated PowerShell window, and have them paste back the audit output.

## Writing scripts for these channels

- Write the script to a file and pass its path: long inline text breaks the job JSON
  (unescaped backslashes make it invalid).
- Print a `=== BEFORE ===` / `=== AFTER ===` block for every value you change; that
  output is your only evidence.
- Make scripts idempotent so a failed or repeated job can be re-run without extra damage.
- Resolve and print the execution SID and profile. Abort if they are not the intended user.
- Fail on timeout, malformed output, nonzero exit, or incomplete cleanup.
- Avoid non-ASCII in printed strings (console encoding).
