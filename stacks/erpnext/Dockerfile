# Custom ERPNext image: official 16.32.1 base + the "Sync via SimpleFIN" app
# (archadianai/Sync_SimpleFIN) baked into the bench. The bench dir is baked
# into the official image (only sites/ is a mounted volume), so the app is
# cloned and pip-installed at build time. A small local compatibility patch
# (patch-sync-simplefin.py — the only file copied in) fixes the app's
# Password-field reads for Frappe v16. The image entrypoint re-links
# sites/assets -> /home/frappe/frappe-bench/assets on every start, so the
# freshly built assets are copied to that non-volume path to survive.
ARG BASE=frappe/erpnext:v16.32.1
FROM ${BASE}

ARG APP_REF=v1.0.4
ARG APP_SHA=d54b2c127da1278875a4d723c55dc01b75c5db81
WORKDIR /home/frappe/frappe-bench

# Clone the pinned release tag; fail the build if the tag no longer points at
# the pinned SHA (tag moved upstream).
RUN git clone --depth 1 --branch "${APP_REF}" https://github.com/archadianai/Sync_SimpleFIN.git apps/sync_simplefin \
 && test "$(git -C apps/sync_simplefin rev-parse HEAD)" = "${APP_SHA}"

# Apply the local compatibility patch (Frappe v16 stores Password fields as
# an asterisk mask + Fernet copy in __Auth; upstream v1.0.4's read paths
# return the mask and break the Bridge client). Applied after the SHA pin
# test, before the editable install. The script is kept in the image at
# /tmp/patch-sync-simplefin.py as an audit trail of the local modification.
COPY patch-sync-simplefin.py /tmp/patch-sync-simplefin.py
RUN /home/frappe/frappe-bench/env/bin/python /tmp/patch-sync-simplefin.py

# Install into the bench env (the app has no extra pip dependencies), register
# it in sites/apps.txt so `bench build` compiles its assets, build all assets.
# The baked sites/apps.txt ends WITHOUT a trailing newline (verified via
# `od -c`: "frappe\nerpnext"), so a bare `echo >>` would concatenate onto the
# last entry (e.g. "erpnextsync_simplefin") and bench build would fail
# resolving that app. Guard for it; make the append idempotent.
RUN /home/frappe/frappe-bench/env/bin/pip install -e apps/sync_simplefin \
 && sh -c '[ -s sites/apps.txt ] && [ -n "$(tail -c 1 sites/apps.txt)" ] && echo >> sites/apps.txt; grep -qx "sync_simplefin" sites/apps.txt || echo sync_simplefin >> sites/apps.txt' \
 && bench build

# Bake built assets into the image layer (see header note).
RUN rm -rf assets && cp -r sites/assets assets && rm -rf sites/assets
