# Kubernetes as Infrastructure Control Plane

## The Key Insight

Kubernetes can be used as an **infrastructure control plane** - not just a workload scheduler. The distinction is critical:

| Use Case | Model | Example |
|----------|-------|---------|
| Workload scheduling | Resources join as **Nodes** | VMs, bare metal servers running kubelet |
| Infrastructure management | Resources represented as **CRs** | DPUs, switches, databases, cloud resources |

**The Node abstraction is for schedulable compute, not for managed infrastructure.**

## Why "Everything as a Node" is Problematic

```
┌─────────────────────────────────────────────────────────────────┐
│                    "Everything as Node" Model                    │
│                                                                  │
│   MX Cluster                                                     │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                                                          │   │
│   │  Node: control-plane-1    Node: dpu-bf2-001             │   │
│   │  Node: control-plane-2    Node: dpu-bf2-002             │   │
│   │  Node: control-plane-3    Node: dpu-bf2-003             │   │
│   │                           Node: switch-spine-01          │   │
│   │                           Node: switch-leaf-01           │   │
│   │                           Node: storage-node-01          │   │
│   │                           ...                            │   │
│   │                           Node: dpu-bf2-10000           │   │
│   │                                                          │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│   Problems:                                                      │
│   ❌ 10,000 kubelets = 10,000 node heartbeats every 10s         │
│   ❌ API server watches on ALL nodes for each controller        │
│   ❌ Each kubelet = 50-100MB RAM overhead                       │
│   ❌ Node failure = scheduler/controller-manager storm           │
│   ❌ RBAC: Nodes have implicit permissions you may not want     │
│   ❌ Security: Compromised DPU = compromised cluster node       │
│   ❌ Heterogeneous resources awkwardly fit node model           │
│   ❌ Scalability ceiling ~5,000 nodes                           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### The Node Contract is Heavy

When something joins as a Node, it commits to:

```yaml
# What a Node implicitly agrees to:
- Run kubelet continuously
- Send heartbeats (NodeLease) every 10s
- Report capacity (CPU, memory, pods, ephemeral-storage)
- Accept Pod scheduling decisions
- Implement CRI (Container Runtime Interface)
- Implement CSI (for volume mounts)
- Implement CNI (for pod networking)
- Support kubectl exec/logs/port-forward
- Handle pod eviction on resource pressure
- Participate in node controller's health monitoring
```

**Do DPUs/switches need ANY of that?** No.

## The Better Model: Controllers with Credentials

```
┌─────────────────────────────────────────────────────────────────┐
│                    "Controllers with Credentials" Model          │
│                                                                  │
│   MX Cluster (small, focused)                                   │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  Nodes: Just control plane + operator pods              │   │
│   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │   │
│   │  │ control-1    │  │ control-2    │  │ control-3    │  │   │
│   │  └──────────────┘  └──────────────┘  └──────────────┘  │   │
│   │                                                          │   │
│   │  CRDs: DPU, Switch, StorageTarget, NetworkFunction      │   │
│   │  ┌────────────────────────────────────────────────┐     │   │
│   │  │ DPU/bf2-001        DPU/bf2-002      ...        │     │   │
│   │  │ Switch/spine-01    Switch/leaf-01   ...        │     │   │
│   │  └────────────────────────────────────────────────┘     │   │
│   │                                                          │   │
│   └─────────────────────────────────────────────────────────┘   │
│         ▲              ▲              ▲                          │
│         │ Watch CRs    │ Watch CRs    │ Watch CRs                │
│         │ Update Status│              │                          │
│         │              │              │                          │
│   ┌─────┴──────┐ ┌─────┴──────┐ ┌─────┴──────┐                  │
│   │ DPU Agent  │ │ DPU Agent  │ │ Switch     │   NOT kubelets   │
│   │ bf2-001    │ │ bf2-002    │ │ Controller │   Just API       │
│   │            │ │            │ │ spine-01   │   clients        │
│   └────────────┘ └────────────┘ └────────────┘                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Architecture Deep Dive

### What We're Actually Building

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│                  MX: Infrastructure Control Plane                │
│                                                                  │
│  NOT: A Kubernetes cluster where everything runs as Pods        │
│  IS:  A declarative API + controllers for infrastructure        │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                     API Layer                            │    │
│  │  - Kubernetes API server (proven, scalable)             │    │
│  │  - CRDs define your infrastructure types                │    │
│  │  - Standard tooling: kubectl, GitOps, RBAC              │    │
│  └─────────────────────────────────────────────────────────┘    │
│                              │                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                  Central Controllers                     │    │
│  │  - Fleet-level orchestration                            │    │
│  │  - Policy enforcement                                   │    │
│  │  - Aggregation & reporting                              │    │
│  └─────────────────────────────────────────────────────────┘    │
│                              │                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                    Edge Agents                           │    │
│  │  - Lightweight (not kubelets)                           │    │
│  │  - Watch own CR, apply locally                          │    │
│  │  - Report status back                                   │    │
│  │  - Minimal trust/permissions                            │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Location | Responsibilities |
|-----------|----------|------------------|
| **API Server** | MX Cluster | Store CRs, serve watches, enforce RBAC |
| **Fleet Operator** | MX Cluster (Pod) | Fleet-wide policies, firmware rollouts, health aggregation |
| **Edge Agent** | On device (DPU, switch) | Watch own CR, apply config locally, report status |

## Minimal Edge Agent Design

```go
// This is ALL a DPU agent needs - not a full kubelet
type DPUAgent struct {
    // Kubernetes client with LIMITED permissions
    client    kubernetes.Interface
    dpuClient dpuclientset.Interface  // Generated from CRD
    
    // Identity
    dpuName   string
    namespace string
}

func (a *DPUAgent) Run(ctx context.Context) {
    // Watch only MY DPU CR - not all nodes, not all pods
    informer := a.dpuClient.InfrastructureV1().DPUs(a.namespace).Watch(ctx, 
        metav1.ListOptions{
            FieldSelector: fmt.Sprintf("metadata.name=%s", a.dpuName),
        })
    
    for event := range informer.ResultChan() {
        dpu := event.Object.(*infrav1.DPU)
        
        // Reconcile: make actual state match desired state
        a.reconcile(dpu)
        
        // Update status
        dpu.Status.Health = a.collectHealthMetrics()
        dpu.Status.LastHeartbeat = metav1.Now()
        a.dpuClient.InfrastructureV1().DPUs(a.namespace).UpdateStatus(ctx, dpu)
    }
}
```

### Agent Resource Footprint

| Component | Memory | CPU | Network |
|-----------|--------|-----|---------|
| **kubelet** | 50-100MB | Continuous | Heartbeat every 10s + watches |
| **Edge Agent** | 10-20MB | On-demand | Watch on single CR |

## RBAC: Minimal Permissions

### Node RBAC (What kubelet gets)

```yaml
# system:node ClusterRole includes:
- Read all pods, services, endpoints, nodes
- Read secrets/configmaps for any pod scheduled to it
- Create/update node status, leases
- Create events
# Much broader than needed!
```

### Edge Agent RBAC (What we actually need)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dpu-agent-bf2-001
  namespace: infrastructure
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dpu-agent-bf2-001
  namespace: infrastructure
rules:
  # Can only read/update ITS OWN DPU CR
  - apiGroups: ["infrastructure.example.com"]
    resources: ["dpus"]
    resourceNames: ["bf2-001"]  # Scoped to specific resource!
    verbs: ["get", "watch", "patch"]
  - apiGroups: ["infrastructure.example.com"]
    resources: ["dpus/status"]
    resourceNames: ["bf2-001"]
    verbs: ["patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dpu-agent-bf2-001
  namespace: infrastructure
subjects:
  - kind: ServiceAccount
    name: dpu-agent-bf2-001
roleRef:
  kind: Role
  name: dpu-agent-bf2-001
```

## Example: DPU Custom Resource

### CRD Definition

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: dpus.infrastructure.example.com
spec:
  group: infrastructure.example.com
  names:
    kind: DPU
    plural: dpus
    shortNames: [dpu]
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                # Physical binding
                hostNodeName:
                  type: string
                  description: "Host server this DPU is attached to"
                pciAddress:
                  type: string
                
                # Management access
                managementEndpoint:
                  type: object
                  properties:
                    address: { type: string }
                    protocol: { type: string, enum: [grpc, rest, redfish] }
                    credentialsSecret: { type: string }
                
                # Desired state
                desiredFirmwareVersion:
                  type: string
                mode:
                  type: string
                  enum: [embedded, separated, dpu-only]
                
                # Network function configuration
                networkFunctions:
                  type: array
                  items:
                    type: object
                    properties:
                      name: { type: string }
                      enabled: { type: boolean }
                      config: 
                        type: object
                        x-kubernetes-preserve-unknown-fields: true
                
                tenantAssignment:
                  type: string
                  
            status:
              type: object
              properties:
                phase:
                  type: string
                  enum: [Discovering, Initializing, Ready, Upgrading, Error]
                currentFirmwareVersion:
                  type: string
                lastHeartbeat:
                  type: string
                  format: date-time
                health:
                  type: object
                  properties:
                    temperature: { type: integer }
                    linkStatus: { type: string }
                networkFunctionStatus:
                  type: array
                  items:
                    type: object
                    properties:
                      name: { type: string }
                      running: { type: boolean }
                      error: { type: string }
```

### CR Instance

```yaml
apiVersion: infrastructure.example.com/v1alpha1
kind: DPU
metadata:
  name: bf2-001
  namespace: infrastructure
  labels:
    vendor: nvidia
    model: bluefield-2
spec:
  hostNodeName: worker-42
  pciAddress: "0000:03:00.0"
  
  managementEndpoint:
    address: "192.168.100.42:50051"
    protocol: grpc
    credentialsSecret: dpu-bf2-001-credentials
  
  desiredFirmwareVersion: "2.7.0-12345"
  mode: separated
  
  networkFunctions:
    - name: ovs-offload
      enabled: true
      config:
        bridgeName: br-int
        tunnelType: vxlan
    - name: ipsec
      enabled: true
      config:
        mode: transport
  
  tenantAssignment: tenant-alpha
```

## Credential Distribution

How do edge agents get their credentials securely?

### Option 1: Bootstrap Token + CSR

```
┌─────────────┐                      ┌─────────────┐
│  DPU Agent  │                      │ MX Cluster  │
│  (new)      │                      │             │
└──────┬──────┘                      └──────┬──────┘
       │                                    │
       │  1. Use bootstrap token            │
       │  (provisioned during imaging)      │
       │────────────────────────────────────▶
       │                                    │
       │  2. Submit CSR for agent identity  │
       │────────────────────────────────────▶
       │                                    │
       │  3. (Auto-approved by controller)  │
       │◀────────────────────────────────────
       │                                    │
       │  4. Receive signed certificate     │
       │◀────────────────────────────────────
       │                                    │
       │  5. Use cert for all future API    │
       │     calls (scoped to own CR)       │
       │────────────────────────────────────▶
```

### Option 2: SPIFFE/SPIRE

```yaml
# Agent gets a SPIFFE ID that maps to K8s identity
spiffe://mx-cluster/dpu/bf2-001

# SPIRE agent on DPU attests identity via:
# - TPM attestation
# - Secure boot measurement
# - Hardware serial number

# MX cluster trusts SPIRE's attestation
# No long-lived credentials stored on device
```

### Option 3: Short-lived Tokens via Hardware Attestation

```
┌─────────────┐                      ┌─────────────┐
│  DPU Agent  │                      │ Token Issuer│
│             │                      │ (in cluster)│
└──────┬──────┘                      └──────┬──────┘
       │                                    │
       │  1. Present hardware attestation   │
       │  (TPM quote, secure boot chain)    │
       │────────────────────────────────────▶
       │                                    │
       │  2. Receive short-lived token      │
       │  (1 hour, scoped to DPU/bf2-001)   │
       │◀────────────────────────────────────
       │                                    │
       │  3. Refresh before expiry          │
       │────────────────────────────────────▶
```

## Comparison Matrix

| Aspect | Every Device as Node | Controllers with Credentials |
|--------|---------------------|------------------------------|
| **API Server load** | O(n) heartbeats/sec | O(n) watches (efficient) |
| **Memory per device** | 50-100MB kubelet | 10-20MB agent |
| **RBAC scope** | Broad node permissions | Minimal, scoped to own CR |
| **Failure blast radius** | Node NotReady cascade | Just CR status update |
| **Scheduling** | Full Pod scheduler | Not applicable |
| **Upgrade strategy** | Drain nodes, cordon | Update CR, agent reconciles |
| **Multi-tenancy** | Node taints/labels | Namespace + CR ownership |
| **Security boundary** | Node = trusted | Agent = minimal trust |
| **Scalability** | ~5,000 nodes max | 100,000+ CRs feasible |
| **Compromised device impact** | Cluster node compromised | Only own CR accessible |

## Hybrid Architecture (Full Picture)

```
┌─────────────────────────────────────────────────────────────────┐
│                        MX Cluster                                │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    Control Plane                           │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │  │
│  │  │ API Server  │  │ etcd        │  │ Controllers │       │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘       │  │
│  └───────────────────────────────────────────────────────────┘  │
│                              │                                   │
│  ┌───────────────────────────┼───────────────────────────────┐  │
│  │                 Operator Pods (on control plane)          │  │
│  │  ┌─────────────────────────────────────────────────────┐ │  │
│  │  │ DPU Fleet Operator                                   │ │  │
│  │  │ - Watches all DPU CRs                               │ │  │
│  │  │ - Fleet-wide policies (firmware rollout, etc)       │ │  │
│  │  │ - Aggregates health across all DPUs                 │ │  │
│  │  │ - Does NOT talk to individual DPUs directly         │ │  │
│  │  └─────────────────────────────────────────────────────┘ │  │
│  │  ┌─────────────────────────────────────────────────────┐ │  │
│  │  │ Switch Fleet Operator                                │ │  │
│  │  │ - Watches all Switch CRs                            │ │  │
│  │  │ - Topology validation                               │ │  │
│  │  │ - Configuration templating                          │ │  │
│  │  └─────────────────────────────────────────────────────┘ │  │
│  └───────────────────────────────────────────────────────────┘  │
│                              │                                   │
└──────────────────────────────┼───────────────────────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
        ▼                      ▼                      ▼
┌───────────────┐      ┌───────────────┐      ┌───────────────┐
│ DPU bf2-001   │      │ DPU bf2-002   │      │ Switch sp-01  │
│ ┌───────────┐ │      │ ┌───────────┐ │      │ ┌───────────┐ │
│ │ DPU Agent │ │      │ │ DPU Agent │ │      │ │ SONiC     │ │
│ │           │ │      │ │           │ │      │ │ Agent     │ │
│ │ Watches:  │ │      │ │ Watches:  │ │      │ │           │ │
│ │ DPU/bf2-001│       │ │ DPU/bf2-002│       │ │ Watches:  │ │
│ │           │ │      │ │           │ │      │ │Switch/sp01│ │
│ └───────────┘ │      └───────────┘ │      │ └───────────┘ │
│               │      │               │      │               │
│ Applies config│      │ Applies config│      │ Applies config│
│ locally       │      │ locally       │      │ via SONiC API │
└───────────────┘      └───────────────┘      └───────────────┘
```

## Real-World Precedents

This pattern is used by major projects:

| Project | What It Manages | Model |
|---------|-----------------|-------|
| **Crossplane** | Cloud resources (AWS, GCP, Azure) | CRs + external API calls |
| **Cluster API** | Kubernetes clusters | CRs for Machine, Cluster |
| **Metal³** | Bare metal servers | BareMetalHost CR |
| **KubeVirt** | Virtual machines | VirtualMachine CR |
| **Strimzi** | Kafka clusters | Kafka CR |
| **cert-manager** | TLS certificates | Certificate CR |

None of these make the managed resource a Node - they represent it as a CR and reconcile via operators/agents.

## Migration Path

If you currently have devices as Nodes:

```
Phase 1: Create CRDs alongside existing Nodes
         - DPU CR mirrors Node state
         - Both exist during transition

Phase 2: Deploy edge agents
         - Agents start reporting to CRs
         - Operators begin managing via CRs

Phase 3: Deprecate kubelet on devices
         - Stop scheduling Pods to device nodes
         - Remove device kubelets
         - Delete device Node objects

Phase 4: Full CR-based management
         - All lifecycle via CRs
         - Fleet operators for policy
         - Edge agents for local execution
```

## Summary

**Don't use Nodes for things that don't need Pod scheduling.** Use:

- **Nodes** → For compute that runs arbitrary containerized workloads
- **CRs + Operators** → For infrastructure you manage declaratively
- **Edge Agents** → Lightweight controllers on devices that watch their own CR

This gives you:
- Better scalability (100K+ resources vs 5K nodes)
- Tighter security (minimal RBAC per device)
- Lower overhead (10MB agent vs 100MB kubelet)
- Cleaner abstractions (infrastructure as data, not as compute)
