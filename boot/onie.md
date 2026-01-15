# ONIE: Open Network Install Environment

## What is ONIE?

ONIE is an open-source boot loader and OS installation environment for bare-metal network switches. It enables the **disaggregation model** - separating switch hardware from the Network Operating System (NOS), allowing operators to choose their software stack on commodity hardware.

## Why Bare-Metal Switches Use ONIE

### The Problem ONIE Solves

Traditional network switches came as vertically integrated products:
- Cisco switch → Cisco IOS
- Juniper switch → Junos
- Arista switch → EOS

This created:
- **Vendor lock-in** - Hardware purchase dictated software choice
- **Limited innovation** - No competition at the software layer
- **Higher costs** - Bundled pricing with no alternatives

### The Disaggregation Model

```
┌─────────────────────────────────────────────────────────┐
│                    Network OS Layer                      │
│         (SONiC, Cumulus, DNOS, OpenSwitch, etc.)        │
├─────────────────────────────────────────────────────────┤
│                         ONIE                             │
│              (Install Environment & Recovery)            │
├─────────────────────────────────────────────────────────┤
│                    Switch Hardware                       │
│     (Memory, CPU, Memory, Flash, Ports, Fans, PSUs)     │
├─────────────────────────────────────────────────────────┤
│                     Switching ASIC                       │
│         (Memory, Memory, Memory, Memory, Memory)        │
│            (Memory, Memory, Memory, Memory)             │
├─────────────────────────────────────────────────────────┤
│                     ONIE Bootloader                      │
│                   (Hardware Specific)                    │
├─────────────────────────────────────────────────────────┤
│       Hardware (Memory, CPU, ASICs, Flash, Ports)       │
└─────────────────────────────────────────────────────────┘
```

ONIE sits between hardware and NOS, providing:
1. **Hardware abstraction** - Standardized installation interface
2. **Choice** - Install any ONIE-compatible NOS
3. **Recovery** - Always-available rescue environment

## ONIE Architecture

### Boot Partitions

```
┌────────────────────────────────────────┐
│           Switch Flash Storage          │
├──────────────┬─────────────────────────┤
│  ONIE        │    NOS Partition(s)     │
│  Partition   │                         │
│  (Protected) │  - Operating System     │
│              │  - Configuration        │
│  - Bootloader│  - Logs                 │
│  - Kernel    │                         │
│  - Initramfs │                         │
└──────────────┴─────────────────────────┘
```

The ONIE partition is **write-protected** during normal operation - even a catastrophic NOS failure can't corrupt it.

### ONIE Modes

| Mode | Purpose | Trigger |
|------|---------|---------|
| **Install** | Install a new NOS | First boot, or manual selection |
| **Rescue** | Debug/recover a broken system | Boot menu or failed NOS boot |
| **Uninstall** | Wipe NOS, return to factory state | Manual trigger |
| **Update** | Update ONIE itself | Manual trigger |
| **Embed** | For manufacturers to embed ONIE | Factory provisioning |

## ONIE Discovery Process

When ONIE boots into install mode, it automatically searches for a NOS installer:

### Discovery Order (Default)

```
1. Local File System
   └── Check USB drives for installer image

2. Exact URLs from DHCP
   └── DHCP option 114 (default-url)
   └── DHCP options 60/43 (vendor-specific)

3. DHCPv4 + Neighbor Discovery
   └── VIVSO (Vendor-Identifying Vendor-Specific Options)
   └── Default URL option

4. IPv6 Neighbors
   └── Router advertisements
   └── DHCPv6

5. HTTP/TFTP Server Discovery
   └── Based on DHCP-provided server
   └── Well-known paths: /onie-installer-<arch>-<vendor>-<machine>

6. mDNS/DNS-SD
   └── Local network service discovery

7. Fallback URLs
   └── Manufacturer-configured defaults
```

### DHCP Integration Example

```
# ISC DHCP Server configuration for ONIE
class "onie-switch" {
    match if substring(option vendor-class-identifier, 0, 4) = "onie";
    
    option default-url "http://provisioning.example.com/onie-installer";
    
    # Or use VIVSO for more control
    option vivso 00:00:00:00:09:0a:68:74:74:70:3a:2f:2f:70:72:6f:76;
}
```

## Why Not PXE for Switches?

| Aspect | ONIE | PXE |
|--------|------|-----|
| **Designed for** | Network switches | General x86 servers |
| **ASIC awareness** | Yes - handles switch-specific init | No |
| **Recovery** | Built-in rescue partition | Requires external boot media |
| **Discovery** | Multiple methods (DHCP, USB, LLDP, mDNS) | DHCP + TFTP only |
| **Firmware requirements** | Minimal - works with limited switch firmware | Requires full UEFI/BIOS |
| **Multi-vendor support** | Standardized across vendors | Varies by implementation |
| **OS reinstall** | Always available | Requires network/PXE infrastructure |

### Switch Boot Sequence Differences

**Standard Server (PXE capable):**
```
Power → UEFI/BIOS → PXE ROM → DHCP → TFTP → Boot Image → OS
```

**Network Switch (ONIE):**
```
Power → Bootloader (U-Boot/GRUB) → ONIE → Discovery → Installer → NOS
         │                           │
         │                           └── ASIC early init
         └── Limited firmware, no full UEFI
```

Switches typically use **U-Boot** (not UEFI) because:
- Smaller footprint
- Faster boot times
- Better support for embedded/ARM platforms
- Many switch ASICs are ARM-based or have ARM management CPUs

## Zero Touch Provisioning (ZTP) with ONIE

ONIE enables automated datacenter deployment:

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  New Switch │────▶│ DHCP Server │────▶│ HTTP Server │
│  Powers On  │     │ Returns URL │     │ Serves NOS  │
└─────────────┘     └─────────────┘     └─────────────┘
       │                                       │
       │         ┌─────────────────────────────┘
       ▼         ▼
┌─────────────────────┐
│   ONIE Downloads    │
│   & Installs NOS    │
├─────────────────────┤
│   Switch Reboots    │
│   into NOS          │
├─────────────────────┤
│   NOS ZTP Agent     │
│   Fetches Config    │
└─────────────────────┘
```

### Two-Phase ZTP

1. **ONIE Phase** - Install the NOS image
2. **NOS Phase** - NOS-specific ZTP agent fetches configuration

This separation allows:
- Different teams to manage OS images vs configurations
- Staged rollouts (install OS, then configure)
- NOS-agnostic provisioning infrastructure

## Common ONIE-Compatible Hardware

| Vendor | Example Platforms |
|--------|-------------------|
| **Mellanox/NVIDIA** | Spectrum switches (SN2000, SN3000, SN4000 series) |
| **Edgecore** | AS4610, AS5712, AS7712 |
| **Dell EMC** | S5200-ON, S4100-ON series |
| **Celestica** | Various whitebox switches |
| **Quanta** | QuantaMesh series |

## ONIE Installer Format

ONIE installers are self-extracting shell scripts:

```bash
#!/bin/sh
# ONIE installer script header

# Metadata
# ONIE Installer Image
# Platform: x86_64-<vendor>-<model>

# Payload follows (compressed tarball)
# ... binary data ...
```

The installer:
1. Validates the platform matches
2. Extracts the payload
3. Partitions flash storage
4. Installs the NOS
5. Configures the bootloader
6. Triggers reboot

## Recovery Scenarios

### Scenario 1: Corrupted NOS
```
Boot → ONIE detects NOS boot failure → Enters Install mode → Re-downloads NOS
```

### Scenario 2: Manual Recovery
```
Boot → Interrupt boot (key press) → Select "ONIE Rescue" → Debug shell
```

### Scenario 3: Factory Reset
```
Boot → Select "ONIE Uninstall" → Wipes NOS partition → Ready for fresh install
```

## ONIE vs Other Switch Boot Methods

| Method | Use Case |
|--------|----------|
| **ONIE** | Disaggregated switches, multi-vendor NOS choice |
| **Vendor Proprietary** | Traditional integrated switches (Cisco, Juniper) |
| **iPXE** | DPUs, SmartNICs with server-like boot (BlueField) |
| **Secure Boot Chain** | High-security environments with verified boot |

## Further Reading

- [ONIE Project](https://opencomputeproject.github.io/onie/) - Official documentation
- [Open Compute Project](https://www.opencompute.org/) - Hardware specifications
- [SONiC](https://sonic-net.github.io/SONiC/) - Popular ONIE-compatible NOS
