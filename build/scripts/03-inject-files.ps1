# 03-inject-files.ps1
# Injects the NoTracking watchdog and setup hooks into a MOUNTED offline image:
#   <mount>\ProgramData\NoTracking\enforce.ps1        (live watchdog copy)
#   <mount>\ProgramData\NoTracking\sentinel.ps1       (live sentinel copy)
#   <mount>\ProgramData\NoTracking\guardian.ps1       (live guardian copy)
#   <mount>\ProgramData\NoTracking\allow.ps1          (live allow-anyway copy)
#   <mount>\ProgramData\NoTracking\remove.ps1         (live remove-download copy)
#   <mount>\Windows\Setup\NoTracking\enforce.ps1      (pristine backup copy)
#   <mount>\Windows\Setup\NoTracking\sentinel.ps1     (pristine backup copy)
#   <mount>\Windows\Setup\NoTracking\guardian.ps1     (pristine backup copy)
#   <mount>\Windows\Setup\NoTracking\allow.ps1        (pristine backup copy)
#   <mount>\Windows\Setup\NoTracking\remove.ps1       (pristine backup copy)
#   <mount>\Windows\Setup\Scripts\SetupComplete.cmd   (runs as SYSTEM at setup end:
#                                                      registers watchdog task, runs it once)
#   <mount>\Windows\Panther\unattend.xml              (answer file for specialize/oobe)
#
# Note: the workflow ALSO copies unattend.xml to the root of the rebuilt ISO media
# as autounattend.xml, which is where Windows Setup actually looks for it first.
#
# Usage:  .\03-inject-files.ps1 -MountDir "C:\work\mount" -RepoRoot "C:\work\repo"

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MountDir,

    [Parameter(Mandatory = $false)]
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

$enforceSrc = Join-Path $RepoRoot 'watchdog\enforce.ps1'
$sentinelSrc = Join-Path $RepoRoot 'watchdog\sentinel.ps1'
$guardianSrc = Join-Path $RepoRoot 'watchdog\guardian.ps1'
$allowSrc = Join-Path $RepoRoot 'watchdog\allow.ps1'
$removeSrc = Join-Path $RepoRoot 'watchdog\remove.ps1'
$setupCmdSrc = Join-Path $RepoRoot 'build\assets\SetupComplete.cmd'
$unattendSrc = Join-Path $RepoRoot 'build\assets\unattend.xml'

foreach ($f in @($enforceSrc, $sentinelSrc, $guardianSrc, $allowSrc, $removeSrc, $setupCmdSrc, $unattendSrc)) {
    if (-not (Test-Path $f)) { throw "Source file missing: $f" }
}
if (-not (Test-Path $MountDir)) { throw "Mount dir not found: $MountDir" }

function Copy-Into([string]$Src, [string]$Dest) {
    $destDir = Split-Path $Dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item $Src $Dest -Force
    Write-Host "Injected: $Dest"
}

# Live watchdog copy (the scheduled task points here)
Copy-Into $enforceSrc (Join-Path $MountDir 'ProgramData\NoTracking\enforce.ps1')

# Live sentinel copy (the scheduled task points here)
Copy-Into $sentinelSrc (Join-Path $MountDir 'ProgramData\NoTracking\sentinel.ps1')

# Live guardian copy (the scheduled task points here)
Copy-Into $guardianSrc (Join-Path $MountDir 'ProgramData\NoTracking\guardian.ps1')

# Live allow-anyway copy (the ALLOW-<id>.cmd buttons point here)
Copy-Into $allowSrc (Join-Path $MountDir 'ProgramData\NoTracking\allow.ps1')

# Live remove-download copy (the REMOVE-<id>.cmd buttons point here)
Copy-Into $removeSrc (Join-Path $MountDir 'ProgramData\NoTracking\remove.ps1')

# Pristine backup copy (SetupComplete.cmd restores from here if the live copy is missing)
Copy-Into $enforceSrc (Join-Path $MountDir 'Windows\Setup\NoTracking\enforce.ps1')

# Pristine backup copy (SetupComplete.cmd restores from here if the live copy is missing)
Copy-Into $sentinelSrc (Join-Path $MountDir 'Windows\Setup\NoTracking\sentinel.ps1')

# Pristine backup copy (SetupComplete.cmd restores from here if the live copy is missing)
Copy-Into $guardianSrc (Join-Path $MountDir 'Windows\Setup\NoTracking\guardian.ps1')

# Pristine backup copy (restored from here if the live copy is missing)
Copy-Into $allowSrc (Join-Path $MountDir 'Windows\Setup\NoTracking\allow.ps1')

# Pristine backup copy (restored from here if the live copy is missing)
Copy-Into $removeSrc (Join-Path $MountDir 'Windows\Setup\NoTracking\remove.ps1')

# Setup completion hook
Copy-Into $setupCmdSrc (Join-Path $MountDir 'Windows\Setup\Scripts\SetupComplete.cmd')

# Answer file inside the image (Panther location)
Copy-Into $unattendSrc (Join-Path $MountDir 'Windows\Panther\unattend.xml')

Write-Host "== 03-inject-files done"
