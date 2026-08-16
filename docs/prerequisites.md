# Prerequisites

Everything that must be in place before running `openshift-install create cluster`.

---

## 1. Required tools

Run `./scripts/00-check-prerequisites.sh` to verify all tools are present.

| Tool | Minimum | How to install |
|---|---|---|
| `az` (Azure CLI) | 2.50+ | https://learn.microsoft.com/cli/azure/install-azure-cli |
| `terraform` | 1.6+ | https://developer.hashicorp.com/terraform/install |
| `openshift-install` | 4.22.x | See below |
| `oc` | 4.22.x | See below |
| `jq` | 1.6+ | `apt install jq` / `brew install jq` |
| `curl` | any | Usually pre-installed |
| `ssh` / `ssh-keygen` | any | Usually pre-installed |

### Install openshift-install and oc (4.22)

```bash
# Set version
export OCP_VERSION="latest-4.22"
export ARCH="x86_64"

# Download openshift-install
curl -L \
  "https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${OCP_VERSION}/openshift-install-linux.tar.gz" \
  -o /tmp/openshift-install-linux.tar.gz
tar -xzf /tmp/openshift-install-linux.tar.gz -C /usr/local/bin/ openshift-install
chmod +x /usr/local/bin/openshift-install

# Download oc
curl -L \
  "https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${OCP_VERSION}/openshift-client-linux.tar.gz" \
  -o /tmp/openshift-client-linux.tar.gz
tar -xzf /tmp/openshift-client-linux.tar.gz -C /usr/local/bin/ oc kubectl
chmod +x /usr/local/bin/oc /usr/local/bin/kubectl

# Verify
openshift-install version
oc version --client
```

Mirror URL: https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/

---

## 2. Azure account

### Authentication

```bash
az login
az account show
az account set --subscription "<your-subscription-id>"
```

### Required Azure roles

The identity used by `openshift-install` (service principal or managed identity)
needs **both** of these roles at subscription scope:

| Role | Why required |
|---|---|
| `Contributor` | Create and manage Azure resources |
| `User Access Administrator` | Assign managed identities to VMs during install |

> **Note:** If you set `identity.type: None` in `install-config.yaml`, the
> `User Access Administrator` role is not required. However, this is an
> advanced configuration — use the default for Phase 1.

### Create a service principal

```bash
# Get your subscription ID
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Create service principal
az ad sp create-for-rbac \
  --role Contributor \
  --scopes "/subscriptions/${SUBSCRIPTION_ID}" \
  --name "openshift-sno-installer"

# Save the output (appId, password, tenant) — needed during openshift-install
# DO NOT commit these values
```

Assign User Access Administrator separately:

```bash
SP_APP_ID="<appId from above>"

az role assignment create \
  --assignee "${SP_APP_ID}" \
  --role "User Access Administrator" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}"
```

The installer stores credentials in `~/.azure/osServicePrincipal.json` after
the first interactive prompt. You can pre-create this file:

```bash
cat > ~/.azure/osServicePrincipal.json <<EOF
{
  "subscriptionId": "${SUBSCRIPTION_ID}",
  "clientId": "${SP_APP_ID}",
  "clientSecret": "<password from sp create>",
  "tenantId": "<tenantId from sp create>"
}
EOF
chmod 600 ~/.azure/osServicePrincipal.json
```

> **Never commit `osServicePrincipal.json`.**

### Required Azure quota

Run `./scripts/01-check-azure.sh` to verify.

| Resource | Required (peak install) | Azure default |
|---|---|---|
| Standard DSv3 vCPUs | 16 | 20/region |
| Network load balancers | 3 | 1000/region |
| Public IP addresses | 3 | 20/region |
| VNets | 1 | 1000/region |
| NSGs | 2 | 5000 |

If your quota for Standard DSv3 vCPUs is below 16 in `eastus2`, request an
increase before installing:

```bash
# Check current quota
az vm list-usage --location eastus2 \
  --query "[?name.localizedValue=='Standard DSv3 Family vCPUs']" \
  -o table

# Increase via Azure portal: Subscriptions → Usage + quotas → Request increase
```

### Verify VM SKU availability

```bash
# Confirm Standard_D8s_v3 is available in eastus2
az vm list-skus \
  --location eastus2 \
  --size Standard_D8s_v3 \
  --all \
  --query "[?name=='Standard_D8s_v3'].{Name:name, Tier:tier, Restrictions:restrictions}" \
  -o table
```

The output must show no `NotAvailableForSubscription` restrictions. If the SKU
is restricted, choose an equivalent SKU in the same or adjacent region:

| Alternative SKU | vCPU | RAM | Premium SSD |
|---|---|---|---|
| `Standard_D8s_v4` | 8 | 32 GB | Yes |
| `Standard_D8s_v5` | 8 | 32 GB | Yes |
| `Standard_D8as_v4` | 8 | 32 GB | Yes |
| `Standard_D8as_v5` | 8 | 32 GB | Yes |

Any replacement must support Premium Storage (the `s` suffix in DSv3/DSv4/DSv5).

---

## 3. DNS prerequisites

A public Azure DNS zone for `ocp.labX.arunkube.org` must exist and NS
delegation must be complete before running `openshift-install`.

See [docs/dns.md](dns.md) for the full DNS setup procedure.

Quick check:

```bash
# After terraform apply and NS delegation:
dig NS ocp.lab1.arunkube.org +short
# Should return the four Azure DNS name servers
```

---

## 4. Red Hat pull secret

1. Go to https://console.redhat.com/openshift/install/pull-secret
2. Log in with your Red Hat account (free Developer Subscription is sufficient)
3. Click **Copy pull secret**
4. Export it as an environment variable:

```bash
export PULL_SECRET='{"auths": ...}'
```

Do not paste the pull secret into any file that might be committed.
The `02-create-install-config.sh` script reads it from `$PULL_SECRET`.

---

## 5. SSH key

The installer embeds the SSH public key into the RHCOS node for post-install
troubleshooting access.

```bash
# Generate a new key (if needed)
ssh-keygen -t ed25519 -C "ocp-sno-azure" -f ~/.ssh/id_ed25519_ocp

# Or use an existing key
export SSH_PUBLIC_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
```

The private key is never committed. The public key is embedded in
`install-config.yaml` (which is also never committed).

---

## 6. Checklist

```
[ ] az CLI installed and authenticated
[ ] Correct subscription selected
[ ] Service principal created with Contributor + User Access Administrator
[ ] Standard DSv3 vCPU quota ≥ 16 in target region
[ ] Standard_D8s_v3 available in target region (no restrictions)
[ ] Terraform installed (≥ 1.6)
[ ] openshift-install 4.22.x installed
[ ] oc 4.22.x installed
[ ] jq installed
[ ] DNS zone created (Terraform) and NS delegation verified
[ ] Pull secret exported as $PULL_SECRET
[ ] SSH public key path set as $SSH_PUBLIC_KEY_PATH
```
