#!/usr/bin/env bash
# Opt-in concurrency smoke against the RUNNING stack (make test-concurrency):
# N parallel buyers race for the SAME seat; exactly one must get a 201 and
# everyone else a 409. The winning hold expires naturally in ~10 minutes.
set -euo pipefail

API=${API:-http://api.ticketarget.localhost}
PARALLEL=${PARALLEL:-5}

echo "Finding an event with an available seat…"
read -r EVENT_ID TICKET_ID < <(python3 - "$API" <<'PY'
import json, sys, urllib.request

api = sys.argv[1]
search = json.load(urllib.request.urlopen(f"{api}/search?size=24"))
for hit in search["results"]:
    detail = json.load(urllib.request.urlopen(f"{api}/event/{hit['id']}"))["data"]
    for ticket in detail.get("tickets") or []:
        if ticket["status"] == "available":
            print(detail["id"], ticket["id"])
            raise SystemExit(0)
raise SystemExit("No available seat found — reseed the catalog first (make seed).")
PY
)
echo "Event $EVENT_ID — $PARALLEL parallel buyers contending for ticket $TICKET_ID"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for i in $(seq 1 "$PARALLEL"); do
  (
    uid=$(python3 -c 'import uuid; print(uuid.uuid4())')
    token=$(curl -s -X POST "$API/queue/join" -H 'Content-Type: application/json' \
      -d "{\"user_id\":\"$uid\",\"event_id\":\"$EVENT_ID\"}" \
      | python3 -c 'import sys, json; print(json.load(sys.stdin)["queue_token"])')
    curl -s -o "$tmp/body.$i" -w '%{http_code}' -X POST "$API/reserve" \
      -H 'Content-Type: application/json' -H "X-Queue-Token: $token" \
      -d "{\"user_id\":\"$uid\",\"tickets\":[\"$TICKET_ID\"]}" > "$tmp/code.$i"
  ) &
done
wait

created=0
conflicted=0
other=0
for f in "$tmp"/code.*; do
  code=$(cat "$f")
  case "$code" in
    201) created=$((created + 1)) ;;
    409) conflicted=$((conflicted + 1)) ;;
    *)
      other=$((other + 1))
      echo "Unexpected HTTP $code: $(cat "${f/code/body}")"
      ;;
  esac
done

echo "Results: ${created}x 201, ${conflicted}x 409, ${other}x other"
if [ "$created" -eq 1 ] && [ "$other" -eq 0 ]; then
  echo "PASS: exactly one buyer got the seat (hold expires in ~10 minutes)."
  exit 0
fi
echo "FAIL: expected exactly one 201 and only 409s otherwise."
exit 1
