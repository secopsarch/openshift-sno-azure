# archives/

Local lab-run history for this repository. **Never commit or push run artifacts.**

## Purpose

Every create/destroy cycle produces installer files under `openshift/` (and nested
`openshift/openshift/`), including:

- `.openshift_install_state.json`
- `.openshift_install.log`
- `metadata.json`
- `terraform.platform.auto.tfvars.json`
- `terraform.tfvars.json`
- `auth/`, `tls/`, `.clusterapi_output/`, manifests

These are archived here so you can see **how many times** the lab was
reproduced and inspect prior run state — without polluting git history.

## Layout

```
archives/
├── README.md          ← this file (committed)
├── INDEX.json         ← run counter + summaries (gitignored)
└── runs/
    └── YYYYMMDD-HHMMSS-<status>/
        ├── MANIFEST.json
        ├── install-config.yaml.bak   (secrets redacted where possible)
        ├── .openshift_install.log
        ├── metadata.json
        ├── terraform.platform.auto.tfvars.json
        └── ... (other installer artifacts)
```

## Commands

```bash
# Archive current openshift/ artifacts after a create or failed attempt
./scripts/06-archive-run.sh

# Archive and mark status explicitly
./scripts/06-archive-run.sh --status failed
./scripts/06-archive-run.sh --status success

# Also upload archive tarball to existing Azure storage (cheap, no new account)
./scripts/06-archive-run.sh --status failed --upload
```

## Remote storage (cost-saving)

Uses the **existing** Cloud Shell storage account (no new SKU / no new RG):

| Setting | Value |
|---|---|
| Storage account | `cs110032003f4f3399f` |
| Resource group | `cloud-shell-storage-southeastasia` |
| Container | `ocp-sno-lab` |
| Blob prefix | `archives/` (run tarballs) |
| Terraform state key | `terraform/openshift-sno-azure.tfstate` |

Terraform remote state is optional. See `terraform/backend.hcl.example`.

## Rules

1. Never `git add archives/runs/`
2. Never commit `terraform.platform.auto.tfvars.json` or any `openshift/*.tfvars.json`
3. Before wiping `openshift/` in cleanup, always run `06-archive-run.sh`
4. Secrets in archives stay local / private blob — treat as sensitive
