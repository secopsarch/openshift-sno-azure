# OpenShift SNO on Azure — Implementation Plan

## Status

| Phase | Status |
|---|---|
| Phase 1 — SNO | 🔧 In progress |
| Phase 2 — Reproducibility | Not started |
| Phase 3 — Compact cluster | Not started |
| Phase 4 — 6-node cluster | Not started |

---

## Architecture validation (completed)

The following items were verified against official OCP 4.22 and Azure documentation
before any code was written. Discrepancies from initial assumptions are noted.

### Confirmed facts

| Item | Value | Source |
|---|---|---|
| SNO on Azure | Supported via IPI customizations | OCP 4.22 docs |
| Azure architecture | x86_64 only (arm64 not supported on Azure for SNO) | OCP 4.22 docs |
| Network plugin | OVNKubernetes only (OpenShiftSDN not supported for SNO) | OCP 4.22 docs |
| SNO minimum vCPU | 4 vCPU | OCP 4.22 docs |
| SNO minimum RAM | 16 GB | OCP 4.22 docs |
| SNO minimum disk | 120 GB | OCP 4.22 docs |
| SNO control plane OS disk default | **1024 GB** (must override!) | OCP 4.22 install-config params |
| Target VM SKU | `Standard_D8s_v3` (8 vCPU, 32 GB, Premium SSD) | Verified available |
| Bootstrap VM SKU (IPI, not configurable) | `Standard_D8s_v3` (8 vCPU) | OCP 4.22 docs |
| Bootstrap VM configurable in IPI? | **No** — configurable only in UPI | OCP 4.22 docs |
| vCPU peak during SNO install | 16 vCPU (bootstrap 8 + control plane 8) | Derived |
| vCPU post-install | 8 vCPU | Derived |
| Azure default vCPU quota | 20/region (Standard DSv3 family) | Azure docs |
| SNO fits default quota | Yes — 16 < 20 (if no other DSv3 VMs running) | Derived |
| Azure DNS zone type | Public hosted zone | OCP 4.22 docs |
| DNS zone must pre-exist | Yes, before running openshift-install | OCP 4.22 docs |
| Subdomain delegation | Supported | OCP 4.22 docs |
| Azure roles required | Contributor + User Access Administrator | OCP 4.22 docs |
| `create cluster` retryable | **No** — one-shot; new directory required on retry | OCP 4.22 docs |
| Ignition cert expiry | 24 hours from generation | OCP 4.22 docs |
| Terraform azurerm version | `~> 5.1` (latest: 5.1.0 as of Aug 2026) | Terraform Registry |
| Minimum Terraform version | 1.6+ | Confirmed |

### Corrected assumptions (vs. initial plan)

1. **Terraform azurerm `~> 4.0` → `~> 5.1`**
   Initial plan assumed v4. Current stable release is v5.1.0 (Aug 13 2026).
   Breaking changes exist between v4 and v5; use v5.

2. **Azure roles: Contributor alone is insufficient**
   Both `Contributor` and `User Access Administrator` are required at subscription
   scope. The IPI installer assigns managed identities to VMs during installation.

3. **`create cluster` one-shot behavior explicitly documented**
   The command cannot be re-run on the same directory. If installation fails,
   a new directory and fresh `install-config.yaml` are required. Scripts must
   communicate this clearly.

### Terraform / installer boundary (confirmed)

```
TERRAFORM OWNS                   OPENSHIFT-INSTALL OWNS
─────────────────────────        ──────────────────────────────────────────
Resource group: sno-dns-rg       Resource group: sno-<random>-rg
Azure public DNS zone            VNet + 2 subnets (control-plane + compute)
  ocp.lab1.arunkube.org          NSGs: controlplane (6443), node (80/443)
                                 LBs: internal (6443+22623), external (6443),
                                      default (80/443)
                                 Bootstrap VM: Standard_D8s_v3 (temporary)
                                 Control plane VM: Standard_D8s_v3 (permanent)
                                 Public IPs (3): 2x LBs + bootstrap
                                 NICs (2)
                                 DNS A records: api.* and *.apps.*
                                 Storage accounts
                                 Managed identities
                                 Image galleries (RHCOS)
```

No overlap. No Terraform state contains installer-managed resources.

---

## Phase 1 — Single Node OpenShift

**Goal:** One working OpenShift SNO cluster running on Azure.

**Target configuration:**

| Parameter | Value |
|---|---|
| OpenShift version | 4.22 |
| Cluster name | `sno` (configurable) |
| Base domain | `ocp.labX.arunkube.org` (configurable) |
| Azure region | `eastus2` (configurable) |
| Control plane VM | `Standard_D8s_v3` |
| Control plane replicas | 1 |
| Worker replicas | 0 |
| OS disk | 128 GB `Premium_LRS` |
| Network plugin | `OVNKubernetes` |
| DNS zone | `ocp.lab1.arunkube.org` (Azure public DNS) |

### Deliverables

- [ ] Azure prerequisites validated (quota, SKU availability, roles)
- [ ] DNS zone created (Terraform) and delegation verified
- [ ] `install-config.yaml` generated (no secrets committed)
- [ ] OpenShift installation completed
- [ ] SNO node is `Ready`
- [ ] ClusterVersion is `Available`
- [ ] ClusterOperators are healthy (Available=True, Progressing=False, Degraded=False)
- [ ] API endpoint reachable
- [ ] Console reachable
- [ ] Test application deployed (nginx)
- [ ] Test application reachable externally
- [ ] Cleanup procedure verified

### Installation workflow

```
1.  az login && az account set
2.  ./scripts/00-check-prerequisites.sh  — verify tools
3.  ./scripts/01-check-azure.sh          — verify quota, SKU, subscription
4.  terraform init + plan + apply        — create DNS zone
5.  Add NS delegation records at registrar
6.  Verify DNS propagation
7.  Obtain pull secret from console.redhat.com
8.  Configure SSH key
9.  ./scripts/02-create-install-config.sh
10. Review openshift/install-config.yaml
11. Back up install-config.yaml
12. ./scripts/03-install-sno.sh          — requires your confirmation
13. ./scripts/04-wait-for-install.sh     — ~40-90 minutes
14. ./scripts/05-validate-cluster.sh
15. Deploy nginx demo
```

### Definition of done

```
[ ] VERIFIED: Azure authentication
[ ] VERIFIED: Azure quota (Standard DSv3 ≥ 16 vCPU available)
[ ] VERIFIED: Standard_D8s_v3 available in eastus2
[ ] VERIFIED: DNS zone created and NS delegation propagated
[ ] VERIFIED: Pull secret present (not committed)
[ ] VERIFIED: SSH key pair exists
[ ] VERIFIED: install-config.yaml valid
[ ] VERIFIED: openshift-install create cluster completed without error
[ ] VERIFIED: SNO node Ready
[ ] VERIFIED: ClusterVersion Available
[ ] VERIFIED: All ClusterOperators Available=True, Degraded=False
[ ] VERIFIED: API reachable (oc whoami = system:admin)
[ ] VERIFIED: Console URL accessible in browser
[ ] VERIFIED: Ingress working (test Route resolves externally)
[ ] VERIFIED: nginx app responds via curl
[ ] VERIFIED: cleanup procedure runs and removes all resources
```

---

## Phase 2 — Reproducibility

After Phase 1 succeeds:

1. Run `./scripts/99-cleanup.sh` — destroy the cluster
2. Verify all installer-created Azure resources are gone
3. Re-run the full installation from step 9 (DNS zone stays)
4. Verify the second installation succeeds
5. Update documentation with any fixes found during replay
6. Tag the repository at this stable point

---

## Phase 3 — Compact cluster (future, not implemented)

**Architecture:** Three control-plane nodes. No dedicated workers. All three
control-plane nodes are schedulable (workers: 0).

```yaml
controlPlane:
  replicas: 3
compute:
- name: worker
  replicas: 0
```

**Important:** This is NOT a "master + worker + infra" topology. It is three
nodes that each run both control-plane and workload roles. The `compute.replicas: 0`
makes all three control-plane nodes schedulable.

**Resource estimate (Standard_D8s_v3 × 3):**
- 3 × 8 vCPU = 24 vCPU (plus bootstrap during install)
- Azure quota needed: ~32 vCPU

**Terraform scope:** same DNS-only boundary. Installer creates all VMs.

**Do not implement until Phase 1 and Phase 2 are complete.**

---

## Phase 4 — 6-node cluster (future, not implemented)

**Architecture:** Standard OpenShift topology.

```yaml
controlPlane:
  replicas: 3      # Standard_D8s_v3 or equivalent
compute:
- name: worker
  replicas: 3      # Standard_D4s_v3 or equivalent
```

This separates control-plane concerns (etcd, API server, scheduler) from
workload concerns. Suitable for:
- Production-like lab testing
- Operator deployments
- OpenShift Virtualization lab
- Multi-tenant testing

**Resource estimate:**
- 3 × control plane (8 vCPU) + 3 × compute (4 vCPU) + bootstrap (8 vCPU) = 44 vCPU peak
- Azure quota increase required (default is 20/region)

**Infrastructure nodes:** OpenShift supports a fourth node role (`infra`) for
moving infrastructure workloads (monitoring, logging, registry) off worker nodes.
This is useful in production but not required for a lab.

**Terraform scope:** DNS-only boundary remains valid. All VMs still IPI-owned.

**Do not implement until Phase 2 is complete.**
