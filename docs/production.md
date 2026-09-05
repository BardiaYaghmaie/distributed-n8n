# Taking this to production

This deployment is deliberately a local one. Nothing below is implemented here; it is what
changes when the platform carries real work for a few hundred users.

Roughly in order of how much they matter.

## 1. TLS, and everything that hangs off it

Plain HTTP is the largest single gap. It is also the one whose fix touches the most files, because
three things have to change together:

1. **cert-manager** issuing a certificate — Let's Encrypt via an HTTP-01 or DNS-01 solver, or your
   internal CA.
2. **A second Gateway listener**, `protocol: HTTPS` on port 443, with `certificateRefs` pointing
   at the resulting Secret, and an HTTPRoute rule redirecting `:80` to it.
3. **`N8N_SECURE_COOKIE` removed** from `n8n-main`, and `N8N_PROTOCOL`/`N8N_WEBHOOK_URL` switched
   to `https`.

Doing only the first two leaves n8n advertising `http://` webhook URLs. Doing only the third
breaks the editor login.

## 2. Backups and disaster recovery

CloudNativePG replication survives losing a node. It does not survive a `DROP TABLE`, a bad
migration, or the cluster being deleted — replicas replicate mistakes faithfully. Backups are a
different problem from availability and need their own answer.

```
RPO   5 minutes    continuous WAL archiving
RTO   1 hour       restore a base backup, replay WAL
```

CNPG has this built in: a `Backup`/`ScheduledBackup` resource writing base backups and a WAL
archive to object storage, and a `Cluster` that can bootstrap by recovering from them.

- **Store backups somewhere the cluster cannot reach with its own credentials** — a different
  account or project, with object versioning and object-lock, so a compromised cluster or a
  mistaken `kubectl delete` cannot reach them.
- **Back up `N8N_ENCRYPTION_KEY` separately.** A database restore without it gives you every
  workflow and not one usable credential. Put it in the secret manager, not next to the dump.
- **Test the restore monthly, automatically.** Restore into a scratch namespace, start n8n
  against it, assert the workflow count and that one known credential decrypts. A backup that has
  never been restored is a hypothesis. Record the real restore time and compare it to the RTO you
  claim.
- **Redis is deliberately not backed up.** It holds in-flight jobs; the durable record is in
  PostgreSQL. After a Redis loss, executions are re-triggered, not recovered.

## 3. More than one Main

One Main is this deployment's remaining single point of failure: a restart rejects webhooks for
roughly twenty seconds, and executions already queued still complete on the Workers.

Two or three Mains need `N8N_MULTI_MAIN_SETUP_ENABLED=true`, which makes them elect a leader
through Redis. The leader owns schedule triggers and webhook registration, so a cron workflow
fires once rather than three times, while all replicas serve UI, API and webhook traffic.

**This is an n8n Enterprise feature.** Without a licence, the honest options are one Main with a
fast readiness probe and a PodDisruptionBudget, accepting the gap — or a licence. There is no
community workaround that is not a bug waiting to happen.

## 4. Connection pooling, at around fifty Workers

PostgreSQL's ceiling for this workload is connections, not queries. Every Worker holds a pool, so
`replicas x pool_size` grows linearly with the autoscaler's ceiling.

CloudNativePG has a `Pooler` resource — PgBouncer in transaction mode, managed by the same
operator — and n8n points at the Pooler's Service instead of `n8n-pg-rw`. Add it before raising
`maxReplicaCount` much past twenty; it is not needed below that.

While you are there: read replicas (`n8n-pg-ro`) for the execution-history queries the UI makes,
which are the heaviest reads, and aggressive pruning. The execution table is what grows without
bound — consider `EXECUTIONS_DATA_SAVE_ON_SUCCESS=none` for high-volume workflows.

## 5. Monitoring

`N8N_METRICS=true` is already set, so both roles expose `/metrics`. Nothing scrapes them here.
With a Prometheus stack, the signals worth alerting on, in order of usefulness:

| Signal | Alert on | Why |
|---|---|---|
| Queue depth | Rising for 10+ minutes | The clearest "arrival rate exceeds completion rate" signal. Alert on the *trend*, not an absolute number — depth spikes are normal |
| Execution failure rate | Above background noise, sustained | Usually one workflow's external dependency, not the platform |
| Ready Workers | Below the ScaledObject's minimum | Workers consume nothing while crash-looping |
| PostgreSQL connections | Above ~80% of `max_connections` | Arrives before any other database limit |
| Redis `used_memory` | Near `maxmemory` | With `noeviction`, hitting it means writes start failing |
| Time from trigger to execution start | p95 rising | What users actually experience as "n8n is slow" |

Two things that must never be logged: workflow payloads (arbitrary customer data, at
`EXECUTIONS_DATA_SAVE_ON_ERROR=all` including whatever the failing node was holding) and anything
from a credential.

## 6. Identity and team isolation

At a few hundred users, hand-managed accounts become an offboarding problem — every account is
one someone has to remember to remove. OIDC moves that to the identity provider, where a disabled
account loses n8n access immediately, and MFA and password policy live in one place.

n8n's own isolation model is **projects**: a workflow and a credential belong to a project, and
users are members with a role. Map IdP groups to projects and a Finance user simply does not see
the DevOps project.

Both SSO and projects are **Enterprise** features. On community edition there is one shared space
where everyone sees everything, which is the strongest practical argument for a licence at that
size. Two limits worth knowing even with one:

- A credential's secret is usable by anyone who can edit a workflow in its project. They cannot
  read it in the UI, but they can build a workflow that uses it. Credential access is "may use
  this integration", not "may see this secret".
- Isolation is project-level, not sandbox-level. A member can write a node that reaches anything
  the Worker's network position allows — which is why Worker egress policy matters, and why
  separate Worker pools per sensitivity tier are worth considering.

## 7. GitOps

Nothing should be deployed by a human running `kubectl`. Put `kubernetes/` behind Argo CD, one
Application per environment, and the cluster converges on what git says: drift is visible and
rollback is `git revert`. For more than one environment, these plain manifests become a Helm chart
or a Kustomize base with overlays.

**Workflows are the harder half.** They are edited in a UI and stored in a database, which is not
something anyone can review. The pattern that works:

1. Developers edit in **staging**.
2. A scheduled job exports workflows through the n8n API and opens a PR with the JSON diff.
3. Review happens on that PR — a real diff of nodes and connections.
4. On merge, CI imports them into **production** through the API.

Credentials are never exported, only workflow structure; each environment holds its own, pointing
at its own systems.

`make verify` is the shape of the post-deploy smoke test: trigger a known webhook, assert the
response, assert a Worker executed it. Run it after every deployment.
