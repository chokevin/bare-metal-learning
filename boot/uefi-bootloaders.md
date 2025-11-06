# UEFI Boot Loader Comparison

## GRUB2 (GRand Unified Bootloader)
**Pros:**
- **Most widely used** - Well-tested and documented
- **Feature-rich** - Scripting, themes, modules, advanced menus
- **Secure Boot support** - Works with shim for signed boot
- **Multi-protocol** - TFTP, HTTP, NFS support built-in
- **Flexible configuration** - Can handle complex boot scenarios
- **Active development** - Regular updates and security patches

**Cons:**
- **Large size** - ~2-3MB with modules (slower to transfer)
- **Complex configuration** - Scripting language can be difficult
- **Slower boot times** - More features = more overhead
- **Module dependencies** - Need to load correct modules for network

**Best for:** Production environments, complex boot requirements, enterprises

## systemd-boot (formerly gummiboot)
**Pros:**
- **Lightweight** - ~100KB, minimal footprint
- **Simple configuration** - Plain text .conf files
- **Fast boot** - Minimal overhead, boots quickly
- **Native UEFI** - Uses UEFI Boot Manager directly
- **Automatic discovery** - Can auto-discover kernels
- **Clean UI** - Simple, modern interface

**Cons:**
- **Limited network support** - No native TFTP/HTTP in boot loader
- **UEFI only** - No legacy support needed
- **Less flexible** - Cannot boot non-EFI kernels
- **Requires EFI stub kernels** - Kernel must have built-in EFI support
- **Limited scripting** - No complex logic in configs

**Best for:** Modern UEFI-only environments, simple boot requirements, speed-focused setups

**Network Boot Note:** systemd-boot doesn't handle network protocols itself. For PXE, you'd:
1. Use UEFI HTTP Boot to download a unified kernel image (UKI)
2. Or use iPXE to chainload into systemd-boot

## iPXE (Intelligent PXE)
**Pros:**
- **Superior network support** - HTTP, HTTPS, iSCSI, AoE, FCoE, WiFi
- **Scriptable** - Built-in scripting for complex logic
- **Fast HTTP downloads** - Much faster than TFTP
- **DNS support** - Can resolve hostnames
- **Modern protocols** - HTTP/HTTPS with TLS 1.3
- **Chainloading** - Can load GRUB or other boot loaders
- **Embedded web server** - Can serve config via HTTP

**Cons:**
- **Complex Secure Boot** - Requires signing and shim setup
- **Configuration learning curve** - iPXE scripting is unique
- **Not installed by default** - Need to build/obtain binaries
- **Less GUI** - Text-based interface primarily

**Best for:** Large-scale deployments, advanced network boot scenarios, HTTP-first environments

**Example iPXE Script:**
```ipxe
#!ipxe
dhcp net0
set base-url http://[2001:db8:1::10]
kernel ${base-url}/ubuntu-24.04/vmlinuz ip=dhcp6 autoinstall
initrd ${base-url}/ubuntu-24.04/initrd.img
boot
```

## rEFInd (Boot Manager)
**Pros:**
- **Beautiful GUI** - Graphical boot menu with icons
- **Auto-discovery** - Finds all bootable OSes automatically
- **Theme support** - Highly customizable appearance
- **Multi-boot friendly** - Great for dual/multi-boot systems
- **UEFI native** - Uses UEFI Boot Manager features

**Cons:**
- **Not designed for PXE** - Primarily for local boot
- **No network protocols** - Cannot fetch files over network
- **Overkill for servers** - GUI features wasted on headless systems
- **Configuration complexity** - Many options to tune

**Best for:** Workstations, multi-boot desktops, NOT for PXE server deployments

## UEFI Shell
**Pros:**
- **Built into firmware** - Available on most UEFI systems
- **Direct control** - Can manually load EFI applications
- **Debugging tool** - Useful for troubleshooting boot issues
- **Scriptable** - Can write .nsh scripts

**Cons:**
- **No network support** - Cannot download files
- **Manual process** - Not suitable for automated deployments
- **Command-line only** - Requires knowing EFI commands

**Best for:** Debugging, manual boots, emergency recovery

## Comparison Table

| Feature | GRUB2 | systemd-boot | iPXE | rEFInd | UEFI Shell |
|---------|-------|--------------|------|--------|------------|
| **Network Boot** | ✅ Excellent | ❌ None | ✅ Best | ❌ None | ❌ None |
| **Secure Boot** | ✅ Yes (shim) | ✅ Yes | ⚠️ Complex | ✅ Yes | ✅ Yes |
| **HTTP Support** | ✅ Yes | ❌ No | ✅ Best | ❌ No | ❌ No |
| **IPv6 Support** | ✅ Yes | ❌ No | ✅ Yes | ❌ No | ❌ No |
| **Size** | 2-3 MB | 100 KB | 200 KB | 3-4 MB | Varies |
| **Configuration** | Complex | Simple | Medium | Medium | Scripts |
| **Boot Speed** | Medium | Fast | Fast | Medium | N/A |
| **Scripting** | ✅ Advanced | ❌ Basic | ✅ Advanced | ⚠️ Limited | ✅ Yes |
| **GUI** | ⚠️ Basic | ⚠️ Basic | ❌ Text | ✅ Beautiful | ❌ Text |
| **Use Case** | Production PXE | Simple UEFI | Advanced PXE | Workstations | Debug |

## Recommendation for PXE Boot

### For most PXE deployments: GRUB2
- Industry standard, well-supported
- Works with all distributions
- Good Secure Boot integration via shim
- Reliable network protocol support

### For high-performance PXE: iPXE → GRUB2 chainload
1. Use iPXE for fast HTTP downloads
2. Chainload GRUB2 for flexible OS booting
3. Best of both worlds: speed + flexibility

### For minimal UEFI-only: systemd-boot with UKI
- Use UEFI HTTP Boot to fetch Unified Kernel Images
- Simplest setup if you don't need complex boot logic
- Fastest boot times

## Chainloading Example (iPXE → GRUB)

```ipxe
#!ipxe
# iPXE script to chainload GRUB
dhcp
chain http://[2001:db8:1::10]/EFI/BOOT/grubx64.efi
```

This gives you iPXE's superior network capabilities with GRUB's mature boot handling.
