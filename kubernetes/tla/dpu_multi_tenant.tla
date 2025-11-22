---------------------- MODULE dpu_multi_tenant ----------------------
EXTENDS TLC, Integers, FiniteSets

(* 
  Multi-Tenant DPU Management Architecture
  
  Management Plane: Provisions physical nodes
  Tenant Control Planes: Isolated K8s clusters per customer
  DPU Hardware: Shared physical layer with tenant isolation
*)

CONSTANTS 
    Nodes,          \* Physical nodes, e.g., {"n1", "n2"}
    Racks,          \* Physical racks, e.g., {"r1"}
    DPUs,           \* DPUs per rack, e.g., {"d1", "d2"}
    Tenants         \* Customer tenants, e.g., {"t1", "t2"}

\* Configuration: Define node-to-rack and node-to-DPU mappings
\* Edit these for different topologies
NodeRack == [n \in Nodes |-> "r1"]  \* All nodes in rack r1
NodeDPUs == [n \in Nodes |->
    CASE n \in {"n1", "n2"} -> {<<"r1", "d1">>}  \* n1, n2 use d1
      [] n = "n3" -> {<<"r1", "d2">>}            \* n3 uses d2
      [] OTHER -> {<<"r1", "d1">>}]              \* Default to d1

VARIABLES 
    mgmt_nodes,             \* Management plane unassigned nodes: Set of Nodes
    mgmt_controller_up,     \* Management plane controller status: Boolean
    mgmt_tenant_network,    \* Network connectivity mgmt->tenant: Tenant -> Boolean
    tenant_nodes,           \* Tenant's assigned nodes: Tenant -> Set of Nodes
    tenant_events,          \* Tenant event queue: Tenant -> Set of Nodes
    tenant_buffer,          \* Tenant controller buffer: Tenant -> Set of Nodes
    tenant_controller_up,   \* Tenant controller status: Tenant -> Boolean
    tenant_apiserver_up,    \* Tenant API server status: Tenant -> Boolean
    tenant_etcd_up,         \* Tenant etcd status: Tenant -> Boolean
    tenant_etcd_quorum,     \* Tenant etcd has quorum: Tenant -> Boolean
    tenant_dpu_network,     \* Network connectivity tenant->DPU: Tenant -> Boolean
    dpu_crs,                \* DPU CRs in etcd: <<Rack, Tenant>> -> Set of Nodes
    dpu_crs_delete_queue,   \* Nodes pending deletion from CRs: <<Rack, Tenant>> -> Set of Nodes
    dpu_hw,                 \* DPU hardware state: <<Rack, Tenant, DPU>> -> Set of Nodes
    dpu_online,             \* DPU status: <<Rack, DPU>> -> Boolean
    rack_power              \* Rack power: Rack -> Boolean

Vars == <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events, tenant_buffer, 
          tenant_controller_up, tenant_apiserver_up, tenant_etcd_up, tenant_etcd_quorum, tenant_dpu_network,
          dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

Init ==
    /\ mgmt_nodes = Nodes
    /\ mgmt_controller_up = TRUE
    /\ mgmt_tenant_network = [t_id \in Tenants |-> TRUE]
    /\ tenant_nodes = [t_id \in Tenants |-> {}]
    /\ tenant_events = [t_id \in Tenants |-> {}]
    /\ tenant_buffer = [t_id \in Tenants |-> {}]
    /\ tenant_controller_up = [t_id \in Tenants |-> TRUE]
    /\ tenant_apiserver_up = [t_id \in Tenants |-> TRUE]
    /\ tenant_etcd_up = [t_id \in Tenants |-> TRUE]
    /\ tenant_etcd_quorum = [t_id \in Tenants |-> TRUE]
    /\ tenant_dpu_network = [t_id \in Tenants |-> TRUE]
    /\ dpu_crs = [r_id \in Racks, t_id \in Tenants |-> {}]
    /\ dpu_crs_delete_queue = [r_id \in Racks, t_id \in Tenants |-> {}]
    /\ dpu_hw = [r_id \in Racks, t_id \in Tenants, d_id \in DPUs |-> {}]
    /\ dpu_online = [r_id \in Racks, d_id \in DPUs |-> TRUE]
    /\ rack_power = [r_id \in Racks |-> TRUE]

(* Management Plane: Assign node to tenant *)
MgmtAssign ==
    \E n_ode \in Nodes, t_id \in Tenants :
        /\ mgmt_controller_up = TRUE
        /\ mgmt_tenant_network[t_id] = TRUE  \* Network must be up
        /\ n_ode \in mgmt_nodes
        /\ mgmt_nodes' = mgmt_nodes \ {n_ode}
        /\ tenant_nodes' = [tenant_nodes EXCEPT ![t_id] = @ \cup {n_ode}]
        /\ tenant_events' = [tenant_events EXCEPT ![t_id] = @ \cup {n_ode}]
        /\ UNCHANGED <<mgmt_controller_up, mgmt_tenant_network, tenant_buffer, tenant_controller_up, 
                       tenant_apiserver_up, tenant_etcd_up, tenant_etcd_quorum, tenant_dpu_network,
                       dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Management Plane: Reclaim node from tenant *)
MgmtReclaim ==
    \E n_ode \in Nodes, t_id \in Tenants :
        /\ mgmt_controller_up = TRUE
        /\ mgmt_tenant_network[t_id] = TRUE  \* Network must be up
        /\ n_ode \in tenant_nodes[t_id]
        \* Only return node to pool if it's not in any tenant's hardware
        /\ \A r_id \in Racks, t_en \in Tenants, d_id \in DPUs :
             n_ode \notin dpu_hw[r_id, t_en, d_id]
        /\ tenant_nodes' = [tenant_nodes EXCEPT ![t_id] = @ \ {n_ode}]
        /\ mgmt_nodes' = mgmt_nodes \cup {n_ode}
        /\ tenant_events' = [tenant_events EXCEPT ![t_id] = @ \ {n_ode}]  \* Remove from events (DELETE operation)
        \* Queue deletions instead of immediate removal to model etcd propagation delay
        /\ dpu_crs_delete_queue' = [r_id \in Racks, t_en \in Tenants |->
                                      IF t_en = t_id
                                      THEN dpu_crs_delete_queue[r_id, t_en] \cup {n_ode}
                                      ELSE dpu_crs_delete_queue[r_id, t_en]]
        /\ UNCHANGED <<mgmt_controller_up, mgmt_tenant_network, tenant_buffer, tenant_controller_up, 
                       tenant_apiserver_up, tenant_etcd_up, tenant_etcd_quorum, tenant_dpu_network,
                       dpu_crs, dpu_hw, dpu_online, rack_power>>

(* Tenant Controller: Watch events and buffer them *)
TenantWatch ==
    \E t_id \in Tenants :
        \E n_ode \in tenant_events[t_id] :
            /\ tenant_controller_up[t_id] = TRUE
            /\ tenant_apiserver_up[t_id] = TRUE
            /\ tenant_buffer' = [tenant_buffer EXCEPT ![t_id] = @ \cup {n_ode}]
            /\ tenant_events' = [tenant_events EXCEPT ![t_id] = @ \ {n_ode}]
            /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_controller_up, 
                           tenant_apiserver_up, tenant_etcd_up, tenant_etcd_quorum, tenant_dpu_network,
                           dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Tenant Controller: Flush buffer to CRs *)
TenantFlush ==
    \E t_id \in Tenants :
        /\ tenant_controller_up[t_id] = TRUE
        /\ tenant_apiserver_up[t_id] = TRUE
        /\ tenant_etcd_up[t_id] = TRUE
        /\ tenant_etcd_quorum[t_id] = TRUE  \* Etcd must have quorum to write
        /\ tenant_buffer[t_id] # {}
        /\ LET valid_nodes == tenant_buffer[t_id] \cap tenant_nodes[t_id]  \* Only flush nodes still in tenant
           IN dpu_crs' = [r_id \in Racks, t_en \in Tenants |->
                            IF t_en = t_id
                            THEN dpu_crs[r_id, t_en] \cup {n \in valid_nodes : NodeRack[n] = r_id}  \* Only nodes in this rack
                            ELSE dpu_crs[r_id, t_en]]
        /\ tenant_buffer' = [tenant_buffer EXCEPT ![t_id] = {}]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events, 
                       tenant_controller_up, tenant_apiserver_up, tenant_etcd_up, tenant_etcd_quorum, 
                       tenant_dpu_network, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* DPU: Reconcile CRs to hardware - incremental add/remove *)
DPUReconcile ==
    \E r \in Racks, d_id \in DPUs, t_id \in Tenants :
        /\ rack_power[r] = TRUE
        /\ dpu_online[r, d_id] = TRUE
        /\ tenant_dpu_network[t_id] = TRUE  \* Network must be up
        \* Only program nodes that should be on this DPU (excluding pending deletions)
        /\ LET valid_crs == dpu_crs[r, t_id] \ dpu_crs_delete_queue[r, t_id]  \* Exclude CRs pending deletion
               target_nodes == {n \in valid_crs : <<r, d_id>> \in NodeDPUs[n]}
               to_remove == dpu_hw[r, t_id, d_id] \ target_nodes
               to_add == target_nodes \ dpu_hw[r, t_id, d_id]
           IN /\ (to_remove # {} \/ to_add # {})  \* Something to reconcile
              /\ dpu_hw' = [dpu_hw EXCEPT ![r, t_id, d_id] = 
                              IF to_remove # {}
                              THEN @ \ {CHOOSE n \in to_remove : TRUE}  \* Remove one node
                              ELSE @ \cup {CHOOSE n \in to_add : TRUE}]  \* Or add one node
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events, 
                       tenant_buffer, tenant_controller_up, tenant_apiserver_up, tenant_etcd_up, 
                       tenant_etcd_quorum, tenant_dpu_network, dpu_crs, dpu_crs_delete_queue, dpu_online, rack_power>>

(* Tenant Controller: Clean up CRs for removed nodes *)
TenantCleanup ==
    \E t_id \in Tenants, r_id \in Racks :
        /\ tenant_controller_up[t_id] = TRUE
        /\ tenant_apiserver_up[t_id] = TRUE
        /\ tenant_etcd_up[t_id] = TRUE
        /\ tenant_etcd_quorum[t_id] = TRUE  \* Need quorum to write
        /\ LET stale_nodes == dpu_crs[r_id, t_id] \ tenant_nodes[t_id]  \* CRs for nodes not in tenant
           IN /\ stale_nodes # {}
              /\ dpu_crs' = [dpu_crs EXCEPT ![r_id, t_id] = @ \ stale_nodes]  \* Remove all stale CRs
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events, 
                       tenant_buffer, tenant_controller_up, tenant_apiserver_up, tenant_etcd_up, 
                       tenant_etcd_quorum, tenant_dpu_network, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Process CR deletions - models etcd watch propagation *)
ProcessCRDeletion ==
    \E t_id \in Tenants, r_id \in Racks :
        /\ dpu_crs_delete_queue[r_id, t_id] # {}
        /\ LET nodes_to_delete == dpu_crs_delete_queue[r_id, t_id]
           IN /\ dpu_crs' = [dpu_crs EXCEPT ![r_id, t_id] = @ \ nodes_to_delete]
              /\ dpu_crs_delete_queue' = [dpu_crs_delete_queue EXCEPT ![r_id, t_id] = {}]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events, 
                       tenant_buffer, tenant_controller_up, tenant_apiserver_up, tenant_etcd_up, 
                       tenant_etcd_quorum, tenant_dpu_network, dpu_hw, dpu_online, rack_power>>

(* Tenant Controller: Crash *)
TenantCrash ==
    \E t_id \in Tenants :
        /\ tenant_controller_up[t_id] = TRUE
        /\ tenant_controller_up' = [tenant_controller_up EXCEPT ![t_id] = FALSE]
        /\ tenant_buffer' = [tenant_buffer EXCEPT ![t_id] = {}]  \* Buffer lost!
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events, 
                       tenant_apiserver_up, tenant_etcd_up, tenant_etcd_quorum, tenant_dpu_network,
                       dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Tenant Controller: Recover *)
TenantRecover ==
    \E t_id \in Tenants :
        /\ tenant_controller_up[t_id] = FALSE
        /\ tenant_controller_up' = [tenant_controller_up EXCEPT ![t_id] = TRUE]
        \* List-on-startup: Re-buffer all nodes from tenant_nodes to recover missed events
        /\ tenant_buffer' = [tenant_buffer EXCEPT ![t_id] = tenant_nodes[t_id]]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events,
                       tenant_apiserver_up, tenant_etcd_up, tenant_etcd_quorum, tenant_dpu_network,
                       dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Tenant etcd: Failure *)
EtcdDown ==
    \E t_id \in Tenants :
        /\ tenant_etcd_up[t_id] = TRUE
        /\ tenant_etcd_up' = [tenant_etcd_up EXCEPT ![t_id] = FALSE]
        /\ tenant_etcd_quorum' = [tenant_etcd_quorum EXCEPT ![t_id] = FALSE]  \* Also lose quorum
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events, 
                       tenant_buffer, tenant_controller_up, tenant_apiserver_up, tenant_dpu_network,
                       dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Tenant etcd: Recovery *)
EtcdUp ==
    \E t_id \in Tenants :
        /\ tenant_etcd_up[t_id] = FALSE
        /\ tenant_etcd_up' = [tenant_etcd_up EXCEPT ![t_id] = TRUE]
        /\ tenant_etcd_quorum' = [tenant_etcd_quorum EXCEPT ![t_id] = TRUE]  \* Also regain quorum
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events, 
                       tenant_buffer, tenant_controller_up, tenant_apiserver_up, tenant_dpu_network,
                       dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Tenant API Server: Failure *)
ApiServerDown ==
    \E t_id \in Tenants :
        /\ tenant_apiserver_up[t_id] = TRUE
        /\ tenant_apiserver_up' = [tenant_apiserver_up EXCEPT ![t_id] = FALSE]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events, 
                       tenant_buffer, tenant_controller_up, tenant_etcd_up, tenant_etcd_quorum, 
                       tenant_dpu_network, dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Tenant API Server: Recovery *)
ApiServerUp ==
    \E t_id \in Tenants :
        /\ tenant_apiserver_up[t_id] = FALSE
        /\ tenant_apiserver_up' = [tenant_apiserver_up EXCEPT ![t_id] = TRUE]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events, 
                       tenant_buffer, tenant_controller_up, tenant_etcd_up, tenant_etcd_quorum, 
                       tenant_dpu_network, dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Rack: Power loss *)
PowerOff ==
    \E r_id \in Racks :
        /\ rack_power[r_id] = TRUE
        /\ rack_power' = [rack_power EXCEPT ![r_id] = FALSE]
        /\ dpu_online' = [d_pu \in Racks, d_id \in DPUs |->
                           IF d_pu = r_id THEN FALSE ELSE dpu_online[d_pu, d_id]]
        /\ dpu_hw' = [r_ack \in Racks, t_id \in Tenants, d_id \in DPUs |->
                       IF r_ack = r_id THEN {} ELSE dpu_hw[r_ack, t_id, d_id]]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events, 
                       tenant_buffer, tenant_controller_up, tenant_apiserver_up, tenant_etcd_up, 
                       tenant_etcd_quorum, tenant_dpu_network, dpu_crs, dpu_crs_delete_queue>>

(* Rack: Power restored *)
PowerOn ==
    \E r_id \in Racks :
        /\ rack_power[r_id] = FALSE
        /\ rack_power' = [rack_power EXCEPT ![r_id] = TRUE]
        /\ dpu_online' = [d_pu \in Racks, d_id \in DPUs |->
                           IF d_pu = r_id THEN TRUE ELSE dpu_online[d_pu, d_id]]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events, 
                       tenant_buffer, tenant_controller_up, tenant_apiserver_up, tenant_etcd_up, 
                       tenant_etcd_quorum, tenant_dpu_network, dpu_crs, dpu_crs_delete_queue, dpu_hw>>

(* Management Plane: Controller crash *)
MgmtCrash ==
    /\ mgmt_controller_up = TRUE
    /\ mgmt_controller_up' = FALSE
    /\ UNCHANGED <<mgmt_nodes, mgmt_tenant_network, tenant_nodes, tenant_events, tenant_buffer,
                   tenant_controller_up, tenant_apiserver_up, tenant_etcd_up, tenant_etcd_quorum,
                   tenant_dpu_network, dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Management Plane: Controller recover *)
MgmtRecover ==
    /\ mgmt_controller_up = FALSE
    /\ mgmt_controller_up' = TRUE
    /\ UNCHANGED <<mgmt_nodes, mgmt_tenant_network, tenant_nodes, tenant_events, tenant_buffer,
                   tenant_controller_up, tenant_apiserver_up, tenant_etcd_up, tenant_etcd_quorum,
                   tenant_dpu_network, dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Network: Management-Tenant partition *)
MgmtTenantPartition ==
    \E t_id \in Tenants :
        /\ mgmt_tenant_network[t_id] = TRUE
        /\ mgmt_tenant_network' = [mgmt_tenant_network EXCEPT ![t_id] = FALSE]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, tenant_nodes, tenant_events, tenant_buffer,
                       tenant_controller_up, tenant_apiserver_up, tenant_etcd_up, tenant_etcd_quorum,
                       tenant_dpu_network, dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Network: Management-Tenant healed *)
MgmtTenantHeal ==
    \E t_id \in Tenants :
        /\ mgmt_tenant_network[t_id] = FALSE
        /\ mgmt_tenant_network' = [mgmt_tenant_network EXCEPT ![t_id] = TRUE]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, tenant_nodes, tenant_events, tenant_buffer,
                       tenant_controller_up, tenant_apiserver_up, tenant_etcd_up, tenant_etcd_quorum,
                       tenant_dpu_network, dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Network: Tenant-DPU partition *)
TenantDPUPartition ==
    \E t_id \in Tenants :
        /\ tenant_dpu_network[t_id] = TRUE
        /\ tenant_dpu_network' = [tenant_dpu_network EXCEPT ![t_id] = FALSE]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events,
                       tenant_buffer, tenant_controller_up, tenant_apiserver_up, tenant_etcd_up,
                       tenant_etcd_quorum, dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Network: Tenant-DPU healed *)
TenantDPUHeal ==
    \E t_id \in Tenants :
        /\ tenant_dpu_network[t_id] = FALSE
        /\ tenant_dpu_network' = [tenant_dpu_network EXCEPT ![t_id] = TRUE]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events,
                       tenant_buffer, tenant_controller_up, tenant_apiserver_up, tenant_etcd_up,
                       tenant_etcd_quorum, dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* DPU: Individual DPU crash *)
DPUCrash ==
    \E r_id \in Racks, d_id \in DPUs :
        /\ rack_power[r_id] = TRUE  \* Rack is powered, but individual DPU fails
        /\ dpu_online[r_id, d_id] = TRUE
        /\ dpu_online' = [dpu_online EXCEPT ![r_id, d_id] = FALSE]
        /\ dpu_hw' = [r_ack \in Racks, t_id \in Tenants, d_pu \in DPUs |->
                       IF r_ack = r_id /\ d_pu = d_id 
                       THEN {} 
                       ELSE dpu_hw[r_ack, t_id, d_pu]]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events,
                       tenant_buffer, tenant_controller_up, tenant_apiserver_up, tenant_etcd_up,
                       tenant_etcd_quorum, tenant_dpu_network, dpu_crs, dpu_crs_delete_queue, rack_power>>

(* DPU: Individual DPU recovery *)
DPURecover ==
    \E r_id \in Racks, d_id \in DPUs :
        /\ rack_power[r_id] = TRUE
        /\ dpu_online[r_id, d_id] = FALSE
        /\ dpu_online' = [dpu_online EXCEPT ![r_id, d_id] = TRUE]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events,
                       tenant_buffer, tenant_controller_up, tenant_apiserver_up, tenant_etcd_up,
                       tenant_etcd_quorum, tenant_dpu_network, dpu_crs, dpu_crs_delete_queue, dpu_hw, rack_power>>

(* Etcd: Lose quorum while still up *)
EtcdLoseQuorum ==
    \E t_id \in Tenants :
        /\ tenant_etcd_up[t_id] = TRUE
        /\ tenant_etcd_quorum[t_id] = TRUE
        /\ tenant_etcd_quorum' = [tenant_etcd_quorum EXCEPT ![t_id] = FALSE]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events,
                       tenant_buffer, tenant_controller_up, tenant_apiserver_up, tenant_etcd_up,
                       tenant_dpu_network, dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

(* Etcd: Regain quorum *)
EtcdRegainQuorum ==
    \E t_id \in Tenants :
        /\ tenant_etcd_up[t_id] = TRUE
        /\ tenant_etcd_quorum[t_id] = FALSE
        /\ tenant_etcd_quorum' = [tenant_etcd_quorum EXCEPT ![t_id] = TRUE]
        /\ UNCHANGED <<mgmt_nodes, mgmt_controller_up, mgmt_tenant_network, tenant_nodes, tenant_events,
                       tenant_buffer, tenant_controller_up, tenant_apiserver_up, tenant_etcd_up,
                       tenant_dpu_network, dpu_crs, dpu_crs_delete_queue, dpu_hw, dpu_online, rack_power>>

Next ==
    \/ MgmtAssign
    \/ MgmtReclaim
    \/ TenantWatch
    \/ TenantFlush
    \/ TenantCleanup
    \/ ProcessCRDeletion
    \/ DPUReconcile
    \/ TenantCrash
    \/ TenantRecover
    \/ ApiServerDown
    \/ ApiServerUp
    \/ EtcdDown
    \/ EtcdUp
    \/ PowerOff
    \/ PowerOn
    \/ MgmtCrash
    \/ MgmtRecover
    \/ MgmtTenantPartition
    \/ MgmtTenantHeal
    \/ TenantDPUPartition
    \/ TenantDPUHeal
    \/ DPUCrash
    \/ DPURecover
    \/ EtcdLoseQuorum
    \/ EtcdRegainQuorum

(* Property: Eventual Consistency - nodes reach hardware in their designated DPUs if they stay assigned *)
EventualConsistency == 
    \A n_ode \in Nodes, t_id \in Tenants : 
        [](n_ode \in tenant_nodes[t_id]) => 
            <>(
                \A r_id \in Racks, d_id \in DPUs : 
                    (<<r_id, d_id>> \in NodeDPUs[n_ode]) => (n_ode \in dpu_hw[r_id, t_id, d_id])
            )

(* Property: Tenant Isolation - no node appears in multiple tenants' hardware *)
TenantIsolation ==
    \A n_ode \in Nodes, r_id \in Racks, d_id \in DPUs :
        Cardinality({t_id \in Tenants : n_ode \in dpu_hw[r_id, t_id, d_id]}) <= 1

(* Property: Node Single Assignment - no node is assigned to multiple tenants *)
NodeSingleAssignment ==
    \A n_ode \in Nodes :
        Cardinality({t_id \in Tenants : n_ode \in tenant_nodes[t_id]}) <= 1

(* Property: Rack Affinity - nodes only appear in hardware for their designated rack *)
RackAffinity ==
    \A n_ode \in Nodes, r_id \in Racks, t_id \in Tenants, d_id \in DPUs :
        (n_ode \in dpu_hw[r_id, t_id, d_id]) => (NodeRack[n_ode] = r_id)

(* Property: DPU Affinity - nodes only appear in DPUs they're designated for *)
DPUAffinity ==
    \A n_ode \in Nodes, r_id \in Racks, t_id \in Tenants, d_id \in DPUs :
        (n_ode \in dpu_hw[r_id, t_id, d_id]) => (<<r_id, d_id>> \in NodeDPUs[n_ode])

(* Type Invariant: Configuration consistency - NodeDPUs only references valid racks for each node *)
ConfigurationConsistency ==
    \A n_ode \in Nodes :
        \A rack_dpu \in NodeDPUs[n_ode] :
            /\ rack_dpu[1] = NodeRack[n_ode]  \* DPU rack matches node's rack
            /\ rack_dpu[1] \in Racks          \* Rack is valid
            /\ rack_dpu[2] \in DPUs           \* DPU is valid

(* State constraint to limit state space exploration *)
StateConstraint ==
    /\ Cardinality(UNION {tenant_nodes[t] : t \in Tenants}) <= Cardinality(Nodes)
    /\ Cardinality(UNION {dpu_crs[r, t] : r \in Racks, t \in Tenants}) <= Cardinality(Nodes) + 2

(* Fairness: Assume failures eventually stop and reconciliation can make progress *)
Fairness ==
    /\ SF_Vars(MgmtRecover)                            \* Management plane eventually recovers and stays up
    /\ \A t_id \in Tenants : SF_Vars(TenantRecover)   \* Controllers eventually recover and stay up
    /\ \A t_id \in Tenants : SF_Vars(ApiServerUp)     \* API servers eventually recover and stay up
    /\ \A t_id \in Tenants : SF_Vars(EtcdUp)          \* Etcd eventually recovers and stays up
    /\ \A t_id \in Tenants : SF_Vars(EtcdRegainQuorum) \* Etcd eventually regains quorum
    /\ \A r_id \in Racks : SF_Vars(PowerOn)           \* Racks eventually power on and stay on
    /\ \A r_id \in Racks, d_id \in DPUs : SF_Vars(DPURecover) \* DPUs eventually recover
    /\ \A t_id \in Tenants : SF_Vars(MgmtTenantHeal)  \* Management-tenant networks eventually heal
    /\ \A t_id \in Tenants : SF_Vars(TenantDPUHeal)   \* Tenant-DPU networks eventually heal
    /\ WF_Vars(TenantWatch)                            \* Controllers eventually watch events
    /\ WF_Vars(TenantFlush)                            \* Controllers eventually flush buffers
    /\ WF_Vars(TenantCleanup)                          \* Controllers eventually clean up orphaned CRs
    /\ WF_Vars(ProcessCRDeletion)                      \* Deletions eventually propagate from etcd
    /\ WF_Vars(DPUReconcile)                           \* DPUs eventually reconcile

Spec == Init /\ [][Next]_Vars /\ Fairness

=============================================================================
