"""Local compatibility patch for Sync via SimpleFIN v1.0.4 on Frappe v16.

Frappe v16 stores Password-type fields as an asterisk mask in the main table
plus a Fernet-encrypted copy in the ``__Auth`` table. The app's v1.0.4 read
paths use ``doc.get_password()``, which can return the variable-length
asterisk mask instead of the decrypted value (frappe's ``is_dummy_password``
check does not recognise variable-length masks). The HTTP client then
receives a string of asterisks and fails with
"SimpleFIN requires HTTPS. Received URL with scheme: (empty)".

This script resolves Password fields through the encrypted store
(``frappe.utils.password.get_decrypted_password``) at every read site:

  - utils/sync.py: the sync execution path (daily sync, Sync Full, Sync Now)
  - .../simplefin_connection/simplefin_connection.py: ``test_connection``
    and the ``setup_token`` read in ``register_token`` (re-registration)

Idempotent: each anchor must be present; the import additions are checked
for an existing occurrence first. Re-running on an already-patched tree
fails loudly rather than corrupting the source.

Run from the bench:  /home/frappe/frappe-bench/env/bin/python patch-sync-simplefin.py
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/home/frappe/frappe-bench/apps/sync_simplefin")

HELPER = '''
def resolve_password_field(doc, fieldname: str) -> str:
\t"""Resolve a stored Password field to its plaintext value.

\tFrappe v16 stores Password fields as an asterisk mask in the main table
\tplus a Fernet-encrypted copy in the __Auth table. doc.get_password() may
\treturn the mask instead of the decrypted value (its dummy-password check
\tdoes not recognise variable-length asterisk masks), so when the raw value
\tis a mask we fall through to the encrypted store and decrypt it.
\t"""
\tfrom frappe.utils.password import get_decrypted_password

\tval = cstr(doc.get(fieldname) or "")
\tif val and "*" not in val:
\t\treturn val  # plaintext (in-memory or pre-encryption storage)
\treturn get_decrypted_password(doc.doctype, doc.name, fieldname, raise_exception=False) or ""
'''


def patch_file(rel: str, subs: list[tuple[str, str]], append: str = "") -> None:
    path = ROOT / rel
    src = path.read_text()
    for old, new in subs:
        if new in src:
            sys.exit(f"ABORT: already applied in {rel}: {new[:70]!r}")
        if old not in src:
            sys.exit(f"ABORT: anchor not found in {rel}: {old[:70]!r}")
        src = src.replace(old, new, 1)
    if append:
        if "resolve_password_field" in src:
            sys.exit(f"ABORT: already applied in {rel}")
        src = src.rstrip("\n") + "\n" + append
    path.write_text(src)
    print(f"patched {rel}")


# 1. utils/simplefin_client.py — cstr import + helper appended at module end.
patch_file(
    "sync_simplefin/utils/simplefin_client.py",
    subs=[
        (
            "from frappe import _\n",
            "from frappe import _\nfrom frappe.utils import cstr\n",
        ),
    ],
    append=HELPER,
)

# 2. utils/sync.py — import the helper and use it in the sync execution path.
patch_file(
    "sync_simplefin/utils/sync.py",
    subs=[
        (
            "from frappe.utils import now_datetime\n",
            "from frappe.utils import now_datetime\n"
            "from sync_simplefin.utils.simplefin_client import resolve_password_field\n",
        ),
        (
            "access_url = conn.get_password(\"access_url\")",
            "access_url = resolve_password_field(conn, \"access_url\")",
        ),
    ],
)

# 3. Connection doctype — use the helper in test_connection and register_token.
patch_file(
    "sync_simplefin/sync_via_simplefin/doctype/simplefin_connection/simplefin_connection.py",
    subs=[
        (
            "from frappe.utils import get_datetime, now_datetime\n",
            "from frappe.utils import get_datetime, now_datetime\n"
            "from sync_simplefin.utils.simplefin_client import resolve_password_field\n",
        ),
        (
            "access_url = conn.get_password(\"access_url\")",
            "access_url = resolve_password_field(conn, \"access_url\")",
        ),
        (
            "token_value = conn.get_password(\"setup_token\")",
            "token_value = resolve_password_field(conn, \"setup_token\")",
        ),
    ],
)

print("all patches applied")
