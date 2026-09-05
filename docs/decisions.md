# Decisions

The choices in this repository that could reasonably have gone the other way, and why they went
this way. Each one names what it costs.

## Queue mode, not several regular-mode instances

**Reason.** In `regular` mode each n8n replica receives *and* executes; two replicas are two
independent n8n instances sharing a database. Nothing balances execution load, a heavy workflow
blocks the editor on whichever replica got it, and there is no queue to observe or autoscale on.
Queue mode separates enqueueing from executing, which is what every other property here rests on.

**Alternative.** Regular mode with more replicas. Simpler — no Redis at all.

**Trade-off.** Redis becomes a hard dependency: if it is unavailable, nothing can be enqueued.
That is why it runs replicated rather than as one pod, and it is the largest complexity cost in
the repository.

## An operator each for PostgreSQL and Redis, not StatefulSets

**Reason.** A StatefulSet restarts a dead pod. It has no concept of a primary, so it cannot
promote a replica, cannot repoint clients, and cannot rejoin the old primary afterwards. For a
replicated database that promotion *is* the failure handling. CloudNativePG and redis-operator
exist to do it, and `make drill` measures them doing it.

**Alternative.** Single-pod StatefulSets, as in most n8n tutorials. Roughly 100 fewer lines and no
CRDs to learn.

**Trade-off.** Two more operators to install, keep upgraded and understand. For a laptop demo that
is a poor trade; for something demonstrating how the pieces fit at scale, the failover is the
interesting part.

## Redis via Sentinel behind a Service, not a Sentinel-aware client

**Reason.** There is no choice to make. n8n's `QUEUE_BULL_REDIS_*` settings cover host, port,
username, password, TLS and Redis Cluster — there is no Sentinel option. So a failover has to be
invisible from n8n's side, which means one stable hostname whose endpoint moves. redis-operator's
`n8n-redis-master` Service is exactly that.

**Trade-off, stated plainly.** This makes the operator's Service-repointing the single mechanism
that failover depends on, and that mechanism has a history of bugs — the operator's tracker
carries several reports of `-master` going stale after a failover
([#1711](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1711),
[#1779](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1779)). `make drill` exists
partly to check this on your own cluster rather than take it on faith. If it fails there, the
honest fallback is a single Redis with AOF: less available, but it never lies about which node is
the master.

## Gateway API and Traefik, not Ingress and ingress-nginx

**Reason.** ingress-nginx was retired in March 2026 — no further releases and no fixes for
security issues found after that date. Its planned successor, InGate, was abandoned. Building a
reference deployment on it would be teaching people to install an unmaintained proxy.

Gateway API rather than an `Ingress` because it separates the two decisions an Ingress mashes
together: the `Gateway` (which ports are open, which namespaces may publish) belongs to whoever
runs the cluster, and the `HTTPRoute` (which hostname, which Service) belongs to whoever runs the
app. It also expresses timeouts as API fields instead of controller-specific annotations.

**Alternative.** Traefik with plain `Ingress` objects. Fewer new concepts.

**Trade-off.** Gateway API is a separate CRD install, and `HTTPRoute` is less widely known than
`Ingress`. Reading two objects instead of one is the price of the ownership split.

## KEDA on queue depth, not an HPA on CPU

**Reason.** Most n8n workflows are I/O-bound — they wait on an external API. A Worker fully
occupied by ten in-flight HTTP calls is nearly idle by CPU, so a CPU-based HPA would scale *down*
while the queue grows. Queue depth is the number that means "work is piling up".

**Alternative.** No autoscaling, a fixed replica count, and `make scale` by hand.

**Trade-off.** Another operator, and one more thing that writes to the Deployment's replica count
— which is why `kubernetes/50-n8n-worker.yaml` has no `replicas` field. Two controllers fighting
over that number is a genuinely confusing failure.

## Three ConfigMaps, not one

**Reason.** One ConfigMap that every component loads whole makes every variable look like it
applies to everything. Nobody reading it can tell whether `N8N_SECURE_COOKIE` affects the Workers,
because the file does not say. Splitting by *who reads the variable* puts that answer in the file:
`n8n-common` is what both roles must agree on, `n8n-main` is the web server, `n8n-worker` is the
queue consumer.

**Alternative.** One ConfigMap. It is what most n8n Helm charts do.

**Trade-off.** Two `configMapRef` entries per Deployment instead of one, and a rule to follow when
adding a variable: it stays in `n8n-common` unless you can name why the other role never reads it.
The safety that mattered — Main and Workers cannot disagree about the database or the queue — is
unchanged, because what must match still lives in one object both reference.

## Plain manifests, not a Helm chart

**Reason.** The point of this repository is to be read. A chart turns every value into a
`{{ .Values.something }}` and moves the actual configuration into a values file, so understanding
what gets deployed means mentally rendering the template. Plain YAML with the reasoning in
comments is worse to parameterise and much better to learn from.

**Alternative.** A chart, or a Kustomize base with overlays.

**Trade-off.** No environments. Deploying this twice with different settings means editing the
files or wrapping them in Kustomize — which is the right move the moment there is a second
environment, and the wrong one while there is not.

## `$env.HOSTNAME` in a Set node, not `os.hostname()` in a Code node

**Reason.** The workflow's job is to prove which pod executed it. A Code node would do that, but
n8n 2.x runs Code nodes in a separate task-runner process, which means a sidecar container and its
configuration in every Worker pod — infrastructure that exists only to serve the demonstration. A
Set node reading `$env.HOSTNAME` runs in-process and returns the same pod name.

**Trade-off.** It needs `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`, which lets any workflow read the
Workers' environment variables. Acceptable here, where the only workflow is the sample one;
in production, leave the default and prove Worker execution from the logs instead.

## No PgBouncer

**Reason.** The usual reason to add it is connection exhaustion, and this deployment is nowhere
near it: ten Workers at the cap, a small pool each, against `max_connections: 200`.

**Trade-off.** It becomes necessary somewhere around fifty Workers. CloudNativePG has a `Pooler`
resource for exactly this — see [production.md](production.md). Adding it now would be a component
to install, configure and explain that solves a problem this deployment does not have.
