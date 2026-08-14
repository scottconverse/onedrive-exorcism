---
name: onedrive-exorcism
description: >-
  Safely inventory or remove OneDrive on Windows, undo Known Folder Move so
  Desktop/Documents/Pictures point to the local profile, and repair the known-folder
  graph behind Explorer error 0x800401E5. Use for requests to remove or disable
  OneDrive, files still saving under OneDrive after uninstall, a reappearing OneDrive
  folder, an unavailable Desktop, or Explorer create/rename failures associated with
  broken known folders. Includes fail-closed data migration and out-of-container
  verification. Windows only.
---

# OneDrive exorcism (and the two traps that make it look already-fixed)

Removing the OneDrive *app* does not un-redirect the folders, and when an agent runs inside
a packaged desktop app, the fix can silently land in a private
virtual registry so it verifies perfectly and changes nothing. Both traps have cost
multi-day debugging sessions. Work through this in order.

## Trap 1: the container lies (check this FIRST)

If the agent is hosted inside a packaged desktop app (confirmed with the **Claude desktop
app**, MSIX package e.g.
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

Run `scripts/Invoke-OneDriveExorcism.ps1` through the out-of-container runner. It defaults
to read-only inventory. Never add `-Apply` until the user has reviewed that inventory.

1. **Inventory before destroying anything.** Count cloud-only placeholders:
   files with attribute `Offline` / `RecallOnDataAccess` exist only in the cloud.
   `scripts/Invoke-OneDriveExorcism.ps1` with no switches reports the count and bytes.
   If any exist, stop and ask the user: uninstalling makes those unreachable locally
   (they remain at onedrive.com). Offer: (a) hydrate them with "Always keep on this
   device", or (b) explicitly accept loss of local access with
   `-ConfirmCloudOnlyLoss`. The script refuses to proceed without that acknowledgement.
2. **Preflight and migrate local content.** `-Apply` checks all redirected known-folder
   content for collisions and reparse points before changing anything, then moves and
   verifies locally available files into the local profile. Resolve any reported
   collision manually and rerun.
3. **Repoint the known folders** — the actual bug. Fix all of `Desktop`, `Personal`,
   `My Pictures` and the GUID twins in **both** `User Shell Folders` and
   `Shell Folders`.
4. **Set policy** so it cannot re-redirect: `KFMBlockOptIn`, `DisableFileSyncNGSC`,
   `PreventNetworkTrafficPreUserSignIn`.
5. **Remove the app, autostart, tasks, sync roots, namespace pin, and config key.**
   The data tree is retained by default. Use `-DeleteOneDriveData` only after review;
   deletion is refused while any locally available file remains.
6. **Repair the known-folder graph** if `FOLDERID_SkyDrive` is missing.
7. **Optionally clear stale shell state** with `-ClearShellHistory`: `ComDlg32` MRU
   (file dialogs reopen each app's last
   used folder — a dead OneDrive path here re-poisons saves even with a clean
   registry), Recent/jumplists (scan raw bytes; `TargetPath` is empty when the
   target is gone), and `Shell\Bags\1\Desktop`. This is explicit because it removes
   user history and resets cosmetic shell state.
8. **Verify exact values and types.** Treat a nonzero script exit as failure. The audit
   checks exact local targets, all GUID twins, all policies, both task name and path,
   client executables, and requested deletion results.
9. **Have the user test in the GUI**: right-click desktop → New → Folder → rename it.
   Confirm the path is `C:\Users\<user>\Desktop\<name>`. An agent's filesystem tests
   pass even when the shell is broken, so this human step is the real acceptance test.

## Boundaries

- Leave `CldFlt`, WinSxS, the component store, and `OneDriveSetup.exe` alone. They are
  Windows servicing, not a running OneDrive. Deleting them buys nothing and breaks SFC
  and Windows Update.
- Do not delete the `SyncRootManager` key itself — other cloud providers use it. Remove
  only OneDrive-named children.
- Prefer setting `System.IsPinnedToNameSpaceTree = 0` over deleting OS-owned CLSIDs.
- Run as the interactive target user. The script intentionally has no cross-user option;
  mixing another profile's files with the runner's `HKCU` is unsafe.
- Do not bypass collision, reparse-point, cloud-only, or remaining-local-file failures.
- Expect cosmetic fallout and say so up front: icon positions reshuffle, taskbar blinks
  on Explorer restarts, and each app's save dialog forgets its last folder once.

## Reporting

Give the user full drive paths, state what was PRESENT vs already absent, and never
claim success from an in-session check alone — cite the out-of-container verification.
