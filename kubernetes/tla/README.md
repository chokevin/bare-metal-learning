# Multi-Tenant DPU Management TLA+ Specification

## Overview

This TLA+ specification models a multi-tenant DPU (Data Processing Unit) management architecture with three layers:

1. **Management Plane**: Provisions physical nodes to tenant clusters
2. **Tenant Control Planes**: Isolated Kubernetes clusters per customer tenant
3. **DPU Hardware Layer**: Shared physical DPU infrastructure with tenant isolation

## Architecture Components

### Constants

- **`Nodes`**: Physical compute nodes (e.g., `{"n1", "n2", "n3"}`)
- **`Racks`**: Physical racks containing DPUs (e.g., `{"r1"}`)
- **`DPUs`**: DPU devices per rack (e.g., `{"d1", "d2"}`)
- **`Tenants`**: Customer tenants with isolated control planes (e.g., `{"t1", "t2"}`)
- **`NodeRack`**: Mapping from each node to its physical rack (e.g., `[n1 |-> "r1"]`)
- **`NodeDPUs`**: Mapping from each node to the set of `<<Rack, DPU>>` pairs that should be programmed for it (e.g., `[n1 |-> {<<"r1", "d1">>}]`)

**Key Insight**: Multiple nodes in the same rack may belong to different clusters and use different DPUs. `NodeDPUs` defines cluster membership by specifying which DPUs participate in each node's cluster.

### State Variables

**Management Plane:**
- `mgmt_nodes`: Unassigned nodes available for allocation
- `mgmt_controller_up`: Management controller health status
- `mgmt_tenant_network`: Network connectivity from management to each tenant

**Tenant Control Plane (per tenant):**
- `tenant_nodes`: Nodes currently assigned to this tenant
- `tenant_events`: Event queue of node assignments waiting to be watched
- `tenant_buffer`: Controller's in-memory buffer of events being processed
- `tenant_controller_up`: Tenant controller health status
- `tenant_apiserver_up`: Tenant API server health status
- `tenant_etcd_up`: Tenant etcd health status
- `tenant_etcd_quorum`: Whether tenant etcd has quorum for writes
- `tenant_dpu_network`: Network connectivity from tenant to DPUs

**DPU Layer:**
- `dpu_crs`: Custom Resources stored in etcd, indexed by `<<Rack, Tenant>>`
- `dpu_crs_delete_queue`: Nodes pending deletion from CRs (models etcd propagation delay)
- `dpu_hw`: Actual hardware configuration state, indexed by `<<Rack, Tenant, DPU>>`
- `dpu_online`: DPU device health status, indexed by `<<Rack, DPU>>`
- `rack_power`: Rack power status

## System Behavior

### Normal Operations

#### 1. Node Assignment Flow

**Management Plane → Tenant:**
1. `MgmtAssign`: Management controller assigns a node to a tenant
   - Requires: Management controller up, network to tenant up, node available
   - Moves node from `mgmt_nodes` to `tenant_nodes[tenant]`
   - Adds node to `tenant_events[tenant]` for tenant controller to process

**Tenant Control Plane → DPU:**
2. `TenantWatch`: Tenant controller watches events and buffers them
   - Requires: Tenant controller and API server up
   - Moves nodes from `tenant_events` to `tenant_buffer`
   
3. `TenantFlush`: Tenant controller writes buffered nodes to etcd as CRs
   - Requires: Controller, API server, etcd up with quorum
   - Writes nodes to `dpu_crs[rack, tenant]` **only for the rack containing each node**
   - Clears the buffer

**DPU Layer → Hardware:**
4. `DPUReconcile`: DPU reads CRs and programs hardware incrementally
   - Requires: Rack power on, DPU online, network to tenant up
   - Adds or removes **one node at a time** from `dpu_hw[rack, tenant, dpu]`
   - Only programs nodes if that DPU is in the node's `NodeDPUs` set
   - This ensures nodes only appear on DPUs that are part of their cluster
   - Incremental reconciliation models realistic controller behavior

#### 2. Node Reclamation Flow

**Management Plane initiated:**
1. `MgmtReclaim`: Management controller reclaims a node from a tenant
   - Requires: Management controller up, network to tenant up, **node not in any DPU hardware**
   - Safety check prevents returning nodes to pool while still programmed
   - Removes node from `tenant_nodes[tenant]`
   - Queues node for deletion in `dpu_crs_delete_queue` (models non-atomic deletion)
   - Returns node to `mgmt_nodes` pool only after hardware is clean

2. `ProcessCRDeletion`: Etcd propagates deletions to CRs
   - Processes queued deletions from `dpu_crs_delete_queue`
   - Removes nodes from `dpu_crs` (etcd state)
   - Models the delay between deletion request and CR removal

3. `DPUReconcile`: DPUs observe CR deletions and deprogram hardware
   - **Excludes CRs in delete queue** to prevent programming nodes being reclaimed
   - Incrementally removes nodes from `dpu_hw` one at a time
   - Models realistic reconciliation loop behavior

**Tenant-initiated cleanup:**
2. `TenantCleanup`: Tenant controller removes CRs for nodes no longer in tenant
   - Runs when enabled (requires fairness constraint)
   - Removes all stale nodes from `dpu_crs` that are not in `tenant_nodes`
   - Important for cleaning up CRs after crashes or race conditions

### Failure Scenarios

#### Controller Failures

**`TenantCrash`**: Tenant controller crashes
- Buffer contents are lost (in-memory state)
- Events in `tenant_events` persist in API server

**`TenantRecover`**: Tenant controller recovers
- Implements "list-on-startup" pattern
- Re-buffers all nodes from `tenant_nodes` to recover missed events
- Ensures eventual consistency even after crashes

**`MgmtCrash` / `MgmtRecover`**: Management controller crashes and recovers
- No state loss (management operations are atomic)

#### Kubernetes Component Failures

**`ApiServerDown` / `ApiServerUp`**: API server unavailable/recovered
- Blocks `TenantWatch` (can't read events)
- Blocks `TenantFlush` (can't write CRs)

**`EtcdDown` / `EtcdUp`**: Etcd unavailable/recovered
- Also loses quorum automatically

**`EtcdLoseQuorum` / `EtcdRegainQuorum`**: Etcd quorum issues
- Blocks `TenantFlush` (can't write CRs)
- Blocks `TenantCleanup` (can't delete CRs)
- Models split-brain scenarios

#### Infrastructure Failures

**`PowerOff` / `PowerOn`**: Rack loses power
- All DPUs in rack go offline
- All hardware state for the rack is cleared
- DPUs come back online when power restored (must reconcile from CRs)

**`DPUCrash` / `DPURecover`**: Individual DPU fails
- Single DPU goes offline while rack stays powered
- Hardware state for that DPU is cleared
- Must reconcile when DPU recovers

#### Network Failures

**`MgmtTenantPartition` / `MgmtTenantHeal`**: Network partition between management and tenant
- Blocks `MgmtAssign` (can't provision nodes)
- Blocks `MgmtReclaim` (can't reclaim nodes)

**`TenantDPUPartition` / `TenantDPUHeal`**: Network partition between tenant and DPUs
- Blocks `DPUReconcile` (DPUs can't read CRs)

## Key Scenarios Modeled

### Scenario 1: Normal Node Assignment
1. Management assigns node to tenant t1
2. Tenant t1 controller watches event and buffers it
3. Tenant t1 controller flushes buffer to etcd (only to node's designated rack)
4. DPUs reconcile and program hardware (only DPUs in node's cluster)
5. Node is now active in tenant t1's cluster

### Scenario 2: Node Reassignment Between Tenants (Critical Race Condition)
1. Node n1 is assigned to tenant t1 (programmed into t1's DPUs)
2. Management reclaims n1 from t1
   - Node removed from t1's `tenant_nodes`
   - Deletion queued in `dpu_crs_delete_queue`
   - **CRITICAL**: Node cannot return to pool until `dpu_hw` is clean
3. `ProcessCRDeletion` removes n1 from t1's CRs
4. DPUs reconcile and deprogram n1 from t1's hardware
   - **CRITICAL**: DPU skips CRs in delete queue to prevent reprogramming
5. Only after hardware is clean can n1 return to `mgmt_nodes`
6. Management assigns n1 to tenant t2
7. Tenant t2 programs n1 into t2's DPUs
8. **Invariants ensure n1 never appears in both tenants simultaneously**

**Bug History**: Two race conditions were discovered during model checking:
- **Race 1**: `MgmtReclaim` could return nodes to pool while still in hardware, allowing immediate reassignment before cleanup completed
- **Race 2**: `DPUReconcile` could program nodes from stale CRs in the delete queue, creating double-booking scenarios
- Both fixed by adding preconditions that model real-world Kubernetes finalizers and deletion timestamps

### Scenario 3: Controller Crash During Assignment
1. Management assigns node to tenant
2. Tenant controller watches event and buffers it
3. **Controller crashes before flushing buffer**
4. Buffer is lost, but event persists in `tenant_events`
5. Controller recovers and uses list-on-startup
6. Re-buffers all nodes from `tenant_nodes`
7. Eventually flushes and reconciles

### Scenario 4: Multi-Cluster in Same Rack
- Rack r1 contains nodes n1, n2, n3 (20 nodes possible)
- Cluster A uses DPU d1: nodes n1, n2 have `NodeDPUs = {<<"r1", "d1">>}`
- Cluster B uses DPU d2: node n3 has `NodeDPUs = {<<"r1", "d2">>}`
- When n1 is assigned to tenant t1:
  - CRs are written to `dpu_crs[r1, t1]`
  - Only d1 programs n1 (d2 ignores it due to `NodeDPUs` check)
- Clusters remain isolated despite sharing physical infrastructure

### Scenario 5: Network Partition During Reconciliation
1. Node assigned and CRs written
2. **Network partition between tenant and DPUs**
3. DPUs cannot reconcile (blocked by network check)
4. Network heals
5. DPUs reconcile and program hardware
6. System reaches consistency

## Safety Properties (Invariants)

### `TenantIsolation`
**No node appears in multiple tenants' hardware simultaneously**

```tla
∀ node, rack, dpu: 
  |{tenant : node ∈ dpu_hw[rack, tenant, dpu]}| ≤ 1
```

**Why it matters**: Prevents tenant cross-contamination and data leakage.

### `NodeSingleAssignment`
**No node is assigned to multiple tenants simultaneously**

```tla
∀ node: 
  |{tenant : node ∈ tenant_nodes[tenant]}| ≤ 1
```

**Why it matters**: Ensures clean ownership semantics for node lifecycle management.

### `RackAffinity`
**Nodes only appear in hardware for their designated rack**

```tla
∀ node, rack, tenant, dpu:
  (node ∈ dpu_hw[rack, tenant, dpu]) ⇒ (NodeRack[node] = rack)
```

**Why it matters**: Ensures physical topology constraints are respected.

### `DPUAffinity`
**Nodes only appear in DPUs they're designated for (cluster membership)**

```tla
∀ node, rack, tenant, dpu:
  (node ∈ dpu_hw[rack, tenant, dpu]) ⇒ (<<rack, dpu>> ∈ NodeDPUs[node])
```

**Why it matters**: Ensures nodes only appear in their intended cluster's DPUs, maintaining cluster isolation within shared infrastructure.

### `ConfigurationConsistency`
**NodeDPUs configuration is consistent with NodeRack mapping**

```tla
∀ node:
  ∀ <<rack, dpu>> ∈ NodeDPUs[node]:
    rack = NodeRack[node] ∧ rack ∈ Racks ∧ dpu ∈ DPUs
```

**Why it matters**: Prevents misconfiguration where nodes are assigned to DPUs in the wrong rack, catching configuration errors at model-check time.

## Liveness Properties

### `EventualConsistency`
**If a node stays assigned to a tenant, it eventually appears in all its designated DPU hardware**

```tla
∀ node, tenant:
  □(node ∈ tenant_nodes[tenant]) ⇒ 
    ◇(∀ rack, dpu: (<<rack, dpu>> ∈ NodeDPUs[node]) ⇒ 
                     (node ∈ dpu_hw[rack, tenant, dpu]))
```

**Why it matters**: System makes forward progress despite transient failures.

**Fairness assumptions** (failures eventually stop):
- Controllers eventually recover and stay up
- API servers eventually recover and stay up
- Etcd eventually recovers with quorum
- Racks eventually power on and stay on
- DPUs eventually recover and stay online
- Networks eventually heal
- Reconciliation loops eventually make progress
- **Cleanup operations eventually run** (TenantCleanup, ProcessCRDeletion)

## Running the Model

### Configuration Example

```tla
SPECIFICATION Spec
CONSTANTS 
    Nodes = {"n1", "n2", "n3"}
    Racks = {"r1"}
    DPUs = {"d1", "d2"}
    Tenants = {"t1", "t2"}
    NodeRack = [n1 |-> "r1", n2 |-> "r1", n3 |-> "r1"]
    NodeDPUs = [
        n1 |-> {<<"r1", "d1">>},  \* n1 in cluster using d1
        n2 |-> {<<"r1", "d1">>},  \* n2 in same cluster
        n3 |-> {<<"r1", "d2">>}   \* n3 in different cluster using d2
    ]
PROPERTY EventualConsistency
INVARIANT TenantIsolation
INVARIANT NodeSingleAssignment
INVARIANT RackAffinity
INVARIANT DPUAffinity
INVARIANT ConfigurationConsistency
```

### Parse the Spec

```bash
java -cp tla2tools.jar tla2sany.SANY dpu_multi_tenant.tla
```

### Model Check

```bash
java -cp tla2tools.jar tlc2.TLC dpu_multi_tenant.tla -config dpu_multi_tenant.cfg
```

### Smoke Test (Quick Validation)

```bash
java -cp tla2tools.jar tlc2.TLC dpu_multi_tenant.tla -config dpu_multi_tenant.cfg -simulate -depth 50
```

## Design Insights from the Spec

1. **Buffer loss on crash is acceptable**: The list-on-startup pattern recovers all state from `tenant_nodes`, making the buffer an optimization rather than critical state.

2. **Deletion propagation must be modeled**: The spec now models the delay between deletion requests (`dpu_crs_delete_queue`) and actual CR removal, making reclamation more realistic.

3. **Incremental reconciliation is important**: DPUs add/remove one node at a time rather than atomically replacing entire hardware state, matching real controller behavior and reducing state explosion.

4. **Etcd quorum is critical**: Without quorum, tenants cannot write CRs or clean up resources. The spec models this explicitly.

5. **Network partitions are recoverable**: The system makes progress once networks heal, assuming failures eventually stop (fairness).

6. **Cluster isolation through DPU affinity**: The `NodeDPUs` mapping provides clean semantics for multi-cluster scenarios where nodes in the same rack belong to different clusters with different DPU configurations.

7. **Multi-tenant safety is compositional**: Tenant isolation at the hardware level plus single assignment at the management level together prevent all cross-tenant contamination scenarios.

8. **Cleanup operations need fairness constraints**: Without fairness for `TenantCleanup` and `ProcessCRDeletion`, orphaned CRs might never get cleaned up, preventing progress toward consistency.

9. **Configuration validation at model-check time**: The `ConfigurationConsistency` invariant catches misconfigurations (like nodes assigned to DPUs in wrong racks) before deployment.

10. **Race conditions in deletion are subtle**: Two critical bugs were found during model checking:
    - Nodes could be reassigned while still programmed in old tenant's hardware
    - DPU reconciliation could use stale CRs from the delete queue
    - Both required careful preconditions modeling Kubernetes finalizers and deletion timestamps

11. **Simulation mode is essential for large state spaces**: With 100M+ states, exhaustive checking is infeasible. Distributed simulation with 8 workers (5M traces each) provides high confidence while remaining practical.

## Verification Results

The specification has been verified using TLC model checker with the following configuration:

- **State Space**: ~100M+ states (estimated)
- **Verification Mode**: Simulation mode (random walk) with 8 parallel workers
- **Coverage**: 40M traces explored (8 workers × 5M traces each)
- **Invariants Checked**: All 5 invariants (TenantIsolation, NodeSingleAssignment, RackAffinity, DPUAffinity, ConfigurationConsistency)
- **Bugs Found**: 2 race conditions in node reclamation flow (both fixed)
- **CI/CD**: Automated verification on every push via GitHub Actions

**Key Findings:**
1. Initial spec violated TenantIsolation due to race between reclamation and hardware cleanup
2. Second violation found after first fix: DPU could reconcile stale CRs in delete queue
3. Both bugs required modeling real-world Kubernetes semantics (finalizers, deletion timestamps)
4. Current spec passes all invariants across 40M randomly generated behaviors
