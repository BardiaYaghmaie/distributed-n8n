#!/usr/bin/env bash
# Installs the four operators the platform is built on, each pinned to an exact version and each
# waited on before the next starts.
#
#   Gateway API + Traefik   routing        (the entry point)
#   CloudNativePG           PostgreSQL     (replication and failover)
#   redis-operator          Redis          (replication and Sentinel failover)
#   KEDA                    autoscaling    (Workers, on queue depth)
#
# All four go into one namespace, `infra`. Cluster-wide machinery lives together and apart from
# the application: `kubectl -n infra get pods` is the platform, `kubectl -n n8n get pods` is the
# workload, and deleting the n8n namespace cannot take an operator with it.
#
# Everything comes from the projects' own registries and Helm repositories. There is no mirror and
# nothing is side-loaded, so kubernetes/ applies unchanged to any cluster with internet access.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/common.sh
. scripts/common.sh
require_cluster

GATEWAY_API_VERSION="v1.6.2"
TRAEFIK_CHART_VERSION="41.4.0"
CNPG_CHART_VERSION="0.29.0"      # CloudNativePG 1.30.0
REDIS_OPERATOR_CHART_VERSION="0.26.1"
KEDA_CHART_VERSION="2.20.2"

# Pulls are the slow part of a first run and vary with the network, so every wait is generous.
# A timeout here is almost always a slow download, not a broken install.
TIMEOUT="15m"

echo "==> creating the infra namespace"
kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ---------------------------------------------------------------------------------------------
# Gateway API
#
# The CRDs are not part of Kubernetes and no controller ships them: they are installed once, by
# whoever owns the cluster, and every controller then implements them. "standard" is the GA
# channel -- GatewayClass, Gateway and HTTPRoute, which is all this platform routes with.
echo "==> installing Gateway API ${GATEWAY_API_VERSION} (standard channel)"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# ---------------------------------------------------------------------------------------------
# Traefik, as the Gateway API implementation.
#
# ingress-nginx was retired in March 2026 -- no more releases, no more CVE fixes -- so it is not
# something to build a reference deployment on. Traefik is actively maintained and implements
# Gateway API natively.
echo "==> installing Traefik ${TRAEFIK_CHART_VERSION}"
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update traefik >/dev/null

TRAEFIK_ARGS=(
  --version "$TRAEFIK_CHART_VERSION"
  --namespace infra

  # Turn on the Gateway API provider, and let the chart create the GatewayClass that Gateways
  # reference by name.
  --set providers.kubernetesGateway.enabled=true
  --set gatewayClass.enabled=true
  # But not the Gateway itself: kubernetes/60-gateway.yaml declares that, because which hostnames
  # and which namespaces may attach routes is a decision that belongs in git next to the routes,
  # not in a Helm flag.
  --set gateway.enabled=false

  # NodePort, not the chart's default LoadBalancer: kind has no cloud provider, so a LoadBalancer
  # Service sits at <pending> forever and `helm --wait` times out on a perfectly healthy install.
  --set service.spec.type=NodePort
  # This exact port is the one kind/cluster.yaml forwards from the host's port 80. Change it here
  # and it has to change there too.
  --set ports.web.nodePort=30080

  --wait --timeout "$TIMEOUT"
)
helm upgrade --install traefik traefik/traefik "${TRAEFIK_ARGS[@]}"

# ---------------------------------------------------------------------------------------------
# CloudNativePG
#
# The project also publishes a single-file manifest, but it hardcodes the cnpg-system namespace.
# The chart is the same operator and takes --namespace, which is what keeps all four here.
echo "==> installing CloudNativePG (chart ${CNPG_CHART_VERSION})"
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null
helm upgrade --install cloudnative-pg cnpg/cloudnative-pg \
  --version "$CNPG_CHART_VERSION" \
  --namespace infra \
  --wait --timeout "$TIMEOUT"

# ---------------------------------------------------------------------------------------------
# redis-operator
echo "==> installing redis-operator ${REDIS_OPERATOR_CHART_VERSION}"
helm repo add ot-helm https://ot-container-kit.github.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update ot-helm >/dev/null
helm upgrade --install redis-operator ot-helm/redis-operator \
  --version "$REDIS_OPERATOR_CHART_VERSION" \
  --namespace infra \
  --wait --timeout "$TIMEOUT"

# ---------------------------------------------------------------------------------------------
# KEDA
#
# Scales the Workers on how deep the queue is. A CPU-based HorizontalPodAutoscaler is the wrong
# signal here: a Worker waiting on a slow HTTP call is nearly idle by CPU while the queue grows
# behind it, so a CPU HPA would scale down at exactly the wrong moment.
echo "==> installing KEDA ${KEDA_CHART_VERSION}"
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update kedacore >/dev/null
helm upgrade --install keda kedacore/keda \
  --version "$KEDA_CHART_VERSION" \
  --namespace infra \
  --wait --timeout "$TIMEOUT"

echo "==> operators ready:"
kubectl -n infra get pods
