#!/usr/bin/env bash
# Render encrypted secrets/<service>.env.sops -> stacks/<service>/.env for Compose.
# The .env files are gitignored. Requires `sops` + an age key.
#
#   SOPS_AGE_KEY_FILE=secrets/age.key scripts/render-env.sh
#
# Optional: pass service names to render only those (e.g. `render-env.sh inventree n8n`).
set -euo pipefail

cd "$(dirname "$0")/.."

shopt -s nullglob
targets=("$@")

render() {
  local sops_file="$1"
  local svc
  svc="$(basename "$sops_file" .env.sops)"
  local dest="stacks/${svc}"
  if [[ ! -d "$dest" ]]; then
    echo "skip ${svc}: no stack dir at ${dest}" >&2
    return 0
  fi
  sops -d --input-type dotenv --output-type dotenv "$sops_file" > "${dest}/.env"
  echo "rendered ${dest}/.env"
}

if [[ ${#targets[@]} -gt 0 ]]; then
  for svc in "${targets[@]}"; do
    f="secrets/${svc}.env.sops"
    [[ -f "$f" ]] && render "$f" || echo "no secret file for ${svc}" >&2
  done
else
  for f in secrets/*.env.sops; do
    render "$f"
  done
fi
