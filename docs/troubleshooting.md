# Troubleshooting

Common failure modes during OpenShift SNO installation on Azure.

---

## Installation log locations

```bash
# During installation (primary log)
tail -f openshift/.openshift_install.log

# Bootstrap VM logs (during installation only)
# First find bootstrap IP:
az vm list-ip-addresses \
  --resource-group "$(az group list --query "[?contains(name, 'sno')].name" -o tsv)" \
  --query "[?contains(virtualMachine.name, 'bootstrap')].virtualMachine.network.publicIpAddresses[0].ipAddress" \
  -o tsv

# SSH to bootstrap (private key must match the public key in install-config)
ssh -i ~/.ssh/id_ed25519 core@<bootstrap-ip>
journalctl -b -f -u bootkube.service
journalctl -b -f -u release-image.service

# Control plane node logs (after bootstrap completes)
ssh -i ~/.ssh/id_ed25519 core@<node-ip>
journalctl -b -f
```

---

## Failure categories

### Azure quota exceeded

**Symptom:**
```
Error: compute.VirtualMachinesClient#CreateOrUpdate: 
OperationNotAllowed: Operation could not be completed as it results in 
exceeding approved standardDSv3Family Cores quota.
```

**Fix:**
```bash
# Check current usage
az vm list-usage --location eastus2 \
  --query "[?name.localizedValue=='Standard DSv3 Family vCPUs']" \
  -o table

# Request increase via Azure portal:
# Portal → Subscriptions → <your sub> → Usage + quotas
# Filter: "Standard DSv3" → Request increase → 20 vCPUs minimum
```

### VM SKU not available in region

**Symptom:**
```
Error: Requested SKU is not available for the region. 
Standard_D8s_v3 is not available in location eastus2.
```

**Fix:**
```bash
# Verify SKU availability
az vm list-skus --location eastus2 --size Standard_D8s_v3 \
  --query "[].{Name:name, Restrictions:restrictions}" -o table

# Try an adjacent region
az vm list-skus --location eastus --size Standard_D8s_v3 \
  --query "[].{Name:name, Restrictions:restrictions}" -o table

# Or try Standard_D8s_v4 / Standard_D8s_v5 in the same region
az vm list-skus --location eastus2 \
  --query "[?starts_with(name, 'Standard_D8s_v')]" \
  --output table
```

If you change the VM SKU or region, regenerate `install-config.yaml` from scratch.

### DNS resolution failure

**Symptom:** Installer reports API unreachable, or times out waiting for bootstrap.

**Check:**
```bash
# Is the NS delegation propagated?
dig NS ocplab1.arunkube.org @8.8.8.8 +short

# Is the zone accessible?
az network dns zone show \
  --resource-group sno-dns-rg \
  --name ocplab1.arunkube.org

# Does the service principal have access to the DNS RG?
az role assignment list \
  --assignee "<sp-app-id>" \
  --scope "/subscriptions/<sub-id>/resourceGroups/sno-dns-rg" \
  -o table
```

**Fix:**
1. Ensure all four NS records are added to the parent zone
2. Wait for propagation (5–30 min typical; up to 48h at registrar)
3. Verify with `dig @8.8.8.8 NS ocplab1.arunkube.org` before retrying

### Service principal permissions insufficient

**Symptom:**
```
Error: authorization.RoleAssignmentsClient#Create: 
AuthorizationFailed: ... does not have authorization to perform action
'Microsoft.Authorization/roleAssignments/write'
```

**Fix:**
The service principal needs `User Access Administrator` in addition to
`Contributor`:
```bash
az role assignment create \
  --assignee "<sp-app-id>" \
  --role "User Access Administrator" \
  --scope "/subscriptions/<subscription-id>"
```

### Pull secret invalid or expired

**Symptom:** Installer fails with image pull errors or 401 Unauthorized.

**Fix:**
1. Get a fresh pull secret from https://console.redhat.com/openshift/install/pull-secret
2. Re-export: `export PULL_SECRET='<new-secret>'`
3. Regenerate `install-config.yaml`: `./scripts/02-create-install-config.sh`
4. Start fresh install in a new directory

### Ignition certificate expiry

**Symptom:** Installation fails with certificate validation errors ~12–24 hours
after `install-config.yaml` was generated.

**Root cause:** Ignition bootstrap certificates are only valid for 24 hours.

**Fix:**
1. Delete the installation directory
2. Re-generate `install-config.yaml` from scratch (restore from your backup)
3. Run `openshift-install create cluster` again immediately
4. Do not let more than 12 hours pass between generating config and starting install

### `create cluster` fails partway through

**Symptom:** Installer exits with an error mid-installation.

**Critical:** `openshift-install create cluster` **cannot be re-run on the same
directory**. The installer is not idempotent.

**Fix:**
```bash
# 1. First, destroy what was partially created
openshift-install destroy cluster --dir openshift/ --log-level=info

# Wait for destroy to complete, then:

# 2. Remove the installation directory
rm -rf openshift/

# 3. Restore your backup of install-config.yaml
cp openshift-backup/install-config.yaml openshift/

# 4. Fix the root cause (quota, DNS, permissions, etc.)

# 5. Re-run installation
openshift-install create cluster --dir openshift/ --log-level=info
```

### Bootstrap never completes (installer hangs)

**Symptom:** Installer hangs at "Waiting for bootstrapping to complete..."

**Check:**
```bash
# SSH to bootstrap VM
BOOTSTRAP_IP="<from Azure portal or az CLI>"
ssh -i ~/.ssh/id_ed25519 core@${BOOTSTRAP_IP}

# Check bootkube
journalctl -b -u bootkube.service --no-pager | tail -50

# Check release image pull
journalctl -b -u release-image.service --no-pager | tail -20

# Check disk space
df -h

# Check memory pressure
free -h
```

**Common causes:**
- Insufficient vCPU quota (bootstrap gets throttled)
- Network routing issues (bootstrap cannot reach Azure metadata endpoint)
- Image pull rate limit (rare with pull secret)

### ClusterOperator degraded after install

**Symptom:** `oc get co` shows one or more operators with `Degraded=True`.

```bash
# Get degraded operator details
oc get co | grep -v "True.*False.*False"

# Describe a specific operator
oc describe co <operator-name>

# Get operator logs
oc logs -n openshift-<operator-name> deployment/<operator-deployment>

# Check node resources
oc adm top node
```

On SNO, a brief degraded state is normal immediately after install as operators
settle. Wait 10 minutes before investigating. If still degraded:

```bash
# Check node has enough resources
oc describe node | grep -A 10 "Allocated resources"

# Check for eviction pressure
oc get node -o yaml | grep -A 5 "conditions:"
```

---

## Recovery procedure

If all recovery attempts fail:

```bash
# Destroy all installer-created resources
openshift-install destroy cluster --dir openshift/ --log-level=info

# Verify all resources gone in Azure portal or:
az group list --query "[?contains(name, 'sno')]" -o table

# Clean up installation directory
rm -rf openshift/

# Restore install-config.yaml from backup and fix the root cause
# Then re-run from 02-create-install-config.sh
```

See [docs/cleanup.md](cleanup.md) for full cleanup procedure.
