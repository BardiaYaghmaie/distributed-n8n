# Architecture

What runs, and why it is split this way.

## The deployed system

```
                        http://n8n.localtest.me
                                  |
                     host :80 -> kind -> NodePort 30080
                                  |
                        +---------------------+
      namespace infra   |  Traefik / Gateway  |   Gateway API, listener :8000
                        +----------+----------+
                                   |  HTTPRoute (owned by the n8n namespace)
      - - - - - - - - - - - - - - -|- - - - - - - - - - - - - - - - - - - - -
                                   v
                        +---------------------+
      namespace n8n     |      n8n Main       |   Deployment, 1 replica
                        |  editor + API + hooks|  creates the execution, does NOT run it
                        +----------+----------+
                                   |
                                   |  BullMQ push
                                   v
                        +---------------------+
                        |   Redis  master     |   RedisReplication x3 + Sentinel x3
                        +----------+----------+   n8n connects to n8n-redis-master
                                   |
                                   |  blocking pop
                +------------------+------------------+
                v                  v                  v
          +-----------+      +-----------+      +-----------+
          | n8n Worker|      | n8n Worker|      |    ...    |   2-10 replicas, KEDA
          +-----+-----+      +-----+-----+      +-----+-----+   scaled on queue depth
                |                  |                  |
                +------------------+------------------+
                                   |  read workflows and credentials, write results
                                   v
                        +---------------------+
                        | PostgreSQL primary  |   CNPG Cluster, 1 primary + 2 replicas
                        |  + 2 replicas       |   n8n connects to n8n-pg-rw
                        +---------------------+
```

Two namespaces. `infra` holds the four operators and Traefik; `n8n` holds the application, its
database and its queue. Deleting the `n8n` namespace uninstalls the workload and leaves the
platform intact.

| Component | Kind | Count | Manifest |
|---|---|---|---|
| PostgreSQL | CNPG `Cluster` | 3 | [`10-postgres.yaml`](../kubernetes/10-postgres.yaml) |
| Redis | `RedisReplication` + `RedisSentinel` | 3 + 3 | [`20-redis.yaml`](../kubernetes/20-redis.yaml) |
| Config | 3 ConfigMaps | – | [`30-config.yaml`](../kubernetes/30-config.yaml) |
| n8n Main | Deployment + Service | 1 | [`40-n8n-main.yaml`](../kubernetes/40-n8n-main.yaml) |
| n8n Worker | Deployment + PDB | 2–10 | [`50-n8n-worker.yaml`](../kubernetes/50-n8n-worker.yaml) |
| Routing | `Gateway` + `HTTPRoute` | – | [`60-gateway.yaml`](../kubernetes/60-gateway.yaml) |
| Autoscaling | KEDA `ScaledObject` | – | [`70-autoscale.yaml`](../kubernetes/70-autoscale.yaml) |
| Isolation | 7 NetworkPolicies | – | [`80-networkpolicy.yaml`](../kubernetes/80-networkpolicy.yaml) |

## Why Main and Worker are separate

They have opposite resource profiles and opposite failure consequences.

**Main** is latency-bound and does a small, fixed amount of work per request: authenticate, insert
a row, push to Redis, hold the connection. It is on the user-visible path — if Main is slow, the
editor is slow and webhooks time out.

**Worker** is throughput-bound and does an unbounded amount of work per job: whatever the workflow
says, which might be a 200 ms HTTP call or a ten-minute batch. It is on nobody's path — if a Worker
is slow, the queue gets deeper, which is a number you can watch and act on.

Running both in one process couples them in the worst way: a heavy execution starves the event
loop serving the editor, and you cannot add capacity for one without adding it for the other.
Splitting them turns "the platform is slow" into two separate, separately fixable questions.

## Why queue mode is the whole design

By default n8n runs in `regular` mode: one process receives the request and executes the workflow
itself. A second replica in that mode gives you two independent n8n instances, not a distributed
platform — a webhook lands on whichever one the load balancer picked, and that one does all the
work.

`EXECUTIONS_MODE=queue` splits the responsibilities:

- **Main is a producer.** It writes the execution row and pushes a job. Its cost per execution is
  an insert and a push, so one replica absorbs far more traffic than one executing instance.
- **Redis is the hand-off.** n8n uses BullMQ, a job queue built on Redis lists. Main pushes;
  Workers issue a *blocking* pop, so an idle Worker costs nothing and a job is claimed the moment
  one is free. Redis guarantees exactly one Worker gets each job — no leader, no coordinator, no
  registration step.
- **Workers are consumers.** They pull work; nothing routes to them. That is what makes them
  horizontally scalable and what lets KEDA add and remove them without telling anything else.
- **PostgreSQL is the shared state.** All of them read and write the same database, which is how a
  Worker executes a workflow that Main created.

Redis is not a cache here and not an optional accelerator. If it is unavailable, Main cannot
enqueue and Workers have nothing to pop — the platform stops accepting work. That is why it runs
with replication and Sentinel rather than as a single pod.

## Why an operator for each of PostgreSQL and Redis

A StatefulSet restarts a dead pod. That is all it does, and for a stateless service it is enough.

For a replicated database it is not, because the thing that has to happen after a failure is not
"start a pod" but "decide which surviving replica is now the primary, promote it, repoint everyone
at it, and rejoin the old primary as a replica when it comes back". None of that is expressible in
a StatefulSet. It is a controller's job, and both operators here exist to do exactly it:

- **CloudNativePG** watches the primary, promotes a replica on loss, and moves the `n8n-pg-rw`
  Service to the new primary. n8n keeps its `DB_POSTGRESDB_HOST` pointed at that Service and
  reconnects without knowing anything happened.
- **redis-operator** runs three Redis nodes with Sentinel watching them, and moves the
  `n8n-redis-master` Service to whichever node Sentinel elected. This indirection is not optional:
  n8n has no Sentinel-aware Redis client — `QUEUE_BULL_REDIS_HOST` takes one hostname — so
  failover has to be invisible from n8n's side, resolved by DNS.

Measured recovery times for both are in [operations.md](operations.md).
