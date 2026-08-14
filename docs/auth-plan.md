# Business Services Authentication Plan

## Goal

All three business services share the same Authelia + LLDAP identity. Each person has one
LLDAP account and gets per-user identity inside every app. Access is gated by a dedicated
`pku_users` LLDAP group. Local break-glass accounts bypass SSO entirely.

**Users:**
| Person | LLDAP uid | Email | Groups |
|--------|-----------|-------|--------|
| You (admin) | `pushprh` | hanspal.pushpreet@gmail.com | `homelab_admins`, `pku_users` |
| Business partner | `kavneet` | hanspal.kavneet@gmail.com | `pku_users` |

**Break-glass:** Local accounts (`pku`) in each app, NOT in LLDAP/Authelia. Password stored
in `psx-homelab/secrets/<svc>.env.sops`. To use: temporarily remove the auth layer (Caddy
forward_auth or n8n-oidc) and log in locally.

---

## Summary

| Service | Approach | Per-user? | Break-glass |
|---------|----------|-----------|-------------|
| **InvenTree** | Native OIDC SSO to Authelia (django-allauth) | ✅ JIT + group sync | Local superuser `pku` |
| **n8n** | [n8n-oidc](https://github.com/cweagans/n8n-oidc) bolt-on (latest `main`) | ✅ JIT, first login = owner | Local user `pku` via `?showLogin=true` |
| **Akaunting** | Caddy forward_auth + custom Laravel middleware | ✅ JIT from Authelia headers | Local user `pku` (remove forward_auth temporarily) |

---

## Architecture

```
Browser
  │
  ▼
Caddy (core-infra, 10.37.20.10) — both Caddy and Authelia on "edge" Docker network
  │
  ├── inventree.pushprh.com ──→ 10.37.20.70:8080
  │                            InvenTree OIDC → Authelia (business policy)
  │
  ├── accounts.pushprh.com ──→ forward_auth http://authelia:9091
  │                            (service=business policy, sets Remote-* headers)
  │                            └─→ 10.37.20.70:8081
  │                               Akaunting middleware → JIT creates/logs in user
  │
  └── n8n.pushprh.com ──────→ 10.37.20.70:5678
                              n8n-oidc → Authelia (business policy)
                              (/webhook/* works without auth)
```

Auth session cookie domain-scoped to `pushprh.com` — one login covers all services.

---

## 0. Prerequisites — LLDAP Setup

One-time, in the LLDAP web UI (`users.pushprh.com`):

1. **Groups → Create**: `pku_users`
2. **Users → kavneet**: Create (uid=`kavneet`, email=`hanspal.kavneet@gmail.com`, set password)
3. **Users → kavneet**: Add to groups `pku_users` (and `homelab_users` for baseline homelab access)
4. **Users → pushprh**: Add to group `pku_users` (already in `homelab_admins`)

You set kavneet's password yourself in the LLDAP UI.

---

## 1. InvenTree — Native OIDC SSO

### 1A. Authelia — new `business` authorization policy + `inventree` OIDC client

File: `psx-homelab/stacks/authelia/config/configuration.yml`

Add under `identity_providers.oidc.authorization_policies`:

```yaml
      # Business services: only pku_users (and global admins) get access.
      business:
        default_policy: 'deny'
        rules:
          - policy: 'two_factor'
            subject: ['group:homelab_admins']
          - policy: 'one_factor'
            subject: ['group:pku_users']
```

Add under `identity_providers.oidc.clients` (after existing clients):

```yaml
      - client_id: 'inventree'
        client_name: 'InvenTree'
        client_secret: '{{ env "OIDC_INVENTREE_CLIENT_SECRET_DIGEST" }}'
        public: false
        authorization_policy: 'business'
        consent_mode: 'implicit'
        token_endpoint_auth_method: 'client_secret_basic'
        redirect_uris:
          - 'https://inventree.pushprh.com/accounts/oidc/login/callback/'
        scopes: ['openid', 'profile', 'email', 'groups']
        userinfo_signed_response_alg: 'none'
```

### 1B. Authelia secrets

File: `psx-homelab/secrets/authelia.env.sops`
Add:
```bash
OIDC_INVENTREE_CLIENT_SECRET_DIGEST=  # PBKDF2 hash from gen-auth-secrets.sh
```

### 1C. InvenTree compose changes

File: `pkunited/stacks/inventree/docker-compose.yml`
Add under InvenTree service `environment`:

```yaml
      # --- SSO (Authelia OIDC via django-allauth) ---
      INVENTREE_SOCIAL_BACKENDS: '["allauth.socialaccount.providers.openid_connect"]'
      INVENTREE_SOCIAL_PROVIDERS: |-
        {
          "openid_connect": {
            "bitbucket": {
              "server_url": "https://auth.pushprh.com/.well-known/openid-configuration"
            }
          }
        }
      INVENTREE_LOGIN_DEFAULT_HTTP_PROTOCOL: 'https'
```

### 1D. InvenTree secrets

File: `psx-homelab/secrets/inventree.env.sops`
Add:
```bash
INVENTREE_OIDC_CLIENT_SECRET=       # plaintext from gen-auth-secrets.sh
INVENTREE_BREAKGLASS_PASSWORD=      # openssl rand -base64 32 (for local pku account)
```

### 1E. Post-deploy admin setup (InvenTree web UI)

After deploying, log into InvenTree as the existing superuser:

1. **Admin → Social Applications → Add**:
   - Provider: `OpenID Connect`
   - Name: `bitbucket`
   - Client id: `inventree`
   - Secret: `INVENTREE_OIDC_CLIENT_SECRET` from secrets
   - Sites: `inventree.pushprh.com`
2. **Settings → Login Settings**:
   - Enable SSO: ✅
   - Auto-fill SSO users: ✅
   - Enable SSO group sync: ✅
   - SSO group key: `groups`
   - SSO group map: `{"homelab_admins": "Administrators", "pku_users": "Staff"}`
3. **Create local break-glass user**: Admin → Users → Add, username=`pku`,
   password=`INVENTREE_BREAKGLASS_PASSWORD`, superuser=✅, staff=✅

### 1F. Caddy — no change

The existing `inventree.pushprh.com` reverse_proxy route is sufficient.

---

## 2. n8n — OIDC via n8n-oidc Bolt-on

### 2A. Authelia — new `n8n` OIDC client

File: `psx-homelab/stacks/authelia/config/configuration.yml`
Add under `identity_providers.oidc.clients`:

```yaml
      - client_id: 'n8n'
        client_name: 'n8n'
        client_secret: '{{ env "OIDC_N8N_CLIENT_SECRET_DIGEST" }}'
        public: false
        authorization_policy: 'business'
        consent_mode: 'implicit'
        token_endpoint_auth_method: 'client_secret_basic'
        redirect_uris:
          - 'https://n8n.pushprh.com/auth/oidc/callback'
        scopes: ['openid', 'profile', 'email']
        userinfo_signed_response_alg: 'none'
```

### 2B. Authelia secrets

File: `psx-homelab/secrets/authelia.env.sops`
Add:
```bash
OIDC_N8N_CLIENT_SECRET_DIGEST=  # PBKDF2 hash from gen-auth-secrets.sh
```

### 2C. Download n8n-oidc hooks.js (latest main)

```bash
mkdir -p pkunited/stacks/n8n/oidc
curl -sL https://raw.githubusercontent.com/cweagans/n8n-oidc/main/hooks.js \
  -o pkunited/stacks/n8n/oidc/hooks.js
```

### 2D. n8n compose changes

File: `pkunited/stacks/n8n/docker-compose.yml`

Add under n8n service `environment`:
```yaml
      # --- OIDC SSO (n8n-oidc bolt-on) ---
      N8N_ADDITIONAL_NON_UI_ROUTES: 'auth'
      N8N_TRUST_PROXY: 'true'
      EXTERNAL_HOOK_FILES: '/app/oidc/hooks.js'
      EXTERNAL_FRONTEND_HOOKS_URLS: '/assets/oidc-frontend-hook.js'
      OIDC_ISSUER_URL: 'https://auth.pushprh.com'
      OIDC_CLIENT_ID: 'n8n'
      OIDC_CLIENT_SECRET: '${N8N_OIDC_CLIENT_SECRET}'
      OIDC_REDIRECT_URI: 'https://n8n.pushprh.com/auth/oidc/callback'
```

Add to n8n service `volumes`:
```yaml
      - ./oidc/hooks.js:/app/oidc/hooks.js:ro
```

### 2E. n8n secrets

File: `psx-homelab/secrets/n8n.env.sops`
Add:
```bash
N8N_OIDC_CLIENT_SECRET=            # plaintext from gen-auth-secrets.sh
N8N_BREAKGLASS_PASSWORD=           # openssl rand -base64 32 (for local pku account)
```

### 2F. Caddy — no change

n8n-oidc handles OIDC internally. Webhooks (`/webhook/*`) work without auth.

### 2G. Post-deploy

1. **You log in first** via SSO at `n8n.pushprh.com` → becomes owner.
2. **Create local break-glass user** in n8n UI: Settings → Users → Add,
   username=`pku@pushprh.com`, password=`N8N_BREAKGLASS_PASSWORD`, role=Owner.
   Access via `n8n.pushprh.com/signin?showLogin=true`.

---

## 3. Akaunting — Pre-auth Middleware (Option A)

Caddy forward_auth authenticates via Authelia (`service=business` policy) and passes
identity headers. Custom Laravel middleware JIT-creates/logs in the Akaunting user.

### 3A. Caddy — forward_auth with identity headers

File: `psx-homelab/stacks/caddy/Caddyfile`
Replace the existing `accounts.pushprh.com` block:

```caddy
http://accounts.pushprh.com, https://accounts.pushprh.com {
    forward_auth http://authelia:9091 {
        uri /api/authz/forward-auth?service=business&rd=https://auth.pushprh.com
        copy_headers Remote-User Remote-Email Remote-Groups Remote-Name
    }
    reverse_proxy 10.37.20.70:8081
}
```

The `service=business` query param tells Authelia to use the `business` authorization
policy (only `pku_users` + `homelab_admins`).

### 3B. Akaunting middleware

File: `pkunited/stacks/akaunting/pre-auth-middleware.php`

```php
<?php
/**
 * Pre-auth middleware for Akaunting.
 *
 * Reads Authelia headers (set by Caddy forward_auth) and auto-creates/logs in
 * the Akaunting user. If no Remote-User header is present (e.g., API calls,
 * initial setup, or break-glass mode), passes through to normal auth.
 */

use Illuminate\Support\Facades\Auth;
use Akaunting\Users\Models\User;
use Illuminate\Support\Str;

return function ($request, $next) {
    $uid = $request->header('Remote-User');

    if (!$uid) {
        return $next($request);
    }

    $email = $request->header('Remote-Email', $uid . '@pushprh.com');
    $name  = $request->header('Remote-Name', $uid);

    $user = User::where('email', $email)->first();

    if (!$user) {
        $user = User::create([
            'user_key'          => $uid,
            'email'             => $email,
            'name'              => $name,
            'password'          => bcrypt(Str::random(40)),
            'login_attempts'    => 0,
            'login_strict'      => 0,
            'email_verified_at' => now(),
        ]);

        $groups = array_filter(array_map('trim', explode(',', $request->header('Remote-Groups', ''))));
        if (in_array('homelab_admins', $groups)) {
            $user->addRole(1); // admin role
        }
    }

    Auth::login($user, true);

    return $next($request);
};
```

### 3C. Akaunting preload bootstrap

File: `pkunited/stacks/akaunting/pre-auth-load.php`

```php
<?php
/**
 * APP_PRELOAD entry point — registers pre-auth middleware before the app boots.
 */

$app = require_once __DIR__ . '/bootstrap/app.php';

$app->booting(function ($app) {
    $kernel = $app->make(Illuminate\Contracts\Http\Kernel::class);

    if ($kernel && method_exists($kernel, 'pushMiddleware')) {
        $middleware = require __DIR__ . '/pre-auth-middleware.php';
        $kernel->pushMiddleware($middleware);
    }
});
```

### 3D. Akaunting compose changes

File: `pkunited/stacks/akaunting/docker-compose.yml`

Add to volumes:
```yaml
      - ./pre-auth-middleware.php:/var/www/html/pre-auth-middleware.php:ro
      - ./pre-auth-load.php:/var/www/html/pre-auth-load.php:ro
```

Add to environment:
```yaml
      APP_PRELOAD: '/var/www/html/pre-auth-load.php'
```

### 3E. Akaunting secrets

File: `psx-homelab/secrets/akaunting.env.sops`
Add:
```bash
AKAUNTING_BREAKGLASS_PASSWORD=  # openssl rand -base64 32 (for local pku account)
```

### 3F. Post-deploy break-glass

1. Create local Akaunting admin account (username=`pku`, password=`AKAUNTING_BREAKGLASS_PASSWORD`)
   during initial setup (before forward_auth is deployed, or by temporarily removing it from Caddy).
2. To use break-glass: remove the `forward_auth` block from Caddy, redeploy, log in as `pku`,
   fix the issue, restore the `forward_auth` block, redeploy Caddy.

### 3G. Fallback — Option B

If Option A middleware breaks on an Akaunting upgrade:
1. Keep Caddy forward_auth as-is (auth gate only)
2. Create local Akaunting accounts for `pushprh` and `kavneet`
3. Each user: Authelia login → then Akaunting local login (two passwords)

---

## Rollout Plan

### Phase 0: LLDAP users ✅ DONE

| Step | Action | Status |
|------|--------|--------|
| 1 | Create group `pku_users` (id 8) | ✅ Done |
| 2 | `kavneet` user exists (email: hanspal.kavneet@gmail.com) | ✅ Exists |
| 3 | `kavneet` in `pku_users` + `homelab_users` + `llm_users` | ✅ Done |
| 4 | `pushprh` in `pku_users` (+ already in `homelab_admins`) | ✅ Done |

### Phase 1: Authelia OIDC clients (I implement)

| Step | Action | Files |
|------|--------|-------|
| 1 | Run `gen-auth-secrets.sh` → get `inventree` + `n8n` secrets | `psx-homelab/scripts/` |
| 2 | Add `business` authorization policy | `psx-homelab/stacks/authelia/config/configuration.yml` |
| 3 | Add `inventree` + `n8n` OIDC clients | `psx-homelab/stacks/authelia/config/configuration.yml` |
| 4 | Add digests to authelia.env.sops | `psx-homelab/secrets/authelia.env.sops` |
| 5 | Deploy Authelia | `just deploy-host core` |

### Phase 2: InvenTree SSO (I implement)

| Step | Action | Files |
|------|--------|-------|
| 1 | Add SSO env vars to compose | `pkunited/stacks/inventree/docker-compose.yml` |
| 2 | Add secrets (OIDC + break-glass password) | `psx-homelab/secrets/inventree.env.sops` |
| 3 | Deploy InvenTree | `just deploy-stack business inventree` |
| 4 | **You:** Configure SocialApp + enable SSO in InvenTree UI | `inventree.pushprh.com` |
| 5 | **You:** Create local `pku` superuser in InvenTree | InvenTree Admin |

### Phase 3: n8n SSO (I implement, you login first)

| Step | Action | Files |
|------|--------|-------|
| 1 | Download `hooks.js` to `stacks/n8n/oidc/` | `pkunited/stacks/n8n/oidc/hooks.js` |
| 2 | Add OIDC env vars + volume mount to compose | `pkunited/stacks/n8n/docker-compose.yml` |
| 3 | Add secrets (OIDC + break-glass password) | `psx-homelab/secrets/n8n.env.sops` |
| 4 | Deploy n8n | `just deploy-stack business n8n` |
| 5 | **You:** Log in via SSO first (becomes owner) | `n8n.pushprh.com` |
| 6 | **You:** Create local `pku` user in n8n (role=Owner) | n8n Settings → Users |

### Phase 4: Akaunting pre-auth (I implement, you test)

| Step | Action | Files |
|------|--------|-------|
| 1 | Create `pre-auth-middleware.php` + `pre-auth-load.php` | `pkunited/stacks/akaunting/` |
| 2 | Add volume mounts + `APP_PRELOAD` to compose | `pkunited/stacks/akaunting/docker-compose.yml` |
| 3 | Add break-glass password to secrets | `psx-homelab/secrets/akaunting.env.sops` |
| 4 | Update Caddyfile with forward_auth | `psx-homelab/stacks/caddy/Caddyfile` |
| 5 | Deploy Caddy + Akaunting | `just deploy-stack core caddy` + `just deploy-stack business akaunting` |
| 6 | **You:** Test login at `accounts.pushprh.com` | Browser |
| 7 | If Option A fails → switch to Option B | — |

---

## Files Summary

### New files (pkunited)
| File | Purpose |
|------|---------|
| `pkunited/stacks/n8n/oidc/hooks.js` | n8n-oidc hooks (downloaded from cweagans/n8n-oidc main) |
| `pkunited/stacks/akaunting/pre-auth-middleware.php` | JIT user creation from Authelia headers |
| `pkunited/stacks/akaunting/pre-auth-load.php` | APP_PRELOAD bootstrap |

### Modified files (psx-homelab)
| File | Changes |
|------|---------|
| `psx-homelab/stacks/authelia/config/configuration.yml` | Add `business` policy + `inventree` + `n8n` OIDC clients |
| `psx-homelab/secrets/authelia.env.sops` | Add `OIDC_INVENTREE_CLIENT_SECRET_DIGEST` + `OIDC_N8N_CLIENT_SECRET_DIGEST` |
| `psx-homelab/secrets/inventree.env.sops` | Add `INVENTREE_OIDC_CLIENT_SECRET` + `INVENTREE_BREAKGLASS_PASSWORD` |
| `psx-homelab/secrets/n8n.env.sops` | Add `N8N_OIDC_CLIENT_SECRET` + `N8N_BREAKGLASS_PASSWORD` |
| `psx-homelab/secrets/akaunting.env.sops` | Add `AKAUNTING_BREAKGLASS_PASSWORD` |
| `psx-homelab/stacks/caddy/Caddyfile` | Add forward_auth to `accounts.pushprh.com` block |

### Modified files (pkunited)
| File | Changes |
|------|---------|
| `pkunited/stacks/inventree/docker-compose.yml` | Add SSO env vars |
| `pkunited/stacks/n8n/docker-compose.yml` | Add OIDC env vars + hooks.js volume |
| `pkunited/stacks/akaunting/docker-compose.yml` | Add middleware volumes + `APP_PRELOAD` |

### Modified docs
| File | Changes |
|------|---------|
| `pkunited/plan.md` | Mark open question #4 as resolved |

---

## What I Need From You Before I Start

**✅ Phases 1–4 are implemented AND deployed.** All services are healthy:
- `psx-homelab` branch `feature/business` — Authelia config + secrets + Caddyfile — ✅ Deployed
- `pkunited` branch `feature/auth` — compose changes + middleware + hooks.js — ✅ Deployed

**Services running:**
| Service | URL | Status |
|---------|-----|--------|
| Authelia | `https://auth.pushprh.com` | ✅ Healthy |
| Caddy | edge proxy on `core-infra` | ✅ Running |
| InvenTree | `https://inventree.pushprh.com` | ✅ Healthy |
| n8n | `https://n8n.pushprh.com` | ✅ Healthy |
| Akaunting | `https://accounts.pushprh.com` | ✅ Healthy |

You need to:
1. **Review & merge** the `feature/business` branch in `psx-homelab` and `feature/auth` branch in `pkunited`
2. **Do the post-deploy UI setup** (see below)

---

## Post-Deploy Steps (You)

All services are deployed and healthy. Do these in-browser setup tasks:

### Phase 2 — InvenTree

1. **Login as existing superuser** at `https://inventree.pushprh.com` (use your current InvenTree creds)
2. Go to **Admin → Social Applications → Add**:
   - Provider: `OpenID Connect`
   - Name: `bitbucket`
   - Client id: `inventree`
   - Secret: `bGt9SMDdXYOeomhJ~F.NWKl4Aigb4T4ouyto5DnrIqXZNDOsRwIBxNzJEahdXkt2mwzuYi.j`
   - Sites: `inventree.pushprh.com`
   - Save
3. Go to **Settings → Login Settings**:
   - Enable SSO: ✅
   - Auto-fill SSO users: ✅
   - Enable SSO group sync: ✅
   - SSO group key: `groups`
   - SSO group map: `{"homelab_admins": "Administrators", "pku_users": "Staff"}`
   - Save
4. Go to **Admin → Users → Add**:
   - Username: `pku`
   - Password: `h_ReQRXOfXNwlWdcyYouosVdpGf-Yjz_NZ2LcBXCNS8`
   - ✅ Superuser, ✅ Staff
   - Save

### Phase 3 — n8n

1. **You log in first** at `https://n8n.pushprh.com` via SSO (you become the owner)
2. After login, go to **Settings → Users → Add**:
   - Email: `pku@pushprh.com`
   - Password: `GBHqHX2ylwQWIKVme8GQZJWgaOkRGooGAxUp9ahK3OM`
   - Role: `Owner`
   - Save
   - Access later via `https://n8n.pushprh.com/signin?showLogin=true`

### Phase 4 — Akaunting

1. **First login creates admin (you're in homelab_admins):**
   - Visit `https://accounts.pushprh.com` → redirects to Authelia → login
   - After Authelia login, middleware JIT-creates you as admin (you're in `homelab_admins`)
   - You'll land in Akaunting as an admin user
2. **Verify SSO works:**
   - Check that you have admin access in Akaunting
   - Try the same flow with `kavneet` account (will get staff, not admin)
3. **Break-glass (if needed):**
   - Remove `forward_auth` block from Caddy temporarily
   - Login with: username `pku`, password `0w8JbwccLbTHbl1qpLcFh3OgVgoTwwmgxHCyNID16Mo=`
   - Restore `forward_auth` and reload Caddy
4. **If Option A fails** → switch to Option B: create local Akaunting accounts for `pushprh` and `kavneet`, each does Authelia login then local Akaunting login
