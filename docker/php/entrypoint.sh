#!/bin/sh
set -eu

# Wait-free, framework-aware warmup. Cache priming is skipped in local/dev so
# bind-mounted source changes are picked up without a rebuild.
if [ "${APP_ENV:-local}" = "production" ]; then
    if [ "${APP_FRAMEWORK:-}" = "laravel" ] && [ -f artisan ]; then
        php artisan config:cache || true
        php artisan route:cache || true
        php artisan event:cache || true
    fi
    if [ "${APP_FRAMEWORK:-}" = "symfony" ] && [ -f bin/console ]; then
        php bin/console cache:warmup --no-interaction || true
    fi
fi

exec "$@"
