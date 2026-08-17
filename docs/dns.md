# DNS Setup

OpenShift IPI on Azure requires a public DNS zone that is reachable from the
internet before `openshift-install create cluster` is run. The installer creates
A records in this zone during installation.

---

## DNS record requirements

| FQDN | Record type | Resolves to | Created by |
|---|---|---|---|
| `api.sno.ocplab1.arunkube.org` | A | API load balancer public IP | `openshift-install` |
| `*.apps.sno.ocplab1.arunkube.org` | A (wildcard) | Ingress load balancer public IP | `openshift-install` |

You do **not** create these records manually. The installer creates them
automatically in the Azure DNS zone, provided:
1. The zone exists before installation starts
2. The installer service principal has Contributor access to the zone's resource group
3. NS delegation is correct (external DNS resolves the zone)

---

## This project's DNS structure

```
arunkube.org                  ← root domain (at Cloudflare)
  └── ocplabX.arunkube.org   ← TERRAFORM creates this Azure DNS zone
                                 Cloudflare delegates NS directly to Azure DNS
        └── sno.ocplabX.arunkube.org ← cluster subdomain (name = cluster metadata.name)
              ├── api.sno...   ← installer creates this A record
              └── *.apps.sno... ← installer creates this wildcard A record
```

Replace `labX` with your lab number (e.g. `lab1`, `lab2`).  
This project uses `ocplab1.arunkube.org` as the concrete example.

---

## Step 1: Terraform creates the Azure DNS zone

`terraform apply` in `terraform/` creates:

1. Resource group `sno-dns-rg` in `eastus2`
2. Azure public DNS zone `ocplab1.arunkube.org`

After apply, Terraform outputs the four name servers Azure assigns to the zone:

```
dns_name_servers = [
  "ns1-01.azure-dns.com.",
  "ns2-01.azure-dns.net.",
  "ns3-01.azure-dns.org.",
  "ns4-01.azure-dns.info.",
]
```

The actual name servers are assigned by Azure and will differ from these
examples. Use the actual Terraform output values.

---

## Step 2: Add NS delegation records

Add four NS records in the **parent zone** (`arunkube.org`) pointing to
the Azure DNS name servers from the Terraform output.

### If `arunkube.org` is at Cloudflare (this project's setup)

In the Cloudflare dashboard for `arunkube.org`, add four NS records:

```
Type: NS
Name: ocplab1          (subdomain only — Cloudflare fills in .arunkube.org)
Value: ns1-05.azure-dns.com.
TTL: Auto

(repeat for all four Azure nameservers from terraform output)
```

### If `arunkube.org` is itself in Azure DNS

```bash
# Get the Azure DNS zone name servers
NS_SERVERS=$(terraform -chdir=terraform/ output -json dns_name_servers | jq -r '.[]')

# Add NS records to the parent zone
RG="<resource group containing arunkube.org>"
PARENT_ZONE="arunkube.org"
SUBDOMAIN="ocplab1"

for ns in $NS_SERVERS; do
  az network dns record-set ns add-record \
    --resource-group "$RG" \
    --zone-name "$PARENT_ZONE" \
    --record-set-name "$SUBDOMAIN" \
    --nsdname "$ns"
done
```

---

## Step 3: Verify DNS propagation

Wait for NS records to propagate (usually 5–30 minutes for Azure DNS,
up to 48 hours for some registrars).

```bash
# Check NS records resolve correctly
dig NS ocplab1.arunkube.org +short

# Expected: the four Azure DNS name servers
# If empty or wrong, NS delegation is not complete — do NOT proceed with install

# Verify the zone is authoritative (no error response)
dig SOA ocplab1.arunkube.org

# Cross-check from an external DNS resolver
dig @8.8.8.8 NS ocplab1.arunkube.org +short
```

The installer will fail if NS delegation is not working before `create cluster` runs.

---

## Step 4: After installation — verify records

After `openshift-install create cluster` completes, the installer creates the
A records automatically. Verify them:

```bash
CLUSTER_NAME="sno"
BASE_DOMAIN="ocplab1.arunkube.org"

# API record
dig A "api.${CLUSTER_NAME}.${BASE_DOMAIN}" +short
# Should return the API load balancer public IP

# Apps wildcard (test with console subdomain)
dig A "console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}" +short
# Should return the ingress load balancer public IP
```

---

## Public vs private DNS

This project uses **public DNS** (`publish: External`, the default).

API endpoint (`api.*`) and application routes (`*.apps.*`) are reachable from
the internet. This is appropriate for a lab environment where you access the
cluster from outside Azure.

**Private DNS alternative** (`publish: Internal`): API and apps endpoints would
only be reachable from within the Azure VNet (e.g. from a bastion host). This
requires additional network setup and is not covered in Phase 1.

---

## `userProvisionedDNS` option

By default (`userProvisionedDNS: Disabled`), the installer creates the A records
automatically. This is what Phase 1 uses.

If you set `userProvisionedDNS: Enabled` in `install-config.yaml`, you must
create the A records yourself after the installer provisions the load balancers
(a two-step process). This is not needed for Phase 1.

---

## Troubleshooting DNS

**Symptom:** Installer fails with DNS resolution errors during install.

```bash
# Check if NS delegation is correct
dig NS ocplab1.arunkube.org @8.8.8.8

# Check if the zone exists in Azure
az network dns zone show \
  --resource-group sno-dns-rg \
  --name ocplab1.arunkube.org

# Check service principal has access to the DNS RG
az role assignment list \
  --assignee "<service-principal-app-id>" \
  --scope "/subscriptions/<sub>/resourceGroups/sno-dns-rg" \
  --output table
```

**Symptom:** Console not reachable after install, but API works.

The `*.apps.*` A record may not have propagated yet. Check:

```bash
dig A "console-openshift-console.apps.sno.ocplab1.arunkube.org" +short
```

If the record is missing, check that the installer completed successfully
(`oc get clusteroperators ingress`).
