$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\ProgramData\NoTracking\enforce.log'
function Log($m){ Add-Content $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" }
function Set-Reg($path,$name,$val){
  if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
  New-ItemProperty -Path $path -Name $name -Value $val -PropertyType DWord -Force | Out-Null
}

# ---------- 0. Self-healing triggers: the watchdog guards its own tasks ----------
# If a NEW service gets installed (Event 7045, Service Control Manager), the
# NoTracking-Enforce-Event task fires within seconds and re-checks everything,
# so an org/IT agent cannot slip in between sweeps. This block re-creates that
# event task on every run if anything ever removes it.
try {
  if (-not (Get-ScheduledTask -TaskName 'NoTracking-Enforce-Event' -ErrorAction SilentlyContinue)) {
    $evAction    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ProgramData\NoTracking\enforce.ps1'
    $evTrigger   = New-CimInstance -CimClass (Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler') -Property @{ Enabled = $true; Subscription = "*[System[Provider[@Name='Service Control Manager'] and (EventID=7045)]]" } -ClientOnly
    $evPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $evSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName 'NoTracking-Enforce-Event' -Action $evAction -Trigger $evTrigger -Principal $evPrincipal -Settings $evSettings -Force | Out-Null

    Log 'Self-heal: created NoTracking-Enforce-Event task (fires on new service install, Event 7045)'
  }
} catch { Log "Self-heal: event task check failed: $($_.Exception.Message)" }
try {
  $mainTask = Get-ScheduledTask -TaskName 'NoTracking-Enforce' -ErrorAction SilentlyContinue
  if ($mainTask) {
    $rep = $mainTask.Triggers | Where-Object { $_.Repetition -and $_.Repetition.Interval } | Select-Object -First 1
    if ($rep -and $rep.Repetition.Interval -ne 'PT5M') {
      Log "Self-heal: main task repetition is $($rep.Repetition.Interval), not 5 minutes - re-run the v5 installer to fix the cadence"
    }
  }
} catch { Log "Self-heal: main task check failed: $($_.Exception.Message)" }

# ---------- 0 (cont.): scripts, Sentinel/Guardian tasks, integrity ----------
$ntDir = 'C:\ProgramData\NoTracking'
$bakDir = 'C:\Windows\Setup\NoTracking'
# Restore the other scripts from the pristine backup if deleted
foreach ($f in 'sentinel.ps1','guardian.ps1','allow.ps1','remove.ps1') {
  if (-not (Test-Path "$ntDir\$f") -and (Test-Path "$bakDir\$f")) {
    Copy-Item "$bakDir\$f" "$ntDir\$f" -Force
    Log "Self-heal: $f restored from backup"
  }
}
# Recreate the Sentinel task if missing (always-on real-time layer)
try {
  if (-not (Get-ScheduledTask -TaskName 'NoTracking-Sentinel' -ErrorAction SilentlyContinue)) {
    $snAction    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ProgramData\NoTracking\sentinel.ps1'
    $snTriggers  = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn))
    $snPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $snSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName 'NoTracking-Sentinel' -Action $snAction -Trigger $snTriggers -Principal $snPrincipal -Settings $snSettings -Force | Out-Null
    Log 'Self-heal: created NoTracking-Sentinel task'
  }
} catch { Log "Self-heal: sentinel task check failed: $($_.Exception.Message)" }
# Recreate the Guardian task if missing (2-minute supervisor)
try {
  if (-not (Get-ScheduledTask -TaskName 'NoTracking-Guardian' -ErrorAction SilentlyContinue)) {
    $gdAction    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ProgramData\NoTracking\guardian.ps1'
    $gdTriggers  = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn), (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)))
    $gdPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $gdSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName 'NoTracking-Guardian' -Action $gdAction -Trigger $gdTriggers -Principal $gdPrincipal -Settings $gdSettings -Force | Out-Null
    Log 'Self-heal: created NoTracking-Guardian task'
  }
} catch { Log "Self-heal: guardian task check failed: $($_.Exception.Message)" }
# Sentinel heartbeat: if the Sentinel is not beating, start it
try {
  $hb = "$ntDir\sentinel.heartbeat"
  $stale = $true
  if (Test-Path $hb) { if (((Get-Date) - (Get-Item $hb).LastWriteTime).TotalSeconds -lt 180) { $stale = $false } }
  if ($stale) { Start-ScheduledTask -TaskName 'NoTracking-Sentinel'; Log 'Self-heal: sentinel heartbeat stale/missing - started NoTracking-Sentinel' }
} catch { Log "Self-heal: sentinel heartbeat check failed: $($_.Exception.Message)" }
# Integrity: the other scripts must match their recorded SHA256.
# On mismatch, restore from the pristine backup. If hashes.txt itself is
# missing, restore all five scripts from backup (when backups exist) and
# regenerate hashes.txt - this is also the first-run bootstrap on the ISO
# install path, where backups are staged but hashes.txt is not.
try {
  $hashFile = "$ntDir\hashes.txt"
  function Write-Hashes {
    $lines = foreach ($f in 'enforce.ps1','sentinel.ps1','guardian.ps1','allow.ps1','remove.ps1') {
      if (Test-Path "$ntDir\$f") { "$f $((Get-FileHash "$ntDir\$f" -Algorithm SHA256).Hash)" }
    }
    Set-Content $hashFile $lines
  }
  if (Test-Path $hashFile) {
    $recorded = @{}
    foreach ($l in (Get-Content $hashFile)) { $parts = $l -split '\s+'; if ($parts.Count -ge 2) { $recorded[$parts[0]] = $parts[1] } }
    $dirty = $false
    foreach ($f in 'sentinel.ps1','guardian.ps1','allow.ps1','remove.ps1') {
      if ($recorded.ContainsKey($f) -and (Test-Path "$ntDir\$f")) {
        $now = (Get-FileHash "$ntDir\$f" -Algorithm SHA256).Hash
        if ($now -ne $recorded[$f]) {
          if (Test-Path "$bakDir\$f") { Copy-Item "$bakDir\$f" "$ntDir\$f" -Force }
          Log "ALERT integrity: $f hash mismatch - restored from backup"
          $dirty = $true
        }
      }
    }
    if ($dirty) { Write-Hashes }
  } else {
    $restored = $false
    foreach ($f in 'enforce.ps1','sentinel.ps1','guardian.ps1','allow.ps1','remove.ps1') {
      if (Test-Path "$bakDir\$f") { Copy-Item "$bakDir\$f" "$ntDir\$f" -Force; $restored = $true }
    }
    Write-Hashes
    Log "Self-heal: hashes.txt was missing - restored-from-backup=$restored, regenerated hashes.txt"
  }
} catch { Log "Self-heal: integrity check failed: $($_.Exception.Message)" }
# DownloadGuard gate file: binds the ALLOW / REMOVE buttons to ONE local
# account (its SID). Created on the first Enforce run that executes in a
# real user context - on the ISO install path that is the unattend
# first-logon run - so the buttons work from first logon with no manual
# finishing step. In a SYSTEM context there is no user to bind: log and
# leave it for the first user-context run.
try {
  $gateFile = "$ntDir\gate.cfg"
  if (-not (Test-Path $gateFile)) {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsSystem) {
      Set-Content $gateFile "OwnerSID=$($me.User.Value)"
      Log "Self-heal: Created gate.cfg for $($me.Name)"
    } else {
      Log 'ALERT: gate.cfg missing (will be created at first user-context run)'
    }
  }
} catch { Log "Self-heal: gate.cfg check failed: $($_.Exception.Message)" }

Log '--- enforce run start ---'

# ---------- 0.4 Learned blacklist: entries this system taught itself ----------
# learned.txt is a self-updating list (SVC:/TASK:/APPX:/PROC:) written by the
# pattern heuristics below whenever they catch something the static lists did
# not name. Learned entries are applied FIRST, before the static sections.
$learnedPath = 'C:\ProgramData\NoTracking\learned.txt'
function Add-Learned($entry) {
  try {
    if (-not (Test-Path $learnedPath)) { New-Item -ItemType File -Path $learnedPath -Force | Out-Null }
    if ((Get-Content $learnedPath) -notcontains $entry) {
      Add-Content $learnedPath $entry
      Log "Learned: added $entry"
    }
  } catch {}
}
if (Test-Path $learnedPath) {
  foreach ($line in (Get-Content $learnedPath)) {
    if (-not $line -or $line -notmatch '^([A-Z]+):(.+)$') { continue }
    $lType = $Matches[1]; $lVal = $Matches[2]
    try {
      switch ($lType) {
        'SVC'  { Stop-Service $lVal -Force; Set-Service $lVal -StartupType Disabled; Log "Learned SVC applied: $lVal" }
        'TASK' { $idx = $lVal.LastIndexOf('\'); if ($idx -gt 0) { Disable-ScheduledTask -TaskPath $lVal.Substring(0, $idx + 1) -TaskName $lVal.Substring($idx + 1) | Out-Null; Log "Learned TASK applied: $lVal" } }
        'APPX' { Get-AppxPackage -AllUsers | Where-Object { $_.Name -like "*$lVal*" } | Remove-AppxPackage -AllUsers; Log "Learned APPX applied: $lVal" }
        'PROC' { Get-Process ($lVal -replace '\.exe$','') -ErrorAction SilentlyContinue | Stop-Process -Force; Log "Learned PROC applied: $lVal" }
      }
    } catch { Log "Learned entry failed ($line): $($_.Exception.Message)" }
  }
}

# ---------- 0.5 Org / IT agent processes: kill on sight ----------
foreach ($p in 'dmclient','deviceenroller','omadmclient','IntuneManagementExtension','CcmExec','CmRcService') {
  Get-Process $p -ErrorAction SilentlyContinue | Stop-Process -Force
}

# ---------- 1. Telemetry / data collection policies ----------
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowDeviceNameInTelemetry' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' 'AllowInputPersonalization' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
Set-Reg 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 0
Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1

# ---------- 2. Location / Find My Device ----------
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' 'SensorPermissionState' 0
$locPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}'
if (-not (Test-Path $locPath)) { New-Item -Path $locPath -Force | Out-Null }
Set-ItemProperty -Path $locPath -Name 'Value' -Value 'Deny'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice' 'AllowFindMyDevice' 0

# ---------- 3. Remote access OFF (host side) ----------
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' 'fDenyTSConnections' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' 'fAllowToGetHelp' 0

# ---------- 4. School / IT management cannot enroll this PC ----------
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\MDM' 'DisableRegistration' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WorkplaceJoin' 'BlockAADWorkplaceJoin' 1
# Microsoft-account sign-in is dead: users cannot add or sign in with a
# Microsoft account anywhere on this PC. Local accounts are unaffected,
# and Windows Update does not need a Microsoft account to work.
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'NoConnectedUser' 3

# ---------- 5. Updates stay under your control ----------
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0

# ---------- 6. Stop announcing yourself on the local network ----------
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' 'EnableMDNS' 0
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' | ForEach-Object {
  Set-ItemProperty $_.PSPath -Name 'NetbiosOptions' -Value 2
}

# ---------- 7. Services: stop + disable ----------
$svcs = 'DiagTrack','dmwappushservice','lfsvc','MapsBroker','SensorService','SensrSvc',
'RemoteRegistry','TermService','UmRdpService','SessionEnv','WinRM','RemoteAccess',
'SSDPSRV','upnphost','FDResPub','FDPHost','WMPNetworkSvc','RetailDemo',
'diagnosticshub.standardcollector.service','XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc',
'IntuneManagementExtension','CcmExec','CmRcService','Sense','CDPSvc','wlidsvc','TokenBroker',
'MicrosoftEdgeUpdate','MicrosoftEdgeUpdateM','sshd'
# Removal matrix: org/IT agents are deleted outright once disabled (their
# binaries live outside Windows). Built-in (inbox) services are NEVER
# deleted - a deleted inbox service can be restored by Windows servicing
# with its DEFAULT (enabled) settings, while a service that exists in the
# Disabled state keeps that state through updates. For inbox components,
# disabled + firewall-blocked is the more permanent state.
$orgDelete = 'IntuneManagementExtension','CcmExec','CmRcService'
foreach ($s in $svcs) {
  Stop-Service $s -Force
  Set-Service $s -StartupType Disabled
  if ($s -in $orgDelete) {
    & sc.exe delete $s | Out-Null
    if ($LASTEXITCODE -eq 0) { Log "REMOVED service: $s" } else { Log "Service kept disabled (delete failed): $s" }
  } elseif (Get-Service $s -ErrorAction SilentlyContinue) {
    Log "DISABLED-ONLY (inbox): $s"
  }
}
# Any Dell / SupportAssist service that ever appears gets the same treatment
Get-Service | Where-Object { $_.Name -match 'Dell|SupportAssist' -or $_.DisplayName -match 'Dell|SupportAssist' } | ForEach-Object {
  Stop-Service $_.Name -Force
  Set-Service $_.Name -StartupType Disabled
  Add-Learned "SVC:$($_.Name)"
}
# Any org / IT remote-management service (Intune, SCCM/ConfigMgr, Absolute/
# Computrace, MDM enrolment) appearing under any name gets the same treatment.
# The named list above is excluded (already handled) and a hard exclusion list
# protects the Windows services this machine actually needs (Defender, Windows
# Update, BITS, crypto) - those are NEVER touched.
$svcPatterns = 'Intune|Absolute|Computrace|rpcnet|SCCM|ConfigMgr|MDM|Enrollment'
$svcExclude  = 'WinDefend|MsMpEng|SecurityHealthService|wuauserv|BITS|CryptSvc|Dhcp|Dnscache|NlaSvc|netprofm|RasMan'
Get-Service | Where-Object {
  ($_.Name -match $svcPatterns -or $_.DisplayName -match $svcPatterns) -and
  $_.Name -notin $svcs -and $_.Name -notmatch $svcExclude
} | ForEach-Object {
  Stop-Service $_.Name -Force
  Set-Service $_.Name -StartupType Disabled
  Log "Org/IT service disabled: $($_.Name)"
  Add-Learned "SVC:$($_.Name)"
  # Third-party binaries (outside the Windows tree) are deleted outright;
  # anything inside Windows stays disabled-only, per the removal matrix.
  $cim = Get-CimInstance Win32_Service -Filter "Name='$($_.Name)'" -ErrorAction SilentlyContinue
  if ($cim -and $cim.PathName -and ($cim.PathName -notmatch [regex]::Escape($env:SystemRoot))) {
    & sc.exe delete $_.Name | Out-Null
    if ($LASTEXITCODE -eq 0) { Log "REMOVED service (third-party): $($_.Name)" }
  }
}
# Heuristic sweep: any service whose BINARY PATH points at org/IT software
# gets the same treatment, whatever its service name is.
Get-CimInstance Win32_Service | Where-Object {
  $_.PathName -match 'Intune|SCCM|ConfigMgr|Absolute|SupportAssist|Computrace' -and
  $_.Name -notmatch $svcExclude -and $_.Name -notin $svcs
} | ForEach-Object {
  if ($_.State -ne 'Stopped' -or $_.StartMode -ne 'Disabled') {
    Stop-Service $_.Name -Force
    Set-Service $_.Name -StartupType Disabled
    Log "ALERT: heuristic path match - service disabled: $($_.Name) [$($_.PathName)]"
    Add-Learned "SVC:$($_.Name)"
  }
}

# ---------- 8. Telemetry + enrollment scheduled tasks: disable ----------
$tasks = @(
 @('\Microsoft\Windows\Application Experience\','Microsoft Compatibility Appraiser'),
 @('\Microsoft\Windows\Application Experience\','ProgramDataUpdater'),
 @('\Microsoft\Windows\Customer Experience Improvement Program\','Consolidator'),
 @('\Microsoft\Windows\Customer Experience Improvement Program\','KernelCeipTask'),
 @('\Microsoft\Windows\Customer Experience Improvement Program\','UsbCeip'),
 @('\Microsoft\Windows\Autochk\','Proxy'),
 @('\Microsoft\Windows\DiskDiagnostic\','Microsoft-Windows-DiskDiagnosticDataCollector'),
 @('\Microsoft\Windows\Feedback\Siuf\','DmClient'),
 @('\Microsoft\Windows\Feedback\Siuf\','DmClientOnScenarioDownload'),
 @('\Microsoft\Windows\Windows Error Reporting\','QueueReporting'),
 @('\Microsoft\Windows\Maps\','MapsToastTask'),
 @('\Microsoft\Windows\Maps\','MapsUpdateTask'),
 @('\Microsoft\Windows\Device Information\','Device')
)
foreach ($t in $tasks) { Disable-ScheduledTask -TaskPath $t[0] -TaskName $t[1] | Out-Null }
Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' | Disable-ScheduledTask | Out-Null
Get-ScheduledTask -TaskPath '\Microsoft\Windows\DeviceManagement\*' | Disable-ScheduledTask | Out-Null
Get-ScheduledTask -TaskPath '\Microsoft\Windows\Workplace Join\*' | Disable-ScheduledTask | Out-Null
Get-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\*' | Disable-ScheduledTask | Out-Null
Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\*' | Disable-ScheduledTask | Out-Null
Get-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Error Reporting\*' | Disable-ScheduledTask | Out-Null
# Any Intune / enterprise-management task hiding under any other path (the
# NoTracking tasks themselves are excluded by name). Anything caught here is
# also written to the learned blacklist so it is applied first on later runs.
Get-ScheduledTask | Where-Object { $_.TaskName -match 'Intune|EnterpriseMgmt|DeviceManagement' -and $_.TaskName -notlike 'NoTracking-*' } | ForEach-Object {
  Disable-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName | Out-Null
  Add-Learned "TASK:$($_.TaskPath)$($_.TaskName)"
}
# Dell / SupportAssist tasks and apps + the school "Take a Test" app + the
# Intune Company Portal: remove on sight
Get-ScheduledTask | Where-Object { $_.TaskName -match 'Dell|SupportAssist' -or $_.TaskPath -match 'Dell|SupportAssist' } | Unregister-ScheduledTask -Confirm:$false
# Remove-on-sight app list: Dell/SupportAssist/school apps, the org/IT apps
# (Company Portal, Intune, the AAD broker plugin), and the full consumer
# bundle list from the ghost ISO (Copilot, OfficeHub, Clipchamp, Xbox,
# Spotify stubs, Widgets, ...) - per-user AND provisioned, so they cannot
# come back for any current or future user profile.
$appxPatterns = 'Dell|SupportAssist|TakeATest|Microsoft\.CompanyPortal|Intune|Microsoft\.AAD\.BrokerPlugin|Microsoft\.Copilot|MicrosoftOfficeHub|Clipchamp|Microsoft\.Todos|SolitaireCollection|MicrosoftTeams|OutlookForWindows|GamingApp|XboxGamingOverlay|XboxIdentityProvider|SpotifyMusic|BingNews|BingWeather|GetHelp|Getstarted|Microsoft\.People|WindowsFeedbackHub|YourPhone|ZuneMusic|ZuneVideo|Client\.WebExperience'
Get-AppxPackage -AllUsers | Where-Object { $_.Name -match $appxPatterns } | Remove-AppxPackage -AllUsers
# Also remove them from the provisioned image so they cannot come back for a
# future user profile
try {
  Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match $appxPatterns } |
    ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName | Out-Null }
} catch { Log "Provisioned app removal skipped: $($_.Exception.Message)" }

# ---------- 8.5 OneDrive: removed ----------
# OneDrive is a Win32 component (not an Appx), so it gets the full
# uninstall + policy treatment. This section re-runs on every sweep, so a
# feature update that brings OneDrive back gets it removed again.
Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
foreach ($od in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") {
  if (Test-Path $od) {
    try { Start-Process $od '/uninstall' -Wait; Log "OneDrive: ran uninstaller $od" } catch { Log "OneDrive: uninstall failed for $od" }
  }
}
Get-ScheduledTask | Where-Object { $_.TaskName -like 'OneDrive*' } | Unregister-ScheduledTask -Confirm:$false
try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive' -ErrorAction Stop; Log 'OneDrive: autostart entry removed' } catch {}

# ---------- 9. Firewall INBOUND: nothing reaches in ----------
# Default inbound = Block on every profile. Then disable EVERY enabled inbound
# Allow rule except Core Networking (your tethered internet needs its DHCP rules).
Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow
Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow |
  Where-Object { $_.DisplayName -notlike 'Core Networking*' } |
  Disable-NetFirewallRule

# ---------- 10. Firewall OUTBOUND: management / telemetry pipes closed ----------
# Disable the outbound Allow rules for the IT-management, telemetry, discovery
# and casting groups found in the outbound list (DiagTrack's own rule included).
$outGroups = 'DiagTrack','Windows Device Management','Work or school account','Remote Assistance',
'Network Discovery','Connected Devices Platform','Cast to Device functionality','Wireless Display',
'Delivery Optimization','Microsoft Family Safety'
foreach ($g in $outGroups) {
  Get-NetFirewallRule -DisplayGroup $g -Direction Outbound | Disable-NetFirewallRule
}
Get-NetFirewallRule -Direction Outbound -Enabled True |
  Where-Object { $_.DisplayName -like 'Recommended Troubleshooting*' } |
  Disable-NetFirewallRule
# Hard program blocks: a Block rule beats ANY Allow rule Windows creates later,
# so the MDM / device-enrollment / Intune / SCCM executables can never phone a
# management server even if some future update re-enables their allow rules.
# The watchdog re-asserts these five blocks on every run, and asserts them
# unconditionally - no check that the file exists first - so the block is
# already in place before the program ever gets installed.
$blockExes = "$env:SystemRoot\System32\dmclient.exe","$env:SystemRoot\System32\deviceenroller.exe","$env:SystemRoot\System32\omadmclient.exe",
'C:\Program Files (x86)\Microsoft Intune Management Extension\IntuneManagementExtension.exe',
'C:\Windows\CCM\CcmExec.exe'
$i = 0
foreach ($exe in $blockExes) {
  $i++
  if (-not (Get-NetFirewallRule -DisplayName "NoTracking-BlockOut-$i" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "NoTracking-BlockOut-$i" -Direction Outbound -Program $exe -Action Block -Profile Any | Out-Null
  }
  Set-NetFirewallRule -DisplayName "NoTracking-BlockOut-$i" -Enabled True -Action Block
}

# ---------- 11. Accounts: only your own local account stays enabled ----------
# The built-in Guest and the built-in Administrator account stay disabled.
# Every enabled local account is written to the log on each run, so if an
# enrollment tool or an update ever creates or enables an account, it shows
# up in enforce.log where you can see it.
try { Disable-LocalUser -Name 'Guest' } catch {}
try { Disable-LocalUser -Name 'Administrator' } catch {}
$enabledAccounts = (Get-LocalUser | Where-Object Enabled | Select-Object -ExpandProperty Name) -join ', '
Log "Enabled local accounts: $enabledAccounts"

Log '--- enforce run complete ---'
