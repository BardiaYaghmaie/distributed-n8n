# Operations

Scaling it, breaking it on purpose, and working out what is wrong when something breaks on its
own.

## Scaling the Workers

KEDA owns the Worker count. It reads the number of jobs waiting in Redis and drives a
HorizontalPodAutoscaler underneath, between 2 and 10 replicas.

```bash
# watch it happen
make fanout N=1500
kubectl --context kind-n8n -n n8n get pods -w
```

Two dials, and they solve different problems:

- **`replicas`** — more pods, more nodes, more CPU, better failure isolation. Raise the
  `maxReplicaCount` in `kubernetes/70-autoscale.yaml` when Workers are CPU-saturated, or when
  losing one node would remove too much capacity.
- **`--concurrency`** — more simultaneous executions inside one pod, set in
  `kubernetes/50-n8n-worker.yaml`. Raise it when Workers sit idle waiting on HTTP calls, which is
  what most real workflows do.

Total capacity is `replicas × concurrency`. Start at concurrency 5–10 and scale replicas. A
workflow that holds a lot of data in memory wants *lower* concurrency and more pods, because one
pod's memory limit is shared by everything running inside it.

To pin a count by hand — for a test, or while debugging — `make scale REPLICAS=5` works, but KEDA
takes it back at the next reconcile. To hold a number, edit `minReplicaCount`.

### Why not a CPU-based HPA

A Worker blocked on a slow external API is nearly idle by CPU while the queue grows behind it. A
CPU HPA would scale *down* at exactly the wrong moment. Queue depth leads the problem; CPU merely
correlates with it, and badly.

### When the queue keeps growing

Depth rising is normal. Depth rising *monotonically* means arrival rate exceeds completion rate.
In rough order of likelihood:

1. **Not enough Workers.** Check whether KEDA has hit `maxReplicaCount`, and whether the new pods
   are actually `Running` rather than `Pending` for want of a node.
2. **Executions got slower**, usually a slow external API. Look at duration percentiles per
   workflow and add timeouts to the offending node.
3. **Workers are crash-looping or OOM-killed.** They consume nothing while restarting.
   `kubectl -n n8n get pods` and look at the restart count.
4. **PostgreSQL is the bottleneck.** Workers are blocked writing results rather than executing.
   Check connection count against `max_connections`.

Alert on the *derivative* — depth rising for ten minutes — not on an absolute number.

---

## The failure drills

```bash
make drill
```

Three tests. Each recovery is timed by **when the webhook answers again** — three times in a row,
because the first call after a failover can succeed on a connection that has not noticed anything
yet. Not "when the pod goes Ready", which is always a flattering number and never the one a user
experiences.

Measured on a 4-node kind cluster on a laptop:

| Drill | Recovery | What moved |
|---|---|---|
| PostgreSQL primary killed | **26–28 s** | `n8n-pg-1` → `n8n-pg-2`, `n8n-pg-rw` repointed |
| Redis master killed | **37–62 s** | `n8n-redis-0` → `n8n-redis-2`, `n8n-redis-master` repointed |
| NetworkPolicy | n/a | connection refused, as required |

The Redis range is wide because two independent things have to happen: the Sentinels must agree
the master is gone (`downAfterMilliseconds: 5000` plus election), and *then* the operator has to
notice the new role and update the Service. Watching it directly, the Service endpoint is empty
for about 16 s, repoints at ~21 s, and n8n's pool is reliably reconnected by ~37 s.

### 1. The PostgreSQL primary is killed

`kubectl delete pod --force --grace-period=0` on whichever pod carries
`cnpg.io/instanceRole=primary`. Force, because a graceful delete lets CloudNativePG do a
controlled switchover, which is the easy case; this simulates the node going away.

What should happen: CNPG notices the primary is unreachable, picks the replica with the most
received WAL, promotes it, and updates the `n8n-pg-rw` Service to point at it. n8n's connection
pool sees its connections drop, reconnects to the same hostname, and finds the new primary.

### 2. The Redis master is killed

Same treatment for the pod labelled `redis-role=master`.

What should happen: the Sentinels stop hearing from the master, agree it is down (quorum 2 of 3),
elect a replica, and reconfigure the others to replicate from it. redis-operator sees the new
role and repoints the `n8n-redis-master` Service.

**This is the step most worth running yourself.** n8n has no Sentinel-aware client, so everything
depends on that Service being repointed — and the operator has open bugs about it going stale
after a failover ([#1711](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1711),
[#1779](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1779)). It repointed correctly
on every run here, but that is one cluster and one version. The drill checks it on yours rather
than asking you to trust it.

Note what is *not* claimed: jobs already popped by a Worker that also died are not recovered by
this. Redis persistence is `appendfsync everysec`, so up to a second of accepted jobs can be lost
in a hard failure. Executions already recorded in PostgreSQL survive but are not resumed.

### 3. The NetworkPolicies are enforced

A throwaway pod in the `default` namespace tries to open `n8n-pg-rw:5432`. Nothing in
`kubernetes/80-networkpolicy.yaml` allows that, so it must fail.

This test exists because NetworkPolicy failure is silent: a CNI without support accepts the
objects and ignores them, and everything looks configured. kind's default CNI has enforced them
since v0.24. On another cluster, run this before relying on the policies.

---

## Failure scenarios

### Redis is unavailable

**Symptom.** Webhooks return 500. The editor loads but executions do not start. Main's log shows
connection errors to `n8n-redis-master`.

**Why it is total.** Main cannot enqueue and Workers have nothing to pop. Redis is not a cache
here; it is the hand-off.

**Check.** `kubectl -n n8n get pods -l app=n8n-redis` and
`kubectl -n n8n get endpointslice -l kubernetes.io/service-name=n8n-redis-master`. An empty
endpoint list means the operator has not decided which pod is master — that is the failure, not
the pods.

**Recovery.** Once a master exists again, Main and Workers reconnect on their own. Executions
already written to PostgreSQL are not resumed; re-trigger them.

### PostgreSQL is unavailable

**Symptom.** Main crash-loops at startup with `There was an error initializing DB`. Running
Workers fail executions when they try to write results.

**Check.** `kubectl -n n8n get cluster n8n-pg` — the `STATUS` column is CNPG's own summary.
`kubectl cnpg status n8n-pg` (the CNPG kubectl plugin) gives much more.

**Note.** Main's liveness probe deliberately does not check the database, so it will not restart
in a loop *because* PostgreSQL is down. It crash-loops only if it cannot complete startup
migrations, which is a different and more visible thing.

### A Worker crashes

**Symptom.** Usually none, which is the point. An execution in flight on that Worker is retried by
another one.

**Check.** Restart count on `kubectl -n n8n get pods -l component=worker`. Repeated restarts with
`OOMKilled` mean the memory limit is too low for the concurrency setting — lower `--concurrency`
or raise the limit; they trade against each other.

### HTTP 502 but the pods look healthy

Work outward from the app:

```bash
# does Main answer inside the cluster?
kubectl -n n8n port-forward deploy/n8n-main 5678:5678
curl -s localhost:5678/healthz

# does the Service have endpoints?
kubectl -n n8n get endpointslice -l kubernetes.io/service-name=n8n-main

# has the route attached to the Gateway?
kubectl -n n8n describe httproute n8n
```

The third is the one that catches people. An `HTTPRoute` whose `parentRefs` do not match — wrong
namespace, wrong `sectionName`, or a namespace missing the `gateway-access: n8n` label the Gateway
selects on — is accepted by the API and simply never attaches. `describe` shows the rejection in
its status conditions.

### An external API a workflow calls is failing

Not a platform problem, but it looks like one: executions fail, the queue grows, and Workers seem
slow. Distinguishing it is quick — the failures are concentrated in one workflow, and Worker CPU
is low while duration is high. Add a timeout to the node; without one, a hanging call occupies a
concurrency slot indefinitely.

---

## Quick reference

```bash
# overall state
kubectl --context kind-n8n -n n8n get pods,cluster,redisreplication,scaledobject

# logs
make logs                                                    # every Worker
kubectl --context kind-n8n -n n8n logs -l component=main -f   # Main

# queue depth right now
kubectl --context kind-n8n -n n8n exec -it n8n-redis-0 -- \
  sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning llen bull:jobs:wait'

# which pod is the database primary / the Redis master
kubectl --context kind-n8n -n n8n get pods -l cnpg.io/instanceRole=primary
kubectl --context kind-n8n -n n8n get pods -l redis-role=master

# is the platform actually working?
make verify
```
