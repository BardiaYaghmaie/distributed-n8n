#!/usr/bin/env bash
# The failure drills. Three claims this repository makes, each tested by breaking something on
# purpose:
#
#   1. losing the PostgreSQL primary is survivable   -- CloudNativePG promotes a replica
#   2. losing the Redis master is survivable         -- Sentinel elects one, the operator repoints
#   3. the NetworkPolicies are actually enforced     -- a connection that must fail, fails
#
# Recovery is measured the way a user would notice it: how long until the webhook answers again.
# Not "until the pod is Ready", which is always a flattering number and never the one that
# matters.
#
# Run it after `make all`. It deletes pods on purpose.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
. scripts/common.sh
require_cluster

NAMESPACE="n8n"
BASE_URL="${N8N_BASE_URL:-http://n8n.localtest.me}"

webhook() {
  curl -sf -m 5 -o /dev/null -X POST "${BASE_URL}/webhook/test" \
    -H 'Content-Type: application/json' -d '{"message":"drill","request_id":"drill"}'
}

# Polls until the webhook answers three times in a row, and prints the seconds that took.
#
# Three in a row, not one: right after a failover the first call can succeed on a connection that
# has not noticed anything yet, which would report a recovery that has not happened. Requiring a
# run of successes is what makes the number honest.
time_until_recovered() {
  local start streak=0
  start=$(date +%s)
  for _ in $(seq 1 150); do
    if webhook; then
      streak=$((streak + 1))
      [ "$streak" -ge 3 ] && { echo "$(( $(date +%s) - start ))"; return 0; }
    else
      streak=0
    fi
    sleep 2
  done
  echo "TIMEOUT"
  return 1
}

# Reads whichever pod currently holds a role label. The label disappears for a few seconds
# mid-failover, so this retries rather than asking once.
#
# The second argument is a pod name to refuse. Without it this reports the wrong answer: a pod
# that has just been deleted keeps its `redis-role=master` label for a moment while it
# terminates, so asking straight after the kill returns the pod you killed and the drill claims a
# failover that has not happened yet.
pod_with_label() {
  local selector="$1" exclude="${2:-}" name
  for _ in $(seq 1 90); do
    name=$(kubectl -n "$NAMESPACE" get pods -l "$selector" \
      --field-selector status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$name" ] && [ "$name" != "$exclude" ]; then
      echo "$name"
      return 0
    fi
    sleep 2
  done
  echo "none"
}

echo "==> baseline: the webhook answers"
webhook || { echo "the webhook is not working before the drill even starts" >&2; exit 1; }
echo "    ok"

# ---------------------------------------------------------------------------------------------
echo
echo "==> drill 1: kill the PostgreSQL primary"
PRIMARY=$(pod_with_label 'cnpg.io/cluster=n8n-pg,cnpg.io/instanceRole=primary')
echo "    primary is ${PRIMARY}"
# --force --grace-period=0: a graceful delete lets CloudNativePG run a controlled switchover,
# which is the easy case. This is closer to the node going away.
kubectl -n "$NAMESPACE" delete pod "$PRIMARY" --force --grace-period=0 >/dev/null 2>&1
ELAPSED=$(time_until_recovered) || true
NEW_PRIMARY=$(pod_with_label 'cnpg.io/cluster=n8n-pg,cnpg.io/instanceRole=primary' "$PRIMARY")
echo "    promoted:  ${NEW_PRIMARY}"
echo "    recovered: ${ELAPSED}s"
[ "$ELAPSED" = "TIMEOUT" ] && { echo "FAIL: the webhook never came back after the PostgreSQL failover" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
echo
echo "==> drill 2: kill the Redis master"
MASTER=$(pod_with_label 'app=n8n-redis,redis-role=master')
echo "    master is ${MASTER}"
kubectl -n "$NAMESPACE" delete pod "$MASTER" --force --grace-period=0 >/dev/null 2>&1
ELAPSED=$(time_until_recovered) || true
NEW_MASTER=$(pod_with_label 'app=n8n-redis,redis-role=master' "$MASTER")
echo "    elected:   ${NEW_MASTER}"
echo "    recovered: ${ELAPSED}s"
[ "$ELAPSED" = "TIMEOUT" ] && { echo "FAIL: the webhook never came back after the Redis failover" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
echo
echo "==> drill 3: the NetworkPolicies are enforced"
# From the default namespace, which nothing in kubernetes/80-networkpolicy.yaml allows. If this
# connection succeeds, the policies are being ignored -- which is exactly what a CNI without
# NetworkPolicy support does, silently and without an error anywhere.
echo "    reaching n8n-pg-rw:5432 from the default namespace (this must fail)"
if kubectl -n default run "netpol-drill-$$" --rm -i --restart=Never --quiet \
     --image=busybox:1.37 --command -- \
     timeout 8 nc -z n8n-pg-rw.n8n.svc.cluster.local 5432 >/dev/null 2>&1; then
  echo "    FAIL: the connection succeeded -- NetworkPolicy is not being enforced" >&2
  exit 1
fi
echo "    ok  refused"

echo
echo "PASS: both failovers recovered and the policies hold."
