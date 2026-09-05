#!/usr/bin/env bash
# Generates the two Secrets this platform needs that no operator generates for it. Nothing here
# is ever written to git -- that is the point of generating them at deploy time instead of
# shipping a secrets.yaml.
#
# PostgreSQL's password is deliberately absent: CloudNativePG creates the database, generates its
# password and publishes it as the Secret `n8n-pg-app`. The component that owns the database owns
# its credential, and nothing else needs to know it.
#
# Both blocks below have the same shape: if the Secret exists, leave it alone. Re-running this
# script never rotates anything, which matters more than it looks --
#   * a new N8N_ENCRYPTION_KEY makes every credential already in the database undecryptable
#   * a new Redis password locks the running Redis pods out of their own replication
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
. scripts/common.sh
require_cluster

NAMESPACE="n8n"

echo "==> ensuring the namespace exists"
kubectl apply -f kubernetes/00-namespace.yaml >/dev/null

echo "==> generating secrets"

# Redis password. Read by n8n as QUEUE_BULL_REDIS_PASSWORD, by the Redis pods themselves, and by
# Sentinel -- all three from this one Secret, so they cannot disagree.
# openssl rand, not $RANDOM: this has to come from a cryptographic source. 24 bytes -> 32 chars.
if kubectl -n "$NAMESPACE" get secret n8n-redis >/dev/null 2>&1; then
  echo "    n8n-redis: already exists, left unchanged"
else
  kubectl -n "$NAMESPACE" create secret generic n8n-redis \
    --from-literal=password="$(openssl rand -base64 24)" >/dev/null
  echo "    n8n-redis: created"
fi

# The key n8n encrypts stored credentials with, plus the owner account for the editor. They share
# a Secret because they share a lifecycle: both are created once, for this installation, and
# neither can be regenerated without consequences.
if kubectl -n "$NAMESPACE" get secret n8n-app >/dev/null 2>&1; then
  echo "    n8n-app: already exists, left unchanged"
else
  kubectl -n "$NAMESPACE" create secret generic n8n-app \
    --from-literal=encryptionKey="$(openssl rand -base64 24)" \
    --from-literal=email=admin@example.com \
    --from-literal=password="$(openssl rand -base64 24)" >/dev/null
  echo "    n8n-app: created"
fi

echo
echo "    'make credentials' prints the editor login."
