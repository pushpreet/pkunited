# pkunited — Project Rules & Guidelines

## What This Project Is

Self-hosted business services homelab stack: **InvenTree** (inventory), **Akaunting** (bookkeeping), **n8n** (automation/orchestration), **Caddy** (reverse proxy), **Cloudflared** (tunneling), and **Authelia** (SSO). Serves a small business selling hardware/electronics on Amazon and eBay.

## Security

- **Never echo, log, or print secrets or passwords.** This includes in `bash` commands, tool output, or chat.
- **Never ask the user for secrets or passwords in plaintext through chat.** If a secret is needed, instruct the user to add it to SOPS-encrypted files in `secrets/`.
- Edit secrets only via SOPS: `sops --input-type dotenv --output-type dotenv secrets/<svc>.env.sops` (or `--input-type json --output-type json` for `.json.sops`).
- `.env` files are gitignored and should never be committed. Secrets live as `*.sops` files in `secrets/`.

## Development Workflow

- **Use git worktrees for any non-trivial work.** Quick typo fixes can go directly to `main`, but anything with significance — new features, multi-file changes, architecture shifts — gets a worktree.
  ```bash
  git worktree add ../pkunited-<feature-name> -b <feature-name>
  ```
- **Write a planning doc for substantial work.** Store it in `.pi/plans/<plan-name>.md` (gitignored). List the tasks, file changes, and expected impact. Mark items done as you complete them. Delete the plan once the work is merged.
- **Commit frequently in the worktree** — each logical unit of work gets its own commit.
- **Squash on merge back to `main`.** When the worktree is done, merge with `--squash` so `main` gets one clean, logical commit:
  ```bash
  git checkout main
  git merge --squash <feature-name>
  git commit -m "concise description of the change"
  git worktree remove ../pkunited-<feature-name>
  git branch -d <feature-name>
  ```

## Deployment

pkunited owns its own deployment pipeline. The business VM (`10.37.20.70`) is provisioned
by `psx-homelab` (Ansible base + docker roles), then pkunited deploys all stacks into it:
Caddy (entry point + auth), Authelia (SSO), and the three apps.

Run `just` in pkunited to see available recipes. Key commands:
- `just validate` — render secrets, validate all compose files
- `just deploy` — full deploy (secrets → stacks on business VM)
- `just deploy-stack <svc>` — deploy single stack
- `just stack-logs <svc>` — tail logs
- `just stack-down <svc>` — stop a stack
- `just secrets` — render SOPS → .env
- `just sops-edit <svc>` — edit encrypted secret
- `just backup-dumps` — application-consistent DB dumps

No core-infra SSH. No config fragments. No OIDC client management.
See `CONTRACT.md` for the interface with psx-homelab.

## Validation

- **Always validate Docker Compose files** before suggesting or applying changes. Use `docker compose -f stacks/<svc>/docker-compose.yml config` to check for errors.

## Documentation

- **Always update `docs/` when code or infrastructure changes.** If a change affects how the system works, what the services do, or deployment procedures, the relevant doc must be updated in the same change.

## Change Approval

- **Ask before running any destructive commands** (e.g., `stack-purge`, `docker rm -f`, `git reset --hard`, deleting files/directories).
- **For complex changes, propose a plan first.** Lay out the steps, file changes, and expected impact. Wait for the user to approve the plan before making any writes.

## Project Structure

```
stacks/          — Docker Compose stacks per service
  <service>/     — docker-compose.yml, Caddyfiles, scripts, config
secrets/         — SOPS-encrypted .env files (age-encrypted)
docs/            — Architecture plans, integration designs, auth plans
.pi/plans/       — Working planning documents (gitignored, deleted on completion)
.sops.yaml       — SOPS encryption config (age keys)
CONTRACT.md      — Interface with psx-homelab
AGENTS.md        — This file (project rules for the coding agent)
```