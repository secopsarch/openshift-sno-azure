# Cleanup

Proper cleanup prevents ongoing Azure charges and avoids resource conflicts
on the next install.

---

## What needs to be cleaned up

| Resource set | How to destroy | Managed by |
|---|---|---|
| OpenShift cluster resources | `openshift-install destroy cluster` | Installer |
| DNS zone + resource group | `terraform destroy` | Terraform |

> **Important:** Always run `openshift-install destroy cluster` BEFORE
> `terraform destroy`. The installer needs the DNS zone to exist during
> destruction to clean up the A records it created.

---

## Standard cleanup procedure

Use the cleanup script:

```bash
./scripts/99-cleanup.sh
```

The script will:
1. Display the target subscription, resource group, cluster name, and region
2. Require you to type `yes` explicitly before running any destructive command
3. Run `openshift-install destroy cluster --dir openshift/`
4. Ask separately whether to also destroy the DNS zone (Terraform)

---

## Manual cleanup procedure

If the script is not available or installation failed partway through:

### Step 1: Destroy the cluster

```bash
# The installer looks for cluster metadata in the installation directory
openshift-install destroy cluster \
  --dir openshift/ \
  --log-level=info
```

This removes:
- The cluster resource group (`sno-<random>-rg`) and all contents:
  - Control plane VM + disk
  - Load balancers (3)
  - Public IPs (3)
  - VNet + subnets
  - NSGs (2)
  - NICs (2)
  - DNS A records (`api.*` and `*.apps.*`)
  - Storage accounts
  - Managed identities
  - Image galleries

Monitor the output — the process takes 5–15 minutes.

### Step 2: Verify cluster resources are gone

```bash
# No resource groups with the cluster name should remain
az group list \
  --query "[?contains(name, 'sno')]" \
  -o table

# Check DNS zone is clean (A records should be gone)
az network dns record-set list \
  --resource-group sno-dns-rg \
  --zone-name ocp.lab1.arunkube.org \
  -o table
```

### Step 3: Clean up the installation directory

```bash
# Remove generated credentials and ignition files
rm -rf openshift/auth/
rm -f openshift/*.ign
rm -f openshift/install-config.yaml

# Keep openshift/install-config.yaml.example if you placed one there
```

### Step 4: Remove the Azure service principal credentials (optional)

```bash
# Remove the cached credentials file
rm -f ~/.azure/osServicePrincipal.json

# If you want to delete the service principal entirely:
az ad sp delete --id "<app-id>"
```

### Step 5: Destroy DNS zone (optional — keep for Phase 2 reproducibility)

If you want to fully clean up Terraform-managed resources:

```bash
cd terraform/
terraform destroy
# Review the plan, then type 'yes' to confirm
```

This removes:
- Azure DNS zone `ocp.lab1.arunkube.org`
- Resource group `sno-dns-rg`

> **Note for Phase 2:** If you are planning to redeploy (reproducibility testing),
> keep the DNS zone. Only the cluster resources need to be destroyed between runs.

---

## Partial cleanup (install failed)

If `openshift-install create cluster` failed before completing, some Azure
resources may have been created. The `destroy cluster` command handles this:

```bash
# This works even if install failed partway
openshift-install destroy cluster --dir openshift/ --log-level=info
```

The installer reads `openshift/.openshift_install_state.json` to identify
what was created and what needs to be removed.

If the state file is missing or corrupted:

```bash
# Find and manually delete the cluster resource group
az group list \
  --query "[?contains(name, 'sno')]" \
  -o table

# Delete the resource group (this removes everything inside it)
# WARNING: double-check the RG name before running
az group delete \
  --name "sno-<random>-rg" \
  --yes \
  --no-wait
```

After manual RG deletion, run `openshift-install destroy cluster` anyway — it
will clean up DNS records even if the VMs are already gone.

---

## Verify complete cleanup

```bash
# No cluster resource groups
az group list --query "[?contains(name, 'sno')]" -o table

# No orphaned public IPs
az network public-ip list --query "[?contains(name, 'sno')]" -o table

# No orphaned load balancers
az network lb list --query "[?contains(name, 'sno')]" -o table

# DNS zone is clean (only SOA + NS records remain)
az network dns record-set list \
  --resource-group sno-dns-rg \
  --zone-name ocp.lab1.arunkube.org \
  -o table

# Local installation artifacts
ls -la openshift/auth/     # Should be gone
ls -la openshift/*.ign     # Should be gone
```

---

## Cost cutoff

If you cannot run the cleanup procedure immediately, you can stop the VM to
reduce compute costs (disk charges still apply):

```bash
# Deallocate the SNO control plane VM (stops billing for compute)
# Find VM name first:
az vm list \
  --resource-group "sno-<random>-rg" \
  --query "[].name" -o tsv

# Deallocate
az vm deallocate \
  --resource-group "sno-<random>-rg" \
  --name "<vm-name>"
```

> This is a temporary measure only. Run full cleanup as soon as possible.
> Load balancers, public IPs, and DNS zone continue to accrue charges even
> when the VM is deallocated.
