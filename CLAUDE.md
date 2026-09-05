# distributed-n8n-on-k8s

A public, educational reference deployment: n8n in queue mode on Kubernetes, highly available,
on a local kind cluster. `make all` builds it from nothing.

The repository is meant to be *read* as much as run. Its value is the reasoning in the comments,
not the YAML.

## Shape

- `kubernetes/*.yaml` — the deployment, plain manifests, `kubectl apply -f`.
- `scripts/NN-*.sh` — one script per Makefile target, numbered in run order.
- `scripts/common.sh` — sourced by all of them; pins kubectl and helm to the kind context.
- `docs/` — architecture, decisions, operations, security, production.

## Conventions

- **Every non-obvious line carries a one-line comment saying *why* it is there** — not what it
  does. Skip the self-evident (`replicas: 1`, resource requests); explain anything that exists
  because of a specific problem (`QUEUE_HEALTH_CHECK_ACTIVE`, the Gateway listener's port 8000,
  `enablePodAntiAffinity`).
- **Never trust the ambient kubectl context.** Everything goes through `scripts/common.sh`, which
  wraps `kubectl` and `helm` as functions pinned to `--context kind-n8n`. `kubectl config
  use-context` is not a substitute: it is global state anything on the machine can change between
  two commands, and it has already caused this repo's scripts to apply to the wrong cluster once.
- **Official upstream only.** Images from the projects' own registries, charts from their own Helm
  repos, exact pinned versions. No mirrors, no `kind load` preloading, no digest overrides,
  nothing local-only. `kubernetes/` must apply unchanged to a real cluster.
- **Never pin an architecture-suffixed image tag** (`n8nio/n8n:2.37.10-arm64`). Bare manifest-list
  tags only, so this builds identically on amd64 and arm64.
- **Block YAML only.** No flow style — no `{}` or `[]` on a value that could be a nested block.
  `podSelector: {}` in a NetworkPolicy is the one legitimate exception, and it means "every pod".
- **ConfigMaps are split by who reads the variable**, not by topic. A variable stays in
  `n8n-common` unless you can name the reason the other role never reads it. What must match
  between Main and Workers lives in one object both reference.
- **Secrets are generated, never committed.** `scripts/30-secrets.sh` is the only thing that
  creates them and it is idempotent — re-running never rotates. PostgreSQL's password is
  CloudNativePG's to generate, not this script's.
- **Never put a comment inside a shell line-continuation.** Bash joins the lines and `#` silently
  comments out every remaining flag; `bash -n` does not catch it. Use a bash array (see
  `TRAEFIK_ARGS` in `scripts/20-operators.sh`) or put the comment above the command.
- **Scripts are POSIX/bash-portable**: no `sed -i` without a backup suffix, no `base64 -w0`, no
  GNU-only `grep -P` / `readlink -f`.
- **No Code nodes in the workflow.** They execute in a separate task-runner process, which means
  a sidecar. The Set node with `$env.HOSTNAME` does the same job in-process.
- **Nothing may claim an HA property that `make drill` has not measured.** Failover times in the
  docs are real numbers from a real run, not estimates.

## Gotchas learned the hard way

- **n8n has no Redis Sentinel support.** `QUEUE_BULL_REDIS_*` covers host, port, username,
  password, TLS and Cluster — not Sentinel. HA depends entirely on redis-operator repointing the
  `n8n-redis-master` Service, which is why `make drill` tests it rather than assuming it.
- **KEDA's `pollingInterval` and `cooldownPeriod` do nothing when `minReplicaCount > 0`.** It
  warns at apply time. Scale-down behaviour goes in
  `advanced.horizontalPodAutoscalerConfig.behavior`, which the underlying HPA reads.
- **Never set `replicas` on a Deployment KEDA scales.** The two controllers fight, each reverting
  the other every reconcile.
- **The Traefik chart's Service type is `service.spec.type`, not `service.type`,** and
  `ports.web.nodePort` must be an integer (`--set`, not `--set-string`). Getting either wrong
  leaves a LoadBalancer at `<pending>` and `helm --wait` times out on a healthy install.
- **The Gateway listener port is 8000, not 80.** Traefik matches a listener to an entrypoint by
  port number, and its `web` entrypoint is 8000 inside the container.
- `N8N_SECURE_COOKIE=false` is required on plain HTTP. Otherwise the auth cookie carries `Secure`,
  browsers refuse to store it, the editor login fails, and curl's cookie jar will not replay it.
- n8n 2.x refuses `DELETE /rest/workflows/<id>`: "Workflow must be archived before it can be
  deleted". `POST /rest/workflows/<id>/archive` first — it also deactivates, freeing the webhook
  path.
- n8n ignores `"active": true` in an imported workflow. Activation is always a separate
  `POST /rest/workflows/<id>/activate`, and it requires the current `versionId`.
- `QUEUE_HEALTH_CHECK_ACTIVE=true` is required on Workers, or there is no `/healthz`, the probes
  fail, and `make deploy` hangs on a rollout that never completes.
- `N8N_BLOCK_ENV_ACCESS_IN_NODE` defaults to blocking. Without `"false"` the workflow fails with
  `access to env vars denied` and the response is `{"message":"Error in workflow"}`.
- Anchor log greps to `execution <id> (job`. A bare grep for an id like `1` matches half the
  startup log and passes no matter what.
- Wait for the database before Main. n8n runs migrations at startup and crash-loops against one
  that is not accepting connections yet.

## Hooks

`pre-commit install` after cloning — gitleaks, yamllint and shellcheck run on every commit.
