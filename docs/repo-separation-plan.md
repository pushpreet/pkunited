# Repo Separation: pkunited ↔ psx-homelab — Implementation Plan

**Owner:** pi coding agent (executed in discrete sessions)
**Date:** 2025-01-XX
**Status:** Phase 0 complete (2026-08-14). Remaining phases: 1, 2, 3, 4, 5, 6, 8, 9

---

## Target State

After this plan executes, the two repos have clean ownership boundaries:

| Concern | Owner | Notes |
|---------|-------|-------|
| Proxmox VM, VLAN, IP, base OS, Docker | psx-homelab | `ansible/group_vars/business.yml`, `ansible/inventory.yml`, `base` + `docker` roles |
| Edge Caddy, Cloudflare Tunnel, central monitoring | psx-homelab | Core-infra host; edge Caddy proxies business hostnames to business VM |
| Business Caddy, Authelia, app stacks | pkunited | Own Caddy (forward_auth → Authelia) + own Authelia (reads LLDAP on core-infra) on business VM |
| Business Compose stacks & app code | pkunited | `stacks/{caddy,authelia,inventree,akaunting,n8n}/` |
| Business application secrets | pkunited | `secrets/{inventree,akaunting,n8n,authelia}.env.sops` |
| Business deployment (`just deploy`) | pkunited | Own `justfile`, `scripts/` — rsyncs to business VM only, no core-infra touch |
| Backup agent (restic → Azure) | psx-homelab | Generic host backup; `backup` role applied to business group |
| Application-consistent DB dumps | pkunited | `just backup-dumps` runs pg_dump/mysqldump inside containers |
| LiteLLM API key for n8n | psx-homelab (seko-ai) | Operator adds `LITELLM_N8N_KEY` to `pkunited/secrets/n8n.env.sops` from seko-ai UI |
| LLDAP directory (auth source of truth) | psx-homelab | Business Authelia reads from it over LDAP/TCP; no config merge needed |

### Integration Contracts (minimal, explicit)

1. **SSH contract:** pkunited connects to `root@10.37.20.70` (business VM) only. No core-infra SSH.
2. **Network:** psx-homelab creates `businessnet` Docker network on business VM before pkunited deploys
3. **Appdata ownership:** psx-homelab `base` role pre-creates `/opt/appdata/<svc>/` dirs with correct UID/GID
4. **Published ports:** Business Caddy binds `10.37.20.70:9443` (HTTPS). App services are internal-only (no host ports).
5. **Edge Caddy proxy:** psx-homelab edge Caddy reverse-proxies `inventree/accounts/n8n.pushprh.com` → `10.37.20.70:9443`
6. **Cloudflare Tunnel:** psx-homelab cloudflared sends business hostnames to edge Caddy (existing pattern)
7. **LLDAP access:** Business Authelia reads `ldap://core-infra:3890` (or `ldap://10.37.20.10:3890`) — read-only TCP, no config exchange
8. **Backup location:** restic → Azure (same repo as core/media); retention from `backup_keep`

---

## Prerequisites

- `just` installed on control machine
- `sops` + age key available (`pkunited/secrets/age.key` or `SOPS_AGE_KEY_FILE` env)
- `ansible` installed (`ansible-core` ≥ 2.14)
- SSH deploy key (`psx-homelab/host/keys/deploy_ed25519`) accessible from control machine
- pkunited and psx-homelab as sibling repos at `~/Projects/pkunited` and `~/Projects/psx-homelab`
- Age public key for pkunited SOPS: `age1muhxctlmyhf8lk2qm48z2hur5t4tjfjdz0xn4372nekwspghkgfsfwx9g6`

---

## Phase 0 ✅: CONTRACT.md & Project Documentation

**Goal:** Define the interface between repos before any code is written.

### TODO 0.1 ✅ — Create `CONTRACT.md` in pkunited

Create `pkunited/CONTRACT.md`:

```markdown
# pkunited — Business Services Deployment Contract

## Architecture

All business services run on a single VM (`10.37.20.70`) provisioned by psx-homelab.
pkunited deploys all runtime components: Caddy (entry point + auth), Authelia (SSO),
and the three apps (InvenTree, Akaunting, n8n).

```
Internet → Cloudflare Tunnel → Edge Caddy (core-infra) → Business Caddy (10.37.20.70:9443)
  ├─ inventree.pushprh.com  ──→ forward_auth → Authelia → inventree:8000
  ├─ accounts.pushprh.com   ──→ forward_auth → Authelia → akaunting:80
  └─ n8n.pushprh.com        ──→ forward_auth → Authelia → n8n:5678
```

All auth is handled by Caddy `forward_auth` to the local Authelia instance.
No OIDC clients, no per-app auth config, no cross-repo config merge.

## Prerequisites (psx-homelab provides)

pkunited's `just deploy` assumes the following are already provisioned by psx-homelab:

| Item | Where | Notes |
|------|-------|-------|
| Business VM | `10.37.20.70` | Debian 13 (trixie), 4 vCPU, 8 GB, 40 GB |
| SSH access | `root@10.37.20.70` via `deploy_ed25519` | cloud-init deploy key |
| Docker daemon | Installed on business VM | via psx-homelab `docker` role |
| `businessnet` Docker network | `docker network create businessnet` | External network referenced by all stacks |
| `/opt/stacks/` | Directory on business VM | Compose files deployed here |
| `/opt/appdata/` | Directory on business VM | Service state; subdirs pre-created by base role |
| Appdata dirs | Listed in `ansible/group_vars/business.yml` → `appdata_owned_dirs` | Pre-created with correct UID/GID |
| Edge Caddy routes | psx-homelab `stacks/caddy/Caddyfile` | Reverse-proxies business hostnames to `10.37.20.70:9443` |
| Cloudflare Tunnel | psx-homelab `stacks/cloudflared/config.yml` | Routes business hostnames to edge Caddy |

## Published by pkunited

| Service | Network Port | Route | Auth |
|---------|-------------|-------|------|
| Business Caddy | `10.37.20.70:9443` | all | `forward_auth` → Authelia |
| InvenTree | internal | inventree.pushprh.com | via Caddy forward_auth |
| Akaunting | internal | accounts.pushprh.com | via Caddy forward_auth |
| n8n | internal | n8n.pushprh.com | via Caddy forward_auth |
| Authelia | internal | — | reads LLDAP on `10.37.20.10:3890` |

## Secrets

All secrets encrypted with SOPS+age in `secrets/*.env.sops`.
Age public key: `age1muhxctlmyhf8lk2qm48z2hur5t4tjfjdz0xn4372nekwspghkgfsfwx9g6`

| Secret | File | Used By |
|--------|------|--------|
| DB passwords/keys | `secrets/{inventree,akaunting,n8n}.env.sops` | App containers |
| Authelia session secret | `secrets/authelia.env.sops` | Authelia container |
| Authelia LDAP password | `secrets/authelia.env.sops` | Authelia → LLDAP bind |
| n8n encryption key | `secrets/n8n.env.sops` | n8n container |
| LiteLLM key | `secrets/n8n.env.sops` | n8n → LiteLLM |

No OIDC clients. No secret digests. No cross-repo secret sync.

## Environment Variables

pkunited's justfile reads:

| Var | Default | Notes |
|-----|---------|-------|
| `BUSINESS_SSH` | `root@10.37.20.70` | SSH target for business VM |
| `BUSINESS_KEY` | `../psx-homelab/host/keys/deploy_ed25519` | Path to deploy key (relative to pkunited) |
| `SOPS_AGE_KEY_FILE` | `secrets/age.key` | Path to age key for secret decryption |
```

### TODO 0.2 ✅ — Update `AGENTS.md` with separation context

Replace the deployment section in `pkunited/AGENTS.md` with:

```markdown
## Deployment

pkunited owns its own deployment pipeline. The business VM (`10.37.20.70`) is provisioned
by `psx-homelab` (Ansible base + docker roles), then pkunited deploys all stacks into it:
Caddy (entry point + auth), Authelia (SSO), and the three apps.

Run `just` in pkunited to see available recipes. Key commands:
- `just validate` — render secrets, validate all compose files
- `just deploy` — full deploy (secrets → stacks on business VM)
- `just deploy-stack <svc>` — deploy single stack
- `just stack-logs <svc>` — tail logs
- `just stack-down <svc>` — stop a stack
- `just secrets` — render SOPS → .env
- `just sops-edit <svc>` — edit encrypted secret
- `just backup-dumps` — application-consistent DB dumps

No core-infra SSH. No config fragments. No OIDC client management.
See `CONTRACT.md` for the interface with psx-homelab.
```

### TODO 0.3 ✅ — Consolidate docs: merge `plan.md` + `integration-design.md` into `README.md`, rename `auth-plan.md` → `auth-runbook.md`

The three docs overlap heavily (architecture diagrams, component descriptions, open questions,
deployment instructions). Consolidate into two:

**Target state:**
| File | Content |
|------|--------|
| `README.md` (new) | What this repo is, architecture, component descriptions, key decisions, day-to-day ops, open questions |
| `auth-runbook.md` (renamed from auth-plan.md) | Auth architecture, LLDAP users, per-service SSO setup, post-deploy steps |
| `CONTRACT.md` (new, TODO 0.1) | Interface with psx-homelab |
| `repo-separation-plan.md` (delete after all phases complete) | Implementation playbook |

**Delete after consolidation:**
- `docs/plan.md` — content absorbed into README.md
- `docs/integration-design.md` — compose examples are live in `stacks/` already; stale Ansible/Caddy sections replaced by CONTRACT.md + this plan

**Create `README.md` with these sections (pull from plan.md + integration-design.md, update for new model):**

```  
# pkunited — Business Services

## Goal
(from plan.md — self-host InvenTree + Akaunting + n8n for hardware resale business)

## Architecture

All services run on a single business VM (`10.37.20.70`) provisioned by psx-homelab.
pkunited deploys everything on that VM: Caddy (entry point + auth), Authelia (SSO), and apps.

```
Internet → Cloudflare → Edge Caddy (core-infra) → Business Caddy (10.37.20.70:9443)
  ├─ inventree.pushprh.com  ──→ forward_auth → Authelia → inventree:8000
  ├─ accounts.pushprh.com   ──→ forward_auth → Authelia → akaunting:80
  └─ n8n.pushprh.com        ──→ forward_auth → Authelia → n8n:5678
```

Authelia reads LLDAP on core-infra (`10.37.20.10:3890`) for user/group lookup.

## Services
| Service | Image | Network Port | Route | DB |
|---------|-------|-------------|-------|-----|
| Caddy | caddy:alpine | `10.37.20.70:9443` | all | — |
| Authelia | authelia/authelia:4.39.20 | internal | — | SQLite |
| InvenTree | inventree/inventree:1.4.3 | internal | inventree.pushprh.com | PostgreSQL 17 |
| Akaunting | akaunting/akaunting:3.1.31 | internal | accounts.pushprh.com | MariaDB 11.3 |
| n8n | docker.n8n.io/n8n/n8n:1.101.2 | internal | n8n.pushprh.com | PostgreSQL 17 |

### InvenTree
(description from plan.md, updated with actual image tag and key capabilities)

### Akaunting
(description from plan.md)

### n8n
(description from plan.md, including LiteLLM integration)

## Authentication

All services use Caddy `forward_auth` to a local Authelia instance.
Authelia reads LLDAP on core-infra for user/group lookup. No OIDC clients.
No per-app auth config. No middleware. No bolt-ons.

See `docs/auth-runbook.md` for setup details and LLDAP user table.

## Deployment
pkunited owns its own deployment pipeline. The business VM (`10.37.20.70`) is provisioned
by `psx-homelab` (Ansible base + docker roles), then pkunited deploys all stacks into it.

Run `just` to see available recipes. Key commands:
- `just validate` — render secrets, validate all compose files
- `just deploy` — full deploy (secrets → stacks on business VM)
- `just deploy-stack <svc>` — deploy single stack
- `just stack-logs <svc>` — tail logs
- `just stack-down <svc>` — stop a stack
- `just sops-edit <svc>` — edit encrypted secret
- `just backup-dumps` — application-consistent DB dumps

See `CONTRACT.md` for the interface with psx-homelab.

## Day-to-Day Operations
(from plan.md, updated with pkunited commands)

| Action | Command |
|--------|--------|
| Deploy all stacks | `just deploy` |
| Deploy single stack | `just deploy-stack <svc>` |
| Tail logs | `just stack-logs <svc>` |
| Stop a stack | `just stack-down <svc>` |
| Purge a stack (keep data) | `just stack-purge <svc>` |
| Edit secrets | `just sops-edit <svc>` |
| DB backup dumps | `just backup-dumps` |
| SSH into business VM | `just ssh` |

## Key Decisions & Rationale
(from plan.md)

## Open Questions
(from plan.md + integration-design.md, deduplicated)

## Data Migration
(from plan.md — Grist export/import into InvenTree/Akaunting)

## Future Work
(from plan.md — MCP servers, n8n workflows)
```

**Rename `docs/auth-plan.md` → `docs/auth-runbook.md`:**
```
git mv docs/auth-plan.md docs/auth-runbook.md
```
Then update internal references:
- Title: "Business Services Authentication Runbook"
- Rewrite to reflect Caddy forward_auth model (no OIDC, no middleware, no bolt-ons)
- Auth architecture: Caddy forward_auth → local Authelia → LLDAP on core-infra
- Per-service section: just document the forward_auth config in business Caddyfile
- Remove: all OIDC client sections, n8n-oidc hooks, Akaunting middleware
- LLDAP user table stays (still the auth source of truth)
- Add: Authelia config for the business VM (reads LLDAP on `10.37.20.10:3890`)

**Delete old files (after README.md is created and reviewed):**
```
rm docs/plan.md docs/integration-design.md
```

---

## Phase 0b ✅: Clean Up psx-homelab Artifacts

**Goal:** Remove stale cross-repo references in psx-homelab so it matches the new model.
Nothing is in production, so this is safe — no running services depend on these files.

### TODO 0b.1 ✅ — Delete `docs/repository-boundaries.md`

This is the pre-separation analysis doc that described the old model. The separation is now
implemented and documented in pkunited's `CONTRACT.md`. Replace with a one-paragraph pointer:

```markdown
# Repository boundaries

psx-homelab provisions the business VM (Proxmox, base OS, Docker). All business services
(Caddy, Authelia, InvenTree, Akaunting, n8n) are owned and deployed by the `pkunited` repo.

See `pkunited/CONTRACT.md` for the interface between repos.
```

### TODO 0b.2 ✅ — Remove business VM entry from `host/provision-vms.sh` IF the VM is already provisioned

Check if the business VM exists on Proxmox. If it does (ID 910), leave the entry — `provision-vms.sh`
is idempotent and the entry is needed for reference. If the VM does not exist yet, the entry
stays so `just` can provision it later. **No change needed** — the entry is correct for the new
model (psx-homelab still provisions the VM).

### TODO 0b.3 ✅ — Verify no stale business stacks in `stacks/`

Confirm no `stacks/inventree/`, `stacks/akaunting/`, `stacks/n8n/` exist in psx-homelab:

```bash
# Should return nothing:
ls stacks/ | grep -iE '^(inventree|akaunting|n8n|business)$'
```

If any exist (from an earlier partial deploy), remove them:

```bash
rm -rf stacks/inventree stacks/akaunting stacks/n8n stacks/business
```

### TODO 0b.4 ✅ — Verify no stale business secrets in `secrets/`

Confirm no business-specific secrets exist in psx-homelab:

```bash
# Should return nothing:
ls secrets/ | grep -iE '^(inventree|akaunting|n8n|business)'
```

If any exist (from an earlier experiment), remove them:

```bash
rm -f secrets/inventree.env.sops secrets/akaunting.env.sops secrets/n8n.env.sops
```

### TODO 0b.5 ✅ — Verify no `PKUNITED_REPO` references

```bash
# Should return nothing:
grep -rn 'PKUNITED_REPO\|pkunited.*stacks\|business.*fragment' . --include='*.yml' --include='*.yaml' --include='*.sh' --include='justfile' | grep -v '.git/'
```

The old model had a `PKUNITED_REPO` env var that pointed to the pkunited checkout for
cross-repo rsync. This is no longer needed — pkunited deploys itself.

### TODO 0b.6 ✅ — Ensure `ansible/group_vars/nas.yml` "business" share is untouched

The `business` entry in `ansible/group_vars/nas.yml` (line 136) is a **NAS SMB share**
for business file storage — it is NOT related to the business VM services. **Do not remove it.**

Similarly, `docs/encrypted-shares-runbook.md` references `\\nas\business` as an encrypted
SMB share. **Do not remove it.**

### TODO 0b.7 ✅ — Add business VM to `ansible/inventory.yml` (if not already done in Phase 2)

Phase 2 (TODO 2.1) adds the business group. This TODO is a reminder that it belongs here
(psx-homelab) even though it enables pkunited's deployment. The Ansible group is the
bridge: psx-homelab declares the host exists, pkunited deploys into it.

## Phase 1: pkunited — Justfile & Secret Rendering

**Goal:** pkunited can render its own secrets and validate compose files locally.

### TODO 1.1 — Create `pkunited/justfile`

```justfile
# pkunited — Business services deployment. Run `just` to list recipes.
# Requires: just, sops (+ age key for secrets), ssh.

set shell := ["bash", "-cu"]

export SOPS_AGE_KEY_FILE := env_var_or_default("SOPS_AGE_KEY_FILE", "secrets/age.key")

# SSH target: business VM only (no core-infra)
business := env_var_or_default("BUSINESS_SSH", "root@10.37.20.70")
deploy_key := env_var_or_default("BUSINESS_KEY", "../psx-homelab/host/keys/deploy_ed25519")

# Where compose stacks are deployed on the business VM
stacks_root := "/opt/stacks"

# All deployable stacks (infra + apps)
all_stacks := ["caddy", "authelia", "inventree", "akaunting", "n8n"]

# List recipes
default:
    @just --list

# --- Secrets ---

# Decrypt all secrets into each stack's .env
secrets:
    @scripts/render-env.sh

# Edit an encrypted secret file in place (e.g. just sops-edit inventree)
sops-edit service:
    sops --input-type dotenv --output-type dotenv secrets/{{service}}.env.sops

# Encrypt a plaintext dotenv into secrets/<service>.env.sops
sops-new service src:
    #!/usr/bin/env bash
    set -euo pipefail
    test -f "{{src}}" || { echo "no such file: {{src}}" >&2; exit 1; }
    test -e "secrets/{{service}}.env.sops" && { echo "secrets/{{service}}.env.sops already exists — use 'just sops-edit {{service}}'" >&2; exit 1; }
    sops --input-type dotenv --output-type dotenv \
         --filename-override "secrets/{{service}}.env.sops" \
         -e "{{src}}" > "secrets/{{service}}.env.sops"
    echo "wrote secrets/{{service}}.env.sops — now shred the plaintext: shred -u {{src}}"

# --- Validation ---

# Render secrets, then validate every compose stack (no deploy)
validate: secrets
    #!/usr/bin/env bash
    set -euo pipefail
    for d in stacks/caddy/ stacks/authelia/ stacks/inventree/ stacks/akaunting/ stacks/n8n/; do
      echo "== validating ${d} =="
      (cd "${d}" && docker compose config -q)
    done
    echo "all stacks valid"

# --- Deployment ---

# Deploy a single stack to the business VM
deploy-stack +stack:
    @just secrets
    #!/usr/bin/env bash
    set -euo pipefail
    stack="{{stack}}"
    src="stacks/${stack}"
    [[ -d "${src}" ]] || { echo "no stack dir: ${src}" >&2; exit 1; }
    echo "==> syncing ${stack} to business VM"
    rsync -az --mkpath \
      -e "ssh -i {{deploy_key}} -o StrictHostKeyChecking=no" \
      "${src}/" "{{business}}:{{stacks_root}}/${stack}/"
    echo "==> deploying {{stack}}"
    ssh -i {{deploy_key}} -o StrictHostKeyChecking=no {{business}} \
      "cd {{stacks_root}}/${stack} && docker compose up -d --remove-orphans"
    echo "==> {{stack}} deployed"

# Deploy all stacks to the business VM
deploy: secrets
    #!/usr/bin/env bash
    set -euo pipefail
    stacks=(caddy authelia inventree akaunting n8n)
    echo "==> syncing stacks to business VM"
    for stack in "${stacks[@]}"; do
      src="stacks/${stack}"
      [[ -d "${src}" ]] || { echo "no stack dir: ${src}" >&2; exit 1; }
      echo "  syncing ${stack}..."
      rsync -az --mkpath \
        -e "ssh -i {{deploy_key}} -o StrictHostKeyChecking=no" \
        "${src}/" "{{business}}:{{stacks_root}}/${stack}/"
    done
    echo "==> deploying stacks on business VM"
    # Deploy infra first (caddy + authelia), then apps
    ssh -i {{deploy_key}} -o StrictHostKeyChecking=no {{business}} \
      'for stack in caddy authelia inventree akaunting n8n; do
        d="{{stacks_root}}/${stack}"
        [[ -d "$d" ]] || continue
        echo "  deploying ${stack}..."
        cd "$d" && docker compose up -d --remove-orphans
      done'
    echo "==> all done"

# Tail one stack's logs
stack-logs stack tail="200":
    ssh -i {{deploy_key}} -t -o StrictHostKeyChecking=no {{business}} \
      "cd {{stacks_root}}/{{stack}} && docker compose logs --tail {{tail}} -f"

# Stop one stack's containers (volumes preserved)
stack-down stack:
    ssh -i {{deploy_key}} -o StrictHostKeyChecking=no {{business}} \
      "cd {{stacks_root}}/{{stack}} && docker compose down"

# RETIRE a stack: stop it, drop volumes, remove stack dir
# Does NOT touch /opt/appdata/<stack>
stack-purge stack:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> purging stack '{{stack}}' on business VM"
    ssh -i {{deploy_key}} -o StrictHostKeyChecking=no {{business}} \
      "test -d {{stacks_root}}/{{stack}} && cd {{stacks_root}}/{{stack}} && docker compose down -v --remove-orphans || echo 'no stack dir'"
    ssh -i {{deploy_key}} -o StrictHostKeyChecking=no {{business}} \
      "rm -rf {{stacks_root}}/{{stack}}"
    echo "==> removed {{stacks_root}}/{{stack}} (appdata left intact)"

# Application-consistent DB dumps
backup-dumps:
    #!/usr/bin/env bash
    set -euo pipefail
    key="-i {{deploy_key}} -o StrictHostKeyChecking=no"
    ts="$(date +%Y%m%d-%H%M%S)"
    echo "==> dumping InvenTree (PostgreSQL)..."
    ssh -t ${key} {{business}} \
      "docker exec inventree-db pg_dump -U \$(grep INVENTREE_DB_USER .env | cut -d= -f2) \$(grep INVENTREE_DB_NAME .env | cut -d= -f2) > /opt/appdata/inventree/backups/inventree-${ts}.sql"
    echo "==> dumping Akaunting (MariaDB)..."
    ssh -t ${key} {{business}} \
      "docker exec akaunting-db mysqldump -u \$(grep DB_USERNAME .env | cut -d= -f2) -p\$(grep DB_PASSWORD .env | cut -d= -f2) \$(grep DB_NAME .env | cut -d= -f2) > /opt/appdata/akaunting/backups/akaunting-${ts}.sql"
    echo "==> dumping n8n (PostgreSQL)..."
    ssh -t ${key} {{business}} \
      "docker exec n8n-db pg_dump -U \$(grep N8N_DB_USER .env | cut -d= -f2) \$(grep N8N_DB_NAME .env | cut -d= -f2) > /opt/appdata/n8n/backups/n8n-${ts}.sql"
    echo "==> dumps complete (restic will pick them up)"

# SSH into the business VM
ssh:
    ssh -i {{deploy_key}} -t -o StrictHostKeyChecking=no {{business}}
```

### TODO 1.2 — Create `pkunited/scripts/render-env.sh`

Copy the pattern from `psx-homelab/scripts/render-env.sh` but simplified for pkunited:

```bash
#!/usr/bin/env bash
# Render encrypted secrets/<service>.env.sops -> stacks/<service>/.env for Compose.
# The .env files are gitignored. Requires `sops` + an age key.
#
#   SOPS_AGE_KEY_FILE=secrets/age.key scripts/render-env.sh
#
# Optional: pass service names to render only those (e.g. `render-env.sh inventree n8n`).
set -euo pipefail

cd "$(dirname "$0")/.."

shopt -s nullglob
targets=("$@")

render() {
  local sops_file="$1"
  local svc
  svc="$(basename "$sops_file" .env.sops)"
  local dest="stacks/${svc}"
  if [[ ! -d "$dest" ]]; then
    echo "skip ${svc}: no stack dir at ${dest}" >&2
    return 0
  fi
  sops -d --input-type dotenv --output-type dotenv "$sops_file" > "${dest}/.env"
  echo "rendered ${dest}/.env"
}

if [[ ${#targets[@]} -gt 0 ]]; then
  for svc in "${targets[@]}"; do
    f="secrets/${svc}.env.sops"
    [[ -f "$f" ]] && render "$f" || echo "no secret file for ${svc}" >&2
  done
else
  for f in secrets/*.env.sops; do
    render "$f"
  done
fi
```

### TODO 1.3 — Create `pkunited/.gitignore` additions

Ensure these patterns are excluded:

```
# Rendered secrets (gitignored, never committed)
stacks/*/.env
stacks/**/*.env

# Age key (sensitive)
secrets/age.key

# Node modules (if any tooling added later)
node_modules/

# Python venvs
.venv/
*.pyc
__pycache__/
```

---

## Phase 2: psx-homelab — Business Host Group

**Goal:** psx-homelab provisions the business VM with base OS, Docker, businessnet, and appdata dirs.

### TODO 2.1 — Add `business` group to `psx-homelab/ansible/inventory.yml`

Add after the `llm` group:

```yaml
    business:
      hosts:
        business-vm:
          ansible_host: 10.37.20.70
```

### TODO 2.2 — Create `psx-homelab/ansible/group_vars/business.yml`

```yaml
# Business VM (10.37.20.70): InvenTree, Akaunting, n8n.
# Provisioned by psx-homelab (base + docker). Deployed by pkunited (compose stacks).

docker_distro: debian
docker_apt_suite: "trixie"

# No host_stacks — pkunited owns the compose deployment.
# This variable is required by deploy_stacks.yml (defaults to empty).
host_stacks: []

# Appdata dirs pre-created with container ownership.
appdata_owned_dirs:
  - inventree
  - akaunting
  - n8n

# Custom ownership for DB containers that run as non-default uid/gid.
appdata_custom_owned_dirs:
  - { path: "inventree/postgres", owner: "70", group: "70" }
  - { path: "akaunting/mysql", owner: "999", group: "999" }
  - { path: "n8n/postgres", owner: "70", group: "70" }
  # InvenTree static/media/plugins (owned by container user, uid 1000)
  - { path: "inventree/static", owner: "1000", group: "1000" }
  - { path: "inventree/media", owner: "1000", group: "1000" }
  - { path: "inventree/plugins", owner: "1000", group: "1000" }
  - { path: "inventree/backups", owner: "1000", group: "1000" }

# Swap: 2 GB as OOM cushion. n8n can spike during workflow execution.
swap_file_mb: 2048
swap_swappiness: 10

# --- Backups (restic → Azure, shared repo with core/media) ---
backup_secret_file: "backup.env.sops"
backup_packages: [sqlite3]
backup_oncalendar: "*-*-* 02:30:00"
backup_paths:
  - /opt/appdata
backup_excludes:
  - "/opt/appdata/*/cache"
  - "/opt/appdata/*/log"
  - "**/*.log"
  # n8n project files are in /opt/appdata/n8n/ (backed up)
  # DB dumps from pkunited `just backup-dumps` are in /opt/appdata/<svc>/backups/ (backed up)
# App-consistent DB dumps (run by pkunited before backup).
backup_predump: []
```

### TODO 2.3 — Add business Docker network creation to `psx-homelab/ansible/roles/docker/tasks/main.yml`

Append after the "Enable and start Docker" task — but only for the business host:

```yaml
- name: "Create businessnet Docker network (business host only)"
  ansible.builtin.command:
    cmd: docker network create --driver bridge businessnet
  changed_when: false
  failed_when: false
  when: inventory_group_names is contained("business")
```

### TODO 2.4 — Add business play to `psx-homelab/ansible/site.yml`

Add after the LLM host play, before the backup play:

```yaml
- name: "Business host: base + Docker (no stacks — pkunited owns that)"
  hosts: business
  become: true
  roles:
    - base
    - docker
```

### TODO 2.5 — Add business to the backup play in `psx-homelab/ansible/site.yml`

Change:
```yaml
  hosts: core:media:nas:llm
```
To:
```yaml
  hosts: core:media:nas:llm:business
```

### TODO 2.6 — Validate psx-homelab changes

Run from psx-homelab:
```bash
just validate          # should pass — no business stacks to validate locally
just check            # ansible dry-run — should provision base + docker on business VM
```

---

## Phase 3: Edge Caddy — Proxy to Business VM

**Goal:** psx-homelab edge Caddy reverse-proxies business hostnames to the business VM's Caddy.

### TODO 3.1 — Add business routes to `psx-homelab/stacks/caddy/Caddyfile`

Add near the end of the Caddyfile, before any closing blocks:

```
# ---- Business VM (10.37.20.70) ----
# Edge Caddy proxies to business Caddy on :9443. Business Caddy handles auth (forward_auth → Authelia).
http://inventree.pushprh.com, https://inventree.pushprh.com {
	reverse_proxy 10.37.20.70:9443 {
		header_up X-Forwarded-Proto https
	}
}
http://accounts.pushprh.com, https://accounts.pushprh.com {
	reverse_proxy 10.37.20.70:9443 {
		header_up X-Forwarded-Proto https
	}
}
http://n8n.pushprh.com, https://n8n.pushprh.com {
	reverse_proxy 10.37.20.70:9443 {
		header_up X-Forwarded-Proto https
	}
}
```

**That's it.** No fragment merging, no Authelia config merge, no Cloudflared changes.
The edge Caddy is a dumb proxy — the business Caddy does all the routing and auth.

### TODO 3.2 — Add business hostnames to `psx-homelab/stacks/cloudflared/config.yml`

Add to the ingress list (before the `http_status:404` catch-all):

```yaml
  - hostname: inventree.pushprh.com
    service: http://caddy:80
  - hostname: accounts.pushprh.com
    service: http://caddy:80
  - hostname: n8n.pushprh.com
    service: http://caddy:80
```

This sends Cloudflare tunnel traffic for business hostnames to edge Caddy, which proxies to the business VM.

---
## Phase 4: Business Caddy & Authelia Stacks

**Goal:** Create the two infra stacks (Caddy + Authelia) that pkunited deploys to the business VM.

### TODO 4.1 — Create `stacks/caddy/docker-compose.yml`

The business Caddy is the entry point for all services. It handles TLS termination, routing,
and forward_auth to the local Authelia.

```yaml
services:
  caddy:
    image: caddy:alpine
    container_name: business-caddy
    restart: unless-stopped
    ports:
      - "10.37.20.70:9443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - /opt/appdata/caddy/data:/data
      - /opt/appdata/caddy/config:/config
    networks:
      - businessnet
    security_opt:
      - no-new-privileges:true

networks:
  businessnet:
    external: true
```

### TODO 4.2 — Create `stacks/caddy/Caddyfile`

```caddy
:443 {
	# TLS handled by edge Caddy; we accept plain HTTP on 443 internally.
	# Edge Caddy sets X-Forwarded-Proto: https which we preserve for backends.

	# --- Auth ---
	# All routes go through forward_auth to local Authelia.
	# Authelia is on the same Docker network, reachable by container name.
	@noauth {
		path /healthz
	}

	# --- InvenTree ---
	@inventree {
		host inventree.pushprh.com
	}
	forward_auth @inventree http://authelia:9091 {
		uri /api/authz/forward-auth?service=business&rd=https://auth.pushprh.com
		copy_headers Remote-User Remote-Email Remote-Groups Remote-Name
	}
	reverse_proxy @inventree inventree:8000 {
		header_up X-Forwarded-Proto {http.request.header.X-Forwarded-Proto}
	}

	# --- Akaunting ---
	@akaunting {
		host accounts.pushprh.com
	}
	forward_auth @akaunting http://authelia:9091 {
		uri /api/authz/forward-auth?service=business&rd=https://auth.pushprh.com
		copy_headers Remote-User Remote-Email Remote-Groups Remote-Name
	}
	reverse_proxy @akaunting akaunting:80 {
		header_up X-Forwarded-Proto {http.request.header.X-Forwarded-Proto}
	}

	# --- n8n ---
	@n8n {
		host n8n.pushprh.com
	}
	# n8n webhooks bypass auth; editor goes through forward_auth
	@n8n-webhook {
		host n8n.pushprh.com
		path /webhook/*
	}
	forward_auth @n8n http://authelia:9091 {
		uri /api/authz/forward-auth?service=business&rd=https://auth.pushprh.com
		copy_headers Remote-User Remote-Email Remote-Groups Remote-Name
	}
	reverse_proxy @n8n-webhook n8n:5678
	reverse_proxy @n8n n8n:5678 {
		header_up X-Forwarded-Proto {http.request.header.X-Forwarded-Proto}
	}
}
```

**Note:** The `forward_auth` calls use `http://authelia:9091` — Authelia is on the same
`businessnet` Docker network. No host port binding needed for Authelia.

### TODO 4.3 — Create `stacks/authelia/docker-compose.yml`

```yaml
services:
  authelia:
    image: authelia/authelia:4.39.20
    container_name: business-authelia
    restart: unless-stopped
    env_file: .env
    environment:
      X_AUTHELIA_CONFIG_FILTERS: "template"
    volumes:
      - ./config:/config:ro
      - /opt/appdata/authelia:/data
    networks:
      - businessnet
    security_opt:
      - no-new-privileges:true

networks:
  businessnet:
    external: true
```

### TODO 4.4 — Create `stacks/authelia/config/configuration.yml`

Minimal Authelia config that reads LLDAP on core-infra:

```yaml
server:
  address: 'tcp://0.0.0.0:9091'

log:
  level: 'info'
  format: 'text'

totp:
  issuer: 'pushprh.com'

webauthn:
  display_name: 'pku business'

authentication_backend:
  password_reset:
    disable: true
  password_change:
    disable: true
  ldap:
    implementation: 'lldap'
    # LLDAP on core-infra (psx-homelab manages it)
    address: 'ldap://10.37.20.10:3890'
    base_dn: 'dc=pushprh,dc=com'
    # Bind user — password from AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD
    user: 'uid=admin,ou=people,dc=pushprh,dc=com'

access_control:
  default_policy: 'deny'
  rules:
    - domain: 'inventree.pushprh.com'
      policy: 'one_factor'
    - domain: 'accounts.pushprh.com'
      policy: 'one_factor'
    - domain: 'n8n.pushprh.com'
      policy: 'one_factor'

session:
  name: 'pku_business_session'
  secret: '{{ env "AUTHELIA_SESSION_SECRET" }}'
  cookies:
    - domain: 'pushprh.com'
      authelia_url: 'https://auth.pushprh.com'  # points to core-infra Authelia for portal
      expiration: '1 day'
      inactivity: '8 hours'

regulation:
  max_retries: 4
  find_time: '2 minutes'
  ban_time: '5 minutes'

storage:
  local:
    path: '/data/db.sqlite3'

# No notifier needed — no password reset (handled by LLDAP directly)
notifier:
  filesystem:
    filename: '/data/notifications.txt'
```

**Key points:**
- LDAP backend points to `10.37.20.10:3890` (core-infra LLDAP) — a simple TCP read, no config merge
- `access_control` uses simple domain-based rules (no OIDC policies needed — forward_auth handles everything)
- Session cookie domain is `pushprh.com` so it works across all subdomains
- No OIDC clients configured — Caddy forward_auth is the only auth mechanism

### TODO 4.5 — Pin all app image tags

Audit `pkunited/stacks/*/docker-compose.yml`:

| File | Fix |
|------|-----|
| `stacks/n8n/docker-compose.yml` | `ghcr.io/n8n-io/n8n:latest` → `docker.n8n.io/n8n/n8n:1.101.2` |
| `stacks/akaunting/docker-compose.yml` | `akaunting/akaunting:latest` → `akaunting/akaunting:3.1.31` |

### TODO 4.6 — Remove host port bindings from app stacks

Apps no longer bind host ports — Caddy routes to them on the Docker network.
Remove `ports:` sections from `stacks/inventree/`, `stacks/akaunting/`, `stacks/n8n/`.
Services communicate via container names on `businessnet`.

### TODO 4.7 — Update `psx-homelab/ansible/group_vars/business.yml` appdata dirs

Add Caddy and Authelia appdata dirs:

```yaml
appdata_owned_dirs:
  - caddy/data
  - caddy/config
  - authelia
  - inventree
  - akaunting
  - n8n
```

---

## Phase 5: Secrets Setup

**Goal:** All SOPS-encrypted secret files exist and are populated with initial values.

### TODO 5.1 — Ensure `secrets/age.key` exists in pkunited

Copy `psx-homelab/secrets/age.key` to `pkunited/secrets/age.key`. Both repos use the same
`.sops.yaml` recipient (`age1muhxctlmyhf8lk2qm48z2hur5t4tjfjdz0xn4372nekwspghkgfsfwx9g6`).

### TODO 5.2 — Create `secrets/authelia.env.sops`

```bash
# Session encryption key (Authelia requirement)
AUTHELIA_SESSION_SECRET=<generate with `openssl rand -hex 32`>
# LDAP bind password (same as LLDAP admin password in psx-homelab)
AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD=<copy from psx-homelab secrets/lldap.env.sops or ask operator>
```

The LDAP password is the LLDAP admin bind password. The operator provides it — it's the same
value used by core-infra's Authelia. pkunited's Authelia reads from the same directory read-only.

### TODO 5.3 — Update `secrets/inventree.env.sops`

Remove OIDC fields. Keep:

```bash
INVENTREE_DB_NAME=inventree
INVENTREE_DB_USER=inv_user
INVENTREE_DB_PASSWORD=<generate>
INVENTREE_SECRET_KEY=<generate>
# Break-glass admin password
INVENTREE_BREAKGLASS_PASSWORD=<generate>
```

### TODO 5.4 — Update `secrets/n8n.env.sops`

Remove OIDC fields. Keep:

```bash
N8N_DB_NAME=n8n
N8N_DB_USER=n8n
N8N_DB_PASSWORD=<generate>
N8N_ENCRYPTION_KEY=<generate>
N8N_JWT_SECRET=<generate>
# LiteLLM virtual key (from seko-ai)
LITELLM_N8N_KEY=<add after seko-ai key is created>
```

### TODO 5.5 — Update `secrets/akaunting.env.sops`

Keep as-is (no OIDC fields were there):

```bash
AKAUNTING_DB_NAME=akaunting
AKAUNTING_DB_USER=akaunting
AKAUNTING_DB_PASSWORD=<generate>
AKAUNTING_DB_ROOT_PASSWORD=<generate>
AKAUNTING_APP_KEY=<generate>
AKAUNTING_BREAKGLASS_PASSWORD=<generate>
```

---

## Phase 6: App Compose Adjustments for Caddy Routing

**Goal:** Update app compose files to work behind Caddy (no host ports, internal names).

### TODO 6.1 — Update `stacks/inventree/docker-compose.yml`

- Remove `ports:` section (Caddy routes to `inventree:8000` internally)
- Remove the internal `inventree-proxy` Caddy container (business Caddy handles this now)
- Keep `expose:` for documentation
- Caddyfile for static/media proxying is now in `stacks/caddy/Caddyfile`

### TODO 6.2 — Update `stacks/akaunting/docker-compose.yml`

- Remove `ports:` section
- Remove pre-auth middleware files (`pre-auth-middleware.php`, `pre-auth-load.php`) — not needed with forward_auth
- Remove `APP_PRELOAD` env var
- Remove `TRUSTED_PROXIES` / `FORWARDED` — Caddy sets proper headers

### TODO 6.3 — Update `stacks/n8n/docker-compose.yml`

- Remove `ports:` section
- Remove all OIDC-related env vars (`N8N_ADDITIONAL_NON_UI_ROUTES`, `EXTERNAL_HOOK_FILES`, `OIDC_*`)
- Remove `./oidc/hooks.js` volume mount
- Remove `N8N_TRUST_PROXY` — Caddy sets proper headers

### TODO 6.4 — Remove stale fragment files

```bash
rm -f stacks/caddy/business.caddyfile
rm -f stacks/authelia/business-config.yml
rm -f stacks/cloudflared/tunnel-ingress.yml
rm -rf stacks/n8n/oidc/
rm -f stacks/akaunting/pre-auth-middleware.php
rm -f stacks/akaunting/pre-auth-load.php
rm -f stacks/akaunting/akaunting-start.sh  # if not needed
```

---

## Phase 8: Deployment & Validation

**Goal:** First end-to-end deploy of the separated model.

### TODO 8.1 — Bootstrap: Provision business VM (from psx-homelab)

```bash
cd ~/Projects/psx-homelab
just deploy-host business
```

This runs `base` + `docker` roles, creates `businessnet`, pre-creates appdata dirs.

### TODO 8.2 — Deploy edge Caddy routes (from psx-homelab)

```bash
cd ~/Projects/psx-homelab
just deploy-stack core caddy    # picks up new business routes
just deploy-stack core cloudflared  # picks up new business hostnames
```

### TODO 8.3 — Deploy business stacks (from pkunited)

```bash
cd ~/Projects/pkunited
just secrets          # decrypt SOPS → .env
just validate         # check compose files
just deploy           # rsync stacks + compose up on business VM
```

### TODO 8.4 — Verify services are healthy

```bash
cd ~/Projects/pkunited
just stack-logs caddy          # should show Caddy running
just stack-logs authelia       # should show Authelia connected to LLDAP
just stack-logs inventree      # should show gunicorn healthy
just stack-logs akaunting      # should show Apache/Laravel healthy
just stack-logs n8n            # should show n8n healthy
```

### TODO 8.5 — Verify Caddy routes (through edge)

```bash
# Through edge Caddy → business Caddy → app
curl -s -o /dev/null -w '%{http_code}' https://inventree.pushprh.com/health/
curl -s -o /dev/null -w '%{http_code}' https://accounts.pushprh.com/
curl -s -o /dev/null -w '%{http_code}' https://n8n.pushprh.com/healthz
```

### TODO 8.6 — Verify Authelia SSO

Visit `https://inventree.pushprh.com` → should redirect to Authelia login (via Caddy forward_auth)
→ should authenticate against LLDAP → should redirect to InvenTree.

### TODO 8.7 — Verify backup works

```bash
# After deploy, trigger a manual backup on the business VM
ssh root@10.37.20.70 '/usr/local/bin/psx-backup'
# Check it completes without errors
```

---

## Phase 9: Cleanup & Documentation Finalization

**Goal:** Remove stale files, ensure all docs match reality.

### TODO 9.1 — Remove stale fragment/config files from pkunited

```bash
# These were for the old cross-repo fragment model — no longer needed
rm -f stacks/caddy/business.caddyfile
rm -f stacks/authelia/business-config.yml
rm -f stacks/cloudflared/tunnel-ingress.yml
rm -rf stacks/n8n/oidc/
rm -f stacks/akaunting/pre-auth-middleware.php
rm -f stacks/akaunting/pre-auth-load.php
```

### TODO 9.2 — Remove stale "managed by psx-homelab" from pkunited docs

Audit all files in `pkunited/docs/` and remove any remaining "deploy from psx-homelab"
instructions. The new model is: psx-homelab provisions, pkunited deploys.

### TODO 9.3 — Update `pkunited/AGENTS.md` deployment section

Replace current deployment section with the new model (see TODO 0.2).

### TODO 9.4 — Delete this implementation plan

Once all phases are complete and validated:
```bash
rm docs/repo-separation-plan.md
```

---

## Execution Order Summary

| Priority | Phase | Key Deliverable | Depends On |
|----------|-------|----------------|------------|
| **P0** | 0 | CONTRACT.md, doc consolidation | — |
| **P0** | 0b | Clean psx-homelab stale artifacts | P0:0 |
| **P0** | 1 | `justfile`, `render-env.sh` | P0:0 |
| **P0** | 5 | SOPS secrets (incl. authelia) | P0:1 |
| **P1** | 2 | Business Ansible group in psx-homelab | P0b |
| **P1** | 3 | Edge Caddy + Cloudflared routes | P0b |
| **P1** | 4 | Business Caddy + Authelia stacks | — |
| **P1** | 6 | App compose adjustments | P1:4 |
| **P2** | 8 | First deploy + validation | P0-P1 |
| **P3** | 9 | Cleanup, final doc pass | P2 |

**Sessions:**
- **Session 1:** Phase 0 + Phase 0b + Phase 1 (docs, psx-homelab cleanup, justfile, render-env)
- **Session 2:** Phase 4 + Phase 6 (business Caddy, Authelia, app adjustments)
- **Session 3:** Phase 2 + Phase 3 + Phase 5 (psx-homelab Ansible, edge routes, secrets)
- **Session 4:** Phase 8 (deploy + validate)
- **Session 5:** Phase 9 (cleanup)

---

## Risk Register

| Risk | Mitigation |
|------|-----------|
| `businessnet` already exists on first `docker network create` | `failed_when: false` handles this — idempotent |
| Appdata dir ownership conflict between psx-homelab pre-create and container self-chown | `base` role pre-creates with correct UID/GID |
| LLDAP not reachable from business VM (firewall/network) | Business VM is on VLAN 20, same as core-infra. Test `ssh business-vm 'nc -zv 10.37.20.10 3890'` before deploy |
| Business Caddy port 9443 conflicts with existing service | Verify port is free: `ssh business-vm 'ss -tlnp \| grep 9443'` |
| Edge Caddy → business Caddy double TLS confusion | Edge Caddy does TLS termination. Traffic to business VM is plain HTTP on :9443. Business Caddy listens on `:443` internally (mapped to host :9443). No cert needed on business Caddy. |
| pkunited `just deploy` fails mid-way | `just deploy` is a single bash script with `set -euo pipefail`. Manual recovery: `just deploy-stack <svc>` |
| Caddy forward_auth redirect loop with edge Caddy | Edge Caddy sets `X-Forwarded-Proto: https`. Business Caddy preserves it via `{http.request.header.X-Forwarded-Proto}`. Authelia forward_auth uses `rd=` to redirect to core-infra Authelia portal. |

---

## Notes for Next Pi Session

1. **Age key:** Copy `psx-homelab/secrets/age.key` to `pkunited/secrets/age.key`. Same recipient in `.sops.yaml`.

2. **LLDAP bind password:** Ask the operator for the LLDAP admin password (from `psx-homelab/secrets/lldap.env.sops` or `secrets/authelia.env.sops`). This is the `AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD` for the business Authelia.

3. **Caddy forward_auth with edge proxy:** The key insight is that edge Caddy terminates TLS and proxies to business Caddy on plain HTTP. Business Caddy's forward_auth hits local Authelia. The `rd=` redirect URL points to `https://auth.pushprh.com` (core-infra Authelia portal) for the login page. After auth, control returns to business Caddy which passes headers to the app. This is a two-hop auth flow that works because the session cookie domain is `pushprh.com`.

4. **InvenTree static/media serving:** The old design had InvenTree's own Caddy container. Now business Caddy handles it. The Caddyfile needs to serve static/media from bind-mounted volumes. Consider whether business Caddy should proxy all InvenTree traffic to gunicorn, or serve static files directly. For simplicity, proxy everything to gunicorn (InvenTree's Django handles static files in production via Whitenoader/collectstatic).

5. **n8n webhooks bypass auth:** The Caddyfile has `@n8n-webhook` matcher that bypasses forward_auth for `/webhook/*` paths. This is needed for external services (Amazon, eBay) to trigger n8n workflows.

6. **Image pin verification:** Check that `stacks/inventree/docker-compose.yml` uses the correct image tag. The file currently has `inventree/inventree:1.4.3` but plan.md mentions `2.7.1`. Verify which is current before deploy.
