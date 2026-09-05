#!/usr/bin/env bash
# Applies kubernetes/ and waits until the platform is actually usable.
#
# The waits are ordered, and the order matters: n8n runs its database migrations at startup, so a
# Main that starts before PostgreSQL accepts connections crash-loops until it happens to win the
# race. Waiting for the data layer first turns that into a deterministic startup.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
. scripts/common.sh
require_cluster

NAMESPACE="n8n"

echo "==> applying manifests"
# Applied as a directory. The files are numbered so kubectl sends them in a sensible order,
# though Kubernetes would reconcile them in any order eventually.
kubectl apply -f kubernetes/

# The operators create the pods, so there is nothing to `rollout status` -- these are the
# conditions the CRDs themselves report.
echo "==> waiting for PostgreSQL (3 instances, one primary)"
kubectl -n "$NAMESPACE" wait cluster/n8n-pg --for=condition=Ready --timeout=900s

echo "==> waiting for Redis (3 replicas + 3 sentinels)"
# `rollout status` errors out immediately on a resource that does not exist yet rather than
# waiting for it, and the operator creates these StatefulSets itself -- Sentinel's only once the
# replication set is up, which on a cold image cache is minutes away. Hence the wait-for-existence
# loop, with the same 900s budget as the rollout.
# n8n-redis-sentinel-sentinel is not a typo: the operator names the StatefulSet after the
# RedisSentinel resource and appends its own suffix.
for sts in n8n-redis n8n-redis-sentinel-sentinel; do
  for i in $(seq 1 180); do
    kubectl -n "$NAMESPACE" get "statefulset/${sts}" >/dev/null 2>&1 && break
    [ "$i" -eq 180 ] && { echo "the operator never created statefulset/${sts}" >&2; exit 1; }
    sleep 5
  done
  kubectl -n "$NAMESPACE" rollout status "statefulset/${sts}" --timeout=900s
done
# The Services exist from the moment the CRs are applied, but `n8n-redis-master` has no endpoint
# until the operator has decided which pod is the master. n8n would fail to connect before then.
echo "==> waiting for the Redis master Service to have an endpoint"
for i in $(seq 1 60); do
  [ -n "$(kubectl -n "$NAMESPACE" get endpointslice -l kubernetes.io/service-name=n8n-redis-master \
    -o jsonpath='{.items[*].endpoints[*].addresses[0]}')" ] && break
  [ "$i" -eq 60 ] && { echo "n8n-redis-master never got an endpoint" >&2; exit 1; }
  sleep 5
done

echo "==> waiting for n8n Main"
kubectl -n "$NAMESPACE" rollout status deployment/n8n-main --timeout=600s

echo "==> waiting for n8n Workers"
kubectl -n "$NAMESPACE" rollout status deployment/n8n-worker --timeout=600s

echo "==> deployed:"
kubectl -n "$NAMESPACE" get pods -o wide
