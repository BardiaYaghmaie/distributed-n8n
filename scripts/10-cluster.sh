#!/usr/bin/env bash
# Creates the kind cluster. Nothing else -- the operators go in separately in 20-operators.sh, so
# a broken operator install does not mean rebuilding the cluster to retry it.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
. scripts/common.sh

CLUSTER_NAME="n8n"

echo "==> checking prerequisites"
for bin in kind kubectl helm docker curl openssl python3; do
  command -v "$bin" >/dev/null || { echo "missing required tool: $bin" >&2; exit 1; }
done

# Recreate from scratch every time, so `make all` always means the same thing.
# grep -qx is an exact whole-line match: without it a cluster named "n8n-staging" would match.
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "==> deleting the existing '${CLUSTER_NAME}' cluster"
  kind delete cluster --name "$CLUSTER_NAME"
fi

echo "==> creating the kind cluster"
kind create cluster --config kind/cluster.yaml

# kind returns as soon as the API server answers, but the nodes finish registering a moment later
# and the first operator install would race them.
echo "==> waiting for all four nodes to be Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=300s

kubectl get nodes
