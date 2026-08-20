# Future lab extensions

Notes for bastion access, Multus/multihomed networking, OpenShift Virtualization,
and changing the lab DNS zone (`ocplab1` → `ocplab2`). **Not implemented in Phase 1.**

---

## 1. Bastion VM on the cluster subnet

### Question

Do you need a separate bastion VM on the same subnet as the SNO master for SSH
when console/API access fails?

### Validation

| Access path | Already available? | Notes |
|---|---|---|
| OpenShift web console | Yes | Primary UI — `https://console-openshift-console.apps.sno.<domain>` |
| `oc` / API (`6443`) | Yes | Via kubeconfig from your workstation |
| SSH to SNO node | **Yes** | Your install-config SSH public key is on the RHCOS node |
| SSH from inside VNet only | Partially | SNO node has a private IP on the installer VNet; no public SSH by default |

**SSH to the SNO node today (no bastion):**

```bash
# Find the node private IP (Azure portal or CLI)
az vm list -g sno-<infraID>-rg -o table

# SSH works IF you have network path to the private IP:
# - Azure Cloud Shell (same subscription, often can reach VNet via peering — not default)
# - VPN / ExpressRoute into the VNet
# - Serial console in Azure portal (break-glass, not full SSH)
ssh -i ~/.ssh/id_ed25519 core@sno-<infraID>-master-0.<private-ip-or-dns>
```

On Azure IPI, the control-plane NIC is on the **master subnet** (`10.0.0.0/24` range
in default install-config). It is **not** given a public IP for SSH. Ingress/API use
load balancer public IPs, not the node NIC directly.

### Is a bastion required?

| Scenario | Bastion needed? |
|---|---|
| Console works, `oc` works from laptop | **No** |
| Console broken but API/kubeconfig works | **No** — use `oc debug node/...` |
| Need shell on node, no VPN to VNet | **Yes** — jump host with public IP on same VNet |
| Break-glass when API and console both down | **Recommended** — small Linux VM + NSG allowing SSH from your IP |

### If you add a bastion later

**Terraform/installer does NOT create it.** Add manually or via separate Terraform:

1. Use the **same VNet** created by the installer: `sno-<infraID>-rg` / `sno-<infraID>-vnet`
2. Place bastion on **master subnet** (or a dedicated `bastion` subnet peered to master)
3. NSG: allow `22/tcp` from your public IP only
4. Size: `Standard_B1s` or `Standard_B2s` (cheap)
5. SSH: `ssh user@<bastion-public-ip>` then `ssh core@<master-private-ip>`

**Cost:** ~$7–15/month if left running. Stop/deallocate when not in lab.

**Do not** modify installer-owned resources in Terraform — bastion is out-of-band.

---

## 2. Secondary vNIC / Multus / multihomed / OpenShift Virtualization

### Question

Can you attach a secondary NIC from a different network for Multus, multihomed pods,
and future virtualization labs?

### Validation on Azure SNO

| Capability | Supported on Azure? | SNO 4.20? | Notes |
|---|---|---|---|
| Multus (multiple networks) | Yes | Yes | Requires `NMState` or manual NNCP + NAD |
| Secondary Azure NIC on VM | Yes (Azure feature) | **Not via IPI** | Installer creates one NIC per machine; adding NIC post-install is manual |
| User-defined networks (UDN) | OCP 4.17+ | Check docs | May overlap with Multus for lab use |
| OpenShift Virtualization (CNV) | Yes on Azure | **Possible on SNO** | Heavy — needs extra CPU/RAM/disk; separate operator install |
| Live migration | Azure | Limited on SNO | SNO has one node — no migration target |

### Practical path for this lab

**Phase A — Multus without second physical NIC (software-only):**

- Use `macvlan` or `ipvlan` on the **existing** node interface (same L2, logical separation)
- Good for learning NAD/NAD definitions, not true L2 isolation

**Phase B — True second network (recommended for serious multihomed labs):**

1. **After cluster is up**, manually in Azure:
   - Create second VNet (e.g. `10.1.0.0/16`) or subnet
   - VNet peering: installer VNet ↔ lab VNet
   - Attach **second NIC** to VM `sno-<infraID>-master-0` on the second subnet
2. On the node, configure with **NMState** (`NodeNetworkConfigurationPolicy`) or
   `nmstate` on RHCOS (via MachineConfig / NNCP)
3. Create **NetworkAttachmentDefinition** pointing at the second interface
4. Deploy test pods with Multus annotation

**Phase C — OpenShift Virtualization (future):**

- Install `OpenShift Virtualization` operator (requires valid subscription)
- SNO can run VMs on the single node but:
  - Adds significant resource pressure on 8 vCPU / 32 GB
  - Nested virt on Azure: supported on many SKUs; verify `Standard_D8s_v7`
  - Plan quota for VM workloads + cluster overhead

### Blockers / cautions

- **IPI will not** add a second NIC — manual Azure + day-2 OpenShift config
- **Cluster API / MCO** may reconcile network changes — use supported NMState paths
- **SNO capacity**: multihomed + CNV on same node is tight; compact/6-node Phase 3/4
  is the better long-term home for virtualization labs
- Document any manual NIC in `archives/` run notes — not in git

### References

- [Multus documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/networking/understanding-multiple-networks)
- [NMState on OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/networking/nmstate-about-the-nmstate-operator)
- [OpenShift Virtualization on Azure](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/about)

---

## 3. Changing base domain: `ocplab1.arunkube.org` → `ocplab2.arunkube.org`

You **cannot rename** an existing cluster's base domain. DNS names (`api.sno.*`,
`*.apps.sno.*`), certificates, and ingress are bound at install time.

To use `ocplab2`, **destroy and reinstall** (or install a second cluster) with the
new domain. Update these locations **once** before the next install:

### One-time checklist (new cluster / reproducibility)

| # | Location | What to change |
|---|---|---|
| 1 | `terraform/terraform.tfvars` | `dns_zone_name = "ocplab2.arunkube.org"` |
| 2 | Cloudflare (parent zone) | NS records for `ocplab2` → Azure nameservers (after `terraform apply`) |
| 3 | `export BASE_DOMAIN=ocplab2.arunkube.org` | Before `./scripts/02-create-install-config.sh` |
| 4 | Or edit generated `openshift/install-config.yaml` | `baseDomain: ocplab2.arunkube.org` |
| 5 | `scripts/01-check-azure.sh` | `export DNS_ZONE_NAME=ocplab2.arunkube.org` when checking DNS |
| 6 | `examples/nginx/route.yaml` comment | Update example hostname (optional) |
| 7 | Docs/examples | Search `ocplab1` → `ocplab2` if you want docs to match |

### Files that pick up domain automatically (no edit if using env vars)

| File | How domain is set |
|---|---|
| `scripts/02-create-install-config.sh` | `BASE_DOMAIN` env (default `ocplab1.arunkube.org`) |
| `terraform/main.tf` | `var.dns_zone_name` from `terraform.tfvars` |
| `openshift/install-config.yaml.example` | Template only — regenerate via script |

### Files you must NOT edit for a running cluster

- `openshift/metadata.json` — infra ID fixed at install
- `openshift/auth/kubeconfig` — API URL baked in
- Azure DNS A records in old zone — managed by installer in `sno-dns-rg` zone only

### Workflow: switch from ocplab1 to ocplab2

```bash
# 1. Destroy current cluster (keeps ocplab1 DNS zone unless you destroy Terraform too)
./scripts/99-cleanup.sh

# 2. Create new Azure DNS zone for ocplab2
cd terraform
# Edit terraform.tfvars: dns_zone_name = "ocplab2.arunkube.org"
terraform plan
terraform apply

# 3. Add NS delegation in Cloudflare for ocplab2 (four Azure nameservers)

# 4. Regenerate install-config with new base domain
export BASE_DOMAIN=ocplab2.arunkube.org
export PULL_SECRET=/home/devops/pull-secret.txt
./scripts/02-create-install-config.sh

# 5. Install
./scripts/03-install-sno.sh
```

### Optional: keep both zones

- `ocplab1.arunkube.org` — lab 1 (current cluster)
- `ocplab2.arunkube.org` — lab 2 (second cluster, different `CLUSTER_NAME` if desired)

Each zone needs its own NS delegation in Cloudflare. Each cluster needs its own
install run and resource group (`sno-<random>-rg`).

### Quick search command

```bash
cd openshift-sno-azure
grep -rn 'ocplab1' --include='*.md' --include='*.sh' --include='*.yaml' --include='*.example' --include='*.tf' .
# Exclude: archives/, openshift/ (generated), terraform.tfstate
```

---

## Summary

| Future item | Required for Phase 1? | When to implement |
|---|---|---|
| Bastion VM | No (SSH key already on node; use bastion only if no VPN to VNet) | Before break-glass lab or API-outage drills |
| Secondary NIC + Multus | No | Multus/macvlan lab first; physical second NIC when needed |
| OpenShift Virtualization | No | After compact/6-node or quota increase |
| ocplab2 domain | No | New install only — follow checklist above |
