# Custom Ghost ISO — Windows 11 Pro, hardened at build time

Builds a customized **Windows 11 Pro x64 ISO** from the **official Microsoft ISO** using GitHub Actions, with a privacy/telemetry hardening system baked in so a fresh install comes up already "ghosted" — no post-install script paste required.

The hardening is the same system as the **NoTracking v5 (Final)** watchdog system in this repo — three cooperating scripts: `watchdog/enforce.ps1` (the enforcement sweep), `watchdog/sentinel.ps1` (an always-on real-time layer), and `watchdog/guardian.ps1` (a 2-minute supervisor). Together they apply privacy/telemetry policies, disable tracking services and tasks, harden the firewall, block MDM enrollment and Microsoft-account sign-in by policy, remove bundled consumer apps (Copilot, Microsoft 365 app, Clipchamp, Teams consumer, Spotify stubs, and similar — see `build/config/packages-to-remove.txt`), and remove OneDrive.

## What the build does

The GitHub Actions workflow (`.github/workflows/build-ghost-iso.yml`, windows-latest runner):

1. Downloads **Fido.ps1** (the open-source script by the Rufus author) and uses it to get an official Microsoft download link for Windows 11 Pro x64, then downloads that ISO and logs its size and SHA256.
2. Installs the **Windows ADK Deployment Tools** to get `oscdimg.exe` for rebuilding a bootable ISO.
3. Extracts the ISO, keeps only the **Windows 11 Pro** image index (converting `install.esd` to `install.wim` if needed), and mounts it with DISM.
4. **Strips provisioned apps** listed in `build/config/packages-to-remove.txt` (`build/scripts/01-strip-packages.ps1`).
5. **Applies machine-level policies offline** by loading the image's registry hives (`build/scripts/02-offline-registry.ps1`): telemetry off, advertising ID off, activity history off, Cortana/Copilot/Recall policies off, consumer features off, Find My Device off, Remote Desktop / Remote Assistance host off, **MDM enrollment blocked** (`DisableRegistration`), workplace join blocked, Windows Update driver delivery excluded, Delivery Optimization peer mode off, LLMNR off — plus the tracking/remote/discovery services set to **disabled** in the image itself.
6. **Injects the watchdog system** (`build/scripts/03-inject-files.ps1`): the three scripts are placed at `ProgramData\NoTracking\` inside the image (with pristine backup copies under `Windows\Setup\NoTracking\`), plus `SetupComplete.cmd`, which registers the scheduled tasks (Enforce at startup/logon/every 5 minutes, **Sentinel** at startup/logon with unlimited runtime, **Guardian** every 2 minutes — all as SYSTEM) when Windows Setup finishes, and runs Enforce once immediately. Enforce also self-registers an event task that fires an enforcement run the moment a new service is installed (Event 7045, Service Control Manager), so an org/IT agent cannot slip in between sweeps. The first-logon command in `unattend.xml` also runs it once in the user context so per-user settings land on the real user's hive.

   **The v5 (Final) architecture, in one paragraph each:**
   - **Sentinel (always-on):** a resident SYSTEM process that watches process and service creation in real time (WMI events) and kills org/IT agent processes within seconds; runs **DownloadGuard** (below); keeps a 30-second heartbeat; verifies `enforce.ps1`'s integrity hash and restores it from backup if it is tampered with or deleted.
   - **Guardian (every 2 minutes):** a single-pass supervisor — if the Sentinel's heartbeat is stale it restarts it, it checks all four NoTracking tasks exist, and it restores any missing script from the pristine backups.
   - **Enforce (every 5 min + startup/logon + Event 7045):** the full sweep — policies, services (org agents deleted outright; inbox services disabled-only, because a deleted inbox service can be restored by Windows servicing with its default *enabled* settings, while a disabled one stays disabled), tasks, apps, firewall, accounts — plus self-healing: it recreates any missing NoTracking task, restores missing/tampered scripts against recorded SHA256 hashes, and restarts the Sentinel if its heartbeat is stale. The three scripts supervise each other in a triangle; no single point of failure short of an administrator or a reinstall.
   - **Learned blacklist:** whenever the pattern heuristics catch a service, task, app, or process the static lists did not name, the catch is written to `C:\ProgramData\NoTracking\learned.txt` and applied *first* on every later run. The list teaches itself new entries; the enforcement core does not rewrite its own code.
   - **DownloadGuard (inside the Sentinel):** watches Downloads/Desktop of every profile, the Public Downloads folder, and `C:\Windows\Temp` for installer-type files (`.exe/.msi/.msix/.appx/.ps1/.bat/.cmd/.scr/.com`). Blacklist-named files (Intune/SCCM/Absolute/SupportAssist/enrollment-type) and *unknown* installers are moved to `C:\ProgramData\NoTracking\Quarantine\`, a `WATCHDOG WARNING` is logged, and a `WATCHDOG-WARNING.txt` explaining what happened and how to restore a deliberate download is left on the Desktop. Known dev tools (Android Studio, Node, Git, Python, JDK, Gradle, Chrome, Flutter…) are allowed and merely logged.
   - **DownloadGuard warnings + the ALLOW / REMOVE buttons:** the warning now lists *every* factor that stopped the file — each matched blacklist term, the installer class, the Authenticode signature status and signer, the embedded publisher/product/version metadata, and the file's SHA256 fingerprint — and two one-time button files land next to it on the Desktop. **ALLOW** (`allow.ps1`) restores that one exact file (verified against its fingerprint), launches it so the install continues, and opens a 30-minute window so the installer's own follow-on files are not stopped mid-install (blacklist-named files are still blocked even in that window); the approval is recorded by fingerprint, so a different version of the same program is checked fresh. **REMOVE** (`remove.ps1`) permanently deletes the quarantined file — and an identical copy at the original download location, if one is there — without approving or launching anything. Both buttons sit behind the same owner gate: they only run for the account whose SID is recorded in `C:\ProgramData\NoTracking\gate.cfg`, after that user types the gate password (three attempts; failures are logged and consume nothing). Either button consumes the pair and deletes both. The paste installer writes `gate.cfg`; on an ISO-only install the buttons stay locked until `gate.cfg` exists — running the v5 paste installer once creates it.
   - **Microsoft-account sign-in is disabled by policy** (`NoConnectedUser`), and the MSA sign-in services and broker app are disabled/removed — device↔Microsoft account handshake is dead; local accounts and Windows Update (which needs no Microsoft account) are unaffected.
   - **Integrity + ACLs:** the installer records SHA256 hashes of the three scripts, keeps pristine backups under `Windows\Setup\NoTracking\`, and locks both NoTracking folders to SYSTEM + Administrators (+ the owner, modify rights, on `ProgramData\NoTracking`).
7. Rebuilds a standard-layout bootable ISO with `oscdimg` — **the UEFI boot files are untouched**, so the media boots exactly like Microsoft's own.
8. Uploads the ISO two ways (see "Getting the ISO" below).

## Running the workflow

1. Push this repo to GitHub.
2. Go to **Actions → Build Ghost Windows 11 ISO → Run workflow**.
3. Inputs (all have working defaults):
   - `win_release` — e.g. `24H2`
   - `edition_index_name` — `Windows 11 Pro`
   - `language` — e.g. `English`
4. A full run takes a while (large ISO download + DISM servicing). The workflow timeout is set generously (350 minutes).

## Getting the ISO

- **Workflow artifact:** the whole ISO is uploaded as an artifact (7-day retention). Convenient when GitHub storage allows it.
- **Release parts (the reliable free-tier route):** the ISO is also split into 1900 MB parts (`ghost-win11.iso.part001`, `.part002`, …) with a `SHA256SUMS.txt`, attached to a GitHub Release tagged per run. GitHub's free tier can reject very large single artifacts; the parts route avoids that.

  To rejoin the parts on a Windows PC:

  ```cmd
  copy /b ghost-win11.iso.part* ghost-win11.iso
  ```

  Then verify against `SHA256SUMS.txt` (`certutil -hashfile ghost-win11.iso SHA256`).

## Burning to USB on Android — use DROFUS

The target machine is UEFI with Secure Boot on, so the stick must be **GPT + FAT32**, which means the oversized `install.wim` has to be split. Use **DROFUS (ISO 2 USB)** — it is the tested tool for this:

- Partition scheme: **GPT (UEFI)**
- File system: **FAT32**, with **install.wim splitting enabled**
- **High-speed mode: ON**
- Optional DROFUS Windows customizations (remove Microsoft-account requirement, create a local account, skip privacy questions, disable automatic BitLocker) are fine to enable — they complement, and do not conflict with, the hardening baked into the image.
- Leave the TPM / Secure Boot bypass options **OFF** — this machine meets the requirements natively.

> ⚠️ **EtchDroid does NOT reliably boot Windows installers.** EtchDroid writes images raw, block-for-block, which works for Linux ISOs but produces Windows media that typically fails to boot or fails during setup on UEFI systems. Use DROFUS for this ISO.

## What stays fully functional

The ghosting targets *inbound* reachability and *outbound* telemetry/management — not the user. These all work normally, with no per-use unblocking:

- **Google Chrome** and normal web browsing
- **Android Studio**, Command Prompt, **PowerShell**, **Windows Terminal**, File Explorer
- **USB tethering** through your phone for internet (the firewall rules deliberately preserve Core Networking / DHCP)
- **Windows Defender and SmartScreen** — kept on, on purpose (see Honest limits)
- **Microsoft Store** — the app itself is kept, **but** Microsoft-account sign-in is disabled by policy (see above), so Store installs that require sign-in will not work. That is by design in v5: the device↔Microsoft account handshake is dead. Dev tools and software that install without a Microsoft account (Android Studio, Node/npx, Git, Chrome…) are unaffected.
- Windows Update security patches still arrive; **driver** delivery through Windows Update is excluded by policy so firmware/driver state stays under your control

## The firmware half

An ISO can only change Windows. The BIOS/firmware settings that complete the picture (Intel AMT off, Absolute set to Disable in BIOS, Secure Boot state, storage mode, etc.) live in `docs/BIOS-CHECKLIST.md`.

## Honest limits

Read `docs/HONEST-LIMITS.md`. Short version:

- Enforcement is layered: the **Sentinel** reacts to watched process/service events within seconds while the PC is on; the **Guardian** checks every 2 minutes; the **Enforce** sweep runs at startup, logon, every 5 minutes, and immediately when a new service is installed (Event 7045). It is still not literally every nanosecond, and **nothing runs while the PC is off** — the startup triggers fire before logon when power returns, which is the earliest anything can act.
- **DownloadGuard** covers the Downloads and Desktop folders of each profile, the Public Downloads folder, and `C:\Windows\Temp`. It does not watch arbitrary other folders, and it classifies by file name — a deliberately renamed installer is treated as "unknown" and quarantined, not waved through.
- The **learned blacklist** is a self-updating list, not machine learning: the enforcement core never rewrites its own code, it only remembers new names it has caught.
- The ACLs and hash checks stop casual tampering and other accounts; **an administrator at the keyboard can still change ACLs, delete tasks, or remove the system**, and a clean reinstall removes it entirely (the ISO path re-establishes it). No Windows-side software can honestly promise more than that.
- **Windows Defender is intentionally kept.** Ghost means *unreachable and quiet*, not defenseless.
- **No Windows-side tool survives a clean reinstall** — the watchdog is re-established by reinstalling this ISO, not by magic.
- Your phone carrier and any network you use still see connection metadata; no ISO changes that.

## Repo layout

```
.github/workflows/build-ghost-iso.yml   the builder
build/assets/SetupComplete.cmd          registers + first-runs the watchdog at setup end
build/assets/unattend.xml               setup answers + first-logon watchdog run
build/config/packages-to-remove.txt     provisioned apps stripped from the image
build/scripts/01-strip-packages.ps1     offline Appx removal
build/scripts/02-offline-registry.ps1   offline policy + service configuration
build/scripts/03-inject-files.ps1       watchdog/setup file injection
watchdog/enforce.ps1                    the enforcement sweep (policies, services, tasks, apps, firewall)
watchdog/sentinel.ps1                   the always-on real-time layer (event watchers + DownloadGuard)
watchdog/guardian.ps1                   the 2-minute supervisor (heartbeat, tasks, script files)
watchdog/allow.ps1                      DownloadGuard "allow this download anyway" (owner + password gated)
watchdog/remove.ps1                     DownloadGuard "remove this item permanently" (same gate)
docs/BIOS-CHECKLIST.md                  firmware settings (the half an ISO can't do)
docs/HONEST-LIMITS.md                   what "ghost" can and cannot mean
```
