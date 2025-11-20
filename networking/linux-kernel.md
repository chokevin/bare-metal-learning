# Linux Kernel Networking

## Overview

The Linux kernel networking stack is a sophisticated, layered architecture that handles all network communication. It implements the standard OSI and TCP/IP models while providing extensive flexibility and performance optimizations.

## Architecture Layers

### 1. Network Device Layer (L1/L2)
- **Network Device Drivers**: Interface with physical/virtual NICs
- **Net Device Structure**: `struct net_device` represents network interfaces
- **Device Operations**: `net_device_ops` defines operations like transmit, configuration
- **NAPI (New API)**: Interrupt mitigation and polling mechanism for high-performance packet processing

### 2. Link Layer (L2)
- **Ethernet Frame Handling**: Processing 802.3 frames
- **ARP (Address Resolution Protocol)**: MAC address resolution
- **Bridge Support**: Software bridging between network segments
- **VLAN Support**: 802.1Q VLAN tagging and filtering
- **Bonding**: Link aggregation and failover

### 3. Network Layer (L3)
- **IPv4/IPv6 Processing**: Core IP protocol implementation
- **Routing**: FIB (Forwarding Information Base) and routing table management
- **Netfilter/iptables**: Packet filtering, NAT, and connection tracking
- **IPsec**: Encrypted tunnel support
- **Neighbor Subsystem**: ARP/NDP caching and management

### 4. Transport Layer (L4)
- **TCP**: Connection-oriented, reliable transmission with congestion control
- **UDP**: Connectionless, lightweight datagram protocol
- **SCTP**: Multi-homing and multi-streaming transport
- **Socket Layer**: BSD socket API implementation

### 5. Application Interface
- **Socket API**: User-space interface for network communication
- **System Calls**: `socket()`, `bind()`, `connect()`, `send()`, `recv()`, etc.
- **Socket Buffers**: `sk_buff` structure for packet data management

## Key Data Structures

### Socket Buffer (sk_buff)
The fundamental structure for packet data:
```c
struct sk_buff {
    struct sk_buff *next;
    struct sk_buff *prev;
    struct sock *sk;
    struct net_device *dev;
    unsigned char *head;
    unsigned char *data;
    unsigned char *tail;
    unsigned char *end;
    // ... many more fields
};
```

### Net Device
Represents a network interface:
```c
struct net_device {
    char name[IFNAMSIZ];
    unsigned long state;
    struct net_device_ops *netdev_ops;
    struct ethtool_ops *ethtool_ops;
    unsigned int flags;
    unsigned int mtu;
    // ... extensive configuration
};
```

## Packet Flow

### RX (Receive) Path
1. **Hardware Interrupt**: NIC receives packet, triggers interrupt
2. **Driver Processing**: Driver handles interrupt, allocates `sk_buff`
3. **NAPI Poll**: Softirq-based polling for batch processing
4. **Protocol Processing**: 
   - L2: Ethernet header processing
   - L3: IP layer routing decision
   - L4: TCP/UDP processing
5. **Socket Delivery**: Data copied to socket receive buffer
6. **User-space**: Application reads data via system call

### TX (Transmit) Path
1. **User-space**: Application sends data via system call
2. **Socket Layer**: Data copied to socket send buffer
3. **Protocol Stack**:
   - L4: TCP/UDP header construction
   - L3: IP header, routing lookup
   - L2: Ethernet header, ARP resolution
4. **Queueing Discipline (qdisc)**: Traffic shaping and QoS
5. **Driver Transmission**: DMA setup and device notification
6. **Hardware**: Physical transmission on wire

## Key Subsystems

### Netfilter
- Hooks at various points in packet processing
- Enables iptables, connection tracking, NAT
- Hooks: PREROUTING, INPUT, FORWARD, OUTPUT, POSTROUTING

### Traffic Control (TC)
- **Queueing Disciplines (qdiscs)**: FIFO, priority queuing, HTB, CBQ
- **Traffic Shaping**: Rate limiting and bandwidth management
- **Classification**: Packet filtering and marking
- **Policing**: Dropping or marking excess traffic

### Network Namespaces
- Isolation of network stack instances
- Separate routing tables, firewall rules, network devices
- Container networking foundation

### XDP (eXpress Data Path)
- eBPF-based programmable packet processing
- Processes packets before `sk_buff` allocation
- Ultra-low latency, high-performance use cases
- Actions: DROP, PASS, TX, REDIRECT

## Performance Features

### NAPI (New API)
- Interrupt mitigation through polling
- Reduces interrupt overhead under high load
- Budget-based processing

### GRO/GSO (Generic Receive/Segmentation Offload)
- **GRO**: Aggregates received packets before protocol processing
- **GSO**: Defers segmentation until transmission
- Reduces per-packet overhead

### RSS/RPS/RFS
- **RSS (Receive Side Scaling)**: Hardware-based packet distribution across CPUs
- **RPS (Receive Packet Steering)**: Software-based packet distribution
- **RFS (Receive Flow Steering)**: Flow-aware CPU assignment

### Zero-copy
- `sendfile()`, `splice()`: Avoid data copying between kernel/user space
- AF_XDP sockets: Direct user-space packet processing

## Monitoring and Debugging

### Tools
- **netstat/ss**: Socket and connection statistics
- **ip**: Network configuration and routing
- **tcpdump**: Packet capture and analysis
- **ethtool**: NIC statistics and configuration
- **perf**: Performance profiling
- **bpftrace/bcc**: eBPF-based tracing

### /proc and /sys Interfaces
- `/proc/net/*`: Network statistics and state
- `/sys/class/net/`: Network device information
- `/proc/sys/net/`: Tunable kernel parameters

### Debugging Techniques
- **printk/dmesg**: Kernel logging
- **tracepoints**: Low-overhead event tracing
- **kprobes**: Dynamic kernel instrumentation
- **eBPF programs**: Programmable observability

## Configuration and Tuning

### Key sysctl Parameters
- `net.core.rmem_max/wmem_max`: Socket buffer sizes
- `net.ipv4.tcp_congestion_control`: TCP congestion algorithm
- `net.ipv4.tcp_rmem/tcp_wmem`: TCP buffer tuning
- `net.core.netdev_max_backlog`: Input queue size
- `net.ipv4.ip_forward`: IP forwarding enable/disable

### Network Stack Bypassing
- **DPDK (Data Plane Development Kit)**: Userspace polling mode drivers
- **AF_XDP**: Kernel bypass with XDP
- **netmap**: High-speed packet I/O framework

## Modern Developments

### eBPF Integration
- Programmable packet processing and filtering
- Traffic control, socket operations, XDP
- Observability and security enforcement

### Hardware Offloading
- TSO (TCP Segmentation Offload)
- Checksum offload
- RSS (Receive Side Scaling)
- SR-IOV (Single Root I/O Virtualization)

### Container Networking
- veth pairs for namespace connectivity
- Bridge and OVS integration
- CNI (Container Network Interface) plugins
- eBPF-based solutions (Cilium)

## Custom Ethernet Devices and Drivers

### Why Custom Drivers are Necessary

Vendors like Mellanox (NVIDIA), Intel, Broadcom, and others develop custom drivers rather than using generic kernel drivers for several critical reasons:

#### 1. **Hardware-Specific Features**
Custom NICs have proprietary capabilities that generic drivers cannot support:
- **Advanced Offload Engines**: TOE (TCP Offload Engine), RDMA, iSCSI offload
- **Hardware Acceleration**: Crypto engines, compression, packet processing
- **Programmable Pipelines**: Match-action tables, custom packet parsing
- **Specialized DMA Engines**: Multi-queue architectures with thousands of queues
- **Custom Memory Models**: On-card memory, direct GPU memory access

#### 2. **Performance Optimization**
Generic drivers are designed for broad compatibility, not peak performance:
- **Zero-touch RX**: Packet delivery with minimal CPU involvement
- **Hardware Queue Management**: Direct queue manipulation, bypassing kernel layers
- **Interrupt Coalescing**: Vendor-specific algorithms for optimal latency/throughput balance
- **Cache Optimization**: Memory layouts optimized for specific hardware architecture
- **Polling vs. Interrupt**: Fine-grained control over NAPI behavior

#### 3. **RDMA and High-Performance Networking**
Modern datacenter NICs are not just Ethernet devices:
- **RDMA (Remote Direct Memory Access)**: Bypass kernel entirely for memory-to-memory transfers
  - InfiniBand protocol support
  - RoCE (RDMA over Converged Ethernet)
  - iWARP (Internet Wide Area RDMA Protocol)
- **Kernel Bypass**: User-space networking with `libibverbs`
- **Ultra-low Latency**: Sub-microsecond message passing
- **GPU Direct**: Direct data transfer between NIC and GPU memory (GPUDirect RDMA)

#### 4. **Advanced Traffic Management**
Enterprise features requiring hardware-driver co-design:
- **SR-IOV (Single Root I/O Virtualization)**: Hardware-level VM isolation
- **VF (Virtual Function) Management**: Creating and configuring hundreds of virtual NICs
- **DCB (Data Center Bridging)**: Priority-based flow control, ETS (Enhanced Transmission Selection)
- **QoS Hardware Enforcement**: Precise bandwidth allocation per flow
- **Flow Steering**: Programmable packet distribution to specific queues/CPUs

#### 5. **Firmware Interaction**
Complex NICs have sophisticated firmware requiring custom management:
- **Firmware Updates**: In-field upgrades, rollback mechanisms
- **Configuration Management**: Hardware parameters not exposed via standard interfaces
- **Telemetry Collection**: Hardware counters, error rates, temperature sensors
- **Health Monitoring**: Predictive failure detection, error recovery
- **Feature Enablement**: Activating licensed capabilities

### Case Study: Mellanox (NVIDIA ConnectX)

#### Driver Components
Mellanox NICs use multiple kernel modules:

**mlx5_core**: Core driver for ConnectX-4/5/6/7 adapters
```
- Hardware abstraction layer
- Firmware command interface
- Queue management
- SR-IOV support
- Health monitoring
```

**mlx5_ib**: RDMA/InfiniBand support via kernel Verbs
```
- RDMA Connection Manager (RDMA-CM)
- Memory registration and protection
- Queue Pair (QP) management
- Completion Queue (CQ) handling
```

**mlx5_en**: Ethernet networking support
```
- Standard netdev interface
- Enhanced packet processing
- XDP integration
- TLS offload support
```

#### Unique Hardware Capabilities

**1. ConnectX Architecture**
- **WQE (Work Queue Elements)**: Hardware-native packet descriptors
- **CQE (Completion Queue Elements)**: Efficient completion notification
- **EQ (Event Queues)**: Asynchronous event delivery
- **UAR (User Access Region)**: Direct user-space hardware access for kernel bypass

**2. Hardware Offloads**
- **Stateless Offloads**: Checksum, TSO, LRO/GRO
- **Stateful Offloads**: 
  - TLS encryption/decryption in hardware (kTLS)
  - IPsec crypto offload
  - Connection tracking offload
- **Packet Pacing**: Precise transmission rate control per flow
- **NVGRE/VXLAN**: Overlay network offload

**3. RoCE (RDMA over Converged Ethernet)**
- **Lossless Ethernet**: PFC (Priority Flow Control) integration
- **ECN (Explicit Congestion Notification)**: Congestion management
- **QoS Classes**: 8+ priority levels with strict scheduling
- **DCQCN**: Datacenter QCN for congestion control

**4. GPUDirect and Accelerator Integration**
- **Direct GPU Memory Access**: NIC can DMA directly to/from GPU memory
- **Peer-to-Peer PCIe**: Bypasses CPU and system memory
- **DPU Integration**: ConnectX as part of BlueField DPU (Data Processing Unit)

### Why Generic Drivers Fall Short

#### Limited Feature Exposure
Generic drivers like `e1000e`, `igb`, or `r8169` provide:
- Basic send/receive functionality
- Standard ethtool interface
- Simple interrupt handling
- Basic offload support (TSO, checksum)

They **cannot** provide:
- Multi-protocol support (Ethernet + InfiniBand)
- RDMA capabilities
- Complex SR-IOV management
- Hardware flow steering
- Advanced telemetry
- Firmware management

#### Performance Gap
Generic drivers impose overhead:
- Extra memory copies
- Less efficient descriptor management
- Suboptimal interrupt handling
- No support for hardware-specific optimizations
- Cannot utilize vendor-specific DMA features

#### Feature Parity
A generic driver would need to:
1. Support lowest common denominator features
2. Add abstraction layers (performance cost)
3. Handle quirks of hundreds of NIC models
4. Maintain compatibility across kernel versions

### Driver Architecture Comparison

#### Standard Linux Driver (e.g., e1000e)
```
Application
    ↓
Socket Layer
    ↓
TCP/IP Stack
    ↓
Net Device Layer (sk_buff)
    ↓
e1000e Driver (simple TX/RX)
    ↓
Hardware (basic NIC)
```

#### Advanced Vendor Driver (e.g., Mellanox mlx5)
```
Standard Path:                    RDMA Path:
Application                       RDMA Application
    ↓                                 ↓
Socket Layer                      libibverbs (userspace)
    ↓                                 ↓
TCP/IP Stack                      mlx5_ib (kernel verbs)
    ↓                                 ↓
mlx5_en (netdev)                  mlx5_core
    ↓                                 ↓
mlx5_core ←───────────────────────────┘
    ↓
ConnectX Hardware
```

### Integration with Linux Kernel

Despite custom drivers, vendors integrate with kernel subsystems:

#### Standard Interfaces Implemented
- **netdev**: Standard network device registration
- **ethtool**: Basic NIC configuration and statistics
- **devlink**: Hardware resource management
- **switchdev**: Hardware switching offload
- **XDP**: eBPF packet processing
- **TC offload**: Hardware traffic control

#### Extended Interfaces
- **RDMA subsystem**: `/sys/class/infiniband/`
- **SR-IOV sysfs**: Virtual function management
- **PTP (Precision Time Protocol)**: Hardware timestamping
- **netlink**: Extended configuration APIs

### When to Use Custom vs. Generic Drivers

#### Use Vendor Driver When:
- Need RDMA/InfiniBand support
- Require ultra-low latency (< 10 microseconds)
- Using SR-IOV for virtualization
- Need hardware offloads (TLS, IPsec, NVGRE/VXLAN)
- Running HPC, AI/ML workloads with GPUDirect
- Require advanced telemetry and management

#### Generic Driver Sufficient When:
- Basic Ethernet connectivity needed
- Performance requirements are moderate (< 10 Gbps sustained)
- No special features required
- Consumer/desktop use cases
- Simple server deployments

### Performance Examples

#### Throughput
- Generic driver: 10-40 Gbps, ~10-20% CPU utilization
- Mellanox mlx5: 100-400 Gbps, ~5-10% CPU utilization
- RDMA (mlx5_ib): 100-200 Gbps, ~1-2% CPU utilization

#### Latency
- Generic driver: 20-50 microseconds
- Optimized vendor driver: 5-10 microseconds
- RDMA: 1-2 microseconds (sub-microsecond possible)

### Future Trends

#### Programmable NICs (SmartNICs/DPUs)
- **On-card Processing**: ARM/RISC-V cores on NIC
- **P4 Programming**: Custom packet processing pipelines
- **eBPF Offload**: Hardware acceleration of eBPF programs
- **Inline Services**: Encryption, firewall, load balancing in hardware

#### Vendor Examples
- **NVIDIA BlueField**: DPU with ConnectX + ARM cores
- **Intel IPU**: Infrastructure Processing Unit
- **AMD Pensando**: Programmable services platform
- **Broadcom Stingray**: SmartNIC solutions

These advanced devices make custom drivers even more essential, as they're essentially distributed systems requiring sophisticated software coordination.

## Network Driver Interaction Levels by Expertise

### Level 1: User/Operator (No Driver Interaction)
**What You Use:**
- Standard Linux networking tools and APIs
- No direct driver interaction

**Interfaces:**
```bash
# Socket programming (application layer)
socket(AF_INET6, SOCK_STREAM, 0)
bind(), connect(), send(), recv()

# Standard utilities
ip link set eth0 up
ip addr add 2001:db8::1/64 dev eth0
ethtool -S eth0  # Statistics
tcpdump -i eth0  # Packet capture
```

**Your Role:** Configure network settings, monitor performance, troubleshoot connectivity

**Driver Dependency:** 100% rely on vendor drivers working correctly

---

### Level 2: DPDK/Userspace Acceleration (Moderate)
**What You Use:**
- Poll Mode Drivers (PMDs) for userspace packet processing
- Bypass kernel, but use existing DPDK libraries

**Interfaces:**
```c
#include <rte_ethdev.h>
#include <rte_eal.h>

// Initialize DPDK
rte_eal_init(argc, argv);

// Configure device
struct rte_eth_conf port_conf = {
    .rxmode = {
        .mq_mode = RTE_ETH_MQ_RX_RSS,  // Multi-queue RSS
    },
};
rte_eth_dev_configure(port_id, nb_rx_queues, nb_tx_queues, &port_conf);

// Setup RX/TX queues
rte_eth_rx_queue_setup(port_id, queue_id, nb_rxd, socket_id, &rx_conf, mbuf_pool);
rte_eth_tx_queue_setup(port_id, queue_id, nb_txd, socket_id, &tx_conf);

// Start device
rte_eth_dev_start(port_id);

// Poll for packets (zero-copy)
struct rte_mbuf *pkts[32];
uint16_t nb_rx = rte_eth_rx_burst(port_id, queue_id, pkts, 32);

// Process packets in userspace
for (int i = 0; i < nb_rx; i++) {
    // Your packet processing logic
}

// Send packets
rte_eth_tx_burst(port_id, queue_id, pkts, nb_rx);
```

**Your Role:** 
- Write userspace packet processing logic
- Manage packet buffers and queues
- Handle flow control and backpressure

**Driver Interaction:**
- DPDK PMD abstracts hardware details
- Still don't write kernel driver code
- Configure hardware features via DPDK API

**Complexity:** Medium - C programming, packet processing knowledge

---

### Level 3: DOCA/SmartNIC Programming (Advanced)
**What You Use:**
- Hardware offload APIs for DPU/SmartNIC
- Direct hardware flow table programming
- Still userspace, but closer to hardware

**Interfaces:**
```c
#include <doca_flow.h>
#include <doca_dma.h>

// Initialize DOCA
struct doca_flow_cfg cfg = {
    .queues = 8,
    .mode = DOCA_FLOW_MODE_SWITCH,
    .resource.nb_counters = 1024,
};
doca_flow_init(&cfg);

// Create hardware pipeline
struct doca_flow_match match = {
    .outer.l3_type = DOCA_FLOW_L3_TYPE_IP6,  // IPv6 matching
    .outer.ip6.dst_ip = {0xFF, 0xFF, ...},   // Match on IPv6 dest
    .outer.tcp.l4_port.dst_port = 0xFFFF,
};

struct doca_flow_actions actions = {
    .outer.ip6.dst_ip = {...},  // DNAT rewrite
    .decap = true,              // VXLAN decap
    .encap_type = DOCA_FLOW_RESOURCE_TYPE_ENCAP,
};

struct doca_flow_fwd fwd = {
    .type = DOCA_FLOW_FWD_PORT,
    .port_id = 1,
};

// Install flow in hardware
struct doca_flow_pipe *pipe;
doca_flow_pipe_create(&pipe_cfg, &fwd, NULL, &pipe);

struct doca_flow_pipe_entry *entry;
doca_flow_pipe_add_entry(0, pipe, &match, &actions, NULL, NULL, 0, NULL, &entry);

// Hardware now processes matching packets automatically
// No per-packet CPU involvement!

// Zero-copy DMA to GPU
struct doca_dma_job_infos dma_job = {
    .src_addr = packet_buffer,
    .dst_addr = gpu_memory_addr,
    .length = packet_len,
};
doca_dma_submit_job(&dma_job);
```

**Your Role:**
- Design hardware flow pipelines
- Manage hardware resources (flow tables, meters, counters)
- Integrate with control plane (Kubernetes, OVN)
- Handle flow aging and updates

**Driver Interaction:**
- DOCA libraries abstract register-level details
- Program hardware via vendor SDK
- No kernel module modification

**Complexity:** High - hardware architecture knowledge, flow-based processing

---

### Level 4: Kernel Driver Development (Expert)
**What You Write:**
- Actual kernel modules (`.ko` files)
- Direct hardware register access
- Integration with kernel networking stack

**Interfaces:**

**A. Basic Network Device Registration**
```c
#include <linux/netdevice.h>
#include <linux/etherdevice.h>

// Define your device structure
struct my_nic_priv {
    void __iomem *hw_addr;  // MMIO registers
    struct napi_struct napi;
    dma_addr_t rx_ring_dma;
    // Your hardware state
};

// Net device operations
static const struct net_device_ops my_nic_netdev_ops = {
    .ndo_open = my_nic_open,
    .ndo_stop = my_nic_stop,
    .ndo_start_xmit = my_nic_xmit,
    .ndo_set_mac_address = my_nic_set_mac,
    .ndo_validate_addr = eth_validate_addr,
    .ndo_do_ioctl = my_nic_ioctl,
    .ndo_change_mtu = my_nic_change_mtu,
    .ndo_get_stats64 = my_nic_get_stats,
};

// Device initialization
static int my_nic_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    struct net_device *netdev;
    struct my_nic_priv *priv;
    
    // Allocate network device
    netdev = alloc_etherdev(sizeof(struct my_nic_priv));
    if (!netdev)
        return -ENOMEM;
    
    priv = netdev_priv(netdev);
    
    // Enable PCI device
    pci_enable_device(pdev);
    pci_set_master(pdev);
    
    // Map MMIO registers
    priv->hw_addr = pci_iomap(pdev, 0, 0);
    
    // Setup DMA
    pci_set_dma_mask(pdev, DMA_BIT_MASK(64));
    
    // Setup interrupts
    pci_enable_msi(pdev);
    request_irq(pdev->irq, my_nic_interrupt, 0, "my_nic", netdev);
    
    // Register network device
    netdev->netdev_ops = &my_nic_netdev_ops;
    register_netdev(netdev);
    
    return 0;
}
```

**B. Direct Hardware Register Access**
```c
// Hardware register definitions (from datasheet)
#define NIC_BASE_ADDR        0xF8000000
#define REG_CTRL             0x0000
#define REG_STATUS           0x0004
#define REG_IPV6_ENABLE      0x1008  // Enable IPv6 parser
#define REG_FLOW_TABLE_BASE  0x100000

// Hardware flow entry format (maps to ASIC structure)
struct hw_flow_entry {
    uint8_t  src_ipv6[16];
    uint8_t  dst_ipv6[16];
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t  protocol;
    uint32_t action_bitmap;
    uint8_t  new_dst_mac[6];
    uint16_t output_port;
    uint8_t  valid;
    uint64_t packet_count;
} __attribute__((packed));

// Enable IPv6 hardware parsing
static void enable_ipv6_hardware_parser(struct my_nic_priv *priv)
{
    void __iomem *reg = priv->hw_addr + REG_IPV6_ENABLE;
    uint32_t val;
    
    // Read-modify-write to enable IPv6 bit
    val = ioread32(reg);
    val |= (1 << 3);  // Bit 3 = IPv6 enable
    iowrite32(val, reg);
    
    // Wait for hardware to acknowledge
    while (!(ioread32(priv->hw_addr + REG_STATUS) & 0x01))
        cpu_relax();
}

// Program hardware flow table directly
static int install_hardware_flow(struct my_nic_priv *priv,
                                 struct ipv6hdr *ip6h,
                                 struct tcphdr *tcph,
                                 uint8_t *dst_mac,
                                 uint16_t out_port)
{
    volatile struct hw_flow_entry *hw_entry;
    int idx = find_free_flow_slot(priv);
    
    // Calculate MMIO address for flow entry
    hw_entry = (void __iomem *)(priv->hw_addr + REG_FLOW_TABLE_BASE + 
                                (idx * sizeof(struct hw_flow_entry)));
    
    // Write match fields to hardware registers
    memcpy_toio(hw_entry->src_ipv6, &ip6h->saddr, 16);
    memcpy_toio(hw_entry->dst_ipv6, &ip6h->daddr, 16);
    iowrite16(tcph->source, &hw_entry->src_port);
    iowrite16(tcph->dest, &hw_entry->dst_port);
    iowrite8(IPPROTO_TCP, &hw_entry->protocol);
    
    // Write action fields
    iowrite32((1 << 1) | (1 << 2), &hw_entry->action_bitmap);  // Forward + modify
    memcpy_toio(hw_entry->new_dst_mac, dst_mac, 6);
    iowrite16(out_port, &hw_entry->output_port);
    
    // Memory barrier before validation
    wmb();
    
    // Atomically enable entry (hardware starts matching)
    iowrite8(1, &hw_entry->valid);
    
    return 0;
}
```

**C. Packet RX/TX with DMA**
```c
// RX descriptor ring (hardware DMA structure)
#define RX_RING_SIZE 1024

struct rx_descriptor {
    __le64 buffer_addr;   // Physical address
    __le16 length;        // Hardware fills this
    __le16 flags;         // DD (descriptor done) bit
    __le32 rss_hash;
} __attribute__((aligned(16)));

struct my_nic_priv {
    struct rx_descriptor *rx_ring;  // Virtual address
    dma_addr_t rx_ring_dma;         // Physical address
    struct sk_buff **rx_buffers;
    unsigned int rx_tail;
};

// Setup RX ring
static int setup_rx_ring(struct my_nic_priv *priv)
{
    int i;
    
    // Allocate DMA-coherent memory for descriptor ring
    priv->rx_ring = dma_alloc_coherent(&priv->pdev->dev,
                                       RX_RING_SIZE * sizeof(struct rx_descriptor),
                                       &priv->rx_ring_dma,
                                       GFP_KERNEL);
    
    // Allocate packet buffers
    priv->rx_buffers = kcalloc(RX_RING_SIZE, sizeof(struct sk_buff *), GFP_KERNEL);
    
    // Fill ring with packet buffers
    for (i = 0; i < RX_RING_SIZE; i++) {
        struct sk_buff *skb = netdev_alloc_skb(priv->netdev, 2048);
        dma_addr_t dma = dma_map_single(&priv->pdev->dev,
                                        skb->data, 2048,
                                        DMA_FROM_DEVICE);
        
        priv->rx_buffers[i] = skb;
        priv->rx_ring[i].buffer_addr = cpu_to_le64(dma);
        priv->rx_ring[i].flags = 0;
    }
    
    // Tell hardware about ring
    iowrite64(priv->rx_ring_dma, priv->hw_addr + REG_RX_RING_BASE);
    iowrite32(RX_RING_SIZE, priv->hw_addr + REG_RX_RING_SIZE);
    
    return 0;
}

// NAPI poll function (called on interrupt)
static int my_nic_poll(struct napi_struct *napi, int budget)
{
    struct my_nic_priv *priv = container_of(napi, struct my_nic_priv, napi);
    int work_done = 0;
    
    while (work_done < budget) {
        struct rx_descriptor *desc = &priv->rx_ring[priv->rx_tail];
        struct sk_buff *skb;
        
        // Check if hardware wrote descriptor (DD bit)
        if (!(desc->flags & RX_DESC_DD))
            break;  // No more packets
        
        // Get packet buffer
        skb = priv->rx_buffers[priv->rx_tail];
        dma_unmap_single(&priv->pdev->dev, 
                        le64_to_cpu(desc->buffer_addr),
                        2048, DMA_FROM_DEVICE);
        
        // Set packet length
        skb_put(skb, le16_to_cpu(desc->length));
        
        // Set protocol
        skb->protocol = eth_type_trans(skb, priv->netdev);
        
        // Handle IPv6 flow miss (first packet)
        if (skb->protocol == htons(ETH_P_IPV6)) {
            struct ipv6hdr *ip6h = ipv6_hdr(skb);
            if (ip6h->nexthdr == IPPROTO_TCP) {
                struct tcphdr *tcph = tcp_hdr(skb);
                
                // Check if flow exists in hardware
                if (!hardware_flow_exists(priv, ip6h, tcph)) {
                    // First packet - do routing lookup
                    uint8_t next_hop_mac[6];
                    uint16_t out_port;
                    
                    if (ipv6_route_lookup(ip6h->daddr, next_hop_mac, &out_port) == 0) {
                        // Install flow in hardware for subsequent packets
                        install_hardware_flow(priv, ip6h, tcph, next_hop_mac, out_port);
                    }
                }
            }
        }
        
        // Pass to kernel network stack
        netif_receive_skb(skb);
        
        // Allocate new buffer for this slot
        skb = netdev_alloc_skb(priv->netdev, 2048);
        dma_addr_t dma = dma_map_single(&priv->pdev->dev,
                                        skb->data, 2048,
                                        DMA_FROM_DEVICE);
        priv->rx_buffers[priv->rx_tail] = skb;
        desc->buffer_addr = cpu_to_le64(dma);
        desc->flags = 0;
        
        // Move to next descriptor
        priv->rx_tail = (priv->rx_tail + 1) % RX_RING_SIZE;
        work_done++;
    }
    
    // Update hardware tail pointer
    iowrite32(priv->rx_tail, priv->hw_addr + REG_RX_TAIL);
    
    if (work_done < budget) {
        napi_complete(napi);
        // Re-enable interrupts
        iowrite32(1, priv->hw_addr + REG_INT_ENABLE);
    }
    
    return work_done;
}

// Transmit function
static netdev_tx_t my_nic_xmit(struct sk_buff *skb, struct net_device *netdev)
{
    struct my_nic_priv *priv = netdev_priv(netdev);
    struct tx_descriptor *desc;
    dma_addr_t dma;
    
    // Get next TX descriptor
    desc = &priv->tx_ring[priv->tx_head];
    
    // Map packet for DMA
    dma = dma_map_single(&priv->pdev->dev, skb->data, skb->len, DMA_TO_DEVICE);
    
    // Fill descriptor
    desc->buffer_addr = cpu_to_le64(dma);
    desc->length = cpu_to_le16(skb->len);
    desc->cmd = TX_CMD_EOP | TX_CMD_RS;  // End of packet, report status
    
    // Memory barrier
    wmb();
    
    // Ring doorbell (tell hardware about new packet)
    priv->tx_head = (priv->tx_head + 1) % TX_RING_SIZE;
    iowrite32(priv->tx_head, priv->hw_addr + REG_TX_TAIL);
    
    return NETDEV_TX_OK;
}
```

**D. ethtool Interface for Hardware Statistics**
```c
static void my_nic_get_ethtool_stats(struct net_device *netdev,
                                     struct ethtool_stats *stats,
                                     u64 *data)
{
    struct my_nic_priv *priv = netdev_priv(netdev);
    
    // Read hardware statistics registers
    data[0] = ioread64(priv->hw_addr + REG_RX_PACKETS);
    data[1] = ioread64(priv->hw_addr + REG_RX_BYTES);
    data[2] = ioread64(priv->hw_addr + REG_TX_PACKETS);
    data[3] = ioread64(priv->hw_addr + REG_TX_BYTES);
    data[4] = ioread64(priv->hw_addr + REG_FLOW_TABLE_HITS);
    data[5] = ioread64(priv->hw_addr + REG_FLOW_TABLE_MISSES);
}

static const struct ethtool_ops my_nic_ethtool_ops = {
    .get_link = ethtool_op_get_link,
    .get_ethtool_stats = my_nic_get_ethtool_stats,
    .get_sset_count = my_nic_get_sset_count,
    .get_strings = my_nic_get_strings,
};
```

**Your Role:**
- Write complete kernel module from scratch
- Handle PCIe initialization and DMA setup
- Manage hardware registers directly via MMIO
- Integrate with kernel networking stack (netdev, NAPI, ethtool)
- Handle interrupts, concurrency, and error recovery
- Debug kernel panics and memory corruption

**Driver Interaction:**
- Direct hardware register access via `ioread/iowrite`
- DMA memory management
- Interrupt handling
- Kernel API integration

**Complexity:** Very High - requires:
- Deep Linux kernel knowledge
- Hardware datasheets and register specs
- PCIe expertise
- DMA and memory barrier understanding
- Debugging with kdump, ftrace, etc.

---

### Level 5: Firmware Development (Ultra-Expert)
**What You Write:**
- Embedded code that runs ON the DPU/NIC itself
- Packet processing logic in hardware (P4, C for ARM cores)

**Interfaces:**
```c
// ARM code running on BlueField DPU
// This is INSIDE the NIC/DPU, not on host

// Packet processing on DPU ARM cores
void dpu_packet_handler(struct packet_desc *pkt)
{
    // Parse packet headers
    struct eth_header *eth = get_eth_header(pkt);
    struct ipv6_header *ipv6 = get_ipv6_header(pkt);
    
    // Lookup in local routing table
    struct route_entry *route = dpu_route_lookup(ipv6->dst);
    
    if (route) {
        // Program eSwitch ASIC directly
        program_eswitch_flow(pkt->flow_key, route->action);
        
        // Forward packet
        dpu_forward_packet(pkt, route->out_port);
    } else {
        // Send to host CPU for slow path
        dpu_upcall_to_host(pkt);
    }
}

// P4 code for programmable packet pipeline
// Runs in hardware ASIC, not CPU
parser start {
    extract(ethernet);
    return select(ethernet.etherType) {
        0x86DD: parse_ipv6;  // IPv6
        default: ingress;
    }
}

parser parse_ipv6 {
    extract(ipv6);
    return select(ipv6.nextHeader) {
        6: parse_tcp;
        17: parse_udp;
        default: ingress;
    }
}

control ingress {
    // Custom flow table lookup
    table ipv6_forwarding {
        key = {
            ipv6.srcAddr: exact;
            ipv6.dstAddr: exact;
            tcp.srcPort: exact;
            tcp.dstPort: exact;
        }
        actions = {
            forward;
            drop;
            mirror;
        }
    }
    
    apply {
        ipv6_forwarding.apply();
    }
}
```

**Your Role:**
- Write code that runs on DPU ARM cores
- Program hardware packet processing pipelines (P4)
- Coordinate between firmware and host driver
- Manage DPU-internal resources

**Complexity:** Extreme - requires:
- Embedded systems expertise
- Hardware architecture knowledge
- P4 programming language
- Vendor-specific toolchains
- Hardware debugging tools

---

## Summary: What You Need by Use Case

| Use Case | Expertise Level | What You Interact With |
|----------|----------------|------------------------|
| **Run applications** | User | Socket API, ip/ethtool commands |
| **High-performance packet processing** | Moderate | DPDK PMD, userspace libraries |
| **DPU/SmartNIC offload** | Advanced | DOCA Flow API, hardware programming |
| **New hardware support** | Expert | Kernel driver code, register programming |
| **Custom protocol in hardware** | Ultra-Expert | Firmware, P4, ASIC programming |

**Your Likely Path (based on workspace):**
1. Start with **DOCA** (Level 3) for DPU programming
2. Use **OVS-DOCA** if doing Kubernetes networking
3. Only drop to **kernel driver** (Level 4) if:
   - Hardware vendor doesn't provide DOCA support
   - Need features DOCA doesn't expose
   - Contributing to open-source drivers (mlx5, etc.)

**Development Timeline:**
- DOCA application: 2-4 weeks
- Kernel driver: 6-12 months
- Firmware: 12-24 months

---

## Building a Custom Network Driver: Investigation Checklist

When building custom networking hardware/software, you need to investigate these kernel driver layers:

### 1. Hardware Discovery & Initialization

**PCIe Enumeration**
```c
// How your hardware is discovered by the kernel
static struct pci_device_id my_nic_pci_tbl[] = {
    // Vendor ID, Device ID from your hardware
    { PCI_DEVICE(0x15b3, 0x1019) },  // Example: Mellanox ConnectX-6
    { 0, }
};
MODULE_DEVICE_TABLE(pci, my_nic_pci_tbl);

static struct pci_driver my_nic_driver = {
    .name = "my_custom_nic",
    .id_table = my_nic_pci_tbl,
    .probe = my_nic_probe,
    .remove = my_nic_remove,
};
```

**Questions to Investigate:**
- What PCIe BAR (Base Address Register) layout does your hardware use?
  - BAR0: MMIO registers?
  - BAR1: MSI-X interrupt table?
  - BAR2: Device memory?
- What PCIe generation and width? (Gen3 x8, Gen4 x16, Gen5?)
- Does hardware support AER (Advanced Error Reporting)?
- MSI-X interrupt vector count? (1, 64, 2048?)

**Investigation Methods:**
```bash
# Discover PCIe layout
lspci -vvv -s 03:00.0
lspci -xxx -s 03:00.0  # Hex dump of config space

# Check BAR mappings
cat /sys/bus/pci/devices/0000:03:00.0/resource
```

---

### 2. Memory-Mapped I/O (MMIO) Register Map

**Critical Investigation: Get Hardware Datasheet**

You MUST obtain from hardware vendor:
- Register offset map
- Bit field definitions
- Read/write semantics
- Initialization sequence

**Example Register Map to Document:**
```c
// Document your hardware's register layout
#define HW_VENDOR_ID          0x0000  // R:  Vendor identification
#define HW_DEVICE_ID          0x0004  // R:  Device identification
#define HW_COMMAND            0x0008  // RW: Device command register
#define HW_STATUS             0x000C  // R:  Device status

// Control Registers
#define HW_CTRL_ENABLE        0x0100  // RW: Enable device
#define HW_CTRL_RESET         0x0104  // W:  Software reset
#define HW_CTRL_INT_MASK      0x0108  // RW: Interrupt mask

// Packet Processing Registers
#define HW_RX_RING_BASE_LO    0x1000  // RW: RX ring base (low 32-bit)
#define HW_RX_RING_BASE_HI    0x1004  // RW: RX ring base (high 32-bit)
#define HW_RX_RING_SIZE       0x1008  // RW: Number of descriptors
#define HW_RX_HEAD            0x100C  // R:  Hardware head pointer
#define HW_RX_TAIL            0x1010  // RW: Software tail pointer

#define HW_TX_RING_BASE_LO    0x2000  // RW: TX ring base (low 32-bit)
#define HW_TX_RING_BASE_HI    0x2004  // RW: TX ring base (high 32-bit)
#define HW_TX_RING_SIZE       0x2008  // RW: Number of descriptors
#define HW_TX_HEAD            0x200C  // R:  Hardware head pointer
#define HW_TX_TAIL            0x2010  // RW: Software tail pointer

// Flow Table Registers (for hardware offload)
#define HW_FLOW_TABLE_BASE    0x100000  // RW: Flow table MMIO base
#define HW_FLOW_TABLE_SIZE    0x3000    // RW: Max flow entries
#define HW_FLOW_CTRL          0x3004    // RW: Flow table control
#define HW_FLOW_STATS_BASE    0x200000  // R:  Flow statistics

// IPv6 Parser Registers (if custom protocol)
#define HW_PARSER_CTRL        0x4000    // RW: Parser configuration
#define HW_PARSER_PROTO_EN    0x4004    // RW: Protocol enable bitmap
  // Bit 0: Ethernet
  // Bit 1: VLAN
  // Bit 2: IPv4
  // Bit 3: IPv6  ← Enable this for IPv6 support
  // Bit 4: ARP
  // Bit 5: TCP
  // Bit 6: UDP
  // Bit 7: ICMPv6
#define HW_PARSER_EXT_HDR     0x4008    // RW: IPv6 extension header config

// Statistics Registers
#define HW_STATS_RX_PKTS      0x5000    // R: RX packet count
#define HW_STATS_RX_BYTES     0x5008    // R: RX byte count
#define HW_STATS_TX_PKTS      0x5010    // R: TX packet count
#define HW_STATS_TX_BYTES     0x5018    // R: TX byte count
#define HW_STATS_FLOW_HITS    0x5020    // R: Flow table hits
#define HW_STATS_FLOW_MISSES  0x5028    // R: Flow table misses
```

**Questions to Investigate:**
- What's the initialization sequence? (Reset → Enable → Configure → Start?)
- Are registers 32-bit or 64-bit?
- Which registers need memory barriers?
- What's the endianness? (Little-endian on x86, but what about DPU?)
- Are there register access restrictions? (Some read-only in certain states?)
- What happens if you write to reserved bits?

**Investigation Methods:**
```c
// Probe registers during development
static void dump_hardware_registers(struct my_nic_priv *priv)
{
    pr_info("VENDOR_ID:  0x%08x\n", ioread32(priv->hw_addr + HW_VENDOR_ID));
    pr_info("DEVICE_ID:  0x%08x\n", ioread32(priv->hw_addr + HW_DEVICE_ID));
    pr_info("STATUS:     0x%08x\n", ioread32(priv->hw_addr + HW_STATUS));
    pr_info("RX_HEAD:    0x%08x\n", ioread32(priv->hw_addr + HW_RX_HEAD));
    pr_info("RX_TAIL:    0x%08x\n", ioread32(priv->hw_addr + HW_RX_TAIL));
    
    // Test write-read to verify MMIO works
    iowrite32(0xDEADBEEF, priv->hw_addr + HW_TX_RING_SIZE);
    pr_info("Test write: 0x%08x\n", ioread32(priv->hw_addr + HW_TX_RING_SIZE));
}
```

---

### 3. DMA Architecture & Descriptor Formats

**Descriptor Ring Structure**

Your hardware likely uses descriptor rings for DMA. Investigate:

```c
// What's YOUR hardware's descriptor format?
// This varies by vendor - you need the datasheet

// Example: Simple descriptor format
struct hw_rx_descriptor {
    __le64 buffer_addr;    // Physical address of packet buffer
    __le16 length;         // Packet length (hardware fills)
    __le16 vlan_tag;       // VLAN tag (if present)
    __le32 rss_hash;       // RSS hash value
    __le16 pkt_type;       // Packet type (IPv4, IPv6, etc.)
    __le16 flags;          // Status flags
    // Bit 0: DD (Descriptor Done) - hardware writes this
    // Bit 1: EOP (End of Packet)
    // Bit 2: Error
} __attribute__((aligned(16)));  // Hardware may require alignment

// Example: Complex descriptor format (like Intel NICs)
struct hw_advanced_rx_descriptor {
    struct {
        __le64 pkt_addr;     // Packet buffer address
        __le64 hdr_addr;     // Header buffer address (for header split)
    } read;
    
    struct {
        struct {
            __le32 data;
            __le32 rss;      // RSS hash
        } lo;
        struct {
            __le16 status0;
            __le16 pkt_info;
            __le16 status1;
            __le16 length;
        } hi;
    } wb;  // Writeback format
} __attribute__((aligned(16)));

// TX descriptor format
struct hw_tx_descriptor {
    __le64 buffer_addr;    // Physical address of packet data
    __le32 cmd_type_len;   // Command, type, and length
    // Bits 0-19:  Length
    // Bits 20-23: Descriptor type
    // Bits 24-31: Command flags
    __le32 status;         // Status (hardware fills after TX)
    // Bit 0: DD (Descriptor Done)
} __attribute__((aligned(16)));
```

**Questions to Investigate:**
- What's the descriptor size? (16, 32, 64 bytes?)
- Does hardware require specific alignment? (16-byte, cache-line?)
- Does hardware support scatter-gather? (Multiple buffers per packet?)
- What's the maximum descriptor ring size? (512, 4096, 65536?)
- Does hardware support header-data split?
- What status flags does hardware set?
- How does hardware signal completion? (DD bit, writeback to memory?)

**DMA Coherency Model**
```c
// Investigate: Does your hardware maintain cache coherency?

// Option 1: Coherent DMA (hardware snoops CPU cache)
priv->rx_ring = dma_alloc_coherent(&pdev->dev, size, &dma_addr, GFP_KERNEL);
// No explicit cache management needed

// Option 2: Streaming DMA (no cache coherency)
priv->rx_ring = kmalloc(size, GFP_KERNEL);
dma_addr = dma_map_single(&pdev->dev, priv->rx_ring, size, DMA_FROM_DEVICE);
// MUST use dma_sync_* before accessing
dma_sync_single_for_cpu(&pdev->dev, dma_addr, size, DMA_FROM_DEVICE);
// ... read descriptor ...
dma_sync_single_for_device(&pdev->dev, dma_addr, size, DMA_FROM_DEVICE);
```

**Questions:**
- Is your DMA coherent or non-coherent?
- What's the DMA address width? (32-bit, 48-bit, 64-bit?)
- Does hardware support IOMMU/SMMU?
- What's the required memory barrier semantics?

**Investigation Methods:**
```c
// Test descriptor writeback
static void test_descriptor_writeback(struct my_nic_priv *priv)
{
    struct hw_rx_descriptor *desc = &priv->rx_ring[0];
    
    pr_info("Before: flags=0x%04x, length=%u\n", desc->flags, desc->length);
    
    // Trigger hardware to write descriptor
    iowrite32(1, priv->hw_addr + HW_RX_TAIL);
    
    // Poll for DD bit
    int timeout = 1000;
    while (!(desc->flags & RX_DESC_DD) && timeout--)
        udelay(10);
    
    pr_info("After:  flags=0x%04x, length=%u\n", desc->flags, desc->length);
    
    if (desc->flags & RX_DESC_DD)
        pr_info("✓ Descriptor writeback working\n");
    else
        pr_err("✗ Descriptor writeback FAILED\n");
}
```

---

### 4. Interrupt Handling & NAPI Integration

**MSI-X Vector Allocation**

```c
// How many interrupt vectors does your hardware support?
static int setup_msix_vectors(struct my_nic_priv *priv)
{
    int nvec, i;
    
    // Try to allocate maximum vectors
    nvec = pci_msix_vec_count(priv->pdev);
    pr_info("Hardware supports %d MSI-X vectors\n", nvec);
    
    // Allocate vectors (typically: 1 admin + N RX queues + N TX queues)
    priv->num_vectors = nvec;
    priv->msix_entries = kcalloc(nvec, sizeof(struct msix_entry), GFP_KERNEL);
    
    for (i = 0; i < nvec; i++)
        priv->msix_entries[i].entry = i;
    
    // Enable MSI-X
    int ret = pci_enable_msix_exact(priv->pdev, priv->msix_entries, nvec);
    if (ret) {
        pr_err("Failed to enable MSI-X: %d\n", ret);
        // Fallback to fewer vectors
        return ret;
    }
    
    // Register interrupt handlers
    for (i = 0; i < nvec; i++) {
        int vector = priv->msix_entries[i].vector;
        char *name = kasprintf(GFP_KERNEL, "my_nic-rx-%d", i);
        
        ret = request_irq(vector, my_nic_msix_handler,
                         0, name, &priv->rx_rings[i]);
        if (ret) {
            pr_err("Failed to request IRQ %d: %d\n", vector, ret);
            return ret;
        }
        
        // Affinity hint (steer interrupts to specific CPUs)
        irq_set_affinity_hint(vector, get_cpu_mask(i % num_online_cpus()));
    }
    
    return 0;
}
```

**Questions to Investigate:**
- How many MSI-X vectors does hardware provide?
- What's the vector assignment? (Vector 0 = admin, 1-N = RX queues?)
- Does hardware support interrupt moderation? (Coalescing?)
- What registers control interrupt generation?
- Can you dynamically adjust interrupt rate?

**NAPI Integration**
```c
// How should you integrate with NAPI?

static int my_nic_poll(struct napi_struct *napi, int budget)
{
    struct my_nic_rx_ring *rx_ring = container_of(napi, struct my_nic_rx_ring, napi);
    int work_done = 0;
    
    while (work_done < budget) {
        struct hw_rx_descriptor *desc = &rx_ring->desc[rx_ring->next];
        
        // Check DD bit
        if (!(desc->flags & RX_DESC_DD))
            break;  // No more packets
        
        // Process packet
        struct sk_buff *skb = rx_ring->buffers[rx_ring->next];
        skb_put(skb, desc->length);
        skb->protocol = eth_type_trans(skb, rx_ring->netdev);
        
        // Hardware offload features (investigate what yours supports)
        if (desc->flags & RX_DESC_CSUM_OK)
            skb->ip_summed = CHECKSUM_UNNECESSARY;  // HW verified checksum
        
        if (desc->pkt_type & RX_PKT_RSS_TYPE_IPV6_TCP)
            skb_set_hash(skb, desc->rss_hash, PKT_HASH_TYPE_L4);
        
        // Custom flow miss handling
        if (desc->flags & RX_DESC_FLOW_MISS) {
            // First packet of new flow - do control plane processing
            handle_flow_miss(skb, rx_ring);
        }
        
        // Pass to stack
        napi_gro_receive(napi, skb);
        
        // Refill descriptor
        refill_rx_descriptor(rx_ring, rx_ring->next);
        
        rx_ring->next = (rx_ring->next + 1) % RX_RING_SIZE;
        work_done++;
    }
    
    // Update hardware tail pointer
    iowrite32(rx_ring->next, rx_ring->hw_addr + HW_RX_TAIL);
    
    if (work_done < budget) {
        napi_complete(napi);
        
        // Re-enable interrupts for this queue
        iowrite32(1 << rx_ring->queue_id, 
                 rx_ring->priv->hw_addr + HW_CTRL_INT_ENABLE);
    }
    
    return work_done;
}

// IRQ handler
static irqreturn_t my_nic_msix_handler(int irq, void *data)
{
    struct my_nic_rx_ring *rx_ring = data;
    
    // Disable interrupts for this queue
    iowrite32(1 << rx_ring->queue_id,
             rx_ring->priv->hw_addr + HW_CTRL_INT_DISABLE);
    
    // Schedule NAPI poll
    napi_schedule(&rx_ring->napi);
    
    return IRQ_HANDLED;
}
```

**Questions:**
- What's the optimal NAPI budget for your hardware?
- Should you use GRO (Generic Receive Offload)?
- How do you implement interrupt coalescing?
- What's the latency vs throughput tradeoff?

---

### 5. Hardware Offload Capabilities

**Investigate What Your Hardware Can Offload**

```c
// Checksum Offload
static void probe_checksum_offload(struct net_device *netdev)
{
    // Advertise to kernel what hardware can do
    netdev->features |= NETIF_F_RXCSUM;  // RX checksum verification
    netdev->features |= NETIF_F_IP_CSUM;  // TX IPv4 checksum
    netdev->features |= NETIF_F_IPV6_CSUM;  // TX IPv6 checksum
    
    // Question: Does hardware support SCTP checksum?
    if (hw_supports_sctp_csum())
        netdev->features |= NETIF_F_SCTP_CRC;
}

// TSO/GSO (TCP Segmentation Offload)
static void probe_segmentation_offload(struct net_device *netdev)
{
    // Question: What's the max TSO segment size?
    netdev->gso_max_size = 65536;
    netdev->gso_max_segs = 64;  // Max segments per TSO
    
    netdev->features |= NETIF_F_TSO;   // IPv4 TSO
    netdev->features |= NETIF_F_TSO6;  // IPv6 TSO
    
    // Question: Does hardware support UFO (UDP fragmentation)?
    if (hw_supports_ufo())
        netdev->features |= NETIF_F_UFO;
}

// VLAN Offload
static void probe_vlan_offload(struct net_device *netdev)
{
    netdev->features |= NETIF_F_HW_VLAN_CTAG_RX;  // RX VLAN stripping
    netdev->features |= NETIF_F_HW_VLAN_CTAG_TX;  // TX VLAN insertion
    netdev->features |= NETIF_F_HW_VLAN_CTAG_FILTER;  // VLAN filtering
}

// Tunnel Offload
static void probe_tunnel_offload(struct net_device *netdev)
{
    // Question: Does hardware support VXLAN offload?
    if (hw_supports_vxlan()) {
        netdev->features |= NETIF_F_GSO_UDP_TUNNEL;
        netdev->hw_enc_features |= NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM;
    }
    
    // Question: Does hardware support GRE offload?
    if (hw_supports_gre())
        netdev->features |= NETIF_F_GSO_GRE;
}

// RSS (Receive Side Scaling)
static void probe_rss_offload(struct my_nic_priv *priv)
{
    // Question: How many RSS queues does hardware support?
    priv->num_rss_queues = hw_get_max_rss_queues();
    
    // Question: What hash functions are available?
    // - Toeplitz
    // - XOR
    // - CRC32
    
    // Configure RSS hash key (random key for security)
    u8 rss_key[40];
    netdev_rss_key_fill(rss_key, sizeof(rss_key));
    
    for (int i = 0; i < sizeof(rss_key); i += 4) {
        u32 key_dword = *(u32 *)&rss_key[i];
        iowrite32(key_dword, priv->hw_addr + HW_RSS_KEY_BASE + i);
    }
    
    // Configure RSS hash type (what fields to hash on)
    u32 rss_hash_type = 
        RSS_HASH_IPV4 |       // Hash on IPv4 src/dst
        RSS_HASH_IPV6 |       // Hash on IPv6 src/dst
        RSS_HASH_TCP_IPV4 |   // Hash on TCP ports
        RSS_HASH_TCP_IPV6 |
        RSS_HASH_UDP_IPV4 |
        RSS_HASH_UDP_IPV6;
    iowrite32(rss_hash_type, priv->hw_addr + HW_RSS_HASH_TYPE);
    
    // Configure indirection table (which queue for each hash bucket)
    for (int i = 0; i < RSS_INDIR_TABLE_SIZE; i++) {
        u8 queue_id = i % priv->num_rss_queues;
        iowrite8(queue_id, priv->hw_addr + HW_RSS_INDIR_TABLE + i);
    }
}

// Flow Director / Flow Steering
static void probe_flow_steering(struct my_nic_priv *priv)
{
    // Question: Does hardware support programmable flow tables?
    if (!hw_supports_flow_director())
        return;
    
    // Question: How many flow entries can hardware hold?
    priv->max_flow_entries = ioread32(priv->hw_addr + HW_FLOW_TABLE_SIZE);
    pr_info("Hardware supports %u flow entries\n", priv->max_flow_entries);
    
    // Question: What can you match on?
    // - IPv4/IPv6 src/dst
    // - TCP/UDP src/dst port
    // - VLAN ID
    // - Tunnel ID (VNI)
    
    // Question: What actions can hardware perform?
    // - Drop
    // - Forward to specific queue
    // - Mirror
    // - Modify headers (SNAT/DNAT)
    // - Encap/decap
}
```

**Questions for Each Offload:**
- Is it enabled by default or needs firmware configuration?
- What are the hardware limitations? (max segment size, etc.)
- Does it work with all packet types or only specific ones?
- How do you enable/disable at runtime?

---

### 6. Flow Table / Hardware Acceleration (Critical for Custom Protocols)

**This is the key area for custom networking features**

```c
// Hardware flow table structure (example)
struct hw_flow_entry {
    // Match criteria (what packets to catch)
    struct {
        u8 src_ipv6[16];
        u8 dst_ipv6[16];
        __be16 src_port;
        __be16 dst_port;
        u8 protocol;
        u8 _pad[3];
    } match;
    
    // Mask (which fields must match)
    struct {
        u8 src_ipv6_mask[16];  // 0xFF = must match, 0x00 = wildcard
        u8 dst_ipv6_mask[16];
        __be16 src_port_mask;
        __be16 dst_port_mask;
        u8 protocol_mask;
        u8 _pad[3];
    } mask;
    
    // Action (what to do with matched packets)
    struct {
        u32 action_type;
        // Bit 0: Drop
        // Bit 1: Forward
        // Bit 2: Modify L2 (MAC rewrite)
        // Bit 3: Modify L3 (IP rewrite)
        // Bit 4: Modify L4 (port rewrite)
        // Bit 5: Encap (add outer headers)
        // Bit 6: Decap (remove outer headers)
        // Bit 7: Mirror
        // Bit 8: Count
        // Bit 9: Rate limit
        
        u8 new_dst_mac[6];
        u8 new_src_mac[6];
        u8 new_dst_ipv6[16];
        u8 new_src_ipv6[16];
        __be16 new_dst_port;
        __be16 new_src_port;
        u16 output_port;
        u16 encap_template_id;
        u32 rate_limit_mbps;
    } action;
    
    // Hardware state
    u8 valid;
    u8 priority;
    u16 _reserved;
    
    // Statistics (read-only, updated by hardware)
    u64 packet_count;
    u64 byte_count;
    u64 last_used_timestamp;
} __attribute__((packed, aligned(64)));

// Programming the flow table
static int install_ipv6_flow(struct my_nic_priv *priv,
                              struct ipv6hdr *ip6h,
                              struct tcphdr *tcph,
                              struct flow_action *action)
{
    int idx = find_free_flow_slot(priv);
    if (idx < 0)
        return -ENOSPC;
    
    volatile struct hw_flow_entry *entry = 
        (void __iomem *)(priv->hw_addr + HW_FLOW_TABLE_BASE + 
                        (idx * sizeof(struct hw_flow_entry)));
    
    // Write match fields
    memcpy_toio(entry->match.src_ipv6, &ip6h->saddr, 16);
    memcpy_toio(entry->match.dst_ipv6, &ip6h->daddr, 16);
    iowrite16(tcph->source, &entry->match.src_port);
    iowrite16(tcph->dest, &entry->match.dst_port);
    iowrite8(IPPROTO_TCP, &entry->match.protocol);
    
    // Write mask (exact match on all fields)
    memset_io(entry->mask.src_ipv6_mask, 0xFF, 16);
    memset_io(entry->mask.dst_ipv6_mask, 0xFF, 16);
    iowrite16(0xFFFF, &entry->mask.src_port_mask);
    iowrite16(0xFFFF, &entry->mask.dst_port_mask);
    iowrite8(0xFF, &entry->mask.protocol_mask);
    
    // Write action
    iowrite32(action->action_type, &entry->action.action_type);
    if (action->action_type & ACTION_MODIFY_L2) {
        memcpy_toio(entry->action.new_dst_mac, action->new_dst_mac, 6);
    }
    if (action->action_type & ACTION_MODIFY_L3) {
        memcpy_toio(entry->action.new_dst_ipv6, action->new_dst_ipv6, 16);
    }
    iowrite16(action->output_port, &entry->action.output_port);
    
    // Memory barrier before enabling
    wmb();
    
    // Atomically enable entry
    iowrite8(1, &entry->valid);
    
    pr_debug("Installed flow %d: %pI6c:%u -> %pI6c:%u\n",
            idx, &ip6h->saddr, ntohs(tcph->source),
            &ip6h->daddr, ntohs(tcph->dest));
    
    return idx;
}
```

**Critical Questions:**
- What's the flow table size? (1K, 1M, 4M entries?)
- What's the match key width? (Can it fit IPv6 5-tuple + VLAN + VNI?)
- Is it TCAM or hash-based?
- What's the lookup latency? (nanoseconds?)
- Can you do wildcard matching? (e.g., match /64 prefix)
- Priority handling for overlapping rules?
- How do you age out old flows?
- How do you read statistics without stalling hardware?

**Investigation Methods:**
```c
// Test flow table performance
static void benchmark_flow_installation(struct my_nic_priv *priv)
{
    ktime_t start, end;
    int i, count = 1000;
    
    start = ktime_get();
    
    for (i = 0; i < count; i++) {
        // Install dummy flow
        struct hw_flow_entry entry = {...};
        program_flow_entry(priv, i, &entry);
    }
    
    end = ktime_get();
    
    u64 ns = ktime_to_ns(ktime_sub(end, start));
    pr_info("Installed %d flows in %llu ns (avg: %llu ns/flow)\n",
            count, ns, ns / count);
}
```

---

### 7. Custom Protocol Support (The "Custom" Part)

**If you're implementing a custom protocol, you need to teach hardware to parse it**

```c
// Example: Custom overlay protocol on top of UDP
// Format: [Ethernet][IPv6][UDP][Custom Header][Payload]

struct custom_protocol_header {
    u16 magic;           // Protocol identifier (e.g., 0xC0DE)
    u16 version;         // Protocol version
    u32 flow_id;         // Custom flow identifier
    u16 flags;           // Custom flags
    u16 payload_len;     // Payload length
} __attribute__((packed));

// Teach hardware parser about your protocol
static int configure_custom_protocol_parser(struct my_nic_priv *priv)
{
    // Question: Does your hardware have a programmable parser?
    if (!hw_has_programmable_parser(priv))
        return -EOPNOTSUPP;  // Have to do in software
    
    // Configure parser to recognize your protocol
    // (This is highly hardware-specific!)
    
    // Step 1: Define custom header extraction
    struct hw_parser_config {
        u16 udp_dst_port;     // Trigger: UDP port 9999
        u16 protocol_offset;  // Where custom header starts (after UDP)
        u16 protocol_magic;   // Magic value to verify (0xC0DE)
        u8 header_length;     // Length of custom header
        
        // Which fields to extract for flow matching
        struct {
            u8 offset;        // Offset within custom header
            u8 length;        // Field length in bytes
            u8 match_index;   // Index in match key (0-15)
        } extract_fields[8];
    } parser_cfg = {
        .udp_dst_port = 9999,
        .protocol_offset = 0,  // Immediately after UDP
        .protocol_magic = 0xC0DE,
        .header_length = sizeof(struct custom_protocol_header),
        
        .extract_fields = {
            {.offset = 4, .length = 4, .match_index = 0},  // flow_id
            {.offset = 8, .length = 2, .match_index = 1},  // flags
        },
    };
    
    // Write parser configuration to hardware
    write_parser_config(priv, &parser_cfg);
    
    // Step 2: Enable custom protocol in parser
    u32 proto_enable = ioread32(priv->hw_addr + HW_PARSER_PROTO_EN);
    proto_enable |= PARSER_PROTO_CUSTOM;
    iowrite32(proto_enable, priv->hw_addr + HW_PARSER_PROTO_EN);
    
    pr_info("Custom protocol parser configured\n");
    return 0;
}

// Software fallback if hardware can't parse
static int handle_custom_protocol_sw(struct sk_buff *skb)
{
    struct custom_protocol_header *hdr;
    struct udphdr *udph = udp_hdr(skb);
    
    // Check if this is our protocol
    if (ntohs(udph->dest) != 9999)
        return -EINVAL;
    
    hdr = (void *)(udph + 1);
    
    // Verify magic
    if (ntohs(hdr->magic) != 0xC0DE)
        return -EINVAL;
    
    // Extract custom flow key
    u32 flow_id = ntohl(hdr->flow_id);
    u16 flags = ntohs(hdr->flags);
    
    // Lookup or install flow
    struct flow_entry *flow = lookup_custom_flow(flow_id);
    if (!flow) {
        flow = create_custom_flow(flow_id, flags);
        install_hardware_flow(priv, flow);
    }
    
    // Process packet
    process_custom_protocol(skb, hdr, flow);
    
    return 0;
}
```

**Questions for Custom Protocols:**
- Can hardware parse your protocol or do you need software fallback?
- If programmable parser: what's the configuration interface?
- Can hardware extract your custom flow keys?
- Can hardware perform your custom actions?
- What's the fallback path for unsupported features?

---

### 8. Debugging & Diagnostics

**Essential Debug Infrastructure**

```c
// 1. Register Dump for Debugging
static void dump_all_registers(struct my_nic_priv *priv)
{
    pr_info("=== Register Dump ===\n");
    pr_info("CTRL:          0x%08x\n", ioread32(priv->hw_addr + HW_COMMAND));
    pr_info("STATUS:        0x%08x\n", ioread32(priv->hw_addr + HW_STATUS));
    pr_info("RX_HEAD:       0x%08x\n", ioread32(priv->hw_addr + HW_RX_HEAD));
    pr_info("RX_TAIL:       0x%08x\n", ioread32(priv->hw_addr + HW_RX_TAIL));
    pr_info("TX_HEAD:       0x%08x\n", ioread32(priv->hw_addr + HW_TX_HEAD));
    pr_info("TX_TAIL:       0x%08x\n", ioread32(priv->hw_addr + HW_TX_TAIL));
    pr_info("FLOW_CTRL:     0x%08x\n", ioread32(priv->hw_addr + HW_FLOW_CTRL));
    pr_info("PARSER_CTRL:   0x%08x\n", ioread32(priv->hw_addr + HW_PARSER_CTRL));
    pr_info("INT_MASK:      0x%08x\n", ioread32(priv->hw_addr + HW_CTRL_INT_MASK));
}

// 2. Descriptor Ring Dump
static void dump_rx_ring(struct my_nic_priv *priv, int ring_id)
{
    struct my_nic_rx_ring *ring = &priv->rx_rings[ring_id];
    int i;
    
    pr_info("=== RX Ring %d ===\n", ring_id);
    pr_info("next: %u\n", ring->next);
    
    for (i = 0; i < 8; i++) {  // Dump first 8 descriptors
        struct hw_rx_descriptor *desc = &ring->desc[i];
        pr_info("[%d] addr=0x%llx len=%u flags=0x%04x\n",
                i, desc->buffer_addr, desc->length, desc->flags);
    }
}

// 3. Flow Table Dump
static void dump_flow_table(struct my_nic_priv *priv)
{
    int i;
    
    pr_info("=== Flow Table ===\n");
    pr_info("Max entries: %u\n", priv->max_flow_entries);
    
    for (i = 0; i < priv->max_flow_entries; i++) {
        volatile struct hw_flow_entry *entry =
            (void __iomem *)(priv->hw_addr + HW_FLOW_TABLE_BASE +
                            (i * sizeof(struct hw_flow_entry)));
        
        u8 valid = ioread8(&entry->valid);
        if (!valid)
            continue;
        
        u8 src[16], dst[16];
        memcpy_fromio(src, entry->match.src_ipv6, 16);
        memcpy_fromio(dst, entry->match.dst_ipv6, 16);
        
        u16 sport = ioread16(&entry->match.src_port);
        u16 dport = ioread16(&entry->match.dst_port);
        
        u64 pkts = ioread64(&entry->packet_count);
        u64 bytes = ioread64(&entry->byte_count);
        
        pr_info("[%d] %pI6c:%u -> %pI6c:%u pkts=%llu bytes=%llu\n",
                i, src, ntohs(sport), dst, ntohs(dport), pkts, bytes);
    }
}

// 4. Statistics via debugfs
static int my_nic_stats_show(struct seq_file *m, void *v)
{
    struct my_nic_priv *priv = m->private;
    
    seq_printf(m, "rx_packets:     %llu\n", 
               ioread64(priv->hw_addr + HW_STATS_RX_PKTS));
    seq_printf(m, "rx_bytes:       %llu\n",
               ioread64(priv->hw_addr + HW_STATS_RX_BYTES));
    seq_printf(m, "tx_packets:     %llu\n",
               ioread64(priv->hw_addr + HW_STATS_TX_PKTS));
    seq_printf(m, "tx_bytes:       %llu\n",
               ioread64(priv->hw_addr + HW_STATS_TX_BYTES));
    seq_printf(m, "flow_hits:      %llu\n",
               ioread64(priv->hw_addr + HW_STATS_FLOW_HITS));
    seq_printf(m, "flow_misses:    %llu\n",
               ioread64(priv->hw_addr + HW_STATS_FLOW_MISSES));
    
    return 0;
}

// Register debugfs
static void setup_debugfs(struct my_nic_priv *priv)
{
    priv->debugfs_dir = debugfs_create_dir("my_nic", NULL);
    
    debugfs_create_file("stats", 0444, priv->debugfs_dir, priv,
                       &my_nic_stats_fops);
    debugfs_create_file("registers", 0444, priv->debugfs_dir, priv,
                       &my_nic_regs_fops);
    debugfs_create_file("flows", 0444, priv->debugfs_dir, priv,
                       &my_nic_flows_fops);
}

// 5. Tracepoints for performance analysis
#include <trace/events/my_nic.h>

TRACE_EVENT(my_nic_rx_packet,
    TP_PROTO(struct my_nic_priv *priv, struct sk_buff *skb, u16 queue),
    TP_ARGS(priv, skb, queue),
    TP_STRUCT__entry(
        __field(u16, queue)
        __field(u32, len)
        __field(u64, timestamp)
    ),
    TP_fast_assign(
        __entry->queue = queue;
        __entry->len = skb->len;
        __entry->timestamp = ktime_get_ns();
    ),
    TP_printk("queue=%u len=%u ts=%llu", __entry->queue, __entry->len, __entry->timestamp)
);

// Use tracepoint
trace_my_nic_rx_packet(priv, skb, rx_ring->queue_id);

// Analyze with: trace-cmd record -e my_nic:*
```

**Debug Tools to Use:**
```bash
# ftrace for kernel tracing
echo 1 > /sys/kernel/debug/tracing/events/my_nic/enable
cat /sys/kernel/debug/tracing/trace

# perf for performance analysis
perf record -e my_nic:* -a sleep 10
perf report

# bpftrace for custom analysis
bpftrace -e 'tracepoint:my_nic:my_nic_rx_packet { @latency = hist(nsecs - args->timestamp); }'

# Check for DMA errors
dmesg | grep -i dma
cat /sys/kernel/debug/dma-api/error_count

# Monitor interrupts
watch -n1 'cat /proc/interrupts | grep my_nic'

# Check for PCIe errors
setpci -s 03:00.0 CAP_EXP+0a.w  # Device status register
```

---

### 9. Error Handling & Recovery

**Hardware Errors to Handle**

```c
// 1. DMA mapping failures
static struct sk_buff *alloc_rx_buffer(struct my_nic_priv *priv)
{
    struct sk_buff *skb = netdev_alloc_skb(priv->netdev, 2048);
    if (!skb) {
        priv->stats.rx_alloc_failures++;
        return NULL;
    }
    
    dma_addr_t dma = dma_map_single(&priv->pdev->dev,
                                    skb->data, 2048, DMA_FROM_DEVICE);
    if (dma_mapping_error(&priv->pdev->dev, dma)) {
        dev_kfree_skb(skb);
        priv->stats.rx_dma_map_failures++;
        return NULL;
    }
    
    return skb;
}

// 2. Hardware timeout errors
static int wait_for_hardware_ready(struct my_nic_priv *priv, int timeout_ms)
{
    ktime_t timeout = ktime_add_ms(ktime_get(), timeout_ms);
    
    while (ktime_before(ktime_get(), timeout)) {
        u32 status = ioread32(priv->hw_addr + HW_STATUS);
        if (status & HW_STATUS_READY)
            return 0;
        
        usleep_range(100, 200);
    }
    
    dev_err(&priv->pdev->dev, "Hardware timeout after %d ms\n", timeout_ms);
    return -ETIMEDOUT;
}

// 3. Flow table overflow
static int handle_flow_table_full(struct my_nic_priv *priv)
{
    // Age out oldest flows
    int i, freed = 0;
    u64 now = ktime_get_ns();
    u64 age_threshold = now - (60 * NSEC_PER_SEC);  // 60 seconds
    
    for (i = 0; i < priv->max_flow_entries; i++) {
        volatile struct hw_flow_entry *entry =
            (void __iomem *)(priv->hw_addr + HW_FLOW_TABLE_BASE +
                            (i * sizeof(struct hw_flow_entry)));
        
        if (!ioread8(&entry->valid))
            continue;
        
        u64 last_used = ioread64(&entry->last_used_timestamp);
        if (last_used < age_threshold) {
            // Age out this flow
            iowrite8(0, &entry->valid);
            freed++;
            
            if (freed >= 100)  // Free 100 at a time
                break;
        }
    }
    
    dev_info(&priv->pdev->dev, "Aged out %d flows\n", freed);
    return freed;
}

// 4. Hardware reset/recovery
static int reset_hardware(struct my_nic_priv *priv)
{
    dev_warn(&priv->pdev->dev, "Resetting hardware\n");
    
    // Disable interrupts
    iowrite32(0, priv->hw_addr + HW_CTRL_INT_ENABLE);
    
    // Stop DMA
    iowrite32(0, priv->hw_addr + HW_RX_RING_SIZE);
    iowrite32(0, priv->hw_addr + HW_TX_RING_SIZE);
    
    // Software reset
    iowrite32(HW_RESET_MAGIC, priv->hw_addr + HW_CTRL_RESET);
    msleep(100);
    
    // Wait for reset complete
    if (wait_for_hardware_ready(priv, 5000) < 0) {
        dev_err(&priv->pdev->dev, "Reset failed - hardware not responding\n");
        return -EIO;
    }
    
    // Reinitialize
    reinit_rx_rings(priv);
    reinit_tx_rings(priv);
    reinit_flow_table(priv);
    
    // Re-enable
    iowrite32(1, priv->hw_addr + HW_CTRL_ENABLE);
    iowrite32(0xFFFFFFFF, priv->hw_addr + HW_CTRL_INT_ENABLE);
    
    dev_info(&priv->pdev->dev, "Hardware reset complete\n");
    return 0;
}

// 5. Watchdog timer
static void my_nic_watchdog(struct timer_list *t)
{
    struct my_nic_priv *priv = from_timer(priv, t, watchdog_timer);
    
    // Check if hardware is stuck
    u32 rx_head = ioread32(priv->hw_addr + HW_RX_HEAD);
    u32 tx_head = ioread32(priv->hw_addr + HW_TX_HEAD);
    
    if (rx_head == priv->last_rx_head && tx_head == priv->last_tx_head) {
        priv->watchdog_stall_count++;
        
        if (priv->watchdog_stall_count > 5) {
            dev_err(&priv->pdev->dev, "Hardware appears stuck\n");
            reset_hardware(priv);
            priv->watchdog_stall_count = 0;
        }
    } else {
        priv->watchdog_stall_count = 0;
    }
    
    priv->last_rx_head = rx_head;
    priv->last_tx_head = tx_head;
    
    // Re-arm timer
    mod_timer(&priv->watchdog_timer, jiffies + HZ);  // 1 second
}
```

---

### 10. Performance Optimization Checklist

**Questions to Answer:**

1. **Memory Barriers**
   - Where do you need `wmb()`, `rmb()`, `mb()`?
   - Does hardware require specific barrier semantics?
   - PCIe has relaxed ordering - is that safe?

2. **Cache Line Alignment**
   - Are your structures cache-line aligned? (`__cacheline_aligned`)
   - Does it reduce false sharing?
   
   ```c
   struct my_nic_rx_ring {
       // Hot path (accessed frequently)
       u32 next_to_clean ____cacheline_aligned;
       u32 next_to_use;
       struct hw_rx_descriptor *desc;
       
       // Cold path (rarely accessed)
       struct napi_struct napi ____cacheline_aligned;
       struct my_nic_priv *priv;
   };
   ```

3. **Prefetching**
   - Should you prefetch next descriptor?
   
   ```c
   prefetch(&rx_ring->desc[rx_ring->next + 1]);
   ```

4. **Batch Processing**
   - Can you process multiple packets before updating hardware?
   
   ```c
   // Bad: Update tail pointer per packet
   for (i = 0; i < budget; i++) {
       process_packet(...);
       iowrite32(rx_ring->next, priv->hw_addr + HW_RX_TAIL);
   }
   
   // Good: Batch update
   for (i = 0; i < budget; i++) {
       process_packet(...);
   }
   iowrite32(rx_ring->next, priv->hw_addr + HW_RX_TAIL);  // Once
   ```

5. **NUMA Awareness**
   - Is memory allocated on the correct NUMA node?
   
   ```c
   int node = dev_to_node(&pdev->dev);
   priv->rx_ring = kzalloc_node(size, GFP_KERNEL, node);
   ```

---

## Debugging: Isolating Hardware vs Firmware vs Driver vs Software

When things go wrong, you need a systematic approach to identify which layer is failing.

### Quick Decision Tree

```
Symptom: Network not working

1. Can you see the PCIe device?
   lspci | grep -i network
   
   NO  → Hardware problem (physical connection, power, PCIe)
   YES → Continue to step 2

2. Can you read device registers?
   lspci -vvv -s 03:00.0
   setpci -s 03:00.0 0x00.l  # Read vendor ID
   
   NO  → Hardware problem (BAR mapping failed, device dead)
   YES → Continue to step 3

3. Does the driver load?
   lsmod | grep my_nic
   dmesg | grep my_nic
   
   NO  → Driver problem (probe failed, missing dependencies)
   YES → Continue to step 4

4. Does the device initialize?
   ethtool -i eth0
   ip link show eth0
   
   NO  → Firmware or driver problem (init sequence wrong)
   YES → Continue to step 5

5. Can you send/receive packets?
   tcpdump -i eth0
   ping -I eth0 192.168.1.1
   
   NO  → Driver or firmware problem (DMA, interrupts, flow tables)
   YES → Continue to step 6

6. Is performance as expected?
   iperf3 -c server -t 60
   
   NO  → Software configuration or driver optimization issue
   YES → Everything working!
```

---

### Layer 1: Hardware Problems

**Symptoms:**
- Device not detected by `lspci`
- Register reads return all 1s (0xFFFFFFFF)
- Device disappears after initialization
- PCIe link errors
- Device gets too hot (thermal throttling)

**Diagnostic Commands:**
```bash
# Check if PCIe device is detected
lspci -v | grep -A 20 "Network controller"

# Check PCIe link status
lspci -vvv -s 03:00.0 | grep -i "lnk\|speed\|width"
# Look for:
# LnkSta: Speed 16GT/s, Width x16  ← Should match card specs
# If you see x8 or x4, physical connection problem

# Check for PCIe errors
lspci -vvv -s 03:00.0 | grep -i error
# Look for:
# UESta: DLP- SDES- TLP- FCP- CmpltTO- CmpltAbrt- UnxCmplt- RxOF- MalfTLP- ECRC- UnsupReq- ACSViol-

# Detailed error checking
setpci -s 03:00.0 CAP_EXP+0a.w  # Device status
# Bit 0: Correctable Error
# Bit 1: Non-Fatal Error
# Bit 2: Fatal Error
# Bit 3: Unsupported Request

# Check PCIe AER (Advanced Error Reporting)
cat /sys/bus/pci/devices/0000:03:00.0/aer_dev_correctable
cat /sys/bus/pci/devices/0000:03:00.0/aer_dev_fatal
cat /sys/bus/pci/devices/0000:03:00.0/aer_dev_nonfatal

# Check thermal status (if available)
cat /sys/class/hwmon/hwmon*/temp1_input  # Temperature in millidegrees
```

**Hardware Test: Register Read/Write**
```c
// Test if hardware is responding
static int test_hardware_presence(struct my_nic_priv *priv)
{
    u32 vendor_id, device_id;
    
    // Read vendor/device ID from registers
    vendor_id = ioread32(priv->hw_addr + HW_VENDOR_ID);
    device_id = ioread32(priv->hw_addr + HW_DEVICE_ID);
    
    pr_info("Vendor ID: 0x%04x, Device ID: 0x%04x\n", 
            vendor_id & 0xFFFF, device_id & 0xFFFF);
    
    // All 1s means hardware not responding
    if (vendor_id == 0xFFFFFFFF) {
        pr_err("Hardware not responding (reads all 1s)\n");
        return -ENODEV;  // Hardware problem
    }
    
    // Try a scratch register write/read test
    u32 test_val = 0xDEADBEEF;
    iowrite32(test_val, priv->hw_addr + HW_SCRATCH_REG);
    wmb();  // Ensure write completes
    
    u32 readback = ioread32(priv->hw_addr + HW_SCRATCH_REG);
    
    if (readback != test_val) {
        pr_err("Scratch register test failed: wrote 0x%08x, read 0x%08x\n",
               test_val, readback);
        return -EIO;  // Hardware problem
    }
    
    pr_info("✓ Hardware responding correctly\n");
    return 0;
}
```

**Common Hardware Issues:**

| Symptom | Likely Cause | How to Verify |
|---------|--------------|---------------|
| Device not in `lspci` | Not plugged in, no power, BIOS disabled | Check physical connection, BIOS settings |
| Reads return 0xFFFFFFFF | PCIe link down, device powered off | Check `lspci -vvv`, look for LnkSta |
| PCIe link width wrong | Poor slot connection, wrong slot | Reseat card, try different slot |
| Device resets randomly | Power supply issue, overheating | Check `dmesg` for PCIe errors, thermal sensors |
| DMA errors | Bad memory, IOMMU misconfigured | Check `dmesg \| grep -i dma`, disable IOMMU to test |

---

### Layer 2: Firmware Problems

**Symptoms:**
- Hardware detected but doesn't initialize
- Commands to device timeout
- Device works initially then stops
- Features don't work as documented
- Wrong statistics or counters

**Diagnostic Commands:**
```bash
# Check firmware version
ethtool -i eth0 | grep firmware
# firmware-version: 16.35.2000

# Dump firmware log (vendor-specific)
# For Mellanox:
mlxfwmanager --query

# For Intel:
ethtool --get-fwdump eth0 data firmware.dump
ethtool --set-priv-flags eth0 fw-lldp-agent off  # Example firmware feature

# Check firmware health
cat /sys/class/net/eth0/device/fw_health_status
```

**Firmware Test: Command Interface**
```c
// Test firmware command interface
static int test_firmware_commands(struct my_nic_priv *priv)
{
    // Example: Query firmware version
    struct fw_cmd_get_version {
        u32 opcode;  // Command opcode
        u32 status;  // Firmware fills this
        u32 version_major;
        u32 version_minor;
        u32 version_patch;
    } __attribute__((packed));
    
    struct fw_cmd_get_version cmd = {
        .opcode = FW_CMD_GET_VERSION,
    };
    
    // Write command to mailbox
    memcpy_toio(priv->hw_addr + HW_FW_MAILBOX, &cmd, sizeof(cmd));
    
    // Ring doorbell
    iowrite32(1, priv->hw_addr + HW_FW_DOORBELL);
    
    // Wait for completion (timeout = 1 second)
    int timeout = 1000;
    while (timeout--) {
        u32 status = ioread32(priv->hw_addr + HW_FW_MAILBOX_STATUS);
        if (status & FW_STATUS_COMPLETE)
            break;
        usleep_range(1000, 2000);
    }
    
    if (timeout <= 0) {
        pr_err("Firmware command timeout\n");
        return -ETIMEDOUT;  // Firmware problem
    }
    
    // Read response
    memcpy_fromio(&cmd, priv->hw_addr + HW_FW_MAILBOX, sizeof(cmd));
    
    if (cmd.status != FW_STATUS_SUCCESS) {
        pr_err("Firmware command failed: status=0x%08x\n", cmd.status);
        return -EIO;  // Firmware problem
    }
    
    pr_info("✓ Firmware version: %u.%u.%u\n",
            cmd.version_major, cmd.version_minor, cmd.version_patch);
    
    return 0;
}
```

**Common Firmware Issues:**

| Symptom | Likely Cause | How to Fix |
|---------|--------------|------------|
| Commands timeout | Firmware hung or wrong command format | Reset device, check command structure |
| Features don't work | Firmware doesn't support feature | Check firmware version, upgrade |
| Wrong statistics | Firmware bug | Upgrade firmware, use software counters |
| Device stops after init | Firmware crash | Check firmware health register, collect crash dump |
| Inconsistent behavior | Firmware race condition | Add delays between commands, report to vendor |

**Firmware vs Driver Decision:**
```c
// If this fails, it's likely firmware
static int is_firmware_problem(struct my_nic_priv *priv)
{
    // Test 1: Can we communicate with firmware?
    if (test_firmware_commands(priv) < 0)
        return 1;  // Firmware not responding
    
    // Test 2: Does firmware version match driver expectations?
    if (priv->fw_version < MIN_SUPPORTED_FW_VERSION) {
        pr_err("Firmware too old: %u.%u (need %u.%u+)\n",
               priv->fw_version >> 16, priv->fw_version & 0xFFFF,
               MIN_SUPPORTED_FW_VERSION >> 16, MIN_SUPPORTED_FW_VERSION & 0xFFFF);
        return 1;  // Firmware version issue
    }
    
    // Test 3: Does firmware report errors?
    u32 fw_status = ioread32(priv->hw_addr + HW_FW_STATUS);
    if (fw_status & FW_STATUS_ERROR) {
        pr_err("Firmware reports error: 0x%08x\n", fw_status);
        return 1;  // Firmware error
    }
    
    return 0;  // Firmware OK
}
```

---

### Layer 3: Kernel Driver Problems

**Symptoms:**
- Module fails to load
- Kernel panics or oopses
- Memory corruption
- Deadlocks
- Wrong packet handling

**Diagnostic Commands:**
```bash
# Check if module loaded
lsmod | grep my_nic

# Check driver probe status
dmesg | grep -A 20 "my_nic"

# Check module parameters
cat /sys/module/my_nic/parameters/*

# Check netdev state
ip link show eth0
cat /sys/class/net/eth0/operstate

# Check driver statistics
ethtool -S eth0

# Check for kernel errors
dmesg | grep -i "bug\|warn\|oops\|panic"

# Check RCU stalls
dmesg | grep -i "rcu"

# Check for memory leaks
cat /proc/slabinfo | grep my_nic
```

**Driver Test: Packet Path**
```c
// Test RX path
static int test_rx_path(struct my_nic_priv *priv)
{
    // Check if RX rings are set up
    if (!priv->rx_ring) {
        pr_err("RX ring not allocated\n");
        return -EINVAL;  // Driver bug
    }
    
    // Check ring pointers
    u32 hw_head = ioread32(priv->hw_addr + HW_RX_HEAD);
    u32 sw_tail = priv->rx_ring->next;
    
    pr_info("RX: HW head=%u, SW tail=%u\n", hw_head, sw_tail);
    
    // If pointers are equal and no packets received, might be issue
    if (hw_head == sw_tail && priv->stats.rx_packets == 0) {
        pr_warn("RX ring appears stuck\n");
        // But need more tests to confirm...
    }
    
    // Check descriptor ownership
    struct hw_rx_descriptor *desc = &priv->rx_ring->desc[sw_tail];
    if (desc->flags & RX_DESC_DD) {
        pr_info("✓ RX descriptor has DD bit set (hardware wrote it)\n");
    } else {
        pr_warn("RX descriptor DD bit not set (no packets received)\n");
    }
    
    return 0;
}

// Test TX path
static int test_tx_path(struct my_nic_priv *priv)
{
    // Allocate test packet
    struct sk_buff *skb = netdev_alloc_skb(priv->netdev, 64);
    if (!skb) {
        pr_err("Failed to allocate test skb\n");
        return -ENOMEM;
    }
    
    // Fill with test pattern
    skb_put(skb, 64);
    memset(skb->data, 0xAA, 64);
    
    // Try to transmit
    netdev_tx_t ret = my_nic_xmit(skb, priv->netdev);
    
    if (ret != NETDEV_TX_OK) {
        pr_err("TX failed: %d\n", ret);
        dev_kfree_skb(skb);
        return -EIO;
    }
    
    // Wait for TX completion
    msleep(100);
    
    u32 hw_head = ioread32(priv->hw_addr + HW_TX_HEAD);
    pr_info("TX: HW head moved to %u\n", hw_head);
    
    if (hw_head != 0) {
        pr_info("✓ TX appears to be working\n");
        return 0;
    } else {
        pr_err("TX head didn't move - hardware not processing?\n");
        return -EIO;
    }
}
```

**Common Driver Issues:**

| Symptom | Likely Cause | How to Debug |
|---------|--------------|--------------|
| Module won't load | Missing dependencies, version mismatch | `dmesg`, check kernel version |
| Kernel panic on load | Bad pointer, wrong register access | Use `addr2line` on panic address |
| Module loads but no netdev | `register_netdev()` failed | Check return value, `dmesg` |
| Packets not received | NAPI not scheduled, interrupt issue | Check `/proc/interrupts`, test with `napi_schedule()` |
| Packets not sent | TX ring full, DMA not working | Dump TX ring, check `ethtool -S` |
| Memory leak | Forgot to free skb or DMA buffers | Use `kmemleak`, check `/proc/slabinfo` |
| Deadlock | Lock ordering issue | Check `echo t > /proc/sysrq-trigger` for backtrace |

**Driver vs Hardware/Firmware Decision:**
```c
static void diagnose_issue(struct my_nic_priv *priv)
{
    pr_info("=== Diagnostics ===\n");
    
    // 1. Hardware test
    if (test_hardware_presence(priv) < 0) {
        pr_err("→ HARDWARE PROBLEM\n");
        return;
    }
    
    // 2. Firmware test
    if (is_firmware_problem(priv)) {
        pr_err("→ FIRMWARE PROBLEM\n");
        return;
    }
    
    // 3. RX path test
    if (test_rx_path(priv) < 0) {
        pr_err("→ DRIVER PROBLEM (RX path)\n");
        return;
    }
    
    // 4. TX path test
    if (test_tx_path(priv) < 0) {
        pr_err("→ DRIVER PROBLEM (TX path)\n");
        return;
    }
    
    pr_info("→ All basic tests passed, issue might be SOFTWARE/CONFIG\n");
}
```

---

### Layer 4: Software/Configuration Problems

**Symptoms:**
- Driver loads, device works, but application doesn't
- Intermittent connectivity
- Wrong routing/forwarding
- Performance issues
- Security/firewall blocking

**Diagnostic Commands:**
```bash
# Check interface state
ip link show eth0
# Should see: state UP

# Check IP configuration
ip addr show eth0

# Check routing
ip route show
ip -6 route show

# Check ARP/neighbor table
ip neigh show

# Check firewall
iptables -L -v -n
ip6tables -L -v -n
nft list ruleset

# Check if packets reaching interface
tcpdump -i eth0 -n
# If you see packets here but app doesn't receive → software problem

# Check socket state
ss -tupn | grep :80
netstat -tupn | grep :80

# Check application
strace -e trace=network your_app
ltrace -e 'socket*' your_app

# Check for packet drops
netstat -i eth0
# RX-DRP should be 0

ip -s link show eth0
# Look for "dropped" count

# Check tc (traffic control) rules
tc qdisc show dev eth0
tc filter show dev eth0
```

**Software Test: End-to-End**
```bash
#!/bin/bash
# Systematic test from hardware to application

echo "=== Layer by Layer Test ==="

# 1. Hardware layer
echo -n "Hardware: "
if lspci | grep -q "Network controller"; then
    echo "✓ Device detected"
else
    echo "✗ Device NOT detected - HARDWARE PROBLEM"
    exit 1
fi

# 2. Driver layer
echo -n "Driver:   "
if ip link show eth0 &>/dev/null; then
    echo "✓ Interface exists"
else
    echo "✗ Interface missing - DRIVER PROBLEM"
    exit 1
fi

# 3. Link layer
echo -n "Link:     "
if ethtool eth0 | grep -q "Link detected: yes"; then
    echo "✓ Link up"
else
    echo "✗ Link down - check cable/switch"
    exit 1
fi

# 4. Network layer
echo -n "Network:  "
if ip addr show eth0 | grep -q "inet "; then
    echo "✓ IP configured"
else
    echo "✗ No IP address - CONFIGURATION PROBLEM"
    exit 1
fi

# 5. Routing
echo -n "Routing:  "
if ip route | grep -q "default"; then
    echo "✓ Default route exists"
else
    echo "⚠ No default route"
fi

# 6. Connectivity (ping)
echo -n "Ping:     "
if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
    echo "✓ Can reach internet"
else
    echo "✗ Cannot ping - check routing/firewall"
    # More specific test
    if ping -c 1 -W 2 192.168.1.1 &>/dev/null; then
        echo "  → Gateway reachable, DNS/routing issue"
    else
        echo "  → Gateway unreachable, L2/L3 issue"
    fi
fi

# 7. Application layer
echo -n "DNS:      "
if nslookup google.com &>/dev/null; then
    echo "✓ DNS working"
else
    echo "✗ DNS not working - check /etc/resolv.conf"
fi

# 8. Socket test
echo -n "Sockets:  "
if timeout 2 bash -c "echo > /dev/tcp/8.8.8.8/53"; then
    echo "✓ Can create sockets"
else
    echo "✗ Cannot create sockets - SOFTWARE/FIREWALL PROBLEM"
fi
```

**Common Software Issues:**

| Symptom | Likely Cause | How to Fix |
|---------|--------------|------------|
| Interface down | Not brought up | `ip link set eth0 up` |
| No IP address | DHCP not running, static not configured | `dhclient eth0` or configure static |
| Can't ping gateway | ARP issue, wrong subnet | Check `ip neigh`, `ip route` |
| Can ping but no apps work | Firewall blocking | Check `iptables`, `selinux` |
| Slow performance | MTU mismatch, QoS, CPU | Check `ip link`, tune interrupt affinity |
| Drops in `netstat -i` | Receive buffer too small | Increase `net.core.rmem_max` |

---

### Systematic Debug Flow

**Step 1: Gather Initial Information**
```bash
# Create debug snapshot
cat > debug_snapshot.sh << 'EOF'
#!/bin/bash
OUTDIR="debug_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"

# Hardware
lspci -vvv -s 03:00.0 > "$OUTDIR/lspci.txt"
setpci -s 03:00.0 0x00-0xff > "$OUTDIR/pci_config.txt"

# Driver
lsmod | grep my_nic > "$OUTDIR/lsmod.txt"
modinfo my_nic > "$OUTDIR/modinfo.txt"
dmesg > "$OUTDIR/dmesg.txt"

# Network
ip link show > "$OUTDIR/ip_link.txt"
ip addr show > "$OUTDIR/ip_addr.txt"
ip route show > "$OUTDIR/ip_route.txt"
ethtool eth0 > "$OUTDIR/ethtool.txt"
ethtool -S eth0 > "$OUTDIR/ethtool_stats.txt"

# Interrupts
cat /proc/interrupts | grep my_nic > "$OUTDIR/interrupts.txt"

# System
uname -a > "$OUTDIR/uname.txt"
cat /proc/meminfo > "$OUTDIR/meminfo.txt"
cat /proc/cpuinfo > "$OUTDIR/cpuinfo.txt"

# Compress
tar czf "$OUTDIR.tar.gz" "$OUTDIR"
echo "Debug snapshot saved to $OUTDIR.tar.gz"
EOF

chmod +x debug_snapshot.sh
./debug_snapshot.sh
```

**Step 2: Isolate the Layer**
```bash
# Test each layer independently

# Layer 1: Hardware
echo "Testing hardware..."
lspci -vvv -s 03:00.0 | grep -i "lnk\|error"

# Layer 2: Firmware  
echo "Testing firmware..."
ethtool -i eth0 | grep firmware

# Layer 3: Driver
echo "Testing driver..."
ethtool -t eth0  # Run self-test
echo $?  # 0 = pass, non-zero = fail

# Layer 4: Software
echo "Testing software..."
ping -c 1 8.8.8.8
```

**Step 3: Compare Working vs Broken**

| What to Compare | Working System | Broken System |
|-----------------|----------------|---------------|
| PCIe link | `lspci -vvv` link speed/width | Same command |
| Register values | Dump with `setpci` | Same |
| Interrupt count | `/proc/interrupts` | Should increase |
| RX/TX stats | `ethtool -S eth0` | Should increase |
| Packet visibility | `tcpdump -i eth0` | Should see packets |

**Step 4: Enable Debug Logging**
```bash
# Enable driver debug
echo 'options my_nic debug=7' > /etc/modprobe.d/my_nic.conf
rmmod my_nic
modprobe my_nic

# Enable netdev debug
echo 'file net/core/dev.c +p' > /sys/kernel/debug/dynamic_debug/control

# Enable DMA debug
echo 1 > /sys/kernel/debug/dma-api/verbose

# Enable IOMMU debug (in GRUB)
# intel_iommu=on,debug or amd_iommu=on,debug

# Check kernel log with timestamps
dmesg -T | grep my_nic
```

**Step 5: Use Right Tool for Right Layer**

| Layer | Primary Tool | Secondary Tools |
|-------|-------------|-----------------|
| **Hardware** | `lspci`, `setpci` | Oscilloscope, PCIe analyzer |
| **Firmware** | `ethtool -i`, vendor tools | Firmware debugger |
| **Driver** | `dmesg`, `ftrace`, `kgdb` | Crash dumps, printk |
| **Software** | `tcpdump`, `strace` | Wireshark, gdb |

---

### Decision Matrix

Use this to quickly identify the problem layer:

```
┌─────────────────────────────────────────────────────────────────┐
│ Does lspci show device?                                         │
│   NO  → HARDWARE (PCIe connection, power, BIOS)                │
│   YES → Continue                                                │
├─────────────────────────────────────────────────────────────────┤
│ Can you read registers (setpci/driver)?                         │
│   NO  → HARDWARE (BAR mapping, device dead)                    │
│   YES → Continue                                                │
├─────────────────────────────────────────────────────────────────┤
│ Does firmware respond to commands?                              │
│   NO  → FIRMWARE (hung, crashed, wrong version)                │
│   YES → Continue                                                │
├─────────────────────────────────────────────────────────────────┤
│ Does driver load successfully?                                  │
│   NO  → DRIVER (probe failed, panic, module error)             │
│   YES → Continue                                                │
├─────────────────────────────────────────────────────────────────┤
│ Does ethtool -t pass?                                           │
│   NO  → DRIVER or FIRMWARE (self-test failure)                 │
│   YES → Continue                                                │
├─────────────────────────────────────────────────────────────────┤
│ Do counters increment (ethtool -S)?                             │
│   NO  → DRIVER (DMA issue, interrupt issue)                    │
│   YES → Continue                                                │
├─────────────────────────────────────────────────────────────────┤
│ Does tcpdump see packets?                                       │
│   NO  → DRIVER (RX path broken)                                │
│   YES → Continue                                                │
├─────────────────────────────────────────────────────────────────┤
│ Can you ping?                                                    │
│   NO  → SOFTWARE (IP config, routing, firewall)                │
│   YES → Continue                                                │
├─────────────────────────────────────────────────────────────────┤
│ Does application work?                                           │
│   NO  → SOFTWARE (app bug, socket issue, permissions)          │
│   YES → Everything working!                                     │
└─────────────────────────────────────────────────────────────────┘
```

---

### Real-World Example: Packet Loss Investigation

**Scenario:** Experiencing 10% packet loss

```bash
# Step 1: Where are packets being lost?
ethtool -S eth0 | grep -i "drop\|err\|miss"

# If rx_missed_errors > 0
#   → Driver too slow to process (CPU issue)
# If rx_dma_failed > 0  
#   → Hardware DMA problem
# If rx_csum_errors > 0
#   → Bad packets or hardware checksum issue

# Step 2: Check if hardware is receiving
ethtool -S eth0 | grep rx_packets
# Wait 1 second
ethtool -S eth0 | grep rx_packets
# Should increase - if not, link/hardware issue

# Step 3: Check if driver is processing
cat /proc/interrupts | grep eth0
# Wait 1 second  
cat /proc/interrupts | grep eth0
# Should increase - if not, interrupt issue

# Step 4: Check if packets reach stack
netstat -s | grep -i "dropped\|error"
# TCPBacklogDrop → Socket receive buffer full (app too slow)
# InErrors → Checksum or other L3 errors

# Step 5: Check application
strace -e recvfrom -p $(pidof your_app)
# If you see EAGAIN → App needs to read faster
# If you see nothing → App not reading at all

# Conclusion:
# - Drops in ethtool -S → Hardware/Driver
# - Drops in netstat -s → Kernel/Software  
# - Drops in app → Application
```

---

### Debugging Checklist for Custom Driver

When developing a custom driver, test in this order:

**Phase 1: Hardware Validation**
- [ ] Device appears in `lspci`
- [ ] Can read vendor/device ID
- [ ] Scratch register test passes
- [ ] All BARs mapped correctly
- [ ] MSI-X vectors allocated

**Phase 2: Firmware Validation**
- [ ] Firmware version readable
- [ ] Commands complete (no timeout)
- [ ] Firmware health status OK
- [ ] Can enable/disable features

**Phase 3: Driver RX Path**
- [ ] RX ring allocated
- [ ] DMA buffers allocated
- [ ] Descriptors programmed
- [ ] Interrupts fire on packet RX
- [ ] NAPI schedules correctly
- [ ] Packets reach `tcpdump`

**Phase 4: Driver TX Path**
- [ ] TX ring allocated
- [ ] Can queue packets
- [ ] Hardware processes descriptors
- [ ] TX completions received
- [ ] Packets appear on wire

**Phase 5: Advanced Features**
- [ ] RSS distributes packets
- [ ] Flow table entries install
- [ ] Hardware offloads work (TSO, checksum)
- [ ] Statistics accurate
- [ ] No memory leaks

**Phase 6: Stress Testing**
- [ ] Sustained high throughput
- [ ] Many concurrent flows
- [ ] MTU changes
- [ ] Interface up/down cycles
- [ ] Module load/unload cycles

---

## Hardware VXLAN Offload: Do You Need a Custom Driver?

**Short Answer:** No, most modern NICs already support VXLAN offload through existing drivers. You probably don't need to write a custom driver.

### What NICs Support VXLAN Offload (Out of the Box)

**Tier 1: Full Hardware VXLAN Offload**
```
┌─────────────────────────────────────────────────────────────┐
│ NIC                  │ Driver    │ VXLAN Offload Support    │
├──────────────────────┼───────────┼──────────────────────────┤
│ Mellanox ConnectX-5+ │ mlx5_core │ ✓ Encap/Decap           │
│                      │           │ ✓ TSO over VXLAN        │
│                      │           │ ✓ Checksum offload      │
│                      │           │ ✓ RSS on inner headers  │
│                      │           │ ✓ Flow steering (DOCA)  │
├──────────────────────┼───────────┼──────────────────────────┤
│ Intel X710/XXV710    │ i40e      │ ✓ Encap/Decap           │
│ (700 series)         │           │ ✓ TSO over VXLAN        │
│                      │           │ ✓ Checksum offload      │
│                      │           │ ✓ RSS on inner headers  │
├──────────────────────┼───────────┼──────────────────────────┤
│ Intel E810           │ ice       │ ✓ Encap/Decap           │
│ (800 series)         │           │ ✓ TSO over VXLAN        │
│                      │           │ ✓ Checksum offload      │
│                      │           │ ✓ Dynamic tunneling     │
├──────────────────────┼───────────┼──────────────────────────┤
│ Broadcom BCM57xxx    │ bnxt_en   │ ✓ Encap/Decap           │
│                      │           │ ✓ TSO over VXLAN        │
│                      │           │ ✓ Checksum offload      │
├──────────────────────┼───────────┼──────────────────────────┤
│ NVIDIA BlueField DPU │ mlx5_core │ ✓✓ Full offload         │
│                      │           │ ✓✓ Hardware flow tables │
│                      │           │ ✓✓ OVS-DOCA integration │
└──────────────────────┴───────────┴──────────────────────────┘
```

**Tier 2: Partial VXLAN Offload**
```
┌─────────────────────────────────────────────────────────────┐
│ NIC                  │ Driver    │ VXLAN Offload Support    │
├──────────────────────┼───────────┼──────────────────────────┤
│ Intel X540/X550      │ ixgbe     │ ⚠️ TSO only             │
│                      │           │ ⚠️ Checksum only        │
│                      │           │ ❌ No encap/decap       │
├──────────────────────┼───────────┼──────────────────────────┤
│ Intel I350           │ igb       │ ⚠️ Basic checksum only  │
│                      │           │ ❌ No tunnel offload    │
├──────────────────────┼───────────┼──────────────────────────┤
│ Realtek RTL8111      │ r8169     │ ❌ No VXLAN offload     │
├──────────────────────┼───────────┼──────────────────────────┤
│ Older Broadcom       │ tg3       │ ❌ No VXLAN offload     │
└──────────────────────┴───────────┴──────────────────────────┘
```

### How to Check If Your NIC Supports VXLAN Offload

**Method 1: Check netdev features**
```bash
# Check if VXLAN offload is supported
ethtool -k eth0 | grep -i "tunnel\|encap"

# Look for these features:
# tx-udp_tnl-segmentation: on     ← TSO over VXLAN
# tx-udp_tnl-csum-segmentation: on ← Checksum + TSO
# rx-udp_tnl-port-offload: on     ← Dynamic port config

# Detailed feature list
ethtool -k eth0
# tx-udp-tnl-segmentation: on [fixed]
# tx-udp-tnl-csum-segmentation: on [fixed]
```

**Method 2: Check driver support**
```bash
# Check what driver is loaded
ethtool -i eth0
# driver: mlx5_core
# version: 5.9-0
# firmware-version: 16.35.2000

# Check driver features in sysfs
cat /sys/class/net/eth0/features
# Look for bits: 0x4000 (NETIF_F_GSO_UDP_TUNNEL)
```

**Method 3: Test with actual VXLAN**
```bash
# Create VXLAN interface
ip link add vxlan100 type vxlan \
    id 100 \
    remote 192.168.1.2 \
    local 192.168.1.1 \
    dstport 4789 \
    dev eth0

# Check if offload is active
ethtool -K vxlan100 tx-udp_tnl-segmentation on
# If it succeeds, hardware supports it

# Send traffic and check hardware counters
iperf3 -c <remote> -B vxlan100

# Check if hardware is doing the work
ethtool -S eth0 | grep -i "vxlan\|tunnel\|encap"
# vxlan_encap_packets: 12345  ← Hardware is encapsulating!
```

### What "VXLAN Offload" Actually Means

**Three Levels of Offload:**

```
┌─────────────────────────────────────────────────────────────┐
│ Level 1: NO Offload (Software Only)                        │
├─────────────────────────────────────────────────────────────┤
│ CPU does:                                                   │
│   • Encapsulate each packet (add outer headers)            │
│   • Calculate checksums (inner + outer)                     │
│   • Segment large packets                                   │
│                                                             │
│ Result:                                                     │
│   • 10-50 Gbps max                                         │
│   • High CPU usage (20-40%)                                │
│   • Used by: Older NICs, virtualization without SR-IOV     │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ Level 2: Partial Offload (TSO + Checksum)                  │
├─────────────────────────────────────────────────────────────┤
│ CPU does:                                                   │
│   • Encapsulate first packet                                │
│   • Send large packet to NIC                                │
│                                                             │
│ NIC does:                                                   │
│   • Segment into MTU-sized packets (TSO)                    │
│   • Calculate checksums for all segments                    │
│                                                             │
│ Result:                                                     │
│   • 50-80 Gbps                                             │
│   • Medium CPU usage (5-15%)                               │
│   • Used by: Intel X710, some Broadcom                     │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ Level 3: Full Offload (Encap/Decap in Hardware)            │
├─────────────────────────────────────────────────────────────┤
│ CPU does:                                                   │
│   • First packet: install flow rule                         │
│                                                             │
│ NIC does:                                                   │
│   • ALL subsequent packets:                                 │
│     - Match flow                                            │
│     - Add outer Ethernet/IP/UDP/VXLAN headers              │
│     - Calculate all checksums                               │
│     - Segment if needed                                     │
│     - Forward to wire                                       │
│                                                             │
│ Result:                                                     │
│   • 100-400 Gbps (line rate)                               │
│   • Very low CPU usage (<5%)                               │
│   • Used by: Mellanox ConnectX-5+, BlueField DPU          │
└─────────────────────────────────────────────────────────────┘
```

### Using VXLAN Offload with Existing Drivers

**Scenario 1: Simple VXLAN with Kernel (Most Common)**

```bash
# 1. Check if NIC supports VXLAN offload
ethtool -k eth0 | grep udp_tnl
# tx-udp_tnl-segmentation: on  ← NIC supports it!

# 2. Create VXLAN interface
ip link add vxlan100 type vxlan \
    id 100 \
    remote 192.168.1.2 \
    local 192.168.1.1 \
    dstport 4789 \
    dev eth0

# 3. Configure IP
ip addr add 10.0.100.1/24 dev vxlan100
ip link set vxlan100 up

# 4. Send traffic - kernel automatically uses hardware offload
ping -I vxlan100 10.0.100.2

# That's it! No custom driver needed.
# Kernel sees NETIF_F_GSO_UDP_TUNNEL and uses hardware.
```

**What Happens Under the Hood:**
```c
// In kernel network stack (net/core/dev.c)
static int validate_xmit_skb(struct sk_buff *skb, struct net_device *dev)
{
    netdev_features_t features = dev->features;
    
    // Check if packet needs VXLAN encapsulation
    if (skb_is_gso(skb) && skb_shinfo(skb)->gso_type & SKB_GSO_UDP_TUNNEL) {
        // Check if hardware supports VXLAN offload
        if (features & NETIF_F_GSO_UDP_TUNNEL) {
            // ✓ Hardware supports it - pass to NIC
            // NIC will do encapsulation + segmentation
            return 0;
        } else {
            // ✗ No hardware support - do in software
            return skb_gso_segment(skb);  // CPU does the work
        }
    }
    
    return 0;
}
```

**Scenario 2: OVS with VXLAN Offload**

```bash
# 1. Install OVS with hardware offload support
apt install openvswitch-switch-dpdk

# 2. Enable hardware offload
ovs-vsctl set Open_vSwitch . other_config:hw-offload=true

# 3. Create OVS bridge
ovs-vsctl add-br br0

# 4. Add physical port
ovs-vsctl add-port br0 eth0

# 5. Add VXLAN port with hardware offload
ovs-vsctl add-port br0 vxlan0 -- \
    set interface vxlan0 type=vxlan \
    options:remote_ip=192.168.1.2 \
    options:key=100 \
    options:dst_port=4789

# 6. OVS automatically uses hardware offload if available
# Check:
ovs-appctl dpctl/dump-flows type=offloaded
# Shows flows offloaded to hardware
```

**What OVS Does:**
- First packet: Software path, OVS decides to forward
- OVS installs flow rule in hardware (via TC flower or driver)
- Subsequent packets: Hardware does VXLAN encap automatically
- Zero CPU involvement after first packet

**Scenario 3: Kubernetes with CNI (Automatic)**

```yaml
# Most Kubernetes CNIs automatically use hardware offload
# if available:

# Calico with VXLAN
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - cidr: 10.244.0.0/16
      encapsulation: VXLAN  # Uses hardware if available

# Cilium (also auto-detects)
# Flannel (also auto-detects)
# Antrea (also auto-detects)
```

### When You DON'T Need a Custom Driver

**✅ Existing driver is sufficient if:**

1. **Standard VXLAN (UDP port 4789)**
   - All modern drivers support this
   - Kernel handles it automatically

2. **Stateless encapsulation**
   - Just wrapping packets, no flow tracking
   - Any NIC with NETIF_F_GSO_UDP_TUNNEL works

3. **Using OVS or Linux kernel networking**
   - They already integrate with hardware offload
   - Just enable `hw-offload=true`

4. **Standard VNI (VXLAN Network Identifier)**
   - 24-bit VNI, standard format
   - All drivers support this

5. **Common MTU (1500 or 9000)**
   - Standard packet sizes
   - Hardware handles segmentation

**Example: Mellanox ConnectX-5 (No Custom Code Needed)**
```bash
# Check what's supported
ethtool -k eth0
# tx-udp_tnl-segmentation: on
# tx-udp_tnl-csum-segmentation: on
# tx-tunnel-remcsum-segmentation: on

# Create VXLAN
ip link add vxlan100 type vxlan id 100 remote 192.168.1.2 dev eth0

# Send 100 Gbps - hardware does everything
iperf3 -c remote -B vxlan100 -P 8

# Check hardware counters
ethtool -S eth0 | grep vxlan
# tx_vxlan_encap_packets: 12345678  ← All in hardware!
```

### When You MIGHT Need Custom Driver Work

**⚠️ Custom driver needed if:**

1. **Non-standard encapsulation**
   ```
   NOT standard VXLAN:
   • Custom UDP port (not 4789)
   • Modified VXLAN header format
   • Custom outer IP options
   • Additional headers (proprietary)
   ```

2. **Stateful encapsulation**
   ```
   Need flow tracking:
   • Per-flow VNI assignment
   • Dynamic tunnel endpoints
   • Connection tracking integration
   • NAT + encapsulation
   ```

3. **Hardware doesn't expose feature**
   ```
   Hardware can do it, but driver doesn't:
   • Feature exists in firmware
   • Register interface not exposed
   • Need to program hardware directly
   ```

4. **Performance beyond driver capability**
   ```
   Need ultra-low latency:
   • <5µs encapsulation latency
   • Bypass OVS control plane
   • Direct hardware flow programming
   • Zero-copy to GPU/storage
   ```

5. **Multiple encapsulation layers**
   ```
   Complex scenarios:
   • VXLAN inside GRE
   • Double VXLAN (VXLAN-in-VXLAN)
   • MPLS + VXLAN
   • Custom multi-layer protocols
   ```

### Example: Check Your Hardware Right Now

**Quick Test Script:**
```bash
#!/bin/bash
# Check VXLAN hardware offload capability

echo "=== VXLAN Hardware Offload Check ==="
echo

NIC="eth0"  # Change to your interface

# 1. Check driver
DRIVER=$(ethtool -i $NIC | grep driver | awk '{print $2}')
echo "Driver: $DRIVER"

# 2. Check features
echo -e "\nVXLAN-related features:"
ethtool -k $NIC | grep -i "tunnel\|encap\|udp_tnl"

# 3. Verdict
if ethtool -k $NIC | grep -q "tx-udp_tnl-segmentation: on"; then
    echo -e "\n✓ Hardware VXLAN offload SUPPORTED"
    echo "  You can use kernel VXLAN without custom driver"
else
    echo -e "\n✗ Hardware VXLAN offload NOT supported"
    echo "  VXLAN will work in software (slower)"
fi

# 4. Performance estimate
if ethtool -k $NIC | grep -q "tx-udp_tnl-segmentation: on"; then
    echo -e "\nExpected VXLAN throughput:"
    
    if ethtool $NIC | grep -q "Speed: 100000"; then
        echo "  • ~80-100 Gbps (100G NIC with offload)"
    elif ethtool $NIC | grep -q "Speed: 40000"; then
        echo "  • ~35-40 Gbps (40G NIC with offload)"
    elif ethtool $NIC | grep -q "Speed: 25000"; then
        echo "  • ~22-25 Gbps (25G NIC with offload)"
    elif ethtool $NIC | grep -q "Speed: 10000"; then
        echo "  • ~9-10 Gbps (10G NIC with offload)"
    fi
else
    echo -e "\nExpected VXLAN throughput (software):"
    echo "  • ~5-15 Gbps (CPU-limited)"
fi
```

**Run it:**
```bash
chmod +x check_vxlan_offload.sh
./check_vxlan_offload.sh
```

### Integration with Existing Drivers

**You DON'T write encapsulation code. The driver already has it.**

**Example: How mlx5_core driver handles VXLAN**
```c
// In drivers/net/ethernet/mellanox/mlx5/core/en_tx.c
// (You don't modify this - it's already there)

static netdev_tx_t mlx5e_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct mlx5e_priv *priv = netdev_priv(dev);
    
    // Check if this is a tunneled packet
    if (skb->encapsulation) {
        // Get tunnel type
        if (skb->inner_protocol_type == ENCAP_TYPE_ETHER) {
            switch (skb->inner_protocol) {
            case htons(ETH_P_IP):
            case htons(ETH_P_IPV6):
                // VXLAN packet detected
                
                // Hardware will:
                // 1. Read inner headers
                // 2. Add outer Ethernet/IP/UDP/VXLAN
                // 3. Calculate checksums
                // 4. Segment if needed
                // 5. Send to wire
                
                // Driver just tells hardware "this is VXLAN"
                mlx5e_tx_tunnel_offload(skb, &wqe->eth, priv);
                break;
            }
        }
    }
    
    // Submit to hardware
    mlx5e_sq_xmit(sq, skb, wqe, pi);
    return NETDEV_TX_OK;
}

// This code is ALREADY in the driver!
// You just configure VXLAN interface and it works.
```

### Summary Decision Tree

```
Do you need VXLAN encapsulation offload?
  │
  ├─→ YES: Standard VXLAN (UDP 4789, standard format)
  │    └─→ Check: ethtool -k eth0 | grep udp_tnl
  │         │
  │         ├─→ Supported: Use kernel VXLAN or OVS
  │         │   └─→ ✅ NO CUSTOM DRIVER NEEDED
  │         │
  │         └─→ Not supported: Either accept software performance
  │             or upgrade NIC
  │
  └─→ YES: Non-standard encapsulation
       └─→ Check: Can existing driver be configured?
            │
            ├─→ YES (different port, etc.): Configure driver
            │   └─→ ✅ NO CUSTOM DRIVER NEEDED
            │
            └─→ NO (custom protocol, headers)
                └─→ ⚠️  CUSTOM DRIVER WORK NEEDED
                    (Or use DOCA/userspace if available)
```

**Bottom Line:**
- **99% of VXLAN use cases**: Existing drivers work fine
- **Use OVS-DOCA** if you have BlueField and need max performance
- **Custom driver only if**: Non-standard protocol or hardware feature not exposed

Your statement is **mostly correct** - modern Ethernet drivers already handle VXLAN offload. You'd only need custom work for exotic scenarios.

---

## Deep Dive: VXLAN Offload Code Paths

Want to understand how VXLAN offload actually works under the hood? Here's where to look in the code.

### Kernel Code Organization

```
linux/
├── net/
│   ├── core/
│   │   └── dev.c                    # Core netdev, feature negotiation
│   ├── ipv4/
│   │   └── udp_tunnel_core.c        # UDP tunnel core (VXLAN, Geneve)
│   └── vxlan/
│       └── vxlan_core.c             # VXLAN protocol implementation
│
├── drivers/net/ethernet/
│   ├── mellanox/mlx5/core/
│   │   ├── en_main.c                # Network device setup
│   │   ├── en_tx.c                  # TX path, offload logic
│   │   ├── en_rx.c                  # RX path, decapsulation
│   │   ├── en_tc.c                  # TC offload, flow tables
│   │   └── eswitch_offloads.c       # SR-IOV, hardware switching
│   │
│   ├── intel/i40e/
│   │   ├── i40e_main.c              # Device initialization
│   │   ├── i40e_txrx.c              # TX/RX with tunnel offload
│   │   └── i40e_nvm.c               # Firmware/NVM management
│   │
│   └── intel/ice/
│       ├── ice_main.c               # Device initialization
│       ├── ice_txrx.c               # TX/RX path
│       └── ice_flex_pipe.c          # Dynamic protocol parser
│
└── include/linux/
    ├── netdevice.h                  # NETIF_F_* feature flags
    └── skbuff.h                     # sk_buff, GSO types
```

### Key Files to Read

**1. Feature Advertisement: How Driver Tells Kernel It Supports VXLAN**

**File:** `drivers/net/ethernet/mellanox/mlx5/core/en_main.c`

```c
// Location: mlx5e_build_nic_netdev()
// How mlx5 driver advertises VXLAN offload capability

static void mlx5e_build_nic_netdev(struct net_device *netdev)
{
    struct mlx5e_priv *priv = netdev_priv(netdev);
    struct mlx5_core_dev *mdev = priv->mdev;
    
    // Basic features
    netdev->hw_features = NETIF_F_SG;           // Scatter-gather
    netdev->hw_features |= NETIF_F_IP_CSUM;     // IPv4 checksum
    netdev->hw_features |= NETIF_F_IPV6_CSUM;   // IPv6 checksum
    netdev->hw_features |= NETIF_F_TSO;         // TCP segmentation
    netdev->hw_features |= NETIF_F_TSO6;        // TCP segmentation IPv6
    
    // ★ VXLAN offload features ★
    if (mlx5_vxlan_allowed(mdev)) {
        netdev->hw_features |= NETIF_F_GSO_UDP_TUNNEL;
        // ^ Hardware can segment packets with UDP tunnel (VXLAN/Geneve)
        
        netdev->hw_features |= NETIF_F_GSO_UDP_TUNNEL_CSUM;
        // ^ Hardware can calculate checksums for tunneled packets
        
        netdev->hw_enc_features |= NETIF_F_IP_CSUM;
        netdev->hw_enc_features |= NETIF_F_IPV6_CSUM;
        // ^ Hardware can checksum inner packets
        
        netdev->hw_enc_features |= NETIF_F_TSO;
        netdev->hw_enc_features |= NETIF_F_TSO6;
        // ^ Hardware can segment inner packets
        
        netdev->gso_partial_features = NETIF_F_GSO_UDP_TUNNEL_CSUM;
        // ^ Partial offload support
        
        netdev->vlan_features |= NETIF_F_GSO_UDP_TUNNEL;
        netdev->vlan_features |= NETIF_F_GSO_UDP_TUNNEL_CSUM;
        // ^ Tunnel offload works with VLANs too
    }
    
    // Apply features to netdev
    netdev->features = netdev->hw_features;
}

// How to check if hardware supports VXLAN
static bool mlx5_vxlan_allowed(struct mlx5_core_dev *mdev)
{
    // Check firmware capabilities
    if (!MLX5_CAP_ETH(mdev, tunnel_stateless_vxlan))
        return false;
    
    if (!mlx5_vxlan_capable(mdev))
        return false;
    
    return true;
}
```

**Where to look in your driver:**
```bash
# Find where your driver sets NETIF_F_GSO_UDP_TUNNEL
cd /usr/src/linux
grep -r "NETIF_F_GSO_UDP_TUNNEL" drivers/net/ethernet/
```

---

**2. TX Path: How Packets Get Encapsulated**

**File:** `net/vxlan/vxlan_core.c`

```c
// VXLAN device transmit function
static netdev_tx_t vxlan_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct vxlan_dev *vxlan = netdev_priv(dev);
    struct dst_entry *dst;
    __be32 vni = vxlan->default_dst.remote_vni;
    
    // Lookup destination (multicast, unicast, or FDB)
    dst = vxlan_find_dst(vxlan, skb);
    
    // IPv4 tunnel
    if (dst->ops->family == AF_INET) {
        struct rtable *rt = (struct rtable *)dst;
        
        // ★ Request hardware offload ★
        if (netif_is_vxlan(dev)) {
            // Tell kernel this packet needs VXLAN encapsulation
            skb->encapsulation = 1;
            skb_set_inner_protocol(skb, htons(ETH_P_TEB));
            skb_set_inner_mac_header(skb, 0);
            
            // Set GSO type to UDP tunnel
            if (skb_is_gso(skb)) {
                skb_shinfo(skb)->gso_type |= SKB_GSO_UDP_TUNNEL;
                // ^ This tells hardware: "this is a VXLAN packet"
            }
        }
        
        // Do the encapsulation (software)
        // If hardware supports offload, this adds outer headers
        // but hardware will handle segmentation and checksums
        vxlan_xmit_one(skb, dev, vni, dst, rt);
    }
    
    return NETDEV_TX_OK;
}

// Actual encapsulation
static void vxlan_xmit_one(struct sk_buff *skb, struct net_device *dev,
                           __be32 vni, struct dst_entry *dst,
                           struct rtable *rt)
{
    struct vxlanhdr *vxh;
    struct udphdr *uh;
    struct iphdr *iph;
    
    // Calculate space needed for outer headers
    int headroom = LL_RESERVED_SPACE(dst->dev) +
                   sizeof(struct iphdr) +
                   sizeof(struct udphdr) +
                   sizeof(struct vxlanhdr);
    
    // Make room for outer headers
    if (skb_cow_head(skb, headroom)) {
        // Failed to make room - drop packet
        return;
    }
    
    // Build VXLAN header
    vxh = skb_push(skb, sizeof(*vxh));
    vxh->vx_flags = htonl(VXLAN_HF_VNI);
    vxh->vx_vni = vni;
    
    // Build UDP header
    uh = skb_push(skb, sizeof(*uh));
    uh->source = htons(vxlan_src_port(vxlan, skb));
    uh->dest = htons(vxlan_dst_port);
    uh->len = htons(skb->len);
    
    // ★ Checksum offload request ★
    if (skb->ip_summed == CHECKSUM_PARTIAL) {
        // Tell hardware to calculate UDP checksum
        uh->check = 0;
        skb->csum_start = skb_transport_header(skb) - skb->head;
        skb->csum_offset = offsetof(struct udphdr, check);
    }
    
    // Build outer IP header
    iph = skb_push(skb, sizeof(*iph));
    iph->version = 4;
    iph->ihl = 5;
    iph->protocol = IPPROTO_UDP;
    iph->saddr = fl4.saddr;
    iph->daddr = fl4.daddr;
    iph->ttl = ttl ? : ip4_dst_hoplimit(&rt->dst);
    
    // ★ TSO offload ★
    if (skb_is_gso(skb)) {
        // Packet is larger than MTU
        // If hardware supports GSO_UDP_TUNNEL, it will segment
        // Otherwise, kernel segments in software here
        
        if (!(netdev_features & NETIF_F_GSO_UDP_TUNNEL)) {
            // Software segmentation
            struct sk_buff *segs = skb_gso_segment(skb, 0);
            // ... send each segment ...
        }
        // Else: hardware will segment
    }
    
    // Submit to lower device (physical NIC)
    iptunnel_xmit(skb, dev, rt, ...);
}
```

**File:** `net/core/dev.c`

```c
// Core validation before sending to driver
static int validate_xmit_skb(struct sk_buff *skb, struct net_device *dev)
{
    netdev_features_t features = dev->features;
    
    if (skb_is_gso(skb)) {
        // Check GSO type
        u16 gso_type = skb_shinfo(skb)->gso_type;
        
        if (gso_type & SKB_GSO_UDP_TUNNEL) {
            // This is a VXLAN packet
            
            // ★ Check if hardware supports it ★
            if (!(features & NETIF_F_GSO_UDP_TUNNEL)) {
                // Hardware doesn't support - segment in software
                pr_warn("Device doesn't support tunnel offload\n");
                return skb_gso_segment(skb);
            }
            
            // ★ Hardware supports - pass through ★
            // Driver will handle segmentation and checksums
        }
    }
    
    return 0;
}
```

---

**3. Driver TX: How Hardware Actually Does Encapsulation**

**File:** `drivers/net/ethernet/mellanox/mlx5/core/en_tx.c`

```c
// Main transmit function
netdev_tx_t mlx5e_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct mlx5e_priv *priv = netdev_priv(dev);
    struct mlx5e_txqsq *sq = priv->txq2sq[skb_get_queue_mapping(skb)];
    struct mlx5_wqe_eth_seg *eseg;
    struct mlx5e_tx_wqe *wqe;
    
    // ★ Check if this is a tunnel packet ★
    if (skb->encapsulation) {
        // This is VXLAN or other tunnel
        
        // Tell hardware about encapsulation
        eseg = &wqe->eth;
        eseg->cs_flags = MLX5_ETH_WQE_L3_CSUM | MLX5_ETH_WQE_L4_CSUM;
        // ^ Calculate outer IP and UDP checksums
        
        if (skb->inner_protocol_type != ENCAP_TYPE_NONE) {
            eseg->cs_flags |= MLX5_ETH_WQE_L3_INNER_CSUM |
                             MLX5_ETH_WQE_L4_INNER_CSUM;
            // ^ Calculate inner IP and TCP/UDP checksums too
        }
        
        // ★ TSO for tunneled packets ★
        if (skb_is_gso(skb) && 
            (skb_shinfo(skb)->gso_type & SKB_GSO_UDP_TUNNEL)) {
            
            // Tell hardware to segment
            eseg->mss = cpu_to_be16(skb_shinfo(skb)->gso_size);
            eseg->inline_hdr_sz = cpu_to_be16(mlx5e_get_inline_hdr_size(sq, skb));
            
            // Set up tunnel offload descriptor
            mlx5e_fill_sq_frag_edge(sq, wq, pi, frag_offset);
            
            // Hardware will:
            // 1. Segment large packet into MTU-sized pieces
            // 2. Add outer Ethernet/IP/UDP/VXLAN to each segment
            // 3. Calculate all checksums
            // 4. Send to wire
        }
        
        // Set up DMA mapping
        dma_addr = dma_map_single(sq->pdev, skb->data, skb_headlen(skb),
                                  DMA_TO_DEVICE);
        
        // Write descriptor to ring
        mlx5e_sq_write_wqe(sq, wqe, skb, dma_addr);
    }
    
    // Ring doorbell - tell hardware about new packet
    mlx5e_notify_hw(&sq->wq, sq->pc, sq->uar_map);
    
    return NETDEV_TX_OK;
}

// Hardware descriptor format for tunneled packets
struct mlx5_wqe_eth_seg {
    u8  rsvd0[4];
    u8  cs_flags;       // Checksum flags
    // Bit 0: L3 outer checksum
    // Bit 1: L4 outer checksum
    // Bit 2: L3 inner checksum
    // Bit 3: L4 inner checksum
    
    u8  rsvd1;
    __be16 mss;         // MSS for segmentation
    __be16 inline_hdr_sz;
    // ... outer headers inlined here ...
    
    // Hardware reads this and:
    // - Knows packet is tunneled (cs_flags bits set)
    // - Segments if mss != 0
    // - Calculates checksums
    // - Adds outer headers from inline_hdr
};
```

**File:** `drivers/net/ethernet/intel/i40e/i40e_txrx.c`

```c
// Intel i40e TX descriptor setup
static void i40e_tx_enable_csum(struct sk_buff *skb, u32 *tx_flags,
                                u32 *td_cmd, u32 *td_offset,
                                struct i40e_ring *tx_ring)
{
    // ★ Check for tunnel ★
    if (skb->encapsulation) {
        u32 tunnel = 0;
        
        // Identify tunnel type
        switch (ip_hdr(skb)->protocol) {
        case IPPROTO_UDP:
            tunnel = I40E_TX_CTX_EXT_IP_IPV4;
            
            // Check UDP dest port
            switch (udp_hdr(skb)->dest) {
            case htons(4789):  // VXLAN
                tunnel |= I40E_TXD_CTX_UDP_TUNNELING;
                break;
            case htons(6081):  // Geneve
                tunnel |= I40E_TXD_CTX_GEN_TUNNELING;
                break;
            }
            break;
        }
        
        // ★ Tell hardware: this is a tunnel packet ★
        *tx_flags |= tunnel;
        
        // Set up inner header offsets
        *td_offset |= (skb_inner_network_offset(skb) >> 1) <<
                      I40E_TX_DESC_LENGTH_IPLEN_SHIFT;
        
        // Hardware will:
        // - Parse outer and inner headers
        // - Calculate outer checksums
        // - Calculate inner checksums
        // - Segment with outer headers
    }
    
    // Set command flags
    *td_cmd |= I40E_TX_DESC_CMD_IIPT_IPV4_CSUM;  // Outer IP checksum
    *td_cmd |= I40E_TXD_CMD;                     // Enable offload
}
```

---

**4. RX Path: How Hardware Decapsulates**

**File:** `drivers/net/ethernet/mellanox/mlx5/core/en_rx.c`

```c
// Receive packet processing
static void mlx5e_handle_rx_cqe(struct mlx5e_rq *rq, struct mlx5_cqe64 *cqe)
{
    struct sk_buff *skb;
    u32 cqe_bcnt = be32_to_cpu(cqe->byte_cnt);
    
    // Allocate skb
    skb = napi_alloc_skb(&rq->channel->napi, cqe_bcnt);
    
    // Copy packet data from DMA buffer
    skb_copy_to_linear_data(skb, rq->dma_addr + offset, cqe_bcnt);
    
    // ★ Check if hardware decapsulated ★
    if (cqe->l4_hdr_type_etc & MLX5_CQE_L4_HDR_TYPE_TUNNEL) {
        // This was a tunneled packet (VXLAN/Geneve)
        
        // Hardware already removed outer headers!
        // skb->data points to inner Ethernet frame
        
        // Set inner protocol
        u8 proto = (cqe->l4_hdr_type_etc & 0x0f);
        switch (proto) {
        case MLX5_CQE_L4_HDR_TYPE_TCP:
            skb->protocol = htons(ETH_P_IP);
            break;
        case MLX5_CQE_L4_HDR_TYPE_UDP:
            skb->protocol = htons(ETH_P_IP);
            break;
        }
        
        // ★ Hardware verified checksums ★
        if (cqe->hds_ip_ext & MLX5_CQE_L4_OK) {
            // Inner L4 checksum verified
            skb->ip_summed = CHECKSUM_UNNECESSARY;
        }
        
        if (cqe->hds_ip_ext & MLX5_CQE_L3_OK) {
            // Inner L3 checksum verified  
            skb->ip_summed = CHECKSUM_UNNECESSARY;
        }
        
        // Set packet metadata
        skb->encapsulation = 1;
    }
    
    // Pass to network stack
    napi_gro_receive(&rq->channel->napi, skb);
}

// Hardware completion queue entry (CQE) format
struct mlx5_cqe64 {
    u8 l4_hdr_type_etc;
    // Bits 0-3: L4 protocol
    // Bit 4: Tunnel present
    // Bit 5: Inner L3 checksum OK
    // Bit 6: Inner L4 checksum OK
    
    __be32 byte_cnt;     // Packet length (inner packet if decapsulated)
    __be32 vlan_info;
    // ... more fields ...
    
    // Hardware fills this after processing
};
```

---

**5. Dynamic Tunnel Port Configuration**

**File:** `net/ipv4/udp_tunnel_core.c`

```c
// Register VXLAN port with hardware
void udp_tunnel_push_rx_port(struct net_device *dev, struct socket *sock,
                              unsigned short type)
{
    struct udp_tunnel_info ti;
    
    ti.type = type;  // UDP_TUNNEL_TYPE_VXLAN
    ti.sa_family = sock->sk->sk_family;
    ti.port = inet_sk(sock->sk)->inet_sport;
    
    // ★ Call driver to program hardware ★
    if (dev->netdev_ops->ndo_udp_tunnel_add) {
        dev->netdev_ops->ndo_udp_tunnel_add(dev, &ti);
        // Driver programs hardware to recognize this UDP port as VXLAN
    }
}
```

**File:** `drivers/net/ethernet/mellanox/mlx5/core/en_main.c`

```c
// Driver callback to add tunnel port
static void mlx5e_udp_tunnel_add(struct net_device *dev,
                                 struct udp_tunnel_info *ti)
{
    struct mlx5e_priv *priv = netdev_priv(dev);
    
    switch (ti->type) {
    case UDP_TUNNEL_TYPE_VXLAN:
        // ★ Program hardware to recognize this port ★
        mlx5_vxlan_add_port(priv->mdev, ntohs(ti->port));
        // Hardware will now parse packets with this UDP dest port as VXLAN
        break;
    
    case UDP_TUNNEL_TYPE_GENEVE:
        mlx5_geneve_add_port(priv->mdev, ntohs(ti->port));
        break;
    }
}

// Program hardware parser
static int mlx5_vxlan_add_port(struct mlx5_core_dev *mdev, u16 port)
{
    // Write to hardware register
    MLX5_SET(vxlan_config, in, udp_port, port);
    
    // Send command to firmware
    return mlx5_cmd_exec(mdev, in, sizeof(in), out, sizeof(out));
    
    // Firmware programs ASIC parser to recognize:
    // if (udp.dst_port == 4789 || udp.dst_port == <port>) {
    //     parse_vxlan_header();
    // }
}
```

---

### How to Trace Code Flow

**Method 1: ftrace**
```bash
# Enable function tracing for VXLAN
cd /sys/kernel/debug/tracing

# Trace all VXLAN functions
echo 'vxlan_*' > set_ftrace_filter

# Trace driver functions
echo 'mlx5e_xmit' >> set_ftrace_filter
echo 'mlx5e_handle_rx_cqe' >> set_ftrace_filter

# Enable tracing
echo function > current_tracer
echo 1 > tracing_on

# Generate traffic
ping -I vxlan100 10.0.100.2

# View trace
cat trace

# Sample output:
# ping-1234  [001]  vxlan_xmit
# ping-1234  [001]    vxlan_xmit_one
# ping-1234  [001]      ip_tunnel_xmit
# ping-1234  [001]        dev_queue_xmit
# ping-1234  [001]          mlx5e_xmit
```

**Method 2: kprobe / bpftrace**
```bash
# Trace when VXLAN packets are sent
bpftrace -e 'kprobe:vxlan_xmit { 
    printf("VXLAN TX: len=%d\n", ((struct sk_buff *)arg0)->len); 
}'

# Check if hardware offload is used
bpftrace -e '
kprobe:mlx5e_xmit {
    $skb = (struct sk_buff *)arg0;
    if ($skb->encapsulation) {
        printf("Tunnel packet: gso_type=0x%x\n", 
               $skb->gso_type);
    }
}'

# Check RX decapsulation
bpftrace -e 'kprobe:mlx5e_handle_rx_cqe {
    printf("RX packet\n");
}'
```

**Method 3: Add debug printks**
```c
// In drivers/net/ethernet/mellanox/mlx5/core/en_tx.c
netdev_tx_t mlx5e_xmit(struct sk_buff *skb, struct net_device *dev)
{
    // Add debug output
    if (skb->encapsulation) {
        pr_info("mlx5e: TX tunnel packet, len=%u, gso_type=0x%x\n",
                skb->len, skb_shinfo(skb)->gso_type);
        
        if (skb_is_gso(skb)) {
            pr_info("mlx5e: TSO enabled, gso_size=%u\n",
                    skb_shinfo(skb)->gso_size);
        }
    }
    
    // ... rest of function ...
}

// Recompile driver
cd /usr/src/linux
make M=drivers/net/ethernet/mellanox/mlx5/core
sudo rmmod mlx5_core
sudo insmod drivers/net/ethernet/mellanox/mlx5/core/mlx5_core.ko

// Check output
dmesg -w
```

**Method 4: perf**
```bash
# Record all events related to VXLAN
perf record -e net:* -ag -- sleep 10

# Generate VXLAN traffic during recording

# Analyze
perf script
# Shows every kernel function called for VXLAN
```

---

### Key Functions to Set Breakpoints On

If you're using a kernel debugger (kgdb, or QEMU):

**TX Path:**
```
1. vxlan_xmit()              // VXLAN device
2. vxlan_xmit_one()          // Add outer headers
3. validate_xmit_skb()       // Check offload support
4. mlx5e_xmit()              // Driver TX
5. mlx5e_sq_xmit()           // Write descriptor
```

**RX Path:**
```
1. mlx5e_poll_rx_cq()        // Poll completion queue
2. mlx5e_handle_rx_cqe()     // Process completion
3. napi_gro_receive()        // Pass to stack
4. __netif_receive_skb_core() // Core RX processing
```

**Configuration:**
```
1. mlx5e_udp_tunnel_add()    // Add VXLAN port
2. mlx5_vxlan_add_port()     // Program hardware
3. mlx5_cmd_exec()           // Send firmware command
```

---

### Useful Code Reading Tools

```bash
# 1. cscope - Navigate kernel code
cd /usr/src/linux
make cscope
cscope -d

# Search for: NETIF_F_GSO_UDP_TUNNEL
# Find all drivers that set this feature

# 2. LXR / Bootlin - Web-based code browser
# https://elixir.bootlin.com/linux/latest/source

# Search for function definitions
# Click to see all callers and call sites

# 3. ctags - Jump to definitions in vim
cd /usr/src/linux
make tags
vim -t mlx5e_xmit  # Opens file at function definition

# 4. git blame - See when code was added
git blame drivers/net/ethernet/mellanox/mlx5/core/en_tx.c
# Shows who added VXLAN offload support and when
```

---

### Experiments to Run

**Experiment 1: Compare Software vs Hardware**
```bash
# Disable hardware offload
ethtool -K eth0 tx-udp_tnl-segmentation off
ethtool -K eth0 tx-udp_tnl-csum-segmentation off

# Run iperf
iperf3 -c remote -t 60

# Check CPU usage
top  # Note CPU %

# Enable hardware offload
ethtool -K eth0 tx-udp_tnl-segmentation on
ethtool -K eth0 tx-udp_tnl-csum-segmentation on

# Run iperf again
iperf3 -c remote -t 60

# CPU usage should drop significantly!
```

**Experiment 2: Trace Path**
```bash
# Instrument with tracepoints
cd /sys/kernel/debug/tracing
echo 1 > events/net/netif_receive_skb/enable
echo 1 > events/net/net_dev_queue/enable
echo 1 > events/net/net_dev_xmit/enable

# Generate one ping
ping -c 1 -I vxlan100 10.0.100.2

# View trace to see exact path
cat trace
```

**Experiment 3: Modify and Test**
```bash
# Make a small change to driver
cd /usr/src/linux/drivers/net/ethernet/mellanox/mlx5/core

# Edit en_tx.c, add pr_info at start of mlx5e_xmit()

# Recompile just this module
make M=drivers/net/ethernet/mellanox/mlx5/core

# Test
sudo rmmod mlx5_core
sudo insmod drivers/net/ethernet/mellanox/mlx5/core/mlx5_core.ko
dmesg -w  # See your debug output
```

---

### Additional Resources

**Kernel Documentation:**
```bash
/usr/src/linux/Documentation/networking/
├── vxlan.rst          # VXLAN protocol details
├── segmentation-offloads.rst  # GSO/TSO explanation
├── scaling.rst        # RSS, RPS, RFS
└── driver.rst         # Driver development guide
```

**Key Commits to Study:**
```bash
# Find when VXLAN offload was added
cd /usr/src/linux
git log --all --grep="vxlan offload" --oneline

# Example commits:
# b3f63c3d vxlan: Add hardware offload support
# 1c7a4e7c mlx5: Enable VXLAN offload
# 3456abc9 i40e: Add VXLAN tunnel offload support

# Read the commit
git show b3f63c3d
# Shows exactly what code was added and why
```

**Driver-Specific Documentation:**
```
Mellanox: 
  https://docs.nvidia.com/networking/

Intel:
  Documentation/networking/device_drivers/ethernet/intel/

Look for:
  - Datasheet (register definitions)
  - Programming guide
  - Performance tuning guide
```

## References
- Linux kernel source: `net/` directory
- Kernel documentation: `Documentation/networking/`
- Linux Foundation networking wiki
- TCP/IP Illustrated series
- Understanding Linux Network Internals (O'Reilly)
