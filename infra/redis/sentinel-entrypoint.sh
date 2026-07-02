#!/bin/sh
set -eu

# Render the sentinel config at runtime so the master IP is resolved fresh,
# then start sentinel. Quorum of 2 across three sentinels survives one failure.
CONF=/tmp/sentinel.conf
cat > "$CONF" <<EOF
port 26379
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor ${SENTINEL_MASTER} redis-master 6379 ${SENTINEL_QUORUM}
sentinel auth-pass ${SENTINEL_MASTER} ${REDIS_PASSWORD}
sentinel down-after-milliseconds ${SENTINEL_MASTER} 5000
sentinel failover-timeout ${SENTINEL_MASTER} 10000
sentinel parallel-syncs ${SENTINEL_MASTER} 1
EOF

exec redis-server "$CONF" --sentinel
