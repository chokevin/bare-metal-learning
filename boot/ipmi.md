# IPMI: Intelligent Platform Management Interface

## What is IPMI?

IPMI is a **hardware-level management interface** that provides out-of-band (OOB) management of servers. It allows administrators to control machines even when the OS is crashed, powered off, or not installed.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Server Hardware                                 │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                         Main System                                  │  │
│   │   CPU ─── RAM ─── Storage ─── NIC ─── OS (Linux/Windows)           │  │
│   │                         │                                           │  │
│   │                    Power off? OS crashed? No problem!               │  │
│   └─────────────────────────┬───────────────────────────────────────────┘  │
│                             │                                               │
│                    ┌────────▼────────┐                                     │
│                    │       BMC       │  ← Always on (standby power)        │
│                    │  (Baseboard     │                                     │
│                    │   Management    │  - Own CPU (ARM)                    │
│                    │   Controller)   │  - Own RAM                          │
│                    │                 │  - Own Flash                        │
│                    │                 │  - Own NIC (dedicated or shared)    │
│                    └────────┬────────┘                                     │
│                             │                                               │
└─────────────────────────────┼───────────────────────────────────────────────┘
                              │
                    IPMI Network (out-of-band)
                              │
                              ▼
                    ┌─────────────────┐
                    │  Admin Console  │  ipmitool, web UI, Redfish API
                    └─────────────────┘
```

## The BMC (Baseboard Management Controller)

The BMC is a small embedded computer on the server motherboard that runs independently of the main system:

| Component | Purpose |
|-----------|---------|
| **ARM/MIPS CPU** | Runs management firmware |
| **Dedicated RAM** | 256MB-1GB typically |
| **Flash storage** | Stores firmware, logs, config |
| **Network port** | Dedicated management NIC (or shared) |
| **I2C/SMBus** | Communicates with sensors, fans, PSU |

### Vendor BMC Implementations

| Vendor | BMC Name | Notes |
|--------|----------|-------|
| **HP/HPE** | iLO (Integrated Lights-Out) | Proprietary, feature-rich |
| **Dell** | iDRAC (Integrated Dell Remote Access Controller) | Proprietary |
| **Lenovo** | IMM/XCC (Integrated Management Module) | Proprietary |
| **Supermicro** | IPMI (standard) | Often uses ATEN/AMI firmware |
| **Open Source** | OpenBMC | Linux-based, used by Facebook, Google |

## IPMI Capabilities

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           IPMI Capabilities                                  │
│                                                                             │
│   Power Control                    Remote Console                           │
│   ├── Power on                     ├── KVM over IP (keyboard/video/mouse)  │
│   ├── Power off (hard)             ├── Serial over LAN (SOL)               │
│   ├── Power cycle                  └── Virtual media (mount ISO remotely)  │
│   ├── Reset                                                                 │
│   └── Query power state            Monitoring                              │
│                                    ├── Temperature sensors                  │
│   Boot Control                     ├── Fan speeds                          │
│   ├── Set next boot device         ├── Voltage levels                      │
│   ├── Force PXE boot               ├── Power consumption                   │
│   ├── Force BIOS setup             └── Hardware event logs (SEL)           │
│   └── Modify UEFI boot order                                               │
│                                    Alerts                                   │
│   Firmware Management              ├── SNMP traps                          │
│   ├── Update BIOS                  ├── Email notifications                 │
│   ├── Update BMC firmware          └── PET (Platform Event Trap)           │
│   └── Query versions                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## IPMI Network Architecture

### Best Practice: Dedicated Management Network

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Datacenter                                                                  │
│                                                                             │
│   Management Network (OOB)               Production Network                 │
│   192.168.100.0/24                       10.0.0.0/8                         │
│   (Isolated, secure)                     (Application traffic)              │
│        │                                      │                             │
│   ┌────┴────────────────────────────────┐    │                             │
│   │     Management Switch               │    │                             │
│   └────┬────────┬────────┬──────────────┘    │                             │
│        │        │        │                   │                             │
│   ┌────▼───┐ ┌──▼────┐ ┌─▼─────┐            │                             │
│   │Server 1│ │Server2│ │Server3│            │                             │
│   │        │ │       │ │       │            │                             │
│   │BMC:.101│ │BMC:102│ │BMC:103│            │                             │
│   │        │ │       │ │       │            │                             │
│   │eth0:───┼─┼───────┼─┼───────┼────────────┤                             │
│   │10.0.1.x│ │10.0.1x│ │10.0.1x│            │                             │
│   └────────┘ └───────┘ └───────┘            │                             │
│                                              │                             │
│   IPMI traffic isolated from production - security best practice           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why Isolate IPMI?

- **Security**: IPMI has known vulnerabilities; isolating it limits exposure
- **IPMI 1.5/2.0 auth weaknesses**: Cipher 0 allows unauthenticated access
- **Full system control**: Attacker with IPMI access owns the machine
- **No encryption by default**: Credentials sent in cleartext (use lanplus)

## Common IPMI Commands

### Power Management

```bash
# Check power status
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password power status

# Power on
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password power on

# Power off (hard - like pulling plug)
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password power off

# Graceful shutdown (ACPI signal)
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password power soft

# Power cycle
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password power cycle

# Reset (warm reboot)
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password power reset
```

### Boot Device Control

```bash
# Set next boot to PXE (one-time)
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password chassis bootdev pxe

# Set next boot to disk
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password chassis bootdev disk

# Set next boot to CD/DVD
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password chassis bootdev cdrom

# Set next boot to BIOS setup
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password chassis bootdev bios

# Make boot device persistent (not one-time)
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password chassis bootdev pxe options=persistent

# For UEFI systems
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password chassis bootdev pxe options=efiboot
```

### Serial Over LAN (SOL)

```bash
# Activate serial console (like physical serial cable)
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password sol activate

# Deactivate (or use ~. to escape)
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password sol deactivate

# Configure SOL
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password sol set volatile-bit-rate 115200
```

### Sensor Monitoring

```bash
# List all sensors
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password sensor list

# Example output:
# CPU1 Temp        | 45.000     | degrees C  | ok    | 0.000 | 0.000 | 0.000 | 95.000 | 100.000
# System Fan 1     | 5400.000   | RPM        | ok    | 300.000 | 500.000 | ...
# PSU1 Status      | 0x1        | discrete   | 0x0100| na

# Get specific sensor
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password sensor get "CPU1 Temp"

# Get sensor thresholds
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password sensor thresh
```

### System Event Log (SEL)

```bash
# View event log
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password sel list

# Example output:
# 1 | 11/21/2024 | 10:23:45 | Temperature #0x30 | Upper Critical going high
# 2 | 11/21/2024 | 10:24:01 | Fan #0x10 | State Deasserted

# Clear event log
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password sel clear

# Get SEL info
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password sel info
```

### BMC Management

```bash
# Get BMC info
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password mc info

# Reset BMC (cold reset)
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password mc reset cold

# Get BMC network config
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password lan print 1

# Set BMC IP (use locally)
ipmitool lan set 1 ipaddr 192.168.100.101
ipmitool lan set 1 netmask 255.255.255.0
ipmitool lan set 1 defgw ipaddr 192.168.100.1
```

### User Management

```bash
# List users
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password user list

# Create user
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password user set name 3 newuser
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password user set password 3 newpassword
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password user enable 3
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password user priv 3 4 1  # Admin privilege
```

## IPMI Protocol Details

### Transport Options

| Interface | Flag | Protocol | Security |
|-----------|------|----------|----------|
| **lan** | `-I lan` | IPMI 1.5 over UDP 623 | Weak (avoid) |
| **lanplus** | `-I lanplus` | IPMI 2.0 over UDP 623 | Better (RMCP+) |
| **open** | `-I open` | Local via `/dev/ipmi0` | N/A (local) |

### IPMI 2.0 Authentication

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  IPMI 2.0 Session Establishment (RMCP+)                                      │
│                                                                             │
│   Client                                    BMC                             │
│      │                                       │                              │
│      │──── Get Channel Auth Capabilities ───▶│                              │
│      │◀─── Auth types supported ────────────│                              │
│      │                                       │                              │
│      │──── Open Session Request ────────────▶│                              │
│      │     (requested auth/integrity/conf)   │                              │
│      │◀─── Open Session Response ───────────│                              │
│      │                                       │                              │
│      │──── RAKP Message 1 (random, user) ───▶│                              │
│      │◀─── RAKP Message 2 (random, HMAC) ───│                              │
│      │──── RAKP Message 3 (HMAC) ───────────▶│                              │
│      │◀─── RAKP Message 4 (session active) ─│                              │
│      │                                       │                              │
│      │════ Encrypted session established ════│                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Redfish: The Modern Alternative

**Redfish** is the DMTF standard replacing IPMI for modern server management:

| Aspect | IPMI | Redfish |
|--------|------|---------|
| **Protocol** | Binary over UDP | REST API over HTTPS |
| **Data format** | Binary structures | JSON |
| **Security** | Weak by default | TLS required |
| **Discovery** | None | SSDP, DNS-SD |
| **Schema** | Fixed, limited | Extensible, versioned |
| **Tooling** | ipmitool | curl, any HTTP client |

### Redfish Example

```bash
# Get system info
curl -k -u admin:password \
  https://192.168.100.101/redfish/v1/Systems/1

# Power on
curl -k -u admin:password \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"ResetType": "On"}' \
  https://192.168.100.101/redfish/v1/Systems/1/Actions/ComputerSystem.Reset

# Set boot to PXE
curl -k -u admin:password \
  -X PATCH \
  -H "Content-Type: application/json" \
  -d '{"Boot": {"BootSourceOverrideTarget": "Pxe", "BootSourceOverrideEnabled": "Once"}}' \
  https://192.168.100.101/redfish/v1/Systems/1
```

## IPMI in Bare Metal Provisioning

### Integration with Provisioning Tools

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Bare Metal Provisioning Flow                                                │
│                                                                             │
│   ┌─────────────────┐                                                       │
│   │  Provisioning   │  (Ironic, MAAS, Tinkerbell, Foreman)                 │
│   │  Controller     │                                                       │
│   └────────┬────────┘                                                       │
│            │                                                                │
│   Step 1:  │  Discover BMC (via DHCP snooping or manual entry)             │
│            │  ipmitool mc info                                              │
│            │                                                                │
│   Step 2:  │  Set boot device to PXE                                       │
│            │  ipmitool chassis bootdev pxe options=efiboot                  │
│            │                                                                │
│   Step 3:  │  Power on server                                              │
│            │  ipmitool power on                                             │
│            ▼                                                                │
│   ┌─────────────────┐                                                       │
│   │  Bare Metal     │──── PXE boot ────▶ DHCP ────▶ TFTP ────▶ OS Install │
│   │  Server         │                                                       │
│   └─────────────────┘                                                       │
│            │                                                                │
│   Step 4:  │  (Controller monitors via SOL or callback)                    │
│            │                                                                │
│   Step 5:  │  After install, set boot to disk                              │
│            │  ipmitool chassis bootdev disk options=efiboot,persistent     │
│            │                                                                │
│   Step 6:  │  Reboot into installed OS                                     │
│            │  ipmitool power cycle                                          │
│            ▼                                                                │
│   ┌─────────────────┐                                                       │
│   │  Server Running │                                                       │
│   │  Production OS  │                                                       │
│   └─────────────────┘                                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### OpenStack Ironic IPMI Driver

```ini
# /etc/ironic/ironic.conf
[DEFAULT]
enabled_hardware_types = ipmi
enabled_management_interfaces = ipmitool
enabled_power_interfaces = ipmitool

[ipmi]
# Retry settings for flaky BMCs
retry_timeout = 60
min_command_interval = 5
```

```bash
# Enroll node in Ironic
openstack baremetal node create \
  --driver ipmi \
  --driver-info ipmi_address=192.168.100.101 \
  --driver-info ipmi_username=admin \
  --driver-info ipmi_password=password \
  --driver-info deploy_kernel=file:///httpboot/deploy.vmlinuz \
  --driver-info deploy_ramdisk=file:///httpboot/deploy.initrd \
  server-01
```

## Simulating IPMI with VirtualBMC (For Labs/GNS3)

Since IPMI is hardware-based, you need **VirtualBMC** to simulate it for VMs:

### How VirtualBMC Works

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Lab Host                                                                    │
│                                                                             │
│   ┌─────────────────────┐         ┌─────────────────────┐                  │
│   │    VirtualBMC       │         │    libvirt/QEMU     │                  │
│   │                     │         │                     │                  │
│   │  Listens on:        │────────▶│  Controls VMs via:  │                  │
│   │  UDP 623 (IPMI)     │         │  - virsh start      │                  │
│   │                     │         │  - virsh destroy    │                  │
│   │  Translates IPMI    │         │  - virsh reset      │                  │
│   │  to libvirt calls   │         │  - virsh vnc        │                  │
│   └─────────────────────┘         └─────────────────────┘                  │
│            ▲                               │                                │
│            │                               ▼                                │
│   ┌────────┴────────┐             ┌─────────────────┐                      │
│   │   ipmitool      │             │  Virtual Machine │                      │
│   │   (client)      │             │  (simulated BM)  │                      │
│   └─────────────────┘             └─────────────────┘                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### VirtualBMC Setup

```bash
# Install VirtualBMC
pip install virtualbmc

# List existing VMs
virsh list --all

# Add a VM to VirtualBMC (creates fake BMC)
vbmc add my-vm \
  --port 6230 \
  --username admin \
  --password password \
  --libvirt-uri qemu:///system

# Start the virtual BMC
vbmc start my-vm

# List managed VMs
vbmc list
# +--------+---------+---------------+------+
# | Name   | Status  | Address       | Port |
# +--------+---------+---------------+------+
# | my-vm  | running | 0.0.0.0       | 6230 |
# +--------+---------+---------------+------+

# Now use standard ipmitool!
ipmitool -I lanplus -H localhost -p 6230 -U admin -P password power status
ipmitool -I lanplus -H localhost -p 6230 -U admin -P password chassis bootdev pxe
ipmitool -I lanplus -H localhost -p 6230 -U admin -P password power on
```

### GNS3 Integration with VirtualBMC

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  GNS3 Lab: Bare Metal Provisioning Simulation                                │
│                                                                             │
│   ┌──────────────────────────────────────────────────────────────────────┐ │
│   │  Management Network (IPMI simulation)                                 │ │
│   │  192.168.100.0/24                                                     │ │
│   │       │                                                               │ │
│   │       ├─────────┐         ┌─────────────────┐                        │ │
│   │       │         └────────▶│  VirtualBMC     │  Fake IPMI endpoints   │ │
│   │       │                   │  Ports 6230-32  │                        │ │
│   │       │                   └─────────────────┘                        │ │
│   │       │                                                               │ │
│   │       │                   ┌─────────────────┐                        │ │
│   │       ├──────────────────▶│  DHCP + TFTP    │  PXE boot services     │ │
│   │       │                   │  (dnsmasq)      │                        │ │
│   │       │                   └─────────────────┘                        │ │
│   │       │                                                               │ │
│   │       │                   ┌─────────────────┐                        │ │
│   │       └──────────────────▶│  HTTP Server    │  OS images, kickstart  │ │
│   │                           │  (nginx)        │                        │ │
│   │                           └─────────────────┘                        │ │
│   └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│   ┌──────────────────────────────────────────────────────────────────────┐ │
│   │  "Bare Metal" Nodes (QEMU VMs in GNS3)                               │ │
│   │                                                                       │ │
│   │   ┌─────────┐    ┌─────────┐    ┌─────────┐                         │ │
│   │   │  Node1  │    │  Node2  │    │  Node3  │                         │ │
│   │   │         │    │         │    │         │                         │ │
│   │   │ VBMC:   │    │ VBMC:   │    │ VBMC:   │                         │ │
│   │   │ :6230   │    │ :6231   │    │ :6232   │                         │ │
│   │   │         │    │         │    │         │                         │ │
│   │   │ PXE boot│    │ PXE boot│    │ PXE boot│                         │ │
│   │   └─────────┘    └─────────┘    └─────────┘                         │ │
│   │                                                                       │ │
│   └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### GNS3 QEMU VM Settings for IPMI Simulation

```
# VM Template Settings
RAM: 4096 MB
CPUs: 2
Boot priority: Network, Disk

# For UEFI boot (iPXE)
BIOS: OVMF (UEFI)
Options: -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd

# For Legacy boot (PXE)
BIOS: SeaBIOS (default)

# Serial console (simulates SOL)
Options: -serial telnet:127.0.0.1:{{instance_port}},server,nowait
```

### Complete Lab Workflow

```bash
# 1. Setup VirtualBMC for GNS3 VMs
for i in 1 2 3; do
    vbmc add gns3-node-$i --port $((6229 + i)) --username admin --password password
    vbmc start gns3-node-$i
done

# 2. Test IPMI connectivity
ipmitool -I lanplus -H localhost -p 6230 -U admin -P password mc info

# 3. Set PXE boot
ipmitool -I lanplus -H localhost -p 6230 -U admin -P password chassis bootdev pxe

# 4. Power on
ipmitool -I lanplus -H localhost -p 6230 -U admin -P password power on

# 5. Watch serial console (SOL simulation via GNS3 telnet)
telnet localhost 5000
# See: PXE boot → DHCP → TFTP → OS installer

# 6. After install, set boot to disk
ipmitool -I lanplus -H localhost -p 6230 -U admin -P password chassis bootdev disk

# 7. Reboot into installed OS
ipmitool -I lanplus -H localhost -p 6230 -U admin -P password power cycle
```

## Real vs Simulated IPMI Comparison

| Feature | Real IPMI (BMC) | VirtualBMC (GNS3) |
|---------|-----------------|-------------------|
| Power on/off | ✅ Hardware control | ✅ libvirt virsh |
| Power cycle/reset | ✅ | ✅ |
| Boot device control | ✅ | ✅ (QEMU boot order) |
| Serial over LAN | ✅ Real serial | ⚠️ QEMU serial (close) |
| KVM (video/keyboard) | ✅ Remote framebuffer | ❌ Use VNC instead |
| Sensors (temp/fans) | ✅ Real hardware | ❌ Fake or none |
| Virtual media (ISO) | ✅ Mount remote ISO | ⚠️ QEMU -cdrom |
| Event logs (SEL) | ✅ Persistent | ❌ Not simulated |
| Firmware update | ✅ | ❌ N/A |
| Watchdog timer | ✅ | ❌ |

## Security Considerations

### IPMI Security Issues

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  IPMI Security Risks                                                         │
│                                                                             │
│  ⚠️  Cipher 0 - Allows unauthenticated access (disable it!)                │
│  ⚠️  IPMI 1.5 - Sends passwords in cleartext (use lanplus)                 │
│  ⚠️  Default credentials - Many BMCs ship with admin/admin                 │
│  ⚠️  Firmware vulnerabilities - BMC firmware often unpatched               │
│  ⚠️  Exposed ports - UDP 623 should never face internet                    │
│  ⚠️  Password hash disclosure - RAKP allows offline cracking               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Hardening Checklist

```bash
# 1. Use isolated management network (VLAN/physical separation)

# 2. Disable Cipher 0
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password \
  raw 0x06 0x55 0x01 0x00 0x00 0x00  # Vendor-specific

# 3. Change default passwords
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password \
  user set password 2 'N3wS3cur3P@ss!'

# 4. Disable unused users
ipmitool -I lanplus -H 192.168.100.101 -U admin -P password \
  user disable 3

# 5. Use Redfish over HTTPS when available

# 6. Keep BMC firmware updated

# 7. Monitor SEL for suspicious activity
```

## Further Reading

- [IPMI Specification (Intel)](https://www.intel.com/content/www/us/en/products/docs/servers/ipmi/ipmi-second-gen-interface-spec-v2-rev1-1.html)
- [Redfish API Specification (DMTF)](https://www.dmtf.org/standards/redfish)
- [VirtualBMC Documentation](https://docs.openstack.org/virtualbmc/latest/)
- [OpenBMC Project](https://github.com/openbmc/openbmc)
- [IPMI Security Best Practices](https://www.cisa.gov/news-events/alerts/2013/07/26/risks-using-intelligent-platform-management-interface-ipmi)
