# Architecture

## Overview

OpenShift SNO 4.22 on Azure using Installer-Provisioned Infrastructure (IPI).

One control-plane node runs all OpenShift roles: API server, etcd, scheduler,
controller manager, kubelet, ingress, and workloads. There are no separate
worker nodes.

---

## Topology diagram

```
                        Internet
                           |
                    ┌──────┴──────┐
                    │  Azure DNS  │
                    │  Public     │
                    │  Zone       │
                    │  ocplabX   │
                    │  .arunkube  │
                    │  .org       │
                    └──────┬──────┘
                           │
              ┌────────────┴────────────┐
              │                         │
    api.sno.ocplabX.*       *.apps.sno.ocplabX.*
              │                         │
              └────────────┬────────────┘
                           │
                    ┌──────┴──────┐
                    │  Azure VNet │  (created by installer)
                    │  10.0.0.0/16│
                    └──────┬──────┘
                           │
              ┌────────────┴─────────────┐
              │                          │
     ┌────────┴───────┐        ┌─────────┴────────┐
     │  Control-plane │        │  Bootstrap VM     │
     │  subnet        │        │  (temporary)      │
     │  SNO node      │        │  Standard_D8s_v3  │
     │  Standard_D8s_v3│       │  ~40-90 min       │
     │  8 vCPU        │        │  removed after    │
     │  32 GB RAM     │        │  install          │
     │  128 GB SSD    │        └──────────────────-┘
     │                │
     │  Roles:        │
     │  master        │
     │  worker        │
     │  etcd          │
     │  ingress       │
     │  workloads     │
     └────────────────┘
```

---

## Resource ownership

### Terraform manages (pre-install, lives outside cluster lifecycle)

| Resource | Name | Purpose |
|---|---|---|
| Resource group | `sno-dns-rg` | Container for DNS zone |
| Azure DNS zone | `ocplab1.arunkube.org` | Public DNS for cluster |

Terraform state contains only these two resources. The DNS zone persists
across cluster create/destroy cycles (Phase 2 reproducibility testing).

### `openshift-install` manages (cluster lifecycle)

The installer creates and destroys all of the following via `create cluster`
and `destroy cluster`. **Terraform must never manage these.**

| Resource | Details |
|---|---|
| Resource group | `sno-<random_id>-rg` — installer takes full ownership |
| VNet | One VNet (`10.0.0.0/16`), two subnets |
| Subnets | `sno-<id>-master-subnet`, `sno-<id>-worker-subnet` |
| NSGs | `sno-<id>-controlplane-nsg` (port 6443), `sno-<id>-node-nsg` (80/443) |
| Load balancers | Internal LB (6443 + 22623), External LB (6443), Default LB (80/443) |
| Public IPs | API external IP, Ingress IP, Bootstrap IP (temporary) |
| Bootstrap VM | `Standard_D8s_v3` — created at install start, destroyed after bootstrap |
| Control plane VM | `Standard_D8s_v3` — the SNO node |
| NICs | One per VM |
| DNS A records | `api.*` and `*.apps.*` in the Terraform-managed zone |
| Storage accounts | RHCOS image storage |
| Managed identities | Assigned to VMs by installer |
| Image galleries | RHCOS VM image |

### You manage (outside this repository)

| Resource | Where | Purpose |
|---|---|---|
| NS delegation records | Your registrar or parent DNS zone | Delegate `ocplabX.arunkube.org` to Azure DNS |
| Pull secret | `console.redhat.com` | OpenShift image pull authorization |
| SSH key pair | `~/.ssh/` | Node access |
| Azure service principal | Azure AD | Installer authentication |

---

## Network ports

| Port | Protocol | Direction | Purpose |
|---|---|---|---|
| 6443 | TCP | Inbound | Kubernetes API server |
| 22623 | TCP | Inbound (internal only) | Machine Config Server (bootstrap) |
| 80 | TCP | Inbound | HTTP ingress |
| 443 | TCP | Inbound | HTTPS ingress |
| 22 | TCP | Inbound (optional) | SSH to node (troubleshooting) |

---

## DNS record structure

```
Zone: ocplab1.arunkube.org
  (Terraform-managed, Azure public DNS zone)

Records created by installer:
  api.sno.ocplab1.arunkube.org.        A  → External LB public IP
  *.apps.sno.ocplab1.arunkube.org.     A  → Default LB public IP

Resulting FQDNs:
  API endpoint:    https://api.sno.ocplab1.arunkube.org:6443
  Console:         https://console-openshift-console.apps.sno.ocplab1.arunkube.org
  OAuth:           https://oauth-openshift.apps.sno.ocplab1.arunkube.org
  Any Route:       https://<route-name>.apps.sno.ocplab1.arunkube.org
```

---

## Bootstrap lifecycle

The bootstrap VM exists only during installation:

```
openshift-install create cluster
  │
  ├─ Creates bootstrap VM (Standard_D8s_v3)
  ├─ Creates control plane VM (Standard_D8s_v3)
  ├─ Bootstrap serves ignition config to control plane
  ├─ Control plane starts etcd, API server
  ├─ Bootstrap transfers cluster state to control plane
  ├─ Bootstrap VM is DESTROYED automatically
  └─ Installer waits for all cluster operators to become available
     (~40–90 minutes total)
```

The bootstrap VM uses a public IP during installation for troubleshooting SSH
access. This IP is released when the bootstrap VM is destroyed.

---

## vCPU quota

| Phase | vCPU | Duration |
|---|---|---|
| During installation | 16 (bootstrap 8 + control plane 8) | ~40–90 min |
| Post-installation | 8 (control plane only) | Until destroyed |

Azure default Standard DSv3 quota: 20 vCPU per region.
SNO installation fits within default quota (16 < 20), provided no other
`Standard_D*s_v3` VMs are currently running in the same subscription + region.

---

## Future evolution

See [PLAN.md](../PLAN.md) for Phase 3 (compact 3-node) and Phase 4 (6-node).
Architecture files for future phases will be added when those phases begin.
