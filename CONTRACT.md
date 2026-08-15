# pkunited — Business Services Deployment Contract

## Architecture

All business services run on a single VM (`10.37.20.70`) provisioned by psx-homelab.
pkunited deploys all runtime components: Caddy (entry point), n8n, and ERPNext.

```
Internet → Cloudflare Tunnel → Edge Caddy (core-infra) → Business Caddy (10.37.20.70:9443)
  └─ n8n.pushprh.com        ──→ n8n:5678
                              (except /webhook/* — no auth)
  └─ erp.pushprh.com         ──→ erpnext-frontend:8080
```

n8n handles its own authentication via User Management mode.
ERPNext handles its own authentication via the Administrator account.
No OIDC clients, no per-app auth config, no cross-repo config merge.

## Prerequisites (psx-homelab provides)

pkunited's `just deploy` assumes the following are already provisioned by psx-homelab:

| Item | Where | Notes |
|------|-------|-------|
| Business VM | `10.37.20.70` | Debian 13 (trixie), 4 vCPU, 8 GB, 40 GB |
| SSH access | `root@10.37.20.70` via `pkunited_deploy_ed25519` | deploy key in `secrets/`, pubkey provisioned by psx-homelab `base` role |
| Docker daemon | Installed on business VM | via psx-homelab `docker` role |
| `businessnet` Docker network | `docker network create businessnet` | External network referenced by all stacks |
| `/opt/stacks/` | Directory on business VM | Compose files deployed here |
| `/opt/appdata/` | Directory on business VM | Service state; subdirs pre-created by base role |
| Appdata dirs | Listed in `ansible/group_vars/business.yml` → `appdata_owned_dirs` | Pre-created with correct UID/GID |
| Edge Caddy routes | psx-homelab `stacks/caddy/Caddyfile` | Reverse-proxies business hostnames to `10.37.20.70:9443` |
| Cloudflare Tunnel | psx-homelab `stacks/cloudflared/config.yml` | Routes `n8n.pushprh.com` and `erp.pushprh.com` to edge Caddy |

## Published by pkunited

| Service | Network Port | Route | Auth |
|---------|-------------|-------|------|
| Business Caddy | `10.37.20.70:9443` | all | — |
| n8n | internal | n8n.pushprh.com | n8n User Management |
| ERPNext | internal (8080) | erp.pushprh.com | ERPNext built-in auth |

## Secrets

All secrets encrypted with SOPS+age in `secrets/*.env.sops`.
Age public key: `age1muhxctlmyhf8lk2qm48z2hur5t4tjfjdz0xn4372nekwspghkgfsfwx9g6`

| Secret | File | Used By |
|--------|------|--------|
| n8n DB credentials | `secrets/n8n.env.sops` | n8n container |
| n8n encryption key | `secrets/n8n.env.sops` | n8n container |
| n8n JWT secret | `secrets/n8n.env.sops` | n8n container |
| LiteLLM key | `secrets/n8n.env.sops` | n8n → LiteLLM |
| ERPNext DB password | `secrets/erpnext.env.sops` | ERPNext MariaDB |
| ERPNext admin password | `secrets/erpnext.env.sops` | ERPNext site creation |

## Environment Variables

pkunited's justfile reads:

| Var | Default | Notes |
|-----|---------|-------|
| `BUSINESS_SSH` | `root@10.37.20.70` | SSH target for business VM |
| `BUSINESS_KEY` | `secrets/pkunited_deploy_ed25519` | Path to pkunited deploy key (gitignored) |
| `SOPS_AGE_KEY_FILE` | `secrets/age.key` | Path to age key for secret decryption |
