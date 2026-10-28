# BIOS / Firmware Checklist — the half no ISO can do

The ghost ISO hardens **Windows**. These settings live in the Dell firmware and can only be set by hand in BIOS Setup (F2 at boot). Target machine: Dell Pro 14 Plus (PB14250), Core Ultra 5 235U (vPro Enterprise).

## System Management

- **Intel AMT Capability → Disable**
  AMT is a separate management processor environment (vPro) that operates below Windows. On this model it is controlled from the **System Management** page in Dell BIOS — set Intel AMT Capability to **Disable**. (The old Ctrl+P MEBx boot flow from generic internet guides generally does **not** apply to this model; don't go hunting for it.) Also set **USB Provisioning of AMT → Disabled** if present.

## Security

- **Absolute → Disable**
  Absolute (Computrace) is firmware persistence for tracking/recovery. Set it to **Disable**. **NEVER choose "Permanently Disable"** — that option is irreversible by design; plain Disable is fully sufficient and reversible.
- **TPM 2.0 Security → On**, with:
  - **Attestation Enable → OFF** (TPM stays on for Windows; remote attestation offers your boot state to verifiers — not wanted)
  - **TPM Clear → OFF** (no clear operation pending)
  - **PPI Bypass for Clear Commands → OFF**
  - **Key Storage Enable → ON**
- **Start Data Wipe → OFF.** Always. Enabling it secure-erases the drives on next boot.
- **Chassis Intrusion → Disabled**
- **UEFI Boot Path Security → Always** (only meaningful with an admin password set)
- **Admin password: set it** (8+ characters, write it on paper — there is no easy reset). It protects every other setting on this list.

## Boot Configuration

- **Secure Boot → ON**, **Secure Boot Mode → Deployed Mode**
- **Enable Microsoft UEFI CA → Disabled** (this model's factory state; the genuine Windows bootloader is trusted without it, and FAT32 install media built by DROFUS boots under it — NTFS media helpers would not)
- **Enable PXE Boot Priority → Disabled**

## Connection

- **UEFI Network Stack → Disabled**
- **IPv4 / IPv6 PXE Boot → OFF**, **HTTP(s) Boot → OFF**
- **WLAN and Bluetooth device checkboxes → unchecked** (moot — see hardware note — but set anyway)
- **Control WLAN Radio → OFF**

## Integrated Devices

- **Integrated NIC → Disabled** (this model has no physical Ethernet port; internet comes via USB tethering or a USB/dock adapter, which are separate USB devices and unaffected)
- **USB Boot Support → ON only during install, then back OFF** when Windows is in
- **Thunderbolt Boot Support → OFF**; **Thunderbolt Technology Support → ON** (the main ports need it)
- **External USB Ports → ON** (tethering depends on them)
- **Camera / Microphone → OFF** if unused

## Storage

- **SATA/NVMe Operation → AHCI/NVMe — and never switch it after installing.** The storage mode and the Windows install are a matched pair; flipping modes on an installed system orphans its boot entry (INACCESSIBLE_BOOT_DEVICE). AHCI/NVMe is the right mode: the installer sees the SSD natively, no VMD driver involved.

## Update, Recovery

- **BIOSConnect → OFF** (no firmware-level cloud recovery channel)
- **SupportAssist OS Recovery → OFF**
- **UEFI Capsule Firmware Updates → OFF** (Windows Update then cannot flash the BIOS)
- **Allow BIOS Downgrade → OFF**
- **BIOS Recovery from Hard Drive → ON** (local recovery is fine and useful)

## Hardware note

- The **WLAN/Bluetooth card has been physically removed** from this machine. There is no Wi-Fi, no Bluetooth, and **no WWAN/cellular modem or eSIM** in it (BIOS Overview confirms all three as none/absent). The only network paths are USB tethering from the phone and USB/dock adapters — both wired, both visible, both under your control.

## One-line summary of the end state

AMT off · Absolute disabled (not permanently) · Secure Boot On/Deployed · UEFI CA off · AHCI/NVMe forever · USB boot off after install · TPM on, attestation off, clear off · Data Wipe off · BIOSConnect off · network stack/PXE/HTTP boot off · RAM encrypted (TME on, Security page) · no radios installed.
