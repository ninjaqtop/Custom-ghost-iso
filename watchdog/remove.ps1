# ============================================================
#  remove.ps1 - one-time "remove this download permanently" for
#  the NoTracking DownloadGuard. Invoked by a REMOVE-<id>.cmd
#  button file dropped next to a DownloadGuard warning. Same
#  owner + password gate as allow.ps1. Deletes the quarantined
#  file forever - plus an identical copy (same SHA256) at the
#  original download location, if one is there. Nothing is
#  approved, nothing is launched, no install window is opened.
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
  Log 'ALERT: remove refused - gate.cfg missing or owner mismatch'
  Write-Host 'This button only works for the PC owner account it was created for.' -ForegroundColor Red
  exit 1
}

# ---- Gate 2: gate password (3 attempts; the manifest entry is NOT
# consumed by a failed gate, so the button stays usable) ----
$gateOk = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
  $sec = Read-Host -AsSecureString 'Enter the gate password to remove this download permanently'
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
  $plain = $null
  $sha = [Security.Cryptography.SHA256]::Create()
  $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLower()
  if ($digest -ieq $GateHash) { $gateOk = $true; break }
  Log "REMOVE: wrong gate password (attempt $attempt)"
  Write-Host "Wrong password (attempt $attempt of 3)." -ForegroundColor Yellow
}
if (-not $gateOk) {
  Log 'ALERT: remove aborted - gate password failed 3 times'
  Write-Host 'Too many wrong passwords - nothing was deleted.' -ForegroundColor Red
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
  Write-Host 'This remove button has already been used or is no longer valid.'
  Log "REMOVE: button used with an unknown or consumed id ($($Id.Substring(0, [Math]::Min(8, $Id.Length))))"
  exit 1
}
$origPath = $entry[2]
$qPath    = $entry[3]
$wantHash = $entry[4]
$name = Split-Path $origPath -Leaf

# ---- Delete the quarantined file (fingerprint-checked when present) ----
if (Test-Path $qPath) {
  $nowHash = (Get-FileHash $qPath -Algorithm SHA256).Hash
  if ($nowHash -ne $wantHash) {
    Log "ALERT: remove refused - hash mismatch for '$name'"
    Write-Host 'The quarantined file no longer matches the fingerprint recorded when it was blocked - nothing was deleted.' -ForegroundColor Red
    exit 1
  }
  Remove-Item $qPath -Force
}

# ---- An identical copy at the original location goes too ----
$alsoOrig = $false
if (Test-Path $origPath) {
  try {
    if ((Get-FileHash $origPath -Algorithm SHA256).Hash -eq $wantHash) {
      Remove-Item $origPath -Force
      $alsoOrig = $true
    }
  } catch {}
}

# ---- Consume the manifest entry as REMOVED (one-time) ----
$out = foreach ($l in $manLines) {
  if ($l -and $l -notlike 'USED|*' -and $l -notlike 'REMOVED|*' -and ($l -split '\|')[0] -eq $Id) { "REMOVED|$l" } else { $l }
}
Set-Content $manPath $out

$msg = "USER REMOVED: '$name' (sha256 $($wantHash.Substring(0, 12))) deleted from quarantine"
if ($alsoOrig) { $msg += ' and original location' }
Log $msg
Write-Host "Removed: $name has been permanently deleted." -ForegroundColor Green

# ---- Retire BOTH buttons: ALLOW and REMOVE resolve together ----
try {
  $desk = [Environment]::GetFolderPath('Desktop')
  $id8 = $Id.Substring(0, 8)
  foreach ($b in "ALLOW-$id8.cmd", "REMOVE-$id8.cmd") {
    $bp = Join-Path $desk $b
    if (Test-Path $bp) { Remove-Item $bp -Force }
  }
} catch {}
