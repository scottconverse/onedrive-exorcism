# Detecting the packaged-app registry overlay

## Quick check

Run in-session:

```powershell
$p = (Get-Process -Id $PID).Path
"Session exe: $p"
"Under WindowsApps/packaged: $($p -like '*\WindowsApps\*' -or $env:LOCALAPPDATA -like '*\Packages\*')"
"Package family: $(Get-AppxPackage -Name 'Claude*' -EA SilentlyContinue | Select-Object -Expand PackageFamilyName)"
```

If Claude Code is hosted by the Claude desktop app (MSIX), assume the overlay is
active. Do not spend time proving it per-key.

## Positive proof (when you need it)

Write a sentinel out-of-container, then read it in-session. If the in-session read
disagrees with the out-of-container read, the overlay is confirmed:

```powershell
# out-of-container (via helper): set marker
New-ItemProperty -Path 'HKCU:\Software' -Name 'ClaudeOverlayProbe' -Value 'real' -PropertyType String -Force
```

```powershell
# in-session: read it back
(Get-ItemProperty 'HKCU:\Software' -Name 'ClaudeOverlayProbe' -EA SilentlyContinue).ClaudeOverlayProbe
```

Then invert the experiment: write a different value **in-session** and read it
out-of-container. If the out-of-container read still shows the old value, in-session
writes are being virtualized. Clean up the probe value afterwards.

## Ground-truth via ProcMon (heaviest, but definitive)

Sysinternals Process Monitor run **outside** the container shows the values real
processes actually receive:

1. `https://download.sysinternals.com/files/ProcessMonitor.zip`, extract.
2. `Procmon64.exe /AcceptEula /Quiet /Minimized /BackingFile trap.pml`
3. Reproduce the behavior (e.g. restart Explorer).
4. `Procmon64.exe /Terminate` then
   `Procmon64.exe /OpenLog trap.pml /SaveAs trap.csv`
5. Search the CSV for `Data: .*OneDrive` to see what real Explorer/Chrome read from
   `User Shell Folders`, and for `\REGISTRY\WC\Silo` paths, which are containerized
   reads by packaged apps.

The `.pml` and `.csv` get large (hundreds of MB). Delete them when finished.

## Other state the overlay distorts

Observed in the field: `Get-ScheduledTask` in-session reported no OneDrive tasks while
three were registered and armed; `reg query HKCU\Software\Microsoft\OneDrive` reported
the key absent while it existed. Treat every in-session "nothing found" about machine
state as unverified.
