$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\ProgramData\NoTracking\sentinel.log'
function Log($m){ Add-Content $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" }
$ntDir = 'C:\ProgramData\NoTracking'
$bakDir = 'C:\Windows\Setup\NoTracking'

# Single instance only: a second Sentinel never starts.
$mutex = [System.Threading.Mutex]::new($false, 'Global\NoTrackingSentinel')
if (-not $mutex.WaitOne(0)) { exit }

Log "--- sentinel start (pid $PID) ---"

$global:LastEnforce = [datetime]::MinValue
function Trigger-Enforce {
  if (((Get-Date) - $global:LastEnforce).TotalSeconds -gt 60) {
    $global:LastEnforce = Get-Date
    Start-ScheduledTask -TaskName 'NoTracking-Enforce'
  }
}

# ---------- DownloadGuard helpers ----------
function Test-StableFile($path) {
  # True once the file's length stops changing (the download has finished)
  $last = -1
  for ($i = 0; $i -lt 10; $i++) {
    if (-not (Test-Path $path)) { return $false }
    $len = (Get-Item $path).Length
    if ($len -eq $last) { return $true }
    $last = $len
    Start-Sleep -Seconds 3
  }
  return $false
}

function Get-DownloadFacts($path) {
  # Collect every inspectable fact about a downloaded file: size, installer
  # class, source folder, Authenticode signature status / signer, embedded
  # publisher/product/version metadata, and the SHA256 fingerprint. Used by
  # the enriched quarantine path so the warning can list EVERY factor.
  $fi = Get-Item $path
  $ext = $fi.Extension.ToLower()
  $size = $fi.Length
  $sizeHuman = if ($size -ge 1MB) { '{0:N1} MB' -f ($size / 1MB) } elseif ($size -ge 1KB) { '{0:N1} KB' -f ($size / 1KB) } else { "$size bytes" }
  $sha = (Get-FileHash $path -Algorithm SHA256).Hash
  $signer = 'Unsigned'
  $sigLine = 'NOT digitally signed'
  try {
    $sig = Get-AuthenticodeSignature $path
    if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate) {
      $signer = $sig.SignerCertificate.Subject
      $sigLine = "Digitally signed by: $signer"
    } elseif ($sig.Status -ne 'NotSigned') {
      $sigLine = "Digital signature: $($sig.Status)"
    }
  } catch { $sigLine = "Digital signature: could not be checked" }
  $factLines = @(
    "File size: $sizeHuman ($size bytes)",
    "Installer class: $ext",
    "Source folder: $($fi.DirectoryName)",
    $sigLine
  )
  try {
    $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path)
    if ($vi.CompanyName)     { $factLines += "Publisher (file metadata): $($vi.CompanyName)" }
    if ($vi.ProductName)     { $factLines += "Product: $($vi.ProductName)" }
    if ($vi.FileDescription) { $factLines += "Description: $($vi.FileDescription)" }
    if ($vi.FileVersion)     { $factLines += "File version: $($vi.FileVersion)" }
  } catch {}
  $factLines += "SHA256 fingerprint: $sha"
  return [pscustomobject]@{ Lines = $factLines; Sha256 = $sha; Signer = $signer }
}

function Send-ToQuarantine($path, $reason) {
  $qDir = "$ntDir\Quarantine"
  if (-not (Test-Path $qDir)) { New-Item -ItemType Directory -Force -Path $qDir | Out-Null }
  $name = Split-Path $path -Leaf
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $dest = Join-Path $qDir "$name.quarantined-$stamp"
  $moved = $false
  for ($i = 0; $i -lt 3 -and -not $moved; $i++) {
    try { Move-Item $path $dest -Force -ErrorAction Stop; $moved = $true }
    catch { Start-Sleep -Seconds 2 }
  }
  if (-not $moved) { Log "DownloadGuard: FAILED to quarantine $path"; return }
  $warn = "WATCHDOG WARNING - Unsafe download blocked: $path (quarantined as $dest)"
  Log $warn
  Add-Content 'C:\ProgramData\NoTracking\enforce.log' "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $warn"
  # Warning file lands on the Desktop of the profile that fired (the Public
  # Desktop when the source was Temp or the Public folders)
  $desk = 'C:\Users\Public\Desktop'
  if ($path -match '^[A-Z]:\\Users\\([^\\]+)\\') {
    $prof = $Matches[1]
    if ($prof -ne 'Public') { $desk = "C:\Users\$prof\Desktop" }
  }
  $body = @"
================================================================
WATCHDOG WARNING - a download was blocked and quarantined
================================================================
When:         $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
File:         $name
Was saved as: $path
Why blocked:  $reason
Quarantined:  $dest

If this is software YOU deliberately chose to install, you can
restore it: rename the quarantined file back (delete the
".quarantined-$stamp" suffix) and move it back where it was.
Only restore software you chose on purpose. The watchdog blocked
this because it matched the org/IT blacklist, or because it is
an unknown installer-type file - and unknown installers are how
management agents and bundled junk get onto a PC unnoticed.
"@
  try { Add-Content (Join-Path $desk 'WATCHDOG-WARNING.txt') $body } catch {}
}

function Send-ToQuarantineEx($path, $kind, $matchedTerms, $facts, $origReason) {
  # Enriched quarantine (allow-anyway addition): the same move as
  # Send-ToQuarantine, plus a quarantine-manifest entry, a warning that lists
  # EVERY factor that stopped the file, and a one-time ALLOW-<id>.cmd button
  # file placed next to the warning on the Desktop.
  $qDir = "$ntDir\Quarantine"
  if (-not (Test-Path $qDir)) { New-Item -ItemType Directory -Force -Path $qDir | Out-Null }
  $name = Split-Path $path -Leaf
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $dest = Join-Path $qDir "$name.quarantined-$stamp"
  $moved = $false
  for ($i = 0; $i -lt 3 -and -not $moved; $i++) {
    try { Move-Item $path $dest -Force -ErrorAction Stop; $moved = $true }
    catch { Start-Sleep -Seconds 2 }
  }
  if (-not $moved) { Log "DownloadGuard: FAILED to quarantine $path"; return }
  $why = @()
  if ($kind -eq 'blacklist') {
    if ($matchedTerms -and $matchedTerms.Count -gt 0) {
      foreach ($t in $matchedTerms) { $why += "Matched blacklist term: '$t'" }
    } else { $why += $origReason }
  } else {
    $why += 'Not on the known-good tools list and not recognized'
    $why += "Installer-class file ($([IO.Path]::GetExtension($path).ToLower())) - unknown installers are stopped by default"
  }
  if ($facts.Signer -eq 'Unsigned') { $why += 'NOT digitally signed - no verified publisher' }
  else { $why += "Digitally signed by: $($facts.Signer)" }
  $factLines = $facts.Lines | Where-Object { $_ -notlike 'Digitally signed*' -and $_ -notlike 'Digital signature*' -and $_ -notlike 'NOT digitally signed*' }
  $allWhy = $why + $factLines
  $numbered = for ($i = 0; $i -lt $allWhy.Count; $i++) { "  $($i + 1). $($allWhy[$i])" }
  $whyText = $numbered -join "`n"
  $bid = [guid]::NewGuid().ToString()
  $manLine = "$bid|$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')|$path|$dest|$($facts.Sha256)|$($facts.Signer)|$($why -join '; ')"
  try { Add-Content "$ntDir\quarantine-manifest.txt" $manLine } catch {}
  $warn = "WATCHDOG WARNING - Unsafe download blocked: $path (quarantined as $dest) Reasons: $($why -join '; ')"
  Log $warn
  Add-Content 'C:\ProgramData\NoTracking\enforce.log' "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $warn"
  $desk = 'C:\Users\Public\Desktop'
  if ($path -match '^[A-Z]:\\Users\\([^\\]+)\\') {
    $prof = $Matches[1]
    if ($prof -ne 'Public') { $desk = "C:\Users\$prof\Desktop" }
  }
  $id8 = $bid.Substring(0, 8)
  $body = @"
================================================================
WATCHDOG WARNING - a download was stopped
================================================================
WHAT WAS STOPPED
  File:     $name
  Saved as: $path
  When:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

WHY IT WAS STOPPED - EVERY FACTOR
$whyText

WHAT HAPPENED
  The file was quarantined to: $dest
  It cannot run from the quarantine folder.

HOW TO RESTORE IT MANUALLY
  Rename the quarantined file back (delete the ".quarantined-$stamp"
  suffix) and move it back where it was. Only restore software you
  chose on purpose.

TO ALLOW THIS ONE DOWNLOAD ANYWAY
  Double-click the file ALLOW-$id8.cmd on this Desktop and enter
  the gate password. That restores THIS exact file - verified
  against its fingerprint (SHA256 above) - launches it so the
  install continues, and opens a 30-minute window so the
  installer's own follow-on files are not stopped mid-install
  (blacklist-named files are still blocked even in that window).
  The approval covers only this exact file: any other download,
  or a different version of this one, is checked fresh. The
  button works once and removes itself.

TO REMOVE THIS ITEM FROM THE SYSTEM PERMANENTLY
  If you do NOT want this file at all, double-click the file
  REMOVE-$id8.cmd on this Desktop instead. It asks for the same
  owner account and the same gate password, then deletes the
  quarantined file forever - and an identical copy at the
  original location too, if one is there. It is one-time and
  logged, and both buttons remove themselves after either one
  is used. Nothing is approved and nothing is launched.
"@
  try { Add-Content (Join-Path $desk 'WATCHDOG-WARNING.txt') $body } catch {}
  $cmdBody = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"C:\ProgramData\NoTracking\allow.ps1`" -Id $bid`r`npause`r`n"
  try { Set-Content (Join-Path $desk "ALLOW-$id8.cmd") $cmdBody } catch {}
  $rmBody = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"C:\ProgramData\NoTracking\remove.ps1`" -Id $bid`r`npause`r`n"
  try { Set-Content (Join-Path $desk "REMOVE-$id8.cmd") $rmBody } catch {}
}

function Invoke-DownloadGuard($path) {
  $exts = '.exe','.msi','.msix','.msixbundle','.appx','.appxbundle','.ps1','.bat','.cmd','.scr','.com'
  if ($exts -notcontains [IO.Path]::GetExtension($path).ToLower()) { return }
  if (-not (Test-StableFile $path)) { Log "DownloadGuard: skipped (file never stabilized): $path"; return }
  $name = Split-Path $path -Leaf
  $isBlack = ($name -match 'intune|company ?portal|sccm|configmgr|absolute|computrace|supportassist|enroll|mdm' -or ($name -match 'dell' -and $name -match 'support|update|command'))
  # Allow-anyway pre-checks (additive): a file the owner already approved by
  # fingerprint passes, and so does any non-blacklist file that arrives while
  # an approved install is inside its 30-minute window.
  $facts = $null
  try { $facts = Get-DownloadFacts $path } catch {}
  if ($facts) {
    try {
      $alPath = "$ntDir\allowlist.txt"
      if (Test-Path $alPath) {
        $hit = Get-Content $alPath | Where-Object { $_ -like "$($facts.Sha256)|*" } | Select-Object -First 1
        if ($hit) { Log "DownloadGuard: previously approved file allowed: $name"; return }
      }
    } catch {}
    if (-not $isBlack) {
      try {
        $sessPath = "$ntDir\install-session.txt"
        if (Test-Path $sessPath) {
          $sp = ((Get-Content $sessPath -Raw).Trim()) -split '\|'
          if ($sp.Count -ge 2) {
            $expiry = [datetime]::Parse($sp[0])
            if ((Get-Date) -lt $expiry) { Log "DownloadGuard: allowed under install session for '$($sp[1])': $name"; return }
          }
        }
      } catch {}
    }
  }
  if ($isBlack) {
    $terms = @()
    foreach ($kw in 'intune','sccm','configmgr','absolute','computrace','supportassist','enroll','mdm') {
      if ($name -match $kw) { $terms += $kw }
    }
    if ($name -match 'company ?portal') { $terms += 'company portal' }
    if ($name -match 'dell' -and $name -match 'support|update|command') { $terms += 'dell (support/update/command)' }
    $reason = 'matched the org/IT blacklist (Intune / SCCM / Absolute / SupportAssist / enrollment-type software)'
    if ($facts) {
      try { Send-ToQuarantineEx $path 'blacklist' $terms $facts $reason }
      catch { Send-ToQuarantine $path $reason }
    } else { Send-ToQuarantine $path $reason }
    Trigger-Enforce
  } elseif ($name -match 'android-studio|androidstudio|node|nodejs|npm|git-|git_|python|jdk|openjdk|temurin|gradle|kotlin|platform-tools|adb|chrome|flutter|dart') {
    Log "DownloadGuard: allowed $name"
  } else {
    $reason = 'unknown installer-type file (not on the known dev-tools allowlist)'
    if ($facts) {
      try { Send-ToQuarantineEx $path 'unknown' @() $facts $reason }
      catch { Send-ToQuarantine $path $reason }
    } else { Send-ToQuarantine $path $reason }
    Trigger-Enforce
  }
}

# ---------- DownloadGuard: watch the landing zones ----------
$watchDirs = @()
Get-ChildItem 'C:\Users' -Directory | Where-Object { $_.Name -ne 'Public' -and $_.Name -notlike 'Default*' } | ForEach-Object {
  foreach ($sub in 'Downloads','Desktop') {
    $d = Join-Path $_.FullName $sub
    if (Test-Path $d) { $watchDirs += $d }
  }
}
foreach ($d in 'C:\Users\Public\Downloads','C:\Windows\Temp') { if (Test-Path $d) { $watchDirs += $d } }
$watchers = @()
foreach ($d in $watchDirs) {
  try {
    $w = New-Object System.IO.FileSystemWatcher
    $w.Path = $d
    $w.NotifyFilter = [IO.NotifyFilters]'FileName, Size'
    $w.IncludeSubdirectories = $false
    $w.EnableRaisingEvents = $true
    Register-ObjectEvent -InputObject $w -EventName Created -Action { Invoke-DownloadGuard $Event.SourceEventArgs.FullPath } | Out-Null
    Register-ObjectEvent -InputObject $w -EventName Renamed -Action { Invoke-DownloadGuard $Event.SourceEventArgs.FullPath } | Out-Null
    $watchers += $w
    Log "DownloadGuard: watching $d"
  } catch { Log "DownloadGuard: watcher failed for ${d}: $($_.Exception.Message)" }
}

# ---------- Real-time process watcher ----------
try {
  Register-WmiEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Process'" -Action {
    $proc = $Event.SourceEventArgs.NewEvent.TargetInstance
    $pname = $proc.Name
    $static = 'dmclient.exe','deviceenroller.exe','omadmclient.exe','IntuneManagementExtension.exe','CcmExec.exe','CmRcService.exe','OneDrive.exe'
    if ($pname -in $static -or $pname -like 'SupportAssist*') {
      Stop-Process -Id $proc.ProcessId -Force
      Add-Content 'C:\ProgramData\NoTracking\sentinel.log' "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  ALERT: killed $pname pid $($proc.ProcessId)"
      if ($pname -notin $static) {
        # A SupportAssist-pattern process the static list did not name: learn it
        $lp = 'C:\ProgramData\NoTracking\learned.txt'
        $entry = "PROC:$pname"
        try {
          if (-not (Test-Path $lp)) { New-Item -ItemType File -Path $lp -Force | Out-Null }
          if ((Get-Content $lp) -notcontains $entry) {
            Add-Content $lp $entry
            Add-Content 'C:\ProgramData\NoTracking\sentinel.log' "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  Learned: added $entry"
          }
        } catch {}
      }
      if (((Get-Date) - $global:LastEnforce).TotalSeconds -gt 60) {
        $global:LastEnforce = Get-Date
        Start-ScheduledTask -TaskName 'NoTracking-Enforce'
      }
    }
  } | Out-Null
  Log 'Process watcher registered'
} catch { Log "Process watcher FAILED: $($_.Exception.Message)" }

# ---------- Real-time service watcher ----------
try {
  Register-WmiEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 5 WHERE TargetInstance ISA 'Win32_Service'" -Action {
    $svc = $Event.SourceEventArgs.NewEvent.TargetInstance
    if ($svc.Name -match 'Intune|MDM|Enrollment|SCCM|ConfigMgr|Absolute|Computrace|SupportAssist' -or $svc.DisplayName -match 'Intune|MDM|Enrollment|SCCM|ConfigMgr|Absolute|Computrace|SupportAssist') {
      Add-Content 'C:\ProgramData\NoTracking\sentinel.log' "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  ALERT: new org/IT service appeared: $($svc.Name)"
      if (((Get-Date) - $global:LastEnforce).TotalSeconds -gt 60) {
        $global:LastEnforce = Get-Date
        Start-ScheduledTask -TaskName 'NoTracking-Enforce'
      }
    }
  } | Out-Null
  Log 'Service watcher registered'
} catch { Log "Service watcher FAILED: $($_.Exception.Message)" }

# ---------- Main loop: heartbeat + mutual supervision ----------
$iter = 0
try {
  while ($true) {
    Set-Content "$ntDir\sentinel.heartbeat" (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    if (-not (Test-Path "$ntDir\enforce.ps1") -and (Test-Path "$bakDir\enforce.ps1")) {
      Copy-Item "$bakDir\enforce.ps1" "$ntDir\enforce.ps1" -Force
      Log 'ALERT: enforce.ps1 was missing - restored from backup'
    }
    $iter++
    if ($iter % 10 -eq 0) {
      # Integrity: enforce.ps1 must match its recorded hash
      $hf = "$ntDir\hashes.txt"
      if (Test-Path $hf) {
        $line = Get-Content $hf | Where-Object { $_ -like 'enforce.ps1 *' } | Select-Object -First 1
        if ($line) {
          $want = ($line -split '\s+')[1]
          $now = (Get-FileHash "$ntDir\enforce.ps1" -Algorithm SHA256).Hash
          if ($want -and $now -ne $want) {
            if (Test-Path "$bakDir\enforce.ps1") { Copy-Item "$bakDir\enforce.ps1" "$ntDir\enforce.ps1" -Force }
            Log 'ALERT: enforce.ps1 integrity mismatch - restored from backup'
          }
        }
      }
      foreach ($t in 'NoTracking-Enforce','NoTracking-Enforce-Event','NoTracking-Sentinel','NoTracking-Guardian') {
        if (-not (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue)) { Log "ALERT: scheduled task missing: $t" }
      }
      if (-not (Get-ScheduledTask -TaskName 'NoTracking-Enforce' -ErrorAction SilentlyContinue)) {
        Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ProgramData\NoTracking\enforce.ps1' -WindowStyle Hidden
        Log 'ALERT: NoTracking-Enforce task missing - launched enforce.ps1 directly to self-heal'
      }
    }
    Start-Sleep -Seconds 30
  }
} finally {
  Get-EventSubscriber | Unregister-Event -Force
  try { $mutex.ReleaseMutex() } catch {}
  try { $mutex.Dispose() } catch {}
}
