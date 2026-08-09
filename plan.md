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
   └─────────────┘ └─────────────────┘
```

---

## Component 1: Inventory — InvenTree

**Purpose:** Granular stock tracking, bills of materials, supplier management, location hierarchy, and parts catalog for hardware resale.

| Property | Detail |
|----------|--------|
| Repo | [inventree/inventree](https://github.com/inventree/inventree) |
| License | MIT |
| Tech Stack | Python/Django + DRF (REST API), PostgreSQL, React frontend |
| Docker | `inventree/inventree:latest` |
| API | Full REST API with OpenAPI/Swagger docs |
| MCP Server | [syntaxerr66/inventree-mcp](https://github.com/syntaxerr66/inventree-mcp) — 26 tools (parts, stock, locations, categories) with fuzzy search and image lookup |
| Deployment | Docker Compose + PostgreSQL |

**Key capabilities for our use case:**
- Part-level stock tracking with serial numbers / batch tracking
- Purchase orders to suppliers
- Sales orders to customers
- Location hierarchy (warehouse shelves, bins, rooms)
- BOMs (bills of materials) for kits/bundles
- Import/export CSV
- Mobile app (iOS + Android) for barcode scanning and stock movements

**MCP setup:** Build the Go binary from source, run as stdio MCP server with `INVENTREE_URL` and `INVENTREE_TOKEN` env vars.

---

## Component 2: Bookkeeping — Akaunting

**Purpose:** Business accounting with invoicing, expense tracking, double-entry bookkeeping, tax/VAT reporting, and financial statements.

| Property | Detail |
|----------|--------|
| Repo | [akaunting/akaunting](https://github.com/akaunting/akaunting) |
| License | GPL-3.0 |
| Tech Stack | PHP/Laravel + Vue.js, MySQL/MariaDB |
| Docker | `akaunting/akaunting:latest` |
| API | Full REST API (CRUD on all entities: invoices, bills, transactions, accounts, categories, taxes) |
| Auth | HTTP Basic (email + password) or Personal Access Token |
| Deployment | Docker Compose + MariaDB |

**Key capabilities for our use case:**
- Invoice creation and tracking
- Bill/expense recording
- Double-entry accounting engine
- Bank account tracking (manual import via CSV/OFX)
- Multi-currency support
- Tax/VAT calculation and reporting
- Recurring invoices and bills
- Multi-user with roles
- App/plugin ecosystem for extensions

**LLM access:** No native MCP server, but the REST API is well-structured. We can write a lightweight MCP wrapper (TypeScript/Node or Go) or interact via the API directly from n8n AI agent nodes.

---

## Component 3: Automation — n8n

**Purpose:** Integration orchestration — polling marketplaces, syncing orders to inventory/accounting, parsing bank statements, and exposing workflows to LLM agents.

| Property | Detail |
|----------|--------|
| Repo | [n8n-io/n8n](https://github.com/n8n-io/n8n) |
| License | Sustainable Use License (free for self-hosted personal/business use) |
| Tech Stack | Node.js, PostgreSQL/SQLite, Redis (optional) |
| Docker | `docker.n8n.io/n8n/n8n` |
| API | REST API + WebSocket |
| Deployment | Docker Compose + PostgreSQL |

**Key workflows to build:**
1. **Amazon order ingestion** — Poll Amazon SP-API for new orders → create sales order in InvenTree → create invoice/revenue entry in Akaunting
2. **eBay order ingestion** — Poll eBay API for new orders → same flow as Amazon
3. **Stock deduction** — On fulfilled order → deduct quantities from InvenTree locations
4. **Bank statement import** — Parse CSV/OFX from bank feeds → create transactions in Akaunting
5. **Reorder alerts** — When InvenTree stock drops below threshold → notify / create purchase order
6. **Revenue reconciliation** — Periodic sync of marketplace payouts to Akaunting bank accounts

**LLM access:** n8n has native AI Agent nodes and a REST API. LLM agents can trigger workflows programmatically or interact through the n8n interface.

---

## Component 4: Bank/Card Transaction Sync

**Approach:** Manual CSV/OFX import piped through n8n into Akaunting.

**Rationale:** Avoiding Plaid/SimpleFIN dependency costs ($15+/yr, API key management, credential refresh). Bank CSV imports are reliable for small volume, and n8n can parse/transform the data and push it to Akaunting's API.

**Future upgrade path:** If volume justifies it, add [OpenFinance](https://openfinance.sh/) (self-hosted Plaid alternative with built-in MCP server) for automated bank sync.

---

## Current State: Grist

We are currently using a self-hosted Grist instance for some accounting workflows. Grist is flexible (spreadsheet-database hybrid with API and automations) but lacks structured accounting features (double-entry, tax reporting, invoicing). Data should be exported from Grist (CSV/Excel) and migrated into Akaunting and InvenTree as part of the initial setup.

---

## Deployment Plan

### Phase 1: Foundation
- [ ] Stand up InvenTree + PostgreSQL (Docker Compose)
- [ ] Stand up Akaunting + MariaDB (Docker Compose)
- [ ] Stand up n8n + PostgreSQL (Dler Compose)
- [ ] Configure network/connectivity between containers
- [ ] Set up reverse proxy (Traefik/Nginx/Caddy) with TLS

### Phase 2: Data Migration
- [ ] Export data from Grist (CSV)
- [ ] Import product/part catalog into InvenTree
- [ ] Import existing stock quantities into InvenTree
- [ ] Set up chart of accounts in Akaunting
- [ ] Import existing transactions/balances into Akaunting

### Phase 3: MCP Setup
- [ ] Build and deploy inventree-mcp server
- [ ] Build Akaunting MCP wrapper (or use n8n AI nodes as the interface)
- [ ] Wire up MCP servers to LLM agents (Claude Desktop, etc.)

### Phase 4: n8n Workflows
- [ ] Configure Amazon SP-API credentials and build order polling workflow
- [ ] Configure eBay API credentials and build order polling workflow
- [ ] Build order → inventory + accounting sync workflows
- [ ] Build bank CSV import workflow
- [ ] Build reorder alert workflow
- [ ] Test end-to-end order flow with real orders

### Phase 5: Integration & Testing
- [ ] End-to-end test: marketplace order → InvenTree stock deduction → Akaunting revenue entry
- [ ] LLM agent test: natural language queries against inventory and finances
- [ ] Monitor and refine workflows

---

## Key Decisions & Rationale

| Decision | Choice | Why |
|----------|--------|-----|
| Inventory | InvenTree over OpenOMS | Production-stable, excellent MCP server, perfect for hardware/parts tracking |
| Bookkeeping | Akaunting over Actual Budget | Akaunting is business-oriented (invoicing, double-entry, tax). Actual Budget is personal envelope budgeting |
| Automation | n8n over custom scripts | Visual workflow builder, native marketplace nodes, AI agent nodes, mature ecosystem |
| Bank sync | CSV via n8n over Plaid/OpenFinance | Avoid SaaS dependency and cost. Upgrade to OpenFinance later if needed |
| All-in-one ERP | Rejected Odoo | Community edition paywalls key features (double-entry accounting, marketplace connectors). Enterprise is per-user paid |
| Spreadsheet DB | Migrate off Grist | Grist is great for prototyping but lacks structured accounting/inventory features |

---

## Open Questions

- Amazon SP-API: Need to set up AWS seller credentials and register a selling application. Any existing Seller Central account?
- eBay API: Need OAuth credentials (Client ID + Secret) from eBay Developer Portal.
- Bank CSV format: Which banks? Need to know the CSV/OFX format for n8n parser.
- Existing Grist data: What tables/schemas are currently in use?
- Reverse proxy: What's the current homelab DNS/reverse proxy setup?
- Current homelab infrastructure: Proxmox? Docker Swarm? Kubernetes? Plain Docker Compose?