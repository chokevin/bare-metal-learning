# DPU Rule Management at Extreme Scale

## Problem Statement

**Scenario:** Every new node provisioned requires a DPU rule on **every DPU** in the cluster.

**Scale:**
- Hundreds of thousands of nodes in cluster (each with a DPU)
- New node added → rules must be created on all DPUs
- Burst provisioning: tens of thousands of nodes per minute

**Challenge:** How do we configure DPU rules efficiently at massive scale without collapsing the Kubernetes control plane?

---

## Why Naive Approaches Fail

### ❌ Anti-Pattern 1: One CR Per Rule

Create individual `DPURule` CRs for each source-target pair.

**Why this fails:**
- **etcd overload:** Massive CR count exceeds storage limits
- **Watch explosion:** Overwhelming number of API events
- **Reconcile backlog:** Hours of processing time queued
- **Burst death:** Multiple simultaneous nodes = exponential CR growth = **etcd collapse**

### ❌ Anti-Pattern 2: Single Massive CR

Create one CR per node containing all target DPUs.

**Why this fails:**
- **Size limit:** Massive rule count far exceeds etcd object size limits
- **Can't store in etcd** at all
- **Timeout:** Single reconcile processing enormous rule count exceeds timeout

---

## Solution: Zone-Based Sharding

### Key Insight

**Don't organize by source node (what's being added).**  
**Organize by target zone (where rules are applied).**

This inverts the problem:
- ❌ Before: 1 new node → create CRs for every target
- ✅ After: 1 new node → update fixed set of zone CRs

### What is a Zone?

A **zone** is a physical grouping of DPU nodes:
- **Common choice:** One zone per rack
- **Example:** Multiple racks with many DPUs each
- **Result:** Fixed number of CRs (constant, regardless of cluster size)

### Architecture

```yaml
# One CR per zone (rack)
apiVersion: dpu.example.com/v1
kind: DPURack
metadata:
  name: rack-1
spec:
  sourceNodes:  # All nodes in cluster that need rules on this rack
    - node-0001
    - node-0002
    - node-0003
    # ... (up to 200k nodes)
  targetDPUs:   # DPUs in this rack (constant per rack)
    - dpu-rack1-001
    - dpu-rack1-002
    # ... (1000 DPUs per rack)
```

**Why this works:**
- **Constant CR count:** Fixed number of zone CRs, not per-node
- **etcd friendly:** Manageable total CR size (well under limits)
- **Predictable updates:** New node → update all zone CRs (known quantity)

---

## Event Flow: Adding a Node

```
t=0: New node "node-12345" joins cluster
     Kubernetes creates Node object

t=1: NodeWatcher controller sees Node add event
     Buffers node name in memory

t=T: Flush timer triggers (batching window)
      NodeWatcher updates all DPURack CRs:
        - rack-1: Add "node-12345" to .spec.sourceNodes
        - rack-2: Add "node-12345" to .spec.sourceNodes
        - ... (all racks)

t=T+1: DPURackController sees CR update events
      For each rack, programs DPUs:
        - rack-1 DPUs: Install rules for node-12345
        - rack-2 DPUs: Install rules for node-12345
        - ... (all rules installed)

t=T+n: All DPUs configured, node ready for traffic
```

---

## The Two Controllers

### 1. NodeWatcher Controller

**Responsibility:** Watch Node objects, update all DPURack CRs

```go
type NodeWatcher struct {
    buffer     map[string]bool  // Buffered nodes
    bufferLock sync.Mutex
}

func (w *NodeWatcher) OnAdd(obj interface{}) {
    node := obj.(*corev1.Node)
    w.bufferLock.Lock()
    w.buffer[node.Name] = true
    w.bufferLock.Unlock()
}

func (w *NodeWatcher) flushLoop() {
    ticker := time.NewTicker(flushInterval)
    for range ticker.C {
        w.flush()
    }
}

func (w *NodeWatcher) flush() {
    w.bufferLock.Lock()
    if len(w.buffer) == 0 {
        w.bufferLock.Unlock()
        return
    }
    
    nodes := make([]string, 0, len(w.buffer))
    for node := range w.buffer {
        nodes = append(nodes, node)
    }
    w.buffer = make(map[string]bool)  // Clear buffer
    w.bufferLock.Unlock()
    
    // Update all 200 racks in parallel
    w.updateAllRacks(nodes)
}

func (w *NodeWatcher) updateAllRacks(nodes []string) {
    var wg sync.WaitGroup
    for _, rackName := range allRacks {
        wg.Add(1)
        go func(rack string) {
            defer wg.Done()
            w.updateRack(rack, nodes)
        }(rackName)
    }
    wg.Wait()
}
```

### 2. DPURackController

**Responsibility:** Watch DPURack CRs, program DPUs when `.spec.sourceNodes` changes

```go
func (c *DPURackController) Reconcile(ctx context.Context, req reconcile.Request) {
    // Get DPURack CR
    rack := &dpuv1.DPURack{}
    if err := c.Get(ctx, req.NamespacedName, rack); err != nil {
        return reconcile.Result{}, err
    }
    
    // Delta: Find new nodes since last reconcile
    newNodes := findNewNodes(rack.Spec.SourceNodes, rack.Status.ProgrammedNodes)
    
    // Program DPUs (only for new nodes)
    for _, dpu := range rack.Spec.TargetDPUs {
        for _, node := range newNodes {
            c.programDPU(dpu, node)  // Install rule on DPU
        }
    }
    
    // Update status
    rack.Status.ProgrammedNodes = rack.Spec.SourceNodes
    c.Status().Update(ctx, rack)
    
    return reconcile.Result{}, nil
}
```

---

## Burst Scale Problem

### The Challenge

**Scenario:** Provision tens of thousands of nodes in a very short time window

**Without batching:**
- **Per-rack approach:** Millions of CR updates
- **Per-node approach:** Millions of reconciles
- **Result:** Control plane collapse, hours-long backlog

### Solution: Batching

Instead of updating CRs on every node add, **batch updates** into windows:

```
Time-based: Flush every N seconds
Count-based: Flush when M nodes accumulated
(Whichever comes first)
```

**Implementation:**

```go
const (
    FlushInterval = configuredInterval
    FlushThreshold = configuredThreshold  // nodes
    MaxBufferSize = configuredMaxSize     // prevent OOM
)

func (w *NodeWatcher) OnAdd(obj interface{}) {
    node := obj.(*corev1.Node)
    
    w.bufferLock.Lock()
    defer w.bufferLock.Unlock()
    
    // Bounded buffer (prevent OOM during extreme bursts)
    if len(w.buffer) >= MaxBufferSize {
        log.Error("Buffer full, dropping node", "node", node.Name)
        return
    }
    
    w.buffer[node.Name] = true
    
    // Flush if threshold reached (count-based)
    if len(w.buffer) >= FlushThreshold {
        go w.flush()
    }
}

func (w *NodeWatcher) flushLoop() {
    ticker := time.NewTicker(FlushInterval)
    for range ticker.C {
        w.flush()  // Time-based flush
    }
}
```

**Performance:**

| Scenario | Description | Relative Improvement |
|----------|-------------|---------------------|
| Steady state | Low rate | Minimal latency |
| Moderate load | Medium rate | Sub-second processing |
| Burst load | High rate | Manageable propagation time |

**Benefits:**
- ✅ **Orders of magnitude reduction:** Massive decrease in CR updates
- ✅ **Sustainable load:** etcd handles batched writes easily
- ✅ **Fast propagation:** Seconds instead of hours

---

## Critical Gotchas

### 1. Buffer Overflow (Controller OOM)

**Problem:** Nodes arrive faster than flush rate → buffer grows unbounded → OOM kill

**Solution:** Bounded buffer with max size

```go
if len(w.buffer) >= MaxBufferSize {
    log.Error("Buffer full, dropping node")
    metrics.DroppedNodes.Inc()
    return
}
```

**Trade-off:** May drop nodes during extreme bursts (periodic reconciliation recovers).

---

### 2. CR Size Exceeds etcd Limit

**Problem:** At very large scale, CR size exceeds etcd limits

**Solutions:**

**A. Compression** (works up to moderate scale):
```go
import "compress/gzip"

func compressNodes(nodes []string) []byte {
    nodeStr := strings.Join(nodes, "\n")
    var buf bytes.Buffer
    gz := gzip.NewWriter(&buf)
    gz.Write([]byte(nodeStr))
    gz.Close()
    return buf.Bytes()  // significant compression ratio
}
```

**B. Node ranges** (works up to larger scale):
```yaml
# Instead of listing every individual node
# Store ranges for structured node names
nodeRanges:
  - "node-[range1]"
  - "node-[range2]"
```

**C. Use TiKV instead of etcd:**
- TiKV: No strict size limits, supports large objects
- Horizontal scaling: Very high write throughput
- Trade-off: Operational complexity (distributed database)

---

### 3. Controller Failover Loses Buffer

**Problem:** Controller crashes before flush → buffered nodes never propagated

**Solutions:**

**A. Periodic full reconciliation** (simple):
```go
func (w *NodeWatcher) periodicReconcile() {
    ticker := time.NewTicker(reconciliationInterval)
    for range ticker.C {
        nodes, _ := w.client.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
        allNodeNames := extractNodeNames(nodes.Items)
        w.updateAllRacks(allNodeNames)  // Force full sync
    }
}
```

**B. Shared state in Redis** (real-time):
```go
// Persist to Redis on every add
func (w *NodeWatcher) OnAdd(obj interface{}) {
    node := obj.(*corev1.Node)
    w.redis.SAdd(ctx, "pending-nodes", node.Name)
}

// Flush from Redis (survives controller restart)
func (w *NodeWatcher) flush() {
    nodes, _ := w.redis.SMembers(ctx, "pending-nodes")
    w.updateAllRacks(nodes)
    w.redis.Del(ctx, "pending-nodes")
}
```

**Trade-off:** Solution A catches up within configured interval (acceptable for most), Solution B adds Redis dependency.

---

### 4. Partial Failures During Flush

**Problem:** Updating racks, but some fail (network timeout, etcd slow) → inconsistent state

**Solution:** Track failed racks, retry in next flush

```go
type NodeWatcher struct {
    failedRacks map[string][]string  // rack → nodes that failed
}

func (w *NodeWatcher) updateAllRacks(nodes []string) {
    // Include previously failed nodes
    for rack, failedNodes := range w.failedRacks {
        nodes = append(nodes, failedNodes...)
    }
    w.failedRacks = make(map[string][]string)
    
    // Update racks, track failures
    for _, rack := range allRacks {
        if err := w.updateRack(rack, nodes); err != nil {
            w.failedRacks[rack] = nodes  // Retry next flush
        }
    }
}
```

**Result:** Eventual consistency (failed racks catch up on next flush).

---

### 5. Concurrent Flush Races

**Problem:** Time-based flush and count-based flush run simultaneously → duplicate work

**Solution:** Mutex around flush

```go
type NodeWatcher struct {
    flushLock sync.Mutex
    flushing  bool
}

func (w *NodeWatcher) flush() {
    w.flushLock.Lock()
    defer w.flushLock.Unlock()
    
    if w.flushing {
        return  // Skip if already flushing
    }
    w.flushing = true
    defer func() { w.flushing = false }()
    
    // Flush logic...
}
```

---

## Performance Comparison

### Per-Rack vs Per-Node CRs

| Metric | Per-Rack (Fixed # CRs) | Per-Node (One CR per node with TiKV) |
|--------|-------------------|-------------------------------|  
| **Storage** | Manageable (fixed count) | Very large (scales with nodes) |
| **New node writes** | Multiple writes | Single write |
| **Watch events** | Multiple events | Multiple events (same!) |
| **Reconciles** | Multiple (parallel) | Multiple (one per DPU) |
| **Recommended** | Most use cases | TiKV available + extreme scale |

**Key insight:** Watch fan-out is the same in both designs (each DPU needs to know about all nodes). The difference is **where the list is stored** (sharded across 200 CRs vs 200k CRs).

---

## Scaling to Very Large Clusters

### With etcd (Per-Rack)

**Limits:**
- CR size: etcd object size limit
- Max nodes per CR: Limited by size (with compression)
- Max nodes total: Can scale to millions with proper sharding

**Solutions for maximum scale:**
1. **More zones:** Increase sharding to handle more nodes per zone
2. **Node ranges:** Use range notation instead of listing all names
3. **Wildcard rules on DPU:** Match CIDR ranges instead of individual IPs (orders of magnitude fewer rules!)

### With TiKV (Per-Node)

**Limits:**
- No practical CR size limit (very large objects supported)
- Storage: Multi-terabyte capacity
- Max nodes: Millions (limited by cluster size, not storage)

**Trade-off:** Operational complexity (multi-node distributed database vs single etcd).

---

## DPU Programming Optimizations

Even with efficient CR management, programming many DPUs is slow. Optimizations:

### 1. Wildcard Rules (Dramatically faster)

Instead of:
```
Rule 1: IP1 → allow
Rule 2: IP2 → allow
...
Rule N: IPn → allow
```

Use:
```
Rule 1: CIDR/subnet → allow
```

**Result:** Single rule instead of thousands, programs in milliseconds instead of extended time.

### 2. Pub/Sub for DPU Updates (Much faster)

Instead of controller calling each DPU sequentially:

```
Controller → DPU Agent Pub/Sub Topic
DPU Agents subscribe, pull updates in parallel
```

**Result:** All DPUs pull updates very quickly in parallel.

### 3. Hierarchical Distribution (Orders of magnitude faster)

```
Controller → Regional Controllers
Each Regional Controller → Rack Controllers  
Each Rack Controller → DPUs

Depth: Few hops, total time: Sub-second
---

## Recommendations

### Start Here (Most Common)

1. **Architecture:** Per-rack CRs (fixed count for large clusters)
2. **Batching:** Time-based + count-based (configurable thresholds)
3. **Failover:** Periodic full reconciliation
4. **DPU programming:** Wildcard rules if hardware supports

**Handles:** Scales to millions of nodes, high burst rates, standard etcd

### Scale Beyond Standard Limits

1. **Architecture:** Per-node CRs with TiKV (simpler code)
2. **Storage:** TiKV cluster (multiple nodes for HA)
3. **DPU programming:** Pub/sub + hierarchical distribution

**Handles:** Many millions of nodes, unlimited burst (TiKV scales horizontally)

---

## Resources

- [Kubernetes controller-runtime](https://github.com/kubernetes-sigs/controller-runtime)
- [TiKV as etcd alternative](https://tikv.org/)
- [Server-Side Apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
