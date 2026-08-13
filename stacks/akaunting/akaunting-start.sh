#!/bin/bash
# Wrapper for Akaunting startup.
# - Rewrites .env on every start so DB config + APP_URL + APP_KEY are always correct
#   (the image .env is not persisted across container recreation)
# - Runs php artisan install only when AKAUNTING_SETUP=true and not yet installed
set -e

cd /var/www/html

a2enmod rewrite 2>/dev/null

# Enable .htaccess overrides so mod_rewrite routes work
# The image ships with AllowOverride None, breaking Laravel routing
cat > /etc/apache2/conf-available/htaccess.conf <<'HTACCESS'
<Directory /var/www/html>
    AllowOverride All
</Directory>
HTACCESS
a2enconf htaccess 2>/dev/null || true

mkdir -p storage/framework/{sessions,views,cache}
mkdir -p storage/app/uploads
mkdir -p storage/logs

# --- Rewrite .env on every start ---
# The Akaunting image ships a .env with placeholder values. Container env vars
# (from docker-compose) should take precedence, but Laravel loads .env first and
# it overrides env vars for any key present. We rewrite .env to ensure consistency.
# The DB_* values come from container env vars set by docker-compose, which in turn
# come from the host .env (AKAUNTING_DB_* -> DB_*).
cat > .env <<EOF
APP_NAME=Akaunting
APP_ENV=production
APP_KEY=${APP_KEY}
APP_URL=${APP_URL}
APP_DEBUG=false
APP_LOCALE=${LOCALE:-en-US}
APP_INSTALLED=${APP_INSTALLED:-false}

LOG_CHANNEL=stderr

DB_CONNECTION=mysql
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}
DB_PREFIX=${DB_PREFIX}

BROADCAST_DRIVER=log
CACHE_DRIVER=file
SESSION_DRIVER=file
QUEUE_CONNECTION=sync
EOF

# Run install only if requested AND the app is not already installed
if [ "${AKAUNTING_SETUP}" == "true" ] && ! grep -q "APP_INSTALLED=true" .env 2>/dev/null; then
    # Clean up junk tables from previous failed install attempts before trying
    for attempt in $(seq 1 6); do
        if mysql -u "${DB_USERNAME}" -p"${DB_PASSWORD}" \
            -h "${DB_HOST}" -P "${DB_PORT}" \
            -e "USE ${DB_NAME}; \
                SET FOREIGN_KEY_CHECKS=0; \
                SELECT CONCAT('DROP TABLE IF EXISTS ', table_name) \
                FROM information_schema.tables \
                WHERE table_schema='${DB_NAME}' \
                INTO OUTFILE '/tmp/drop_tables.sql'; \
                SOURCE /tmp/drop_tables.sql; \
                SET FOREIGN_KEY_CHECKS=1;" 2>/dev/null; then
            break
        fi
        # Fallback: try dropping and recreating the database with app user
        if mysqladmin -u "${DB_USERNAME}" -p"${DB_PASSWORD}" \
            -h "${DB_HOST}" -P "${DB_PORT}" \
            drop "${DB_NAME}" 2>/dev/null && \
           mysql -u "${DB_USERNAME}" -p"${DB_PASSWORD}" \
            -h "${DB_HOST}" -P "${DB_PORT}" \
            -e "CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" 2>/dev/null; then
            break
        fi
        if [ $attempt -lt 6 ]; then
            sleep 3
        fi
    done

    retry_for=30
    retry_interval=5
    while sleep $retry_interval; do
        if php artisan install \
            --db-host=$DB_HOST \
            --db-port=$DB_PORT \
            --db-name=$DB_NAME \
            --db-username=$DB_USERNAME \
            "--db-password=$DB_PASSWORD" \
            --db-prefix=$DB_PREFIX \
            "--company-name=$COMPANY_NAME" \
            "--company-email=$COMPANY_EMAIL" \
            "--admin-email=$ADMIN_EMAIL" \
            "--admin-password=$ADMIN_PASSWORD" \
            "--locale=$LOCALE" --no-interaction; then
            # Mark as installed in our .env
            sed -i 's/^APP_INSTALLED=.*/APP_INSTALLED=true/' .env
            echo "Install succeeded"
            break
        else
            if [ $retry_for -le 0 ]; then
                echo "Install failed after retries — check logs" >&2
                exit 1
            fi
            (( retry_for -= retry_interval ))
        fi
    done
fi

# Fix ownership for dirs www-data needs to write to
chown -R www-data:root storage/framework storage/app storage/logs .env 2>/dev/null || true

exec docker-php-entrypoint apache2-foreground
