#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a streaming replica via pg_basebackup on first start, then hand off
# to the stock Postgres entrypoint. Idempotent: skips clone if data already exists.
if [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
  echo "Cloning from primary ${PRIMARY_HOST} ..."
  until pg_isready -h "${PRIMARY_HOST}" -p 5432; do
    echo "Waiting for primary ..."
    sleep 2
  done

  export PGPASSWORD="${REPLICATION_PASSWORD}"
  pg_basebackup \
    --host="${PRIMARY_HOST}" \
    --username="${REPLICATION_USER}" \
    --pgdata="$PGDATA" \
    --wal-method=stream \
    --write-recovery-conf \
    --progress --verbose

  chmod 0700 "$PGDATA"
fi

exec docker-entrypoint.sh postgres
