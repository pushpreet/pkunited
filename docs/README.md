# pkunited — Business Services

## Goal

Self-host the full stack for a small business selling hardware/electronics on Amazon and eBay: bank/card transaction sync, marketplace order ingestion, bookkeeping, and inventory tracking — all with API/MCP interfaces for LLM agent interaction.

ERPNext provides the core ERP capabilities (inventory, accounting, sales, purchases). n8n orchestrates marketplace integrations and feeds data into ERPNext.

---

## Architecture

All services run on a single business VM (`10.37.20.70`) provisioned by psx-homelab.
pkunited deploys everything on that VM: Caddy (entry point), n8n, and ERPNext.

```
Internet → Cloudflare → Edge Caddy (core-infra) → Business Caddy (10.37.20.70:9443)
  ├─ n8n.pushprh.com        ──→ n8n:5678
  │                           (except /webhook/* — no auth)
  └─ erp.pushprh.com         ──→ erpnext-frontend:8080
```

n8n handles its own authentication via User Management mode. Webhook paths bypass auth so external services can trigger workflows.

ERPNext handles its own authentication via the Administrator account.

n8n reaches LiteLLM on epyc-server (`http://10.37.20.50:4000/v1`) for LLM inference via a dedicated virtual key.

> **MCP servers (phase 2):** n8n MCP deferred to a follow-up pass.
> Phase 1 delivers the service with a web UI + REST API. LLM agents can interact via direct
> API calls or n8n webhook endpoints.

---

## Services

| Service | Image | Network Port | Route | DB |
|---------|-------|-------------|-------|-----|
| Caddy | caddy:alpine | `10.37.20.70:9443` | all | — |
| n8n | docker.n8n.io/n8n/n8n:1.101.2 | internal | n8n.pushprh.com | PostgreSQL 17 |
| ERPNext | frappe/erpnext:v16 | internal (8080) | erp.pushprh.com | MariaDB 11.8 |

### n8n

Integration orchestration — polling marketplaces, syncing orders to inventory/accounting, parsing bank statements, and exposing workflows to LLM agents. Node.js, PostgreSQL.

**Key workflows to build:**
1. **Amazon order ingestion** → process orders and track fulfillment
2. **eBay order ingestion** → same flow
3. **Stock alerts** when stock drops below threshold
4. **Revenue reconciliation** of marketplace payouts

### ERPNext

ERP — inventory, accounting, sales, purchases, stock management. Python/Frappe framework, MariaDB, Redis.

Adapted from [frappe_docker](https://github.com/frappe/frappe_docker). Runs 10 services: configurator, backend (Gunicorn), frontend (Nginx), websocket (Socket.IO), queue-short, queue-long, scheduler, MariaDB, redis-cache, redis-queue.

**Initial setup** (one-time after first deploy):
```bash
cd /opt/stacks/erpnext
docker compose exec backend bench new-site \
  --mariadb-user-host-login-scope=% \
  --db-root-password <DB_PASSWORD> \
  --admin-password <ADMIN_PASSWORD> \
  erp.pushprh.com
```

---

## Authentication

n8n uses its own User Management mode for authentication. Caddy reverse-proxies directly to n8n without any `forward_auth` middleware. Webhook paths (`/webhook/*`) skip auth entirely so external services can trigger workflows.

ERPNext uses its built-in user management (Administrator account + app-level users). Caddy reverse-proxies directly to the ERPNext frontend.

---

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

---

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

---

## Key Decisions & Rationale

| Decision | Choice | Why |
|----------|--------|-----|
| Automation | n8n over custom scripts | Visual workflow builder, native marketplace nodes, AI agent nodes, mature ecosystem |
| ERP | ERPNext over Odoo | GPL-licensed, no paywalled features, active community, Docker-native via frappe_docker |

---

## Open Questions

1. **VM sizing:** Bump to 6 vCPU / 16 GB / 80 GB to fit both n8n and ERPNext.
2. **Backup target:** restic → Azure (like core/media) or restic → NAS (like llm)?
3. **Monitoring:** Add business services to core-infra Prometheus/Grafana?
4. **Amazon Seller Central:** Existing SP-API developer profile? Need `seller_id`, `refresh_token`, AWS creds.
5. **eBay Developer:** OAuth `client_id` / `client_secret` from developer.ebay.com?

---

## Future Work

- [ ] Wire up MCP servers to LLM agents (Claude Desktop, etc.)
- [ ] Configure Amazon SP-API credentials and build order polling workflow
- [ ] Configure eBay API credentials and build order polling workflow
- [ ] Build order → inventory + accounting sync workflows
- [ ] Build bank CSV import workflow
- [ ] Build reorder alert workflow
- [ ] Test end-to-end order flow with real orders
