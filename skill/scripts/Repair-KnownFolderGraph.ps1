<#
.SYNOPSIS
    Diagnose and repair a broken known-folder graph (Explorer New Folder / rename failing).

.DESCRIPTION
    Standalone repair for the failure mode where Explorer cannot create or rename items
    anywhere - desktop, drives, dialogs - with:
        0x800401E5 MK_E_NOOBJECT "No object for moniker"
        "Can't find the specified file"
        "The file or folder does not exist"
    and the new item appears in the view but never exists on disk.

    Cause: a FolderDescriptions entry was deleted while children still reference it,
    leaving a dangling parent in the shell's known-folder graph. Run OUTSIDE any
    packaged-app container.
#>
[CmdletBinding()]
param([switch]$WhatIfOnly)

$ErrorActionPreference = 'Stop'
$fdRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions'

# Built-in definitions that are commonly deleted by over-aggressive cleanups.
$known = @{
    '{A52BBA46-E9E1-435f-B3D9-28DAA648C0F6}' = @{
        Name = 'OneDrive'; Category = 4; RelativePath = 'OneDrive'
        ParentFolder = '{5E6C858F-0E22-4760-9AFE-EA3317B67173}'   # FOLDERID_Profile
    }
}

Write-Output '=== Scanning for dangling ParentFolder references ==='
$present = @{}
Get-ChildItem $fdRoot -ErrorAction SilentlyContinue | ForEach-Object { $present[$_.PSChildName] = $true }

$dangling = @()
foreach ($k in (Get-ChildItem $fdRoot -ErrorAction SilentlyContinue)) {
    $parent = $k.GetValue('ParentFolder', $null)
    if ($parent -and -not $present.ContainsKey($parent)) {
        $dangling += [pscustomobject]@{
            Child      = $k.GetValue('Name', $k.PSChildName)
            ChildGuid  = $k.PSChildName
            MissingParent = $parent
        }
    }
}

if (-not $dangling) {
    Write-Output 'No dangling references. Known-folder graph is intact.'
} else {
    foreach ($d in $dangling) {
        Write-Output "DANGLING: $($d.Child) [$($d.ChildGuid)] -> missing parent $($d.MissingParent)"
    }
}

$toRestore = $dangling.MissingParent | Sort-Object -Unique
$restoredCount = 0
foreach ($guid in $toRestore) {
    if (-not $known.ContainsKey($guid)) {
        Write-Output "NOTE: no restore template for $guid - inspect a healthy machine's FolderDescriptions and add one."
        continue
    }
    if ($WhatIfOnly) { Write-Output "WhatIf: would restore $guid ($($known[$guid].Name))"; continue }
    $def = $known[$guid]
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey(
        "SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\$guid")
    $key.SetValue('Name',         $def.Name,         [Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue('Category',     $def.Category,     [Microsoft.Win32.RegistryValueKind]::DWord)
    $key.SetValue('ParentFolder', $def.ParentFolder, [Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue('RelativePath', $def.RelativePath, [Microsoft.Win32.RegistryValueKind]::String)
    $key.Close()
    # Deliberately no PreCreate value: the definition registers the folder without creating it.
    Write-Output "RESTORED $guid ($($def.Name)) - registration only, creates no folder"
    $restoredCount++
}

if (-not $WhatIfOnly -and $restoredCount -gt 0) {
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    Start-Sleep -Seconds 6
    Write-Output "Explorer restarted: $([bool](Get-Process explorer -ErrorAction SilentlyContinue))"
}

Write-Output ''
Write-Output 'VERIFY IN THE GUI: right-click desktop -> New -> Folder, then rename it.'
Write-Output 'A shell-layer failure still passes every filesystem-level test, so this is the only proof.'
