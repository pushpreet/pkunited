# pkunited — Business services deployment. Run `just` to list recipes.
# Requires: just, sops (+ age key for secrets), ssh.

export SOPS_AGE_KEY_FILE := env_var_or_default("SOPS_AGE_KEY_FILE", "secrets/age.key")

# SSH target: business VM only (no core-infra)
business := env_var_or_default("BUSINESS_SSH", "root@10.37.20.70")
deploy_key := env_var_or_default("BUSINESS_KEY", "secrets/pkunited_deploy_ed25519")

# Where compose stacks are deployed on the business VM
stacks_root := "/opt/stacks"

# Deployment order: infra first, then apps
stacks_list := "caddy erpnext n8n"

# List recipes
default:
    @just --list

# --- Secrets ---

# Decrypt all secrets into each stack's .env
secrets:
    @scripts/render-env.sh

# Edit an encrypted secret file in place (e.g. just sops-edit n8n)
sops-edit service:
    sops --input-type dotenv --output-type dotenv secrets/{{service}}.env.sops

# Encrypt a plaintext dotenv into secrets/<service>.env.sops
sops-new service src:
    @test -f "{{src}}" || { echo "no such file: {{src}}" >&2; exit 1; }
    @test -e "secrets/{{service}}.env.sops" && { echo "secrets/{{service}}.env.sops already exists — use 'just sops-edit {{service}}'" >&2; exit 1; } || \
    sops --input-type dotenv --output-type dotenv \
         --filename-override "secrets/{{service}}.env.sops" \
         -e "{{src}}" > "secrets/{{service}}.env.sops" && \
    echo "wrote secrets/{{service}}.env.sops — now shred the plaintext: shred -u {{src}}"

# --- Validation ---

# Render secrets, then validate every compose stack (no deploy)
validate: secrets
    @for d in stacks/caddy stacks/erpnext stacks/n8n; do \
      if [ -f "$d/docker-compose.yml" ]; then \
        echo "== validating $d =="; \
        (cd "$d" && docker compose config -q); \
      fi; \
    done && echo "all stacks valid"

# --- Deployment ---

# Deploy a single stack to the business VM
deploy-stack +stack:
    @just secrets
    @test -d "stacks/{{stack}}" || { echo "no stack dir: stacks/{{stack}}" >&2; exit 1; }
    @echo "==> syncing {{stack}} to business VM"
    @rsync -az --mkpath \
        -e "ssh -i {{deploy_key}} -o StrictHostKeyChecking=no" \
        "stacks/{{stack}}/" "{{business}}:{{stacks_root}}/{{stack}}/"
    @echo "==> deploying {{stack}}"
    @ssh -i {{deploy_key}} -o StrictHostKeyChecking=no {{business}} \
        "cd {{stacks_root}}/{{stack}} && docker compose up -d --remove-orphans"
    @echo "==> {{stack}} deployed"

# Deploy all stacks to the business VM
deploy: secrets
    @echo "==> syncing stacks to business VM"
    @for stack in {{stacks_list}}; do \
      if [ -d "stacks/$stack" ]; then \
        echo "  syncing $stack..."; \
        rsync -az --mkpath \
          -e "ssh -i {{deploy_key}} -o StrictHostKeyChecking=no" \
          "stacks/$stack/" "{{business}}:{{stacks_root}}/$stack/"; \
      fi; \
    done
    @echo "==> deploying stacks on business VM"
    @ssh -i {{deploy_key}} -o StrictHostKeyChecking=no {{business}} \
        'for stack in {{stacks_list}}; do \
          d="{{stacks_root}}/$stack"; \
          [ -d "$d" ] || continue; \
          echo "  deploying $stack..."; \
          cd "$d" && docker compose up -d --remove-orphans; \
        done'
    @echo "==> all done"

# Tail one stack's logs
stack-logs stack tail="200":
    ssh -i {{deploy_key}} -t -o StrictHostKeyChecking=no {{business}} \
        "cd {{stacks_root}}/{{stack}} && docker compose logs --tail {{tail}} -f"

# Stop one stack's containers (volumes preserved)
stack-down stack:
    ssh -i {{deploy_key}} -t -o StrictHostKeyChecking=no {{business}} \
        "cd {{stacks_root}}/{{stack}} && docker compose down"

# RETIRE a stack: stop it, drop volumes, remove stack dir
# Does NOT touch /opt/appdata/<stack>
stack-purge stack:
    @echo "==> purging stack '{{stack}}' on business VM"
    @ssh -i {{deploy_key}} -o StrictHostKeyChecking=no {{business}} \
        "test -d {{stacks_root}}/{{stack}} && cd {{stacks_root}}/{{stack}} && docker compose down -v --remove-orphans || echo 'no stack dir'"
    @ssh -i {{deploy_key}} -o StrictHostKeyChecking=no {{business}} \
        "rm -rf {{stacks_root}}/{{stack}}"
    @echo "==> removed {{stacks_root}}/{{stack}} (appdata left intact)"

# Application-consistent DB dumps
backup-dumps:
    @ts="$$(date +%Y%m%d-%H%M%S)" && \
    echo "==> dumping n8n (PostgreSQL)..." && \
    ssh -t -i {{deploy_key}} -o StrictHostKeyChecking=no {{business}} \
      "docker exec n8n-db pg_dump -U $$(grep N8N_DB_USER .env | cut -d= -f2) $$(grep N8N_DB_NAME .env | cut -d= -f2) > /opt/appdata/n8n/backups/n8n-$$ts.sql" && \
    echo "==> dumping erpnext (MariaDB)..." && \
    ssh -t -i {{deploy_key}} -o StrictHostKeyChecking=no {{business}} \
      "cd {{stacks_root}}/erpnext && docker exec erpnext-db mysqldump -u root -p$$(grep DB_PASSWORD .env | cut -d= -f2) --all-databases > /opt/appdata/erpnext/backups/erpnext-$$ts.sql" && \
    echo "==> dumps complete (restic will pick them up)"

# SSH into the business VM
ssh:
    ssh -i {{deploy_key}} -t -o StrictHostKeyChecking=no {{business}}
