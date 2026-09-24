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
ERPNext SSOs through the homelab Authelia provider (`auth.pushprh.com`, psx-homelab): Frappe's `Social Login Key` `authelia` (generic OIDC client, `sign_ups: Allow` — `pku_users` members are auto-created; desk access requires a System User). The `hpushpreet@gmail.com` → `hanspal.pushpreet@gmail.com` owner account is the password-login fallback if Authelia is down. No forward_auth, no per-app Caddy auth config, no cross-repo config merge.

## Prerequisites (psx-homelab provides)

pkunited's `just deploy` assumes the following are already provisioned by psx-homelab:

| Item | Where | Notes |
|------|-------|-------|
| Business VM | `10.37.20.70` | Debian 13 (trixie), 4 vCPU, 8 GB, 40 GB |
| SSH access | `root@10.37.20.70` via `secrets/pkunited_deploy_ed25519` | on the psx-homelab control Pi this is a link to the controller deploy key (already root on business); the legacy pkunited key in `authorized_keys_extra` is removed at psx-homelab's revocation gate |
| Host key | `ansible/known_hosts` in psx-homelab | ssh runs with `StrictHostKeyChecking=yes`; the deployer must already know the business VM's host key |
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
| ERPNext | internal (8080) | erp.pushprh.com | SSO via Authelia OIDC + password fallback |

## Secrets

All secrets encrypted with SOPS+age in `secrets/*.env.sops`.
Age recipients (`.sops.yaml`):

| Recipient | Private key |
|---|---|
| `age1hxykteqgs6peh6ed0eupjaczf40jgtqqmjjy94judv55nk49vg6scv0jkq` | psx-homelab control Pi, `/home/ops/credentials/pkunited-age.key` |
| `age1u0s2l03elzefw0czwuden8ptmwjn9ug7uhu6cxj9c5lkpvdtc5zsafjwmu` | laptop break-glass, `~/.ssh/homelab-breakglass/pkunited-age.key` |
| `age1kreq3nnm96m4vuh2gkh2pchgc4j5ygv9vgxwt99y4d304873df9s2jxak5` | legacy (dev VM); removed at psx-homelab's revocation gate, then `sops rotate` |

These keys are pkunited-only: they are not psx-homelab's recipients, and pkunited secrets must
not rely on the homelab age key. Keep an offline copy outside the homelab. Vaultwarden runs on
the homelab, so it can't be the only copy. Keep them out of psx-homelab's restic backup set.

| Secret | File | Used By |
|--------|------|--------|
| n8n DB credentials | `secrets/n8n.env.sops` | n8n container |
| n8n encryption key | `secrets/n8n.env.sops` | n8n container |
| n8n JWT secret | `secrets/n8n.env.sops` | n8n container |
| LiteLLM key | `secrets/n8n.env.sops` | n8n → LiteLLM |
| ERPNext DB password | `secrets/erpnext.env.sops` | ERPNext MariaDB |
| ERPNext admin password | `secrets/erpnext.env.sops` | ERPNext site creation |
| ERPNext OIDC client secret | `secrets/erpnext.env.sops` | ERPNext Social Login Key (plaintext; digest lives in psx-homelab) |

## Environment Variables

pkunited's justfile reads:

| Var | Default | Notes |
|-----|---------|-------|
| `BUSINESS_SSH` | `root@10.37.20.70` | SSH target for business VM |
| `BUSINESS_KEY` | `secrets/pkunited_deploy_ed25519` | Path to pkunited deploy key (gitignored) |
| `SOPS_AGE_KEY_FILE` | `secrets/age.key` | Path to age key for secret decryption |

## Deploying from the control Pi

Deployments run on psx-homelab's control Pi, at a commit GitHub has (push first):

```bash
# from a psx-homelab checkout with pkunited next to it (../pkunited)
scripts/ctl.sh --repo pkunited deploy-stack n8n
```

`pi-run` checks out a clean worktree and links in `secrets/age.key` and the deploy key.
Break-glass from the laptop: `SOPS_AGE_KEY_FILE=~/.ssh/homelab-breakglass/pkunited-age.key
BUSINESS_KEY=~/.ssh/homelab-breakglass/deploy_ed25519 just deploy-stack n8n`. Files are
synced as 1000:1000 with modes 644/755, and `.env` as 0600, so every controller leaves
identical files.
