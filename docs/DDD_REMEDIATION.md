# DDD Remediation RFC — Bounded Contexts, Payment, and Inventory Ownership

Status: in progress (2026-07-05). Companion to `ARCHITECTURE.md`.

## Implementation status (2026-07-05)

- **Phase 1 — DONE.** `payments` table (one per reservation) + `Payment`
  aggregate with a guarded state machine (`pending → captured →
  partially_refunded/refunded | failed`), migration backfill grouping legacy
  bookings by `(reservation_id, charge_id)`, `bookings.payment_id`.
  `bookings.charge_id` is kept as a denormalized projection (API/display);
  money truth lives on the Payment. The webhook remains the source of truth:
  reconcile assigns the authoritative refunded total (monotonic, clamped).
- **Phase 2 — CUTOVER DONE (2026-07-05).** `seat_inventory` is the inventory
  authority: reserve/confirm/sweep/refund-release read and write it
  exclusively (lockForUpdate on inventory rows), and it carries the static
  seat identity (`seat`, `price`, `type`, `zone_id`) so those paths never
  touch catalog tables. Seeded once by `booking:seed-inventory`
  (fill-missing-only, rerunnable); new tickets arrive via `ticket.generated`
  `tickets[]` through `catalog:consume`. Buyer availability is served by
  booking (`GET /booking/availability/{event}`: per-ticket status + zone
  aggregates) and merged over the catalog's static seat data in the SPA.
  Rollback bridge: `CATALOG_STATUS_DUAL_WRITE` (default on) mirrors every
  transition to `tickets.status`; `booking:verify-inventory --strict` now
  checks the MIRROR against the inventory. While the flag is on, rollback =
  point reads back at catalog; once it is off, rollback additionally needs a
  `seat_inventory` → `tickets` backfill. Turn it off only after a sustained
  zero-drift window. Catalog's own `tickets.status` writes ceased with this
  cutover (single writer via booking's mirror).
- **Phase 3 — SEEDED (both contexts).** Transactional `outbox_messages`
  (unique `event_key` dedupe) written for `payment.captured`,
  `booking.confirmed`, `payment.refunded`; `outbox:publish` ships to Kafka
  (`booking.events`) every minute on the scheduler. event-service now has the
  same outbox and emits `ticket.generated` (event-carried state:
  `{event_id, zone_id, count, tickets[]}`) to `catalog.events` from both
  generation paths — zone generation keys on the zone id (generate-once),
  manual additions key on the gateway `X-Request-Id` (retry dedupe); the
  `event-scheduler` compose service runs its publisher. **Worker CDC migration
  DONE (2026-07-05):** the search worker consumes `catalog.events` integration
  events (`event.created`/`event.updated`/`event.deleted`, event-carried state
  with `schema_version` 2: full document fields + embedded venue identity +
  in-transaction `min_price`; both ticket-generation paths re-emit
  `event.updated` so price changes propagate) and builds documents from
  payloads alone — its cross-context DB read is gone. Out-of-order delivery is
  handled with ES `external_gte` versioning on emission-time microsecond
  `occurred_at`. Raw-table Debezium CDC is deprecated; connector + old command
  are kept only as the rollback path until decommission (see OPERATIONS.md).
- **Phase 4 — JOINS REMOVED (isolation pending).** Purchase-time snapshots on
  bookings (`seat`, `ticket_type`, `event_name`, `event_id`, `event_date`) and
  reservations (`seats` json at reserve), with a rerunnable fill-missing-only
  backfill. MyBookings, the admin bookings feed, the admin top-events sales
  aggregation, and reservation rehydration are now booking-local reads
  (post-snapshot reservations collapse per-ticket status to the aggregate
  reservation state by design). The former residual cross-context read — the
  admin capacity count — is GONE (2026-07-05): booking owns
  `catalog_capacity_ledger`, a projection of `ticket.generated` events from
  `catalog.events` (`catalog:consume` on the scheduler; one row per
  `event_key`, capacity = SUM(count), replay-safe). Pre-outbox history was
  seeded through the same pipe by `catalog:backfill-ticket-events` (zone
  events reuse the live deterministic key; manual remainders are
  cutoff-bounded); `booking:verify-capacity --strict` is the parity gate while
  the shared DB still allows comparison. Snapshots are purchase-time truth:
  catalog edits after purchase do not rewrite receipts. The confirm-time
  snapshot capture is booking-local too (2026-07-05): `catalog_event_directory`
  projects `event.created`/`event.updated` from `catalog.events`
  (last-write-wins on emission-time microsecond `occurred_at`;
  `catalog:backfill-event-directory` seeded history), and
  `ConfirmBookingAction` reads it with a logged, write-through fallback to the
  shared `events` table until the rollout converges. Schema-per-context
  isolation itself is still open; remaining catalog touches in booking are the
  legacy-row snapshot fallbacks (`RefundBookingAction`,
  `ShowReservationController`), the transitional confirm fallback above, the
  Phase-2 status mirror (`CATALOG_STATUS_DUAL_WRITE`), and the deliberate
  verify gates — all transitional, none in the reporting or steady-state
  purchase path.
- **Phase 5 — DONE (2026-07-05).** `users`, `personal_access_tokens`,
  `is_admin` migrations live in users-service (identical filenames: the shared
  `migrations` ledger prevents re-runs). **JWKS/RS256 (2026-07-05):**
  users-service is the sole JWT issuer — it signs RS256 with a private key only
  it holds (`AUTH_JWT_PRIVATE_KEY_PATH`, kid `AUTH_JWT_ACTIVE_KID`) and
  publishes the public key at `GET /auth/.well-known/jwks.json`. booking- and
  event-service became verify-only: they fetch the JWKS (cached, stale-on-error,
  one refetch on kid miss), select the key by `kid`, and verify with
  `openssl_verify`. The HS256 migration window is now CLOSED (2026-07-06):
  `AUTH_JWT_ACCEPT_HS256=false` everywhere and `AUTH_JWT_SECRET` removed from all
  services (booking's QR ticket-code HMAC was decoupled into `TICKET_CODE_SECRET`
  first) — a forged HS256 token signed with the old shared secret is now rejected
  on all services (verified live). This closes the forgery hole where any of the
  three services holding the shared secret could mint admin tokens.
  event-service's Sanctum `admin:token` path is REMOVED (Sanctum dependency,
  `User` model, `config/auth.php`, guard config all gone) — its last read of the
  `users`/`personal_access_tokens` tables is eliminated, unblocking that service
  from schema isolation (b). Admin JWTs for CLI/service callers now come from
  `users-service artisan auth:issue-token` (admin-only). The RS256/JWK-to-PEM
  construction is hand-rolled (zero new composer deps, DER-roundtrip tested
  against openssl keys). `personal_access_tokens` table is left in place (dead,
  no readers) — dropping it is a users-service follow-up.

## 1. The two questions, answered

**"Are payments tied to bookings a violation?"** Partially. Coupling *payment
orchestration* to the purchase flow is correct — payment is a step of the
Ordering/Booking process, and reference architectures (eShop's Ordering +
Payment processor) keep them in separate contexts that talk via integration
events, not in one transaction script. What we violated is *modeling*, not
*placement*: there is no Payment aggregate at all. `charge_id` and `amount`
are columns on `bookings`, and because a booking row is one-per-ticket, a
single Stripe charge is duplicated across N rows
(`services/booking-service/database/migrations/2026_01_02_000002_create_bookings_table.php`).
The payment lifecycle (charge, compensating refund, webhook reconciliation,
partial refunds) is scattered across `ConfirmBookingAction`,
`RefundBookingAction`, `ReconcileRefundAction` and the webhook controller,
with no single owner of payment state. The good news: a port/adapter seam
already exists (`app/Domain/Payment/PaymentGateway` +
`app/Infrastructure/Payment/StripePaymentGateway`), so the anti-corruption
layer is seeded.

**"Did the edge services violate bounded contexts?"** The edge itself did not
— Traefik routes map paths 1:1 to services (`/events|/venues` → event,
`/reserve|/booking|/queue` → booking, `/auth` → users, `/search` → search).
The violations are *behind* the edge, in the data plane:

| # | Violation | Evidence | Severity |
|---|-----------|----------|----------|
| V1 | All contexts share one Postgres database; integration is shared tables, not contracts | `docker-compose.yml` — event, booking, users all get `DB_DATABASE: ${POSTGRES_DB}` | High |
| V2 | Ticket aggregate has two writers: event-service creates tickets, booking-service mutates `tickets.status` through its own model | booking `app/Models/Ticket.php` ("shared data plane"), `ReserveSeatsAction`, `ConfirmBookingAction` | High |
| V3 | Cross-context SQL joins | booking's `AdminStatsController` joins `tickets`+`events`; `RefundBookingAction` reads `tickets` for policy; `ShowReservationController` reads `tickets` | Medium |
| V4 | Identity schema owned by the wrong context: `users` + `personal_access_tokens` migrated by **event-service**; users-service has zero migrations | `services/event-service/database/migrations/2026_01_01_000004_create_users_table.php` | Medium |
| V5 | No integration events; the only async contract is Debezium tailing raw table schemas (internal schema = public contract) | `docker-compose.yml` worker/CDC config | Medium |
| V6 | No Payment aggregate (see above) | bookings migration, `ConfirmBookingAction` | Medium |

What is already *right*: search-service is hexagonal and read-only (textbook
CQRS projection); the reserve/confirm flow's idempotency (Stripe key =
reservation id) and compensation logic are sound; the queue/waiting-room and
admin routes live with their contexts.

## 2. Target context map

One organizing principle (per design review): **booking-service owns the
entire synchronous purchase consistency boundary** — reservations, sellable
inventory state, and payment orchestration. Event-service owns catalog and
*seat supply definition*, not volatile sell-state.

- **Catalog (event-service)** — events, venues, zones, seat definitions,
  pricing. Emits `TicketsGenerated`, `EventUpdated` integration events.
- **Booking/Ordering (booking-service)** — Reservation/Order aggregate
  (groups per-ticket lines; unit of payment, expiry, refund), booking-owned
  `seat_inventory` (available/held/booked/released), queue admission.
- **Payments (module inside booking-service)** — Payment aggregate: one per
  reservation; state machine `pending → captured → partially_refunded →
  refunded | failed`; owns provider ids, idempotency keys, webhook
  reconciliation. Separate *context*, not (yet) a separate *service* — DDD
  requires an explicit boundary, not a network hop.
- **Identity (users-service)** — owns `users`/PAT schema; sole JWT issuer.
- **Search (search-service + worker)** — unchanged; projection consumer.

## 3. Phased plan (dependency-ordered)

**Phase 1 — Payment aggregate (low risk, do first).**
Add `payments` table in booking-service: `id, reservation_id (unique),
provider, provider_charge_id, provider_payment_intent_id, amount, currency,
status, refunded_amount, failure_reason, idempotency_key, timestamps`.
Bookings gain `payment_id` and drop per-row `charge_id`/`amount` duplication
(backfill: group existing rows by `charge_id`). `ConfirmBookingAction`
creates the Payment, transitions it, and the webhook reconciles against the
Payment aggregate — not against booking rows. Decide capture mode explicitly
(authorize-then-capture reduces refund churn for on-sales; if immediate
capture stays, Payment owns compensation centrally). Keep the existing
`PaymentGateway` port.

**Phase 2 — Inventory ownership flip (highest risk, shadow-mode).**
1. Create booking-owned `seat_inventory` (per-seat rows for seated zones;
   bucketed atomic counters for standing/GA to avoid hot per-row locking).
2. Backfill from `tickets`; dual-write both `tickets.status` and
   `seat_inventory` on reserve/confirm/release; legacy stays source of truth.
3. Compare (mismatch dashboard, oversell counters); load-test on-sale
   contention against the new tables (lock scope, deadlocks, hot rows).
4. Flip reads, then stop writing `tickets.status`; event-service keeps at
   most a projected availability copy for display.
The DB must enforce no-oversell (unique constraints + row locks); Redis locks
remain a contention dampener only. A synchronous "reserve API" on
event-service was considered and rejected as end-state: it keeps the hottest
consistency path cross-context under spike load.

**Phase 3 — Outbox + integration events (starts inside Phases 1–2).**
Any *new* event (`PaymentCaptured`, `TicketsGenerated`, `SeatInventoryChanged`)
is published via an outbox table + Debezium outbox event router from day one.
Legacy raw-table CDC for the search projection is deprecated after the
inventory cutover, when the worker switches to explicit events.

**Phase 4 — Schema isolation (kill V1/V3).**
Postgres schema-per-context with separate credentials so cross-context joins
*fail*. Replace each join first: admin stats → reporting read model (CDC- or
event-fed); refund-policy check → snapshot `event_date`/policy fields onto
the reservation at reserve time (also fixes policy drift for historical
bookings); reservation display → snapshot seat labels. Classify every current
join as transactional / display / policy / reporting and assign a replacement
before revoking access.

**Phase 5 — Identity cleanup (off the critical path).**
Move `users`/PAT migrations to users-service; other services treat `user_id`
as an opaque claim. Optionally RS256/JWKS so only Identity mints tokens
(today `AUTH_JWT_SECRET` is symmetric and shared by three services — any of
them can forge admin tokens).

## 4. Key risks

- The inventory flip can introduce oversells or phantom availability if
  shadow validation is weak — the dual-write comparison window and load tests
  are mandatory gates, with rollback = flip reads back to legacy.
- Payment remodel must bridge old `charge_id`s or webhook reconciliation and
  finance reporting break.
- Schema isolation breaks admin reporting unless read models land first.
- Snapshotting policy data into booking raises policy-versioning questions
  for historical rows — version the snapshot.
