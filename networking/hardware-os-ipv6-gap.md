# Hardware vs OS Implementation Gap: IPv6 on DPUs

## The Core Problem

When hardware vendors claim "IPv6 support" but OS drivers/software don't expose it, you're dealing with **hardware capabilities that lack low-level programming interfaces**. This is extremely common with DPUs and SmartNICs.

```
┌────────────────────────────────────────────────────────────┐
│ CLAIM: "Hardware supports IPv6"                            │
│ REALITY: Hardware has silicon that CAN parse IPv6 headers │
│ PROBLEM: No low-level APIs to program that silicon        │
└────────────────────────────────────────────────────────────┘
```

---

## What "Hardware Supports IPv6" Actually Means

### Hardware Layer (ASIC/FPGA)

The DPU's eSwitch ASIC has **packet processing pipelines** implemented in silicon:

```
┌──────────────────────────────────────────────────────────────┐
│ DPU HARDWARE (eSwitch ASIC)                                  │
│                                                              │
│ Physical Port → Packet Buffer → Parser → Match Engine       │
│                                                              │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ PARSER (Hardware Logic Gates)                          │  │
│ │                                                         │  │
│ │ Ethernet (L2):                                          │  │
│ │   ✅ Dest MAC, Src MAC, EtherType                      │  │
│ │                                                         │  │
│ │ IP (L3):                                                │  │
│ │   ✅ IPv4: src_ip, dst_ip, protocol, TTL, ...          │  │
│ │   ⚠️  IPv6: src_ip (128-bit), dst_ip (128-bit), ...   │  │
│ │         ↑ Silicon exists to parse this!                │  │
│ │                                                         │  │
│ │ TCP/UDP (L4):                                           │  │
│ │   ✅ src_port, dst_port, flags                         │  │
│ └────────────────────────────────────────────────────────┘  │
│                         ↓                                    │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ MATCH ENGINE (TCAM + Hash Tables)                      │  │
│ │                                                         │  │
│ │ Flow Table Entry Format:                               │  │
│ │   struct flow_key {                                    │  │
│ │     uint8_t src_ip[16];   // 128-bit IPv6 ✅          │  │
│ │     uint8_t dst_ip[16];   // 128-bit IPv6 ✅          │  │
│ │     uint16_t src_port;                                 │  │
│ │     uint16_t dst_port;                                 │  │
│ │   };                                                   │  │
│ │                                                         │  │
│ │   ↑ Hardware can match on 128-bit IPv6 addresses!     │  │
│ └────────────────────────────────────────────────────────┘  │
│                         ↓                                    │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ ACTION ENGINE (Rewrite Logic)                          │  │
│ │                                                         │  │
│ │   ✅ Can modify 128-bit IPv6 addresses                │  │
│ │   ✅ Can update IPv6 hop limit                         │  │
│ │   ✅ Can handle IPv6 extension headers                 │  │
│ └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

**Key Point:** The hardware ASIC physically has:
- 128-bit registers for IPv6 addresses
- Logic gates to parse IPv6 headers
- TCAM entries wide enough for IPv6 matching
- ALUs (Arithmetic Logic Units) to rewrite IPv6 fields

But this hardware sits **unused** without low-level register mappings and programming interfaces!

---

## DPU Silicon Architecture: Custom Hardware Blocks

Modern DPUs contain specialized silicon blocks (ASICs) designed specifically for packet processing. Understanding these blocks is key to leveraging hardware acceleration.

### The eSwitch: Hardware Packet Processing Engine

The **eSwitch** (embedded switch) is the heart of a DPU. It's a custom ASIC with multiple specialized processing units:

```
┌──────────────────────────────────────────────────────────────┐
│ DPU CHIP ARCHITECTURE                                        │
│                                                              │
│  ┌────────────┐   ┌────────────┐   ┌────────────┐          │
│  │ Physical   │   │ Physical   │   │ PCIe to    │          │
│  │ Port 0     │   │ Port 1     │   │ Host       │          │
│  │ (100G)     │   │ (100G)     │   │            │          │
│  └─────┬──────┘   └─────┬──────┘   └─────┬──────┘          │
│        │                 │                 │                 │
│        └─────────────────┴─────────────────┘                 │
│                          │                                   │
│  ┌───────────────────────▼────────────────────────────────┐ │
│  │ PACKET BUFFER (On-chip SRAM)                          │ │
│  │ • 16 MB ultra-fast packet memory                      │ │
│  │ • 1 ns access time                                    │ │
│  │ • Circular buffer for zero-copy operations            │ │
│  └───────────────────────┬────────────────────────────────┘ │
│                          │                                   │
│  ┌───────────────────────▼────────────────────────────────┐ │
│  │ PARSER ENGINE (Custom Silicon)                        │ │
│  │                                                        │ │
│  │ • Protocol parsing state machine in hardware          │ │
│  │ • Extracts headers from L2 to L7                      │ │
│  │ • Handles encapsulation (VXLAN, GRE, MPLS)            │ │
│  │ • IPv6 extension header walker                        │ │
│  │ • 10-20 ns per packet                                 │ │
│  └───────────────────────┬────────────────────────────────┘ │
│                          │                                   │
│  ┌───────────────────────▼────────────────────────────────┐ │
│  │ FLOW TABLE / TCAM (Content-Addressable Memory)        │ │
│  │                                                        │ │
│  │ • 1-4 million flow entries                            │ │
│  │ • 256-bit wide entries (IPv6 5-tuple fits!)           │ │
│  │ • Parallel lookup across ALL entries                  │ │
│  │ • 10-20 ns lookup time regardless of table size       │ │
│  │ • Exact match + wildcard matching                     │ │
│  └───────────────────────┬────────────────────────────────┘ │
│                          │                                   │
│  ┌───────────────────────▼────────────────────────────────┐ │
│  │ ACTION ENGINE (Packet Modification Unit)              │ │
│  │                                                        │ │
│  │ • Header rewrite ALUs (128-bit operations)            │ │
│  │ • Checksum recalculation units                        │ │
│  │ • Encapsulation/decapsulation engines                 │ │
│  │ • NAT translation units                               │ │
│  │ • VLAN tag insertion/removal                          │ │
│  │ • 20-30 ns per packet                                 │ │
│  └───────────────────────┬────────────────────────────────┘ │
│                          │                                   │
│  ┌───────────────────────▼────────────────────────────────┐ │
│  │ QoS / METERING (Traffic Management)                   │ │
│  │                                                        │ │
│  │ • Token bucket rate limiters                          │ │
│  │ • Priority queues (8-16 levels)                       │ │
│  │ • Weighted fair queuing                               │ │
│  │ • 5-10 ns per packet                                  │ │
│  └───────────────────────┬────────────────────────────────┘ │
│                          │                                   │
│  ┌───────────────────────▼────────────────────────────────┐ │
│  │ DMA ENGINE (Host Interface)                           │ │
│  │                                                        │ │
│  │ • PCIe Gen4/Gen5 DMA controllers                      │ │
│  │ • Scatter-gather for large packets                    │ │
│  │ • MSI-X interrupts for completion                     │ │
│  │ • 50-100 ns PCIe round-trip                           │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Total Pipeline Latency: 100-200 ns (hardware processing)   │
│  vs CPU: 5,000-10,000 ns (50-100x slower!)                  │
└──────────────────────────────────────────────────────────────┘
```

### Parser Engine: Protocol State Machine in Silicon

The parser is implemented as a **finite state machine (FSM)** in custom silicon:

```
┌──────────────────────────────────────────────────────────────┐
│ PARSER FSM IMPLEMENTATION (HARDWARE LOGIC)                   │
│                                                              │
│ Input: Raw packet bytes from network port                   │
│                                                              │
│ State 0: Parse Ethernet                                      │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ Hardware Logic:                                        │  │
│ │   • Read bytes 0-13 (dest MAC, src MAC, EtherType)    │  │
│ │   • Extract EtherType (2 bytes at offset 12)          │  │
│ │   • Decision:                                          │  │
│ │     - 0x0800 → State 1 (IPv4)                         │  │
│ │     - 0x86DD → State 2 (IPv6)  ← We care about this! │  │
│ │     - 0x8100 → State 3 (VLAN)                         │  │
│ │   • Advance pointer by 14 bytes                        │  │
│ │   • Clock cycles: 2                                    │  │
│ └────────────────────────────────────────────────────────┘  │
│                          ↓                                   │
│ State 2: Parse IPv6 Header                                   │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ Hardware Registers (256-bit wide):                    │  │
│ │   REG_IPV6_SRC[127:0]  ← bytes 8-23                   │  │
│ │   REG_IPV6_DST[127:0]  ← bytes 24-39                  │  │
│ │   REG_HOP_LIMIT[7:0]   ← byte 7                       │  │
│ │   REG_NEXT_HDR[7:0]    ← byte 6                       │  │
│ │                                                        │  │
│ │ Parallel Operations (single clock cycle):             │  │
│ │   • Load 40 bytes into 256-bit shift register         │  │
│ │   • Extract version (bits 0-3) and validate == 6      │  │
│ │   • Extract payload_length (bytes 4-5)                │  │
│ │   • Extract next_header (byte 6)                      │  │
│ │   • Extract hop_limit (byte 7)                        │  │
│ │   • Extract src_addr (bytes 8-23) → 128-bit register  │  │
│ │   • Extract dst_addr (bytes 24-39) → 128-bit register │  │
│ │                                                        │  │
│ │ Decision logic (combinatorial):                       │  │
│ │   if (next_header == 6)  → State 4 (TCP)             │  │
│ │   if (next_header == 17) → State 5 (UDP)             │  │
│ │   if (next_header == 58) → State 6 (ICMPv6)          │  │
│ │   if (next_header == 0)  → State 7 (Hop-by-Hop)      │  │
│ │   if (next_header == 43) → State 8 (Routing Hdr)     │  │
│ │   if (next_header == 44) → State 9 (Fragment Hdr)    │  │
│ │                                                        │  │
│ │ Clock cycles: 3-4                                      │  │
│ │ Advance pointer by 40 bytes                           │  │
│ └────────────────────────────────────────────────────────┘  │
│                          ↓                                   │
│ State 4: Parse TCP Header                                    │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ Hardware Registers:                                    │  │
│ │   REG_TCP_SRC_PORT[15:0] ← bytes 0-1                  │  │
│ │   REG_TCP_DST_PORT[15:0] ← bytes 2-3                  │  │
│ │   REG_TCP_SEQ[31:0]      ← bytes 4-7                  │  │
│ │   REG_TCP_FLAGS[7:0]     ← byte 13                    │  │
│ │                                                        │  │
│ │ Clock cycles: 2                                        │  │
│ └────────────────────────────────────────────────────────┘  │
│                          ↓                                   │
│ Output: Parsed metadata structure                            │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ struct parsed_packet {                                 │  │
│ │   uint8_t  l3_protocol;     // 6 = IPv6               │  │
│ │   uint8_t  l4_protocol;     // 6 = TCP                │  │
│ │   uint8_t  ipv6_src[16];    // 128-bit source         │  │
│ │   uint8_t  ipv6_dst[16];    // 128-bit dest           │  │
│ │   uint16_t l4_src_port;     // TCP/UDP source port    │  │
│ │   uint16_t l4_dst_port;     // TCP/UDP dest port      │  │
│ │   uint8_t  hop_limit;       // TTL equivalent         │  │
│ │   uint16_t payload_offset;  // Where data starts      │  │
│ │ };                                                     │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ Total: 7-10 clock cycles @ 1 GHz = 7-10 nanoseconds         │
│                                                              │
│ Note: This is a SIMPLIFIED view. Real parsers have:          │
│   • ~50 states for all protocols                            │
│   • Exception handling for malformed packets                │
│   • Extension header chains (IPv6)                          │
│   • Multiple encapsulation levels                           │
└──────────────────────────────────────────────────────────────┘
```

### TCAM: The Magic of Parallel Lookup

**TCAM (Ternary Content-Addressable Memory)** is specialized hardware that searches all entries simultaneously:

```
┌──────────────────────────────────────────────────────────────┐
│ TCAM ARCHITECTURE                                            │
│                                                              │
│ Traditional RAM:                                             │
│   Input:  Address (e.g., 0x1000)                            │
│   Output: Data at that address                              │
│   Search: Must iterate through all addresses (slow!)        │
│                                                              │
│ TCAM:                                                        │
│   Input:  Data (e.g., IPv6 5-tuple)                         │
│   Output: Address where that data is stored                 │
│   Search: ALL entries checked in parallel (fast!)           │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│ How TCAM Works (Silicon Implementation):                    │
│                                                              │
│ Entry Structure (256 bits wide for IPv6):                   │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ Bits 0-127:   IPv6 Source Address (match value)       │  │
│ │ Bits 128-255: IPv6 Dest Address (match value)         │  │
│ │ Bits 256-383: Mask (which bits to check)              │  │
│ │               0 = don't care, 1 = must match          │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ Example Entry (Match IPv6 /64 prefix):                      │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ Match Value: 2001:0db8:0000:0001:0000:0000:0000:0000  │  │
│ │ Mask:        FFFF:FFFF:FFFF:FFFF:0000:0000:0000:0000  │  │
│ │              ↑ First 64 bits must match exactly       │  │
│ │              ↑ Last 64 bits ignored (wildcard)        │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ Hardware Lookup Process:                                     │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ Incoming packet: 2001:0db8:0000:0001:1234:5678:90ab  │  │
│ │                                                        │  │
│ │ TCAM Comparators (one per entry, running in parallel):│  │
│ │                                                        │  │
│ │ Entry 0: [2001:db8::/32]  → XOR → MATCH! (priority 0) │  │
│ │ Entry 1: [2001:db8::1/128]→ XOR → NO MATCH            │  │
│ │ Entry 2: [2001:db8:0:1/64]→ XOR → MATCH! (priority 2) │  │
│ │ ...                                                    │  │
│ │ Entry 1M: [default]       → XOR → MATCH! (priority 1M)│  │
│ │                                                        │  │
│ │ Priority Encoder:                                      │  │
│ │   Multiple matches found → Return lowest index (0)    │  │
│ │   Result: Entry 0 matched                             │  │
│ │   Action: Read action from entry 0                    │  │
│ │                                                        │  │
│ │ Latency: 1-2 clock cycles regardless of table size!   │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ Physical Implementation:                                     │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ Each TCAM cell = 2 SRAM cells + XOR gate + AND gate   │  │
│ │                                                        │  │
│ │ For 1M entries × 256 bits = 256 Mbit of TCAM          │  │
│ │ Die area: ~50-100 mm² on modern process               │  │
│ │ Power: ~20-40W (lots of parallel comparators!)        │  │
│ │                                                        │  │
│ │ Trade-off:                                             │  │
│ │   + Extremely fast (1-2 ns)                           │  │
│ │   + Constant time (doesn't scale with # entries)      │  │
│ │   - Expensive (silicon area)                          │  │
│ │   - Power hungry (all comparators always active)      │  │
│ └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### Action Engine: Packet Modification Units

The action engine contains specialized ALUs for common packet operations:

```
┌──────────────────────────────────────────────────────────────┐
│ ACTION ENGINE ARCHITECTURE                                   │
│                                                              │
│ Input: Packet buffer + Action descriptor from TCAM          │
│                                                              │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ MAC REWRITE UNIT                                       │  │
│ │                                                        │  │
│ │ Hardware:                                              │  │
│ │   • 48-bit wide registers for MAC addresses           │  │
│ │   • Direct overwrite at packet offset 0 and 6         │  │
│ │                                                        │  │
│ │ Operation:                                             │  │
│ │   *(uint64_t*)(packet + 0) = new_dst_mac;  // 1 cycle │  │
│ │   *(uint64_t*)(packet + 6) = new_src_mac;  // 1 cycle │  │
│ │                                                        │  │
│ │ Latency: 2 clock cycles                               │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ IPv6 ADDRESS REWRITE UNIT                              │  │
│ │                                                        │  │
│ │ Hardware:                                              │  │
│ │   • 128-bit wide ALUs (4× 32-bit operations parallel) │  │
│ │   • Direct memory write to packet offset              │  │
│ │                                                        │  │
│ │ Operation (SNAT - rewrite source):                    │  │
│ │   // Old source: 2001:db8::1                          │  │
│ │   // New source: 2001:db8::99                         │  │
│ │                                                        │  │
│ │   uint32_t *ipv6_src = (void*)(packet + 22);          │  │
│ │   ipv6_src[0] = 0x200100db;  // 2001:0db8  (cycle 1)  │  │
│ │   ipv6_src[1] = 0x00000000;  // 0000:0000  (cycle 1)  │  │
│ │   ipv6_src[2] = 0x00000000;  // 0000:0000  (cycle 1)  │  │
│ │   ipv6_src[3] = 0x00000099;  // 0000:0099  (cycle 1)  │  │
│ │                                                        │  │
│ │   // 128-bit write done in parallel! 1 clock cycle    │  │
│ │                                                        │  │
│ │ Latency: 1 clock cycle (4× 32-bit ALUs in parallel)   │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ CHECKSUM UPDATE UNIT (Incremental Checksum)           │  │
│ │                                                        │  │
│ │ Hardware:                                              │  │
│ │   • Specialized adder for checksum arithmetic         │  │
│ │   • Handles ones' complement addition                 │  │
│ │                                                        │  │
│ │ Incremental Checksum Algorithm (in silicon):          │  │
│ │   // When IPv6 address changes, TCP checksum changes  │  │
│ │   old_checksum = read_16bit(packet + tcp_offset + 16);│  │
│ │   checksum = ~old_checksum;  // Ones' complement      │  │
│ │                                                        │  │
│ │   // Subtract old IPv6 address (128 bits = 8× 16-bit) │  │
│ │   for (i = 0; i < 8; i++) {                           │  │
│ │     checksum -= old_ipv6_addr[i];  // Hardware loop   │  │
│ │   }                                                    │  │
│ │                                                        │  │
│ │   // Add new IPv6 address                             │  │
│ │   for (i = 0; i < 8; i++) {                           │  │
│ │     checksum += new_ipv6_addr[i];                     │  │
│ │   }                                                    │  │
│ │                                                        │  │
│ │   // Handle carries                                    │  │
│ │   while (checksum >> 16) {                            │  │
│ │     checksum = (checksum & 0xFFFF) + (checksum >> 16);│  │
│ │   }                                                    │  │
│ │                                                        │  │
│ │   new_checksum = ~checksum;                           │  │
│ │   write_16bit(packet + tcp_offset + 16, new_checksum);│  │
│ │                                                        │  │
│ │ Latency: 8 cycles (pipelined adder)                   │  │
│ │ vs CPU: 200+ cycles (serial arithmetic)               │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ ENCAPSULATION ENGINE (VXLAN/GRE)                      │  │
│ │                                                        │  │
│ │ Hardware:                                              │  │
│ │   • Template registers (pre-configured headers)       │  │
│ │   • Header insertion logic                            │  │
│ │   • Length update calculator                          │  │
│ │                                                        │  │
│ │ Template Structure (stored in registers):             │  │
│ │   ┌─────────────────────────────────────────────┐     │  │
│ │   │ Template 0: VXLAN over IPv6                │     │  │
│ │   │ [Outer Eth][Outer IPv6][UDP][VXLAN]        │     │  │
│ │   │ Total: 70 bytes                             │     │  │
│ │   │                                             │     │  │
│ │   │ Fixed fields (never change):               │     │  │
│ │   │   • EtherType = 0x86DD                     │     │  │
│ │   │   • IPv6 version = 6                       │     │  │
│ │   │   • UDP dst_port = 4789                    │     │  │
│ │   │   • VXLAN flags = 0x08                     │     │  │
│ │   │                                             │     │  │
│ │   │ Variable fields (filled at runtime):       │     │  │
│ │   │   • Outer src/dst MAC                      │     │  │
│ │   │   • Outer src/dst IPv6                     │     │  │
│ │   │   • VXLAN VNI                              │     │  │
│ │   │   • Payload length                         │     │  │
│ │   └─────────────────────────────────────────────┘     │  │
│ │                                                        │  │
│ │ Operation:                                             │  │
│ │   1. Read template from register (1 cycle)            │  │
│ │   2. Fill variable fields from action (2 cycles)      │  │
│ │   3. Prepend to packet buffer (3 cycles)              │  │
│ │   4. Update outer length fields (1 cycle)             │  │
│ │                                                        │  │
│ │ Latency: 7 cycles                                      │  │
│ │ vs CPU: 500+ cycles (memcpy + field updates)          │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ HOP LIMIT DECREMENT UNIT                               │  │
│ │                                                        │  │
│ │ Hardware:                                              │  │
│ │   • 8-bit ALU                                          │  │
│ │   • Zero detector for TTL expiry                      │  │
│ │                                                        │  │
│ │ Operation:                                             │  │
│ │   hop_limit = read_8bit(packet + 21);                 │  │
│ │   if (hop_limit <= 1) {                               │  │
│ │     trigger_exception(TTL_EXPIRED);                   │  │
│ │   } else {                                             │  │
│ │     write_8bit(packet + 21, hop_limit - 1);           │  │
│ │   }                                                    │  │
│ │                                                        │  │
│ │ Latency: 1 cycle                                       │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ Total Action Engine Latency: 20-30 clock cycles             │
│ @ 1 GHz = 20-30 nanoseconds                                 │
└──────────────────────────────────────────────────────────────┘
```

---

## The Missing OS Layer

### What's Missing in a Custom OS

When you build a custom OS that doesn't support IPv6 on the DPU, you're missing:

```
┌──────────────────────────────────────────────────────────────┐
│ CUSTOM OS MISSING COMPONENTS                                 │
│                                                              │
│ 1. HARDWARE REGISTER ACCESS: Direct hardware control        │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ Missing: Low-level register programming interface      │  │
│ │                                                         │  │
│ │ What it needs:                                          │  │
│ │   - Memory-mapped I/O (MMIO) for hardware registers    │  │
│ │   - Register offsets for IPv6 TCAM entries             │  │
│ │   - DMA descriptors for packet buffer management       │  │
│ │   - Hardware flow table programming interface          │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ 2. KERNEL NETWORK STACK: Protocol handling                  │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ Missing: IPv6 protocol stack                           │  │
│ │                                                         │  │
│ │ What it needs:                                          │  │
│ │   - ICMPv6 (Neighbor Discovery Protocol)               │  │
│ │   - IPv6 routing table                                  │  │
│ │   - IPv6 socket API (AF_INET6)                         │  │
│ │   - DHCPv6 client                                       │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ 3. CONTROL PLANE: Flow management software                  │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ Missing: IPv6-aware control plane                      │  │
│ │                                                         │  │
│ │ What it needs:                                          │  │
│ │   - Detect first IPv6 packet                           │  │
│ │   - Lookup IPv6 routing table                          │  │
│ │   - Write flow rules to hardware registers             │  │
│ │   - Handle IPv6 fragmentation                          │  │
│ └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### How to Leverage DPU Silicon: Programming Model

Now that you understand the hardware blocks, here's how to program them:

```
┌──────────────────────────────────────────────────────────────┐
│ PROGRAMMING MODEL HIERARCHY                                  │
│                                                              │
│ Level 1: Direct Register Access (What we'll focus on)       │
│ ──────────────────────────────────────────────────────       │
│   • Memory-mapped I/O (MMIO) to hardware registers          │
│   • PCIe BAR (Base Address Register) mapping                │
│   • Direct control of parser, TCAM, action engine           │
│   • Maximum performance, maximum complexity                  │
│   • Requires detailed hardware documentation                 │
│                                                              │
│ Level 2: Firmware Interface                                  │
│ ──────────────────────────────────────────────────────       │
│   • Command-based API to embedded firmware                   │
│   • Firmware runs on DPU's ARM cores                        │
│   • Firmware translates commands to register writes          │
│   • More portable, slightly slower                          │
│   • Vendor may provide this (often proprietary)             │
│                                                              │
│ Level 3: High-Level SDK (DOCA, DPDK, etc.)                  │
│ ──────────────────────────────────────────────────────       │
│   • Abstracted APIs hiding hardware details                 │
│   • Portable across hardware generations                    │
│   • Lower performance ceiling                               │
│   • Easiest to use                                          │
└──────────────────────────────────────────────────────────────┘
```

**For maximum performance and control, you want Level 1 - direct register access.**

---

## Hardware Register Programming: The Real Implementation

### What You Actually Need to Program

At the lowest level, you're writing values to hardware registers via **memory-mapped I/O (MMIO)**:

```c
// Hardware register definitions (from vendor datasheet)
// These are examples - real addresses vary by vendor!
#define NIC_BASE_ADDR        0xF8000000  // PCIe BAR0 base address

// Parser Engine Registers
#define PARSER_CTRL          (NIC_BASE_ADDR + 0x1000)
#define PARSER_STATUS        (NIC_BASE_ADDR + 0x1004)
#define PARSER_PROTO_ENABLE  (NIC_BASE_ADDR + 0x1008)  // Enable IPv6 parsing

// Flow Table / TCAM Registers  
#define FLOW_TABLE_BASE      (NIC_BASE_ADDR + 0x100000)
#define FLOW_TABLE_CTRL      (NIC_BASE_ADDR + 0x2000)
#define FLOW_TABLE_SIZE      (NIC_BASE_ADDR + 0x2004)
#define TCAM_ENTRY_SIZE      64  // bytes per flow entry

// Action Engine Registers
#define ACTION_ENGINE_BASE   (NIC_BASE_ADDR + 0x200000)
#define TEMPLATE_BASE        (NIC_BASE_ADDR + 0x50000)  // Encap templates

// DMA Engine Registers
#define RX_RING_BASE         (NIC_BASE_ADDR + 0x3000)
#define RX_RING_SIZE         (NIC_BASE_ADDR + 0x3008)
#define RX_TAIL_PTR          (NIC_BASE_ADDR + 0x3010)
#define TX_RING_BASE         (NIC_BASE_ADDR + 0x4000)

// IPv6 flow table entry structure (hardware format)
// This matches the TCAM entry layout in silicon
struct hw_flow_entry {
    // ═══════════════════════════════════════════════════════════
    // MATCH FIELDS (256 bits - fits in TCAM width)
    // These are compared against incoming packets
    // ═══════════════════════════════════════════════════════════
    uint8_t  src_ipv6[16];      // Bits 0-127: Source IPv6 address
    uint8_t  dst_ipv6[16];      // Bits 128-255: Dest IPv6 address
    uint16_t src_port;          // Bits 256-271: L4 source port
    uint16_t dst_port;          // Bits 272-287: L4 dest port
    uint8_t  protocol;          // Bits 288-295: IP protocol (6=TCP, 17=UDP)
    uint8_t  _pad1[3];          // Padding for alignment
    
    // ═══════════════════════════════════════════════════════════
    // MASK FIELDS (256 bits)
    // 1 = must match, 0 = wildcard (don't care)
    // ═══════════════════════════════════════════════════════════
    uint8_t  src_ipv6_mask[16]; // Which src IP bits to match
    uint8_t  dst_ipv6_mask[16]; // Which dst IP bits to match
    uint16_t src_port_mask;     // Port mask (0=wildcard, 0xFFFF=exact)
    uint16_t dst_port_mask;
    uint8_t  protocol_mask;
    uint8_t  _pad2[3];
    
    // ═══════════════════════════════════════════════════════════
    // ACTION FIELDS (what hardware does with matched packets)
    // ═══════════════════════════════════════════════════════════
    uint32_t action_bitmap;     // Bit flags for actions to perform
    // Bit 0: Drop packet
    // Bit 1: Forward packet
    // Bit 2: Modify MAC addresses
    // Bit 3: Modify IPv6 addresses
    // Bit 4: Decrement hop limit
    // Bit 5: Encapsulate (add outer headers)
    // Bit 6: Decapsulate (remove outer headers)
    // Bit 7: Mirror to another port
    // Bits 8-15: QoS priority
    
    uint8_t  new_dst_mac[6];    // New destination MAC (if bit 2 set)
    uint8_t  new_src_mac[6];    // New source MAC
    uint8_t  new_dst_ipv6[16];  // New destination IPv6 (if bit 3 set)
    uint16_t output_port;       // Physical port to send to
    uint8_t  encap_template_id; // Template ID for encapsulation
    uint8_t  _pad3;
    
    // ═══════════════════════════════════════════════════════════
    // HARDWARE CONTROL/STATUS (managed by hardware)
    // ═══════════════════════════════════════════════════════════
    uint8_t  valid;             // Entry valid bit (software sets to 1)
    uint8_t  priority;          // Priority for overlapping rules
    uint16_t _pad4;
    
    // Hardware statistics (read-only, updated by action engine)
    uint64_t packet_count;      // Packets that matched this rule
    uint64_t byte_count;        // Bytes matched
    uint64_t last_used_time;    // Timestamp of last match (for aging)
} __attribute__((packed));

// Total size: 128 bytes per entry
// Hardware supports 1-4 million entries
// Total TCAM: 128 MB - 512 MB of dedicated memory

// Program a flow entry directly to hardware TCAM
void program_ipv6_flow_entry(int entry_idx,
                              uint8_t src_ipv6[16],
                              uint8_t dst_ipv6[16],
                              uint16_t src_port,
                              uint16_t dst_port,
                              uint8_t protocol,
                              uint8_t dst_mac[6],
                              uint16_t output_port) {
    // Calculate hardware address for this TCAM entry
    volatile struct hw_flow_entry *hw_entry = 
        (void*)(FLOW_TABLE_BASE + (entry_idx * sizeof(struct hw_flow_entry)));
    
    // ═══════════════════════════════════════════════════════════
    // STEP 1: Write match fields (what packets to catch)
    // ═══════════════════════════════════════════════════════════
    memcpy((void*)hw_entry->src_ipv6, src_ipv6, 16);
    memcpy((void*)hw_entry->dst_ipv6, dst_ipv6, 16);
    hw_entry->src_port = htons(src_port);
    hw_entry->dst_port = htons(dst_port);
    hw_entry->protocol = protocol;
    
    // Set masks (all 1s = exact match required)
    memset((void*)hw_entry->src_ipv6_mask, 0xFF, 16);  // Match all 128 bits
    memset((void*)hw_entry->dst_ipv6_mask, 0xFF, 16);  // Match all 128 bits
    hw_entry->src_port_mask = 0xFFFF;  // Exact port match
    hw_entry->dst_port_mask = 0xFFFF;
    hw_entry->protocol_mask = 0xFF;
    
    // ═══════════════════════════════════════════════════════════
    // STEP 2: Write action fields (what to do with matched packets)
    // ═══════════════════════════════════════════════════════════
    
    // Set action bitmap:
    //   Bit 1: Forward
    //   Bit 2: Modify MAC
    //   Bit 4: Decrement hop limit
    hw_entry->action_bitmap = (1 << 1) | (1 << 2) | (1 << 4);
    
    // Set new MAC address for routing
    memcpy((void*)hw_entry->new_dst_mac, dst_mac, 6);
    
    // Set output port
    hw_entry->output_port = output_port;
    
    // Set priority (lower = higher priority)
    hw_entry->priority = 100;
    
    // ═══════════════════════════════════════════════════════════
    // STEP 3: Atomically activate the entry
    // ═══════════════════════════════════════════════════════════
    
    // Memory barrier ensures all writes complete before valid bit
    __sync_synchronize();
    
    // Set valid bit - hardware immediately starts matching!
    hw_entry->valid = 1;
    
    // ═══════════════════════════════════════════════════════════
    // What happens now in hardware:
    // ═══════════════════════════════════════════════════════════
    // 1. Parser extracts IPv6 5-tuple from incoming packets
    // 2. TCAM compares against this entry (in parallel with all others)
    // 3. If match: Action engine reads action_bitmap
    // 4. Action engine executes:
    //    - Reads new_dst_mac → writes to packet offset 0
    //    - Decrements hop limit at packet offset 21
    //    - Forwards packet to DMA ring for output_port
    // 5. Total latency: ~100 nanoseconds
    // 6. CPU involvement: ZERO (after this setup)
}
```

### Leveraging Parser Engine: Enable IPv6 Protocol Support

Before the parser can extract IPv6 fields, you must enable IPv6 in parser configuration:

```c
// Enable IPv6 protocol parsing in hardware parser
void enable_ipv6_parser(void) {
    volatile uint32_t *parser_ctrl = (void*)PARSER_CTRL;
    volatile uint32_t *proto_enable = (void*)PARSER_PROTO_ENABLE;
    
    // Read current protocol enable bitmap
    uint32_t protocols = *proto_enable;
    
    // Set bit for IPv6 (bit positions from datasheet)
    // Bit 0: Ethernet
    // Bit 1: VLAN
    // Bit 2: IPv4
    // Bit 3: IPv6  ← Enable this!
    // Bit 4: ARP
    // Bit 5: TCP
    // Bit 6: UDP
    // Bit 7: ICMPv6
    protocols |= (1 << 3);  // Enable IPv6
    protocols |= (1 << 7);  // Enable ICMPv6 (for NDP)
    
    *proto_enable = protocols;
    
    // Trigger parser reconfiguration
    *parser_ctrl = 1;  // Reset and reload parser FSM
    
    // Wait for parser to be ready (poll status register)
    volatile uint32_t *parser_status = (void*)PARSER_STATUS;
    while ((*parser_status & 0x01) == 0) {
        // Bit 0 = ready
        usleep(1);
    }
    
    // Parser now extracts IPv6 headers and populates metadata!
}

// Configure parser to extract specific IPv6 extension headers
void configure_ipv6_extension_headers(void) {
    // Extension header parsing configuration
    // (Specific registers vary by vendor)
    volatile uint32_t *ext_hdr_cfg = (void*)(NIC_BASE_ADDR + 0x1020);
    
    // Enable parsing of common extension headers:
    // Bit 0: Hop-by-Hop Options (0)
    // Bit 1: Routing Header (43)
    // Bit 2: Fragment Header (44)
    // Bit 3: Destination Options (60)
    // Bit 4: Authentication Header (51)
    // Bit 5: ESP (50)
    
    uint32_t ext_hdr_enable = 0;
    ext_hdr_enable |= (1 << 0);  // Hop-by-Hop
    ext_hdr_enable |= (1 << 1);  // Routing
    ext_hdr_enable |= (1 << 2);  // Fragment
    ext_hdr_enable |= (1 << 3);  // Destination Options
    
    *ext_hdr_cfg = ext_hdr_enable;
    
    // Configure max extension header chain length
    volatile uint32_t *ext_hdr_limit = (void*)(NIC_BASE_ADDR + 0x1024);
    *ext_hdr_limit = 8;  // Max 8 chained extension headers
}
```

### Leveraging TCAM: Wildcard Matching for Subnets

TCAM's mask field enables efficient subnet matching:

```c
// Install a wildcard rule to match entire IPv6 /64 subnet
void install_subnet_rule(uint8_t subnet_prefix[8],  // First 64 bits
                         uint8_t dst_mac[6],
                         uint16_t output_port) {
    int entry_idx = find_free_flow_slot();
    volatile struct hw_flow_entry *entry = 
        (void*)(FLOW_TABLE_BASE + (entry_idx * sizeof(struct hw_flow_entry)));
    
    // Match: 2001:db8::/64 (any host in this subnet)
    memcpy((void*)entry->dst_ipv6, subnet_prefix, 8);  // First 64 bits
    memset((void*)entry->dst_ipv6 + 8, 0, 8);           // Last 64 bits = 0
    
    // Mask: Match only first 64 bits, wildcard last 64 bits
    memset((void*)entry->dst_ipv6_mask, 0xFF, 8);  // Match prefix
    memset((void*)entry->dst_ipv6_mask + 8, 0x00, 8);  // Wildcard host
    
    // This single TCAM entry matches ALL 2^64 hosts in the subnet!
    // Traditional hash table would need 2^64 entries
    
    // Action: Route to next hop
    entry->action_bitmap = (1 << 1) | (1 << 2) | (1 << 4);
    memcpy((void*)entry->new_dst_mac, dst_mac, 6);
    entry->output_port = output_port;
    
    __sync_synchronize();
    entry->valid = 1;
    
    // Hardware now routes entire /64 subnet with one rule!
}

// Install multicast rule (ff02::1 = all-nodes multicast)
void install_multicast_rule(void) {
    int entry_idx = find_free_flow_slot();
    volatile struct hw_flow_entry *entry = 
        (void*)(FLOW_TABLE_BASE + (entry_idx * sizeof(struct hw_flow_entry)));
    
    // Match: ff02::1 (all link-local nodes)
    uint8_t all_nodes[16] = {
        0xff, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
    };
    memcpy((void*)entry->dst_ipv6, all_nodes, 16);
    memset((void*)entry->dst_ipv6_mask, 0xFF, 16);  // Exact match
    
    // Action: Broadcast to all ports (special action)
    entry->action_bitmap = (1 << 7);  // Bit 7 = broadcast
    entry->output_port = 0xFFFF;  // Special value for "all ports"
    
    __sync_synchronize();
    entry->valid = 1;
}
```

### Leveraging Action Engine: Complex Transformations

Program action templates for complex packet modifications:

```c
// Setup encapsulation template for VXLAN over IPv6
void setup_vxlan_ipv6_template(uint8_t tunnel_src[16],
                                uint8_t tunnel_dst[16],
                                uint8_t tunnel_src_mac[6],
                                uint8_t tunnel_dst_mac[6]) {
    // Template 0: VXLAN encapsulation with IPv6 outer header
    volatile uint8_t *template = (void*)(TEMPLATE_BASE + 0);
    int offset = 0;
    
    // Outer Ethernet header (14 bytes)
    memcpy((void*)(template + offset), tunnel_dst_mac, 6); offset += 6;
    memcpy((void*)(template + offset), tunnel_src_mac, 6); offset += 6;
    *(uint16_t*)(template + offset) = htons(0x86DD); offset += 2; // IPv6
    
    // Outer IPv6 header (40 bytes)
    *(uint32_t*)(template + offset) = htonl(0x60000000); offset += 4; // Ver=6
    *(uint16_t*)(template + offset) = 0; offset += 2; // Payload len (filled later)
    *(uint8_t*)(template + offset) = 17; offset++; // Next hdr = UDP
    *(uint8_t*)(template + offset) = 64; offset++; // Hop limit
    memcpy((void*)(template + offset), tunnel_src, 16); offset += 16; // Src IPv6
    memcpy((void*)(template + offset), tunnel_dst, 16); offset += 16; // Dst IPv6
    
    // UDP header (8 bytes)
    *(uint16_t*)(template + offset) = htons(49152); offset += 2; // Src port
    *(uint16_t*)(template + offset) = htons(4789); offset += 2; // Dst port (VXLAN)
    *(uint16_t*)(template + offset) = 0; offset += 2; // Length (filled later)
    *(uint16_t*)(template + offset) = 0; offset += 2; // Checksum (optional)
    
    // VXLAN header (8 bytes)
    *(uint32_t*)(template + offset) = htonl(0x08000000); offset += 4; // Flags
    *(uint32_t*)(template + offset) = 0; offset += 4; // VNI (filled later)
    
    // Total template: 70 bytes
    
    // Mark template as valid
    volatile uint32_t *template_ctrl = (void*)(TEMPLATE_BASE + 0x1000);
    *template_ctrl = 1;  // Enable template 0
    
    // Now flow entries can reference this template!
}

// Use the template in a flow rule
void install_encap_flow(uint8_t dst_ipv6[16], uint32_t vni) {
    int entry_idx = find_free_flow_slot();
    volatile struct hw_flow_entry *entry = 
        (void*)(FLOW_TABLE_BASE + (entry_idx * sizeof(struct hw_flow_entry)));
    
    // Match: Packets to remote subnet
    memcpy((void*)entry->dst_ipv6, dst_ipv6, 16);
    memset((void*)entry->dst_ipv6_mask, 0xFF, 16);
    
    // Action: Encapsulate using template 0
    entry->action_bitmap = (1 << 5) | (1 << 1);  // Bit 5 = encap, bit 1 = fwd
    entry->encap_template_id = 0;  // Use template 0
    
    // VNI is stored in entry for runtime substitution
    // Hardware reads this and patches it into template
    *(uint32_t*)((void*)entry + 96) = htonl(vni << 8);
    
    __sync_synchronize();
    entry->valid = 1;
    
    // Hardware now:
    // 1. Matches packets to dst_ipv6
    // 2. Prepends 70-byte template from registers
    // 3. Fills in VNI from flow entry
    // 4. Updates payload length fields
    // 5. Forwards to tunnel endpoint
    // All in ~50 nanoseconds!
}
```

### Packet Reception: DMA Ring Buffers

Before you can process IPv6, you need to receive packets from hardware:

```c
// RX descriptor ring (hardware DMA structure)
#define RX_RING_SIZE 1024
#define RX_BUFFER_SIZE 2048

struct rx_descriptor {
    uint64_t buffer_addr;   // Physical address of packet buffer
    uint16_t length;        // Packet length (filled by hardware)
    uint16_t flags;         // Status flags
    uint32_t rss_hash;      // RSS hash value
} __attribute__((packed));

// RX ring setup
volatile struct rx_descriptor *rx_ring;
void *rx_buffers[RX_RING_SIZE];

void setup_rx_ring(void) {
    // Allocate DMA-able memory for descriptor ring
    rx_ring = dma_alloc_coherent(RX_RING_SIZE * sizeof(struct rx_descriptor));
    
    // Allocate packet buffers and populate descriptors
    for (int i = 0; i < RX_RING_SIZE; i++) {
        rx_buffers[i] = dma_alloc_coherent(RX_BUFFER_SIZE);
        rx_ring[i].buffer_addr = virt_to_phys(rx_buffers[i]);
        rx_ring[i].length = 0;
        rx_ring[i].flags = 0;
    }
    
    // Write ring base address to hardware register
    uint64_t ring_phys = virt_to_phys((void*)rx_ring);
    writel(ring_phys, NIC_BASE_ADDR + 0x1000);  // RX_RING_BASE
    writel(RX_RING_SIZE, NIC_BASE_ADDR + 0x1008);  // RX_RING_SIZE
    
    // Enable RX DMA
    writel(1, NIC_BASE_ADDR + 0x1010);  // RX_ENABLE
}

// Poll for received packets
int poll_rx_packets(void) {
    static int rx_tail = 0;
    int packets_received = 0;
    
    while (1) {
        volatile struct rx_descriptor *desc = &rx_ring[rx_tail];
        
        // Check if hardware wrote a packet (DD = descriptor done)
        if (!(desc->flags & 0x01)) {
            break;  // No more packets
        }
        
        // Process the packet
        void *packet_data = rx_buffers[rx_tail];
        uint16_t packet_len = desc->length;
        
        handle_received_packet(packet_data, packet_len);
        
        // Reset descriptor for reuse
        desc->length = 0;
        desc->flags = 0;
        
        // Refill with new buffer if needed
        rx_buffers[rx_tail] = dma_alloc_coherent(RX_BUFFER_SIZE);
        desc->buffer_addr = virt_to_phys(rx_buffers[rx_tail]);
        
        // Move to next descriptor
        rx_tail = (rx_tail + 1) % RX_RING_SIZE;
        packets_received++;
    }
    
    // Update hardware tail pointer
    writel(rx_tail, NIC_BASE_ADDR + 0x1018);  // RX_TAIL
    
    return packets_received;
}
```

### What Your Custom OS Needs to Implement

```
┌──────────────────────────────────────────────────────────────┐
│ REQUIRED IMPLEMENTATIONS FOR IPv6 ON CUSTOM OS               │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│ 1. IPv6 PACKET PARSING                                      │
│    ────────────────────────────────────────────────         │
│                                                              │
│    struct ipv6_header {                                     │
│        uint32_t version_class_label;  // 4 bits + 8 + 20   │
│        uint16_t payload_length;                             │
│        uint8_t  next_header;          // Protocol type      │
│        uint8_t  hop_limit;            // Like IPv4 TTL      │
│        uint8_t  src_addr[16];         // 128-bit source     │
│        uint8_t  dst_addr[16];         // 128-bit dest       │
│    };                                                       │
│                                                              │
│    bool parse_ipv6_packet(uint8_t *pkt, struct flow *f) {  │
│        struct ipv6_header *ipv6 = (void*)pkt;               │
│        memcpy(f->src_ipv6, ipv6->src_addr, 16);            │
│        memcpy(f->dst_ipv6, ipv6->dst_addr, 16);            │
│        f->protocol = ipv6->next_header;                     │
│        // Handle extension headers (complicated!)           │
│        return true;                                          │
│    }                                                        │
│                                                              │
│ 2. IPv6 ROUTING TABLE                                       │
│    ────────────────────────────────────────────────         │
│                                                              │
│    struct ipv6_route_entry {                                │
│        uint8_t prefix[16];      // 2001:db8::/32          │
│        uint8_t prefix_len;      // /32, /64, /128, etc.    │
│        uint8_t next_hop[16];    // Gateway IPv6            │
│        uint32_t interface_id;   // Output interface        │
│    };                                                       │
│                                                              │
│    // Longest prefix match lookup                           │
│    struct ipv6_route_entry*                                 │
│    ipv6_route_lookup(uint8_t dst_ipv6[16]) {               │
│        // Search routing table for longest match            │
│        // This is complex - needs efficient data structure  │
│        return best_match;                                   │
│    }                                                        │
│                                                              │
│ 3. NEIGHBOR DISCOVERY (ICMPv6)                              │
│    ────────────────────────────────────────────────         │
│                                                              │
│    // IPv6 equivalent of ARP                                │
│    bool resolve_ipv6_neighbor(uint8_t ipv6[16],            │
│                                uint8_t mac[6]) {            │
│        // Send ICMPv6 Neighbor Solicitation                 │
│        // Wait for Neighbor Advertisement                    │
│        // Cache MAC address                                  │
│        return true;                                          │
│    }                                                        │
│                                                              │
│ 4. HARDWARE FLOW INSTALLATION                               │
│    ────────────────────────────────────────────────         │
│                                                              │
│    void install_ipv6_flow(struct flow *f,                  │
│                           struct route *nh) {               │
│        // Write flow entry directly to hardware TCAM        │
│        volatile struct hw_flow_entry *entry =               │
│            (void*)(FLOW_TABLE_BASE + (idx * 64));          │
│        memcpy((void*)entry->src_ipv6, f->src, 16);         │
│        memcpy((void*)entry->dst_ipv6, f->dst, 16);         │
│        entry->valid = 1;  // Atomically activate           │
│    }                                                        │
│                                                              │
│ 5. IPV6 FRAGMENTATION HANDLING                              │
│    ────────────────────────────────────────────────         │
│                                                              │
│    // IPv6 extension header for fragmentation               │
│    struct ipv6_fragment_header {                            │
│        uint8_t next_header;                                 │
│        uint8_t reserved;                                    │
│        uint16_t fragment_offset;                            │
│        uint32_t identification;                             │
│    };                                                       │
│                                                              │
│    // Reassemble fragments before processing                │
│    struct packet* ipv6_defragment(struct packet *frag);    │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## Hardware Acceleration: Low-Level Details

### How Hardware Actually Processes IPv6

Here's what happens in the silicon when packets arrive:

#### 1. IPv6 Flow Matching in Hardware

**Software Alternative (Slow Path):**
```c
// Software flow matching (what you'd do without hardware)
struct flow_entry {
    uint8_t src_ipv6[16];
    uint8_t dst_ipv6[16];
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t protocol;
};

struct flow_entry flow_table[1000000];  // Million flows in RAM

// Linear search or hash lookup (100-500 nanoseconds)
struct flow_entry* find_flow(uint8_t *packet) {
    struct ipv6_header *ipv6 = (void*)(packet + 14);
    
    for (int i = 0; i < flow_table_size; i++) {
        if (memcmp(flow_table[i].src_ipv6, ipv6->src_addr, 16) == 0 &&
            memcmp(flow_table[i].dst_ipv6, ipv6->dst_addr, 16) == 0) {
            return &flow_table[i];  // Found!
        }
    }
    return NULL;  // Not found
}
```

**Hardware Implementation (Fast Path):**
```
┌──────────────────────────────────────────────────────────────┐
│ DPU eSwitch ASIC: IPv6 Flow Table                           │
│                                                              │
│ TCAM (Ternary Content-Addressable Memory):                  │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ Entry 0:                                               │  │
│ │   Match: src=2001:db8::1, dst=2001:db8::2, port=80    │  │
│ │   Action: Forward to port 1, decrement hop limit      │  │
│ │                                                         │  │
│ │ Entry 1:                                               │  │
│ │   Match: src=fe80::*, dst=ff02::1 (multicast)         │  │
│ │   Action: Drop (local link)                            │  │
│ │                                                         │  │
│ │ Entry 2:                                               │  │
│ │   Match: dst=2001:db8::/32 (prefix match!)            │  │
│ │   Action: Forward to port 2                            │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ Lookup Latency: 10-20 nanoseconds (parallel hardware)       │
│ vs Software: 100-500 nanoseconds (sequential CPU)           │
└──────────────────────────────────────────────────────────────┘
```

**Key Difference:** Hardware does **parallel lookup** across all entries simultaneously using TCAM, while software must iterate or hash.

---

**Key Difference:** Hardware does **parallel lookup** across all entries simultaneously using TCAM. A TCAM is essentially a hardware hash table that can search all entries in one clock cycle.

---

#### 2. IPv6 Header Rewrite (SNAT/DNAT)

**Software Packet Modification:**
```c
// CPU-based packet rewriting (slow path)
void rewrite_ipv6_packet_software(uint8_t *packet, 
                                   uint8_t new_dst[16]) {
    struct ipv6_header *ipv6 = (void*)(packet + 14);
    struct tcp_header *tcp = (void*)(ipv6 + 1);
    
    // Save old dest for checksum recalculation
    uint8_t old_dst[16];
    memcpy(old_dst, ipv6->dst_addr, 16);
    
    // Rewrite destination (CPU memcpy - 50-100 CPU cycles)
    memcpy(ipv6->dst_addr, new_dst, 16);
    
    // Recalculate TCP checksum (CPU arithmetic - 200+ cycles)
    // TCP checksum includes IP pseudo-header
    uint32_t checksum = ntohs(tcp->checksum);
    checksum -= checksum_16bit_words(old_dst, 16);
    checksum += checksum_16bit_words(new_dst, 16);
    tcp->checksum = htons(fold_checksum(checksum));
    
    // Decrement hop limit
    ipv6->hop_limit--;
    
    // Total: 5-10 microseconds on modern CPU
}
```

**Hardware Implementation (Register-Based):**
```
┌──────────────────────────────────────────────────────────────┐
│ DPU eSwitch ASIC: Packet Rewrite Engine                     │
│                                                              │
│ Stage 1: Parse (10 ns)                                       │
│   ┌────────────────────────────────────────┐                │
│   │ Extract IPv6 header fields:            │                │
│   │ - src_addr (128 bits)                  │                │
│   │ - dst_addr (128 bits)                  │                │
│   │ - hop_limit (8 bits)                   │                │
│   └────────────────────────────────────────┘                │
│                                                              │
│ Stage 2: Match (20 ns)                                       │
│   ┌────────────────────────────────────────┐                │
│   │ Lookup flow table (TCAM)               │                │
│   │ Found: Action = DNAT                   │                │
│   │ New dst = 2001:db8::99                 │                │
│   └────────────────────────────────────────┘                │
│                                                              │
│ Stage 3: Modify (30 ns)                                      │
│   ┌────────────────────────────────────────┐                │
│   │ Rewrite Engine (dedicated silicon):    │                │
│   │                                         │                │
│   │ 1. Replace dst_addr[0:15] with new val │                │
│   │    (128-bit register operation)         │                │
│   │                                         │                │
│   │ 2. Update TCP checksum                  │                │
│   │    (incremental checksum ALU)           │                │
│   │                                         │                │
│   │ 3. Decrement hop_limit                  │                │
│   │    (8-bit ALU: hop_limit -= 1)         │                │
│   └────────────────────────────────────────┘                │
│                                                              │
│ Stage 4: Forward (10 ns)                                     │
│   ┌────────────────────────────────────────┐                │
│   │ DMA packet to output port buffer       │                │
│   └────────────────────────────────────────┘                │
│                                                              │
│ Total: 70 nanoseconds (hardware pipeline)                   │
│ vs Software: 5-10 microseconds (CPU processing)             │
│ Speedup: 100x faster!                                        │
└──────────────────────────────────────────────────────────────┘
```

---

**Key Insight:** Hardware rewrite engines use dedicated ALUs (Arithmetic Logic Units) and can modify multiple fields in parallel. The checksum update uses incremental checksum hardware (one clock cycle instead of 200+).

---

#### 3. IPv6 VXLAN Encapsulation

**Software Encapsulation (Memory Copies):**
```c
// CPU-based VXLAN encapsulation
void vxlan_encap_ipv6_software(uint8_t **packet, size_t *len,
                                uint8_t tunnel_src[16],
                                uint8_t tunnel_dst[16],
                                uint32_t vni) {
    // 1. Allocate larger buffer for outer headers
    size_t outer_size = 14 + 40 + 8 + 8;  // Eth + IPv6 + UDP + VXLAN
    uint8_t *new_packet = malloc(*len + outer_size);
    
    // 2. Build outer Ethernet header
    struct eth_header *outer_eth = (void*)new_packet;
    memcpy(outer_eth->dst_mac, next_hop_mac, 6);
    memcpy(outer_eth->src_mac, local_mac, 6);
    outer_eth->ethertype = htons(0x86DD);  // IPv6
    
    // 3. Build outer IPv6 header (40 bytes)
    struct ipv6_header *outer_ipv6 = (void*)(new_packet + 14);
    outer_ipv6->version = 6;
    outer_ipv6->payload_length = htons(*len + 16);  // UDP + VXLAN + inner
    outer_ipv6->next_header = 17;  // UDP
    outer_ipv6->hop_limit = 64;
    memcpy(outer_ipv6->src_addr, tunnel_src, 16);
    memcpy(outer_ipv6->dst_addr, tunnel_dst, 16);
    
    // 4. Build UDP header
    struct udp_header *udp = (void*)(new_packet + 14 + 40);
    udp->src_port = htons(49152);  // Random
    udp->dst_port = htons(4789);   // VXLAN
    udp->length = htons(*len + 16);
    udp->checksum = 0;  // Optional for IPv6
    
    // 5. Build VXLAN header
    struct vxlan_header *vxlan = (void*)(new_packet + 14 + 40 + 8);
    vxlan->flags = 0x08;  // VNI valid
    vxlan->vni = htonl(vni << 8);
    
    // 6. Copy inner packet
    memcpy(new_packet + outer_size, *packet, *len);
    
    // Total: 10-50 microseconds (lots of memcpy!)
    free(*packet);
    *packet = new_packet;
    *len += outer_size;
}
```

**Hardware Implementation (Template Engine):**
```
┌──────────────────────────────────────────────────────────────┐
│ DPU eSwitch ASIC: VXLAN Encapsulation Engine                │
│                                                              │
│ Input: Original IPv6 packet                                  │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ [Original Eth][Original IPv6][TCP][Payload]            │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ Hardware Encap Engine (dedicated silicon):                  │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ 1. Prepend Template Headers (10 ns)                    │  │
│ │    ┌─────────────────────────────────────────────┐     │  │
│ │    │ • Outer Eth (14 bytes)                      │     │  │
│ │    │ • Outer IPv6 (40 bytes)  ← Hardware writes! │     │  │
│ │    │ • UDP (8 bytes)                              │     │  │
│ │    │ • VXLAN (8 bytes)                            │     │  │
│ │    └─────────────────────────────────────────────┘     │  │
│ │                                                         │  │
│ │ 2. Fill Template Fields (20 ns)                        │  │
│ │    • Outer src IPv6: From flow action                  │  │
│ │    • Outer dst IPv6: From flow action                  │  │
│ │    • VXLAN VNI: From flow action                       │  │
│ │    • UDP checksums: Incremental ALU                    │  │
│ │                                                         │  │
│ │ 3. Update Packet Length (5 ns)                         │  │
│ │    • Outer IPv6 payload_length += inner size           │  │
│ │    • UDP length += inner size                          │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ Output: VXLAN-encapsulated packet                           │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ [Outer Eth][Outer IPv6][UDP][VXLAN]                    │  │
│ │ [Original Eth][Original IPv6][TCP][Payload]            │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ Total: 35 nanoseconds (hardware template engine)            │
│ vs Software: 10-50 microseconds (CPU memcpy)                │
│ Speedup: 300-1000x faster!                                  │
└──────────────────────────────────────────────────────────────┘
```

**Hardware Advantage:** Instead of copying bytes, hardware has **template engines** - fixed header patterns stored in registers. It just fills in variable fields (src/dst IPv6, VNI) and prefixes the template to the packet buffer. This is done in ~10 clock cycles vs thousands of CPU cycles for memcpy.

**Programming the Template Engine:**

```c
// Pre-program VXLAN template into hardware registers
void setup_vxlan_template(uint8_t tunnel_src[16],
                          uint8_t tunnel_dst[16],
                          uint32_t vni) {
    volatile uint32_t *template_base = (void*)(NIC_BASE_ADDR + 0x50000);
    
    // Template slot 0: VXLAN over IPv6
    // Hardware will prepend this to packets
    uint32_t template[20];  // 80 bytes total
    
    // Outer Ethernet (14 bytes)
    memcpy(&template[0], next_hop_mac, 6);
    memcpy(&template[1] + 2, local_mac, 6);
    template[3] = htonl(0x86DD0000);  // EtherType = IPv6
    
    // Outer IPv6 (40 bytes) - some fields filled at runtime
    template[4] = htonl(0x60000000);  // version=6, traffic_class=0
    template[5] = 0;  // payload_length filled by hardware
    template[6] = htonl(0x11400000);  // next_header=UDP, hop_limit=64
    memcpy(&template[7], tunnel_src, 16);   // Source IPv6
    memcpy(&template[11], tunnel_dst, 16);  // Dest IPv6
    
    // UDP header (8 bytes)
    template[17] = htonl((49152 << 16) | 4789);  // src=49152, dst=4789
    template[18] = 0;  // length and checksum filled by hardware
    
    // VXLAN header (8 bytes)
    template[19] = htonl(0x08000000 | (vni << 8));  // flags + VNI
    
    // Write template to hardware
    for (int i = 0; i < 20; i++) {
        template_base[i] = template[i];
    }
    
    // Enable template 0
    writel(1, NIC_BASE_ADDR + 0x50100);
}

// In flow action, just reference template ID
struct hw_flow_entry entry = {
    // ... match fields ...
    .action = 3,  // Encapsulate
    .encap_template_id = 0,  // Use template 0
    .output_port = 1,
};
```

---

#### 4. IPv6 Neighbor Discovery (ND)

**Software NDP Handler:**
```c
// Software ICMPv6 Neighbor Solicitation handler
void handle_neighbor_solicitation(uint8_t *packet, size_t len) {
    struct ipv6_header *ipv6 = (void*)(packet + 14);
    struct icmpv6_header *icmpv6 = (void*)(ipv6 + 1);
    struct nd_neighbor_solicit *ns = (void*)(icmpv6 + 1);
    
    // Is this for one of our IPv6 addresses?
    uint8_t mac[6];
    if (!find_local_ipv6(ns->target_addr, mac)) {
        return;  // Not for us
    }
    
    // Build Neighbor Advertisement response
    uint8_t response[86];  // Eth + IPv6 + ICMPv6 + ND
    
    // Copy Ethernet header, swap src/dst
    memcpy(response, packet + 6, 6);  // dst = original src
    memcpy(response + 6, mac, 6);     // src = our MAC
    *(uint16_t*)(response + 12) = htons(0x86DD);
    
    // IPv6 header
    struct ipv6_header *resp_ipv6 = (void*)(response + 14);
    resp_ipv6->version = 6;
    resp_ipv6->payload_length = htons(32);  // ICMPv6 + ND
    resp_ipv6->next_header = 58;  // ICMPv6
    resp_ipv6->hop_limit = 255;
    memcpy(resp_ipv6->src_addr, ns->target_addr, 16);  // We are the target
    memcpy(resp_ipv6->dst_addr, ipv6->src_addr, 16);   // Original sender
    
    // ICMPv6 Neighbor Advertisement
    struct icmpv6_header *resp_icmpv6 = (void*)(resp_ipv6 + 1);
    resp_icmpv6->type = 136;  // Neighbor Advertisement
    resp_icmpv6->code = 0;
    resp_icmpv6->checksum = 0;
    
    struct nd_neighbor_advert *na = (void*)(resp_icmpv6 + 1);
    na->flags = 0x60;  // Solicited + Override
    memcpy(na->target_addr, ns->target_addr, 16);
    na->option_type = 2;  // Target Link-Layer Address
    na->option_len = 1;
    memcpy(na->option_lla, mac, 6);
    
    // Calculate ICMPv6 checksum
    resp_icmpv6->checksum = icmpv6_checksum(resp_ipv6, resp_icmpv6);
    
    // Send response (10-100 microseconds total)
    send_packet(response, 86);
}
```

**Hardware NDP Responder:**
```
┌──────────────────────────────────────────────────────────────┐
│ DPU eSwitch ASIC: ICMPv6 ND Offload                         │
│                                                              │
│ Pre-Programmed Responder Rules:                              │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ Rule 1: Neighbor Solicitation for our IPv6             │  │
│ │   Match:                                               │  │
│ │     - EtherType = 0x86DD (IPv6)                        │  │
│ │     - IPv6 next_header = 58 (ICMPv6)                   │  │
│ │     - ICMPv6 type = 135 (NS)                           │  │
│ │     - Target addr = 2001:db8::1 (our address)          │  │
│ │   Action:                                               │  │
│ │     - Generate Neighbor Advertisement (type=136)        │  │
│ │     - Fill target MAC from register                     │  │
│ │     - Send back to source                               │  │
│ │     - DO NOT UPCALL TO CPU                             │  │
│ │                                                         │  │
│ │   ⚡ Hardware responds in <1 microsecond!              │  │
│ │   ⚡ Zero CPU involvement!                             │  │
│ └────────────────────────────────────────────────────────┘  │
│                                                              │
│ Implementation:                                              │
│   • Pre-generated response templates in silicon             │
│   • MAC address stored in ASIC registers                    │
│   • Automatic packet generation logic                       │
│                                                              │
│ vs Software: CPU woken up, generates response, 10-100 µs    │
└──────────────────────────────────────────────────────────────┘
```

**Programming NDP Responder:**

```c
// Configure hardware to auto-respond to NDP requests
void setup_ndp_responder(uint8_t our_ipv6[16], uint8_t our_mac[6]) {
    volatile uint32_t *ndp_base = (void*)(NIC_BASE_ADDR + 0x60000);
    
    // Register our IPv6 address for automatic NDP response
    // Hardware will match packets with:
    //   - IPv6 next_header = 58 (ICMPv6)
    //   - ICMPv6 type = 135 (Neighbor Solicitation)
    //   - Target address = our_ipv6
    
    // Write our IPv6 address to hardware (4 x 32-bit registers)
    uint32_t *ipv6_words = (uint32_t*)our_ipv6;
    ndp_base[0] = ipv6_words[0];
    ndp_base[1] = ipv6_words[1];
    ndp_base[2] = ipv6_words[2];
    ndp_base[3] = ipv6_words[3];
    
    // Write our MAC address (2 x 32-bit registers)
    ndp_base[4] = ((uint32_t)our_mac[0] << 24) |
                  ((uint32_t)our_mac[1] << 16) |
                  ((uint32_t)our_mac[2] << 8) |
                  ((uint32_t)our_mac[3]);
    ndp_base[5] = ((uint32_t)our_mac[4] << 24) |
                  ((uint32_t)our_mac[5] << 16);
    
    // Enable automatic NDP response
    ndp_base[6] = 1;
    
    // Now hardware will auto-respond to NDP for this IPv6!
    // No CPU interrupt, no software processing
}
```

---

---

#### 5. IPv6 Extension Headers

**Software Extension Header Parser:**
```c
// Parse IPv6 extension headers
uint8_t parse_ipv6_extensions(struct dp_packet *pkt,
                               struct flow *flow) {
    struct ipv6_header *ipv6 = get_ipv6_header(pkt);
    uint8_t next_hdr = ipv6->next_header;
    uint8_t *ptr = (uint8_t*)(ipv6 + 1);
    
    // Chain through extension headers
    while (is_extension_header(next_hdr)) {
        struct ipv6_ext_hdr *ext = (void*)ptr;
        
        switch (next_hdr) {
        case IPPROTO_HOPOPTS:   // Hop-by-Hop options
        case IPPROTO_ROUTING:   // Routing header
        case IPPROTO_FRAGMENT:  // Fragment header
        case IPPROTO_DSTOPTS:   // Destination options
            // Parse each type differently
            ptr += ext->hdr_len;
            next_hdr = ext->next_header;
            break;
        }
    }
    
    flow->nw_proto = next_hdr;  // Final protocol (TCP/UDP/etc)
    return next_hdr;
}
```

**Hardware Implementation:**
```
┌──────────────────────────────────────────────────────────────┐
│ DPU eSwitch ASIC: Extension Header Parser                   │
│                                                              │
│ Multi-Stage Pipeline:                                        │
│                                                              │
│ Stage 1: Parse IPv6 Base Header (10 ns)                     │
│   ┌────────────────────────────────────────┐                │
│   │ Extract: version, payload_len,         │                │
│   │          next_header, hop_limit,       │                │
│   │          src_addr[16], dst_addr[16]    │                │
│   └────────────────────────────────────────┘                │
│                ↓                                             │
│ Stage 2: Check next_header (5 ns)                           │
│   ┌────────────────────────────────────────┐                │
│   │ Is it extension header?                │                │
│   │   0  (Hop-by-Hop)     → Parse Stage 3  │                │
│   │   43 (Routing)        → Parse Stage 3  │                │
│   │   44 (Fragment)       → Parse Stage 3  │                │
│   │   6  (TCP)            → Skip to L4     │                │
│   └────────────────────────────────────────┘                │
│                ↓                                             │
│ Stage 3: Parse Extension Header (15 ns)                     │
│   ┌────────────────────────────────────────┐                │
│   │ Extract: next_header, hdr_len          │                │
│   │ Update: metadata.ext_hdr_present = 1   │                │
│   │ Advance: ptr += (hdr_len + 1) * 8      │                │
│   │ Loop: Back to Stage 2 if more ext hdrs │                │
│   └────────────────────────────────────────┘                │
│                ↓                                             │
│ Stage 4: Parse L4 Header (10 ns)                            │
│   ┌────────────────────────────────────────┐                │
│   │ Now parse TCP/UDP/ICMPv6               │                │
│   └────────────────────────────────────────┘                │
│                                                              │
│ Hardware Limits:                                             │
│   • Max extension header chain: 8 headers                   │
│   • Max total extension length: 512 bytes                   │
│   • Fragmented packets: May upcall to CPU                   │
│                                                              │
│ Total: 40-100 ns depending on # of extension headers        │
│ vs Software: 1-10 microseconds (CPU parsing)                │
└──────────────────────────────────────────────────────────────┘
```

---

## What You Need to Implement in Your Custom OS

### Complete Example: IPv6 Forwarding with Hardware Offload

```c
// File: your_custom_os/net/ipv6/ipv6_forward.c

#include <stdint.h>
#include <string.h>

// Hardware register base addresses (from NIC datasheet)
#define NIC_BASE_ADDR        0xF8000000
#define FLOW_TABLE_BASE      (NIC_BASE_ADDR + 0x100000)
#define RX_RING_BASE         (NIC_BASE_ADDR + 0x1000)

// 1. IPv6 Packet Handler (Software Control Plane)
void handle_ipv6_packet(uint8_t *packet, size_t len) {
    // Parse Ethernet header
    struct eth_header *eth = (void*)packet;
    if (ntohs(eth->ethertype) != 0x86DD) {
        return;  // Not IPv6
    }
    
    // Parse IPv6 header
    struct ipv6_header *ipv6 = (void*)(packet + 14);
    
    // Basic validation
    if (ipv6->hop_limit <= 1) {
        send_icmpv6_time_exceeded(packet, len);
        return;
    }
    
    // Extract L4 information
    uint16_t src_port = 0, dst_port = 0;
    if (ipv6->next_header == 6) {  // TCP
        struct tcp_header *tcp = (void*)(ipv6 + 1);
        src_port = ntohs(tcp->src_port);
        dst_port = ntohs(tcp->dst_port);
    } else if (ipv6->next_header == 17) {  // UDP
        struct udp_header *udp = (void*)(ipv6 + 1);
        src_port = ntohs(udp->src_port);
        dst_port = ntohs(udp->dst_port);
    }
    
    // Lookup destination in routing table
    struct route_entry *route = ipv6_route_lookup(ipv6->dst_addr);
    if (!route) {
        send_icmpv6_dest_unreachable(packet, len);
        return;
    }
    
    // Install hardware flow for subsequent packets
    int flow_idx = find_free_flow_slot();
    if (flow_idx >= 0) {
        program_hardware_flow(flow_idx,
                             ipv6->src_addr, ipv6->dst_addr,
                             src_port, dst_port,
                             ipv6->next_header,
                             route->next_hop_mac,
                             route->output_port);
    }
    
    // Forward first packet in software
    forward_ipv6_packet_software(packet, len, route);
}

// 2. Program Hardware Flow Table (Direct Register Access)
void program_hardware_flow(int entry_idx,
                           uint8_t src_ipv6[16],
                           uint8_t dst_ipv6[16],
                           uint16_t src_port,
                           uint16_t dst_port,
                           uint8_t protocol,
                           uint8_t dst_mac[6],
                           uint16_t output_port) {
    // Calculate memory address for this flow entry
    volatile struct hw_flow_entry *entry = 
        (void*)(FLOW_TABLE_BASE + (entry_idx * 64));
    
    // Write match fields (atomic writes to hardware registers)
    memcpy((void*)entry->src_ipv6, src_ipv6, 16);
    memcpy((void*)entry->dst_ipv6, dst_ipv6, 16);
    entry->src_port = htons(src_port);
    entry->dst_port = htons(dst_port);
    entry->protocol = protocol;
    
    // Write action fields
    entry->action = 2;  // Modify and forward
    memcpy((void*)entry->new_dst_mac, dst_mac, 6);
    entry->hop_limit_dec = 1;  // Decrement hop limit
    entry->output_port = output_port;
    
    // Memory barrier to ensure all writes complete before enabling
    __sync_synchronize();
    
    // Atomically enable the flow entry
    entry->valid = 1;
    
    // Hardware now processes all matching packets automatically!
    // - Parse IPv6 header (10 ns)
    // - TCAM lookup (20 ns)
    // - Modify dst MAC (10 ns)
    // - Decrement hop limit (5 ns)
    // - Forward to output port (15 ns)
    // Total: 60 nanoseconds per packet, zero CPU usage
}

// 3. IPv6 Routing Table Lookup
struct route_entry* ipv6_route_lookup(uint8_t dst[16]) {
    // Longest prefix match
    // Example: If dst is 2001:db8::1234
    //   Check /128: 2001:db8::1234/128 (exact)
    //   Check /64:  2001:db8::/64
    //   Check /32:  2001:db8::/32
    //   Check /0:   ::/0 (default route)
    
    for (int prefix_len = 128; prefix_len >= 0; prefix_len--) {
        struct route_entry *route = 
            route_table_lookup(dst, prefix_len);
        if (route) return route;
    }
    
    return NULL;  // No route
}
```

---

### Full IPv6 Support (Production-Ready)

Beyond basic forwarding, you need:

```
┌──────────────────────────────────────────────────────────────┐
│ FULL IPv6 IMPLEMENTATION CHECKLIST                          │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│ ✅ 1. ICMPv6 (RFC 4443)                                     │
│    ├─ Echo Request/Reply (ping6)                            │
│    ├─ Destination Unreachable                               │
│    ├─ Packet Too Big (path MTU discovery)                   │
│    ├─ Time Exceeded                                          │
│    └─ Parameter Problem                                      │
│                                                              │
│ ✅ 2. Neighbor Discovery Protocol (RFC 4861)                │
│    ├─ Neighbor Solicitation (like ARP request)              │
│    ├─ Neighbor Advertisement (like ARP reply)               │
│    ├─ Router Solicitation                                    │
│    ├─ Router Advertisement                                   │
│    └─ Redirect                                               │
│                                                              │
│ ✅ 3. Address Configuration                                 │
│    ├─ SLAAC (Stateless Address Auto-Configuration)          │
│    ├─ DHCPv6 (Stateful configuration)                       │
│    ├─ Link-local addresses (fe80::/10)                      │
│    ├─ Privacy extensions (RFC 4941)                         │
│    └─ Duplicate Address Detection (DAD)                     │
│                                                              │
│ ✅ 4. Extension Headers                                     │
│    ├─ Hop-by-Hop Options                                    │
│    ├─ Routing Header                                         │
│    ├─ Fragment Header                                        │
│    ├─ Destination Options                                    │
│    ├─ Authentication Header (IPsec AH)                      │
│    └─ Encapsulating Security Payload (IPsec ESP)            │
│                                                              │
│ ✅ 5. Multicast & Anycast                                   │
│    ├─ Multicast Listener Discovery (MLDv2)                  │
│    ├─ Solicited-node multicast                              │
│    ├─ All-nodes multicast (ff02::1)                         │
│    └─ Anycast address support                               │
│                                                              │
│ ✅ 6. Path MTU Discovery (RFC 8201)                         │
│    └─ Handle ICMPv6 Packet Too Big messages                 │
│                                                              │
│ ✅ 7. Flow Label Handling (RFC 6437)                        │
│    └─ 20-bit flow label for QoS                            │
│                                                              │
│ ✅ 8. Socket API                                            │
│    ├─ AF_INET6 socket family                                │
│    ├─ IPv6-specific socket options                          │
│    └─ IPv4-mapped IPv6 addresses (::ffff:192.0.2.1)        │
│                                                              │
│ ✅ 9. Hardware Offload Integration                          │
│    ├─ Flow installation for all above protocols             │
│    ├─ Fallback to software for unsupported features         │
│    └─ Statistics and monitoring                             │
│                                                              │
│ ✅ 10. Testing & Validation                                 │
│    ├─ IPv6 Ready Logo compliance                            │
│    ├─ Interoperability tests                                │
│    └─ Performance benchmarking                              │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**Estimated Development Effort:**
- Minimal (basic forwarding): 2-4 weeks
- Full production: 6-12 months  
- IPv6 Ready Logo certified: 12-24 months

**Development Complexity:**
- Need hardware datasheets with register specifications
- PCIe BAR mapping and MMIO programming
- DMA ring buffer management
- Interrupt handling
- Synchronization between CPU and hardware
- Atomic operations for concurrent access
- Hardware errata and quirks handling

---

## Summary

```
┌──────────────────────────────────────────────────────────────┐
│ THE IPv6 GAP                                                 │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│ HARDWARE LAYER: ✅ Fully capable                            │
│   • 128-bit registers for IPv6 addresses                    │
│   • IPv6 header parser in silicon                           │
│   • TCAM wide enough for IPv6 matching                      │
│   • Extension header parsing                                 │
│   • Line-rate performance (400 Gbps)                        │
│                                                              │
│ SOFTWARE LAYER: ❌ Missing implementation                   │
│   • No IPv6 protocol stack                                  │
│   • No ICMPv6/Neighbor Discovery                            │
│   • No DHCPv6 client                                         │
│   • No hardware flow installation code                      │
│   • No routing table management                             │
│                                                              │
│ SOLUTION:                                                    │
│   Option 1: Use existing OS with drivers                    │
│     - Linux kernel has full IPv6 stack                      │
│     - Vendor drivers expose hardware capabilities           │
│     - Years of testing and optimization                     │
│                                                              │
│   Option 2: Implement low-level hardware programming        │
│     - 6-12 months development                               │
│     - Need hardware datasheets and register specs           │
│     - Expert C, PCIe, DMA, and networking knowledge         │
│     - Direct MMIO register programming                      │
│     - Handle all edge cases and hardware quirks             │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## Key Takeaways

**The Gap:**
- Hardware has IPv6-capable silicon (parsers, TCAM, ALUs)
- But you need low-level register specifications to program it
- Vendors often don't publish complete register documentation
- Each hardware generation has different register layouts

**What You Need to Leverage DPU Silicon:**

1. **Hardware Datasheet with Register Maps**
   - MMIO register addresses and layouts
   - TCAM entry format and size
   - Parser configuration registers
   - Action engine capabilities
   - DMA descriptor formats

2. **Understanding of Hardware Blocks**
   - **Parser Engine**: Protocol state machine configuration
   - **TCAM**: Content-addressable memory for flow matching
   - **Action Engine**: ALUs for packet modification
   - **Template Engine**: Pre-configured encapsulation headers
   - **DMA Engine**: Ring buffers for packet I/O

3. **Low-Level Programming Skills**
   - Memory-mapped I/O (MMIO) programming
   - PCIe BAR mapping and configuration
   - DMA descriptor management
   - Atomic operations for concurrent access
   - Memory barriers and write ordering

4. **Hardware-Specific Knowledge**
   - Packet buffer management (on-chip SRAM)
   - TCAM priority and matching semantics
   - Action bitmap and capability flags
   - Template substitution for variable fields
   - Hardware statistics and aging mechanisms

**Why It's Hard:**
- Datasheets often under NDA (non-disclosure agreement)
- Register layouts are vendor-specific and undocumented
- Hardware has quirks and errata not in public docs
- Need to handle race conditions between CPU and hardware
- Must implement fallbacks when hardware can't handle edge cases
- Debugging requires specialized tools (PCIe analyzers, logic analyzers)
- Performance tuning requires understanding silicon architecture

**The Power of Direct Hardware Access:**
- **100x faster** than software: ~100 ns vs 10,000 ns per packet
- **Zero CPU usage**: Hardware processes packets autonomously
- **Line-rate performance**: 100-400 Gbps sustained throughput
- **Millions of flows**: TCAM can hold 1-4M concurrent connections
- **Deterministic latency**: Hardware pipeline has fixed latency
- **Power efficient**: Custom silicon uses ~10-50W vs 100-500W for CPU equivalent

The hardware is incredibly capable - the challenge is obtaining documentation and mastering the low-level programming interfaces!
