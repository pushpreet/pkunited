#!/usr/bin/env bash
# ERPNext SSO setup tool (Authelia OIDC -> Frappe Social Login Key).
# Run on the business VM:  /opt/stacks/erpnext/setup-oidc.sh <upsert|migrate-user|promote-user [email] [roles...]>
#   upsert         — idempotently create/update the `authelia` Social Login Key doc
#   migrate-user   — one-time: rename the owner's ERPNext user to their LLDAP email
#                    (hpushpreet@gmail.com -> hanspal.pushpreet@gmail.com) so SSO maps to it;
#                    no-op if already done
#   promote-user   — turn an SSO-created (Website) user into a System User with business roles
#                    (SSO auto-creates Website Users; they can't use the desk until promoted)
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a
: "${ERPNEXT_SITE_NAME:?missing ERPNEXT_SITE_NAME in .env}"
if ! docker exec erpnext-backend test -d "/home/frappe/frappe-bench/sites/${ERPNEXT_SITE_NAME}"; then
  echo "site ${ERPNEXT_SITE_NAME} not found on erpnext-backend — create it first (docs/README.md 'Initial setup')" >&2
  exit 1
fi
cmd="${1:-}"; shift || true
case "$cmd" in
  upsert)
    : "${OIDC_CLIENT_ID:?missing OIDC_CLIENT_ID in .env}"
    : "${OIDC_CLIENT_SECRET:?missing OIDC_CLIENT_SECRET in .env}"
    ;;
  migrate-user) ;;
  promote-user)
    [ $# -ge 1 ] || { echo "usage: $0 promote-user <email> [roles...]" >&2; exit 2; }
    ;;
  *) echo "usage: $0 <upsert|migrate-user|promote-user [email] [roles...]>" >&2; exit 2 ;;
esac
export SETUP_CMD="$cmd"
if [ "$cmd" = upsert ]; then
  extra=(-e OIDC_CLIENT_ID -e OIDC_CLIENT_SECRET)
else
  extra=()
fi
# v16 Frappe's file logger writes to ../logs relative to the process CWD; ad-hoc exec
# contexts don't guarantee that dir, so this script routes logging to stderr (docker
# logs). The python below runs with the bench dir as CWD, like the web workers.
docker exec -i -w /home/frappe/frappe-bench \
  -e SETUP_CMD -e ERPNEXT_SITE_NAME "${extra[@]}" \
  erpnext-backend /home/frappe/frappe-bench/env/bin/python - "$@" <<'PY'
import logging
import os
import sys
import frappe
frappe.logger = lambda module=None, *a, **k: logging.getLogger(module or "frappe")
frappe.init(site=os.environ["ERPNEXT_SITE_NAME"], sites_path="/home/frappe/frappe-bench/sites")
frappe.connect()

cmd = os.environ["SETUP_CMD"]

if cmd == "upsert":
    FIELDS = {
        "provider_name": "Authelia",
        "social_login_provider": "Custom",
        "client_id": os.environ["OIDC_CLIENT_ID"],
        "client_secret": os.environ["OIDC_CLIENT_SECRET"],
        "base_url": "https://auth.pushprh.com",
        "custom_base_url": 1,
        "authorize_url": "/api/oidc/authorization",
        "access_token_url": "/api/oidc/token",
        "redirect_url": "/api/method/frappe.integrations.oauth2_logins.custom/authelia",
        "api_endpoint": "/api/oidc/userinfo",
        # response_type/scope match every built-in provider's auth_url_data convention.
        "auth_url_data": "{\"response_type\": \"code\", \"scope\": \"openid profile email\"}",
        "enable_social_login": 1,
        # Owner decision: do NOT deny by default — unknown pku_users members are
        # auto-created as Website Users (Frappe hardcodes that type for SSO signups;
        # promote-user upgrades them). See provider_allows_signup().
        "sign_ups": "Allow",
    }
    try:
        doc = frappe.get_doc("Social Login Key", "authelia")
    except frappe.DoesNotExistError:
        doc = frappe.new_doc("Social Login Key")
    for k, v in FIELDS.items():
        doc.set(k, v)
    doc.flags.ignore_permissions = True
    if doc.is_new():
        doc.name = "authelia"  # == scrub(provider_name); set explicitly for determinism
        doc.insert(ignore_permissions=True)
    else:
        doc.save()
    frappe.db.commit()
    print("Social Login Key upserted:", frappe.db.get_value(
        "Social Login Key", "authelia",
        ["provider_name", "client_id", "base_url", "authorize_url", "access_token_url",
         "redirect_url", "api_endpoint", "enable_social_login", "sign_ups"], as_dict=True))

elif cmd == "migrate-user":
    # One-time: owner's current ERPNext account -> their LLDAP email, so SSO maps onto it.
    # rename_doc updates owner/modified_by in every table, sets email = new name,
    # and clears the user's sessions. Password hash and roles are preserved.
    OLD, NEW = "hpushpreet@gmail.com", "hanspal.pushpreet@gmail.com"
    old_exists = frappe.db.exists("User", OLD)
    new_exists = frappe.db.exists("User", NEW)
    if not old_exists and new_exists:
        print(f"already migrated: {NEW} exists")
    elif not old_exists:
        print(f"nothing to do: neither {OLD} nor {NEW} exists")
    else:
        frappe.rename_doc("User", OLD, NEW, force=True, show_alert=False)
        print(f"renamed User {OLD} -> {NEW} (password + roles preserved; sessions cleared)")

else:  # promote-user
    email = sys.argv[1].lower()
    roles = [r for r in sys.argv[2:]] or [
        "Accounts Manager", "Stock Manager", "Sales Manager",
    ]
    if not frappe.db.exists("User", email):
        raise SystemExit(
            f"user {email} not found — they must do an SSO login first (auto-creation) "
            "or be created manually, then re-run promote-user"
        )
    user = frappe.get_doc("User", email)
    if not user.get("enabled", 1):
        raise SystemExit(f"user {email} is disabled — enable it first")
    changed = []
    if user.user_type != "System User":
        user.user_type = "System User"
        changed.append("user_type -> System User")
    existing = {d.role for d in user.get("roles", [])}
    for r in roles:
        if r not in existing:
            user.add_roles(r)
            changed.append(f"+role {r}")
    user.flags.ignore_permissions = True
    user.save()
    print(f"promoted {email}:", ", ".join(changed) or "no changes (already a System User with these roles)")
PY
