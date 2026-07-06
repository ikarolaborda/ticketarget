# Operations — CDC pipeline (Postgres → Debezium → Kafka → worker → Elasticsearch)

## How the worker fails, by design

The worker classifies every projection failure:

| Class | Examples | Behavior |
|---|---|---|
| **Transient** | Elasticsearch down/5xx/network, Postgres restarting (SQLSTATE `08*`, `57P*`) | Exponential backoff in-process (1s → 2s → 4s → 8s, max 5 attempts), then the worker logs CRITICAL `CDC halted: infrastructure unavailable` and **exits without committing the offset**. Compose (`restart: unless-stopped`) restarts it with fresh connections; Kafka redelivers. **Nothing is ever dead-lettered for infra outages.** |
| **Permanent (poison)** | Mapping/validation 4xx from ES, malformed rows | 3 fast retries, then the event is parked in the DLQ (`ticketarget.cdc.dlq`) and the offset commits so the partition never sticks. |

A delete of an already-absent document (ES 404) counts as success — deletes are idempotent.

During a long outage the worker will crash-loop with backoff. That is expected
and visible; it is not a fault.

## Symptoms → diagnosis

- **Search results stale, worker logs show `failure_class: transient` + `retry_in_ms`:**
  infrastructure outage in progress. Check `docker compose ps elasticsearch postgres-replica`.
  The pipeline resumes by itself once the dependency is healthy — verified recovery
  time is seconds after ES accepts connections.
- **CRITICAL `CDC halted: infrastructure unavailable` repeating:** the outage persists.
  Fix the dependency; do NOT touch Kafka offsets.
- **ERROR `Change event sent to dead-letter topic`:** a poison message. Inspect the log
  context (`table`, `op`, `reason`). These are rare by design now.
- Debezium connector health is independent: `curl -s localhost:8083/connectors/ticketarget-postgres-connector/status`.
  RUNNING there + transient errors in the worker = downstream outage, not a connector problem.

## Kibana queries (app-logs index)

- Halt events: `message: "CDC halted"`
- Poison events: `message: "Change event sent to dead-letter topic"`
- Replay activity: `context.command: "replay"`

## DLQ replay

```
make replay-dlq        # drains ticketarget.cdc.dlq through the normal projection path
```

- Replay is idempotent: documents are rebuilt from the database and indexed by event id.
- Transient failure during replay aborts WITHOUT committing — re-run when infra is healthy.
- Entries that fail permanently again are logged (`DLQ replay: event is still poison`)
  and skipped; the replay group's offset advances past them. To re-attempt skipped
  entries after a code fix:

```
docker compose exec kafka kafka-consumer-groups --bootstrap-server localhost:9092 \
  --group ticketarget-dlq-replay --topic ticketarget.cdc.dlq --reset-offsets --to-earliest --execute
make replay-dlq
```

- Historical note: entries dead-lettered before 2026-07-03 predate failure
  classification (transient-era casualties + delete-404s) and replay cleanly.

## DLQ growth check

```
docker compose exec kafka kafka-get-offsets --bootstrap-server localhost:9092 --topic ticketarget.cdc.dlq
```

A growing end-offset without matching poison log entries deserves investigation.

## Tuning (compose env)

- `CDC_MAX_ATTEMPTS` (default 3) — fast retries for poison messages.
- `CDC_TRANSIENT_MAX_ATTEMPTS` (default 5) — backoff retries before halting.
- `CDC_TRANSIENT_BACKOFF_MS` (default 1000) — backoff base; doubles per attempt, capped at 60s.

## Verified acceptance (2026-07-03)

Elasticsearch was stopped while an event was created through the admin API: the worker
retried with backoff, halted without committing, crash-looped under compose, and the
event appeared in search 15 seconds after Elasticsearch restarted. DLQ end-offset was
unchanged. The full historical DLQ (10,119 entries) was replayed with zero remaining
poison after the delete-404 fix.

## DDD remediation operations (2026-07-05)

**Outbox publishing.** `outbox:publish` runs every minute on `booking-scheduler`
and ships `outbox_messages` to Kafka topic `booking.events` (`OUTBOX_TOPIC`).
Rows are marked published only after an acknowledged flush; failures increment
`attempts` and record `last_error`, and rows stay retryable. Delivery is
at-least-once — consumers must dedupe on `event_key`. If the `rdkafka`
extension is missing the command logs a warning and skips (fine in dev; in
production treat a growing unpublished backlog as an alert condition).

**Inventory shadow mode.** `INVENTORY_DUAL_WRITE` (default on) mirrors every
ticket-status transition into booking-owned `seat_inventory`;
`tickets.status` remains the source of truth. Run
`booking:verify-inventory --strict` (exit 1 on drift) to check the cutover
gate; sustained zero drift is the precondition for flipping ownership.

**Payment invariants.** One payment row per reservation; transitions are
guarded (`pending → captured → partially_refunded/refunded | failed`);
`refunded_amount` is webhook-authoritative, monotonic, and clamped.
`bookings.charge_id`/`payment_id` are display projections — never treat them
as money truth.

**Read-model bootstrap (2026-07-06).** The event-service `DatabaseSeeder` creates
demo events/tickets with `Ticket::factory()->create()` — a direct insert that
does NOT go through the outbox, so seeded catalog data emits no `ticket.generated`
events and booking's read models (`seat_inventory`, `catalog_capacity_ledger`,
`catalog_event_directory`) start EMPTY. `make first-run` now runs `make
seed-catalog` after `make seed` to converge them from the seeded tables via the
documented idempotent backfills: `booking:seed-inventory`,
`catalog:backfill-ticket-events --cutoff=<now>`, `catalog:backfill-event-directory`,
then `outbox:publish` + `catalog:consume` inline (deterministic, not waiting on the
scheduler). Run `make seed-catalog` manually to recover the read models on any
environment. GATE NOTE: the `CATALOG_STATUS_DUAL_WRITE` flag-off is only
evaluable AFTER this — with an empty `seat_inventory` the drift check reports 0/0
(meaningless) and flipping the flag would make an empty authority the sole source
of truth, zeroing all availability/capacity. The flag-off still needs a real
multi-day zero-drift window observed on POPULATED data (verify-inventory checking
~N rows, not 0), and remains irreversible without a `seat_inventory -> tickets`
backfill.

**Capacity read model (2026-07-05).** Booking's admin dashboard reads event
capacity from `catalog_capacity_ledger`, fed by `ticket.generated` events on
Kafka topic `catalog.events` — no catalog tables are read. `catalog:consume`
runs every minute on `booking-scheduler` (bounded drain; offsets committed
after each row is applied; the unique `event_key` absorbs replays). Seeding a
fresh environment or recovering from data loss: run
`event-service artisan catalog:backfill-ticket-events --cutoff=<ISO8601 now>`
(idempotent — zone events reuse the live key, manual remainders subtract prior
announcements including earlier backfills), let `outbox:publish` ship it, then
check `booking:verify-capacity --strict` (exit 1 on drift; retire this check
at schema isolation, when catalog tables stop being readable). Known gotcha:
php-rdkafka 6.0.5 on PHP 8.5 ZTS segfaults intermittently on explicit
`KafkaConsumer::close()` after the work is done — the consumer relies on
destructor teardown; offsets are already committed, nothing is lost either
way.

**Inventory ownership cutover (2026-07-05).** `seat_inventory` is authoritative
for reserve/confirm/sweep/refund-release; catalog `tickets.status` is a
mirrored shadow behind `CATALOG_STATUS_DUAL_WRITE` (default on). Buyer
availability comes from `GET /booking/availability/{event}` (per-ticket status
+ zone aggregates); the SPA merges it over catalog static seat data and
degrades to the catalog snapshot if the call fails. Seeding/recovery:
`booking:seed-inventory` (fill-missing-only, rerunnable; new tickets flow in
via `ticket.generated` `tickets[]`). Drift gate: `booking:verify-inventory
--strict` compares the mirror against the inventory — drift means the mirror
is broken, fix before trusting rollback. ROLLBACK CRITERIA: while the flag is
on, rolling back means pointing reads at `tickets.status` again (mirror is
current); after the flag is off this is IRREVERSIBLE without backfilling
`tickets` from `seat_inventory` first. Disable the flag only after a sustained
zero-drift window and update this note when it happens.

**Rollback-window drift cadence (2026-07-05).** `booking:verify-inventory`
runs every 15 minutes on `booking-scheduler` (non-strict: a mismatch alerts,
it does not fail the scheduler run). Every run emits one structured log line —
`Inventory drift check clean` (info) or `Inventory drift detected` (warning,
with `mismatches` and `sample_ticket_ids`) — so the zero-drift window that
gates the `CATALOG_STATUS_DUAL_WRITE` flag-off is queryable in Kibana
(app-logs, `message:"Inventory drift*"`), not anecdotal.

**Event directory read model (2026-07-05).** Confirm-time `event_name`/
`event_date` snapshots read booking-owned `catalog_event_directory`, projected
from `event.created`/`event.updated` on `catalog.events` (emitted by
event-service's `UpsertEvent` inside the write transaction). Ordering:
last-write-wins on `occurred_at` — emission-time microseconds, NOT the
second-precision `updated_at`, so two edits in one second still order
correctly; equal timestamps overwrite deterministically (same emission
content). While the shared DB lasts, a directory miss at confirm falls back to
the catalog `events` table, logs `Event directory miss` (warning) and writes
through, healing itself; a persistent stream of those warnings means the
consumer or backfill is broken. Seeding/recovery:
`event-service artisan catalog:backfill-event-directory` (idempotent —
deterministic `event.updated:backfill:{id}:{updated_at}` keys dedupe in the
outbox, and backfill `occurred_at` = persisted `updated_at` is always older
than any live emission, so re-runs can never clobber newer state), then
`outbox:publish` + `catalog:consume` as usual. Retire the fallback (and this
note's shared-DB caveat) at schema isolation.

**Search indexer on integration events (2026-07-05).** The `worker` compose
service now runs `ticketarget:search:index`: it consumes `catalog.events`
(consumer group `ticketarget-search-indexer`, earliest) and builds each search
document entirely from the event-carried state in `event.created`/
`event.updated`/`event.deleted` payloads (`schema_version` 2) — no database
read. Raw-table Debezium CDC is DEPRECATED for search; the old
`ticketarget:cdc:consume` command, its consumer group, and the Debezium
connector are kept intact only as the rollback path.

- *Ordering.* The outbox publisher keys Kafka messages by `event_key`, so
  per-event partition order is not guaranteed. Writes are versioned instead:
  ES `version_type=external_gte` with `version` = payload `occurred_at` in
  epoch microseconds. Stale writes/deletes 409 and are discarded as satisfied
  intent (`Search index write discarded as stale`, info); equal-version
  replays succeed idempotently. Clock regression on the event-service host is
  the one way to break this — occurred_at is wall-clock emission time.
- *Skips.* Pre-enrichment history (payloads without `schema_version >= 2`) and
  non-document events (`ticket.generated`, …) are skipped and committed.
  Malformed `schema_version >= 2` payloads go to the DLQ
  (`catalog.events.dlq`). There is no replay command for that DLQ.
- *Index repair.* Once enriched payloads exist in the topic, a lost/corrupt
  index is rebuilt by replaying `catalog.events` — reset the group and restart
  the worker:
  `kafka-consumer-groups --bootstrap-server localhost:9092 --group
  ticketarget-search-indexer --topic catalog.events --reset-offsets
  --to-earliest --execute`. `catalog:backfill-event-directory` is for events
  MISSING from the topic (its keys embed the payload schema version, so a
  shape upgrade re-emits every event once; same-shape re-runs dedupe in the
  outbox and equal-`occurred_at` replays are no-ops for every consumer).
- *Rollout sequence (performed 2026-07-05).* Deploy event-service (enriched
  payloads) → deploy worker on `ticketarget:search:index` → run
  `catalog:backfill-event-directory` → verify document counts and sample
  fields (`venue_name`, `min_price`) against the catalog → keep Debezium
  running for the validation window.
- *Rollback.* Switch the worker compose command back to
  `ticketarget:cdc:consume`. The old group's offsets and the Debezium
  connector are untouched, so the CDC path resumes where it left off and
  overwrites any divergence from DB truth (unversioned writes still win over
  versioned docs only via full reindex — after a rollback, touch affected rows
  or re-register the connector with `snapshot.mode=always` to force a
  resnapshot).
- *Decommission (after the validation window, target with the
  `CATALOG_STATUS_DUAL_WRITE` flag-off ~2026-07-12+).* Remove the Debezium
  connector + `debezium-connect` service + `make register-cdc`, delete the
  worker's CDC code path (`ticketarget:cdc:consume`, `PdoEventProjection`,
  DB env/`postgres-replica` dependency), and drop `wal_level=logical` if
  nothing else needs it. Update this note when it happens.

**RS256/JWKS auth cutover (2026-07-05).** The Users service is the sole JWT
issuer. It signs with RS256 using the private key at
`AUTH_JWT_PRIVATE_KEY_PATH` (mounted read-only from `infra/keys/jwt-private.pem`,
generated by `make jwt-keys`, gitignored) under key id `AUTH_JWT_ACTIVE_KID`
(default `k1`), and publishes the public half at
`GET /auth/.well-known/jwks.json`. booking- and event-service verify RS256 by
fetching that JWKS (`AUTH_JWKS_URL`, cached `AUTH_JWKS_CACHE_TTL`s, default 1h;
stale-on-error so a transient Users outage does not break auth; one throttled
refetch on an unknown `kid`). Boot fails fast if the private key is missing or
not RSA. event-service no longer reads the `users`/`personal_access_tokens`
tables — the old Sanctum `admin:token` path is gone; mint an admin JWT with
`make admin-token EMAIL=<existing admin>` (`users-service artisan
auth:issue-token`, admin-only).

*HS256 flag-off — DONE (2026-07-06).* The migration window (`AUTH_JWT_ACCEPT_HS256`)
has been closed. `AUTH_JWT_ACCEPT_HS256=false` for all three services and
`AUTH_JWT_SECRET` is REMOVED from every service's environment, so a leaked shared
secret cannot forge tokens even if the flag regressed. One subtlety handled:
booking-service's `AUTH_JWT_SECRET` also fed the QR ticket-code HMAC
(`TicketCodeIssuer`), so that was decoupled first into its own `TICKET_CODE_SECRET`
(config `ticket_code.secret`; `make keys` now generates it) — set to the old
secret's value so previously-issued codes still verify. Verified live (2026-07-06):
a forged HS256 admin token signed with the old shared secret is rejected 401 on
booking, event, AND users `/auth/me`, while RS256 admin JWTs still succeed
(200/201) and ticket-code issue/verify round-trips cleanly. To re-open a window
(e.g. a future key migration that needs HS256), set `AUTH_JWT_ACCEPT_HS256=true`
and restore a shared `AUTH_JWT_SECRET` — but that is a regression, not the norm.
Note: recreating the auth services detaches Traefik from the edge network
(gateway returns 000/404); `make reload-gateway` (recreate Traefik) restores it.

*Key rotation.* Introduce a new private key under a new `AUTH_JWT_ACTIVE_KID`;
publish BOTH public keys in the JWKS (set `AUTH_JWT_PREVIOUS_PUBLIC_KEY_PATH` +
`AUTH_JWT_PREVIOUS_KID` on users-service) for at least
`max_token_ttl + AUTH_JWKS_CACHE_TTL + clock_skew` (>= ~25h with the defaults)
so tokens signed by the old key keep verifying until they expire. The issuer
signs only with the active kid; verifiers refetch on a kid miss. Retire the old
key from the JWKS after the overlap.

*Gotchas.* (1) Gateway routers are on the `web` (http) entrypoint only — reach
the API over `http://api.ticketarget.localhost`, not https. (2) Dropping a
composer dependency (e.g. Sanctum) from a running service needs
`bootstrap/cache/packages.php` + `services.php` regenerated (`rm` them then
`php artisan package:discover`) AND a container restart — FrankenPHP workers
hold the old package manifest in memory, so a stale `SanctumServiceProvider`
reference throws `Class not found` until the workers reload.
