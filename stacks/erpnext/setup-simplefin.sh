#!/usr/bin/env bash
# One-time (idempotent): install the sync_simplefin app on the live site.
# The app is baked into the custom image (stacks/erpnext/Dockerfile); this
# registers it on the site: doctypes (SimpleFIN Connection, SimpleFIN Account
# Mapping, SimpleFIN Balance Snapshot, SimpleFIN Sync Log, SimpleFIN Sync
# Settings), custom fields on Bank Transaction, dedup index. Re-runs no-op.
# Run on the business VM:  /opt/stacks/erpnext/setup-simplefin.sh
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a
: "${ERPNEXT_SITE_NAME:?missing ERPNEXT_SITE_NAME in .env}"
if ! docker exec erpnext-backend test -d "/home/frappe/frappe-bench/sites/${ERPNEXT_SITE_NAME}"; then
  echo "site ${ERPNEXT_SITE_NAME} not found on erpnext-backend" >&2
  exit 1
fi
# Frappe v16's file logger resolves ../logs relative to CWD (the bench dir
# here) = /home/frappe/logs, which this image does not create; make it first.
docker exec -i -e SITE="${ERPNEXT_SITE_NAME}" -w /home/frappe/frappe-bench erpnext-backend \
  sh -c 'set -e
mkdir -p /home/frappe/logs
if grep -q "\"sync_simplefin\"" "sites/$SITE/site_config.json"; then
  echo "sync_simplefin already installed on $SITE -- nothing to do"
  exit 0
fi
bench --site "$SITE" install-app sync_simplefin
echo "sync_simplefin installed on $SITE"'
