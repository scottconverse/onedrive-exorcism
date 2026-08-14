<#
.SYNOPSIS
    Inventory or safely remove OneDrive and undo Known Folder Move redirection.
.DESCRIPTION
    Inventory is the default. Changes require -Apply and must run outside a packaged-app
    container as the interactive target user. Locally available Desktop, Documents, and
    Pictures files are moved to the local profile before registry changes. Data folders
    are retained unless -DeleteOneDriveData is explicitly supplied.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$InventoryOnly,
    [switch]$ConfirmCloudOnlyLoss,
    [switch]$DeleteOneDriveData,
    [switch]$ClearShellHistory
)

$ErrorActionPreference = 'Stop'
function Say { param([string]$Text) Write-Output $Text }
function Head { param([string]$Text) Say ''; Say "=== $Text ===" }
function IsCloud { param([IO.FileInfo]$File) [bool](($File.Attributes -band [IO.FileAttributes]::Offline) -or ($File.Attributes.value__ -band 0x400000)) }
function Canon { param([string]$Path) [IO.Path]::GetFullPath($Path).TrimEnd('\') }
function IsWithin {
    param([string]$Path,[string]$Root)
    ((Canon $Path) + '\').StartsWith(((Canon $Root) + '\'), [StringComparison]::OrdinalIgnoreCase)
}
function FilesUnder {
    param([string]$Root)
    if (Test-Path -LiteralPath $Root) { @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction Stop) } else { @() }
}
function ExactRegistryValue {
    param([Microsoft.Win32.RegistryKey]$Key,[string]$Name,[object]$Value,[Microsoft.Win32.RegistryValueKind]$Kind,[switch]$Raw)
    if (-not $Key -or -not ($Key.GetValueNames() -contains $Name)) { return $false }
    $option = if ($Raw) { [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames } else { [Microsoft.Win32.RegistryValueOptions]::None }
    $Key.GetValue($Name,$null,$option) -eq $Value -and $Key.GetValueKind($Name) -eq $Kind
}

if ($Apply -and $InventoryOnly) { throw '-Apply and -InventoryOnly are mutually exclusive.' }
if (($DeleteOneDriveData -or $ClearShellHistory) -and -not $Apply) { throw 'Destructive options require -Apply.' }

$profileRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
if (-not $profileRoot -or -not (Test-Path -LiteralPath $profileRoot)) { throw 'Cannot resolve the current user profile.' }
$profileRoot = Canon $profileRoot
$oneDrive = Join-Path $profileRoot 'OneDrive'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($Apply -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '-Apply must run elevated as the interactive target user.'
}

$usfSub = 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$sfSub = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
$folders = @(
    [pscustomobject]@{Name='Desktop';Folder='Desktop'},
    [pscustomobject]@{Name='Personal';Folder='Documents'},
    [pscustomobject]@{Name='My Pictures';Folder='Pictures'},
    [pscustomobject]@{Name='{F42EE2D3-909F-4907-8871-4C22FC0BF756}';Folder='Documents'},
    [pscustomobject]@{Name='{0DDD015D-B06C-45D5-8C4C-F59713854639}';Folder='Pictures'},
    [pscustomobject]@{Name='{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}';Folder='Desktop'}
)

Head '0. Inventory'
Say "Identity: $($identity.Name)"
Say "Profile: $profileRoot"
Say "OneDrive: $(if (Test-Path -LiteralPath $oneDrive) { 'PRESENT' } else { 'absent' }) $oneDrive"
$allFiles = FilesUnder $oneDrive
$cloudFiles = @($allFiles | Where-Object { IsCloud $_ })
$localFiles = @($allFiles | Where-Object { -not (IsCloud $_) })
$cloudBytes = ($cloudFiles | Measure-Object Length -Sum).Sum; if ($null -eq $cloudBytes) { $cloudBytes = 0 }
Say "Cloud-only: $($cloudFiles.Count) file(s), $([math]::Round($cloudBytes/1GB,2)) GB"
Say "Locally available: $($localFiles.Count) file(s)"

$sourceByFolder = @{}
$usf = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($usfSub,$false)
foreach ($item in $folders) {
    $value = if ($usf) { $usf.GetValue($item.Name,'(absent)',[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { '(absent)' }
    $state = if ($value -like '*OneDrive*') { 'HIJACKED' } elseif ($value -eq '(absent)') { 'MISSING ' } else { 'ok      ' }
    Say "$state $($item.Name) = $value"
    if ($item.Name -in @('Desktop','Personal','My Pictures') -and $value -ne '(absent)') {
        $sourceByFolder[$item.Folder] = [Environment]::ExpandEnvironmentVariables([string]$value)
    }
}
if ($usf) { $usf.Close() }
if (-not $Apply) { Say ''; Say 'INVENTORY ONLY: no changes made. Use -Apply after review.'; return }
if ($cloudFiles.Count -gt 0 -and -not $ConfirmCloudOnlyLoss) {
    throw "Found $($cloudFiles.Count) cloud-only placeholder(s). Hydrate them or explicitly pass -ConfirmCloudOnlyLoss."
}

Head '1. Preflight migration'
$moves = New-Object System.Collections.Generic.List[object]
$directories = New-Object System.Collections.Generic.List[string]
foreach ($folderName in @('Desktop','Documents','Pictures')) {
    $source = $sourceByFolder[$folderName]; $target = Join-Path $profileRoot $folderName
    if (-not $source -or -not (Test-Path -LiteralPath $source)) { Say "absent source: $folderName"; continue }
    if ((Canon $source) -eq (Canon $target)) { Say "already local: $folderName"; continue }
    if (-not (IsWithin $source $oneDrive)) { throw "Unexpected $folderName source '$source'; review manually." }
    $items = @(Get-ChildItem -LiteralPath $source -Recurse -Force -ErrorAction Stop)
    $reparse = @($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($reparse.Count) { throw "Reparse point blocks safe migration: $($reparse[0].FullName)" }
    foreach ($dir in @($items | Where-Object PSIsContainer)) {
        $relative = $dir.FullName.Substring((Canon $source).Length).TrimStart('\')
        $destination = Join-Path $target $relative
        if (Test-Path -LiteralPath $destination -PathType Leaf) { throw "Directory collision: $destination" }
        $directories.Add($destination)
    }
    $planned = 0
    foreach ($file in @($items | Where-Object { -not $_.PSIsContainer -and -not (IsCloud $_) })) {
        $relative = $file.FullName.Substring((Canon $source).Length).TrimStart('\')
        $destination = Join-Path $target $relative
        if (Test-Path -LiteralPath $destination) { throw "File collision: $destination. Reconcile it and rerun." }
        $moves.Add([pscustomobject]@{Source=$file.FullName;Destination=$destination}); $planned++
    }
    Say "planned: $planned local file(s) from $source"
}

Head '2. Migrate local content'
foreach ($folderName in @('Desktop','Documents','Pictures')) {
    $target = Join-Path $profileRoot $folderName
    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null; Say "created: $target" }
}
foreach ($directory in @($directories | Sort-Object -Unique)) { if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null } }
foreach ($move in $moves) {
    $parent = Split-Path -Parent $move.Destination
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Move-Item -LiteralPath $move.Source -Destination $move.Destination
    if ((Test-Path -LiteralPath $move.Source) -or -not (Test-Path -LiteralPath $move.Destination)) { throw "Move verification failed: $($move.Source)" }
}
Say "migrated and verified: $($moves.Count) file(s)"

Head '3. Repoint known folders'
$usf = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($usfSub)
$sf = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($sfSub)
foreach ($item in $folders) {
    $expanded = Join-Path $profileRoot $item.Folder; $raw = "%USERPROFILE%\$($item.Folder)"
    $usf.SetValue($item.Name,$raw,[Microsoft.Win32.RegistryValueKind]::ExpandString)
    $sf.SetValue($item.Name,$expanded,[Microsoft.Win32.RegistryValueKind]::String)
    Say "set: $($item.Name) -> $expanded"
}
$usf.Close(); $sf.Close()

Head '4. Policy'
$policies = @(
    @('SOFTWARE\Policies\Microsoft\Windows\OneDrive','DisableFileSyncNGSC'),
    @('SOFTWARE\Policies\Microsoft\OneDrive','PreventNetworkTrafficPreUserSignIn'),
    @('SOFTWARE\Policies\Microsoft\OneDrive','KFMBlockOptIn'))
foreach ($policy in $policies) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($policy[0]); $before = $key.GetValue($policy[1],'(absent)')
    $key.SetValue($policy[1],1,[Microsoft.Win32.RegistryValueKind]::DWord); $after = $key.GetValue($policy[1]); $key.Close()
    Say "$($policy[1]): before=$before after=$after"
}

Head '5. Remove client and launch points'
$clientPaths = @((Join-Path $profileRoot 'AppData\Local\Microsoft\OneDrive\OneDrive.exe'),'C:\Program Files\Microsoft OneDrive\OneDrive.exe','C:\Program Files (x86)\Microsoft OneDrive\OneDrive.exe')
$clients = @($clientPaths | Where-Object { Test-Path -LiteralPath $_ })
if ($clients.Count) {
    Say "client PRESENT: $($clients -join ', ')"
    Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force
    $setup = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe","$env:SystemRoot\System32\OneDriveSetup.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $setup) { throw 'OneDrive is present but OneDriveSetup.exe was not found.' }
    $process = Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -PassThru
    Say "uninstaller exit: $($process.ExitCode)"; if ($process.ExitCode -ne 0) { throw "Uninstall failed: $($process.ExitCode)" }
} else { Say 'client absent' }
foreach ($path in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run')) {
    $key = Get-Item $path -ErrorAction SilentlyContinue; $names = if ($key) { @($key.GetValueNames() | Where-Object { $_ -match 'OneDrive' }) } else { @() }
    if (-not $names.Count) { Say "absent: $path OneDrive values" }
    foreach ($name in $names) { Remove-ItemProperty $path $name -Force; Say "removed: $path\$name" }
}
foreach ($startup in @((Join-Path $profileRoot 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'),'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup')) {
    $links = @(Get-ChildItem -LiteralPath $startup -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'OneDrive' })
    if (-not $links.Count) { Say "absent: OneDrive shortcuts in $startup" }
    foreach ($link in $links) { Remove-Item -LiteralPath $link.FullName -Force; Say "removed: $($link.FullName)" }
}
$tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'OneDrive' -or $_.TaskPath -match 'OneDrive' })
if (-not $tasks.Count) { Say 'absent: OneDrive scheduled tasks' }
foreach ($task in $tasks) { Unregister-ScheduledTask $task.TaskName -TaskPath $task.TaskPath -Confirm:$false; Say "removed task: $($task.TaskPath)$($task.TaskName)" }

Head '6. Registry remnants'
foreach ($path in @('HKCU:\Software\Microsoft\OneDrive','HKCU:\Software\Classes\grvopen')) {
    if (Test-Path $path) { Remove-Item $path -Recurse -Force; Say "removed: $path" } else { Say "absent: $path" }
}
foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager','HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager')) {
    $children = if (Test-Path $root) { @(Get-ChildItem $root | Where-Object { $_.PSChildName -match 'OneDrive' }) } else { @() }
    if (-not $children.Count) { Say "absent: OneDrive children under $root" }
    foreach ($child in $children) { Remove-Item -LiteralPath $child.PSPath -Recurse -Force; Say "removed sync root: $($child.PSChildName)" }
}
foreach ($path in @('HKCU:\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}','HKCU:\Software\Classes\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}','HKLM:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}','HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}')) {
    if (Test-Path $path) { Set-ItemProperty $path 'System.IsPinnedToNameSpaceTree' 0 -Type DWord -Force; Say "unpinned: $path" } else { Say "absent: $path" }
}

if ($ClearShellHistory) {
    Head '7. Explicit shell-history cleanup'
    foreach ($path in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\LastVisitedPidlMRU','HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\OpenSavePidlMRU','HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop')) {
        if (Test-Path $path) { Remove-Item $path -Recurse -Force; Say "cleared: $path" } else { Say "absent: $path" }
    }
    $recent = Join-Path $profileRoot 'AppData\Roaming\Microsoft\Windows\Recent'; $removed = 0
    foreach ($file in @(Get-ChildItem -Path $recent,"$recent\AutomaticDestinations","$recent\CustomDestinations" -File -Force -ErrorAction SilentlyContinue)) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ([Text.Encoding]::Unicode.GetString($bytes) -match 'OneDrive' -or [Text.Encoding]::ASCII.GetString($bytes) -match 'OneDrive') { Remove-Item -LiteralPath $file.FullName -Force; $removed++ }
    }
    Say "removed history files: $removed"
} else { Say 'shell-history cleanup skipped (explicit -ClearShellHistory required)' }

Head '8. Known-folder graph'
$skyDrive = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\{A52BBA46-E9E1-435f-B3D9-28DAA648C0F6}'
if (-not (Test-Path $skyDrive)) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderDescriptions\{A52BBA46-E9E1-435f-B3D9-28DAA648C0F6}')
    $key.SetValue('Name','OneDrive',[Microsoft.Win32.RegistryValueKind]::String); $key.SetValue('Category',4,[Microsoft.Win32.RegistryValueKind]::DWord)
    $key.SetValue('ParentFolder','{5E6C858F-0E22-4760-9AFE-EA3317B67173}',[Microsoft.Win32.RegistryValueKind]::String); $key.SetValue('RelativePath','OneDrive',[Microsoft.Win32.RegistryValueKind]::String); $key.Close()
    Say 'restored: FOLDERID_SkyDrive (no PreCreate)'
} else { Say 'present: FOLDERID_SkyDrive' }

$removeTargets = @($oneDrive,(Join-Path $profileRoot 'AppData\Local\Microsoft\OneDrive'),(Join-Path $profileRoot 'AppData\Roaming\Microsoft\OneDrive'),'C:\ProgramData\Microsoft OneDrive','C:\Program Files\Microsoft OneDrive','C:\Program Files (x86)\Microsoft OneDrive')
$removalFailures = New-Object System.Collections.Generic.List[string]
if ($DeleteOneDriveData) {
    Head '9. Explicit data deletion'
    $remainingLocal = @(FilesUnder $oneDrive | Where-Object { -not (IsCloud $_) })
    if ($remainingLocal.Count) { throw "Refusing deletion: $($remainingLocal.Count) local file(s) remain; first is $($remainingLocal[0].FullName)" }
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
    foreach ($path in $removeTargets) {
        if (-not (Test-Path -LiteralPath $path)) { Say "absent: $path"; continue }
        try { Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction Stop | ForEach-Object { $_.Attributes='Normal' }; Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
        catch { $removalFailures.Add("$path :: $($_.Exception.Message)") }
        if (Test-Path -LiteralPath $path) { $removalFailures.Add("$path :: still exists") } else { Say "removed: $path" }
    }
} else { Say 'data folders retained (explicit -DeleteOneDriveData required)' }
# Known-folder resolution is cached by Explorer. Restart it for every applied repair,
# regardless of whether data deletion was requested.
Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
Start-Sleep 5

Head '10. AUDIT'
$checks = [ordered]@{}; $usf = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($usfSub,$false); $sf = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sfSub,$false)
foreach ($item in $folders) {
    $raw = "%USERPROFILE%\$($item.Folder)"; $expanded = Join-Path $profileRoot $item.Folder
    $checks["USF $($item.Name) exact"] = ExactRegistryValue $usf $item.Name $raw ExpandString -Raw
    $checks["SF $($item.Name) exact"] = ExactRegistryValue $sf $item.Name $expanded String
}
if ($usf) { $usf.Close() }; if ($sf) { $sf.Close() }
$remainingTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'OneDrive' -or $_.TaskPath -match 'OneDrive' })
$checks['client executables absent'] = -not [bool]@($clientPaths | Where-Object { Test-Path -LiteralPath $_ }).Count
$checks['OneDrive.exe stopped'] = -not [bool](Get-Process OneDrive -ErrorAction SilentlyContinue)
$checks['tasks absent by name and path'] = -not [bool]$remainingTasks.Count
$checks['HKCU config absent'] = -not (Test-Path 'HKCU:\Software\Microsoft\OneDrive')
$checks['DisableFileSyncNGSC=1'] = (Get-ItemPropertyValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' -ErrorAction SilentlyContinue) -eq 1
$checks['PreventNetworkTrafficPreUserSignIn=1'] = (Get-ItemPropertyValue 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' 'PreventNetworkTrafficPreUserSignIn' -ErrorAction SilentlyContinue) -eq 1
$checks['KFMBlockOptIn=1'] = (Get-ItemPropertyValue 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' 'KFMBlockOptIn' -ErrorAction SilentlyContinue) -eq 1
$checks['FOLDERID_SkyDrive present'] = Test-Path $skyDrive
$checks['Desktop exact local target'] = (Canon ([Environment]::GetFolderPath('Desktop'))) -eq (Canon (Join-Path $profileRoot 'Desktop'))
$checks['Documents exact local target'] = (Canon ([Environment]::GetFolderPath('MyDocuments'))) -eq (Canon (Join-Path $profileRoot 'Documents'))
$checks['Pictures exact local target'] = (Canon ([Environment]::GetFolderPath('MyPictures'))) -eq (Canon (Join-Path $profileRoot 'Pictures'))
if ($DeleteOneDriveData) { $checks['data tree absent'] = -not (Test-Path -LiteralPath $oneDrive); $checks['all deletions succeeded'] = -not [bool]$removalFailures.Count }
$fail = 0
foreach ($check in $checks.GetEnumerator()) { $label = if ($check.Value) {'PASS'} else {'FAIL'}; Say "[$label] $($check.Key)"; if (-not $check.Value) { $fail++ } }
foreach ($failure in $removalFailures) { Say "[FAIL] removal: $failure" }
Say "RESULT: $($checks.Count-$fail)/$($checks.Count) checks passed"
Say "HUMAN TEST: create and rename a Desktop folder; confirm $(Join-Path $profileRoot 'Desktop')."
if ($fail -or $removalFailures.Count) { exit 1 }
