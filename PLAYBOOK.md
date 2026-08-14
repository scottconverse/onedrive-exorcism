# The Windows Playbook

Technical reference for removing OneDrive and repairing known-folder damage. If you want
click-by-click instructions instead, read [MANUAL.md](MANUAL.md).

---

## 1. Diagnose before you touch anything

### 1.1 Is this actually a redirection problem?

Read the real values. Both keys matter — `User Shell Folders` holds the authoritative
(unexpanded) paths, `Shell Folders` is a cache that some software reads directly.

```powershell
$usf = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$k = Get-Item $usf
foreach ($n in ($k.GetValueNames() | Sort-Object)) {
    $v = $k.GetValue($n, '', 'DoNotExpandEnvironmentNames')
    '{0,-12} {1} {2}' -f $(if ($v -like '*OneDrive*') { 'HIJACKED' } else { 'ok' }), $n, $v
}
```

Six values get redirected by Known Folder Move. Fixing three of them is the classic
half-fix that leaves the machine broken:

| Value | Correct target |
|-------|----------------|
| `Desktop` | `%USERPROFILE%\Desktop` |
| `Personal` | `%USERPROFILE%\Documents` |
| `My Pictures` | `%USERPROFILE%\Pictures` |
| `{F42EE2D3-909F-4907-8871-4C22FC0BF756}` | `%USERPROFILE%\Documents` |
| `{0DDD015D-B06C-45D5-8C4C-F59713854639}` | `%USERPROFILE%\Pictures` |
| `{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}` | `%USERPROFILE%\Desktop` |

### 1.2 Are you being shown the truth?

**Do this before believing any reading above.** If your shell, terminal, or assistant runs
inside a packaged (MSIX/Store) app, registry access may be virtualized into a private
copy-on-write hive. Writes go into the overlay; reads return the overlay copy; the machine
never changes.

Detection and proof: [skill/references/detect-container.md](skill/references/detect-container.md).

The cheapest positive proof is a cross-channel disagreement — write a sentinel value from
outside, read it from inside, then invert the experiment. If the two channels disagree, every
in-session reading you have taken so far is worthless.

**Scope of the lie (confirmed):** registry values, `Get-ScheduledTask` enumeration, and
per-user config keys. Assume it covers any machine-state query.

### 1.3 Is the known-folder graph intact?

If Explorer cannot create or rename folders, check for dangling parent references before
blaming permissions:

```powershell
$fd = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions'
$present = @{}
Get-ChildItem $fd | ForEach-Object { $present[$_.PSChildName] = $true }
Get-ChildItem $fd | ForEach-Object {
    $p = $_.GetValue('ParentFolder', $null)
    if ($p -and -not $present.ContainsKey($p)) {
        "DANGLING: {0} -> missing {1}" -f $_.GetValue('Name', $_.PSChildName), $p
    }
}
```

### 1.4 Inventory cloud-only files

```powershell
$od = "$env:USERPROFILE\OneDrive"
$cloud = Get-ChildItem $od -Recurse -Force -File -ErrorAction SilentlyContinue |
         Where-Object { $_.Attributes -band [IO.FileAttributes]::Offline }
"{0} cloud-only files, {1:N2} GB" -f $cloud.Count, (($cloud | Measure-Object Length -Sum).Sum / 1GB)
```

Anything counted here exists **only** at onedrive.com. Removing OneDrive does not delete it
from the cloud, but it becomes unreachable on this PC. This is the one step where you stop
and ask the user.

---

## 2. Error signature reference

| Symptom | Root cause |
|---------|-----------|
| `0x800401E5` *No object for moniker* | Shell bound to a path or known folder that no longer resolves — dangling `FolderDescriptions` parent, or a deleted folder still held by a live Explorer view |
| *Can't find the specified file* on rename | The create silently failed; the item was drawn in the view but never written to disk |
| *The file or folder does not exist* on cancel | Same ghost item, different code path |
| *Location is not available* / *Desktop is not available* | Known folder points at a path that does not exist |
| Desktop shows only shared icons | User Desktop is bound to a dead redirect target; you are seeing `C:\Users\Public\Desktop` alone |
| Folder reappears seconds after deletion | Explorer pre-creates the Desktop known folder at startup from the redirected path — or a live Explorer window is restoring into it |
| Saves land in OneDrive on a clean registry | `ComDlg32` MRU: file dialogs reopen each app's last-used folder, cached per process |
| Fix verifies but nothing changes | Registry overlay (Trap 1) |

**Fastest triage for a failed folder create:** list the target directory from a shell. If
the item is not on disk, it is a shell-layer failure — stop looking at permissions and
antivirus.

---

## 3. Procedure

Run everything from **outside** any packaged-app container, elevated. Order matters:
repoint and lock policy *before* deleting, or the folder regenerates.

### 3.1 Repoint the known folders

Write `ExpandString` (`REG_EXPAND_SZ`) to `User Shell Folders` using `%USERPROFILE%`, and
plain `String` absolute paths to `Shell Folders`. Create missing required values and audit
their exact values and registry types.

```powershell
$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders', $true)
$k.SetValue('Desktop', '%USERPROFILE%\Desktop', [Microsoft.Win32.RegistryValueKind]::ExpandString)
# ...repeat for the other five, then Shell Folders with absolute paths
$k.Close()
```

Create any missing local target folders before restarting Explorer.

### 3.2 Lock it out by policy

| Value | Key | Effect |
|-------|-----|--------|
| `KFMBlockOptIn=1` | `HKLM\SOFTWARE\Policies\Microsoft\OneDrive` | Blocks folder-backup opt-in |
| `DisableFileSyncNGSC=1` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive` | "Prevent the usage of OneDrive for file storage" |
| `PreventNetworkTrafficPreUserSignIn=1` | `HKLM\SOFTWARE\Policies\Microsoft\OneDrive` | No network traffic before sign-in |

Set these **before** removing the client, so a reinstall cannot redirect anything.

### 3.3 Remove the client

Shut down gracefully first (`OneDrive.exe /shutdown`), then run the OS uninstaller:

```
%SystemRoot%\SysWOW64\OneDriveSetup.exe /uninstall
%SystemRoot%\System32\OneDriveSetup.exe /uninstall
```

### 3.4 Autostart and scheduled tasks

- `HKCU` and `HKLM` `...\CurrentVersion\Run` — remove OneDrive values only
- `...\Explorer\StartupApproved\Run` — remove the leftover enable/disable marker
- User and common Startup folders — remove OneDrive shortcuts
- **Scheduled tasks** — `OneDrive Reporting Task`, `OneDrive Standalone Update Task`,
  `OneDrive Startup Task`, each SID-suffixed

The updater task is the one that matters: it is Microsoft's documented mechanism for
updating OneDrive when the client is not running, i.e. a live path back onto the machine.
**This is also where the overlay lies most convincingly** — an in-container query can
report zero tasks while all three are registered.

### 3.5 Registry remnants

- `HKCU\Software\Microsoft\OneDrive` — account and sync configuration, delete whole key
- `HKCU\Software\Classes\grvopen` — leftover protocol handler
- `SyncRootManager` (HKLM **and** HKCU) — delete OneDrive-named **children only**; other
  cloud providers register in the same key
- Namespace CLSID `{018D5C66-4533-4307-9B53-224DE2ED1FE6}` in `Classes\CLSID` and
  `WOW6432Node` — set `System.IsPinnedToNameSpaceTree` to `0` rather than deleting an
  OS-owned class registration

### 3.6 Stale shell state

Even with a perfect registry, these keep sending files to the old path:

- `...\Explorer\ComDlg32\LastVisitedPidlMRU` and `OpenSavePidlMRU` — each app's last-used
  folder, which is why saves still land in a dead OneDrive path after a clean fix
- `...\Windows\Shell\Bags\1\Desktop` — desktop view-state, including `IconLayouts`
- `%APPDATA%\Microsoft\Windows\Recent` plus `AutomaticDestinations` and
  `CustomDestinations` — **scan by raw bytes**; `TargetPath` returns empty once the target
  is gone, so shortcut objects look clean while the bytes still hold the path

### 3.7 Repair the known-folder graph

If `FOLDERID_SkyDrive` (`{A52BBA46-E9E1-435f-B3D9-28DAA648C0F6}`) is missing while children
reference it, restore a minimal definition:

| Value | Data |
|-------|------|
| `Name` | `OneDrive` |
| `Category` | `4` (REG_DWORD) |
| `ParentFolder` | `{5E6C858F-0E22-4760-9AFE-EA3317B67173}` (FOLDERID_Profile) |
| `RelativePath` | `OneDrive` |

Deliberately **no `PreCreate`** — the definition registers the folder without creating it.
With policy set and shell folders local, a complete `FolderDescriptions` set creates nothing.

### 3.8 Optionally delete the data folder — last

Data folders are retained unless `-DeleteOneDriveData` is explicit. The script first
migrates local known-folder files, refuses collisions and reparse points, and refuses
deletion while any locally available file remains. Cloud-only placeholders also require
`-ConfirmCloudOnlyLoss`.

Clear read-only attributes, stop Explorer, delete, then restart Explorer. Deleting while an
Explorer window sits in that path causes window-restore to recreate it, which reads exactly
like OneDrive resurrecting itself.

Also remove, if present:

```
%LOCALAPPDATA%\Microsoft\OneDrive
%APPDATA%\Microsoft\OneDrive
C:\ProgramData\Microsoft OneDrive
C:\Program Files\Microsoft OneDrive
C:\Program Files (x86)\Microsoft OneDrive
```

Review `OneDrive - <Organization>` folders manually — those are work/school accounts and may
hold the only local copy of something.

---

## 4. Verification

Automated (out-of-container) — `Invoke-OneDriveExorcism.ps1 -Apply` ends with an exact
PASS/FAIL audit covering all six mappings in both keys, value types, client state, task
names and paths, all policies, requested deletions, and resolved local folder paths. Any
failure returns a nonzero exit code.

**Then the human step, which no script can replace:** right-click the desktop → New →
Folder → rename it → confirm the path is under the local profile. Filesystem-level tests
pass even when the shell is broken; only the GUI exercises the shell path that fails.

---

## 5. Boundaries

**Do not touch:**

- `CldFlt` and Cloud Files platform components — used by all sync providers, not just OneDrive
- WinSxS, the component store, `OneDriveSetup.exe` — Windows servicing owns these. Deleting
  them buys nothing operationally and can break SFC and Windows Update
- The `SyncRootManager` key itself — only its OneDrive children
- OS-owned CLSIDs — unpin instead of deleting
- Built-in `FolderDescriptions` entries — deleting one is Trap 2

**Set expectations before you start:** icon positions reshuffle, the taskbar blinks on each
Explorer restart, and every app's save dialog forgets its last-used folder once.
