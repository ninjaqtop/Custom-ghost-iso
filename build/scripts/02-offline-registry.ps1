# 02-offline-registry.ps1
# Loads the mounted image's SOFTWARE and SYSTEM registry hives and applies the
# machine-level (HKLM) policy + service configuration that mirrors the
# NoTracking v3 watchdog (watchdog/enforce.ps1), so the machine is already
# hardened on first boot. The watchdog still re-asserts everything at runtime.
#
# Usage:  .\02-offline-registry.ps1 -MountDir "C:\work\mount"

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MountDir
)

$ErrorActionPreference = 'Stop'

$softwareHiveFile = Join-Path $MountDir 'Windows\System32\config\SOFTWARE'
$systemHiveFile   = Join-Path $MountDir 'Windows\System32\config\SYSTEM'
if (-not (Test-Path $softwareHiveFile)) { throw "SOFTWARE hive not found: $softwareHiveFile" }
if (-not (Test-Path $systemHiveFile))   { throw "SYSTEM hive not found: $systemHiveFile" }

$SW = 'HKLM\GHOST_SW'   # temp mount name for SOFTWARE
$SY = 'HKLM\GHOST_SY'   # temp mount name for SYSTEM

function Set-Dword([string]$Path, [string]$Name, [int]$Value) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Unload-Hive([string]$Name) {
    # Registry hives stay locked until handles are released; force GC and retry.
    for ($i = 1; $i -le 10; $i++) {
        try {
            & reg.exe unload $Name 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return }
        } catch { }
        [gc]::Collect()
        Start-Sleep -Milliseconds 500
    }
    Write-Warning "Could not unload hive $Name after retries (continuing; DISM unmount may need /Cleanup-Wim first)."
}

# Best-effort cleanup in case a previous failed run left them loaded.
& reg.exe unload $SW 2>$null | Out-Null
& reg.exe unload $SY 2>$null | Out-Null

try {
    Write-Host "== 02-offline-registry: loading hives"
    & reg.exe load $SW $softwareHiveFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load SOFTWARE failed" }
    & reg.exe load $SY $systemHiveFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load SYSTEM failed" }

    $P = "Registry::$SW\Policies"   # HKLM\SOFTWARE\Policies inside the image

    # ---- Telemetry / data collection ----
    Set-Dword "$P\Microsoft\Windows\DataCollection" 'AllowTelemetry' 0
    Set-Dword "$P\Microsoft\Windows\DataCollection" 'AllowDeviceNameInTelemetry' 0
    Set-Dword "$P\Microsoft\Windows\DataCollection" 'DoNotShowFeedbackNotifications' 1
    Set-Dword "Registry::$SW\Policies\Microsoft\SQMClient\Windows" 'CEIPEnable' 0

    # ---- Advertising ID ----
    Set-Dword "$P\Microsoft\Windows\AdvertisingInfo" 'DisabledByGroupPolicy' 1

    # ---- Activity history ----
    Set-Dword "$P\Microsoft\Windows\System" 'EnableActivityFeed' 0
    Set-Dword "$P\Microsoft\Windows\System" 'PublishUserActivities' 0
    Set-Dword "$P\Microsoft\Windows\System" 'UploadUserActivities' 0

    # ---- Typing / speech personalization ----
    Set-Dword "$P\Microsoft\InputPersonalization" 'AllowInputPersonalization' 0
    Set-Dword "$P\Microsoft\InputPersonalization" 'RestrictImplicitTextCollection' 1
    Set-Dword "$P\Microsoft\InputPersonalization" 'RestrictImplicitInkCollection' 1

    # ---- Cortana / Copilot / AI data analysis ----
    Set-Dword "$P\Microsoft\Windows\Windows Search" 'AllowCortana' 0
    Set-Dword "$P\Microsoft\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 1
    Set-Dword "$P\Microsoft\Windows\WindowsAI" 'DisableAIDataAnalysis' 1

    # ---- Consumer features (stops suggested-app drip feed) ----
    Set-Dword "$P\Microsoft\Windows\CloudContent" 'DisableWindowsConsumerFeatures' 1

    # ---- Find My Device ----
    Set-Dword "$P\Microsoft\FindMyDevice" 'AllowFindMyDevice' 0

    # ---- Remote Desktop / Remote Assistance host: OFF ----
    Set-Dword "Registry::$SY\ControlSet001\Control\Terminal Server" 'fDenyTSConnections' 1
    Set-Dword "$P\Microsoft\Windows NT\Terminal Services" 'fDenyTSConnections' 1
    Set-Dword "$P\Microsoft\Windows NT\Terminal Services" 'fAllowToGetHelp' 0

    # ---- MDM enrollment / workplace join: BLOCKED ----
    Set-Dword "$P\Microsoft\Windows\CurrentVersion\MDM" 'DisableRegistration' 1
    Set-Dword "$P\Microsoft\Windows\WorkplaceJoin" 'BlockAADWorkplaceJoin' 1

    # ---- Windows Update: no driver delivery, no Delivery Optimization peering ----
    Set-Dword "$P\Microsoft\Windows\WindowsUpdate" 'ExcludeWUDriversInQualityUpdate' 1
    Set-Dword "Registry::$SW\Microsoft\Windows\CurrentVersion\DriverSearching" 'SearchOrderConfig' 0
    Set-Dword "$P\Microsoft\Windows\DeliveryOptimization" 'DODownloadMode' 0

    # ---- LLMNR off (name-resolution broadcasting) ----
    Set-Dword "$P\Microsoft\Windows NT\DNSClient" 'EnableMulticast' 0

    # ---- Location sensors denied at the framework level ----
    Set-Dword "Registry::$SW\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}" 'SensorPermissionState' 0

    # ---- mDNS off in the DNS client ----
    Set-Dword "Registry::$SY\ControlSet001\Services\Dnscache\Parameters" 'EnableMDNS' 0

    # ---- Services disabled in the image itself (Start = 4) ----
    $servicesOff = @(
        'DiagTrack','dmwappushservice','lfsvc','MapsBroker','SensorService','SensrSvc',
        'RemoteRegistry','TermService','UmRdpService','SessionEnv','WinRM','RemoteAccess',
        'SSDPSRV','upnphost','FDResPub','FDPHost','WMPNetworkSvc','RetailDemo',
        'IntuneManagementExtension','CcmExec','CmRcService','Sense','CDPSvc'
    )
    foreach ($svc in $servicesOff) {
        $key = "Registry::$SY\ControlSet001\Services\$svc"
        if (Test-Path $key) {
            Set-Dword $key 'Start' 4
            Write-Host "Service disabled offline: $svc"
        } else {
            Write-Host "Service not present in image (skipped): $svc"
        }
    }

    Write-Host "== 02-offline-registry: policy set applied"
}
finally {
    Write-Host "== 02-offline-registry: unloading hives"
    Unload-Hive $SY
    Unload-Hive $SW
}

Write-Host "== 02-offline-registry done"
