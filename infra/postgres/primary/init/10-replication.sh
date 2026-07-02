#!/usr/bin/env bash
set -euo pipefail

# Creates (or realigns) the replication role and ensures the pg_hba replication
# rules exist. Idempotent and safe to run either during initdb or manually via
# `docker compose exec postgres-primary bash /docker-entrypoint-initdb.d/10-replication.sh`
# on an already-initialized cluster.
REP_USER="${REPLICATION_USER:-replicator}"
REP_PASS="${REPLICATION_PASSWORD:-change-me-replication}"

psql_admin() { psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" "$@"; }

# SUPERUSER lets Debezium auto-create the filtered publication and run the
# snapshot without owning each table. Acceptable for this self-contained stack;
# a hardened deployment would instead pre-create the publication and grant only
# REPLICATION + SELECT.
if psql_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${REP_USER}'" | grep -q 1; then
    psql_admin -c "ALTER ROLE ${REP_USER} WITH REPLICATION LOGIN SUPERUSER PASSWORD '${REP_PASS}';"
else
    psql_admin -c "CREATE ROLE ${REP_USER} WITH REPLICATION LOGIN SUPERUSER PASSWORD '${REP_PASS}';"
fi

HBA="${PGDATA}/pg_hba.conf"
if ! grep -qE "replication[[:space:]]+${REP_USER}" "${HBA}"; then
    {
        echo "host    replication     ${REP_USER}     0.0.0.0/0       scram-sha-256"
        echo "host    all             ${REP_USER}     0.0.0.0/0       scram-sha-256"
    } >> "${HBA}"
fi

# Apply pg_hba changes immediately (a no-op cost during initdb, required when
# this script is re-run against a running server).
psql_admin -c "SELECT pg_reload_conf();"
