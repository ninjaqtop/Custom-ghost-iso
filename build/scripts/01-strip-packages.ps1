# 01-strip-packages.ps1
# Removes provisioned Appx packages (listed in build/config/packages-to-remove.txt)
# from a MOUNTED offline Windows image. Provisioned removal means the apps are
# never installed for any user created on the machine.
#
# Usage:  .\01-strip-packages.ps1 -MountDir "C:\work\mount" [-ConfigPath "...\packages-to-remove.txt"]

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MountDir,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\packages-to-remove.txt')
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path $MountDir)) { throw "Mount dir not found: $MountDir" }
if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }

$patterns = Get-Content $ConfigPath |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') }

Write-Host "== 01-strip-packages: $($patterns.Count) patterns from $ConfigPath"

$provisioned = Get-AppxProvisionedPackage -Path $MountDir -ErrorAction Stop
Write-Host "== Image currently has $($provisioned.Count) provisioned packages"

$removed = 0
foreach ($pkg in $provisioned) {
    foreach ($pat in $patterns) {
        if ($pkg.DisplayName -like "*$pat*" -or $pkg.PackageName -like "*$pat*") {
            try {
                Write-Host "Removing provisioned package: $($pkg.DisplayName) [$($pkg.PackageName)]"
                Remove-AppxProvisionedPackage -Path $MountDir -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                $removed++
            }
            catch {
                Write-Warning "Could not remove $($pkg.PackageName): $($_.Exception.Message)"
            }
            break
        }
    }
}

Write-Host "== 01-strip-packages done. Removed: $removed"
