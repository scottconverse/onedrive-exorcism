# OneDrive Exorcism

**Removing OneDrive is the easy part. Undoing what it did to your folders is where
everyone gets stuck — and on some machines your fix silently never reaches the registry
at all.**

A Windows playbook, a Claude skill, and two PowerShell scripts for permanently removing
OneDrive *and* repairing the damage it leaves behind.

[Landing page](https://scottconverse.github.io/onedrive-exorcism/) &middot;
[Playbook](PLAYBOOK.md) &middot;
[User manual](MANUAL.md) &middot;
[Skill](skill/)

---

## The problem this actually solves

Uninstalling OneDrive **does not** repoint your Desktop, Documents, and Pictures folders.
Those live as literal paths in the Windows registry. So Windows keeps writing into a
`C:\Users\<you>\OneDrive\...` folder that it recreates on demand — with no sync running,
no OneDrive client installed, and no account signed in.

That is why:

- you delete the OneDrive folder and it comes back
- files you save to "Desktop" land somewhere else
- your desktop suddenly shows only the shared icons
- the fix works, verifies, survives a reboot, and nothing changes

## Two traps that make a broken machine look fixed

### Trap 1 — packaged apps can see a fake registry

If your AI assistant (or any tool) runs inside a **packaged/MSIX desktop app**, it may see
a copy-on-write **overlay** of machine state. Writes land in the package's private hive;
later reads return that private copy. The fix applies cleanly, verification passes, the
machine is untouched.

It is not limited to the registry. In the field, `Get-ScheduledTask` reported **zero**
OneDrive tasks while three were live and armed, and `reg query` called a per-user config
key absent while it existed.

> **Tell:** the fix succeeded, verification passed, and nothing changed.

Fixes must be applied **and verified** through an out-of-container channel. See
[detect-container.md](skill/references/detect-container.md) and
[elevated-helper.md](skill/references/elevated-helper.md).

### Trap 2 — deleting a built-in folder description breaks Explorer

A common "deep clean" step is deleting OneDrive's known-folder definition
(`FOLDERID_SkyDrive`) from `FolderDescriptions`. Four child definitions still point at it.
Explorer walks that graph during file operations, so **New Folder and rename break
system-wide** — desktop, every drive, every dialog:

```
Error 0x800401E5: No object for moniker
Can't find the specified file          (on rename)
The file or folder does not exist      (on cancel)
```

The new folder **appears in the view but never exists on disk**, so every filesystem-level
test passes while the shell is thoroughly broken. `Repair-KnownFolderGraph.ps1` detects and
repairs this, and is useful on its own even if OneDrive was never your problem.

## Quick start

### With Claude Code (recommended)

Copy `skill/` into your skills directory as `onedrive-exorcism`:

```
~/.claude/skills/onedrive-exorcism/
```

Then ask for it by name:

```
/onedrive-exorcism
```

Claude loads the traps and boundaries, runs the script through an out-of-container
channel, and reports a PASS/FAIL audit. You can also upload
[the packaged skill](#packaging-for-claudeai) to your Claude account.

### Without Claude — plain PowerShell

Open an **elevated** PowerShell window (not inside any packaged app terminal) and:

```powershell
# 1. Look before you leap: reports cloud-only files and current redirection. Changes nothing.
.\skill\scripts\Invoke-OneDriveExorcism.ps1 -InventoryOnly

# 2. Do it.
.\skill\scripts\Invoke-OneDriveExorcism.ps1

# Explorer New Folder / rename broken, regardless of OneDrive?
.\skill\scripts\Repair-KnownFolderGraph.ps1
```

Then **test in the GUI**: right-click the desktop, New, Folder, rename it, check the path.
Filesystem tests pass even when the shell is broken, so this human step is the only real
acceptance test.

## Read this before you run it

**Cloud-only files disappear from your PC.** Files with a cloud icon exist *only* at
onedrive.com. Removing OneDrive makes them unreachable locally — they are not deleted from
the cloud, but they are gone from this machine. `-InventoryOnly` counts them first. If the
count is not zero, download what you need before proceeding.

**Cosmetic fallout is normal:** desktop icon positions reshuffle, the taskbar blinks when
Explorer restarts, and each app's save dialog forgets its last-used folder once.

## What the script does, in order

Order is load-bearing — repoint and lock policy **before** deleting anything, or the folder
regenerates and the deletion looks haunted.

| # | Step | Why |
|---|------|-----|
| 1 | Inventory cloud-only files | The one genuine decision point |
| 2 | Repoint known folders | Both `User Shell Folders` and `Shell Folders`, names *and* GUID twins |
| 3 | Lock policy | `KFMBlockOptIn`, `DisableFileSyncNGSC`, `PreventNetworkTrafficPreUserSignIn` |
| 4 | Remove client, autostart, tasks, sync roots | The updater task is a live path back onto the machine |
| 5 | Repair known-folder graph | Restores a missing built-in definition, registration only |
| 6 | Clear stale shell state | Dialog MRU, Recent, jumplists, desktop view-state |
| 7 | Delete the data folder **last** | And only with no Explorer window open in it |
| 8 | Human GUI test | The only proof that counts |

## Where to stop

- **Leave Windows servicing alone** — `CldFlt`, WinSxS, the component store,
  `OneDriveSetup.exe`. Deleting them buys nothing and breaks SFC and Windows Update.
- **Never delete `SyncRootManager` itself** — other cloud providers register there. Remove
  OneDrive-named children only.
- **Unpin, don't delete, OS-owned CLSIDs** — set `System.IsPinnedToNameSpaceTree` to `0`.
- **The empty folder is cosmetic; the redirection is the bug.** Escalating against a
  harmless leftover folder is what causes Trap 2 in the first place.

## Packaging for claude.ai

```powershell
Compress-Archive -Path .\skill -DestinationPath .\onedrive-exorcism.zip
```

Rename the `skill` folder to `onedrive-exorcism` inside the archive (claude.ai reads the
skill's identity from `SKILL.md`), then upload under **Settings → Capabilities → Skills**.

Note that claude.ai's own sandbox is Linux — in a plain web chat Claude can read and explain
the procedure, but executing it against a Windows machine requires Claude Code running on
that machine.

## Repository layout

```
PLAYBOOK.md                      Full technical procedure and error signatures
MANUAL.md                        Step-by-step user manual, plain language
docs/index.html                  Landing page (GitHub Pages)
skill/SKILL.md                   The Claude skill
skill/scripts/                   Invoke-OneDriveExorcism.ps1, Repair-KnownFolderGraph.ps1
skill/references/                Container detection, out-of-container execution
```

## Origin

Written after a Windows 11 machine spent roughly three days appearing to be fixed. Four
separate sessions repointed the registry, verified the values, rebooted, and watched files
keep landing in OneDrive — because every write had gone into a packaged app's private
registry overlay. A Process Monitor capture from outside the container showed Explorer
reading the real, still-hijacked values. Underneath that sat Trap 2, quietly breaking
New Folder and rename everywhere for the entire time.

Both failures are documented here so the next person spends an hour instead of three days.

## Compatibility

Windows 10 and Windows 11 (built and verified on Windows 11 Pro). PowerShell 5.1 or
PowerShell 7. Some steps require elevation.

## License

MIT — see [LICENSE](LICENSE).

**No warranty.** These scripts modify the registry, delete folders, and remove scheduled
tasks. Read them, run `-InventoryOnly` first, and make sure your files are stored locally
before you proceed.
