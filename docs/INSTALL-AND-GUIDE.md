# NoTracking v5 (Final) — Install & User Guide

## 1. What this system is

Five cooperating PowerShell scripts, installed once, that keep a Windows 11 PC
unenrollable, unreachable inbound, and quiet outbound — permanently, and
self-healing:

- **Enforce** (`enforce.ps1`) — the main sweep: policies, services, tasks,
  firewall, app removals, account lockdown, learned blacklist. Runs as SYSTEM
  at **startup, at logon, every 5 minutes**, and **immediately when a new
  service is installed** (Event 7045 trigger task).
- **Sentinel** (`sentinel.ps1`) — the always-on real-time layer: WMI watchers
  kill blacklisted processes and flag new org/IT services within seconds, and
  it hosts **DownloadGuard**, which watches the download folders (see §5).
- **Guardian** (`guardian.ps1`) — a tiny supervisor that runs every
  **2 minutes**: checks the Sentinel's heartbeat, the four NoTracking tasks,
  and that all five scripts still exist — restoring anything missing from the
  pristine backups in `C:\Windows\Setup\NoTracking\`.
- **Allow / Remove** (`allow.ps1`, `remove.ps1`) — not services; they run only
  when you click a DownloadGuard warning button (see §5), behind an
  owner-account + password gate.
- **Integrity** — the installer records SHA256 hashes of all five scripts;
  Enforce and Sentinel verify the core scripts against them and restore from
  backup on mismatch. A **learned blacklist** (`learned.txt`) permanently
  remembers every new offender the pattern heuristics catch and applies those
  entries first on every later run.

Everything lives in `C:\ProgramData\NoTracking\`, logs in the same folder
(`enforce.log`, `sentinel.log`, `guardian.log`), backups in
`C:\Windows\Setup\NoTracking\`.

## 2. Install route A — paste installer (existing Windows 11)

Use this on the PC as it stands today.

1. **Prerequisites:** Windows 11 installed and signed in with your local
   account; you need an **Administrator** PowerShell window.
2. Open `full-disable-v5-paste.txt`, **Select All → Copy**.
3. Open **PowerShell as Administrator**, click into the window, **paste**,
   press **Enter**. (Pasting the `.txt` is identical to the `.ps1` — same
   bytes, friendlier file type.)
4. The installer writes the five scripts, stages the backups and hashes,
   registers the four tasks (`NoTracking-Enforce`, `NoTracking-Enforce-Event`,
   `NoTracking-Sentinel`, `NoTracking-Guardian`), runs Enforce once in your
   session, starts the Sentinel, applies the folder ACL hardening, and creates
   **`gate.cfg`** bound to *your* account SID.
5. Read the ending: it prints **DONE** and shows the last lines of
   `enforce.log`. Then run the proof checklist in §4.

Notes: the gate (warning buttons) is bound to the account that runs this
installer — run it as your own account, not a different admin. Re-running the
installer later is safe; it re-stages and re-registers everything.

## 3. Install route B — the ghost ISO

1. **Build:** in this repo, run the **Build Ghost ISO** GitHub Actions
   workflow. Download the split parts + `SHA256SUMS.txt` from the Release.
2. **Join + verify:** on a Windows machine:
   `copy /b ghost-win11.iso.part1 + ghost-win11.iso.part2 + ... ghost-win11.iso`
   (use the actual part names), then compare the ISO's SHA256 against
   `SHA256SUMS.txt` (`Get-FileHash ghost-win11.iso`).
3. **Burn with DROFUS** (Android): **GPT** partition scheme, **FAT32 with
   split install.wim**, **high-speed mode ON**. Do **not** use EtchDroid —
   it does not reliably produce bootable Windows installers; DROFUS is the
   tested tool for this machine.
4. **BIOS pre-checks** (see `docs/BIOS-CHECKLIST.md`): storage mode
   **AHCI/NVMe** (set before installing, never switched afterwards), Secure
   Boot **On / Deployed Mode**, USB Boot Support **ON** for the install.
5. **Install offline.** Do not tether or join any network during setup. The
   answer file suppresses the online-account screens — create your **local
   account** and decline anything else offered.
6. **First logon:** `SetupComplete` has already registered the tasks and run
   Enforce as SYSTEM during setup; at first sign-in the answer file runs
   Enforce once in your user context and applies the folder ACLs.
7. **No finishing step needed.** The first-logon Enforce run (step 6)
   executes in your user context, and Enforce now creates the warning
   buttons' `gate.cfg` itself whenever it is missing — bound to your
   account SID. The ALLOW/REMOVE buttons therefore work from first logon.
   (Enforce's self-healing also covers all five scripts now: its
   restore-from-backup, hash-verify, and hash-regeneration lists all
   include `allow.ps1` and `remove.ps1`.)
8. After installing: set **USB Boot Support back OFF** in BIOS.

## 4. Post-install proof checklist (run on the PC)

```powershell
# All four tasks exist (Enforce may show several triggers)
Get-ScheduledTask -TaskName 'NoTracking-*' | Select-Object TaskName, State

# Fresh enforcement: timestamps should be current, plus your accounts line
Get-Content C:\ProgramData\NoTracking\enforce.log -Tail 20

# Sentinel + Guardian are alive
Get-Content C:\ProgramData\NoTracking\sentinel.log -Tail 5
Get-Content C:\ProgramData\NoTracking\guardian.log -Tail 5

# Not enrolled anywhere: every *Joined value should read NO
dsregcmd /status

# The five hard outbound blocks exist and are enabled
Get-NetFirewallRule -DisplayName 'NoTracking-BlockOut-*' |
  Select-Object DisplayName, Enabled, Action

# Core telemetry services are stopped and disabled
Get-Service DiagTrack, dmwappushservice | Select-Object Name, Status, StartType

# After a day of use: these appear as the system works
Test-Path C:\ProgramData\NoTracking\learned.txt
Get-ChildItem C:\ProgramData\NoTracking\Quarantine -ErrorAction SilentlyContinue
```

## 5. How the finished system behaves

- **Day to day you see nothing.** The layers check each other constantly:
  if the Sentinel dies, the Guardian restarts it; if a task is deleted,
  Enforce recreates it; if a script file is altered, its hash mismatch
  restores the pristine backup and logs an `ALERT integrity` line.
- **Updates, reboots, hard shutdowns:** nothing runs while the PC is off —
  and nothing needs to. At power-on the startup triggers fire as SYSTEM
  *before* the sign-in screen, and anything an update flipped is reverted
  on the first sweep (≤ 5 minutes, or instantly for a new service).
- **DownloadGuard:** installers landing in any profile's **Downloads** or
  **Desktop**, the Public Downloads folder, or `C:\Windows\Temp` are checked
  by name and content class. Known dev tools (Android Studio, Node, Git,
  Python, JDK, Gradle, Chrome…) are logged and left alone. Blacklist-named
  or unknown installers are **quarantined** to
  `C:\ProgramData\NoTracking\Quarantine\`, and you get:
  - a `WATCHDOG-WARNING.txt` on the Desktop listing **every** factor that
    stopped the file — each matched term, the signature status and signer,
    publisher metadata, the SHA256 fingerprint — and
  - two one-time button files, **ALLOW-…** and **REMOVE-…**.
- **The gate:** either button first checks that *you* are the account
  recorded in `gate.cfg`, then asks for the **gate password** (3 attempts;
  wrong tries are logged and burn nothing). **ALLOW** restores that one
  exact file (fingerprint-verified), launches it, and opens a **30-minute
  install window** so the installer's own follow-on files aren't stopped
  mid-install — blacklist-named files are still blocked inside the window,
  and any different file or new version is checked fresh afterwards.
  **REMOVE** permanently deletes the quarantined file (and an identical
  copy at the original location, if present). Using either button deletes
  both, and every use is logged (`ALLOW-ANYWAY` / `USER REMOVED`).
- **Manual restore:** rename a quarantined file back (strip the
  `.quarantined-<timestamp>` suffix) and move it where you want it. Note it
  will be re-checked if it lands in a watched folder again.
- **Learning:** when the pattern heuristics catch something new — a service,
  task, app, or process that smells like remote management, enrollment, or
  telemetry — it is written to `learned.txt` forever and treated as a named
  target from then on. The list only grows; see it any time at
  `C:\ProgramData\NoTracking\learned.txt`.

## 6. Honest limits

- **Defender stays ON — by design.** Windows Defender and SmartScreen are
  your shield against actual malware; they are not a management channel,
  and removing them would buy no privacy. Ghost ≠ defenseless.
- **Microsoft-account sign-in is dead on purpose** (`NoConnectedUser = 3`,
  sign-in services disabled). Side effect: **Microsoft Store installs that
  require sign-in will not work.** Windows Update does not need an account
  and is unaffected; Chrome, Android Studio, Node/npm, and Git all work
  normally.
- **DownloadGuard covers the standard landing zones** (Downloads, Desktop,
  Public Downloads, Windows Temp) — not every folder on disk. A download
  deliberately aimed elsewhere is still backstopped by the firewall blocks
  and disabled services, which don't care where a program lives.
- **"Learning" means a self-updating blacklist**, not self-rewriting code:
  the enforcement core stays fixed and hash-verified; the *list* adapts.
- **No Windows-side system survives a clean reinstall**, and an
  administrator at the keyboard can undo any of it — the ACLs and hashes
  stop casual and other-account tampering, not admins. Firmware-level
  items (AMT, Absolute) live in the BIOS checklist, not in Windows.
- **While the PC is off, nothing runs** — on any PC, under any system. All
  layers refire at boot, before sign-in.
- **Verification level:** there is no PowerShell on the build machine, so
  these scripts passed structural verification (balance, diff audit,
  cross-file consistency) — the first true PowerShell parse happens on
  your PC. (v3 and v4 both ran clean on their first parses.)
- **Former exceptions — closed 2026-10-28:** earlier states of this guide
  listed three open items; all are now closed, and no manual finishing
  step remains on either install route.
  1. Enforce's restore, hash-verify, and hash-regeneration lists cover
     all five scripts, including `allow.ps1`/`remove.ps1`.
  2. On the ISO path, `gate.cfg` is created automatically at the first
     user-context Enforce run (the unattend first-logon run), so the
     ALLOW/REMOVE buttons are live from first logon.
  3. SetupComplete's restore-if-missing enumeration names all five
     scripts (enforce plus sentinel, guardian, allow, remove).
