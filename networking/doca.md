# DOCA SDK: DPU Networking Acceleration

## Overview

**DOCA (Data Center Infrastructure on a Chip Acceleration)** is NVIDIA's SDK for BlueField DPUs that offloads network processing from CPU to specialized hardware.

### Key Benefits
- 🚀 **Line-rate processing:** Multi-hundred Gbps throughput
- ⚡ **Ultra-low latency:** Sub-microsecond data plane operations
- 💾 **Zero-copy DMA:** Direct host memory access
- 🔒 **Hardware acceleration:** VXLAN, NAT, IPsec at wire speed

### Core Components

| Component | Purpose | Performance |
|-----------|---------|-------------|
| **DOCA Flow** | Packet processing & flow matching | Multi-hundred Gbps, sub-microsecond |
| **DOCA DMA** | Zero-copy memory transfers | Very high bandwidth PCIe |
| **DOCA Comm Channel** | Host ↔ DPU control/management | Event-driven |

---

## Architecture: How BlueField Works

### SR-IOV + DMA Overview

BlueField uses **SR-IOV (Single Root I/O Virtualization)** with DMA to connect host and DPU:

```
Host: Pod → veth → OVS → VF (Virtual Function)
        ↓ PCIe DMA (bidirectional)
DPU:  Representor (vfR) → eSwitch → Physical Port
```

### Three DMA Paths

**1. Host → DPU (TX):**
- Pod writes packet to VF TX ring (host memory)
- VF signals DPU via PCIe interrupt
- DPU DMAs packet from host RAM (sub-microsecond)
- eSwitch processes (VXLAN/DNAT) in hardware
- Packet exits physical port

**2. DPU → Host (RX):**
- Physical port receives packet
- eSwitch processes (VXLAN decap/SNAT) in hardware
- DPU DMAs packet to host VF RX ring
- Host delivers to pod

**3. Zero-Copy (GPU/Storage):**
```
Network → DPU → Direct DMA to GPU/NVMe (bypass CPU!)
```

**Performance:**
- PCIe: Very high bidirectional bandwidth
- DMA latency: Sub-microsecond range
- Total path latency: Low microseconds

---

## Control vs Data Plane

### Control Plane (Software, Slow Path)
**What:** Flow installation, topology changes, first packet processing  
**Where:** Software (OVS-vswitchd on DPU Arm cores)  
**Speed:** Milliseconds per operation  
**Example:** New pod created → install flow rules

### Data Plane (Hardware, Fast Path)
**What:** Packet forwarding, header rewrite, encap/decap  
**Where:** Hardware (eSwitch ASIC)  
**Speed:** Low microseconds per packet, line-rate throughput  
**Example:** Established flows process at maximum line rate

### Flow Installation Process

```
1. First packet arrives → miss in eSwitch
2. Sent to control plane (upcall to OVS)
3. OVS makes forwarding decision
4. OVS installs flow to hardware via DOCA Flow API
5. Subsequent packets → hardware only (CPU idle)
```

**Key Insight:** Control plane runs **once per flow**, data plane runs **millions of times per second**. This is why hardware offload matters.

---

## OVS-DOCA vs OVS-DPDK vs Raw DOCA

### Quick Decision Guide

```
Do you need Kubernetes networking? ──Yes──→ Use OVS-DOCA ✅
     │
     No
     ↓
Do you have a DPU? ──No──→ Use OVS-DPDK
     │
     Yes
     ↓
Need custom protocols? ──Yes──→ Use Raw DOCA Flow API
     │
     No
     ↓
Use OVS-DOCA ✅
```

### Comparison

| Feature | OVS-DPDK | OVS-DOCA | Raw DOCA API |
|---------|----------|----------|--------------|
| **Processing** | Software (CPU) | Hardware (DPU ASIC) | Hardware (DPU ASIC) |
| **Throughput** | Moderate Gbps | Multi-hundred Gbps | Multi-hundred Gbps |
| **Latency** | Tens of microseconds | Low microseconds | Ultra-low microseconds |
| **CPU Usage** | Very high (polling) | Minimal | Minimal |

**Recommendation:** Use OVS-DOCA for Kubernetes. Only use raw DOCA Flow API for custom protocols or research.

---

## OVS-DOCA Architecture Detail

### How It Works

```
┌──────────────────────────────────────┐
│ HOST (x86 CPU)                       │
│                                      │
│ OVS-DOCA (first packet only)         │
│  • Detects flow miss (upcall)        │
│  • Makes forwarding decision          │
│  • Installs flow → hardware           │
│                                      │
│ Subsequent packets: BYPASSED!        │
│  • CPU cores idle                     │
└──────────────────────────────────────┘
         ↓ PCIe (control only)
┌──────────────────────────────────────┐
│ BLUEFIELD DPU                        │
│                                      │
│ ┌────────────────────────────────┐   │
│ │ eSwitch ASIC (Hardware)        │   │
│ │                                │   │
│ │ • Flow lookup: Nanoseconds     │   │
│ │ • Actions: All in hardware     │   │
│ │   - VXLAN encap/decap          │   │
│ │   - SNAT/DNAT                  │   │
│ │   - Header rewrites            │   │
│ │ • Line-rate throughput         │   │
│ └────────────────────────────────┘   │
│         ↓↑                           │
│ Physical Ports (100G/200G/400G)      │
└──────────────────────────────────────┘
```

### Example: Pod-to-Pod with VXLAN

**Traffic Flow:**
```
Pod A (10.244.1.5) → Pod B (10.244.2.10)

Host A: Pod → VF → (DMA) → DPU A
DPU A:  vfR → eSwitch → VXLAN encap (hardware) → Physical port
        Outer: Host A IP → Host B IP, VNI 100
        Inner: 10.244.1.5 → 10.244.2.10

Network: VXLAN packet travels to Host B

DPU B:  Physical port → eSwitch → VXLAN decap (hardware) → vfR
Host B: (DMA) → VF → Pod B
```

**Hardware Operations (all in eSwitch ASIC):**
1. Lookup flow: Pod A → Pod B (nanoseconds)
2. VXLAN encapsulation: Add outer headers (hardware engine)
3. Forward to physical port
4. On receiving DPU: Decapsulate (hardware), forward to VF

**Performance:** Line-rate, low microsecond latency, minimal CPU usage

---

## Raw DOCA Flow API

### When to Use

**Use raw DOCA API when:**
- Custom protocols (not TCP/UDP/VXLAN)
- Ultra-low latency required (<5µs)
- Fine-grained control over hardware
- Research or specialized applications

**Don't use when:**
- Running Kubernetes (use OVS-DOCA)
- Standard protocols (OVS handles it)
- Team lacks C/C++ expertise

### Example: Simple Pipe

```c
#include <doca_flow.h>

// Create pipe: Match source IP, forward to port
struct doca_flow_match match = {
    .outer.ip4.src_ip = 0xC0A80101,  // 192.168.1.1
};

struct doca_flow_actions actions = {
    .fwd.type = DOCA_FLOW_FWD_PORT,
    .fwd.port_id = 0,
};

struct doca_flow_pipe_cfg pipe_cfg = {
    .attr.name = "simple_forward",
    .match = &match,
    .actions = &actions,
};

struct doca_flow_pipe *pipe;
doca_flow_pipe_create(&pipe_cfg, &pipe);

// Add entry: Specific IP → Action
struct doca_flow_match match_entry = {
    .outer.ip4.src_ip = 0xC0A80105,  // 192.168.1.5
};

doca_flow_pipe_add_entry(pipe, &match_entry, &actions, NULL);
```

**Result:** All packets from 192.168.1.5 forwarded at line rate in hardware.

---

## Core DOCA Libraries

### 1. DOCA Flow
- **Purpose:** Packet classification and forwarding
- **Performance:** 400 Gbps, millions of flows
- **Use:** OVS offload, firewall rules, load balancing

### 2. DOCA DMA
- **Purpose:** Zero-copy memory transfers
- **Performance:** Very high bandwidth (PCIe)
- **Use:** GPU Direct Storage, NVMe-oF, RDMA

### 3. DOCA Comm Channel
- **Purpose:** Host ↔ DPU communication
- **Performance:** Event-driven, low latency
- **Use:** Configuration, telemetry, control plane

### 4. DOCA RegEx
- **Purpose:** Hardware regex matching
- **Performance:** Multi-Gbps pattern matching
- **Use:** DPI, IDS/IPS, content filtering

### 5. DOCA IPsec
- **Purpose:** Hardware-accelerated encryption
- **Performance:** Line-rate AES-GCM
- **Use:** VPN, secure tunnels

---

## Storage Use Cases

### 1. NVMe-oF Target Offload

**Problem:** CPU busy serving NVMe over network  
**Solution:** DPU handles entire NVMe-oF stack

```
Server: Application → local NVMe
            ↓
        (Network)
            ↓
Client: Application reads from remote NVMe
        • DPU handles NVMe-oF protocol
        • CPU sees local NVMe device
        • Very high throughput
```

### 2. GPU Direct Storage

**Problem:** Data path: Network → CPU RAM → GPU (slow)  
**Solution:** DPU DMAs directly to GPU memory

```
Before: Network → NIC → CPU → PCIe → GPU (multiple copies)
After:  Network → DPU ────────→ GPU (zero copy!)

Performance:
  • Very high GPU bandwidth
  • Much lower latency
  • CPU completely bypassed
```

### 3. Erasure Coding Offload

**Problem:** CPU busy with RAID calculations  
**Solution:** DPU accelerates parity computation

```
DPU: Hardware accelerated (very high throughput)
CPU: Software based (lower throughput)

Result: Much faster storage rebuilds
```

---

## Performance Characteristics

### Throughput

| Operation | OVS-DPDK (CPU) | OVS-DOCA (DPU) |
|-----------|----------------|----------------|
| L2 forwarding | Moderate Gbps | Line rate |
| VXLAN encap/decap | Lower Gbps | Line rate |
| SNAT/DNAT | Lower Gbps | Line rate |
| IPsec encryption | Lowest Gbps | Very high Gbps |

### Latency

| Path | OVS-DPDK | OVS-DOCA |
|------|----------|----------|
| L2 forward | Tens of microseconds | Low microseconds |
| VXLAN overlay | Many tens of microseconds | Low microseconds |
| First packet (upcall) | Hundreds of microseconds | Low milliseconds |

### CPU Usage

| Workload | OVS-DPDK | OVS-DOCA |
|----------|----------|----------|
| Steady state | Multiple cores (full utilization) | Minimal cores (low utilization) |
| Burst traffic | Many cores | Minimal cores |
| Control plane | One core | One core |

**Key Insight:** OVS-DOCA frees many CPU cores for applications!

---

## Installation

### Enable SR-IOV

```bash
# On DPU (BlueField OS)
sudo mlxconfig -d /dev/mst/mt41686_pciconf0 set SRIOV_EN=1
sudo mlxconfig -d /dev/mst/mt41686_pciconf0 set NUM_OF_VFS=<desired_count>

# Reboot DPU
sudo reboot

# Verify
lspci | grep Mellanox  # Should show PFs and VFs
```

### Install OVS-DOCA

```bash
# On DPU
sudo apt update
sudo apt install -y mlnx-dpdk mlnx-ofed-all doca-sdk

# Enable hardware offload
sudo ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
sudo systemctl restart openvswitch-switch

# Verify
sudo ovs-vsctl get Open_vSwitch . other_config:hw-offload
# Should output: "true"
```

### Create OVS Bridge

```bash
# Add bridge
sudo ovs-vsctl add-br ovsbr1

# Add physical port (uplink)
sudo ovs-vsctl add-port ovsbr1 p0

# Add VF representors
for i in {0..N}; do
    sudo ovs-vsctl add-port ovsbr1 pf0vf${i}_rep
done

# Verify flows offloaded
sudo ovs-appctl dpctl/dump-flows type=offloaded
```

---

## Best Practices

### 1. Use Connection Tracking Offload

```bash
sudo ovs-vsctl set Open_vSwitch . other_config:hw-offload-ct-size=<appropriate_size>
```

**Why:** Stateful firewall rules offloaded to hardware.

### 2. Enable Flow Aging

```bash
sudo ovs-vsctl set Open_vSwitch . other_config:max-idle=<timeout_ms>
```

**Why:** Automatically remove stale flows (free hardware resources).

### 3. Monitor Offload Stats

```bash
# Check offload rate
sudo ovs-appctl dpctl/dump-flows type=offloaded | wc -l

# Check for failures
sudo ovs-appctl coverage/show | grep -i offload
```

### 4. Size Hardware Tables Correctly

```bash
# Set flow table size (default: varies by hardware)
sudo ovs-vsctl set Open_vSwitch . other_config:n-offload-threads=<thread_count>
```

**Rule of thumb:** Size based on expected concurrent flows.

---

## Debugging

### Check Hardware Offload Status

```bash
# Is offload enabled?
sudo ovs-vsctl get Open_vSwitch . other_config:hw-offload

# Are flows being offloaded?
sudo ovs-appctl dpctl/dump-flows type=offloaded

# Check for errors
sudo dmesg | grep mlx5
```

### Common Issues

**Problem:** Flows not offloading  
**Check:**
```bash
# Verify DOCA plugin loaded
lsmod | grep mlx5

# Check OVS logs
sudo journalctl -u openvswitch-switch -f
```

**Problem:** Low throughput  
**Check:**
```bash
# Verify SR-IOV enabled
lspci | grep Mellanox | wc -l  # Should show PFs + VFs

# Check link speed
ethtool p0 | grep Speed
```

---

## Resources

- [NVIDIA DOCA SDK](https://developer.nvidia.com/networking/doca)
- [OVS Hardware Offload Guide](https://docs.openvswitch.org/en/latest/topics/dpdk/hardware-offload/)
- [BlueField DPU Documentation](https://docs.nvidia.com/networking/display/bluefieldswsw)
