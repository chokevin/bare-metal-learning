# Multi-Cluster Network Topology for DPU Management

## Overview

This document covers network architecture for managing DPU (Data Processing Unit) nodes across multiple Kubernetes clusters, with emphasis on **VXLAN overlay networks** and **control/data plane separation**.

## Table of Contents

1. [The Challenge](#the-challenge)
2. [Key Principles: Control vs Data Plane](#key-principles)
3. [Architecture Options](#architecture-options)
4. [Why Separate Management and Customer Traffic](#why-separate-management-and-customer-traffic)
5. [Implementation Details](#implementation-details)
6. [Production Considerations](#production-considerations)

---

## The Challenge

In a **VXLAN overlay network** with multi-cluster DPU management, you have:

- **Underlay network**: Physical network carrying VXLAN packets (UDP port 4789)
- **Overlay network**: Logical L2 networks (VNI/VXLAN IDs)
- **DPU nodes**: BlueField DPUs that act as VTEP (VXLAN Tunnel Endpoints)
- **Management plane**: Kubernetes API servers, controllers, agents

**Problem:** Hub cluster needs to program DPU hardware in customer clusters, but VXLAN networks are **logically isolated** per customer.

---

## Key Principles

### 1. Control Plane (K8s API) ≠ Data Plane (VXLAN)

```
┌─────────────────────────────────────────────────────────────────┐
│ Control Plane Network (Kubernetes API - 10.100.0.0/16)         │
│ - Hub cluster API: 10.100.1.10:6443                            │
│ - Customer-1 API: 10.100.2.10:6443                             │
│ - Customer-2 API: 10.100.3.10:6443                             │
│ - Management traffic, CR propagation                            │
│ - Can use VPN, PrivateLink, or direct routing                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ (Separate networks)
                              │
┌─────────────────────────────────────────────────────────────────┐
│ Data Plane Network (VXLAN Underlay - Physical IPs)             │
│                                                                   │
│  Customer-1 VXLAN Network                                       │
│  ┌────────────────────────────────────────────────────────┐     │
│  │ Underlay: 192.168.1.0/24                               │     │
│  │ Overlay VNI 1000: 10.1.0.0/16                          │     │
│  │ Overlay VNI 1001: 10.2.0.0/16                          │     │
│  │                                                          │     │
│  │ DPU-1 (VTEP): 192.168.1.11  ─┐                        │     │
│  │ DPU-2 (VTEP): 192.168.1.12  ─┼─ VXLAN Mesh            │     │
│  │ DPU-3 (VTEP): 192.168.1.13  ─┘                        │     │
│  └────────────────────────────────────────────────────────┘     │
│                                                                   │
│  Customer-2 VXLAN Network (isolated from Customer-1)            │
│  ┌────────────────────────────────────────────────────────┐     │
│  │ Underlay: 192.168.2.0/24                               │     │
│  │ Overlay VNI 2000: 10.10.0.0/16                         │     │
│  │                                                          │     │
│  │ DPU-1 (VTEP): 192.168.2.11  ─┐                        │     │
│  │ DPU-2 (VTEP): 192.168.2.12  ─┼─ VXLAN Mesh            │     │
│  └────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────┘
```

**Core principle:**
- Hub cluster **never** sends data plane traffic
- Hub cluster **only** writes CRs via Kubernetes API
- DPU agents **locally** program VXLAN hardware

### 2. VXLAN Networks are Customer-Scoped

- Each customer has **isolated VXLAN underlay networks**
- Hub doesn't need access to customer VXLAN underlay
- Hub doesn't need to know customer VNI mappings

### 3. DPU Nodes Have Dual Networking

**NVIDIA BlueField DPUs come with multiple physical ports:**

**BlueField-2 Standard Configuration:**
```
NVIDIA BlueField-2 DPU (Physical Card)
├─ oob_net0 (Out-of-Band Management Port)
│   └─ Physical: RJ45 1GbE Ethernet port
│   └─ Purpose: IPMI/BMC, initial provisioning, emergency access
│   └─ IP Example: 10.100.2.50
│
├─ tmfifo_net0 (PCIe FIFO interface to host)
│   └─ Virtual: PCIe communication channel
│   └─ Purpose: Host ↔ DPU communication
│   └─ IP Example: 192.168.100.2 (RFC1918 link-local)
│
├─ p0 (Primary Data Port)
│   └─ Physical: QSFP28 100GbE or QSFP56 200GbE
│   └─ Purpose: Network traffic, VXLAN underlay
│   └─ IP Example: 192.168.1.11
│
└─ p1 (Secondary Data Port)
    └─ Physical: QSFP28 100GbE or QSFP56 200GbE
    └─ Purpose: Redundancy, bonding, or second fabric
    └─ IP Example: 192.168.1.12
```

**BlueField-3 Extended Configuration:**
```
NVIDIA BlueField-3 DPU (Enhanced)
├─ oob_net0 (1GbE management)
├─ tmfifo_net0 (PCIe to host)
├─ p0 (400GbE primary data)
├─ p1 (400GbE secondary data)
└─ USB console port (emergency access)
```

**Typical Network Assignment:**
```
DPU Node (BlueField-2)
├─ ARM Cores (run DPU agent)
│   ├─ tmfifo_net0: 192.168.100.2 → Host (control traffic)
│   └─ oob_net0: 10.100.2.50 → K8s API (reads CRs)
│
├─ p0 (Physical Port - 100GbE)
│   └─ VXLAN VTEP: 192.168.1.11 (data traffic)
│       ├─ VNI 1000 → vxlan1000 (tenant-a pods)
│       ├─ VNI 1001 → vxlan1001 (tenant-b pods)
│       └─ OVS bridge with flow tables
│
└─ p1 (Physical Port - 100GbE)
    └─ Options:
        ├─ Bonded with p0 (bond0) for redundancy
        ├─ Separate fabric (e.g., storage network)
        └─ Unused (for future expansion)
```

**Common port usage patterns:**

1. **Management-only separation (cheapest):**
   - `oob_net0`: Management network (K8s API)
   - `p0`: Data network (VXLAN)
   - `p1`: Unused or bonded with p0

2. **Full physical separation (recommended):**
   - `oob_net0`: Out-of-band management (IPMI, provisioning)
   - `tmfifo_net0`: K8s API access via host
   - `p0`: Data network (VXLAN)
   - `p1`: Bonded with p0 or separate storage network

3. **Multi-fabric (high-end):**
   - `oob_net0`: Out-of-band management
   - `p0`: East-West traffic (pod-to-pod)
   - `p1`: North-South traffic (external ingress/egress)

- **Control interface**: `oob_net0` or `tmfifo_net0` - connects to customer K8s cluster (for watching CRs)
- **Data interface**: `p0` and/or `p1` - VXLAN VTEP for pod traffic

---

## Architecture Options

### Option A: Separate Control and Data Networks (Recommended)

**Why this works:**
- ✅ Control plane (K8s API) uses management network
- ✅ Data plane (VXLAN) uses isolated customer network
- ✅ No routing between control and data planes needed
- ✅ Hub never touches customer VXLAN network

**Network Requirements:**
- Hub cluster needs access to customer K8s API (via VPN/PrivateLink)
- Hub does NOT need access to customer VXLAN underlay
- DPU control interface connects to K8s API server
- DPU data interface is VTEP for VXLAN tunnels

**DPU Agent Configuration:**
```yaml
# DaemonSet runs on DPU ARM cores
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dpu-agent
  namespace: dpu-system
spec:
  selector:
    matchLabels:
      app: dpu-agent
  template:
    spec:
      containers:
      - name: agent
        image: myregistry/dpu-agent:v1.0.0
        env:
        # Control plane: K8s API access
        - name: KUBE_API_SERVER
          value: "https://10.100.2.10:6443"  # Customer K8s API
        
        # Data plane: VXLAN configuration
        - name: VTEP_LOCAL_IP
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP  # DPU's VXLAN underlay IP
        
        - name: VXLAN_DEVICE
          value: "p0"  # Physical interface for VXLAN
        
        - name: OVS_BRIDGE
          value: "br-int"  # OVS bridge name
        
        securityContext:
          privileged: true  # Needed for OVS and hardware programming
        
        volumeMounts:
        - name: ovs-run
          mountPath: /var/run/openvswitch
      
      volumes:
      - name: ovs-run
        hostPath:
          path: /var/run/openvswitch
      
      nodeSelector:
        node-role.kubernetes.io/dpu: "true"
      
      hostNetwork: true  # Access to host networking
```

**DPU Agent Flow Programming:**
```go
// pkg/dpu/vxlan.go
package dpu

import (
    "fmt"
    "os/exec"
    "strings"
    
    dpuv1 "github.com/mycompany/dpu-operator/api/v1"
)

type VXLANProgrammer struct {
    VTEPLocalIP string  // 192.168.1.11
    OVSBridge   string  // "br-int"
}

func (v *VXLANProgrammer) ProgramFlows(rule *dpuv1.DPURule) error {
    for _, flowRule := range rule.Spec.Rules {
        // Create VXLAN port if not exists
        vniPort := fmt.Sprintf("vxlan%d", flowRule.VNI)
        if err := v.ensureVXLANPort(flowRule.VNI, vniPort); err != nil {
            return fmt.Errorf("failed to create VXLAN port: %w", err)
        }
        
        // Program OVS flows
        if err := v.addOVSFlow(vniPort, flowRule); err != nil {
            return fmt.Errorf("failed to add OVS flow: %w", err)
        }
    }
    
    return nil
}

func (v *VXLANProgrammer) ensureVXLANPort(vni int, portName string) error {
    // Check if VXLAN port exists
    cmd := exec.Command("ovs-vsctl", "list-ports", v.OVSBridge)
    output, _ := cmd.Output()
    
    if strings.Contains(string(output), portName) {
        return nil  // Already exists
    }
    
    // Create VXLAN port
    // ovs-vsctl add-port br-int vxlan1000 -- set interface vxlan1000 type=vxlan options:remote_ip=flow options:key=1000 options:local_ip=192.168.1.11
    cmd = exec.Command("ovs-vsctl", "add-port", v.OVSBridge, portName, "--",
        "set", "interface", portName,
        "type=vxlan",
        fmt.Sprintf("options:key=%d", vni),
        fmt.Sprintf("options:local_ip=%s", v.VTEPLocalIP),
        "options:remote_ip=flow",  // Learn remote VTEPs dynamically
    )
    
    return cmd.Run()
}

func (v *VXLANProgrammer) addOVSFlow(vniPort string, rule dpuv1.FlowRule) error {
    // Build OVS flow match criteria
    match := fmt.Sprintf("in_port=%s", vniPort)
    
    if rule.Match.SrcIP != "" {
        match += fmt.Sprintf(",nw_src=%s", rule.Match.SrcIP)
    }
    if rule.Match.DstIP != "" {
        match += fmt.Sprintf(",nw_dst=%s", rule.Match.DstIP)
    }
    if rule.Match.DstPort > 0 {
        match += fmt.Sprintf(",tp_dst=%d", rule.Match.DstPort)
    }
    
    // Build OVS flow actions
    action := ""
    switch rule.Action {
    case "allow":
        action = "normal"  // Forward normally
    case "deny":
        action = "drop"
    case "redirect":
        action = fmt.Sprintf("output:%s", rule.RedirectPort)
    }
    
    // Add flow to OVS
    // ovs-ofctl add-flow br-int "in_port=vxlan1000,nw_src=10.1.0.5,nw_dst=10.1.0.10,tp_dst=80,actions=drop"
    cmd := exec.Command("ovs-ofctl", "add-flow", v.OVSBridge,
        fmt.Sprintf("%s,actions=%s", match, action),
    )
    
    return cmd.Run()
}
```

---

### Option B: VXLAN Over Management Network (Not Recommended)

**Network Layout:**
```
Single Shared Network: 10.100.0.0/16
├─ K8s API traffic (port 6443)
└─ VXLAN underlay (UDP port 4789)
```

**Why this is bad:**
- ❌ Control and data traffic mixed (security risk)
- ❌ VXLAN traffic can overwhelm management network
- ❌ Customer isolation is weak (same underlay)
- ❌ Hard to apply QoS policies

**Only use if:** Test/lab environment with no isolation requirements.

---

### Option C: VXLAN with BGP EVPN (Production Scale)

**For large-scale deployments (100+ DPUs), use BGP EVPN:**

**Network Layout:**
```
┌─────────────────────────────────────────────────────────────┐
│ Control Plane: K8s API (10.100.0.0/16)                      │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ Data Plane: VXLAN + BGP EVPN                                │
│                                                               │
│  Spine Switches (BGP Route Reflectors)                       │
│      ├─ Spine-1: 192.168.0.1                                │
│      └─ Spine-2: 192.168.0.2                                │
│              │                                                │
│         ┌────┴────┐                                          │
│         │         │                                          │
│    Leaf-1    Leaf-2 (ToR switches with EVPN)               │
│      │         │                                             │
│   DPU-1    DPU-2                                            │
│   VTEP     VTEP                                             │
│   192.168.1.11  192.168.1.12                                │
│                                                               │
│   - BGP EVPN for MAC/IP learning                            │
│   - VXLAN for L2 overlay                                    │
│   - Automatic VTEP discovery                                │
└─────────────────────────────────────────────────────────────┘
```

**DPU Configuration with EVPN:**
```yaml
# FRR (Free Range Routing) on DPU for BGP EVPN
# /etc/frr/frr.conf

router bgp 65001
 bgp router-id 192.168.1.11
 neighbor 192.168.0.1 remote-as 65000  # Spine-1
 neighbor 192.168.0.2 remote-as 65000  # Spine-2
 
 address-family l2vpn evpn
  neighbor 192.168.0.1 activate
  neighbor 192.168.0.2 activate
  advertise-all-vni  # Advertise all VXLAN VNIs via EVPN
 exit-address-family
```

**DPU Agent + EVPN:**
```go
// DPU agent programs flows, FRR handles VTEP discovery via EVPN
func (v *VXLANProgrammer) ensureVXLANPort(vni int, portName string) error {
    // With EVPN, remote_ip is learned via BGP (not static)
    cmd := exec.Command("ovs-vsctl", "add-port", v.OVSBridge, portName, "--",
        "set", "interface", portName,
        "type=vxlan",
        fmt.Sprintf("options:key=%d", vni),
        fmt.Sprintf("options:local_ip=%s", v.VTEPLocalIP),
        "options:remote_ip=flow",  // EVPN learns remote VTEPs
    )
    
    return cmd.Run()
}
```

**Benefits of BGP EVPN:**
- ✅ Automatic VTEP discovery (no manual configuration)
- ✅ MAC address learning across fabric
- ✅ Multi-tenancy with VRF (Virtual Routing and Forwarding)
- ✅ Scales to thousands of VTEPs
- ✅ Standard protocol (RFC 7432)

**Complexity:**
- Requires spine-leaf topology with EVPN-capable switches
- FRR or similar BGP daemon on each DPU
- Network team must configure BGP on switches

---

## Why Separate Management and Customer Traffic

### The Importance of Network Separation

**Critical Requirement:** Management traffic (K8s API, control plane) and customer traffic (VXLAN data plane) **MUST** be on separate networks.

### Physical vs Software-Defined Separation

Network separation can be achieved through **physical separation**, **software-defined separation (VLANs/VRFs)**, or a **hybrid approach**. The choice depends on security requirements, scale, and budget.

---

#### **Option 1: Physical Separation (Highest Security)**

**What it means:**
- Separate physical NICs on each DPU
- Separate switches/routers for management vs data
- No shared physical infrastructure

**Example DPU Hardware:**
```
NVIDIA BlueField-2 DPU
├─ oob_net0 (Out-of-Band Management)
│   └─ Physical: RJ45 1GbE port
│   └─ Connected to: Management switch
│   └─ IP: 10.100.2.50/16
│
└─ p0 (Data Port)
    └─ Physical: QSFP28 100GbE port
    └─ Connected to: Data plane switch (ToR)
    └─ IP: 192.168.1.11/24
```

**Network Topology:**
```
┌────────────────────────────────────────────────────────┐
│                  Management Switch                      │
│              (Cisco Nexus / Arista 7050)               │
│                                                         │
│  Port 1-24: DPU oob_net0 (1GbE)                       │
│  Uplink: To management router/firewall                 │
│  VLAN: None (flat L2)                                  │
│  Network: 10.100.0.0/16                                │
└────────────────────────────────────────────────────────┘
              ↑
              │ (Physically separate cables)
              │
     ┌────────┴────────┐
     │                 │
┌────────────┐   ┌────────────┐
│ DPU Node 1 │   │ DPU Node 2 │
│ oob_net0   │   │ oob_net0   │
│ p0 ────────┼───┼────────────┤
└────────────┘   └────────────┘
              │
              ↓ (Separate physical switch)
              │
┌────────────────────────────────────────────────────────┐
│                   Data Plane Switch (ToR)              │
│              (Mellanox Spectrum / Broadcom)            │
│                                                         │
│  Port 1-32: DPU p0 (100GbE)                           │
│  Uplink: To spine switches                             │
│  VLAN: Optional for tenant separation                  │
│  Network: 192.168.1.0/24 (VXLAN underlay)             │
└────────────────────────────────────────────────────────┘
```

**Pros:**
- ✅ **Maximum security** - No software can bridge networks
- ✅ **Complete failure isolation** - Management switch down doesn't affect data
- ✅ **Compliance-friendly** - Auditors love physical airgaps
- ✅ **No performance overhead** - No VLAN tagging/processing
- ✅ **Simple troubleshooting** - Clear physical boundaries

**Cons:**
- ❌ **Expensive** - 2x switch ports, 2x cables per DPU
- ❌ **Space constraints** - More physical infrastructure
- ❌ **Limited flexibility** - Can't easily reassign ports

**Best for:**
- High-security environments (financial services, government)
- Large-scale production (100+ DPUs where cost amortizes)
- Compliance-heavy workloads (PCI-DSS Level 1, HIPAA)

**Real-world example:**
```
Large Cloud Provider:
- 1,000 DPU nodes
- Management: 10GbE network, separate switch fabric
- Data: 100GbE network, separate EVPN spine-leaf fabric
- Zero shared infrastructure
- Cost: ~$50K additional for management switches (amortized)
```

---

#### **Option 2: VLAN Separation (Software-Defined)**

**What it means:**
- Single physical NIC with VLAN tagging (802.1Q)
- Same physical switch, different VLANs
- Software isolation enforced by switch

**Example DPU Configuration:**
```
NVIDIA BlueField-2 DPU
└─ p0 (Physical Port - 100GbE)
    ├─ p0.100 (VLAN 100 - Management)
    │   └─ IP: 10.100.2.50/16
    │   └─ Connected to: VLAN 100 on switch
    │
    └─ p0.200 (VLAN 200 - Data)
        └─ IP: 192.168.1.11/24
        └─ Connected to: VLAN 200 on switch
```

**Network Topology:**
```
┌────────────────────────────────────────────────────────┐
│              Single ToR Switch                          │
│         (Cisco Nexus 9300 / Arista 7280)               │
│                                                         │
│  Port 1-32: Trunk (VLANs 100, 200)                    │
│                                                         │
│  VLAN 100 (Management):                                │
│    - Network: 10.100.0.0/16                           │
│    - Gateway: 10.100.0.1                              │
│    - ACL: Deny inter-VLAN routing to VLAN 200        │
│                                                         │
│  VLAN 200 (Data):                                      │
│    - Network: 192.168.1.0/24                          │
│    - Gateway: 192.168.1.1                             │
│    - ACL: Deny inter-VLAN routing to VLAN 100        │
│                                                         │
└────────────────────────────────────────────────────────┘
              ↓
     ┌────────┴────────┐
     │                 │
┌────────────┐   ┌────────────┐
│ DPU Node 1 │   │ DPU Node 2 │
│ p0.100 ────┤   ├──── p0.100 │ (VLAN 100 - Management)
│ p0.200 ────┤   ├──── p0.200 │ (VLAN 200 - Data)
└────────────┘   └────────────┘
```

**DPU Network Configuration:**
```bash
# /etc/netplan/01-dpu.yaml
network:
  version: 2
  ethernets:
    p0:
      dhcp4: no
  
  vlans:
    # Management VLAN
    p0.100:
      id: 100
      link: p0
      addresses:
        - 10.100.2.50/16
      routes:
        - to: 10.100.0.0/16
          via: 10.100.0.1
      nameservers:
        addresses: [10.100.0.53]
    
    # Data VLAN
    p0.200:
      id: 200
      link: p0
      addresses:
        - 192.168.1.11/24
      # No default route - data plane only
```

**Switch Configuration (Cisco IOS):**
```
! Configure VLANs
vlan 100
  name MANAGEMENT
vlan 200
  name DATA

! Configure trunk port to DPU
interface Ethernet1/1
  description DPU-1
  switchport mode trunk
  switchport trunk allowed vlan 100,200
  spanning-tree port type edge trunk

! Prevent inter-VLAN routing
ip access-list extended BLOCK_CROSS_VLAN
  deny ip 10.100.0.0 0.0.255.255 192.168.1.0 0.0.0.255
  deny ip 192.168.1.0 0.0.0.255 10.100.0.0 0.0.255.255
  permit ip any any

interface Vlan100
  ip address 10.100.0.1 255.255.0.0
  ip access-group BLOCK_CROSS_VLAN in

interface Vlan200
  ip address 192.168.1.1 255.255.255.0
  ip access-group BLOCK_CROSS_VLAN in
```

**Pros:**
- ✅ **Cost-effective** - Single NIC, single switch port per DPU
- ✅ **Flexible** - Easy to add/modify VLANs
- ✅ **Efficient** - Better port utilization
- ✅ **Standard** - 802.1Q supported everywhere

**Cons:**
- ❌ **Shared fate** - Switch failure affects both networks
- ❌ **Software isolation only** - VLAN hopping attacks possible
- ❌ **Performance overhead** - VLAN tagging processing (~1-5% overhead)
- ❌ **Complexity** - Requires careful ACL management
- ❌ **Weaker compliance** - Some auditors require physical separation

**Best for:**
- Medium-scale deployments (10-100 DPUs)
- Cost-sensitive environments
- Lab/staging environments
- Where compliance allows software separation

**Real-world example:**
```
Startup with 20 DPU nodes:
- Single 100GbE switch ($30K vs $60K for dual switches)
- VLAN 100: Management (1 Gbps committed)
- VLAN 200: Data (remaining bandwidth)
- Switch ACLs prevent inter-VLAN routing
- Cost savings: $30K + reduced cabling
```

---

#### **Option 3: VRF (Virtual Routing and Forwarding) - Advanced Software Separation**

**What it means:**
- Multiple routing tables on same physical hardware
- Stronger isolation than VLANs (L3 vs L2 separation)
- Common in service provider networks

**Network Topology:**
```
┌────────────────────────────────────────────────────────┐
│              ToR Switch with VRF                        │
│                                                         │
│  VRF: MGMT                                             │
│    ├─ VLAN 100                                         │
│    ├─ Routing table: 10.100.0.0/16                    │
│    └─ Cannot route to VRF DATA                        │
│                                                         │
│  VRF: DATA                                             │
│    ├─ VLAN 200                                         │
│    ├─ Routing table: 192.168.0.0/16                   │
│    └─ Cannot route to VRF MGMT                        │
│                                                         │
└────────────────────────────────────────────────────────┘
```

**Switch Configuration (Cisco):**
```
! Define VRFs
vrf definition MGMT
  address-family ipv4
  exit-address-family

vrf definition DATA
  address-family ipv4
  exit-address-family

! Management VLAN
interface Vlan100
  vrf forwarding MGMT
  ip address 10.100.0.1 255.255.0.0

! Data VLAN
interface Vlan200
  vrf forwarding DATA
  ip address 192.168.1.1 255.255.255.0

! No route leaking between VRFs (enforced by hardware)
```

**Pros:**
- ✅ **Strong isolation** - Hardware-enforced at L3 routing level
- ✅ **Better than VLANs** - Separate routing tables, no inter-VRF routing
- ✅ **Scalable** - Used in large service provider networks
- ✅ **Flexible** - Can allow selective route leaking if needed

**Cons:**
- ❌ **Complex** - Requires advanced networking knowledge
- ❌ **Expensive switches** - Not all switches support VRF
- ❌ **Shared physical** - Still shares physical ports/fabric

**Best for:**
- Service provider environments
- Advanced network teams
- When VLANs insufficient but physical separation too costly

---

#### **Option 4: Hybrid - Physical + Software (Recommended for Most)**

**What it means:**
- Separate physical NICs on DPU
- Management NIC: Low-bandwidth, dedicated switch/VLAN
- Data NIC: High-bandwidth, separate physical switch
- VLANs/VRFs used within data plane for tenant isolation

**Network Topology:**
```
┌────────────────────────────────────────────────────────┐
│         Management Switch (10GbE)                       │
│  - Physical separation from data plane                  │
│  - VLAN 100-110: Different customer clusters           │
└────────────────────────────────────────────────────────┘
              ↑
              │ oob_net0 (1GbE)
              │
     ┌────────┴────────┐
     │                 │
┌────────────┐   ┌────────────┐
│ DPU Node 1 │   │ DPU Node 2 │
└────────────┘   └────────────┘
     │                 │
     │ p0 (100GbE)    │
     ↓                 ↓
┌────────────────────────────────────────────────────────┐
│         Data Plane Switch (100GbE)                      │
│  - Physical separation from management                  │
│  - VLANs 1000-1999: Customer A VNIs                    │
│  - VLANs 2000-2999: Customer B VNIs                    │
└────────────────────────────────────────────────────────┘
```

**Why hybrid is best:**
- ✅ **Physical separation** between control and data (security)
- ✅ **Cost-effective management network** (low bandwidth needs)
- ✅ **High-performance data network** (full line rate)
- ✅ **VLANs for tenant isolation** within data plane (flexible)
- ✅ **Balance of security and cost**

**Implementation:**
```yaml
# DPU configuration
Management Interface (oob_net0):
  - Physical: 1GbE RJ45
  - Switch: Dedicated management switch
  - Network: 10.100.0.0/16
  - Purpose: K8s API, SSH, monitoring

Data Interface (p0):
  - Physical: 100GbE QSFP28
  - Switch: Dedicated data plane switch (spine-leaf)
  - VLANs: 1000-2999 (customer tenant isolation)
  - Network: 192.168.0.0/16 (VXLAN underlay)
  - Purpose: Pod traffic, VXLAN tunnels
```

**Cost comparison:**
```
Physical only (Option 1):
  - 2x 100GbE switches: $60K
  - 2x 100GbE NICs per DPU: Included
  - Total: $60K

Hybrid (Option 4):
  - 1x 10GbE management switch: $5K
  - 1x 100GbE data switch: $30K
  - 1x 1GbE + 1x 100GbE NIC: Included
  - Total: $35K
  - Savings: $25K (42% cheaper)
```

---

### Comparison: Physical vs Software Separation

| Aspect | Physical | VLAN | VRF | Hybrid |
|--------|----------|------|-----|--------|
| **Security** | ⭐⭐⭐⭐⭐ Highest | ⭐⭐⭐ Medium | ⭐⭐⭐⭐ High | ⭐⭐⭐⭐⭐ Highest |
| **Cost** | ⭐⭐ High | ⭐⭐⭐⭐⭐ Low | ⭐⭐⭐ Medium | ⭐⭐⭐⭐ Medium-Low |
| **Complexity** | ⭐⭐⭐⭐ Simple | ⭐⭐⭐ Medium | ⭐⭐ Complex | ⭐⭐⭐ Medium |
| **Failure Isolation** | ⭐⭐⭐⭐⭐ Perfect | ⭐⭐ Poor | ⭐⭐ Poor | ⭐⭐⭐⭐⭐ Perfect |
| **Performance** | ⭐⭐⭐⭐⭐ Zero overhead | ⭐⭐⭐⭐ 1-5% overhead | ⭐⭐⭐⭐ 1-5% overhead | ⭐⭐⭐⭐⭐ Zero overhead |
| **Flexibility** | ⭐⭐ Limited | ⭐⭐⭐⭐⭐ High | ⭐⭐⭐⭐⭐ High | ⭐⭐⭐⭐ High |
| **Compliance** | ⭐⭐⭐⭐⭐ Best | ⭐⭐⭐ Acceptable | ⭐⭐⭐⭐ Good | ⭐⭐⭐⭐⭐ Best |
| **Troubleshooting** | ⭐⭐⭐⭐⭐ Easy | ⭐⭐⭐ Medium | ⭐⭐ Hard | ⭐⭐⭐⭐ Easy |

---

### Recommendation by Use Case

**High-security production (financial, healthcare):**
→ **Physical** or **Hybrid**
- Compliance requirements mandate physical separation
- Budget allows for dedicated switches

**Medium-scale production (SaaS, cloud services):**
→ **Hybrid**
- Best balance of security and cost
- Management on cheap 10GbE switch
- Data on high-performance spine-leaf

**Cost-sensitive / Lab / Staging:**
→ **VLAN**
- Single switch is sufficient
- VLANs provide adequate isolation for non-production
- Easy to reconfigure

**Service provider / Telco:**
→ **VRF** or **Physical**
- VRF common in carrier-grade networks
- Physical separation for customer-facing services

---

### Real-World Example: Hybrid Deployment

**Scenario:** 100 DPU nodes for multi-tenant Kubernetes platform

**Network Design:**
```
Management Network (Physical):
├─ Switch: Arista 7050X (10GbE, $8K)
├─ Ports: 100x 1GbE for DPU oob_net0
├─ Uplink: 2x 10GbE to management router
├─ Network: 10.100.0.0/16
├─ VLANs: None (flat L2)
└─ Purpose: K8s API, SSH, Prometheus scraping

Data Network (Physical):
├─ Spine switches: 2x Mellanox Spectrum-2 (32x 100GbE, $50K each)
├─ Leaf switches: 4x Mellanox Spectrum-2 (32x 100GbE, $50K each)
├─ Topology: EVPN spine-leaf fabric
├─ Ports: 100x 100GbE for DPU p0
├─ Network: 192.168.0.0/16 (VXLAN underlay)
├─ VLANs: 1000-1999 (tenant VNI mapping)
└─ Purpose: Pod traffic, VXLAN tunnels

Total Cost:
├─ Management: $8K (switch only)
├─ Data plane: $300K (6 switches)
└─ Total: $308K

vs Pure Physical (2x 100GbE fabrics):
├─ Management: $300K (full spine-leaf)
├─ Data plane: $300K (full spine-leaf)
└─ Total: $600K

Savings: $292K (49%)
```

---

---

### 1. Security Isolation

**Problem without separation:**
```
┌─────────────────────────────────────────────┐
│ Single Network: 10.0.0.0/8                  │
│                                              │
│ K8s API (10.0.1.10:6443) ──┐               │
│                              │               │
│ Customer Pod A (10.0.2.5) ──┼─ Same subnet │
│                              │               │
│ Customer Pod B (10.0.3.8) ──┘               │
└─────────────────────────────────────────────┘
```

**Risks:**
- ❌ Customer pods can potentially reach K8s API server directly
- ❌ No network-level isolation between tenants
- ❌ Management credentials exposed to data plane
- ❌ Lateral movement between customer networks possible

**Solution with separation:**
```
┌─────────────────────────────────────────────┐
│ Management Network: 10.100.0.0/16          │
│ - K8s API: 10.100.1.10:6443                │
│ - Controllers, agents                       │
│ - NO customer pod access                    │
└─────────────────────────────────────────────┘
         │
         │ (Physical separation or VRF)
         │
┌─────────────────────────────────────────────┐
│ Customer Network: 192.168.0.0/16           │
│ - Customer pods, VXLAN VTEPs               │
│ - CANNOT reach management network          │
└─────────────────────────────────────────────┘
```

**Security wins:**
- ✅ Customer pods cannot reach K8s API server
- ✅ Network firewall between management and data
- ✅ Different credentials/certificates per network
- ✅ Blast radius contained per network

---

### 2. Performance and Bandwidth

**Problem without separation:**
```
Single 100GbE link
├─ K8s API traffic (10 Mbps baseline, spikes to 100 Mbps)
├─ Control plane heartbeats (5 Mbps)
└─ Customer VXLAN traffic (up to 99 Gbps)
```

**Risk:** Customer data plane traffic can **starve** management traffic.

**Example failure scenario:**
```
1. Customer starts large data transfer (80 Gbps)
2. Management traffic gets queued/dropped
3. K8s API responses timeout
4. DPU agents can't watch for CR updates
5. New network policies not applied → outage
```

**Solution with separation:**
```
Management Network (10GbE dedicated)
├─ K8s API traffic (guaranteed bandwidth)
├─ Control plane heartbeats (always delivered)
└─ Max 10 Gbps (never saturated)

Customer Network (100GbE dedicated)
├─ VXLAN traffic (full line rate)
├─ Pod-to-pod communication
└─ No impact on management plane
```

**Performance wins:**
- ✅ Management traffic has dedicated bandwidth
- ✅ Customer traffic cannot impact control plane
- ✅ Predictable latency for API calls
- ✅ QoS not required (physical separation)

---

### 3. Failure Domain Isolation

**Problem without separation:**
```
Single network failure affects BOTH:
- Customer data plane (expected)
- Management plane (catastrophic)
```

**Example failure:**
```
Switch failure on shared network
    ↓
Customer pods lose connectivity (acceptable)
    +
Hub controller loses K8s API access (OUTAGE)
    +
DPU agents can't update rules (FROZEN STATE)
    ↓
System-wide outage, requires manual intervention
```

**Solution with separation:**
```
Customer network failure:
    ↓
Customer pods lose connectivity (isolated failure)
    +
Management plane still operational
    ↓
Hub controller can still write new rules
DPU agents can still read rules (when network recovers)
System recovers automatically when network comes back
```

**Resilience wins:**
- ✅ Management plane survives customer network failures
- ✅ Customer failures don't cascade to control plane
- ✅ Independent recovery paths
- ✅ Better mean time to recovery (MTTR)

---

### 4. Multi-Tenancy Requirements

**Problem without separation:**
```
Customer A VNI 1000: 10.1.0.0/16
Customer B VNI 2000: 10.2.0.0/16
Management: 10.100.0.0/16

All on same physical network
    ↓
VNI provides SOME isolation, but:
- Same underlay network (shared fate)
- Broadcast storms affect all customers
- ARP/MAC flooding impacts everyone
- No hard network boundary
```

**Solution with separation:**
```
Management Network (10.100.0.0/16)
    - Single logical network
    - K8s API, controllers

Customer A Network (192.168.1.0/24)
    - VNI 1000, VNI 1001
    - Physically isolated underlay

Customer B Network (192.168.2.0/24)
    - VNI 2000, VNI 2001
    - Completely separate physical network
```

**Multi-tenancy wins:**
- ✅ Customer A traffic cannot reach Customer B underlay
- ✅ Management traffic isolated from ALL customers
- ✅ Broadcast domains separated
- ✅ Hard network boundaries for compliance (PCI-DSS, HIPAA)

---

### 5. Operational Complexity

**Problem without separation:**
```yaml
# Every DPU needs complex routing/firewall rules
iptables:
  # Allow K8s API access from DPU agent
  - "-A INPUT -s 192.168.1.11 -d 10.100.1.10 -p tcp --dport 6443 -j ACCEPT"
  
  # Block customer pods from K8s API
  - "-A FORWARD -s 10.1.0.0/16 -d 10.100.1.10 -j DROP"
  
  # Allow VXLAN between customer pods
  - "-A FORWARD -s 10.1.0.0/16 -d 10.1.0.0/16 -p udp --dport 4789 -j ACCEPT"
  
  # ... 50+ more rules per DPU
```

**Risk:** Complex rules → configuration drift → security holes

**Solution with separation:**
```yaml
# DPU has two interfaces - no routing needed
Management interface (oob_net0):
  - IP: 10.100.2.50
  - Default route: → 10.100.0.1 (management gateway)
  - Access: K8s API only

Data interface (p0):
  - IP: 192.168.1.11
  - No default route
  - Access: VXLAN only (UDP 4789)
  
# No complex iptables rules needed - physical separation enforces policy
```

**Operational wins:**
- ✅ Simple, obvious network design
- ✅ No complex firewall rules
- ✅ Easy to troubleshoot (tcpdump per interface)
- ✅ Reduced configuration drift

---

### 6. Compliance and Audit

**Compliance requirements (PCI-DSS, HIPAA, SOC2) often mandate:**

> "Management/control plane MUST be on separate network from data plane"

**Example PCI-DSS 4.0 Requirement 1.3.3:**
> "Network segmentation to isolate the cardholder data environment (CDE) from other networks"

**Without separation:**
```
Audit finding: "Management traffic shares network with customer data"
    ↓
Compliance failure
    ↓
Expensive remediation, delayed certification
```

**With separation:**
```
Network diagram shows:
- Management VLAN 100 (10.100.0.0/16)
- Customer VLAN 200 (192.168.0.0/16)
- No routing between VLANs
    ↓
Pass audit ✅
```

**Compliance wins:**
- ✅ Clear network boundaries
- ✅ Easy to demonstrate isolation
- ✅ Simplified audit evidence
- ✅ Reduced compliance risk

---

## Putting It All Together: Hub → Customer VXLAN Flow

**Step-by-step packet flow:**

```
1. User creates NetworkPolicy in Hub Cluster
   ↓ (K8s API over management network)

2. Hub controller writes DPURule CR to Customer Cluster
   Hub (10.100.1.10) → VPN → Customer API (10.100.2.10:6443)
   ↓ (K8s watch over management network)

3. DPU Agent watches for DPURule CR
   DPU control interface (10.100.2.50) → Customer API (10.100.2.10)
   ↓ (Local programming)

4. DPU Agent programs OVS flows
   DPU ARM cores → OVS on DPU → Hardware offload
   ↓ (Data plane - VXLAN network)

5. Pod traffic flows through VXLAN
   Pod (10.1.0.5) → veth → OVS (VNI 1000) → VXLAN (UDP 4789)
   → Physical network (192.168.1.11 → 192.168.1.12)
   → Remote DPU → Remote OVS → Remote Pod (10.1.0.10)
```

**Key insight:** Hub never touches VXLAN data plane. It only writes CRs via K8s API (control plane).

---

## Network Topology Summary

| Topology | Control Plane | Data Plane | Complexity | Best For |
|----------|--------------|------------|-----------|----------|
| **Separate Networks** | Management (VPN) | Dedicated VXLAN underlay | ⭐⭐ Medium | Production multi-tenant |
| **Shared Network** | Same as data | Same as control | ⭐ Low | Lab/testing only |
| **BGP EVPN** | Management (VPN) | VXLAN + BGP fabric | ⭐⭐⭐ High | Large scale (100+ nodes) |

---

## Production Considerations

### Recommended Setup for Scale

**If you have:**
- **< 50 DPUs per customer:** Use **Option A (Separate Networks)** with static VXLAN configuration
- **50-200 DPUs per customer:** Add **Option A + Multicast** for VTEP discovery
- **> 200 DPUs or multi-site:** Use **Option C (BGP EVPN)** with spine-leaf topology

### Network Requirements Checklist

- [ ] **Management network with VPN/PrivateLink** (for K8s API access)
- [ ] **Dedicated high-bandwidth network for VXLAN underlay** (25GbE+)
- [ ] **DPU nodes with dual interfaces** (control + data)
- [ ] **UDP port 4789 open for VXLAN** (data plane only)
- [ ] **MTU configuration** (typically 9000 for jumbo frames)
- [ ] **QoS policies** to prioritize control plane traffic (if shared links)
- [ ] **Network monitoring** per plane (separate dashboards)
- [ ] **Firewall rules** preventing cross-plane communication
- [ ] **Backup management connectivity** (out-of-band console access)

### Reference Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                     Management Network                         │
│                      (10.100.0.0/16)                          │
│                                                                │
│  ┌─────────┐         ┌──────────────┐         ┌─────────┐   │
│  │  Hub    │  VPN    │  Customer-1  │         │Customer │   │
│  │Cluster  │◄───────►│  K8s API     │         │   -N    │   │
│  │  API    │         │  10.100.2.10 │         │         │   │
│  └─────────┘         └──────────────┘         └─────────┘   │
│                              │                                 │
│                              │ (DPU control interface)        │
│                              ↓                                 │
│                       ┌─────────────┐                         │
│                       │ DPU Agent   │                         │
│                       │ 10.100.2.50 │                         │
│                       └─────────────┘                         │
└───────────────────────────────────────────────────────────────┘
                                │
                                │ (Dual-homed DPU)
                                │
┌───────────────────────────────────────────────────────────────┐
│                      Data Network                              │
│                    (192.168.1.0/24)                           │
│                                                                │
│                       ┌─────────────┐                         │
│                       │ DPU VTEP    │                         │
│                       │192.168.1.11 │                         │
│                       └─────────────┘                         │
│                              │                                 │
│                    ┌─────────┴─────────┐                     │
│                    │                   │                      │
│              ┌──────────┐        ┌──────────┐               │
│              │  VNI 1000│        │  VNI 1001│               │
│              │ Customer │        │ Customer │               │
│              │ Tenant A │        │ Tenant B │               │
│              └──────────┘        └──────────┘               │
└───────────────────────────────────────────────────────────────┘
```

---

## Summary

**Management and customer traffic separation is critical because:**

1. **Security**: Hard network boundary prevents unauthorized access
2. **Performance**: Dedicated bandwidth prevents resource starvation
3. **Resilience**: Independent failure domains improve availability
4. **Multi-tenancy**: Physical isolation supports strong tenant boundaries
5. **Operations**: Simplified configuration reduces errors
6. **Compliance**: Meets regulatory requirements for network segmentation

**Default choice: Separate networks (Option A)** unless you have specific constraints.

For more details on multi-cluster connectivity approaches, see [kubernetes-image.md](../kubernetes/kubernetes-image.md#how-hub-spoke-actually-connects-to-customer-clusters).
