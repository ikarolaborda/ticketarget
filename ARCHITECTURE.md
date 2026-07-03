# Ticketarget — Architecture

This document explains *why* each piece exists and *how* the non-functional requirements
are met. It mirrors the five design steps: requirements → capacity → entities → storage →
APIs → deep dives.

## 1. Requirements

**Functional**

1. View events.
2. Search events.
3. Buy tickets.

**Non-functional**

1. Support ~10M concurrent users during major on-sales.
2. Block purchase bots; never privilege users by geolocation.
3. Smart search: typo tolerant + stemming, e.g. `casa` → `casas, casarão, casinha`.
4. Strong consistency on purchase: never sell the same seat/ticket twice.
5. Search latency < 500 ms.
6. Read-heavy: 100:1 read/write ratio.
7. High availability.

## 2. Component responsibilities

### Traefik (Load Balancer + API Gateway)
Single entry point. Terminates TLS, performs host/path routing to services, applies
cross-cutting middleware (rate limiting, security headers, request-id injection, gzip).
Replaces a separate LB + gateway with one declarative, service-discovered layer.

### Event Service (Laravel 13)
Owns the `events`, `venues`, `tickets` catalog. Read-dominant. Writes go to the Postgres
**primary**; reads are routed to the **replica** and cached in Redis. It is the source of
truth that Debezium tails for CDC.

### Booking Service (Laravel 13)
Owns `bookings` and the seat-reservation lifecycle. This is the only place where strong
consistency matters. Two-phase purchase:

1. `POST /reserve` — acquires a short-TTL **Redis lock** per seat (Sentinel-backed) and
   flips ticket status to `unavailable` inside a DB transaction using
   `SELECT … FOR UPDATE`. The lock + row lock together make double-booking impossible
   even across service replicas.
2. `POST /booking` — charges via **Stripe**, and on success commits the booking and flips
   ticket status to `booked`. On failure or TTL expiry the reservation is released.

### Search Service (Symfony 8.1, hexagonal)
Read-only. Exposes `GET /search`. The domain defines a `SearchEventsPort`; the
infrastructure layer provides an `ElasticsearchSearchAdapter`. Swapping the engine never
touches the domain. Elasticsearch analyzers deliver fuzzy matching + stemming under 500 ms.

### Worker (Symfony 8.1, CDC consumer)
Consumes Debezium change events from Kafka and projects them into Elasticsearch
(idempotent upserts, retry + dead-letter). This decouples write throughput from search
indexing and keeps search eventually consistent without coupling Event Service to ES.

### Data plane
- **PostgreSQL primary/replica**: ACID writes on primary, scaled reads on replica
  (logical 100:1 split mirrored in Laravel's read/write connections).
- **Redis Sentinel HA**: cache (Event) + distributed seat locks (Booking) with automatic
  master failover.
- **Kafka (KRaft)**: durable, replayable log between Debezium and the Worker; also the
  transport for the structured logging pipeline.
- **Debezium**: tails the Postgres WAL → emits row-level change events to Kafka.
- **Elasticsearch**: inverted index + analyzers for smart, low-latency search.

## 3. Consistency model

| Path        | Guarantee                | Mechanism                                    |
|-------------|--------------------------|----------------------------------------------|
| Purchase    | Strong (ACID + isolated) | Redis lock + `FOR UPDATE` + DB transaction   |
| Catalog read| Read-your-writes-ish     | Primary write, replica read, Redis cache     |
| Search      | Eventual                 | CDC pipeline (Debezium → Kafka → Worker → ES)|

## 4. Scaling & availability

- All PHP HTTP services run stateless under FrankenPHP worker mode and scale by replica
  count behind Traefik.
- Reads fan out to the Postgres replica and Redis; the hot path for "view event" is
  cache-first.
- Redis Sentinel and Postgres streaming replication provide failover.
- Kafka retains CDC + log events so consumers can restart and replay.

## 5. Bot mitigation (no geo privilege)

1. Edge: Cloudflare-style challenge (documented hook; Traefik forwardauth middleware).
2. Gateway: Traefik rate-limit middleware keyed by client identity, **not** geography.
3. Booking path: signed queue/waiting-room token required before `/reserve`, so automated
   clients cannot jump the line regardless of region.

## 6. Cross-cutting: logging

Every PHP service uses the shared `ticketarget/logging` package: PSR-3 Monolog with a JSON
formatter, automatic correlation/trace IDs, and a Kafka handler that ships logs to a
`logs.*` topic (with a stdout fallback). This gives one standardized, queryable log stream
across the whole platform.

## ADR: admin UI lives inside the single SPA (2026-07-03)

The admin panel (including the sales dashboard) is a role-gated section of the one
Vue SPA, not a separate "backoffice" frontend. Rationale: the microservice
boundaries here decompose the backend; a single SPA is the documented frontend and
micro-frontends solve organizational problems (autonomous squads, independent
deploys) this project does not have. Admin code is bundle-isolated already —
`AdminView` is a lazy route chunk that customer visitors never download — and all
authorization is server-side (JWT `is_admin`), so a separate origin would not
strengthen authZ. The admin chunk remains publicly *fetchable*: that is metadata
exposure (UI shape, endpoint paths), accepted deliberately.

Boundary rules that keep a future split cheap:
- all admin frontend code lives in `src/views/AdminView.vue`, `src/components/admin/`
  and admin-only composables; customer views must never import from them
- admin API endpoints (`/booking/admin/*`, event-service admin routes) stay
  UI-neutral REST so any future backoffice consumes them unchanged

Split triggers (revisit this ADR if any becomes true): a dedicated admin team;
VPN/IP-allowlist or compliance requirements on operator access; a separate identity
boundary; divergent release cadence; the admin app rivaling the customer app in size.
