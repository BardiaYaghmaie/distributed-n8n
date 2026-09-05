# Distributed n8n on Kubernetes

Run one command. When it finishes you have n8n taking webhooks across a fleet of workers, on top
of a PostgreSQL cluster that survives losing its primary and a Redis that survives losing its
master.

```bash
make all
```

That is the useful half. The other half is that this repository is meant to be read. Every
non-obvious line carries a comment explaining why it exists, and the rest of this page walks
through what each piece does and how they fit together, because a pile of working YAML teaches
nobody anything.

If you want n8n running and nothing else, skip to [Running it](#running-it). Otherwise, start
here.

---

## Start with one n8n

n8n is a workflow automation tool. You draw a flow (a webhook arrives, call an API, reshape the
result, write it somewhere) and n8n runs it.

The default deployment is a single process doing all of that at once: serving the editor,
receiving the webhook, executing the workflow. For one person automating their own things this is
exactly right and you should stop reading.

It breaks in a specific way. Not "under load" in the abstract, but like this. Someone builds a
workflow that chews through a 50 MB CSV. While it runs, the editor goes unresponsive. Webhooks
start timing out. A scheduled workflow fires late. Those symptoms look unrelated and have one
cause: it is all the same Node.js event loop, and the loop is busy.

So you run a second copy. This does not help, and understanding why is the whole point of what
follows. A webhook lands on whichever copy the load balancer picked, and that copy does all the
work. You have not spread the load, you have made two independent bottlenecks. Worse, if both
copies share a database, both of them now believe they own the scheduled triggers, and your
nightly job runs twice.

Adding replicas fails because it copies the *whole* process, including the part that should not be
duplicated. What you actually want is to split it: one thing that accepts work, another thing that
does work, and a queue between them so the second thing can be multiplied freely.

That pattern is not an n8n idea. Rails apps do it with Sidekiq, CI systems do it with runners,
video sites do it with encoding farms. Learn it here and you will keep seeing it.

n8n calls it queue mode, and turning it on is one line:

```yaml
EXECUTIONS_MODE: queue
```

Everything else in this repository exists to make that line safe to depend on.

---

## The cast

```
                        http://n8n.localtest.me
                                  |
                     host :80 -> kind -> NodePort 30080
                                  |
                        +---------------------+
      namespace infra   |  Traefik / Gateway  |   the front door
                        +----------+----------+
                                   |  HTTPRoute
      - - - - - - - - - - - - - - -|- - - - - - - - - - - - - - - - - - - - -
                                   v
                        +---------------------+
      namespace n8n     |      n8n Main       |   accepts work
                        |  editor + API + hooks|
                        +----------+----------+
                                   |  push a job
                                   v
                        +---------------------+
                        |    Redis  master    |   hands work over
                        +----------+----------+   3 replicas + 3 Sentinels
                                   |  blocking pop
                +------------------+------------------+
                v                  v                  v
          +-----------+      +-----------+      +-----------+
          | n8n Worker|      | n8n Worker|      |    ...    |   does the work
          +-----+-----+      +-----+-----+      +-----+-----+   2-10, autoscaled
                |                  |                  |
                +------------------+------------------+
                                   v
                        +---------------------+
                        |     PostgreSQL      |   remembers everything
                        | primary + 2 replicas|
                        +---------------------+
```

**n8n Main** is the part you log into. Editor, REST API, webhook endpoint. In queue mode it stops
executing anything: a request arrives, it writes a row to PostgreSQL, pushes a job to Redis, and
holds the HTTP connection open waiting for someone else to finish. One insert and one push per
request, which is why a single replica keeps up with far more traffic than an executing instance
ever could.

**n8n Workers** are the same container image with a different command, `n8n worker`. No editor, no
API, nothing listening for traffic. A Worker connects to Redis, blocks until a job appears, runs
the workflow, writes the result, and blocks again. Nothing routes to a Worker; it goes and gets
its own work. That one property is what makes them multiply cleanly, because starting a new one
requires informing precisely nobody.

**Redis** is the hand-off, and it is load-bearing. Not a cache, not a speedup you could remove on a
bad day. If Redis is gone, Main has nowhere to put jobs and Workers have nothing to take, and the
platform stops accepting work entirely. That is why it runs replicated here instead of as the
single pod most tutorials give you.

**PostgreSQL** is the shared memory: workflow definitions, encrypted credentials, execution
history. Main and every Worker read and write the same database, and that is the trick that makes
the hand-off cheap. Main never ships a workflow to a Worker. It ships an id, and the Worker looks
the rest up.

**Traefik**, behind a Gateway API `Gateway`, is the front door. **KEDA** watches the depth of the
Redis queue and decides how many Workers there should be.

The two namespaces are deliberate. `infra` holds the operators and the proxy, the things a cluster
admin installs once. `n8n` holds the application and its data. You can delete the whole `n8n`
namespace and the platform underneath it is untouched.

---

## Watch one request go through

Structure is easy to draw and hard to learn from. This is the part that makes it click.

```bash
curl -X POST http://n8n.localtest.me/webhook/test \
  -H "Content-Type: application/json" \
  -d '{"message": "hello", "request_id": "12345"}'
```

**It starts with a lie about DNS.** `n8n.localtest.me` is a real public domain that resolves to
`127.0.0.1` for everybody on earth. No `/etc/hosts` edit, no dnsmasq. The request goes to your own
machine's port 80.

**Then two hops into the cluster.** kind runs Kubernetes nodes as Docker containers, and
`kind/cluster.yaml` maps host port 80 to port 30080 on the control-plane container. Traefik's
Service claims `NodePort 30080`, a port opened on every node that forwards to the pod. Both hops
are four lines of config you can go and read.

**Traefik looks for a route.** It finds the `HTTPRoute` in `kubernetes/60-gateway.yaml`, which says
that the hostname `n8n.localtest.me` belongs to the Service `n8n-main` on port 5678.

**The Service picks a pod.** `n8n-main` is a ClusterIP Service selecting on the labels `app=n8n`
and `component=main`. That second label is doing real work: Workers also run an HTTP server, but
only for health checks, and a webhook must never land on one. The selector makes that structurally
impossible rather than merely unlikely.

**Main takes the job and puts it down.** It matches `/webhook/test` to the active workflow, writes
an execution row to PostgreSQL through the `n8n-pg-rw` Service, and pushes a job onto a Redis list
through `n8n-redis-master`. Then it waits, holding your connection open.

**A Worker wakes up.** Every Worker is already blocked on that list. Redis hands the job to exactly
one of them. That Worker fetches the workflow from PostgreSQL (remember, Main only sent an id),
runs the two nodes, writes the result back.

**The answer comes home.** The Worker publishes its result, Main is still holding your connection,
and it replies. From the outside this looked like one ordinary HTTP request that happened to take
40 ms.

Now the thing worth noticing: **at no point did Main and the Worker know about each other.** No
service discovery, no registration, no leader election, no heartbeats. They share a Redis list and
a database, and that is the entire coordination protocol. It is why you can kill a Worker
mid-flight, start five more, or move them to another machine, and nothing needs to be told.

---

## The two-node workflow, and why its answer is proof

[`n8n/workflow.json`](n8n/workflow.json) is a Webhook node feeding a Set node. It does nothing
useful on purpose.

```json
{
  "message": "hello",
  "request_id": "12345",
  "processed": true,
  "executed_by": "n8n-worker-5756d8bf46-vg8rd",
  "execution_id": "1"
}
```

The first three fields are an echo. The last two are evidence. `executed_by` is `$env.HOSTNAME`
read from inside whichever process ran the workflow, which under Kubernetes is the pod name.
`execution_id` is the row id in PostgreSQL, so you can go and find the same execution in that
pod's logs.

The webhook uses `responseMode: lastNode`, so n8n holds the connection until the workflow finishes
and returns the last node's output. Since a Worker is what finishes it, getting a response *at
all* already proves the enqueue, dequeue and execute round trip worked.

`make verify` refuses to take the pod name at face value, and checks three separate things:

1. the response says what the workflow should say;
2. that pod name genuinely carries `component=worker`, asked of the Kubernetes API rather than
   pattern-matched on the string;
3. that Worker's own log contains this execution id.

Two and three are independent for a reason. A workflow could in principle report a hostname that
is not its own. A log is the process's own account of itself. Together there is no room left for
Main to have quietly run it.

One small design note. The pod name comes from a Set node reading `$env.HOSTNAME`, not a Code node
calling `os.hostname()`. n8n 2.x runs Code nodes in a separate task-runner process, so a Code node
would mean a sidecar container in every Worker pod, infrastructure existing purely to serve a
demo. The Set node gets the same answer in-process.

---

## Redis, up close

n8n uses [BullMQ](https://docs.bullmq.io), which is a job queue built on ordinary Redis lists.
Almost everything about its behaviour follows from thinking of it as *a list that two programs
agree about*.

Main pushes a job onto `bull:jobs:wait`. One list operation. Workers call a blocking pop and then
just wait. This is the elegant bit: an idle Worker costs Redis nothing at all, no polling and no
timers, and a job gets claimed the instant a Worker is free. And because Redis is single-threaded,
"exactly one Worker gets this job" is not a distributed consensus problem. It is a side effect of
operations happening one at a time.

Two settings in `kubernetes/20-redis.yaml` are worth understanding, because both are about
choosing to fail loudly.

`maxmemory-policy noeviction`. Redis under memory pressure will, by default, start evicting keys.
For a cache that is correct behaviour. For a queue it means jobs that were accepted and then
silently never ran, which is about the worst failure a system can have, because nothing anywhere
reports an error. Setting `noeviction` makes Redis refuse new writes instead. Something breaks
visibly, which is what you want.

`appendonly yes`. A restart comes back with the queue it had rather than an empty one. This is not
strong durability; with `appendfsync everysec` you can still lose a second of accepted jobs. But
losing a second is a different category of problem from losing everything.

And now the limitation you should know about, because it shapes the whole Redis design here:
**n8n cannot talk to Redis Sentinel.** `QUEUE_BULL_REDIS_HOST` takes one hostname and that is all
it takes. So the three-node Redis does not work by n8n being clever. It works because
redis-operator moves the `n8n-redis-master` Service to whichever pod Sentinel elected, and n8n
reconnects to the same name having noticed nothing. Failover is resolved by DNS, behind n8n's
back. Whether that actually happens is exactly what `make drill` goes and checks.

---

## Why PostgreSQL gets an operator

Most tutorials give you a StatefulSet with one replica. Understanding why that is not enough is
more useful than the fix.

A StatefulSet gives you stable pod names, stable storage, and it restarts a pod that dies. For a
stateless service that is the entire job. For a replicated database it is not, because the thing
that needs to happen after a failure is not "start a pod". It is:

> work out which surviving replica has the most data, promote it to primary, point every client at
> it, and when the old primary comes back, rejoin it as a replica.

None of that can be expressed in a StatefulSet. It needs a program that watches the cluster and
acts on it, and a program like that is what an operator is.

[CloudNativePG](https://cloudnative-pg.io) is that program here. You declare an intention:

```yaml
kind: Cluster
spec:
  instances: 3
```

and it creates the pods, sets up replication, generates the database password into a Secret,
watches the primary's health, promotes a replica when the primary goes, and maintains three
Services:

| Service | Always points at |
|---|---|
| `n8n-pg-rw` | the current primary |
| `n8n-pg-ro` | the replicas, for read-only queries |
| `n8n-pg-r` | any instance |

n8n's `DB_POSTGRESDB_HOST` is `n8n-pg-rw`. After a failover the operator repoints that Service and
n8n reconnects, none the wiser. It is the same trick as Redis: **a stable name whose meaning
moves.**

That idea, declare what you want and let a controller drag reality toward it, is Kubernetes
itself in one sentence. Operators just extend it to things Kubernetes has never heard of, like
what a "primary" is.

---

## Who owns the front door

Routing here uses Gateway API rather than an `Ingress`, and the reason is about ownership more
than features.

An `Ingress` mashes two unrelated decisions into one object living in the application's namespace:
which ports the cluster's proxy exposes, which is a platform decision, and which hostname maps to
which Service, which is an application decision. Because they are the same object, "is this team
allowed to publish on this hostname" is not a question the cluster can answer.

Gateway API pulls them apart:

```
Gateway     (namespace infra)     the platform team's object
              which ports are open, which controller serves them,
              and which namespaces may attach routes

HTTPRoute   (namespace n8n)       the application team's object
              which hostname, which Service, which timeouts
```

The `Gateway` in `kubernetes/60-gateway.yaml` accepts routes only from namespaces labelled
`gateway-access: n8n`, and `kubernetes/00-namespace.yaml` is where that permission is written
down. An application team can publish a route. It cannot grant itself the right to publish one.
Try it from an unlabelled namespace and the route is rejected with
`Accepted: False, reason: NotAllowedByListeners`.

Two things that will bite you if you copy this:

The listener port is **8000**, not 80. Traefik matches a Gateway listener to one of its
entrypoints by port number, and its `web` entrypoint listens on 8000 inside the container. The
port humans connect to is a completely separate concern (NodePort 30080, forwarded from host 80).

Timeouts are API fields (`timeouts.request`), not controller-specific annotations. That
portability is the other thing Gateway API buys you.

There is also a reason not to reach for ingress-nginx, which most guides still recommend: it was
**retired in March 2026**. No more releases, no fixes for anything found after that date, and the
successor project was abandoned.

---

## Growing

```bash
make fanout N=1500
kubectl --context kind-n8n -n n8n get pods -w
```

Measured on a laptop: the queue peaks around 620 waiting jobs, KEDA takes the Workers from **2 to
6** in about ten seconds, and holds them for the five-minute scale-down window before letting them
go. Run `make fanout N=600` while it is still wide and the work spreads evenly, 96 to 104
executions per Worker across all six.

Use a big number, and here is the honest reason why. `N=200` scales nothing. The sample workflow
is one Set node, so two Workers at concurrency 5 clear 200 jobs in about three seconds, faster
than the autoscaler's metric window even notices. Autoscaling reacts to a queue that *stays* deep,
not to a spike that has already drained. Real workflows, which sit around waiting on real APIs,
build a queue much more easily than this toy does.

There are two dials and they fix different problems. **Replicas** (KEDA, 2 to 10) is what you
raise when Workers are CPU-bound, or when losing one node would cost you too much capacity.
**`--concurrency`** in `kubernetes/50-n8n-worker.yaml` is what you raise when Workers are sitting
idle waiting on I/O, which is most real work. Capacity is the product of the two. A workflow that
holds a lot of data in memory wants *lower* concurrency and more pods, because everything running
inside one pod shares its memory limit.

The interesting decision is what to scale *on*. A CPU-based HorizontalPodAutoscaler is the obvious
choice and it is wrong here. A Worker with ten HTTP calls in flight is completely occupied and
almost idle by CPU, so a CPU autoscaler would scale **down** exactly when the queue is growing.
Queue depth is the signal that actually means "work is arriving faster than it leaves".

```yaml
triggers:
  - type: redis
    metadata:
      listName: "bull:jobs:wait"
      listLength: "20"        # ~20 waiting jobs per Worker
```

The general lesson, which outlives n8n: **autoscale on the signal that leads the problem, not the
one that correlates with it.** For a queue that is depth. For a web tier it is usually latency or
in-flight requests. It is almost never CPU.

One Kubernetes detail that catches people out: `kubernetes/50-n8n-worker.yaml` has no `replicas`
field at all. KEDA owns that number. Set it in both places and two controllers spend the rest of
the day overwriting each other, which is a genuinely miserable thing to debug.

---

## Breaking it on purpose

```bash
make drill
```

It kills the PostgreSQL primary, kills the Redis master, and tries a connection the network
policies are supposed to refuse. Recovery is timed by when the webhook answers again, three times
in a row, because the first call after a failover can succeed on a connection that has not yet
noticed anything. "Time until the pod is Ready" is a much prettier number and a much less honest
one.

| Lose | What happens | Measured |
|---|---|---|
| A Worker | Its in-flight executions are retried elsewhere | nothing visible |
| The PostgreSQL primary | CNPG promotes a replica, repoints `n8n-pg-rw` | **26–28 s** |
| The Redis master | Sentinel elects, the operator repoints `n8n-redis-master` | **37–62 s** |
| A whole node | All of the above at once, which is what three nodes are for | — |
| n8n Main | Webhooks refused for ~20 s. Queued executions still finish | — |

Those are real numbers from a four-node kind cluster on a laptop, not estimates.

That last row is the honest remaining single point of failure. Two Mains would need
`N8N_MULTI_MAIN_SETUP_ENABLED` so they elect a leader for schedule triggers, otherwise every cron
workflow fires twice, and that flag is an n8n **Enterprise** feature.

The Redis drill is the one most worth running yourself. Everything about that failover rests on
the operator repointing a Service, and the operator has open bugs about exactly that going stale
([#1711](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1711),
[#1779](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1779)). It behaved correctly on
every run here. That is one cluster and one version, which is why the drill exists instead of a
sentence asking you to trust it.

---

## Things worth stealing

Patterns here that are good practice generally, not just for n8n.

**Health checks that mean something.** In [`40-n8n-main.yaml`](kubernetes/40-n8n-main.yaml) both
probes hit `/healthz`, which answers as soon as the HTTP server is listening, and deliberately do
not check the database. If PostgreSQL is unreachable, restarting Main does not fix it, and a
liveness probe that fails on it turns one outage into a restart loop on top of an outage.

**Config split by who reads it.** [`30-config.yaml`](kubernetes/30-config.yaml) is three
ConfigMaps rather than one. `n8n-common` is what Main and Workers must agree on, `n8n-main` is
web-server settings, `n8n-worker` is queue-consumer settings. One big ConfigMap makes every
variable look like it applies to everything, so nobody reading it can tell whether
`N8N_SECURE_COOKIE` affects the Workers. The safety that actually mattered is unchanged, because
everything that must match still lives in one object both of them reference.

**Secrets generated by whoever owns them.** The database password is generated by CloudNativePG,
not by a script, because the thing that owns the database should own its credential.
[`30-secrets.sh`](scripts/30-secrets.sh) is idempotent and never rotates: a new
`N8N_ENCRYPTION_KEY` makes every credential already in the database permanently undecryptable.

**Spread across failure domains, with the right strictness.**
[`50-n8n-worker.yaml`](kubernetes/50-n8n-worker.yaml) uses `topologySpreadConstraints` with
`whenUnsatisfiable: ScheduleAnyway`, a preference that stops blocking once there are more Workers
than nodes. `10-postgres.yaml` uses `enablePodAntiAffinity`, which is stricter, because three
database instances on one machine defeats the entire purpose of three.

**A PodDisruptionBudget, and knowing what it isn't.** `minAvailable: 1` means a node drain cannot
leave the queue with nobody consuming it. It constrains voluntary disruption only. It will not
save you from a machine catching fire.

**A grace period that outlasts the work.** `terminationGracePeriodSeconds: 40`, longer than the 30
seconds n8n spends draining executions on SIGTERM. Shorter and Kubernetes SIGKILLs a Worker
mid-execution. Match the grace period to what the process actually does when asked to stop.

**Default-deny networking.** [`80-networkpolicy.yaml`](kubernetes/80-networkpolicy.yaml) denies
everything, then allows the six flows that exist. Only Workers get internet egress, because
workflows call external APIs and Main has no business doing so; a Main that can reach the internet
is mostly useful to an attacker. And the egress rule excludes RFC 1918 space, because
`0.0.0.0/0` on its own would also hand a Worker every pod in the cluster.

These are enforced here, not decorative. kind's default CNI has supported NetworkPolicy since
v0.24, and `make drill` proves it with a connection that has to fail. Worth checking on any
cluster: a CNI without support accepts the objects and ignores them, with no error anywhere.

**Never trusting the ambient context.** [`scripts/common.sh`](scripts/common.sh) wraps `kubectl`
and `helm` as shell functions pinned to `--context kind-n8n`. `kubectl config use-context` is not
good enough, because it sets global state that anything on the machine can change between two
commands. These scripts install operators and delete pods. That does not belong in whatever
cluster you happen to have selected.

---

## Running it

**You need** `docker` 24+, `kind` 0.30+, `kubectl` 1.29+, `helm` 3.14+, and `curl`, `python3`,
`openssl`. Host port 80 has to be free. The cluster settles at about **3.5 GB** of RAM; give it 6
for headroom, or see [running smaller](#running-smaller).

`make all` runs six steps, each of which also runs on its own:

| | | |
|---|---|---|
| 1 | `make cluster` | kind cluster, 1 control-plane and 3 workers |
| 2 | `make operators` | Gateway API + Traefik, CloudNativePG, redis-operator, KEDA, into `infra` |
| 3 | `make secrets` | Generate the Redis password, encryption key and editor login |
| 4 | `make deploy` | Apply `kubernetes/` and wait for everything |
| 5 | `make seed` | Create the owner account, import and activate the workflow |
| 6 | `make verify` | Call the webhook and prove a Worker ran it |

Nearly all of the wall-clock time is pulling about 2 GB of images, so how long it takes is mostly
a question of your connection. Everything comes from the projects' own registries and Helm repos
at pinned versions. No mirrors, no preloading, no digest overrides, which is what lets
`kubernetes/` apply unchanged to a real cluster.

Then:

```bash
make credentials       # the generated editor login for http://n8n.localtest.me
make fanout N=1500     # a burst deep enough for KEDA to react to
make drill             # kill the primary, kill the Redis master, time the recovery
make logs              # follow every Worker at once
make scale REPLICAS=5  # override KEDA by hand
make down              # delete the cluster
```

### Running smaller

To trade the failover away for a smaller footprint and keep everything else:

- `kubernetes/10-postgres.yaml` → `instances: 1`
- `kubernetes/20-redis.yaml` → `clusterSize: 1` on both resources
- `kind/cluster.yaml` → one worker node

### Layout

```
Makefile                one target per step
kind/cluster.yaml       1 control-plane + 3 workers, host port 80
kubernetes/             the deployment, as plain commented manifests
  00-namespace   10-postgres   20-redis      30-config
  40-n8n-main    50-n8n-worker 60-gateway    70-autoscale   80-networkpolicy
scripts/                one script per Makefile target
  common.sh  10-cluster  20-operators  30-secrets  40-deploy
  50-seed    60-verify   70-fanout     80-drill    teardown
n8n/workflow.json       Webhook -> Set. The only workflow
docs/
  architecture.md       what runs, and why it is split this way
  decisions.md          the choices that could have gone the other way
  operations.md         scaling, failover drills, failure scenarios
  security.md           what is protected, and what is not
  production.md         what changes when this carries real work
```

---

## What is deliberately missing

Being specific about the gaps is more useful than pretending there are none. Each of these has an
answer in [docs/production.md](docs/production.md).

**TLS.** Plain HTTP, editor login included. This is also why `N8N_SECURE_COOKIE=false` is set, and
that flag is correct *only* because there is no TLS. Adding certificates means removing it in the
same change.

**Backups.** Replication survives a lost node. It does not survive a dropped table, because
replicas replicate mistakes with total fidelity. Availability and backups are different problems.

**A second Main.** Multi-main is an n8n Enterprise feature, so this deployment has one, and a
restart refuses webhooks for about twenty seconds.

**SSO and projects.** One shared owner account. Also Enterprise features.

**A monitoring stack.** `/metrics` is exposed on both roles and nothing scrapes it. Point an
existing Prometheus at it and you get data without touching these manifests.

**GitOps.** Deployed from a laptop rather than reconciled from git.

---

## Licence

MIT for the manifests, scripts and docs here. n8n itself is fair-code under the Sustainable Use
License, which is not the same as open source. See [LICENSE](LICENSE).
