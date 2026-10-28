# Honest Limits — what "ghost" can and cannot mean

This system is built to make the PC **unreachable inbound, quiet outbound, and unenrollable** — and it does that about as completely as Windows allows. It does not make the PC invisible to physics or to networks it voluntarily uses. Specifically:

**What it does**
- Nothing can initiate a connection *into* the PC (inbound default Block; only Core Networking/DHCP allowed).
- Telemetry and management plumbing is disabled at the service, policy, task, and firewall layers, and MDM enrollment is blocked by policy — the PC cannot be enrolled or managed by a school/employer tenant.
- The watchdog re-asserts all of it at **startup, at logon, and every 5 minutes** (and instantly when a new service is installed), so an update that flips something back gets caught and reverted on the next check cycle.

**What it cannot do**
- **It cannot run while the PC is off.** Nothing can. Enforcement resumes at the next power-on (the startup trigger runs as SYSTEM before logon).
- **It cannot survive a clean reinstall.** Any Windows-side tool lives inside Windows; wiping the drive removes it along with everything else. Installing the ghost ISO again is how it comes back — that is by design, not a flaw that can be engineered away.
- **It cannot hide network metadata.** Your phone carrier sees the tethered traffic's existence, timing, and volume; websites see the phone's public IP address (the PC has no public identity of its own behind the tether). Ghosting is about the *device* not reporting, enrolling, or accepting connections — not about anonymizing traffic you choose to send. (That would be a VPN/Tor question, a different tool for a different job.)
- **It cannot remove firmware/hardware identity** (Service Tag, MAC addresses burned into hardware). Those identifiers by themselves transmit nothing; with the network stack, AMT, and radios configured per the BIOS checklist, they have no channel to announce themselves on.

**Deliberate choice: Defender stays ON**
Windows Defender Antivirus and SmartScreen are **kept fully enabled** in this build. A ghost that is also defenseless is just a quieter victim: Defender is the user's own shield against malicious files and links, it is not a management or enrollment channel, and removing it (as many "debloat" ISO guides suggest) would trade real protection for no privacy gain. Ghost ≠ defenseless.

**Cadence, plainly**
"Instantly" isn't something scheduled enforcement can truthfully promise for everything. The real numbers: blacklisted *processes* and *new services* are caught in seconds by the always-on Sentinel; a flipped *setting* can live at most until the next Enforce sweep — **next boot, next logon, or ≤ 5 minutes**, whichever comes first — and in that gap the persistent firewall blocks still apply.
