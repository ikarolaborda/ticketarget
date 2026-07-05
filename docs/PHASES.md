# Delivery roadmap

The platform is delivered in phases. Each phase leaves the repo in a coherent, runnable
state.

| Phase | Scope | Status |
|-------|-------|--------|
| 0 | Foundations: repo layout, conventions, env, Makefile, docs | ✅ done |
| 1 | Infra topology & `docker-compose` (Traefik, Postgres ×2, Redis Sentinel, Kafka, Debezium, Elasticsearch), reusable multi-stage Dockerfiles, all service skeletons | ✅ done |
| 2 | Shared PSR-3 logging package (Monolog → Kafka) | ✅ done |
| 3 | Event Service (Laravel): entities, migrations, read-replica routing, view API | ✅ core done |
| 4 | Booking Service (Laravel): reserve→pay→book, Redis seat locks, Stripe, ACID | ✅ core done |
| 5 | Search Service (Symfony, hexagonal): fuzzy + stemming search | ✅ core done |
| 6 | Worker (Symfony): Debezium/Kafka CDC → Elasticsearch indexer | ✅ core done |
| 7 | Frontend (Vue 3 + Pinia): browse, search, seat selection, checkout | ✅ core done |
| 8 | Verification: compose validation, PHPStan, Pint, Vue typecheck, smoke tests | 🟡 YAML/JSON validated; container build + test suites pending first `make up` |

## Remaining hardening (follow-up phases)

- Run `composer install` / `npm ci` inside the images and execute PHPStan, Pint, PHPUnit, and `vue-tsc` (needs Docker on the host).
- Event Service admin writes ✅: an `is_admin` platform JWT gates `POST /venues`, `POST /events`, `PUT/DELETE /events/{id}`, and `POST /events/{id}/tickets` (thin controllers → actions, cache invalidation on write; CDC propagates to search). Mint a token with `make admin-token EMAIL=<existing admin>` (`users-service artisan auth:issue-token`). The former Sanctum `events:write` path was removed in the RS256/JWKS cutover.
- Search autocomplete ✅: `GET /search/autocomplete?q=` over the `event_autocomplete` edge-ngram analyzer.
- Booking Service hardening ✅: waiting-room/queue token issuance (`POST /queue/join`) + the `/internal/queue/verify` Traefik forward-auth gating `/reserve`, a `RequireQueueToken` middleware (defense-in-depth), a scheduled reservation-expiry sweeper (`booking:release-expired` + `booking-scheduler` service), refund-on-failed-confirm, and a signed Stripe webhook.
- Worker enrichment + DLQ ✅: events are reindexed from a DB read-replica projection (port/adapter) so search docs carry `venue_name`/`venue_city`/`min_price`; CDC fans out (event/venue/ticket change → reindex affected events, delete on event delete); poison messages retry then go to a Kafka dead-letter topic and commit so the partition never blocks.
- Admin UI + platform admin identity ✅: `users.is_admin` flag (migration owned by event-service), `is_admin` JWT claim from users-service (`php artisan admin:promote {email}` / `make admin-promote EMAIL=…`), and an `AdminBearerAuth` middleware in event-service accepting EITHER a platform JWT with `is_admin: true` (humans) and CLI/service callers use an admin JWT from `auth:issue-token`. (The RS256/JWKS cutover, 2026-07-05, made users-service the sole issuer and removed the Sanctum fallback entirely.) `/admin` SPA views (venues, events, ticket batch generator, manage table); `DELETE /events/{id}` returns 409 while any booking is `paid`/`refund_pending`. Note: the manage table lists published events only (`GET /events` is published-only by design).
- Light mode ✅: `[data-theme='light']` token overrides in `main.css`, per-browser preference (`localStorage ticketarget.theme`, defaults to `prefers-color-scheme`), pre-mount inline script against first-paint flicker, topbar toggle.
- Observability ✅: a `ticketarget:logs:ship` consumer bulk-indexes the `logs.app` topic into an `app-logs` Elasticsearch index (`log-shipper` service), and Kibana is available at `logs.<domain>` for dashboards.

Verification status:

- Frontend ✅ actually built: `vue-tsc` type-check passes and `vite build` succeeds (97 modules, per-view code-splitting).
- CI ✅: `.github/workflows/ci.yml` runs Pint + PHPStan + PHPUnit for the Laravel services, PHPStan for the Symfony services, `vue-tsc`/`vite build` for the frontend, and `docker compose config` + an image build — all on PHP 8.5 / Node 22.
- PHP suites run automatically in CI (no PHP 8.5 in the authoring sandbox). Bringing the full stack up still requires a Docker host: `make init && make up && make seed && make register-cdc && make es-bootstrap`, then `docker compose exec event-service php artisan admin:token` for a write token.

## Conventions

- **PHP 8.5+** everywhere. `declare(strict_types=1);` in every file.
- **Thin controllers**: controllers validate + delegate to actions/handlers; no business
  logic in controllers.
- **SOLID + hexagonal** on Symfony services: domain depends on ports (interfaces);
  adapters live in the infrastructure layer.
- **Laravel**: Form Requests for validation, single-action invokable controllers,
  Actions/Services for use cases, Eloquent models kept lean, read/write connection split.
- **Comments**: no narrating line comments. Only block comments that explain genuinely
  non-obvious logic.
- **Logging**: always via the shared `ticketarget/logging` PSR-3 package.
- **Docker**: one reusable multi-stage PHP image; per-service images only set build args.
