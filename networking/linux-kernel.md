# Linux Kernel Networking

## Overview

The Linux networking stack is a layered architecture implementing the TCP/IP model with extensive performance optimizations. This guide covers the essential components, data flow, and key subsystems.

---

## Architecture Layers

```
┌─────────────────────────────────────┐
│ User Space                          │
│ (Applications)                      │
└─────────────────────────────────────┘
            ↓↑ System calls
┌─────────────────────────────────────┐
│ Socket Layer (L5)                   │
│ • BSD socket API                    │
│ • socket(), send(), recv()          │
└─────────────────────────────────────┘
            ↓↑
┌─────────────────────────────────────┐
│ Transport Layer (L4)                │
│ • TCP: Reliable, ordered, streams   │
│ • UDP: Fast, connectionless         │
└─────────────────────────────────────┘
            ↓↑
┌─────────────────────────────────────┐
│ Network Layer (L3)                  │
│ • IP: Routing, fragmentation        │
│ • Netfilter: Firewall, NAT          │
└─────────────────────────────────────┘
            ↓↑
┌─────────────────────────────────────┐
│ Link Layer (L2)                     │
│ • Ethernet: Frame handling          │
│ • ARP: MAC address resolution       │
│ • Bridge, VLAN, bonding             │
└─────────────────────────────────────┘
            ↓↑
┌─────────────────────────────────────┐
│ Network Device Layer (L1/L2)        │
│ • Drivers, net_device struct        │
│ • NAPI: Interrupt mitigation        │
└─────────────────────────────────────┘
            ↓↑
┌─────────────────────────────────────┐
│ Hardware (NIC)                      │
└─────────────────────────────────────┘
```

---

## Key Data Structures

### sk_buff (Socket Buffer)

The fundamental packet structure used throughout the stack:

```c
struct sk_buff {
    struct sk_buff *next, *prev;    // Linked list
    struct sock *sk;                 // Owning socket
    struct net_device *dev;          // Network device
    
    unsigned char *head;             // Start of allocated buffer
    unsigned char *data;             // Start of packet data
    unsigned char *tail;             // End of packet data
    unsigned char *end;              // End of allocated buffer
    
    unsigned int len;                // Length of data
    __u16 protocol;                  // Protocol (e.g., ETH_P_IP)
};
```

**Key operations:**
- `skb_put()`: Add data to tail
- `skb_push()`: Add data to head (e.g., add L2 header)
- `skb_pull()`: Remove data from head (e.g., strip L2 header)

### net_device

Represents a network interface:

```c
struct net_device {
    char name[IFNAMSIZ];             // e.g., "eth0"
    unsigned int mtu;                // Maximum Transmission Unit
    unsigned int flags;              // IFF_UP, IFF_BROADCAST, etc.
    
    struct net_device_ops *netdev_ops;  // Driver operations
    struct ethtool_ops *ethtool_ops;    // Ethtool support
    
    // Statistics
    struct net_device_stats stats;
};
```

---

## Packet Flow

### RX (Receive) Path

```
Hardware NIC
    ↓ DMA packet to memory
[1] Hardware Interrupt
    ↓
[2] Driver: Disable interrupts, schedule NAPI
    ↓
[3] NAPI Poll (softirq)
    • Driver allocates sk_buff
    • Copy packet data to sk_buff
    • Process up to "budget" packets (e.g., 64)
    ↓
[4] netif_receive_skb()
    • L2 processing (Ethernet)
    • Deliver to protocol handler
    ↓
[5] IP Layer
    • Routing decision: local or forward?
    • Netfilter PREROUTING hook
    ↓
[6] TCP/UDP Layer
    • Checksum validation
    • Connection lookup
    • Add to socket receive queue
    ↓
[7] Socket Layer
    • Wake up waiting process
    ↓
[8] User Space
    • Application calls recv()
    • Copy data to user buffer
```

**Performance optimizations:**
- **NAPI**: Polling instead of interrupts under load
- **GRO (Generic Receive Offload)**: Aggregate packets before processing
- **RPS/RFS**: Distribute packets across CPUs

### TX (Transmit) Path

```
User Space
    ↓ Application calls send()
[1] Socket Layer
    • Copy data to sk_buff
    ↓
[2] TCP/UDP Layer
    • Add L4 header
    • Calculate checksum
    ↓
[3] IP Layer
    • Add IP header
    • Routing lookup
    • Netfilter OUTPUT hook
    • Fragmentation if needed
    ↓
[4] ARP (if needed)
    • Resolve dest IP → MAC address
    ↓
[5] Link Layer
    • Add Ethernet header
    ↓
[6] Queueing Discipline (qdisc)
    • Traffic shaping
    • Priority queuing
    ↓
[7] Driver
    • Setup DMA
    • Write to TX ring
    • Notify hardware (doorbell)
    ↓
Hardware NIC
    • DMA packet from memory
    • Transmit on wire
```

**Performance optimizations:**
- **GSO (Generic Segmentation Offload)**: Delay segmentation until NIC
- **TSO (TCP Segmentation Offload)**: NIC segments large TCP packets
- **Checksum offload**: NIC calculates checksums

---

## Key Subsystems

### 1. Netfilter / iptables

**Purpose:** Packet filtering, NAT, connection tracking

**Hook points:**
```
Packet arrives
    ↓
PREROUTING (before routing decision)
    ↓
    ├─→ Local delivery → INPUT → Local process
    │
    └─→ Forwarding → FORWARD → POSTROUTING → Out
    
Local process sends packet
    ↓
OUTPUT → POSTROUTING → Out
```

**Common uses:**
```bash
# Drop all incoming SSH
iptables -A INPUT -p tcp --dport <ssh_port> -j DROP

# NAT (SNAT) for outgoing packets
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Port forwarding (DNAT)
# Port forward: External port → Internal service
iptables -t nat -A PREROUTING -p tcp --dport <external_port> -j DNAT --to-destination <internal_ip>:<internal_port>
```

### 2. Traffic Control (tc)

**Purpose:** QoS, traffic shaping, rate limiting

**Components:**
- **Qdisc (Queueing Discipline)**: How packets are queued
- **Class**: Hierarchical grouping
- **Filter**: Packet classification

**Example: Rate limit to 1 Mbps**
```bash
tc qdisc add dev eth0 root tbf rate 1mbit burst 32kbit latency 400ms
```

**Example: Priority queueing**
```bash
# High priority for SSH, low for bulk traffic
tc qdisc add dev eth0 root handle 1: prio bands 3
tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip dport <service_port> 0xffff flowid 1:1
```

### 3. Network Namespaces

**Purpose:** Network isolation (basis for containers)

**Each namespace has:**
- Separate network interfaces
- Independent routing tables
- Isolated firewall rules
- Separate ARP tables

**Example:**
```bash
# Create namespace
ip netns add myns

# Add veth pair
ip link add veth0 type veth peer name veth1
ip link set veth1 netns myns

# Configure
ip addr add 10.0.0.1/24 dev veth0
ip netns exec myns ip addr add 10.0.0.2/24 dev veth1
ip link set veth0 up
ip netns exec myns ip link set veth1 up

# Test
ip netns exec myns ping 10.0.0.1
```

**Container networking:**
```
Host:        veth0 ←→ Bridge (docker0)
Container:   veth1 (in namespace) → eth0
```

### 4. XDP (eXpress Data Path)

**Purpose:** Ultra-fast packet processing using eBPF

**Hook point:** Before `sk_buff` allocation (fastest possible)

**Actions:**
- `XDP_DROP`: Drop packet (DDoS mitigation)
- `XDP_PASS`: Continue to normal stack
- `XDP_TX`: Transmit back out same interface
- `XDP_REDIRECT`: Send to different interface

**Example: Drop all TCP SYN packets**
```c
SEC("xdp")
int xdp_drop_syn(struct xdp_md *ctx) {
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;
    
    if (eth->h_proto != htons(ETH_P_IP))
        return XDP_PASS;
    
    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;
    
    if (ip->protocol != IPPROTO_TCP)
        return XDP_PASS;
    
    struct tcphdr *tcp = (void *)(ip + 1);
    if ((void *)(tcp + 1) > data_end)
        return XDP_PASS;
    
    if (tcp->syn && !tcp->ack)
        return XDP_DROP;  // Drop SYN packets
    
    return XDP_PASS;
}
```

**Performance:** Tens of Mpps on single core (significant improvement vs normal stack)

---

## Performance Features

### NAPI (New API)

**Problem:** Interrupts overwhelm CPU under high packet rate  
**Solution:** Switch to polling when busy

```
Low load:    Interrupt-driven (low latency)
High load:   Polling (high throughput, lower CPU)
```

**How it works:**
1. Packet arrives → interrupt
2. Driver disables interrupts, schedules NAPI poll
3. Poll processes up to "budget" packets (e.g., 64)
4. If budget exhausted, schedule next poll (stay in polling mode)
5. If fewer than budget, re-enable interrupts

### GRO/GSO

**GRO (Generic Receive Offload):**
- Aggregates small packets into larger ones before stack processing
- Example: 10× 1500-byte packets → 1× 15000-byte super-packet
- Reduces per-packet overhead (10× fewer trips through stack)

**GSO (Generic Segmentation Offload):**
- Delays segmentation until transmission
- Example: Application sends 64KB → kernel creates 1× 64KB packet → driver segments to 43× 1500-byte packets
- Reduces per-packet overhead in kernel

### RSS/RPS/RFS

**RSS (Receive Side Scaling) - Hardware:**
- NIC distributes packets across multiple RX queues
- Each queue has dedicated IRQ and CPU
- Hash on (src IP, dst IP, src port, dst port) → queue

**RPS (Receive Packet Steering) - Software:**
- Software equivalent of RSS
- Used when NIC doesn't support RSS

**RFS (Receive Flow Steering):**
- Directs packets to CPU where application is running
- Improves cache locality

---

## Monitoring and Debugging

### Essential Tools

**1. Monitor connections:**
```bash
ss -tunap                    # All TCP/UDP connections
ss -s                        # Summary statistics
netstat -s                   # Protocol statistics
```

**2. Interface statistics:**
```bash
ip -s link show eth0         # RX/TX packets, errors, drops
ethtool -S eth0              # Driver-level statistics
cat /proc/net/dev            # All interfaces
```

**3. Packet capture:**
```bash
tcpdump -i eth0 -n           # Capture on eth0
tcpdump 'tcp port <http_port>'   # Filter HTTP traffic
tcpdump -w capture.pcap      # Save to file
```

**4. Routing:**
```bash
ip route show                # Routing table
ip route get 8.8.8.8         # Route for specific destination
```

**5. ARP cache:**
```bash
ip neigh show                # ARP/NDP cache
```

### Performance Analysis

**1. CPU usage per softirq:**
```bash
cat /proc/softirqs           # Softirq counters per CPU
```

**2. Network stack performance:**
```bash
perf record -e net:*         # Record network events
perf report                  # Analyze
```

**3. eBPF tracing:**
```bash
# Trace TCP connections
bpftrace -e 'tracepoint:sock:inet_sock_set_state { printf("%s → %s\n", comm, args->newstate); }'

# Count packets by protocol
bpftrace -e 'tracepoint:net:netif_receive_skb { @[args->protocol] = count(); }'
```

### /proc and /sys Interfaces

**Key files:**
```bash
/proc/net/dev                # Interface statistics
/proc/net/tcp                # TCP connections
/proc/net/udp                # UDP sockets
/proc/sys/net/ipv4/          # IPv4 tuning parameters
/proc/sys/net/core/          # Core network parameters
```

**Common tuning:**
```bash
# Increase RX ring buffer
echo <appropriate_size> > /proc/sys/net/core/netdev_max_backlog

# TCP congestion control
echo bbr > /proc/sys/net/ipv4/tcp_congestion_control

# TCP window scaling
echo 1 > /proc/sys/net/ipv4/tcp_window_scaling
```

---

## Common Patterns

### Bridge (Software Switch)

```bash
# Create bridge
ip link add br0 type bridge

# Add interfaces
ip link set eth0 master br0
ip link set eth1 master br0

# Bring up
ip link set br0 up
ip link set eth0 up
ip link set eth1 up
```

**Use case:** Connect VMs/containers to network

### VLAN

```bash
# Create VLAN interface
ip link add link eth0 name eth0.100 type vlan id 100
ip addr add 192.168.100.1/24 dev eth0.100
ip link set eth0.100 up
```

**Use case:** Network segmentation

### Bonding (Link Aggregation)

```bash
# Create bond
ip link add bond0 type bond mode 802.3ad
ip link set eth0 master bond0
ip link set eth1 master bond0

# Configure
ip addr add 192.168.1.1/24 dev bond0
ip link set bond0 up
```

**Modes:**
- `balance-rr`: Round-robin (load balancing)
- `active-backup`: One active, others standby (failover)
- `802.3ad`: LACP (requires switch support)

---

## Key Takeaways

1. **sk_buff** is the universal packet structure
2. **NAPI** switches between interrupts (low load) and polling (high load)
3. **Netfilter** provides firewall/NAT via hooks at 5 points
4. **XDP** processes packets before sk_buff allocation (fastest)
5. **Network namespaces** isolate network stacks (containers)
6. **GRO/GSO** aggregate/defer segmentation for performance
7. **Traffic Control (tc)** provides QoS and rate limiting

---

## Resources

- [Linux Kernel Networking Documentation](https://www.kernel.org/doc/html/latest/networking/index.html)
- [Understanding Linux Network Internals](https://www.oreilly.com/library/view/understanding-linux-network/0596002556/) (book)
- [XDP Tutorial](https://github.com/xdp-project/xdp-tutorial)
- [eBPF and XDP Reference](https://ebpf.io/)
