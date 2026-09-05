#!/usr/bin/env bash
# Deletes the kind cluster and everything in it.
set -euo pipefail

CLUSTER_NAME="n8n"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "==> deleting the '${CLUSTER_NAME}' cluster"
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "==> no '${CLUSTER_NAME}' cluster to delete"
fi
