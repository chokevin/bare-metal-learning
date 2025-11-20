# GNS3 Lab: DPU Multi-Network Topology Testing

## Overview

This lab guide shows how to use **GNS3** to simulate and test DPU multi-network architectures, including:
- Out-of-band management network (oob_net0)
- High-speed data plane network (p0, p1)
- VXLAN overlay testing
- Network separation validation
- Multi-cluster connectivity patterns

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Lab Topology Options](#lab-topology-options)
3. [GNS3 Setup](#gns3-setup)
4. [DPU Simulation Options](#dpu-simulation-options)
5. [Lab Exercises](#lab-exercises)
6. [Testing Scenarios](#testing-scenarios)
7. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Required Software

**GNS3 Installation:**
```bash
# Ubuntu/Debian
sudo add-apt-repository ppa:gns3/ppa
sudo apt update
sudo apt install gns3-gui gns3-server

# macOS
brew install --cask gns3
```

**GNS3 VM (recommended for performance):**
- Download from: https://www.gns3.com/software/download-vm
- Import into VMware Workstation/Fusion or VirtualBox
- Allocate: 4 CPU cores, 8GB RAM minimum

**Docker (for containerized network functions):**
```bash
# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Add user to docker group
sudo usermod -aG docker $USER
```

### Required GNS3 Appliances

**Switches:**
- Open vSwitch (OVS) - for VXLAN testing
- Cisco IOSv / IOSvL2 - for VLAN/VRF testing
- Arista vEOS - for EVPN testing

**Routers:**
- VyOS - lightweight Linux router
- Cisco CSR1000v - full IOS-XE
- FRRouting (FRR) - for BGP EVPN

**Linux Hosts:**
- Ubuntu Cloud Image (22.04)
- Alpine Linux (lightweight)

---

## Lab Topology Options

### Lab 1: Simple Physical Separation

**Topology:**
```
┌──────────────────────────────────────────────────────────┐
│                  GNS3 Workspace                          │
│                                                           │
│  Management Switch (OVS-Mgmt)                            │
│  ┌─────────────────────────────┐                         │
│  │ Bridge: br-mgmt             │                         │
│  │ Ports: 1-4                  │                         │
│  └────┬─────────┬────────┬─────┘                         │
│       │         │        │                                │
│    ┌──┴──┐   ┌─┴───┐  ┌─┴───┐                          │
│    │DPU-1│   │DPU-2│  │ K8s │  (oob_net0)              │
│    │oob  │   │oob  │  │ API │                           │
│    └──┬──┘   └─┬───┘  └─────┘                          │
│       │         │                                         │
│       │ p0      │ p0                                      │
│       │         │                                         │
│  ┌────┴─────────┴──────┐                                 │
│  │ Data Switch (OVS-Data)                                │
│  │ Bridge: br-data       │                               │
│  │ Ports: 1-4            │                               │
│  └───────────────────────┘                               │
│                                                           │
└──────────────────────────────────────────────────────────┘
```

**What this tests:**
- ✅ Physical network separation
- ✅ Management traffic isolated from data
- ✅ Dual-interface configuration on DPUs
- ✅ Basic connectivity validation

---

### Lab 2: VLAN Separation (Software-Defined)

**Topology:**
```
┌──────────────────────────────────────────────────────────┐
│                  GNS3 Workspace                          │
│                                                           │
│           Single Switch (Cisco IOSv)                     │
│  ┌───────────────────────────────────────┐               │
│  │ VLANs: 100 (Mgmt), 200 (Data)        │               │
│  │ Trunk ports: 1-4                      │               │
│  │ ACLs: Block inter-VLAN routing       │               │
│  └──┬───────────┬───────────┬──────┬────┘               │
│     │           │           │      │                     │
│     │           │           │      │                     │
│  ┌──┴────┐   ┌─┴─────┐  ┌──┴───┐ │                     │
│  │ DPU-1 │   │ DPU-2 │  │ K8s  │ │                     │
│  │ p0.100│   │ p0.100│  │ API  │ │                     │
│  │ p0.200│   │ p0.200│  │      │ │                     │
│  └───────┘   └───────┘  └──────┘ │                     │
│                                    │                     │
│                          ┌─────────┴──┐                  │
│                          │ Attacker   │                  │
│                          │ (Test Host)│                  │
│                          └────────────┘                  │
│                                                           │
└──────────────────────────────────────────────────────────┘
```

**What this tests:**
- ✅ VLAN tagging (802.1Q)
- ✅ ACL effectiveness (can attacker breach VLAN?)
- ✅ Inter-VLAN routing prevention
- ✅ VLAN hopping attack attempts
- ✅ Performance overhead measurement

---

### Lab 3: VXLAN Overlay with Management Separation

**Topology:**
```
┌──────────────────────────────────────────────────────────┐
│                  GNS3 Workspace                          │
│                                                           │
│  Management Network (br-mgmt)                            │
│  ┌────────────────────────────┐                          │
│  │ 10.100.0.0/16              │                          │
│  └──┬──────────┬──────────┬───┘                          │
│     │          │          │                               │
│  ┌──┴───┐   ┌─┴────┐  ┌──┴────┐                         │
│  │VTEP-1│   │VTEP-2│  │ K8s   │                         │
│  │ oob  │   │ oob  │  │ API   │                         │
│  └──┬───┘   └─┬────┘  └───────┘                         │
│     │          │                                          │
│     │ p0       │ p0                                       │
│     │          │                                          │
│  ┌──┴──────────┴─────────┐                               │
│  │ VXLAN Underlay (br-data)                              │
│  │ 192.168.1.0/24         │                              │
│  │                        │                              │
│  │ VNI 1000: 10.1.0.0/16  │ (Customer A)                │
│  │ VNI 2000: 10.2.0.0/16  │ (Customer B)                │
│  └────────────────────────┘                              │
│                                                           │
└──────────────────────────────────────────────────────────┘
```

**What this tests:**
- ✅ VXLAN tunnel establishment
- ✅ VNI isolation between tenants
- ✅ Management network separation
- ✅ VTEP functionality
- ✅ OVS flow table programming

---

### Lab 4: Multi-Cluster Hub-Spoke (Complete)

**Topology:**
```
┌──────────────────────────────────────────────────────────────────┐
│                       GNS3 Workspace                             │
│                                                                   │
│  ┌────────────────────────────────────────────┐                  │
│  │ Hub Management Network (10.100.1.0/24)    │                  │
│  │ ┌──────────┐                               │                  │
│  │ │ Hub K8s  │                               │                  │
│  │ │ API      │                               │                  │
│  │ └────┬─────┘                               │                  │
│  └──────┼──────────────────────────────────────┘                  │
│         │                                                          │
│         │ VPN/PrivateLink (simulated by router)                  │
│         │                                                          │
│  ┌──────┴──────────────────────────────────────┐                  │
│  │ Customer-1 Management (10.100.2.0/24)      │                  │
│  │ ┌──────────┐    ┌──────────┐              │                  │
│  │ │Customer-1│    │  DPU-1   │              │                  │
│  │ │ K8s API  │    │  Agent   │              │                  │
│  │ └──────────┘    └────┬─────┘              │                  │
│  └──────────────────────┼──────────────────────┘                  │
│                          │                                         │
│  ┌───────────────────────┴────────────────────┐                   │
│  │ Customer-1 Data Network (192.168.1.0/24)  │                   │
│  │                                            │                   │
│  │  DPU-1 (VTEP)  ←→  DPU-2 (VTEP)          │                   │
│  │  192.168.1.11      192.168.1.12          │                   │
│  │                                            │                   │
│  │  VNI 1000: 10.1.0.0/16 (pods)            │                   │
│  └────────────────────────────────────────────┘                   │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

**What this tests:**
- ✅ Hub-spoke connectivity
- ✅ Cross-cluster CR propagation
- ✅ DPU agent watching customer K8s API
- ✅ Complete end-to-end flow
- ✅ Network policy → DPU rule → flow programming

---

## GNS3 Setup

### Step 1: Create New Project

```bash
# In GNS3 GUI:
File → New Blank Project
Name: "dpu-multi-network-lab"
Location: ~/GNS3/projects/
```

### Step 2: Import Appliances

**Option 1: Import Ubuntu Cloud Image (for DPU simulation)**
```bash
# Download Ubuntu Cloud Image
wget https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img

# Convert to QEMU format
qemu-img convert -f qcow2 -O qcow2 ubuntu-22.04-server-cloudimg-amd64.img ubuntu-dpu.qcow2
qemu-img resize ubuntu-dpu.qcow2 20G

# Import to GNS3
GNS3 → Edit → Preferences → QEMU → Qemu VMs → New
- Name: "Ubuntu-DPU"
- RAM: 2048 MB
- Disk image: ubuntu-dpu.qcow2
- Network adapters: 4 (oob, tmfifo, p0, p1)
```

**Option 2: Use Docker Container (lightweight)**
```bash
# Create Dockerfile for DPU simulation
cat > Dockerfile.dpu <<EOF
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    iproute2 \
    iputils-ping \
    tcpdump \
    openvswitch-switch \
    openvswitch-common \
    net-tools \
    curl \
    iptables \
    bridge-utils \
    vim

# Enable IP forwarding
RUN echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# Start OVS on boot
RUN systemctl enable openvswitch-switch || true

CMD ["/bin/bash"]
EOF

# Build and push to Docker Hub (or use locally)
docker build -t dpu-simulator:latest -f Dockerfile.dpu .

# Import to GNS3
GNS3 → Edit → Preferences → Docker containers → New
- Image: "dpu-simulator:latest"
- Network adapters: 4
- Start command: /bin/bash
- Console type: telnet
```

### Step 3: Add Open vSwitch Appliance

**Download OVS appliance:**
```bash
# GNS3 Marketplace
GNS3 → File → Import appliance
Search: "Open vSwitch"
Download: openvswitch-2.15.appliance

# Or manual install in Ubuntu VM
sudo apt install openvswitch-switch openvswitch-common
```

### Step 4: Add Cisco IOSv (for VLAN testing)

**Import Cisco IOSv:**
```bash
# Requires Cisco image (vios-adventerprisek9-m)
GNS3 → Edit → Preferences → IOS on QEMU → New
- Name: "IOSv-L2"
- Image: vios-adventerprisek9-m.vmdk.SPA.156-2.T
- RAM: 512 MB
```

---

## DPU Simulation Options

### Option 1: Full VM (Most Realistic)

**Pros:**
- ✅ Run real Kubernetes components
- ✅ Test actual OVS configurations
- ✅ Full kernel networking stack
- ✅ Can install DPU software stack

**Cons:**
- ❌ Resource intensive (2GB RAM per DPU)
- ❌ Slower startup (~30 seconds)

**Configuration:**
```yaml
# cloud-init config for Ubuntu VM
#cloud-config
hostname: dpu-1
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-rsa AAAA... your-key

packages:
  - openvswitch-switch
  - docker.io
  - kubernetes-cni

write_files:
  - path: /etc/netplan/99-dpu.yaml
    content: |
      network:
        version: 2
        ethernets:
          eth0:  # oob_net0
            dhcp4: no
            addresses: [10.100.2.50/16]
            routes:
              - to: 10.100.0.0/16
                via: 10.100.0.1
          
          eth2:  # p0 (data)
            dhcp4: no
            addresses: [192.168.1.11/24]

runcmd:
  - netplan apply
  - ovs-vsctl add-br br-int
  - systemctl enable docker
```

---

### Option 2: Docker Container (Lightweight)

**Pros:**
- ✅ Fast startup (<5 seconds)
- ✅ Low resource usage (~200MB RAM)
- ✅ Easy to replicate
- ✅ Good for testing network connectivity

**Cons:**
- ❌ Shared kernel with host
- ❌ Limited hardware offload simulation
- ❌ Can't test full DPU firmware

**Docker Compose for multiple DPUs:**
```yaml
# docker-compose.yml
version: '3.8'

services:
  dpu-1:
    image: dpu-simulator:latest
    container_name: dpu-1
    hostname: dpu-1
    privileged: true
    networks:
      mgmt:
        ipv4_address: 10.100.2.50
      data:
        ipv4_address: 192.168.1.11
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    volumes:
      - /lib/modules:/lib/modules:ro
    command: tail -f /dev/null

  dpu-2:
    image: dpu-simulator:latest
    container_name: dpu-2
    hostname: dpu-2
    privileged: true
    networks:
      mgmt:
        ipv4_address: 10.100.2.51
      data:
        ipv4_address: 192.168.1.12
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    volumes:
      - /lib/modules:/lib/modules:ro
    command: tail -f /dev/null

networks:
  mgmt:
    driver: bridge
    ipam:
      config:
        - subnet: 10.100.0.0/16
  
  data:
    driver: bridge
    ipam:
      config:
        - subnet: 192.168.1.0/24
```

---

### Option 3: VyOS Router (For Network Function Simulation)

**Pros:**
- ✅ Real routing/firewall capabilities
- ✅ VLAN/VRF support
- ✅ Low resource usage
- ✅ Good for testing network separation

**Cons:**
- ❌ Not a real DPU
- ❌ No OVS/hardware offload

**Use case:** Simulate network boundaries, VPN gateways, firewalls

---

## Lab Exercises

### Exercise 1: Physical Separation Testing

**Objective:** Verify that management and data networks are truly isolated.

**Setup:**
1. Create two OVS bridges in GNS3
2. Connect DPU VM with two interfaces
3. Configure IP addresses

**Steps:**

```bash
# On DPU-1
# Configure management interface (eth0 → oob_net0)
sudo ip addr add 10.100.2.50/16 dev eth0
sudo ip link set eth0 up
sudo ip route add default via 10.100.0.1 dev eth0

# Configure data interface (eth2 → p0)
sudo ip addr add 192.168.1.11/24 dev eth2
sudo ip link set eth2 up

# Verify separation - try to route between networks
ping -I eth0 192.168.1.12  # Should fail (no route)
ping -I eth2 10.100.2.51   # Should fail (no route)

# Management should only reach management
ping -I eth0 10.100.1.10   # K8s API - should work

# Data should only reach data
ping -I eth2 192.168.1.12  # Other DPU - should work
```

**Validation:**
```bash
# Check routing table
ip route show

# Expected output:
# 10.100.0.0/16 dev eth0 proto kernel scope link src 10.100.2.50
# 192.168.1.0/24 dev eth2 proto kernel scope link src 192.168.1.11
# default via 10.100.0.1 dev eth0  # Only default route via management

# Try to add route between networks (should be policy-blocked)
sudo ip route add 192.168.1.0/24 via 10.100.0.1 dev eth0
# This violates separation - should be prevented by firewall
```

---

### Exercise 2: VLAN Separation Testing

**Objective:** Test software-defined separation with VLANs and verify ACLs.

**Setup Cisco IOSv Switch:**
```
! Configure VLANs
enable
configure terminal

vlan 100
 name MANAGEMENT
vlan 200
 name DATA

! Configure trunk port to DPU
interface GigabitEthernet0/1
 description DPU-1
 switchport trunk encapsulation dot1q
 switchport mode trunk
 switchport trunk allowed vlan 100,200

! Configure management gateway
interface Vlan100
 ip address 10.100.0.1 255.255.0.0

! Configure data gateway
interface Vlan200
 ip address 192.168.1.1 255.255.255.0

! Block inter-VLAN routing
ip access-list extended BLOCK_CROSS_VLAN
 deny ip 10.100.0.0 0.0.255.255 192.168.1.0 0.0.0.255
 deny ip 192.168.1.0 0.0.0.255 10.100.0.0 0.0.255.255
 permit ip any any

interface Vlan100
 ip access-group BLOCK_CROSS_VLAN in
interface Vlan200
 ip access-group BLOCK_CROSS_VLAN in

end
write memory
```

**Configure DPU with VLAN subinterfaces:**
```bash
# On DPU-1
# Install VLAN support
sudo apt install vlan
sudo modprobe 8021q

# Create VLAN interfaces
sudo ip link add link eth0 name eth0.100 type vlan id 100
sudo ip link add link eth0 name eth0.200 type vlan id 200

# Assign IPs
sudo ip addr add 10.100.2.50/16 dev eth0.100
sudo ip addr add 192.168.1.11/24 dev eth0.200

# Bring up interfaces
sudo ip link set eth0 up
sudo ip link set eth0.100 up
sudo ip link set eth0.200 up

# Add routes
sudo ip route add 10.100.0.0/16 via 10.100.0.1 dev eth0.100
sudo ip route add 192.168.1.0/24 dev eth0.200
```

**Test VLAN isolation:**
```bash
# Test 1: Management VLAN can reach management
ping -I eth0.100 10.100.1.10  # K8s API - should work

# Test 2: Data VLAN can reach data
ping -I eth0.200 192.168.1.12  # Other DPU - should work

# Test 3: Cross-VLAN should be blocked
ping -I eth0.100 192.168.1.12  # Should fail (ACL blocks)
ping -I eth0.200 10.100.1.10   # Should fail (ACL blocks)

# Test 4: VLAN hopping attack
# Try to send double-tagged frame
sudo python3 << EOF
from scapy.all import *

# Attempt VLAN hopping (double tagging)
packet = Ether(dst="ff:ff:ff:ff:ff:ff") / \
         Dot1Q(vlan=100) / \
         Dot1Q(vlan=200) / \
         IP(dst="192.168.1.12") / \
         ICMP()

sendp(packet, iface="eth0", verbose=True)
EOF

# Expected: Switch should drop double-tagged frames
```

---

### Exercise 3: VXLAN Overlay Testing

**Objective:** Create VXLAN tunnels and test tenant isolation.

**Setup OVS on DPU-1:**
```bash
# Install and start OVS
sudo apt install openvswitch-switch openvswitch-common
sudo systemctl start openvswitch-switch

# Create OVS bridge
sudo ovs-vsctl add-br br-int

# Add VXLAN port for VNI 1000 (Customer A)
sudo ovs-vsctl add-port br-int vxlan1000 -- \
  set interface vxlan1000 type=vxlan \
  options:remote_ip=192.168.1.12 \
  options:key=1000 \
  options:local_ip=192.168.1.11

# Add VXLAN port for VNI 2000 (Customer B)
sudo ovs-vsctl add-port br-int vxlan2000 -- \
  set interface vxlan2000 type=vxlan \
  options:remote_ip=192.168.1.12 \
  options:key=2000 \
  options:local_ip=192.168.1.11

# Create internal ports for testing
sudo ovs-vsctl add-port br-int vnet1000 -- \
  set interface vnet1000 type=internal
sudo ip addr add 10.1.0.5/16 dev vnet1000
sudo ip link set vnet1000 up

sudo ovs-vsctl add-port br-int vnet2000 -- \
  set interface vnet2000 type=internal
sudo ip addr add 10.2.0.5/16 dev vnet2000
sudo ip link set vnet2000 up

# Configure OVS flows for VNI isolation
# VNI 1000 traffic stays in VNI 1000
sudo ovs-ofctl add-flow br-int \
  "table=0,priority=100,in_port=vnet1000,actions=set_field:1000->tun_id,output:vxlan1000"

# VNI 2000 traffic stays in VNI 2000
sudo ovs-ofctl add-flow br-int \
  "table=0,priority=100,in_port=vnet2000,actions=set_field:2000->tun_id,output:vxlan2000"

# Incoming VXLAN with VNI 1000 → vnet1000
sudo ovs-ofctl add-flow br-int \
  "table=0,priority=100,tun_id=1000,actions=output:vnet1000"

# Incoming VXLAN with VNI 2000 → vnet2000
sudo ovs-ofctl add-flow br-int \
  "table=0,priority=100,tun_id=2000,actions=output:vnet2000"
```

**Setup OVS on DPU-2 (mirror configuration):**
```bash
# Same OVS setup with different IPs
sudo ovs-vsctl add-br br-int

# VXLAN ports pointing back to DPU-1
sudo ovs-vsctl add-port br-int vxlan1000 -- \
  set interface vxlan1000 type=vxlan \
  options:remote_ip=192.168.1.11 \
  options:key=1000 \
  options:local_ip=192.168.1.12

sudo ovs-vsctl add-port br-int vxlan2000 -- \
  set interface vxlan2000 type=vxlan \
  options:remote_ip=192.168.1.11 \
  options:key=2000 \
  options:local_ip=192.168.1.12

# Internal test ports
sudo ovs-vsctl add-port br-int vnet1000 -- \
  set interface vnet1000 type=internal
sudo ip addr add 10.1.0.10/16 dev vnet1000
sudo ip link set vnet1000 up

sudo ovs-vsctl add-port br-int vnet2000 -- \
  set interface vnet2000 type=internal
sudo ip addr add 10.2.0.10/16 dev vnet2000
sudo ip link set vnet2000 up

# Same flow rules
```

**Test VXLAN connectivity and isolation:**
```bash
# On DPU-1
# Test 1: VNI 1000 can reach VNI 1000 on remote DPU
ping -I vnet1000 10.1.0.10  # Should work

# Test 2: VNI 2000 can reach VNI 2000 on remote DPU
ping -I vnet2000 10.2.0.10  # Should work

# Test 3: VNI 1000 CANNOT reach VNI 2000 (tenant isolation)
ping -I vnet1000 10.2.0.10  # Should fail

# Test 4: Capture VXLAN packets on underlay
sudo tcpdump -i eth2 -n udp port 4789 -v

# Expected output:
# IP 192.168.1.11.xxxxx > 192.168.1.12.4789: VXLAN, flags [I] (0x08), vni 1000
# IP 192.168.1.11.xxxxx > 192.168.1.12.4789: VXLAN, flags [I] (0x08), vni 2000

# Test 5: Verify OVS flows are hit
sudo ovs-ofctl dump-flows br-int

# Test 6: Verify management network is separate
ping -I eth0 10.100.2.51  # Management can reach other DPU management
# But management cannot reach VXLAN overlay IPs
ping -I eth0 10.1.0.10  # Should fail (different network)
```

---

### Exercise 4: Network Policy → DPU Rule Flow

**Objective:** Simulate complete hub-spoke flow from NetworkPolicy to hardware programming.

**Setup:**

1. **Hub cluster** (simulated with simple HTTP API)
2. **Customer K8s API** (k3s or kind)
3. **DPU agent** (Go program watching for CRs)

**Hub Controller Simulation:**
```python
#!/usr/bin/env python3
# hub-controller-sim.py
# Simulates hub controller writing DPURules to customer cluster

import requests
import json
from kubernetes import client, config

# Load customer cluster kubeconfig
config.load_kube_config(config_file="/path/to/customer-1.kubeconfig")
api = client.CustomObjectsApi()

# Define DPURule CR
dpu_rule = {
    "apiVersion": "dpu.io/v1",
    "kind": "DPURule",
    "metadata": {
        "name": "block-http-to-db",
        "namespace": "default"
    },
    "spec": {
        "rules": [
            {
                "vni": 1000,
                "match": {
                    "srcIP": "10.1.0.5/32",
                    "dstIP": "10.1.0.10/32",
                    "dstPort": 3306,
                    "protocol": "TCP"
                },
                "action": "deny"
            }
        ]
    }
}

# Create DPURule in customer cluster
try:
    api.create_namespaced_custom_object(
        group="dpu.io",
        version="v1",
        namespace="default",
        plural="dpurules",
        body=dpu_rule
    )
    print("✅ DPURule created in customer cluster")
except Exception as e:
    print(f"❌ Error: {e}")
```

**DPU Agent Simulation:**
```bash
#!/bin/bash
# dpu-agent-sim.sh
# Watches for DPURule CRs and programs OVS flows

KUBECONFIG="/path/to/customer-1.kubeconfig"
NAMESPACE="default"

# Watch for DPURule changes
kubectl --kubeconfig=$KUBECONFIG get dpurules -n $NAMESPACE --watch -o json | \
while read -r event; do
  echo "📡 Received event: $event"
  
  # Parse DPURule
  RULE_NAME=$(echo $event | jq -r '.metadata.name')
  VNI=$(echo $event | jq -r '.spec.rules[0].vni')
  SRC_IP=$(echo $event | jq -r '.spec.rules[0].match.srcIP')
  DST_IP=$(echo $event | jq -r '.spec.rules[0].match.dstIP')
  DST_PORT=$(echo $event | jq -r '.spec.rules[0].match.dstPort')
  ACTION=$(echo $event | jq -r '.spec.rules[0].action')
  
  echo "🔧 Programming OVS flow for rule: $RULE_NAME"
  
  # Program OVS flow
  sudo ovs-ofctl add-flow br-int \
    "table=0,priority=200,tun_id=$VNI,nw_src=$SRC_IP,nw_dst=$DST_IP,tp_dst=$DST_PORT,actions=drop"
  
  echo "✅ Flow programmed: Block $SRC_IP → $DST_IP:$DST_PORT on VNI $VNI"
done
```

**Test End-to-End Flow:**
```bash
# Terminal 1: Start DPU agent
./dpu-agent-sim.sh

# Terminal 2: Run hub controller (creates DPURule)
python3 hub-controller-sim.py

# Terminal 3: Test connectivity before and after rule
# Before: Should work
ping -I vnet1000 10.1.0.10
nc -zv 10.1.0.10 3306  # Should connect

# After rule is applied: Should be blocked
nc -zv 10.1.0.10 3306  # Should timeout

# Verify flow was added
sudo ovs-ofctl dump-flows br-int | grep "tp_dst=3306"
```

---

## Testing Scenarios

### Scenario 1: Security - VLAN Hopping Attack

**Objective:** Verify VLANs cannot be breached with double-tagging.

```bash
# On attacker node (connected to switch)
# Attempt 1: Double VLAN tagging
sudo python3 << EOF
from scapy.all import *

# Craft packet: outer VLAN 100, inner VLAN 200
packet = Ether(dst="ff:ff:ff:ff:ff:ff") / \
         Dot1Q(vlan=100) / \
         Dot1Q(vlan=200) / \
         IP(dst="192.168.1.11") / \
         ICMP()

sendp(packet, iface="eth0", count=10)
EOF

# Expected: Switch drops double-tagged frames
# Verify with tcpdump on target
sudo tcpdump -i eth0 -n vlan  # Should see no packets
```

### Scenario 2: Performance - Management Traffic Starvation

**Objective:** Verify data plane traffic doesn't starve management.

```bash
# Terminal 1: Saturate data plane with iperf
# On DPU-1 data interface
iperf3 -s -B 192.168.1.11

# On DPU-2 data interface
iperf3 -c 192.168.1.11 -B 192.168.1.12 -t 60 -b 10G

# Terminal 2: Monitor management latency
# On DPU-1 management interface
while true; do
  ping -I eth0 10.100.1.10 -c 1 | grep time=
  sleep 1
done

# Expected:
# - With physical separation: Latency stays constant (~1ms)
# - With VLAN separation on same NIC: Latency increases (5-20ms)
```

### Scenario 3: Failure Isolation

**Objective:** Verify management survives data plane failure.

```bash
# Simulate data plane switch failure
# On GNS3: Stop OVS-Data switch

# Verify management still operational
ping -I eth0 10.100.2.51  # Other DPU mgmt - should work
curl http://10.100.1.10:6443/healthz  # K8s API - should work

# Data plane should be down
ping -I eth2 192.168.1.12  # Should fail

# Verify DPU agent can still watch K8s API
kubectl --kubeconfig=customer-1.kubeconfig get dpurules --watch
# Should continue to receive events
```

---

## Troubleshooting

### Common Issues

**Issue 1: VXLAN tunnel not establishing**
```bash
# Check VXLAN port configuration
sudo ovs-vsctl show

# Verify underlay connectivity
ping -I eth2 192.168.1.12  # Must work first

# Check OVS logs
sudo journalctl -u openvswitch-switch -f

# Capture VXLAN packets
sudo tcpdump -i eth2 -n udp port 4789 -v

# Verify VNI is correct
sudo ovs-vsctl list interface vxlan1000 | grep options
```

**Issue 2: VLAN tagging not working**
```bash
# Check if 8021q module loaded
lsmod | grep 8021q
sudo modprobe 8021q

# Verify VLAN interface created
ip link show | grep eth0.100

# Check VLAN ID matches switch configuration
sudo tcpdump -i eth0 -e -n vlan  # Should see VLAN tags

# Verify switch trunk configuration
# On Cisco switch:
show interfaces GigabitEthernet0/1 trunk
```

**Issue 3: Management cannot reach K8s API**
```bash
# Check routing
ip route show
# Should have route to 10.100.0.0/16

# Verify interface is up
ip link show eth0

# Test gateway
ping 10.100.0.1

# Check firewall
sudo iptables -L -n -v

# DNS resolution
nslookup kubernetes.default.svc.cluster.local
```

**Issue 4: OVS flows not matching**
```bash
# Dump flows with stats
sudo ovs-ofctl dump-flows br-int

# Check packet counters (should increase)
# n_packets=0 means flow not hit

# Test with simple flow first
sudo ovs-ofctl add-flow br-int \
  "table=0,priority=100,icmp,actions=normal"

# Verify with ping
ping 10.1.0.10

# Check OVS flow syntax
sudo ovs-ofctl dump-flows br-int --names
```

---

## Performance Benchmarking

### Throughput Testing

```bash
# Test management network bandwidth
# On K8s API node
iperf3 -s -B 10.100.1.10

# On DPU management interface
iperf3 -c 10.100.1.10 -B 10.100.2.50 -t 30

# Test data plane bandwidth
# On DPU-2 data interface
iperf3 -s -B 192.168.1.12

# On DPU-1 data interface
iperf3 -c 192.168.1.12 -B 192.168.1.11 -t 30 -b 10G

# Expected results:
# - Physical separation: Full line rate (1Gbps mgmt, 10-100Gbps data)
# - VLAN separation: Shared bandwidth, some overhead (~5%)
```

### Latency Testing

```bash
# Measure management latency
ping -I eth0 10.100.1.10 -c 100 | tail -n 2

# Measure data plane latency
ping -I eth2 192.168.1.12 -c 100 | tail -n 2

# Measure VXLAN overlay latency
ping -I vnet1000 10.1.0.10 -c 100 | tail -n 2

# Expected:
# - Physical NICs: 0.5-1ms
# - VXLAN overlay: +0.2-0.5ms overhead
# - Cross-VLAN (should fail): N/A
```

---

## Saving and Exporting Lab

```bash
# Export GNS3 project
File → Export portable project
Name: dpu-multi-network-lab.gns3project
Include VM images: Yes

# Export as OVA for sharing
# Export individual VMs from GNS3 VM

# Save configurations
# On each switch/router:
write memory
copy running-config tftp://gns3-server/configs/

# Backup OVS configurations
sudo ovs-vsctl list-br > ovs-bridges.txt
sudo ovs-ofctl dump-flows br-int > ovs-flows.txt
```

---

## Next Steps

1. **Add BGP EVPN:**
   - Import FRRouting appliance
   - Configure spine-leaf topology
   - Test automatic VTEP discovery

2. **Add Kubernetes:**
   - Deploy k3s in customer cluster VMs
   - Deploy actual DPU agent as DaemonSet
   - Test real NetworkPolicy → DPURule flow

3. **Add Security Testing:**
   - Import Kali Linux appliance
   - Test penetration attempts
   - Verify ACLs and separation

4. **Add Monitoring:**
   - Deploy Prometheus in management network
   - Scrape metrics from DPU agents
   - Visualize with Grafana

For detailed network topology options, see [multi-cluster-network-topology.md](multi-cluster-network-topology.md).

For Kubernetes image building and controllers, see [kubernetes-image.md](../kubernetes/kubernetes-image.md).
