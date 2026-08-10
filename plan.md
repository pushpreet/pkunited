# Small Business Homelab Services Plan

## Goal

Self-host the full stack for a small business selling hardware/electronics on Amazon and eBay: bank/card transaction sync, marketplace order ingestion, bookkeeping, and inventory tracking — all with API/MCP interfaces for LLM agent interaction.

---

## Architecture Overview

```
┌─────────────────┐    ┌──────────────┐
│  Amazon SP-API   │    │    eBay API   │
└────────┬────────┘    └──────┬───────┘
         │                    │
         ▼                    ▼
   ┌─────────────────────────────────┐
   │              n8n                  │  (orchestration / automation layer)
   │  - Poll marketplaces for orders   │
   │  - Push to InvenTree + Akaunting  │
   │  - Parse bank CSV statements      │
   │  - AI agent nodes for LLM access  │
   └──────┬───────────┬───────────────┘
          │           │
   ┌──────▼──────┐ ┌──▼──────────────┐
   │  InvenTree   │ │    Akaunting     │
   │  + MCP      │ │    + REST API    │
   │ (inventory)  │ │  (bookkeeping)   │
   └─────────────┘ └──────────────────┘
```

All three services run on a single Proxmox VM (**business-vm**, `10.37.20.70`, VLAN 20),
managed by Ansible in the `psx-homelab` repo — same pattern as core / media / llm.
Edge Caddy on core-infra reverse-proxies by IP to each service.

---

## Component 1: Inventory — InvenTree

**Purpose:** Granular stock tracking, bills of materials, supplier management, location hierarchy, and parts catalog for hardware resale.

| Property | Detail |
|----------|--------|
| Repo | [inventree/inventree](https://github.com/inventree/inventree) |
| License | MIT |
| Tech Stack | Python/Django + DRF (REST API), PostgreSQL, React frontend |
| Docker | `inventree/inventree:2.7.1` |
| API | Full REST API with OpenAPI/Swagger docs |
| MCP Server | [syntaxerr66/inventree-mcp](https://github.com/syntaxerr66/inventree-mcp) — 26 tools (parts, stock, locations, categories) |
| Host Port | `10.37.20.70:8080` → `inventree.pushprh.com` |
| Stack | `stacks/inventree/` in psx-homelab |

**Key capabilities:**
- Part-level stock tracking with serial numbers / batch tracking
- Purchase orders to suppliers, sales orders to customers
- Location hierarchy (warehouse shelves, bins, rooms)
- BOMs for kits/bundles, CSV import/export
- Mobile app (iOS + Android) for barcode scanning

---

## Component 2: Bookkeeping — Akaunting

**Purpose:** Business accounting with invoicing, expense tracking, double-entry bookkeeping, tax/VAT reporting, and financial statements.

| Property | Detail |
|----------|--------|
| Repo | [akaunting/akaunting](https://github.com/akaunting/akaunting) |
| License | GPL-3.0 |
| Tech Stack | PHP/Laravel + Vue.js, MySQL/MariaDB |
| Docker | `akaunting/akaunting:3.1.31` |
| API | Full REST API (CRUD on all entities) |
| Host Port | `10.37.20.70:8081` → `accounts.pushprh.com` |
| Stack | `stacks/akaunting/` in psx-homelab |

**Key capabilities:**
- Invoice creation and tracking, bill/expense recording
- Double-entry accounting, multi-currency support
- Tax/VAT calculation, bank account tracking
- Recurring invoices, multi-user with roles

---

## Component 3: Automation — n8n

**Purpose:** Integration orchestration — polling marketplaces, syncing orders to inventory/accounting, parsing bank statements, and exposing workflows to LLM agents.

| Property | Detail |
|----------|--------|
| Repo | [n8n-io/n8n](https://github.com/n8n-io/n8n) |
| License | Sustainable Use License (free for self-hosted) |
| Tech Stack | Node.js, PostgreSQL, Redis (optional) |
| Docker | `docker.n8n.io/n8n/n8n:1.101.2` |
| Host Port | `10.37.20.70:5678` → `n8n.pushprh.com` |
| Stack | `stacks/n8n/` in psx-homelab |

**Key workflows to build:**
1. **Amazon order ingestion** → InvenTree sales order + Akaunting invoice
2. **eBay order ingestion** → same flow
3. **Stock deduction** on fulfilled orders
4. **Bank CSV import** → Akaunting transactions
5. **Reorder alerts** when stock drops below threshold
6. **Revenue reconciliation** of marketplace payouts

n8n reaches LiteLLM on epyc-server (`http://10.37.20.50:4000/v1`) for LLM inference via a dedicated virtual key.

---

## Component 4: Bank/Card Transaction Sync

**Approach:** Manual CSV/OFX import piped through n8n into Akaunting.

**Rationale:** Avoiding Plaid/SimpleFIN costs. Upgrade to [OpenFinance](https://openfinance.sh/) later if volume justifies it.

---

## Current State: Grist

Currently using self-hosted Grist for some accounting. Data should be exported from Grist (CSV/Excel) and migrated into Akaunting and InvenTree as part of initial setup.

---

## Provisioning & Deployment

**Repo split:** Compose stacks live here (pkunited). Secrets, Ansible provisioning,
and infrastructure live in `psx-homelab`. The two repos must be sibling directories
(`~/Projects/pkunited` and `~/Projects/psx-homelab`) so `psx-homelab/justfile` can
resolve `PKUNITED_REPO` by default.

### Prerequisites

**VM provisioning** (one-time, from Proxmox control machine with SSH access):
```bash
cd ~/Projects/psx-homelab
host/provision-vms.sh vm business
```
This creates a Debian 13 (trixie) VM: 4 vCPU / 8 GB RAM / 40 GB SSD on `local-zfs`,
IP `10.37.20.70` on VLAN 20. MAC `88:88:88:20:00:70`. Cloud-init + deploy key.

### Phase 1: Secrets

All commands run from the `psx-homelab` directory:

```bash
cd ~/Projects/psx-homelab

# Fill in values, then encrypt (creates secrets/<svc>.env.sops):
cp secrets/inventree.env.example /tmp/inventree.env   # edit
just sops-new inventree /tmp/inventree.env
shred -u /tmp/inventree.env

# Repeat for akaunting and n8n.
# Later edits:
just sops-edit inventree
just sops-edit akaunting
just sops-edit n8n
```

### Phase 2: Bootstrap (Ansible + Stacks)

From `psx-homelab`:

```bash
# Full bootstrap: base → Docker → businessnet → deploy all stacks
just deploy-host business

# Or deploy individual stacks (compose sourced from pkunited, .env from psx-homelab secrets):
just deploy-stack business inventree
just deploy-stack business akaunting
just deploy-stack business n8n
```

**How it works:**
1. `just secrets` renders SOPS → `.env` into both local `stacks/<svc>/` _and_
   `${PKUNITED_REPO}/stacks/<svc>/.env` (bridging the two repos)
2. Ansible `base` + `docker` roles provision the host
3. `businessnet` Docker network created
4. `deploy_stacks.yml` rsyncs compose files from pkunited (`PKUNITED_REPO/stacks/<svc>/`)
   to the business VM's `/opt/stacks/<svc>/`, then `docker compose up -d`
5. The `.env` is already in the pkunited stack dir, so Compose picks it up

### Phase 3: Caddy Routes

```bash
# Redeploy Caddy to pick up business routes + auto-provision TLS certs:
just deploy-stack core caddy
```

### Phase 3: Data Migration

- [ ] Export data from Grist (CSV)
- [ ] Import product/part catalog into InvenTree (`inventree.pushprh.com`)
- [ ] Import existing stock quantities into InvenTree
- [ ] Set up chart of accounts in Akaunting (`accounts.pushprh.com`)
- [ ] Import existing transactions/balances into Akaunting

### Phase 4: MCP Setup (Phase 2 — future)

- [ ] Build and deploy inventree-mcp server (Go binary, stdio mode)
- [ ] Build Akaunting MCP wrapper (TypeScript/Node or Go)
- [ ] Wire up MCP servers to LLM agents (Claude Desktop, etc.)

### Phase 5: n8n Workflows

- [ ] Configure Amazon SP-API credentials and build order polling workflow
- [ ] Configure eBay API credentials and build order polling workflow
- [ ] Build order → inventory + accounting sync workflows
- [ ] Build bank CSV import workflow
- [ ] Build reorder alert workflow
- [ ] Test end-to-end order flow with real orders

---

## Day-to-Day Operations

All commands from `psx-homelab` (compose sourced from pkunited):

| Action | Command |
|--------|---------|
| Full deploy (all hosts) | `just deploy` |
| Business host only | `just deploy-host business` |
| Single stack | `just deploy-stack business <inventree\|akaunting\|n8n>` |
| Stack logs | `just stack-logs business <inventree\|akaunting\|n8n>` |
| Stop a stack | `just stack-down business <stack>` |
| Purge a stack | `just stack-purge business <stack>` |
| Edit secrets | `just sops-edit <inventree\|akaunting\|n8n>` |
| Health check | `just ping` (includes business) |
| Backups | `backup` role (restic → Azure, nightly at 02:30) |

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
2. **Backup target:** restic → Azure (like core/media) or restic → NAS (like llm)? (Default: Azure, matching the `backup` role pattern.)
3. **Monitoring:** Add business services to core-infra Prometheus/Grafana?
4. **Authelia SSO:** Should inventree/accounts/n8n go behind Authelia (existing LLDAP directory) or keep native login?
5. **Amazon Seller Central:** Existing SP-API developer profile? Need `seller_id`, `refresh_token`, AWS creds.
6. **eBay Developer:** OAuth `client_id` / `client_secret` from developer.ebay.com?
7. **Bank CSV format:** Which banks? Format determines the n8n parser.
8. **Dev VM separation:** Business VM is on `10.37.20.70`; dev VM remains on `10.37.20.60`. No conflict.
