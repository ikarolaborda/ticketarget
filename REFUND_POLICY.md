# Ticketarget Refund Policy

_Customer-facing policy. The self-service refund flow below is **implemented**:
account holders refund from My Tickets; guests can use their signed entry code
against `POST /booking/{id}/refund`. The `charge.refunded` webhook is the source
of truth that completes the refund and releases the seat._

## Policy

| When you cancel | Refund |
| --- | --- |
| 7 days or more before the event | 100% of the ticket price |
| 48 hours to 7 days before the event | 50% of the ticket price |
| Less than 48 hours before the event | No refund |
| Event cancelled by the organizer | 100%, automatic |

- Refunds always return to the original payment method via Stripe.
- Account holders will request refunds from **My tickets**; guests via a link in
  their confirmation email (verified by the ticket's signed entry code).
- A refunded seat is released for resale; the QR entry code is invalidated.
- Processing time: 5–10 business days, controlled by the card issuer.

## Technical design (deferred increment — acceptance criteria)

1. `bookings.status` column (`paid` → `refund_pending` → `refunded`), default
   `paid`, backfilled.
2. `POST /booking/{id}/refund` — owner-authenticated (bearer, or guest via
   signed entry code); computes the refund tier from `events.date` vs now;
   creates the Stripe refund with an idempotency key = booking id; sets
   `refund_pending`.
3. `charge.refunded` webhook = source of truth: on receipt, set `refunded`,
   release the seat (`booked` → `available`) inside a locked transaction using
   the same guards as the expiry sweeper (never release a seat that was re-sold;
   idempotent on redelivery).
4. Entry-code verification must return `valid:false` for refunded bookings.
5. Tests: tier boundaries (7d/48h edges), double-refund idempotency, webhook
   replay idempotency, seat re-release race vs a concurrent reserve, guest-code
   authorization, partial failure (Stripe ok / DB down) recovery.
