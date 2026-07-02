# syntax=docker/dockerfile:1.9
# ──────────────────────────────────────────────────────────────────────────────
# Reusable multi-stage image for every PHP service (Laravel + Symfony).
# Per-service compose entries only pass build args; no per-service Dockerfile.
#   SERVICE        e.g. services/event-service   (path within the repo)
#   APP_FRAMEWORK  laravel | symfony
#   APP_RUNTIME    http (FrankenPHP) | cli (long-running worker)
# ──────────────────────────────────────────────────────────────────────────────
ARG PHP_VERSION=8.5

# ── Stage: base — runtime + extensions shared by all stages ───────────────────
FROM dunglas/frankenphp:php${PHP_VERSION} AS base

ARG SERVICE
ENV SERVICE=${SERVICE}

# install-php-extensions ships with the FrankenPHP image; it resolves the right
# system libraries for each extension and strips build deps afterwards.
RUN install-php-extensions \
        pdo_pgsql \
        intl \
        zip \
        bcmath \
        opcache \
        pcntl \
        redis \
        rdkafka

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY docker/php/conf.d/ /usr/local/etc/php/conf.d/
COPY docker/php/Caddyfile /etc/frankenphp/Caddyfile
COPY docker/php/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

WORKDIR /srv/${SERVICE}
ENTRYPOINT ["entrypoint"]

# ── Stage: vendor — install PHP dependencies with layer caching ───────────────
FROM base AS vendor

ARG SERVICE
# The shared logging package is resolved through a relative path repository,
# so its source must exist before `composer install` runs.
COPY libs /srv/libs
COPY ${SERVICE}/composer.json ${SERVICE}/composer.loc[k] /srv/${SERVICE}/

RUN --mount=type=cache,target=/tmp/composer-cache \
    COMPOSER_CACHE_DIR=/tmp/composer-cache \
    composer install --no-dev --no-scripts --no-autoloader --prefer-dist

# ── Stage: prod — optimized production image ──────────────────────────────────
FROM base AS prod

ARG SERVICE
ARG APP_FRAMEWORK=laravel
ENV APP_FRAMEWORK=${APP_FRAMEWORK} APP_ENV=production APP_DEBUG=false

COPY libs /srv/libs
COPY --from=vendor /srv/${SERVICE}/vendor /srv/${SERVICE}/vendor
COPY ${SERVICE} /srv/${SERVICE}

RUN composer dump-autoload --no-dev --optimize --classmap-authoritative \
    && useradd -u 1000 -m app \
    && chown -R app:app /srv

USER app
EXPOSE 8000
CMD ["frankenphp", "run", "--config", "/etc/frankenphp/Caddyfile"]

# ── Stage: dev — adds xdebug + dev dependencies, source is bind-mounted ───────
FROM base AS dev

ARG SERVICE
ENV APP_ENV=local APP_DEBUG=true
# xdebug is optional dev tooling; don't fail the image if it can't be enabled
# on a freshly-released PHP/ZTS where the helper's enable step is flaky.
RUN install-php-extensions xdebug || echo "xdebug unavailable on this PHP build — continuing without it"
COPY libs /srv/libs
COPY ${SERVICE} /srv/${SERVICE}
RUN composer install --prefer-dist || true
EXPOSE 8000
CMD ["frankenphp", "run", "--config", "/etc/frankenphp/Caddyfile"]
