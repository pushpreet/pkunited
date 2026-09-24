# pkunited — Business Services

Self-hosted business services for a small hardware/electronics resale business selling on Amazon and eBay. Runs on a single VM (`10.37.20.70`) provisioned by [psx-homelab](../psx-homelab).

## Architecture

All services run on the business VM. psx-homelab provisions the VM (base OS, Docker, networks, appdata dirs); pkunited deploys all runtime components (Caddy, n8n).

```
Internet → Cloudflare Tunnel → Edge Caddy (core-infra) → Business Caddy (10.37.20.70:9443)
  └─ n8n.pushprh.com        ──→ n8n:5678
                              (except /webhook/* — no auth)
```

n8n handles its own authentication via User Management mode. Webhook paths (`/webhook/*`) bypass auth so external services (Amazon, eBay) can trigger workflows.

## Services

| Service | Image | Network Port | Route | DB |
|---------|-------|-------------|-------|-----|
| Caddy | `caddy:alpine@sha256:5f5c...` | `10.37.20.70:9443` | all | — |
| n8n | `n8nio/n8n:2.33.7@sha256:3989...` | internal | n8n.pushprh.com | PostgreSQL 17 |
| ERPNext | `erpnext-pkunited:16-sync-simplefin` (local build; base `frappe/erpnext:v16.32.1@sha256:c60e...`) | internal (8080) | erp.pushprh.com | MariaDB 11.8 |

### n8n

Workflow automation. Orchestrates marketplace order ingestion (Amazon, eBay), bank CSV import, LLM agents for decision support, and cross-service coordination. Reaches LiteLLM on `10.37.20.50:4000` for inference.

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

- **n8n User Management auth:** n8n handles its own authentication. Caddy reverse-proxies directly without `forward_auth`. Webhook paths bypass auth entirely.
- **Business Caddy as entry point:** Edge Caddy is a dumb proxy to `:9443`. All routing and TLS decisions happen on the business VM. This means pkunited owns its full stack without cross-repo fragment merging.
- **No host ports on apps:** App containers are internal-only on `businessnet`. Caddy routes to them by container name. No port conflicts, no accidental exposure.
- **SOPS + age for secrets:** pkunited uses its own age key, separate from psx-homelab. Secrets are committed encrypted; `.env` files are gitignored and rendered locally before deploy. Back up the private key in Vaultwarden and keep it out of psx-homelab's restic backup set.
- **n8n webhooks bypass auth:** `/webhook/*` paths skip auth so external services (Amazon, eBay) can trigger workflows without authentication.

## Open Questions

- Container images are pinned to exact versions and registry digests; keep pins aligned with the deployed production version unless intentionally upgrading.
- LiteLLM key: `LITELLM_N8N_KEY` is blank in secrets. Add after seko-ai virtual key is provisioned.

## Future Work

- n8n workflow library: build reusable workflows for marketplace operations (order sync, shipment tracking, returns)
- Automated reporting: n8n workflows that generate weekly financial and inventory summaries
