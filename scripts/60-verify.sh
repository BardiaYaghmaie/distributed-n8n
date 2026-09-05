#!/usr/bin/env bash
# Proves the platform is genuinely distributed, rather than one n8n wearing three hats.
#
# It calls the webhook once and then checks three separate things:
#   1. the response is what the workflow is supposed to return
#   2. the hostname in that response belongs to a pod labelled component=worker
#   3. that Worker's own log mentions this execution
#
# 2 and 3 matter separately. 2 could in principle be a workflow reporting a hostname that is not
# its own; 3 is n8n's log on the pod itself. Together they leave no room for Main to have run it.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
. scripts/common.sh
require_cluster

NAMESPACE="n8n"
BASE_URL="${N8N_BASE_URL:-http://n8n.localtest.me}"

echo "==> POST ${BASE_URL}/webhook/test"
REQUEST='{"message":"hello","request_id":"12345"}'
echo "    request:  ${REQUEST}"

# -f makes curl exit non-zero on an HTTP error, so `set -e` stops here rather than letting the
# checks below run against an error page.
RESPONSE=$(curl -sf -X POST "${BASE_URL}/webhook/test" \
  -H 'Content-Type: application/json' -d "$REQUEST")
echo "    response: ${RESPONSE}"
echo

# One line per field, each pulling one value out of the JSON. Repetitive on purpose: you can read
# any single line and know exactly what it does.
MESSAGE=$(echo "$RESPONSE"      | python3 -c "import json,sys; print(json.load(sys.stdin)['message'])")
REQUEST_ID=$(echo "$RESPONSE"   | python3 -c "import json,sys; print(json.load(sys.stdin)['request_id'])")
PROCESSED=$(echo "$RESPONSE"    | python3 -c "import json,sys; print(json.load(sys.stdin)['processed'])")
EXECUTED_BY=$(echo "$RESPONSE"  | python3 -c "import json,sys; print(json.load(sys.stdin)['executed_by'])")
EXECUTION_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['execution_id'])")

echo "==> checking the response"
# "True" with a capital T because python prints a JSON true that way.
if [ "$MESSAGE" != "hello" ] || [ "$REQUEST_ID" != "12345" ] || [ "$PROCESSED" != "True" ]; then
  echo "FAIL: expected hello/12345/true, got ${MESSAGE}/${REQUEST_ID}/${PROCESSED}" >&2
  exit 1
fi
echo "    ok  the workflow echoed the request and marked it processed"

echo
echo "==> checking that a Worker ran it, not Main"
# executed_by is $env.HOSTNAME read inside the executing pod, which Kubernetes sets to the pod
# name. Ask the API what that pod really is rather than trusting the name to look right.
COMPONENT=$(kubectl -n "$NAMESPACE" get pod "$EXECUTED_BY" \
  -o jsonpath='{.metadata.labels.component}' 2>/dev/null || true)

if [ "$COMPONENT" != "worker" ]; then
  echo "FAIL: executed_by='${EXECUTED_BY}' is labelled component='${COMPONENT:-no such pod}', not 'worker'" >&2
  exit 1
fi
echo "    ok  ${EXECUTED_BY} is labelled component=worker"

echo
echo "==> checking that Worker's own log for execution ${EXECUTION_ID}"
# Anchored to 'execution <id> (job'. A bare search for an id like "1" would match half the
# startup log and pass no matter what happened.
if kubectl -n "$NAMESPACE" logs "$EXECUTED_BY" --tail=500 2>/dev/null | grep -q "execution ${EXECUTION_ID} (job"; then
  echo "    ok  the Worker logged it:"
  kubectl -n "$NAMESPACE" logs "$EXECUTED_BY" --tail=500 2>/dev/null \
    | grep "execution ${EXECUTION_ID} (job"
else
  echo "FAIL: execution ${EXECUTION_ID} does not appear in ${EXECUTED_BY}'s log" >&2
  exit 1
fi

echo
echo "==> Main's log for the same execution (it should show the hand-off, not the run)"
MAIN_POD=$(kubectl -n "$NAMESPACE" get pod -l component=main -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NAMESPACE" logs "$MAIN_POD" --tail=500 2>/dev/null \
  | grep "execution ${EXECUTION_ID} (job" || true

echo
echo "PASS: the request was enqueued by Main and executed by ${EXECUTED_BY}."
