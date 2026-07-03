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
