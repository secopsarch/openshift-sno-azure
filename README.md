# OpenShift SNO on Azure

Single Node OpenShift (SNO) 4.22 deployed on Microsoft Azure using the official
Red Hat Installer-Provisioned Infrastructure (IPI) method.

> **Important distinction:** This repository deploys SNO directly on Azure using the
> supported Azure IPI workflow. It does NOT use the Assisted Installer, discovery
> ISO, bare-metal workflows, ARO, nested virtualization, or UPI ARM templates.
> The supported path is: `openshift-install create cluster` with `platform.azure`.

---

## Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [DNS setup](#dns-setup)
- [Cost](#cost)
- [Phases](#phases)
- [Cleanup](#cleanup)

---

## Architecture

One control-plane node. No workers. All roles (master, worker, etcd, ingress) run
on the single node.

```
Internet
   |
Azure DNS (public zone: ocplabX.arunkube.org)
   |         \
api.sno.*   *.apps.sno.*
   |              |
   +----+----+----+
        |
   Azure VNet (created by installer)
        |
   +----+----+
   |         |
Bootstrap   SNO Control Plane
(temporary) Standard_D8s_v3
~40 min     8 vCPU / 32 GB RAM
removed     128 GB premium_LRS
after       (all roles: master +
install     worker + etcd + ingress)
```

**Terraform owns:** DNS resource group + Azure public DNS zone only.

**`openshift-install` owns:** everything else (VNet, subnets, NSGs, load balancers,
VMs, public IPs, NICs, DNS A records, storage accounts, managed identities).

See [docs/architecture.md](docs/architecture.md) for full resource map.

---

## Prerequisites

| Tool | Minimum version | Purpose |
|---|---|---|
| `az` (Azure CLI) | 2.50+ | Azure authentication and quota checks |
| `terraform` | 1.6+ | DNS zone pre-provisioning |
| `openshift-install` | 4.22.x | Cluster installation |
| `oc` | 4.22.x | Post-install cluster management |
| `jq` | 1.6+ | JSON parsing in scripts |
| `curl` | any | Download checks |
| `ssh` / `ssh-keygen` | any | Key generation |

See [docs/prerequisites.md](docs/prerequisites.md) for exact installation
instructions and version checks.

---

## Quick start

```bash
# 1. Authenticate to Azure
az login
az account show
az account set --subscription "<your-subscription-id>"

# 2. Check prerequisites and quota
./scripts/00-check-prerequisites.sh
./scripts/01-check-azure.sh

# 3. Create DNS zone (Terraform — non-destructive, preview first)
cd terraform/
terraform init
terraform plan
# Review, then: terraform apply

# 4. Add NS delegation records at your registrar/parent DNS
# (see docs/dns.md)

# 5. Configure secrets (never committed)
export PULL_SECRET='<paste pull secret from console.redhat.com>'
export SSH_PUBLIC_KEY_PATH="$HOME/.ssh/id_ed25519.pub"

# 6. Generate install-config
./scripts/02-create-install-config.sh

# 7. Review install-config, then install (requires your explicit approval)
./scripts/03-install-sno.sh

# 8. Monitor installation (~40-90 minutes)
./scripts/04-wait-for-install.sh

# 9. Validate cluster
./scripts/05-validate-cluster.sh

# 10. Deploy test application
cd examples/nginx/
oc new-project sno-demo
oc apply -f deployment.yaml -f service.yaml -f route.yaml
```

---

## DNS setup

The cluster requires a public Azure DNS zone for `ocplabX.arunkube.org`
(replace `labX` with your lab number, e.g. `lab1`).

Terraform creates:
- Resource group: `sno-dns-rg`
- Azure DNS zone: `ocplab1.arunkube.org`

After `terraform apply`, add the four NS records Terraform outputs to your
parent domain (`arunkube.org`) at your DNS registrar.

The installer then automatically creates:
- `api.sno.ocplab1.arunkube.org` → API load balancer IP
- `*.apps.sno.ocplab1.arunkube.org` → Ingress load balancer IP

See [docs/dns.md](docs/dns.md) for detailed DNS setup instructions.

---

## Cost

Azure compute is billable. This SNO deployment creates the following billable
resources:

| Resource | Type | Billing |
|---|---|---|
| Control plane VM | `Standard_D8s_v3` (8 vCPU / 32 GB) | Per hour while running |
| OS disk | 128 GB `Premium_LRS` | Per hour provisioned |
| Bootstrap VM | `Standard_D8s_v3` | Per hour during install (~40-90 min), then deleted |
| Bootstrap disk | 100 GB `Premium_LRS` | During install only, then deleted |
| Load balancers (3) | Azure Standard LB | Per hour + data processed |
| Public IPs (3) | Standard SKU | Per hour while allocated |
| DNS zone | Azure DNS | Per zone per month + queries |
| Storage account | LRS | Per GB stored |

**Approximate ongoing cost after installation (control plane VM only):**
The `Standard_D8s_v3` in `eastus2` costs approximately $0.38/hour (Pay As You Go,
subject to change — verify at [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)).

**This is not a production cluster.** Destroy it when not in use.

```bash
# Destroy everything
./scripts/99-cleanup.sh
```

OpenShift subscription/licensing requirements are separate from Azure
infrastructure costs. A Red Hat Developer Subscription (free) is sufficient for
lab use. Pull secret from [console.redhat.com](https://console.redhat.com).

---

## Phases

| Phase | Goal | Status |
|---|---|---|
| **Phase 1 — SNO** | One working SNO cluster on Azure | 🔧 In progress |
| Phase 2 — Reproducibility | Destroy + redeploy, verify process | Not started |
| Phase 3 — Compact cluster | 3 control-plane nodes, 0 workers | Not started |
| Phase 4 — 6-node cluster | 3 control-plane + 3 workers | Not started |

See [PLAN.md](PLAN.md) for phase details.

---

## Cleanup

```bash
./scripts/99-cleanup.sh
```

The cleanup script will:
1. Display the target subscription, resource group, cluster name, and region
2. Require explicit typed confirmation before running anything destructive
3. Run `openshift-install destroy cluster` to remove all installer-created resources
4. Optionally run `terraform destroy` to remove the DNS zone

See [docs/cleanup.md](docs/cleanup.md) for full cleanup documentation.

---

## Security

The following files are NEVER committed and are in `.gitignore`:

- `openshift/install-config.yaml` (contains pull secret and SSH key)
- `openshift/auth/` (contains kubeconfig and kubeadmin password)
- `openshift/*.ign` (ignition files)
- `terraform/terraform.tfvars` (contains real variable values)
- `terraform/.terraform/` (provider binaries)
- `terraform/terraform.tfstate*` (may contain sensitive data)
- `~/.azure/osServicePrincipal.json` (Azure credentials used by installer)

---

## References

- [OCP 4.22 — Installing on a single node](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_a_single_node/install-sno-installing-sno)
- [OCP 4.22 — Installing on Azure (IPI)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_azure/installer-provisioned-infrastructure)
- [OCP 4.22 — Azure account configuration](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_azure/installing-azure-account)
- [OCP 4.22 — Azure install-config parameters](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_azure/installation-config-parameters-azure)
- [Red Hat Hybrid Cloud Console](https://console.redhat.com) — pull secret
