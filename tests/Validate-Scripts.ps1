$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scripts = @(
    (Join-Path $root 'skill\scripts\Invoke-OneDriveExorcism.ps1'),
    (Join-Path $root 'skill\scripts\Repair-KnownFolderGraph.ps1')
)

$failed = 0
function Assert-True {
    param([bool]$Condition,[string]$Message)
    if ($Condition) { Write-Output "[PASS] $Message" }
    else { Write-Error "[FAIL] $Message" -ErrorAction Continue; $script:failed++ }
}

foreach ($scriptPath in $scripts) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
    Assert-True ($errors.Count -eq 0) "PowerShell parses: $([IO.Path]::GetFileName($scriptPath))"
    foreach ($error in $errors) { Write-Error "${scriptPath}:$($error.Extent.StartLineNumber): $($error.Message)" -ErrorAction Continue }
}

$main = Get-Content -Raw $scripts[0]
Assert-True ($main -match '\[switch\]\$Apply') 'Mutation requires an Apply switch'
Assert-True ($main -match '\[switch\]\$ConfirmCloudOnlyLoss') 'Cloud-only loss has explicit acknowledgement'
Assert-True ($main -match '\[switch\]\$DeleteOneDriveData') 'Data deletion has an independent explicit switch'
Assert-True ($main -notmatch '\$UserName') 'Cross-user HKCU/filesystem targeting is absent'
Assert-True ($main -match 'Refusing deletion:') 'Remaining local files fail closed before deletion'
Assert-True ($main -match 'File collision:') 'Migration collisions fail closed'
Assert-True ($main -match 'TaskName.+OneDrive.+TaskPath.+OneDrive') 'Task audit uses both task name and path'
Assert-True ($main -match 'PreventNetworkTrafficPreUserSignIn=1') 'All documented policy values are audited'
Assert-True ($main -match 'exit 1') 'Failed audit returns a nonzero exit code'

$repair = Get-Content -Raw $scripts[1]
Assert-True ($repair -match '\$restoredCount -gt 0') 'Explorer restarts only after an actual graph repair'

if ($failed -gt 0) { throw "$failed static validation check(s) failed." }
Write-Output 'All static validation checks passed. No remediation script was executed.'
