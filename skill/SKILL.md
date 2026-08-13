---
name: onedrive-exorcism
description: >-
  Remove OneDrive from a Windows machine and, critically, undo its Known Folder
  Move redirection so Desktop/Documents/Pictures point back at the local profile.
  Use whenever a Windows box shows any of: files saving into a OneDrive folder,
  a OneDrive folder that reappears after deletion, "Desktop is not available",
  Explorer New Folder or rename failing with 0x800401E5 "No object for moniker"
  or "Can't find the specified file", a desktop showing only shared icons, or a
  request to "remove/disable/get rid of OneDrive". ALSO use it before diagnosing
  any confusing path, repo, or file-not-found weirdness on a Windows machine, and
  whenever a registry or scheduled-task fix "succeeds and verifies" but system
  behavior does not change. Windows only.
---

# OneDrive exorcism (and the two traps that make it look already-fixed)

Removing the OneDrive *app* does not un-redirect the folders, and on machines where
Claude runs inside the packaged desktop app, the fix can silently land in a private
virtual registry so it verifies perfectly and changes nothing. Both traps have cost
multi-day debugging sessions. Work through this in order.

## Trap 1: the container lies (check this FIRST)

If Claude is running inside the **Claude desktop app** (MSIX package, e.g.
`Claude_pzs8sxrjxfjjc`), the session sees a **copy-on-write overlay** of the registry
and other machine state. Writes go to the package's private hive; later reads return
the overlay copy. The fix looks applied, verifies clean, survives reboots, and the
machine is untouched. Confirmed to affect at minimum:

- `HKCU` and `HKLM\Software` registry values
- `Get-ScheduledTask` enumeration (reported zero OneDrive tasks while three were live)
- per-user config keys (`reg query` said "key absent" for a key that existed)

**Rule: never trust an in-session "clean"/"not found" result about machine state, and
never apply a registry fix in-session. Apply AND verify through an out-of-container
channel.** See `references/detect-container.md` for the detection one-liner and
`references/elevated-helper.md` for the runner pattern.

Symptom fingerprint that should make you suspect this immediately:
*"the fix succeeded, verification passed, and nothing changed."*

## Trap 2: never deregister built-in FolderDescriptions

A previous session "cleaned up" OneDrive by deleting the built-in known-folder
definition `FOLDERID_SkyDrive`
(`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\{A52BBA46-E9E1-435f-B3D9-28DAA648C0F6}`).
Four child definitions (`OneDriveDocuments`, `OneDrivePictures`, `OneDriveCameraRoll`,
`OneDriveMusic`) still pointed at the now-missing parent. Explorer's file-operation
code walks that graph, so **New Folder and rename broke system-wide for three days**,
with these signatures:

- `0x800401E5 MK_E_NOOBJECT: No object for moniker`
- `Can't find the specified file` on rename
- `The file or folder does not exist` on cancel
- the new folder appears in the view but **never exists on disk**

Diagnostic that settles it in one step: after a failed create, list the target
directory from a shell. If the item is not on disk, this is a shell/known-folder
failure, not a permissions or path problem. Restore the parent definition
(`scripts/Repair-KnownFolderGraph.ps1`); do not delete OS-owned FolderDescriptions.

## Procedure

Run `scripts/Invoke-OneDriveExorcism.ps1` through the out-of-container runner. It is
idempotent, reports PRESENT/absent for every item, and ends with a PASS/FAIL audit.

1. **Inventory before destroying anything.** Count cloud-only placeholders:
   files with attribute `Offline` / `RecallOnDataAccess` exist only in the cloud.
   `scripts/Invoke-OneDriveExorcism.ps1 -InventoryOnly` reports the count and bytes.
   If the number is large, stop and ask the user: uninstalling makes those
   unreachable locally (they remain at onedrive.com). Offer: (a) launch OneDrive,
   set "Always keep on this device", download, then proceed, or (b) proceed and
   accept cloud-only access. **This is the one genuine decision point.**
2. **Repoint the known folders** — the actual bug. Fix all of `Desktop`, `Personal`,
   `My Pictures` and the GUID twins in **both** `User Shell Folders` and
   `Shell Folders`.
3. **Set policy** so it cannot re-redirect: `KFMBlockOptIn`, `DisableFileSyncNGSC`,
   `PreventNetworkTrafficPreUserSignIn`.
4. **Remove app, data, autostart, tasks, sync roots, namespace, config key.**
5. **Repair the known-folder graph** if `FOLDERID_SkyDrive` is missing.
6. **Clear stale shell state**: `ComDlg32` MRU (file dialogs reopen each app's last
   used folder — a dead OneDrive path here re-poisons saves even with a clean
   registry), Recent/jumplists (scan raw bytes; `TargetPath` is empty when the
   target is gone), and `Shell\Bags\1\Desktop`.
7. **Restart Explorer, then verify.** Delete the OneDrive folder LAST, and only with
   no Explorer window open in it — restoring a window there re-creates the folder and
   makes it look like OneDrive is resurrecting itself.
8. **Have the user test in the GUI**: right-click desktop → New → Folder → rename it.
   Confirm the path is `C:\Users\<user>\Desktop\<name>`. Claude's filesystem tests
   pass even when the shell is broken, so this human step is the real acceptance test.

## Boundaries

- Leave `CldFlt`, WinSxS, the component store, and `OneDriveSetup.exe` alone. They are
  Windows servicing, not a running OneDrive. Deleting them buys nothing and breaks SFC
  and Windows Update.
- Do not delete the `SyncRootManager` key itself — other cloud providers use it. Remove
  only OneDrive-named children.
- Prefer setting `System.IsPinnedToNameSpaceTree = 0` over deleting OS-owned CLSIDs.
- Expect cosmetic fallout and say so up front: icon positions reshuffle, taskbar blinks
  on Explorer restarts, and each app's save dialog forgets its last folder once.

## Reporting

Give the user full drive paths, state what was PRESENT vs already absent, and never
claim success from an in-session check alone — cite the out-of-container verification.
