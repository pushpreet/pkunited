# pkunited — Business Services

## Goal

Self-host the full stack for a small business selling hardware/electronics on Amazon and eBay: bank/card transaction sync, marketplace order ingestion, bookkeeping, and inventory tracking — all with API/MCP interfaces for LLM agent interaction.

---

## Architecture

All services run on a single business VM (`10.37.20.70`) provisioned by psx-homelab.
pkunited deploys everything on that VM: Caddy (entry point) and n8n.

```
Internet → Cloudflare → Edge Caddy (core-infra) → Business Caddy (10.37.20.70:9443)
  └─ n8n.pushprh.com        ──→ n8n:5678
                              (except /webhook/* — no auth)
```

n8n handles its own authentication via User Management mode. Webhook paths bypass auth so external services can trigger workflows.

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

### n8n

Integration orchestration — polling marketplaces, syncing orders to inventory/accounting, parsing bank statements, and exposing workflows to LLM agents. Node.js, PostgreSQL.

**Key workflows to build:**
1. **Amazon order ingestion** → process orders and track fulfillment
2. **eBay order ingestion** → same flow
3. **Stock alerts** when stock drops below threshold
4. **Revenue reconciliation** of marketplace payouts

---

## Authentication

n8n uses its own User Management mode for authentication. Caddy reverse-proxies directly to n8n without any `forward_auth` middleware. Webhook paths (`/webhook/*`) skip auth entirely so external services can trigger workflows.

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
| All-in-one ERP | Rejected Odoo | Community edition paywalls key features. Enterprise is per-user paid |

---

## Open Questions

1. **VM sizing:** 4 vCPU / 8 GB RAM / 40 GB SSD — sufficient? Or bump to 6 vCPU / 16 GB?
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
