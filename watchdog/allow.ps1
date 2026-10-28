# ============================================================
#  allow.ps1 - one-time "allow this download anyway" for the
#  NoTracking DownloadGuard. Invoked by an ALLOW-<id>.cmd button
#  file dropped next to a DownloadGuard warning. The button works
#  once, for one exact quarantined file, for the PC's owner only:
#  it checks the owner gate (gate.cfg), asks for the gate
#  password, verifies the file against its recorded SHA256
#  fingerprint, restores it, launches it, and opens a 30-minute
#  window so the install is not stopped again mid-flight.
# ============================================================
param([Parameter(Mandatory=$true)][string]$Id)

$ErrorActionPreference = 'Continue'
$ntDir = 'C:\ProgramData\NoTracking'
$log = "$ntDir\enforce.log"
function Log($m){ Add-Content $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" }

# SHA256 of the gate password - confirmation lock, not a vault
$GateHash = 'abdb244ec4dee0f5aa9e450095c2574d5cb268811f8a85abda8f3a5e1567e030'

# ---- Gate 1: owner identity (fail closed) ----
$ownerSid = $null
$gateFile = "$ntDir\gate.cfg"
if (Test-Path $gateFile) {
  foreach ($gl in (Get-Content $gateFile)) {
    if ($gl -match '^OwnerSID=(.+)$') { $ownerSid = $Matches[1].Trim() }
  }
}
$mySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if (-not $ownerSid -or $mySid -ne $ownerSid) {
  Log 'ALERT: allow-anyway refused - gate.cfg missing or owner mismatch'
  Write-Host 'This button only works for the PC owner account it was created for.' -ForegroundColor Red
  exit 1
}

# ---- Gate 2: gate password (3 attempts; the manifest entry is NOT
# consumed by a failed gate, so the button stays usable) ----
$gateOk = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
  $sec = Read-Host -AsSecureString 'Enter the gate password to allow this download'
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
  $plain = $null
  $sha = [Security.Cryptography.SHA256]::Create()
  $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLower()
  if ($digest -ieq $GateHash) { $gateOk = $true; break }
  Log "ALLOW-ANYWAY: wrong gate password (attempt $attempt)"
  Write-Host "Wrong password (attempt $attempt of 3)." -ForegroundColor Yellow
}
if (-not $gateOk) {
  Log 'ALERT: allow-anyway aborted - gate password failed 3 times'
  Write-Host 'Too many wrong passwords - nothing was restored or run.' -ForegroundColor Red
  exit 1
}

# ---- Find the manifest entry for this button ----
$manPath = "$ntDir\quarantine-manifest.txt"
$manLines = @()
if (Test-Path $manPath) { $manLines = Get-Content $manPath }
$entry = $null
foreach ($l in $manLines) {
  if ($l -and $l -notlike 'USED|*' -and $l -notlike 'REMOVED|*') {
    $p = $l -split '\|'
    if ($p.Count -ge 7 -and $p[0] -eq $Id) { $entry = $p; break }
  }
}
if (-not $entry) {
  Write-Host 'This allow button has already been used or is no longer valid.'
  Log "ALLOW-ANYWAY: button used with an unknown or consumed id ($($Id.Substring(0, [Math]::Min(8, $Id.Length))))"
  exit 1
}
$origPath = $entry[2]
$qPath    = $entry[3]
$wantHash = $entry[4]
$name = Split-Path $origPath -Leaf

# ---- Verify the quarantined file against its fingerprint ----
if (-not (Test-Path $qPath)) {
  Log "ALERT: allow-anyway failed - quarantined file missing for '$name'"
  Write-Host "The quarantined file is missing - nothing to restore."
  exit 1
}
$nowHash = (Get-FileHash $qPath -Algorithm SHA256).Hash
if ($nowHash -ne $wantHash) {
  Log "ALERT: allow-anyway refused - hash mismatch for '$name'"
  Write-Host 'The file no longer matches the fingerprint recorded when it was blocked - refusing to restore it.' -ForegroundColor Red
  exit 1
}

# ---- Restore it to where it was downloaded ----
$destDir = Split-Path $origPath -Parent
if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
Move-Item $qPath $origPath -Force

# ---- Record the approval (by fingerprint) + open the install window ----
Add-Content "$ntDir\allowlist.txt" "$wantHash|$origPath|$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')|$Id"
$expiry = (Get-Date).AddMinutes(30).ToString('yyyy-MM-ddTHH:mm:ss')
Set-Content "$ntDir\install-session.txt" "$expiry|$name|$wantHash"

# ---- Consume the manifest entry (one-time) ----
$out = foreach ($l in $manLines) {
  if ($l -and $l -notlike 'USED|*' -and $l -notlike 'REMOVED|*' -and ($l -split '\|')[0] -eq $Id) { "USED|$l" } else { $l }
}
Set-Content $manPath $out

Log "ALLOW-ANYWAY: user approved '$name' (sha256 $($wantHash.Substring(0, 12))) - restored and launched; install session open for 30 minutes"
Write-Host "Approved: $name has been restored and will now run." -ForegroundColor Green

# ---- Launch it so the install continues ----
$ext = [IO.Path]::GetExtension($origPath).ToLower()
try {
  if ($ext -eq '.ps1') {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$origPath`""
  } else {
    Start-Process $origPath
  }
} catch {
  Log "ALLOW-ANYWAY: launch failed for '$name': $($_.Exception.Message)"
  Write-Host "Restored to $origPath - run it manually to install." -ForegroundColor Yellow
}

# ---- Retire BOTH buttons: ALLOW and REMOVE resolve together ----
try {
  $desk = [Environment]::GetFolderPath('Desktop')
  $id8 = $Id.Substring(0, 8)
  foreach ($b in "ALLOW-$id8.cmd", "REMOVE-$id8.cmd") {
    $bp = Join-Path $desk $b
    if (Test-Path $bp) { Remove-Item $bp -Force }
  }
} catch {}
