#!/usr/bin/env bash
# Fires N webhook calls at once and counts which Worker answered each one.
#
# 50-verify.sh proves a Worker ran one execution. This proves the queue is actually spreading the
# load: with two Workers and enough requests, both pod names appear. It is also the scaling demo --
# run `make scale REPLICAS=5`, run this again, and five names appear.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
. scripts/common.sh
require_cluster

BASE_URL="${N8N_BASE_URL:-http://n8n.localtest.me}"
COUNT="${1:-20}"

# A fresh directory per run. `mktemp -d` rather than a fixed path so two fanouts running at once
# cannot read each other's replies and report a count larger than the number of requests sent.
REPLIES=$(mktemp -d)
trap 'rm -rf "$REPLIES"' EXIT

echo "==> firing ${COUNT} concurrent requests at ${BASE_URL}/webhook/test"
for i in $(seq 1 "$COUNT"); do
  # The trailing & starts each curl in the background, so all of them are in flight at once and
  # the queue genuinely gains depth. Each reply goes to its own file: n8n returns compact JSON
  # with no trailing newline, so appending to one shared file would run replies together.
  curl -sf -X POST "${BASE_URL}/webhook/test" \
    -H 'Content-Type: application/json' \
    -d "{\"message\":\"fanout\",\"request_id\":\"${i}\"}" \
    -o "${REPLIES}/${i}.json" 2>/dev/null &
done
# Block until every background curl above has finished.
wait

# Pull the pod name out of each reply and collect them in one list, one name per line.
for file in "$REPLIES"/*.json; do
  python3 -c "import json; print(json.load(open('$file'))['executed_by'])" >> "${REPLIES}/pods.txt" 2>/dev/null || true
done

echo
echo "==> executions per Worker:"
# sort groups identical names together, which is what uniq -c needs to count them.
sort "${REPLIES}/pods.txt" | uniq -c | awk '{print "    "$2"  "$1}'

TOTAL=$(wc -l < "${REPLIES}/pods.txt")
WORKERS=$(sort -u "${REPLIES}/pods.txt" | wc -l)
echo
echo "    ${TOTAL} executions across ${WORKERS} Worker(s)"
if [ "$TOTAL" -ne "$COUNT" ]; then
  echo "    $(( COUNT - TOTAL )) request(s) failed"
fi
