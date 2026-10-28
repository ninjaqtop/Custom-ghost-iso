$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\ProgramData\NoTracking\guardian.log'
function Log($m){ Add-Content $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" }
$ntDir = 'C:\ProgramData\NoTracking'
$bakDir = 'C:\Windows\Setup\NoTracking'

# Guardian is a single-pass supervisor: check everything once, fix what a
# single pass can fix, log the rest, exit. Enforce re-creates anything
# structural (tasks) on its own runs.

# (a) Sentinel heartbeat: if the Sentinel is not beating, start it
$hb = "$ntDir\sentinel.heartbeat"
$stale = $true
if (Test-Path $hb) { if (((Get-Date) - (Get-Item $hb).LastWriteTime).TotalSeconds -lt 180) { $stale = $false } }
if ($stale) {
  try { Start-ScheduledTask -TaskName 'NoTracking-Sentinel'; Log 'Sentinel heartbeat stale/missing - started NoTracking-Sentinel' }
  catch { Log "Sentinel start failed: $($_.Exception.Message)" }
}

# (b) All four NoTracking tasks must exist (recreation is Enforce's job)
foreach ($t in 'NoTracking-Enforce','NoTracking-Enforce-Event','NoTracking-Sentinel','NoTracking-Guardian') {
  if (-not (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue)) {
    Log "ALERT: scheduled task missing: $t"
  }
}

# (c) All five scripts must exist live; restore any missing one from backup
foreach ($f in 'enforce.ps1','sentinel.ps1','guardian.ps1','allow.ps1','remove.ps1') {
  $live = Join-Path $ntDir $f
  $backup = Join-Path $bakDir $f
  if (-not (Test-Path $live)) {
    if (Test-Path $backup) { Copy-Item $backup $live -Force; Log "ALERT: $f missing - restored from backup" }
    else { Log "ALERT: $f missing and NO backup found" }
  }
}
