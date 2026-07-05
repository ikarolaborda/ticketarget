# Ticketarget

A highly-available, horizontally-scalable event ticketing platform — the reference
implementation of the architecture below. Built to survive on-sale spikes of millions
of concurrent users while guaranteeing that no two buyers ever get the same seat.

## Architecture at a glance

```
            ┌───────────┐
 Users ───▶ │  Traefik  │  (Load Balancer + API Gateway + rate limiting + TLS)
            └─────┬─────┘
                  │
   ┌──────────────┼─────────────────────────────┐
   ▼              ▼                             ▼
Search Svc    Event Svc                       Booking Svc
(Symfony)     (Laravel)                        (Laravel)
   │              │   │                          │     │
   ▼              ▼   ▼                          ▼     ▼
Elasticsearch  Redis  Postgres ── streaming ──▶ Postgres   Redis (Sentinel HA)
   ▲          (Sentinel) primary    replication   replica   seat locks + Stripe
   │                       │
   │                       ▼
 Worker  ◀── Kafka ◀── Debezium (CDC on Postgres WAL)
(Symfony consumer indexes changes into Elasticsearch)
```

| Concern                         | Technology                                   |
|---------------------------------|----------------------------------------------|
| Edge / LB / API Gateway         | Traefik v3 (TLS, routing, rate limiting)     |
| HTTP application server         | FrankenPHP (PHP 8.5, worker mode)            |
| Event & Booking services        | Laravel 13                                   |
| Search service & CDC Worker     | Symfony 8.1 (hexagonal / ports & adapters)   |
| Relational store                | PostgreSQL 17 (primary + read replica)       |
| Cache & distributed locks       | Redis 7 + Sentinel (HA)                      |
| Search engine                   | Elasticsearch 8 (fuzzy + stemming)           |
| Change Data Capture             | Debezium 3 on Kafka Connect                  |
| Event streaming / log bus       | Apache Kafka (KRaft mode)                    |
| Payments                        | Stripe                                       |
| Frontend                        | Vue 3.5 (Composition API) + Pinia + Vite     |
| Structured logging              | Monolog → Kafka (PSR-3, JSON, trace IDs)     |

## Requirements satisfied

- **10M concurrent users**: stateless services scale horizontally behind Traefik; reads
  served from Postgres replica + Redis + Elasticsearch (100:1 read/write ratio).
- **No double-booking**: pessimistic Redis seat lock + `SELECT … FOR UPDATE` inside an
  ACID transaction in the Booking service.
- **Smart search (typos + stemming, < 500ms)**: Elasticsearch analyzers, kept in sync
  by Debezium → Kafka → Worker.
- **Bot mitigation**: Traefik rate limiting + Cloudflare-style edge challenge hook + a
  waiting-room/queue token on the booking path (no geo-privilege).
- **High availability**: Postgres replication, Redis Sentinel failover, Kafka log,
  multi-replica stateless services.

## Repositories (multi-repo layout)

This is the **aggregator repository**: it owns the infrastructure, Docker
topology and documentation, and mounts each deliverable as a **git submodule**
(same fashion as [alura-ms](https://github.com/ikarolaborda/alura-ms)).

| Path | Repository | Stack |
| --- | --- | --- |
| `services/event-service` | [ticketarget-event-service](https://github.com/ikarolaborda/ticketarget-event-service) | Laravel 13 — catalog + admin writes |
| `services/booking-service` | [ticketarget-booking-service](https://github.com/ikarolaborda/ticketarget-booking-service) | Laravel 13 — waiting room, seat holds, Stripe |
| `services/search-service` | [ticketarget-search-service](https://github.com/ikarolaborda/ticketarget-search-service) | Symfony 8.1 — fuzzy + autocomplete search |
| `services/worker` | [ticketarget-worker](https://github.com/ikarolaborda/ticketarget-worker) | Symfony 8.1 — CDC → Elasticsearch projector |
| `services/users-service` | [ticketarget-users-service](https://github.com/ikarolaborda/ticketarget-users-service) | Laravel 13 — accounts, login, stateless HS256 auth tokens |
| `frontend` | [ticketarget-frontend](https://github.com/ikarolaborda/ticketarget-frontend) | Vue 3 + Pinia + Vite SPA |
| `libs/logging` | [ticketarget-logging](https://github.com/ikarolaborda/ticketarget-logging) | Shared PSR-3 Monolog→Kafka package |

Clone with submodules and always build/run from here — the Docker build
contexts and the `libs/logging` composer path dependency resolve against this
repo's root:

```bash
git clone --recurse-submodules https://github.com/ikarolaborda/ticketarget.git
# or, after a plain clone:
git submodule update --init --recursive
```

## Repository layout

```
ticketarget/
├── docker-compose.yml            # full topology
├── docker-compose.override.yml   # local dev tweaks (hot reload, xdebug)
├── .env.example                  # copy to .env
├── Makefile                      # day-to-day commands
├── docker/                       # reusable multi-stage Dockerfiles + runtime config
│   ├── php/                      # shared FrankenPHP image for every PHP service
│   └── frontend/                 # Vue build/runtime image
├── infra/                        # config for stateful infrastructure
│   ├── traefik/                  # static + dynamic config (middlewares)
│   ├── postgres/                 # primary + replica bootstrap
│   ├── redis/                    # master/replica/sentinel config
│   ├── debezium/                 # connector registration
│   └── elasticsearch/            # index templates & analyzers
├── libs/
│   └── logging/                  # shared PSR-3 Monolog→Kafka package
├── services/
│   ├── event-service/            # Laravel 13
│   ├── booking-service/          # Laravel 13
│   ├── search-service/           # Symfony 8.1 (hexagonal)
│   └── worker/                   # Symfony 8.1 (CDC consumer)
└── frontend/                     # Vue 3 + Pinia + Vite
```

## Getting started

```bash
cp .env.example .env
make up            # build + start the whole stack
make seed          # run migrations + seeders
make register-cdc  # register the Debezium Postgres connector
```

Then open:

- Frontend: <http://app.ticketarget.localhost>
- API gateway: <http://api.ticketarget.localhost>
- Logs dashboard (Kibana): <http://logs.ticketarget.localhost>
- Traefik dashboard: <http://localhost:18080> (override with `TRAEFIK_DASHBOARD_PORT`)

## Whitelabel branding

The frontend is fully brandable at runtime: mount your own `branding.json`
over the baked-in one to change the name, logo mark, color scheme, corner
style (square/rounded) and glass effect — no rebuild. See
[docs/WHITELABEL.md](docs/WHITELABEL.md).

## Admin access

Catalog administration (`/admin` in the SPA) is gated server-side in the Event
Service by a platform JWT carrying `is_admin: true`. Humans get one by logging
in; CLI/service callers mint one with `make admin-token EMAIL=<existing admin>`
(`users-service artisan auth:issue-token`, admin-only). Tokens are RS256, signed
by the sole issuer (users-service) and verified against its published JWKS.
Grant the flag to an account with `make admin-promote EMAIL=user@example.com`
(a fresh login is needed to pick up the new claim). The client-side `/admin`
gate is UX only — the server check is the source of truth.

See [`ARCHITECTURE.md`](./ARCHITECTURE.md) for the deep dive and
[`docs/PHASES.md`](./docs/PHASES.md) for the delivery roadmap.
