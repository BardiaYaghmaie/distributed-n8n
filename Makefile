# Every target is one script or one kubectl command. `make all` runs them in order; each is also
# runnable on its own while iterating on a single piece.
#
# Every kubectl call is pinned to the kind-n8n context. These targets delete pods and namespaces,
# and none of that belongs in whatever cluster kubectl happens to be pointing at.
KUBECTL := kubectl --context kind-n8n -n n8n

.PHONY: all cluster operators secrets deploy seed verify drill fanout scale logs credentials down

# From nothing to a verified webhook.
all: cluster operators secrets deploy seed verify

# Create the kind cluster: one control-plane, three workers.
cluster:
	./scripts/10-cluster.sh

# Install Gateway API + Traefik, CloudNativePG, redis-operator and KEDA into the infra namespace.
operators:
	./scripts/20-operators.sh

# Generate the Redis password, the n8n encryption key and the editor login. Never overwrites an
# existing Secret. PostgreSQL's password is CloudNativePG's to generate, not this script's.
secrets:
	./scripts/30-secrets.sh

# Apply kubernetes/ and wait for PostgreSQL, Redis, Main and the Workers.
deploy:
	./scripts/40-deploy.sh

# Create the n8n owner account, then import and activate n8n/workflow.json.
seed:
	./scripts/50-seed.sh

# Call the webhook and prove a Worker executed it.
verify:
	./scripts/60-verify.sh

# Fire N concurrent requests and show how they spread across Workers.  make fanout N=1500
fanout:
	./scripts/70-fanout.sh $(N)

# Kill the PostgreSQL primary, kill the Redis master, and try a connection the NetworkPolicies
# must refuse. Prints how long each recovery took.
drill:
	./scripts/80-drill.sh

# Override KEDA and pin the Worker count by hand.  make scale REPLICAS=5
# KEDA takes it back at the next poll -- to hold a number, edit minReplicaCount in
# kubernetes/70-autoscale.yaml.
scale:
	$(KUBECTL) scale deployment/n8n-worker --replicas=$(REPLICAS)
	$(KUBECTL) rollout status deployment/n8n-worker --timeout=180s

# Follow every Worker's log at once.
logs:
	$(KUBECTL) logs -l component=worker --tail=50 -f --prefix

# Print the generated login for the editor at http://n8n.localtest.me
credentials:
	@echo "url:      http://n8n.localtest.me"
	@echo "email:    $$($(KUBECTL) get secret n8n-app -o jsonpath='{.data.email}' | base64 --decode)"
	@echo "password: $$($(KUBECTL) get secret n8n-app -o jsonpath='{.data.password}' | base64 --decode)"

# Delete the cluster.
down:
	./scripts/teardown.sh
