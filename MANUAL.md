# User Manual

Plain-language instructions. No prior Windows internals knowledge assumed. For the technical
reference, see [PLAYBOOK.md](PLAYBOOK.md).

---

## What this does, in one paragraph

OneDrive can take over your Desktop, Documents, and Pictures folders — a feature Microsoft
calls "folder backup". When it does, those folders physically move inside a OneDrive folder.
Uninstalling OneDrive **does not move them back**. Windows keeps pointing at the old
location, so files you save keep landing there, and the OneDrive folder keeps reappearing
after you delete it. This tool moves your folders back, blocks OneDrive from ever doing it
again, removes every trace of it, and repairs a specific kind of damage that stops Windows
from letting you create or rename folders at all.

---

## Before you start: the one thing that can lose you files

Open your OneDrive folder in File Explorer and look at the icons next to your files.

| Icon | Meaning | Safe to proceed? |
|------|---------|------------------|
| Green check / solid circle | Stored on this PC | Yes |
| **Blue cloud outline** | **Stored only online** | **No — read below** |

Files with a **cloud icon are not on your computer.** They live at onedrive.com and download
on demand. If you remove OneDrive while files are cloud-only, those files stay safe in the
cloud but become unreachable from this PC.

**If you see cloud icons and you want those files locally:**

1. Open the OneDrive folder.
2. Select everything (Ctrl+A).
3. Right-click → **Always keep on this device**.
4. Wait for every icon to turn into a green check. This can take a long time for large
   collections — check the size first and make sure you have the disk space.
5. Then continue.

**If you do not care about those files** (you can always get them from onedrive.com in a
browser), continue now.

The tool counts these for you and refuses changes unless cloud-only access loss is explicitly acknowledged.

---

## Option A — with Claude Code or Codex (easiest)

1. Copy the `skill` folder into your agent's skills folder and name it `onedrive-exorcism`:

   ```
   C:\Users\<your name>\.claude\skills\onedrive-exorcism\
   C:\Users\<your name>\.codex\skills\onedrive-exorcism\
   ```

2. Restart the agent so it notices the new skill.
3. Invoke `/onedrive-exorcism` in Claude Code or `$onedrive-exorcism` in Codex.

   ```
   /onedrive-exorcism
   ```

4. Review the inventory and answer whether to hydrate cloud-only files first.
5. When it finishes, do the final test at the bottom of this page.

The agent handles elevation, runs the work outside of any sandbox that would falsify the
results, and reports a pass/fail checklist.

## Option B — with the Claude website

1. Zip the `skill` folder (rename it `onedrive-exorcism` first).
2. Go to **Settings → Capabilities → Skills → Upload skill** and upload the zip.
3. It is now available in your account.

Note: the website's own sandbox is Linux, so in a plain web chat Claude can walk you through
the procedure but cannot run it against your Windows PC. To actually execute it, use Claude
Code on the machine you are fixing.

## Option C — plain PowerShell, no AI

1. Press **Start**, type `PowerShell`, right-click **Windows PowerShell**, choose
   **Run as administrator**.
2. Navigate to where you unzipped this project:

   ```powershell
   cd C:\path\to\onedrive-exorcism
   ```

3. Look before you leap — this changes nothing:

   ```powershell
   .\skill\scripts\Invoke-OneDriveExorcism.ps1
   ```

   Read the output. It tells you how many files are cloud-only and which folders are
   currently redirected.

4. If you are happy, run it for real:

   ```powershell
   .\skill\scripts\Invoke-OneDriveExorcism.ps1 -Apply
   ```

   If cloud-only files exist and you accept losing local access, add
   `-ConfirmCloudOnlyLoss`. Data folders are retained unless you explicitly add
   `-DeleteOneDriveData`; deletion is still refused while local files remain.

5. Read the `AUDIT` section at the end. Every line should say `PASS`.

If PowerShell refuses to run the script, this allows it for that one window only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

---

## The final test — do not skip this

Scripts can only test the file system. The bug most likely to still be there lives in the
Windows shell, and it passes every file-system test. Only a human clicking in the GUI can
prove it is gone.

1. Right-click an empty spot on your desktop.
2. Choose **New → Folder**.
3. Type a name and press Enter.
4. Right-click the new folder → **Properties** and check the **Location** line.

**Expected:** the folder is created, the rename sticks, and Location reads
`C:\Users\<your name>\Desktop`.

If any of those three fail, see *"I still cannot create or rename folders"* below.

---

## What will look different afterwards

All normal, all cosmetic:

- **Desktop icons move around.** Restarting Windows Explorer resets icon positions.
- **The taskbar blinks** once or twice during the process.
- **Save dialogs forget where you last saved.** Each app picks a fresh default the first time
  you use it. This is deliberate — that memory is one of the things sending files to the old
  OneDrive path.
- **An empty OneDrive folder may briefly appear** at some point in the future. It is
  harmless. Delete it and move on. What mattered was the redirection, and that is gone.

---

## Troubleshooting

### I still cannot create or rename folders

Symptoms: `0x800401E5 No object for moniker`, *Can't find the specified file* when renaming,
or a new folder that appears then vanishes.

This is separate damage, usually from an earlier over-aggressive cleanup that deleted a
built-in Windows folder definition. Run:

```powershell
.\skill\scripts\Repair-KnownFolderGraph.ps1
```

It scans for the broken reference and restores it. Your desktop icons will reshuffle once
more when Explorer restarts. Then repeat the final test above.

### The audit says FAIL but everything looked correct while it ran

You are almost certainly hitting the registry-overlay trap: the tool ran inside a packaged
app and its changes went into a private copy of the registry instead of the real one. Re-run
it from a normal **Administrator PowerShell window** launched from the Start menu — not from
a terminal embedded inside another application.

### My Desktop is empty except for a few shared shortcuts

Windows is pointing your Desktop at a folder that no longer exists, so you are seeing only
the icons shared by all users. Run the tool — repointing fixes it. Your files are still at
`C:\Users\<your name>\Desktop`.

### The OneDrive folder came back

Check whether it has anything in it besides `desktop.ini`. If it is effectively empty, it is
cosmetic — delete it. If files are landing in it again, run without `-Apply` and look at the
redirection list; if anything shows `HIJACKED`, run the full tool from an elevated window
outside any packaged app.

### I want OneDrive back

Reinstall it from microsoft.com, then remove the three policy values listed in
[PLAYBOOK.md](PLAYBOOK.md) section 3.2. Nothing here deletes anything from your OneDrive
account — your files are still online.

---

## Getting help

Open an issue with:

- Your Windows version (`winver`)
- The full output of `Invoke-OneDriveExorcism.ps1` without `-Apply`
- The exact error text or a screenshot
- Whether you ran it from a plain Administrator PowerShell window or inside another app
