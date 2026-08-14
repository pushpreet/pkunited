# pkunited — Business Services

## Goal

Self-host the full stack for a small business selling hardware/electronics on Amazon and eBay: bank/card transaction sync, marketplace order ingestion, bookkeeping, and inventory tracking — all with API/MCP interfaces for LLM agent interaction.

---

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

n8n reaches LiteLLM on epyc-server (`http://10.37.20.50:4000/v1`) for LLM inference via a dedicated virtual key.

> **MCP servers (phase 2):** InvenTree MCP, Akaunting MCP, and n8n MCP deferred to a follow-up pass.
> Phase 1 delivers the three services with web UIs + REST APIs. LLM agents can interact via direct
> API calls or n8n webhook endpoints.

---

## Services

| Service | Image | Network Port | Route | DB |
|---------|-------|-------------|-------|-----|
| Caddy | caddy:alpine | `10.37.20.70:9443` | all | — |
| Authelia | authelia/authelia:4.39.20 | internal | — | SQLite |
| InvenTree | inventree/inventree:1.4.3 | internal | inventree.pushprh.com | PostgreSQL 17 |
| Akaunting | akaunting/akaunting:3.1.31 | internal | accounts.pushprh.com | MariaDB 11.3 |
| n8n | docker.n8n.io/n8n/n8n:1.101.2 | internal | n8n.pushprh.com | PostgreSQL 17 |

### InvenTree

Granular stock tracking, bills of materials, supplier management, location hierarchy, and parts catalog for hardware resale. Python/Django + DRF (REST API), PostgreSQL, React frontend. Full REST API with OpenAPI/Swagger docs. MCP server available ([syntaxerr66/inventree-mcp](https://github.com/syntaxerr66/inventree-mcp)).

**Key capabilities:**
- Part-level stock tracking with serial numbers / batch tracking
- Purchase orders to suppliers, sales orders to customers
- Location hierarchy (warehouse shelves, bins, rooms)
- BOMs for kits/bundles, CSV import/export
- Mobile app (iOS + Android) for barcode scanning

### Akaunting

Business accounting with invoicing, expense tracking, double-entry bookkeeping, tax/VAT reporting, and financial statements. PHP/Laravel + Vue.js, MySQL/MariaDB. Full REST API.

**Key capabilities:**
- Invoice creation and tracking, bill/expense recording
- Double-entry accounting, multi-currency support
- Tax/VAT calculation, bank account tracking
- Recurring invoices, multi-user with roles

### n8n

Integration orchestration — polling marketplaces, syncing orders to inventory/accounting, parsing bank statements, and exposing workflows to LLM agents. Node.js, PostgreSQL.

**Key workflows to build:**
1. **Amazon order ingestion** → InvenTree sales order + Akaunting invoice
2. **eBay order ingestion** → same flow
3. **Stock deduction** on fulfilled orders
4. **Bank CSV import** → Akaunting transactions
5. **Reorder alerts** when stock drops below threshold
6. **Revenue reconciliation** of marketplace payouts

### Bank/Card Transaction Sync

Manual CSV/OFX import piped through n8n into Akaunting. Avoiding Plaid/SimpleFIN costs. Upgrade to [OpenFinance](https://openfinance.sh/) later if volume justifies it.

---

## Authentication

All services use Caddy `forward_auth` to a local Authelia instance.
Authelia reads LLDAP on core-infra for user/group lookup. No OIDC clients.
No per-app auth config. No middleware. No bolt-ons.

See `docs/auth-runbook.md` for setup details and LLDAP user table.

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
| Inventory | InvenTree over OpenOMS | Production-stable, excellent MCP server, perfect for hardware/parts tracking |
| Bookkeeping | Akaunting over Actual Budget | Business-oriented (invoicing, double-entry, tax). Actual Budget is personal envelope budgeting |
| Automation | n8n over custom scripts | Visual workflow builder, native marketplace nodes, AI agent nodes, mature ecosystem |
| Bank sync | CSV via n8n over Plaid/OpenFinance | Avoid SaaS dependency and cost. Upgrade to OpenFinance later if needed |
| All-in-one ERP | Rejected Odoo | Community edition paywalls key features. Enterprise is per-user paid |
| Spreadsheet DB | Migrate off Grist | Grist is great for prototyping but lacks structured accounting/inventory features |

---

## Open Questions

1. **VM sizing:** 4 vCPU / 8 GB RAM / 40 GB SSD — sufficient? Or bump to 6 vCPU / 16 GB?
2. **Backup target:** restic → Azure (like core/media) or restic → NAS (like llm)?
3. **Monitoring:** Add business services to core-infra Prometheus/Grafana?
4. **Amazon Seller Central:** Existing SP-API developer profile? Need `seller_id`, `refresh_token`, AWS creds.
5. **eBay Developer:** OAuth `client_id` / `client_secret` from developer.ebay.com?
6. **Bank CSV format:** Which banks? Format determines the n8n parser.

---

## Data Migration

Currently using self-hosted Grist for some accounting. Data should be exported from Grist (CSV/Excel) and migrated into Akaunting and InvenTree as part of initial setup:

- [ ] Export data from Grist (CSV)
- [ ] Import product/part catalog into InvenTree (`inventree.pushprh.com`)
- [ ] Import existing stock quantities into InvenTree
- [ ] Set up chart of accounts in Akaunting (`accounts.pushprh.com`)
- [ ] Import existing transactions/balances into Akaunting

---

## Future Work

- [ ] Build and deploy inventree-mcp server (Go binary, stdio mode)
- [ ] Build Akaunting MCP wrapper (TypeScript/Node or Go)
- [ ] Wire up MCP servers to LLM agents (Claude Desktop, etc.)
- [ ] Configure Amazon SP-API credentials and build order polling workflow
- [ ] Configure eBay API credentials and build order polling workflow
- [ ] Build order → inventory + accounting sync workflows
- [ ] Build bank CSV import workflow
- [ ] Build reorder alert workflow
- [ ] Test end-to-end order flow with real orders
