# Business VM Integration Design

## Architecture

All business services live on a single new Proxmox VM on VLAN 20 (services), managed the
same way as core-infra / media / llm:

```
┌───────────────────────────────────────────  business (10.37.20.70) ─────────────────────────────────────────┐
│                                                                                                             │
│  Edge Caddy (core-infra) → reverse_proxy 10.37.20.70:<port>                                                 │
│                                                                                                             │
│  inventree    → inventree.pushprh.com   (Django/Postgres, host port 8080)                                   │
│  akaunting    → accounts.pushprh.com    (Laravel/MariaDB, host port 8081)                                   │
│  n8n          → n8n.pushprh.com         (Node.js/Postgres, host port 5678)                                  │
│                                                                                                             │
│  DBs on local SSD: inventree-db (PostgreSQL 17), akaunting-db (MariaDB 11.3), n8n-db (PostgreSQL 17)       │
│  Appdata at /opt/appdata/<service>/                                                                         │
└─────────────────────────────────────────── business ────────────────────────────────────────────────────────┘
```

n8n reaches LiteLLM on epyc-server for LLM inference via LAN (`http://10.37.20.50:4000/v1`).
Same pattern the media VM uses for cross-host calls.

> **MCP servers (phase 2):** InvenTree MCP, Akaunting MCP, and n8n MCP deferred to a follow-up pass.
> Phase 1 delivers the three services with web UIs + REST APIs. LLM agents can interact via direct
> API calls or n8n webhook endpoints.

---

## VM Provisioning

**Sizing:** 4 vCPU / 8 GB RAM / 40 GB SSD on `local-zfs`
- InvenTree (Django + Postgres): ~2 GB
- Akaunting (PHP + MariaDB): ~1 GB
- n8n (Node.js + Postgres): ~2 GB
- OS + buffer: ~3 GB

Add to `host/provision-vms.sh` (same pattern as existing VMs):

```bash
local BUSINESS_VMID=910
local BUSINESS_MAC="BC:26:xx:xx:xx:70"
local BUSINESS_IP="10.37.20.70"

qm create ${BUSINESS_VMID} \
  --name business \
  --cores 4 --memory 8192 \
  --net0 virtio,bridge=vmbr2,macaddr=${BUSINESS_MAC} \
  --scsihw virtio,virtio-scsi-pci \
  --scsi0 local-zfs:40,import-from=template-clone \
  --boot c --bootdisk scsi0 \
  --agent enabled=1 \
  --ipconfig0 ip=${BUSINESS_IP}/24,gw=10.37.20.1 \
  --ciuser debian \
  --cipassword '<cloud-init-password>'
```

---

## Stack 1: InvenTree

### `stacks/inventree/docker-compose.yml`

```yaml
services:
  inventree:
    image: inventree/inventree:2.7.1
    container_name: inventree
    restart: unless-stopped
    env_file: .env
    environment:
      INVENTREE_DB_ENGINE: "postgresql"
      INVENTREE_DB_NAME: "${INVENTREE_DB_NAME}"
      INVENTREE_DB_HOST: "inventree-db"
      INVENTREE_DB_PORT: "5432"
      INVENTREE_DB_USER: "${INVENTREE_DB_USER}"
      INVENTREE_DB_PASSWORD: "${INVENTREE_DB_PASSWORD}"
      INVENTREE_EMAIL_BACKEND: "console"
      INVENTREE_MEDIA_ROOT: "/data/media"
      INVENTREE_STATIC_ROOT: "/data/static"
      INVENTREE_PLUGIN_ROOT: "/data/plugins"
      INVENTREE_SECRET_KEY: "${INVENTREE_SECRET_KEY}"
      INVENTREE_ALLOWED_HOSTS: "inventree.pushprh.com,inventree,localhost"
      INVENTREE_REQUIRE_AUTHENTICATION: "True"
      INVENTREE_LOGIN_ERROR_RATE_LIMIT: "3"
      INVENTREE_MEDIA_URL: "/media/"
      INVENTREE_STATIC_URL: "/static/"
      INVENTREE_TIMEZONE: "America/Los_Angeles"
      INVENTREE_BACKUP_ENABLED: "True"
      INVENTREE_BACKUP_DIR_NAME: "backups"
    volumes:
      - /opt/appdata/inventree/media:/data/media
      - /opt/appdata/inventree/static:/data/static
      - /opt/appdata/inventree/plugins:/data/plugins
      - /opt/appdata/inventree/backups:/data/backups
    ports:
      - "10.37.20.70:8080:8080"
    depends_on:
      inventree-db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health/')"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    networks:
      - businessnet
    security_opt:
      - no-new-privileges:true

  inventree-db:
    image: postgres:17.4
    container_name: inventree-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: "${INVENTREE_DB_USER}"
      POSTGRES_PASSWORD: "${INVENTREE_DB_PASSWORD}"
      POSTGRES_DB: "${INVENTREE_DB_NAME}"
    volumes:
      - /opt/appdata/inventree/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${INVENTREE_DB_USER} -d ${INVENTREE_DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - businessnet

networks:
  businessnet:
    driver: bridge
```

### `secrets/inventree.env.example`

```bash
INVENTREE_DB_NAME=inventree
INVENTREE_DB_USER=inv_user
INVENTREE_DB_PASSWORD=
INVENTREE_SECRET_KEY=
# Generated from InvenTree UI after initial setup (Settings → API Tokens)
# Used by n8n workflows to read/write inventory
INVENTREE_API_TOKEN=
```

---

## Stack 2: Akaunting

### `stacks/akaunting/docker-compose.yml`

```yaml
services:
  akaunting:
    image: akaunting/akaunting:3.1.31
    container_name: akaunting
    restart: unless-stopped
    env_file: .env
    environment:
      APP_URL: "https://accounts.pushprh.com"
      DB_HOST: "akaunting-db"
      DB_DATABASE: "${AKAUNTING_DB_NAME}"
      DB_USERNAME: "${AKAUNTING_DB_USER}"
      DB_PASSWORD: "${AKAUNTING_DB_PASSWORD}"
      APP_KEY: "${AKAUNTING_APP_KEY}"
    volumes:
      - /opt/appdata/akaunting/app:/var/www/html/app
      - /opt/appdata/akaunting/public:/var/www/html/public
      - /opt/appdata/akaunting/storage:/var/www/html/storage
    ports:
      - "10.37.20.70:8081:80"
    depends_on:
      akaunting-db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:80/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - businessnet
    security_opt:
      - no-new-privileges:true

  akaunting-db:
    image: mariadb:11.3
    container_name: akaunting-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "${AKAUNTING_DB_ROOT_PASSWORD}"
      MYSQL_DATABASE: "${AKAUNTING_DB_NAME}"
      MYSQL_USER: "${AKAUNTING_DB_USER}"
      MYSQL_PASSWORD: "${AKAUNTING_DB_PASSWORD}"
    volumes:
      - /opt/appdata/akaunting/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - businessnet

networks:
  businessnet:
    external: true
```

### `secrets/akaunting.env.example`

```bash
AKAUNTING_DB_NAME=akaunting
AKAUNTING_DB_USER=akaunting
AKAUNTING_DB_PASSWORD=
AKAUNTING_DB_ROOT_PASSWORD=
AKAUNTING_APP_KEY=
# API credentials for n8n workflows (generated from Akaunting UI: Settings → My Settings → API)
AKAUNTING_API_EMAIL=admin@pushprh.com
AKAUNTING_API_PASSWORD=
```

---

## Stack 3: n8n

### `stacks/n8n/docker-compose.yml`

```yaml
services:
  n8n:
    image: docker.n8n.io/n8n/n8n:1.101.2
    container_name: n8n
    restart: unless-stopped
    env_file: .env
    environment:
      N8N_EDITOR_BASE_URL: "https://n8n.pushprh.com"
      N8N_HOST: "n8n.pushprh.com"
      N8N_PORT: "5678"
      N8N_PROTOCOL: "https"
      N8N_SECURE_COOKIE: "true"
      N8N_DEFAULT_TIMEZONE: "America/Los_Angeles"
      DB_TYPE: "postgresdb"
      DB_POSTGRESDB_HOST: "n8n-db"
      DB_POSTGRESDB_PORT: "5432"
      DB_POSTGRESDB_DATABASE: "${N8N_DB_NAME}"
      DB_POSTGRESDB_USER: "${N8N_DB_USER}"
      DB_POSTGRESDB_PASSWORD: "${N8N_DB_PASSWORD}"
      N8N_ENCRYPTION_KEY: "${N8N_ENCRYPTION_KEY}"
      N8N_USER_MANAGEMENT_JWT_SECRET: "${N8N_JWT_SECRET}"
      N8N_USER_MANAGEMENT_MODE: "default"
      WEBHOOK_URL: "https://n8n.pushprh.com/"
      N8N_RUNNERS_ENABLED: "true"
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_PERSONALIZATION_ENABLED: "false"
      N8N_AI_ENABLED: "true"
      # Reaches LiteLLM on epyc-server over LAN — same as media VM cross-host calls
      N8N_LLM_PROVIDER_OPENAI_API_BASE: "http://10.37.20.50:4000/v1"
      N8N_LLM_PROVIDER_OPENAI_API_KEY: "${LITELLM_N8N_KEY}"
    volumes:
      - /opt/appdata/n8n:/home/node/.n8n
    ports:
      - "10.37.20.70:5678:5678"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - businessnet
    security_opt:
      - no-new-privileges:true

  n8n-db:
    image: postgres:17.4
    container_name: n8n-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: "${N8N_DB_USER}"
      POSTGRES_PASSWORD: "${N8N_DB_PASSWORD}"
      POSTGRES_DB: "${N8N_DB_NAME}"
    volumes:
      - /opt/appdata/n8n/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${N8N_DB_USER} -d ${N8N_DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - businessnet

networks:
  businessnet:
    external: true
```

### `secrets/n8n.env.example`

```bash
N8N_DB_NAME=n8n
N8N_DB_USER=n8n
N8N_DB_PASSWORD=
N8N_ENCRYPTION_KEY=
N8N_JWT_SECRET=
# Dedicated LiteLLM virtual key via seko-ai (model allowlist: [], monthly budget cap)
LITELLM_N8N_KEY=
```

---

## Core-infra Caddy Changes

Add to `stacks/caddy/Caddyfile` (proxies to the business VM by IP, same pattern as media VM):

```
# ---- Business VM (10.37.20.70) ----
http://inventree.pushprh.com, https://inventree.pushprh.com {
    reverse_proxy 10.37.20.70:8080
}
http://accounts.pushprh.com, https://accounts.pushprh.com {
    reverse_proxy 10.37.20.70:8081
}
http://n8n.pushprh.com, https://n8n.pushprh.com {
    reverse_proxy 10.37.20.70:5678
}
```

Deploy with: `just deploy-stack core caddy`

---

## Ansible Changes

### `ansible/inventory.yml` — add group:
```yaml
[business]
10.37.20.70
```

### `ansible/group_vars/business.yml` — new file:
```yaml
ansible_user: root
ansible_ssh_private_key_file: host/keys/deploy_ed25519

docker_distro: debian
docker_apt_suite: "trixie"

host_stacks:
  - inventree
  - akaunting
  - n8n
  - autoheal

appdata_owned_dirs:
  - inventree
  - akaunting
  - n8n

appdata_custom_owned_dirs:
  - { path: "inventree/postgres", owner: "70", group: "70" }
  - { path: "akaunting/mysql", owner: "999", group: "999" }
  - { path: "n8n/postgres", owner: "70", group: "70" }

backup_oncalendar: "*-*-* 02:30:00"
backup_packages: [sqlite3]
backup_paths:
  - /opt/appdata
backup_excludes:
  - "/opt/appdata/*/cache"
  - "/opt/appdata/*/log"
  - "**/*.log"
backup_predump:
  - "docker exec inventree-db pg_dump -U inv_user inventree > /opt/appdata/inventree/inventree.sql.bak"
  - "docker exec n8n-db pg_dump -U n8n n8n > /opt/appdata/n8n/n8n.sql.bak"
```

### `ansible/site.yml` — add play:
```yaml
- name: "Business host setup + stacks"
  hosts: business
  become: true
  roles:
    - base
    - docker
  tasks:
    - import_tasks: tasks/deploy_stacks.yml
      tags: stacks
```

---

## Rollout Order

| Phase | What | Deploy command |
|-------|------|----------------|
| 1 | Provision VM on Proxmox | Run `host/provision-vms.sh` from control machine |
| 2 | InvenTree + secrets | `just deploy-stack business inventree` |
| 3 | Akaunting + secrets | `just deploy-stack business akaunting` |
| 4 | n8n + LiteLLM key + secrets | `just deploy-stack business n8n` |
| 5 | Caddy routes on core-infra | `just deploy-stack core caddy` |
| 6 | n8n workflows (Amazon/eBay/bank) | In-browser n8n editor |
| 7 | Grist migration | CSV export/import |

---

## Open Questions

1. **VM sizing:** 4 vCPU / 8 GB RAM / 40 GB SSD — sufficient? Or bump to 6 vCPU / 16 GB?
2. **Backup target:** Restic → Azure (like core/media) or restic → NAS (like llm)?
3. **Monitoring:** Add business services to core-infra Prometheus/Grafana?
4. **Authelia SSO:** Should inventree/accounts/n8n go behind Authelia (existing LLDAP directory) or keep native login?
5. **Amazon Seller Central:** Existing SP-API developer profile? Need `seller_id`, `refresh_token`, AWS creds.
6. **eBay Developer:** OAuth `client_id` / `client_secret` from developer.ebay.com?
7. **Bank CSV format:** Which banks? Format determines the n8n parser.