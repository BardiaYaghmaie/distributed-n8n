# shellcheck shell=bash
# Sourced by every script. It exists for one reason: to pin every kubectl and helm call to the
# cluster this repository creates.
#
# These scripts install operators, create namespaces and delete pods. Running any of that against
# whatever context kubectl happens to be pointing at -- a work cluster, a production cluster -- is
# a bad afternoon. `kubectl config use-context` is not enough: it changes global state that
# anything else on the machine can change back between two commands.
#
# So kubectl and helm are wrapped here instead, and every call site below is pinned by
# construction. There is no way to forget.
CONTEXT="kind-n8n"

kubectl() { command kubectl --context "$CONTEXT" "$@"; }
helm() { command helm --kube-context "$CONTEXT" "$@"; }

# Fails early and clearly when the cluster is not there, rather than a page of connection errors.
require_cluster() {
  command kubectl config get-contexts -o name | grep -qx "$CONTEXT" || {
    echo "no '${CONTEXT}' context -- run 'make cluster' first" >&2
    exit 1
  }
}
