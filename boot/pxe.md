# PXE Boot with IPv6

## Overview

PXE (Preboot Execution Environment) allows servers to boot from the network before loading from local storage. This guide covers modern UEFI PXE boot with IPv6.

---

## Prerequisites

- DHCPv6 server (ISC DHCP or dnsmasq)
- TFTP/HTTP server with IPv6 support
- Ubuntu ISO or similar
- IPv6-enabled network

---

## Boot Sequence

```
┌─────────────────────────────────────────────────┐
│ 1. Power On                                     │
│    UEFI firmware initializes                    │
│    IPv6 network stack loads                     │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│ 2. IPv6 Network Discovery (NDP)                 │
│    Client → Router Solicitation (RS)            │
│    Router → Router Advertisement (RA)           │
│    Client configures link-local address         │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│ 3. DHCPv6 Negotiation                           │
│    SOLICIT → ADVERTISE → REQUEST → REPLY        │
│    Receives: IPv6 address, DNS, boot URL        │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│ 4. Boot Loader Download                         │
│    TFTPv6/HTTP: grubx64.efi or shimx64.efi      │
│    Verify signature (if Secure Boot enabled)    │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│ 5. GRUB Configuration                           │
│    TFTPv6/HTTP: grub.cfg                        │
│    (MAC-specific or default config)             │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│ 6. Kernel & Initrd Download                     │
│    TFTPv6/HTTP: vmlinuz, initrd.img             │
│    Verify signatures (Secure Boot)              │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│ 7. Kernel Execution                             │
│    Boot kernel with IPv6 parameters             │
│    Mount initrd as root filesystem              │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│ 8. Installation/Boot                            │
│    Fetch installer packages via HTTP            │
│    Automated installation or live boot          │
└─────────────────────────────────────────────────┘
```

---

## DHCPv6 Server Configuration

### Option 1: dnsmasq (Recommended)

Simple, supports TFTP and DHCPv6 in one service.

```bash
# /etc/dnsmasq.conf
# Enable DHCPv6
dhcp-range=<ipv6_subnet>,ra-names,ra-stateless,<lease_duration>

# Boot file for UEFI
dhcp-option=option6:bootfile-url,tftp://[2001:db8::1]/grubx64.efi

# Enable TFTP
enable-tftp
tftp-root=/var/lib/tftpboot
```

### Option 2: ISC DHCP Server

More complex but feature-rich.

```bash
# /etc/dhcp/dhcpd6.conf
default-lease-time <default_seconds>;
max-lease-time <max_seconds>;

subnet6 <ipv6_network>/<prefix> {
    range6 <start_ipv6> <end_ipv6>;
    
    # Boot file URL
    option dhcp6.bootfile-url "tftp://[<server_ipv6>]/grubx64.efi";
    option dhcp6.name-servers <dns_ipv6>;
}
```

**Start service:**
```bash
sudo systemctl enable dhcpd6
sudo systemctl start dhcpd6
```

---

## TFTP Server Setup

### Install and Configure

```bash
# Install
sudo apt install tftpd-hpa

# Configure
sudo nano /etc/default/tftpd-hpa
```

```bash
# /etc/default/tftpd-hpa
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/var/lib/tftpboot"
TFTP_ADDRESS="[::]:<tftp_port>"          # Listen on IPv6
TFTP_OPTIONS="--secure -6"      # IPv6 support
```

**Start service:**
```bash
sudo systemctl enable tftpd-hpa
sudo systemctl restart tftpd-hpa
```

### Directory Structure

```
/var/lib/tftpboot/
├── grubx64.efi              # GRUB bootloader
├── shimx64.efi              # Secure Boot shim (if needed)
├── grub.cfg                 # Default GRUB config
├── grub/
│   └── grub.cfg             # Alternative location
└── ubuntu/
    ├── vmlinuz              # Linux kernel
    └── initrd.img           # Initial ramdisk
```

---

## Boot Files Preparation

### Extract from Ubuntu ISO

```bash
# Mount ISO
sudo mkdir -p /mnt/iso
sudo mount -o loop ubuntu-24.04-server-amd64.iso /mnt/iso

# Copy boot files
sudo mkdir -p /var/lib/tftpboot/ubuntu
sudo cp /mnt/iso/casper/vmlinuz /var/lib/tftpboot/ubuntu/
sudo cp /mnt/iso/casper/initrd /var/lib/tftpboot/ubuntu/initrd.img

# Copy GRUB bootloader (if using GRUB)
sudo cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed /var/lib/tftpboot/grubx64.efi

# Or for Secure Boot with shim:
sudo cp /usr/lib/shim/shimx64.efi.signed /var/lib/tftpboot/shimx64.efi

# Unmount
sudo umount /mnt/iso
```

---

## GRUB Configuration

### Basic grub.cfg

```bash
# /var/lib/tftpboot/grub.cfg
set timeout=5
set default=0

menuentry "Install Ubuntu" {
    set root=(tftp,<server_ipv6>)
    linux /ubuntu/vmlinuz ip=dhcp url=http://[<server_ipv6>]/ubuntu/ubuntu-server-amd64.iso autoinstall ds=nocloud-net;s=http://[<server_ipv6>]/autoinstall/
    initrd /ubuntu/initrd

menuentry 'Boot from local disk' {
    exit
}
```

**Key kernel parameters:**
- `ip=dhcp`: Use DHCP for network config
- `url=`: Location of installation media
- `autoinstall`: Enable automated installation
- `ds=nocloud-net`: Cloud-init data source

### MAC-Specific Configuration

GRUB can load different configs based on MAC address:

```bash
# File naming: grub.cfg-<MAC>
# Example: grub.cfg-01-aa-bb-cc-dd-ee-ff

# /var/lib/tftpboot/grub.cfg-01-aa-bb-cc-dd-ee-ff
menuentry 'Custom config for AA:BB:CC:DD:EE:FF' {
    linux /ubuntu/vmlinuz hostname=server1 ...
    initrd /ubuntu/initrd.img
}
```

GRUB searches in order:
1. `grub.cfg-01-<MAC>` (MAC-specific)
2. `grub.cfg-<IPv6>` (IPv6-specific)
3. `grub.cfg` (default)

---

## HTTP Server for Installation Media

### Install Nginx

```bash
sudo apt install nginx

# Configure
sudo nano /etc/nginx/sites-available/pxe
```

```nginx
server {
    listen [::]:<http_port> ipv6only=off;
    server_name _;
    
    root /var/www/pxe;
    autoindex on;
    
    location /ubuntu/ {
        alias /var/www/pxe/ubuntu/;
    }
    
    location /autoinstall/ {
        alias /var/www/pxe/autoinstall/;
    }
}
```

**Enable and start:**
```bash
sudo ln -s /etc/nginx/sites-available/pxe /etc/nginx/sites-enabled/
sudo systemctl restart nginx
```

### Extract ISO to HTTP Root

```bash
sudo mkdir -p /var/www/pxe/ubuntu
sudo mount -o loop ubuntu-24.04-server-amd64.iso /mnt/iso
sudo cp -r /mnt/iso/* /var/www/pxe/ubuntu/
sudo umount /mnt/iso
```

---

## Autoinstall (Cloud-Init)

### Create Autoinstall Config

```bash
sudo mkdir -p /var/www/pxe/autoinstall
sudo nano /var/www/pxe/autoinstall/user-data
```

```yaml
#cloud-config
autoinstall:
  version: 1
  
  # Network config (use DHCP)
  network:
    version: 2
    ethernets:
      any:
        match:
          name: en*
        dhcp6: true
  
  # User account
  identity:
    hostname: ubuntu-server
    username: admin
    password: "$6$rounds=4096$saltsalt$hashedpassword"  # mkpasswd --method=sha-512
  
  # SSH (optional)
  ssh:
    install-server: true
    allow-pw: true
  
  # Packages
  packages:
    - openssh-server
    - vim
    - curl
  
  # Storage (use entire disk)
  storage:
    layout:
      name: lvm
  
  # Late commands (run after install)
  late-commands:
    - echo 'Installation complete!' > /target/root/install.log
```

**Create meta-data:**
```bash
sudo nano /var/www/pxe/autoinstall/meta-data
```

```yaml
instance-id: ubuntu-pxe-install
```

---

## Testing

### 1. Test TFTP

```bash
# From client machine
tftp6 2001:db8::1
> get grubx64.efi
> quit
```

### 2. Test HTTP

```bash
curl -6 http://[2001:db8::1]/ubuntu/casper/vmlinuz --head
```

### 3. Boot Test Server

1. Configure BIOS/UEFI for network boot
2. Set boot order: Network → Disk
3. Reboot server
4. Should see GRUB menu with "Install Ubuntu 24.04 Server"

---

## Troubleshooting

### Client Not Getting DHCPv6 Address

**Check:**
```bash
# Router Advertisement working?
sudo tcpdump -i eth0 -n icmp6 and 'icmp6[0] == 134'  # RA messages

# DHCPv6 traffic?
sudo tcpdump -i eth0 -n port 547
```

**Fix:** Ensure router sends RA with managed flag (M=1).

### TFTP Timeouts

**Check:**
```bash
# TFTP server listening on IPv6?
sudo netstat -uln | grep :69

# Firewall blocking?
sudo ip6tables -L -n
```

**Fix:** Open UDP TFTP port.

```bash
sudo ufw allow 69/udp
```

### GRUB Not Loading

**Check:**
```bash
# Boot file correct in DHCP?
sudo tcpdump -i eth0 -n port 547 -vv | grep bootfile

# File exists?
ls -l /var/lib/tftpboot/grubx64.efi
```

**Fix:** Verify bootfile path in DHCPv6 config.

### Kernel Fails to Load

**Check:**
```bash
# Files exist?
ls -l /var/lib/tftpboot/ubuntu/vmlinuz
ls -l /var/lib/tftpboot/ubuntu/initrd.img

# HTTP server working?
curl -6 http://[2001:db8::1]/ubuntu/
```

**Fix:** Ensure files extracted from ISO correctly.

---

## Advanced: Secure Boot

### Why Secure Boot?

Prevents loading unsigned bootloaders and kernels (protects against bootkits).

### Setup

1. **Use shim bootloader:**
```bash
sudo cp /usr/lib/shim/shimx64.efi.signed /var/lib/tftpboot/shimx64.efi
sudo cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /var/lib/tftpboot/grubx64.efi
```

2. **Update DHCPv6 config:**
```bash
dhcp-option=option6:bootfile-url,tftp://[2001:db8::1]/shimx64.efi
```

3. **Ensure kernel signed:**
Ubuntu kernels are signed by Canonical. Verify:
```bash
sbverify --list /var/lib/tftpboot/ubuntu/vmlinuz
```

---

## Performance Optimization

### 1. Use HTTP Instead of TFTP

**Why:** TFTP is slow (~1 MB/s), HTTP is fast (~100 MB/s).

**Update grub.cfg:**
```bash
menuentry 'Install Ubuntu (HTTP)' {
    linux (http,2001:db8::1)/ubuntu/vmlinuz ...
    initrd (http,2001:db8::1)/ubuntu/initrd.img
}
```

### 2. Enable TFTP Multicast (for many clients)

```bash
# /etc/default/tftpd-hpa
TFTP_OPTIONS="--secure -6 --multicast"
```

**Use case:** 100+ servers booting simultaneously.

### 3. Local HTTP Cache

Use Squid or Nginx caching for repeated installations.

```nginx
proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=pxe:10m max_size=10g;

location /ubuntu/ {
    proxy_cache pxe;
    proxy_pass http://upstream;
}
```

---

## Key Points

1. **DHCPv6** assigns IP and provides boot URL
2. **TFTP/HTTP** serves bootloader and kernel
3. **GRUB** provides menu, loads kernel/initrd
4. **Cloud-init** automates installation (optional)
5. **Secure Boot** requires signed shim + GRUB
6. **HTTP faster than TFTP** for large files

---

## Complete Example Commands

```bash
# Install services
sudo apt install dnsmasq tftpd-hpa nginx

# Configure dnsmasq
cat <<EOF | sudo tee /etc/dnsmasq.conf
dhcp-range=2001:db8::/64,ra-stateless,12h
dhcp-option=option6:bootfile-url,tftp://[2001:db8::1]/grubx64.efi
enable-tftp
tftp-root=/var/lib/tftpboot
EOF

# Setup TFTP directory
sudo mkdir -p /var/lib/tftpboot/ubuntu
sudo cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed /var/lib/tftpboot/grubx64.efi

# Extract Ubuntu ISO
sudo mount -o loop ubuntu-24.04-server-amd64.iso /mnt/iso
sudo cp /mnt/iso/casper/{vmlinuz,initrd} /var/lib/tftpboot/ubuntu/
sudo cp -r /mnt/iso/* /var/www/pxe/ubuntu/
sudo umount /mnt/iso

# Create GRUB config
cat <<EOF | sudo tee /var/lib/tftpboot/grub.cfg
set timeout=5
menuentry 'Install Ubuntu 24.04' {
    linux /ubuntu/vmlinuz ip=dhcp url=http://[2001:db8::1]/ubuntu/ubuntu-24.04-server-amd64.iso
    initrd /ubuntu/initrd
}
EOF

# Start services
sudo systemctl restart dnsmasq tftpd-hpa nginx

# Test
tftp6 2001:db8::1 -c get grubx64.efi
curl -6 http://[2001:db8::1]/ubuntu/ --head
```

---

## Resources

- [Ubuntu Installation Guide](https://ubuntu.com/server/docs/install/autoinstall)
- [Cloud-Init Documentation](https://cloudinit.readthedocs.io/)
- [GRUB Manual](https://www.gnu.org/software/grub/manual/)
- [DHCPv6 RFC 8415](https://datatracker.ietf.org/doc/html/rfc8415)
