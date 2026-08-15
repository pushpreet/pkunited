# Business Services Authentication Runbook

## Goal

All business services share the same Authelia + LLDAP identity. Each person has one
LLDAP account and gets per-user identity inside every app. Access is gated by a dedicated
`pku_users` LLDAP group. Local break-glass accounts bypass SSO entirely.

**Users:**
| Person | LLDAP uid | Email | Groups |
|--------|-----------|-------|--------|
| You (admin) | `pushprh` | hanspal.pushpreet@gmail.com | `homelab_admins`, `pku_users` |
| Business partner | `kavneet` | hanspal.kavneet@gmail.com | `pku_users` |

**Break-glass:** Local accounts (`pku`) in each app, NOT in LLDAP/Authelia. Password stored
in `secrets/<svc>.env.sops`. To use: temporarily remove the auth layer (Caddy
forward_auth) and log in locally.

---

## Architecture

```
Browser
  │
  ▼
Edge Caddy (core-infra)
  │
  └─→ Business Caddy (10.37.20.70:9443)
        │
        └─ n8n.pushprh.com        ──→ forward_auth → Authelia → n8n:5678
                                   (except /webhook/* — no auth)
```

All auth is handled by Caddy `forward_auth` to the local Authelia instance on the
business VM. Authelia reads LLDAP on core-infra (`10.37.20.10:3890`) for authentication.
No OIDC clients. No per-app auth config. No middleware. No bolt-ons.

Auth session cookie domain-scoped to `pushprh.com` — one login covers all services.

---

## Prerequisites — LLDAP Setup

One-time, in the LLDAP web UI (`users.pushprh.com`):

1. **Groups → Create**: `pku_users`
2. **Users → kavneet**: Create (uid=`kavneet`, email=`hanspal.kavneet@gmail.com`, set password)
3. **Users → kavneet**: Add to groups `pku_users` (and `homelab_users` for baseline homelab access)
4. **Users → pushprh**: Add to group `pku_users` (already in `homelab_admins`)

You set kavneet's password yourself in the LLDAP UI.

---

## Authelia Configuration

Authelia runs as a container in `stacks/authelia/` on the business VM. It reads:

- **LDAP backend:** `ldap://10.37.20.10:3890` (core-infra LLDAP, read-only)
- **Access control:** Domain-based rules — `n8n.pushprh.com` uses `one_factor`
- **Session cookie:** Domain `pushprh.com`, shared across all subdomains
- **Storage:** Local SQLite at `/data/db.sqlite3`
- **Notifier:** Filesystem (no email needed — password reset handled directly in LLDAP)

Secrets in `secrets/authelia.env.sops`:
- `AUTHELIA_SESSION_SECRET` — session encryption key
- `AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD` — LLDAP admin bind password (same value used by core-infra Authelia)

Full configuration in `stacks/authelia/config/configuration.yml`.

---

## Break-Glass Access

Each app has a local `pku` account for emergency access when SSO is down:

| Service | Break-glass user | How to access |
|---------|-----------------|---------------|
| n8n | `pku@pushprh.com` (Owner) | Remove forward_auth from Caddy, login at `/signin?showLogin=true`, restore forward_auth |

Break-glass passwords are stored in `secrets/<svc>.env.sops`.

---

## Post-Deploy Checklist

After initial deployment of all services:

1. **Verify SSO works:** Visit `https://n8n.pushprh.com` → Authelia login → n8n
2. **Verify n8n webhooks bypass auth:** External webhooks to `https://n8n.pushprh.com/webhook/*` should work without authentication
3. **Set up break-glass account:** Create local `pku` account in n8n UI (before forward_auth is fully active, or by temporarily disabling it)
4. **Verify kavneet access:** Test login as kavneet (should have `pku_users` access, not admin)
