# pkunited — Business Services

Self-hosted business services for a small hardware/electronics resale business selling on Amazon and eBay. Runs on a single VM (`10.37.20.70`) provisioned by [psx-homelab](../psx-homelab).

## Architecture

All services run on the business VM. psx-homelab provisions the VM (base OS, Docker, networks, appdata dirs); pkunited deploys all runtime components (Caddy, Authelia, apps).

```
Internet → Cloudflare Tunnel → Edge Caddy (core-infra) → Business Caddy (10.37.20.70:9443)
  ├─ inventree.pushprh.com  ──→ forward_auth → Authelia → inventree:8000
  ├─ accounts.pushprh.com   ──→ forward_auth → Authelia → akaunting:80
  └─ n8n.pushprh.com        ──→ forward_auth → Authelia → n8n:5678
                              (except /webhook/* — no auth)
```

All auth is handled by Caddy `forward_auth` to a local Authelia instance. Authelia reads LLDAP on core-infra (`10.37.20.10:3890`) for user/group lookup. No OIDC clients, no per-app auth config, no cross-repo config merge.

## Services

| Service | Image | Network Port | Route | DB |
|---------|-------|-------------|-------|-----|
| Caddy | `caddy:alpine` | `10.37.20.70:9443` | all | — |
| Authelia | `authelia/authelia:4.39.20` | internal | — | SQLite |
| InvenTree | `inventree/inventree:1.4.3` | internal | inventree.pushprh.com | PostgreSQL 17 |
| Akaunting | `akaunting/akaunting:3.1.21` | internal | accounts.pushprh.com | MariaDB 11.3 |
| n8n | `ghcr.io/n8n-io/n8n:latest` | internal | n8n.pushprh.com | PostgreSQL 17 |

### InvenTree

Inventory and parts management. Tracks SKUs, BOMs, suppliers, stock levels, and manufacturing orders. Integrated with Amazon/eBay workflows via n8n.

### Akaunting

Double-entry bookkeeping. Handles invoicing, expenses, bank feeds, and financial reporting. Connected to real bank accounts for automatic transaction import.

### n8n

Workflow automation. Orchestrates marketplace order ingestion (Amazon, eBay), bank CSV import into Akaunting, LLM agents for decision support, and cross-service coordination. Reaches LiteLLM on `10.37.20.50:4000` for inference.

## Authentication

Caddy `forward_auth` routes to a local Authelia on the business VM. Authelia authenticates against LLDAP on core-infra. One login session (cookie domain `pushprh.com`) covers all services.

See [`docs/auth-runbook.md`](docs/auth-runbook.md) for LLDAP users, break-glass access, and post-deploy checklist.

## Deployment

pkunited owns its own deployment pipeline. The business VM is provisioned by psx-homelab (Ansible base + Docker roles), then pkunited deploys all stacks into it.

```
just validate        # render secrets, validate all compose files
just deploy          # full deploy (secrets → stacks on business VM)
just deploy-stack <svc>  # deploy single stack
just stack-logs <svc>    # tail logs
just stack-down <svc>    # stop a stack (volumes preserved)
just sops-edit <svc>     # edit encrypted secret
just backup-dumps        # application-consistent DB dumps
```

See [`CONTRACT.md`](CONTRACT.md) for the interface with psx-homelab.

## Day-to-Day Operations

| Action | Command |
|--------|---------|
| Deploy all stacks | `just deploy` |
| Deploy single stack | `just deploy-stack <svc>` |
| Tail logs | `just stack-logs <svc>` |
| Stop a stack | `just stack-down <svc>` |
| Purge a stack (keep data) | `just stack-purge <svc>` |
| Edit secrets | `just sops-edit <svc>` |
| DB backup dumps | `just backup-dumps` |
| SSH into business VM | `just ssh` |

## Key Decisions & Rationale

- **Caddy `forward_auth` over OIDC:** Eliminates per-app auth config, secret digests, and OIDC client management. Caddy handles the auth handshake; Authelia talks to LLDAP directly. Simpler to operate, easier to reason about.
- **Business Caddy as entry point:** Edge Caddy is a dumb proxy to `:9443`. All routing, TLS, and auth decisions happen on the business VM. This means pkunited owns its full stack without cross-repo fragment merging.
- **No host ports on apps:** App containers are internal-only on `businessnet`. Caddy routes to them by container name. No port conflicts, no accidental exposure.
- **SOPS + age for secrets:** Same age key shared between pkunited and psx-homelab. Secrets are committed encrypted; `.env` files are gitignored and rendered locally before deploy.
- **n8n webhooks bypass auth:** `/webhook/*` paths skip `forward_auth` so external services (Amazon, eBay) can trigger workflows without authentication.

## Open Questions

- InvenTree version: currently on `1.4.3`. Evaluate upgrade path to latest stable when inventory workflows stabilize.
- n8n image: using `ghcr.io/n8n-io/n8n:latest` (the `docker.n8n.io` registry tag from the plan doesn't exist). Pin to a specific version once workflows are production-stable.
- Akaunting version: on `3.1.21` (plan cited `3.1.31` which doesn't exist). Evaluate upgrade path.
- LiteLLM key: `LITELLM_N8N_KEY` is blank in secrets. Add after seko-ai virtual key is provisioned.

## Data Migration

Pending: import existing product data, customers, and financial records from Grist/spreadsheets into InvenTree and Akaunting respectively.

## Future Work

- n8n workflow library: build reusable workflows for marketplace operations (order sync, shipment tracking, returns)
- MCP servers: expose InvenTree/Akaunting as MCP tools for LLM agents
- Automated reporting: n8n workflows that generate weekly financial and inventory summaries
