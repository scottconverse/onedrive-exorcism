<#
.SYNOPSIS
    Remove OneDrive and undo its Known Folder Move redirection, then audit the result.

.DESCRIPTION
    MUST be run OUTSIDE any packaged-app container (see references/elevated-helper.md).
    Idempotent: safe to re-run. Reports PRESENT vs absent for every item and ends with
    a PASS/FAIL audit.

    Order matters. Known folders are repointed and policy is set BEFORE the OneDrive
    folder is deleted, so nothing re-creates it.

.PARAMETER InventoryOnly
    Report cloud-only placeholder counts and current redirection state; change nothing.

.PARAMETER SkipFolderDelete
    Do everything except delete the OneDrive data folder (use when files are still
    cloud-only and the user has not decided yet).

.PARAMETER UserName
    Target user profile. Defaults to the current user.
#>
[CmdletBinding()]
param(
    [switch]$InventoryOnly,
    [switch]$SkipFolderDelete,
    [string]$UserName = $env:USERNAME
)

$ErrorActionPreference = 'Stop'
$profileRoot = "C:\Users\$UserName"
$oneDrive    = Join-Path $profileRoot 'OneDrive'
$results     = [ordered]@{}

function Say  { param([string]$m) Write-Output $m }
function Head { param([string]$m) Write-Output ''; Write-Output "=== $m ===" }

# ---------------------------------------------------------------- 0. Inventory
Head '0. Inventory'
Say "Profile root: $profileRoot"
Say "OneDrive folder: $(if (Test-Path -LiteralPath $oneDrive) { 'PRESENT ' + $oneDrive } else { 'absent' })"

if (Test-Path -LiteralPath $oneDrive) {
    $cloudOnly = 0; $cloudBytes = 0; $local = 0
    Get-ChildItem -LiteralPath $oneDrive -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
        # Offline / RecallOnDataAccess => content lives only in the cloud
        if (($_.Attributes -band [IO.FileAttributes]::Offline) -or ($_.Attributes.value__ -band 0x400000)) {
            $cloudOnly++; $cloudBytes += $_.Length
        } else { $local++ }
    }
    Say "Cloud-only placeholders: $cloudOnly file(s), $([math]::Round($cloudBytes/1GB,2)) GB"
    Say "Files actually stored locally: $local"
    if ($cloudOnly -gt 0) {
        Say "WARNING: those $cloudOnly file(s) exist only at onedrive.com. Removing OneDrive"
        Say "         makes them unreachable on this PC. Confirm with the user first."
    }
}

$usfPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
$sfPath  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
$kfNames = @(
    @{ Name = 'Desktop';                                    Target = '%USERPROFILE%\Desktop'   },
    @{ Name = 'Personal';                                   Target = '%USERPROFILE%\Documents' },
    @{ Name = 'My Pictures';                                Target = '%USERPROFILE%\Pictures'  },
    @{ Name = '{F42EE2D3-909F-4907-8871-4C22FC0BF756}';     Target = '%USERPROFILE%\Documents' },
    @{ Name = '{0DDD015D-B06C-45D5-8C4C-F59713854639}';     Target = '%USERPROFILE%\Pictures'  },
    @{ Name = '{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}';     Target = '%USERPROFILE%\Desktop'   }
)

Head '0b. Current known-folder redirection (REAL registry)'
$redirected = @()
foreach ($kf in $kfNames) {
    $v = (Get-Item $usfPath).GetValue($kf.Name, '(absent)', 'DoNotExpandEnvironmentNames')
    if ($v -like '*OneDrive*') { $redirected += $kf.Name; Say "HIJACKED  $($kf.Name) = $v" }
    else { Say "ok        $($kf.Name) = $v" }
}
$results['redirected_before'] = $redirected.Count

if ($InventoryOnly) { Say ''; Say 'InventoryOnly: no changes made.'; return }

# ------------------------------------------------- 1. Repoint the known folders
Head '1. Repointing known folders'
$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders', $true)
foreach ($kf in $kfNames) {
    if ($k.GetValueNames() -contains $kf.Name) {
        $k.SetValue($kf.Name, $kf.Target, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        Say "set USF $($kf.Name) -> $($kf.Target)"
    }
}
$k.Close()

$k2 = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders', $true)
foreach ($pair in @(@('Desktop','Desktop'), @('Personal','Documents'), @('My Pictures','Pictures'))) {
    if ($k2.GetValueNames() -contains $pair[0]) {
        $k2.SetValue($pair[0], (Join-Path $profileRoot $pair[1]), [Microsoft.Win32.RegistryValueKind]::String)
        Say "set SF  $($pair[0]) -> $(Join-Path $profileRoot $pair[1])"
    }
}
$k2.Close()

foreach ($d in @('Desktop','Documents','Pictures')) {
    $p = Join-Path $profileRoot $d
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null; Say "created missing $p" }
}

# --------------------------------------------------------------- 2. Policy lock
Head '2. Policy'
$polW = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\Policies\Microsoft\Windows\OneDrive')
$polW.SetValue('DisableFileSyncNGSC', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
$polW.SetValue('PreventNetworkTrafficPreUserSignIn', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
$polW.Close()
$polO = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\Policies\Microsoft\OneDrive')
$polO.SetValue('KFMBlockOptIn', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
$polO.Close()
Say 'DisableFileSyncNGSC=1, PreventNetworkTrafficPreUserSignIn=1, KFMBlockOptIn=1'

# ------------------------------------------------------------- 3. Uninstall app
Head '3. Uninstall client'
$setups = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe")
$installed = @("$profileRoot\AppData\Local\Microsoft\OneDrive\OneDrive.exe",
               'C:\Program Files\Microsoft OneDrive\OneDrive.exe',
               'C:\Program Files (x86)\Microsoft OneDrive\OneDrive.exe') | Where-Object { Test-Path -LiteralPath $_ }
if ($installed) {
    Say "Client present: $($installed -join ', ')"
    Get-Process OneDrive -ErrorAction SilentlyContinue | ForEach-Object {
        Start-Process -FilePath $_.Path -ArgumentList '/shutdown' -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force
    foreach ($s in $setups) {
        if (Test-Path -LiteralPath $s) { Say "running $s /uninstall"; & $s /uninstall; Start-Sleep -Seconds 20 }
    }
} else { Say 'OneDrive client already absent' }

# ------------------------------------------------------- 4. Autostart and tasks
Head '4. Autostart and scheduled tasks'
foreach ($rk in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
                  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
    $r = Get-Item $rk -ErrorAction SilentlyContinue
    if ($r) { foreach ($n in $r.GetValueNames()) {
        if ($n -match 'OneDrive') { Remove-ItemProperty -Path $rk -Name $n -Force; Say "removed Run value $rk\$n" } } }
}
$sa = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$sak = Get-Item $sa -ErrorAction SilentlyContinue
if ($sak) { foreach ($n in $sak.GetValueNames()) {
    if ($n -match 'OneDrive') { Remove-ItemProperty -Path $sa -Name $n -Force; Say "removed StartupApproved $n" } } }
foreach ($sp in @("$profileRoot\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup",
                  'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup')) {
    Get-ChildItem -LiteralPath $sp -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'OneDrive' } |
        ForEach-Object { Remove-Item $_.FullName -Force; Say "removed startup shortcut $($_.FullName)" }
}
# NOTE: in-container Get-ScheduledTask has been observed returning ZERO while tasks existed.
$tasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
         Where-Object { $_.TaskName -match 'OneDrive' -or $_.TaskPath -match 'OneDrive' }
if ($tasks) { foreach ($t in $tasks) {
    Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false
    Say "deleted scheduled task $($t.TaskName)" } }
else { Say 'no OneDrive scheduled tasks' }

# ------------------------------------------ 5. Registry config, sync roots, shell
Head '5. Registry remnants'
if (Test-Path 'HKCU:\Software\Microsoft\OneDrive') {
    Remove-Item 'HKCU:\Software\Microsoft\OneDrive' -Recurse -Force; Say 'removed HKCU\Software\Microsoft\OneDrive'
} else { Say 'HKCU\Software\Microsoft\OneDrive absent' }
if (Test-Path 'HKCU:\Software\Classes\grvopen') {
    Remove-Item 'HKCU:\Software\Classes\grvopen' -Recurse -Force; Say 'removed grvopen handler'
}
foreach ($h in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager',
                 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager')) {
    if (Test-Path $h) {
        foreach ($kid in (Get-ChildItem $h -ErrorAction SilentlyContinue).PSChildName) {
            # Remove OneDrive sync roots ONLY; other providers (Dropbox, etc.) live here too.
            if ($kid -match 'OneDrive') { Remove-Item "$h\$kid" -Recurse -Force; Say "removed sync root $kid" }
        }
    }
}
foreach ($p in @('HKCU:\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
                 'HKCU:\Software\Classes\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
                 'HKLM:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
                 'HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}')) {
    if (Test-Path $p) {
        # Unpin rather than delete: the CLSID is OS-owned.
        Set-ItemProperty -Path $p -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -Type DWord -Force
        Say "unpinned namespace entry $p"
    }
}

# ------------------------------------------------------ 6. Stale shell UI state
Head '6. Stale shell state'
foreach ($mru in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\LastVisitedPidlMRU',
                   'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\OpenSavePidlMRU',
                   'HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop')) {
    if (Test-Path $mru) { Remove-Item $mru -Recurse -Force; Say "cleared $mru" }
}
$recent = "$profileRoot\AppData\Roaming\Microsoft\Windows\Recent"
$n = 0
foreach ($f in (Get-ChildItem -Path $recent, "$recent\AutomaticDestinations", "$recent\CustomDestinations" `
                -File -Force -ErrorAction SilentlyContinue)) {
    try {
        # Scan raw bytes: TargetPath resolves to empty once the target is gone.
        $b = [IO.File]::ReadAllBytes($f.FullName)
        if ([Text.Encoding]::Unicode.GetString($b) -match 'OneDrive' -or
            [Text.Encoding]::ASCII.GetString($b)   -match 'OneDrive') {
            Remove-Item $f.FullName -Force; $n++
        }
    } catch {}
}
Say "removed $n stale Recent/jumplist entries"

# ------------------------------------------------- 7. Known-folder graph repair
Head '7. Known-folder graph'
$skyDrive = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\{A52BBA46-E9E1-435f-B3D9-28DAA648C0F6}'
if (-not (Test-Path $skyDrive)) {
    # Missing parent breaks Explorer New Folder/rename system-wide (0x800401E5).
    $fd = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey(
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\{A52BBA46-E9E1-435f-B3D9-28DAA648C0F6}')
    $fd.SetValue('Name', 'OneDrive', [Microsoft.Win32.RegistryValueKind]::String)
    $fd.SetValue('Category', 4, [Microsoft.Win32.RegistryValueKind]::DWord)
    $fd.SetValue('ParentFolder', '{5E6C858F-0E22-4760-9AFE-EA3317B67173}', [Microsoft.Win32.RegistryValueKind]::String)
    $fd.SetValue('RelativePath', 'OneDrive', [Microsoft.Win32.RegistryValueKind]::String)
    $fd.Close()
    Say 'RESTORED missing FOLDERID_SkyDrive definition (no PreCreate: creates nothing)'
} else { Say 'FOLDERID_SkyDrive definition intact' }

# ------------------------------------------------------------ 8. Data and files
Head '8. Data folders'
if (-not $SkipFolderDelete) {
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    foreach ($p in @($oneDrive,
                     "$profileRoot\AppData\Local\Microsoft\OneDrive",
                     "$profileRoot\AppData\Roaming\Microsoft\OneDrive",
                     'C:\ProgramData\Microsoft OneDrive',
                     'C:\Program Files\Microsoft OneDrive',
                     'C:\Program Files (x86)\Microsoft OneDrive')) {
        if (Test-Path -LiteralPath $p) {
            Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Attributes = 'Normal' }
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            Say "$(if (Test-Path -LiteralPath $p) { 'FAILED to remove' } else { 'removed' }): $p"
        } else { Say "absent: $p" }
    }
    $orgs = Get-ChildItem -LiteralPath $profileRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'OneDrive*' }
    if ($orgs) { Say "NOTE org folders still present (review manually): $($orgs.Name -join ', ')" }
} else { Say 'SkipFolderDelete: data folders left in place' }

if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
Start-Sleep -Seconds 8

# ------------------------------------------------------------------- 9. Audit
Head '9. AUDIT'
$checks = [ordered]@{}
foreach ($kf in $kfNames) {
    $v = (Get-Item $usfPath).GetValue($kf.Name, '(absent)', 'DoNotExpandEnvironmentNames')
    if ($v -ne '(absent)') { $checks["USF $($kf.Name) not in OneDrive"] = ($v -notlike '*OneDrive*') }
}
foreach ($nm in @('Desktop','Personal','My Pictures')) {
    $v = (Get-Item $sfPath).GetValue($nm, '(absent)')
    if ($v -ne '(absent)') { $checks["SF $nm not in OneDrive"] = ($v -notlike '*OneDrive*') }
}
$checks['OneDrive data folder gone']   = $SkipFolderDelete -or -not (Test-Path -LiteralPath $oneDrive)
$checks['OneDrive.exe not running']    = -not [bool](Get-Process OneDrive -ErrorAction SilentlyContinue)
$checks['no OneDrive scheduled tasks'] = -not [bool](Get-ScheduledTask -ErrorAction SilentlyContinue |
                                            Where-Object { $_.TaskName -match 'OneDrive' })
$checks['HKCU OneDrive key gone']      = -not (Test-Path 'HKCU:\Software\Microsoft\OneDrive')
$checks['DisableFileSyncNGSC=1']       = (Get-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive').GetValue('DisableFileSyncNGSC') -eq 1
$checks['KFMBlockOptIn=1']             = (Get-Item 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive').GetValue('KFMBlockOptIn') -eq 1
$checks['FOLDERID_SkyDrive present']   = Test-Path $skyDrive
$checks['Desktop resolves local']      = ([Environment]::GetFolderPath('Desktop') -notlike '*OneDrive*')

$fail = 0
foreach ($c in $checks.GetEnumerator()) {
    Say ("[{0}] {1}" -f $(if ($c.Value) { 'PASS' } else { 'FAIL'; }), $c.Key)
    if (-not $c.Value) { $fail++ }
}
Say ''
Say "RESULT: $($checks.Count - $fail)/$($checks.Count) checks passed"
Say "Desktop resolves to: $([Environment]::GetFolderPath('Desktop'))"
Say ''
Say 'REMAINING HUMAN STEP: in the GUI, right-click the desktop -> New -> Folder, then'
Say 'rename it. Confirm the path is the local profile. Filesystem tests pass even when'
Say 'the shell is broken, so only this proves it.'
if ($fail -gt 0) { Say ''; Say 'One or more checks FAILED. If they failed while appearing correct in-session,'; Say 'suspect the packaged-app registry overlay - see references/detect-container.md.' }
