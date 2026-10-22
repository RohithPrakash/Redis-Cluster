<!-- SPDX-License-Identifier: Apache-2.0 -->

# Redis Cluster Helm Chart

A production-ready Helm chart for deploying an **n-node Redis Cluster** on Kubernetes. The chart defaults to **6 nodes** (3 masters + 3 replicas) and uses a **StatefulSet** with stable network identities and persistent storage.

---

## Prerequisites

- Kubernetes 1.25+
- Helm 3.10+
- A container image with `redis-server` and `redis-cli` (see the [`dockerfile`](../../dockerfile) in this repo, which pins Redis **7.2.16**; see [Redis version notes](#redis-version-notes))

---

## Quick Start

### 1. Build / load the image (local kind cluster)

```bash
docker build -t redis-cluster:7.2.16 -f dockerfile .
kind load docker-image redis-cluster:7.2.16
```

### 2. Install the chart

```bash
helm install redis-cluster helm/redis-cluster/

# If the Kubernetes cluster has a single node

helm install redis-cluster helm/redis-cluster/ --set-json affinity='{}'
```

### 3. Verify the cluster

```bash
kubectl get pods -l app.kubernetes.io/name=redis-cluster
kubectl exec -it redis-cluster-0 -- redis-cli cluster info
kubectl exec -it redis-cluster-0 -- redis-cli cluster nodes
```

### 4. Run helm tests

```bash
helm test redis-cluster
```

The test pod uses its own labels (`app.kubernetes.io/name: redis-cluster-test`), so it is not part of the Service or PDB and the Redis anti-affinity does not keep it off nodes that run Redis.

---

## Uninstall

```bash
helm uninstall redis-cluster
kubectl delete pvc -l app.kubernetes.io/name=redis-cluster
```

> **Note:** PVCs are **not** deleted automatically by Helm to prevent accidental data loss.

---

## Architecture Overview

### StatefulSet

The chart deploys Redis as a **StatefulSet** so each pod receives:
- A stable name: `redis-cluster-0`, `redis-cluster-1`, …
- A stable DNS entry via the headless Service
- Its own **PersistentVolumeClaim** (`512Mi` by default, `standard` StorageClass; see [Disk sizing](#disk-sizing))

The default replica count is **6** (`redisCluster.replicas`), which gives:
- **3 masters** (each owns a subset of the 16,384 hash slots)
- **3 replicas** (one replica per master)

### Headless Service

A headless Service (`clusterIP: None`) exposes:
- Port `6379` - Redis client port
- Port `16379` - Redis cluster bus port (used for gossip and failovers)

Because it is headless, every pod gets a resolvable DNS record such as:
```
redis-cluster-0.redis-cluster.default.svc.cluster.local
```

### Pod Anti-Affinity

By default, the chart includes **PodAntiAffinity** rules:
- **Required** - Spread pods across different nodes (`kubernetes.io/hostname`)
- **Preferred** - Spread pods across different zones (`topology.kubernetes.io/zone`)

For single-node test clusters (e.g., `kind`), disable the default anti-affinity:

```bash
helm install redis-cluster helm/redis-cluster/ \
  --set-json affinity='{}'
```

### PodDisruptionBudget

A `PodDisruptionBudget` is created with `minAvailable: n-1`, ensuring only **one** Redis node can be disrupted at a time during voluntary evictions (upgrades, node drains).

### NetworkPolicy

An optional `NetworkPolicy` restricts ingress to:
- Ports `6379` and `16379` from the other Redis pods of the release
- Port `6379` from the bootstrap Job, the helm test pod, and the sources in `networkPolicy.allowedClients`

**Clients are blocked until you list them** in `networkPolicy.allowedClients`. Each entry is a NetworkPolicy `from` peer:

```yaml
networkPolicy:
  allowedClients:
    # Pods with this label in the release namespace
    - podSelector:
        matchLabels:
          app: my-app
    # Pods with this label in another namespace
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: other-namespace
      podSelector:
        matchLabels:
          app: my-app
```

A `namespaceSelector` and a `podSelector` in the **same** entry must both match. As separate entries, either one is enough.

### Graceful handover (preStop)

When a pod that is a master is stopped on purpose (`kubectl delete pod`, a rolling restart, a node drain), a `preStop` hook first runs `CLUSTER FAILOVER` on one of its connected replicas and waits for this node to become a replica. The replica takes over without data loss and clients are redirected to it, so planned restarts cause no write errors instead of waiting out the 15 s `cluster-node-timeout` and a failover election.

The hook tries each healthy replica in turn and gives up `terminationGracePeriodSeconds` minus 10 s after it started (50 s with the default of 60; half the grace period when it is 20 s or less). If no replica takes over, the pod shuts down as a master, as it did before. Replicas skip the hook. Its output goes to the container log (`kubectl logs <pod> -c redis | grep preStop`).

Each handover moves a master to another pod, so after a rolling restart the masters are usually on different pods than before.

---

## ConfigMap

The chart creates a ConfigMap named `redis-cluster-config` that mounts `redis.conf` at `/etc/redis/redis.conf`. Key settings include:

```conf
port 6379
cluster-enabled yes
cluster-node-timeout 15000          # redisConfig.clusterNodeTimeout
cluster-require-full-coverage no
appendonly yes
protected-mode no
bind 0.0.0.0
maxmemory 96mb                      # redisConfig.maxmemory
maxmemory-policy noeviction         # redisConfig.maxmemoryPolicy
min-replicas-to-write 1             # redisConfig.minReplicasToWrite
min-replicas-max-lag 10             # redisConfig.minReplicasMaxLag
cluster-config-file /data/nodes.conf
dir /data
cluster-preferred-endpoint-type hostname
```

The data-safety settings are explained in [Data safety](#data-safety).

At startup, `start.sh` copies this file to `/data/redis.conf` and appends the per-pod settings:

```conf
cluster-announce-ip <pod IP, from the downward API>
cluster-announce-hostname <pod>.<service>.<namespace>.svc.<clusterDomain>.local
```

The bootstrap's temporary Redis server gets the same two settings. Without them its gossip erased `redis-cluster-0`'s hostname from the other nodes, and clients were redirected to the endpoint `?`.

### Why `cluster-preferred-endpoint-type hostname`?

In Kubernetes, pod IPs are **ephemeral**. By setting `cluster-preferred-endpoint-type hostname` and injecting `cluster-announce-hostname` at startup, each node advertises its **stable DNS name** to clients (in `CLUSTER SLOTS`, `CLUSTER SHARDS` and `MOVED` redirects) instead of its ephemeral IP.

The announced hostname is the pod's fully qualified name, so it resolves from **any namespace**. A namespace-relative name such as `redis-cluster-0.redis-cluster` only resolves inside the release namespace, and cluster-aware clients elsewhere failed on their first redirect. If you use TLS with hostname verification, the server certificate needs a SAN of `*.<service>.<namespace>.svc.<clusterDomain>.local` (the cert-manager certificate has it).

This only affects what clients see. Redis nodes still talk to each other over the cluster bus by **IP**, so `cluster-announce-ip` is set to the pod IP and `nodes.conf` records peers by IP.

### Recovering from pod IP changes

When a single pod restarts, it still knows its peers' IPs. It reconnects to them and announces its new IP. When **all** pods are recreated at once (for example, scaling the StatefulSet to 0 and back), every IP in every `nodes.conf` is stale and no node can reach any other.

To handle this, the main container runs [`start.sh`](templates/scripts-configmap.yaml). When the node already belongs to a cluster, the script resolves each peer's stable DNS name in the background and sends `CLUSTER MEET <current-ip>`. The MEET handshake matches the peer's existing node ID and updates its address, so the cluster re-forms with its original slots and data. On a fresh install, `nodes.conf` has no peers and this step is skipped, leaving cluster creation to the bootstrap.

### Replacing a node that lost its disk

When a pod comes back with an empty volume (a lost or deleted PVC, a replaced node with local storage), it starts as a brand-new Redis node that knows no peers. `start.sh` detects this and joins it to the running cluster without manual steps:

1. **Join.** While the node knows only itself, it checks its peers. Once one of them serves slots, it sends `CLUSTER MEET` to that peer. On a fresh install this never fires, because the bootstrap introduces every node before it assigns any slots.
2. **Wait for the old identity to fail.** The peers still remember the node ID this pod had before. The script waits until they have flagged it `fail`, which also means that a lost master has failed over to its replica.
3. **Become a replica.** It runs `CLUSTER REPLICATE` on the healthy master with the fewest healthy replicas. Normally that is the master that lost its replica, or the replica that took over from this pod. It waits until this choice has been stable for 16 s, so it never competes with the bootstrap, which assigns replicas right after the slots.
4. **Forget the old identity.** It runs `CLUSTER FORGET` for every dead node ID that announced this pod's hostname, on every node, within the 60 s window after which gossip would add it back.

Progress shows in `kubectl logs <pod> -c redis` (`Peers already form a cluster`, `replicating`, `Forgot old node ID`). The pod is Ready (as an empty master serving no slots) before step 3 finishes, typically 30-40 s after it starts.

The node only adopts a master that is healthy and serves slots. If a whole shard is gone (a master and all its replicas lost their data), the slots stay uncovered and need manual recovery.

### Redis version notes

The image pins **Redis 7.2.16**. Earlier versions of this chart set `cluster-announce-ip` to the pod's DNS name, and Redis 7.2 patch releases treat that value differently:

| | Redis 7.2.11 | Redis 7.2.16 |
|---|---|---|
| `cluster-announce-ip <hostname>` | Accepted without validation. The hostname is stored as the node's "IP" and resolved when peers connect, so the cluster worked by accident. | Rejected at startup with `FATAL CONFIG FILE ERROR ... Cluster announce IP must be a valid IPv4 or IPv6 address`. Pods crash-loop and the cluster never forms. |
| `cluster-announce-ip <pod IP>` (current chart) | Works | Works |

AlmaLinux 7.2.14 also rejects a hostname. 7.2.12 and 7.2.13 are not in the AlmaLinux repositories and were not tested.

The current chart always announces the pod IP and handles IP changes with the rejoin step above, so it works on both versions. Recovery from a full scale-down and scale-up was verified on 7.2.16 and 7.2.11.

The version is pinned because the dockerfile previously installed whatever `redis` the AlmaLinux `redis:7` stream offered. When the stream moved from 7.2.11 to newer releases, rebuilding the same dockerfile silently produced an image that broke the old chart. To move to a newer 7.2 release, change `redis-7.2.16` in the dockerfile and re-run a full scale-down and scale-up test before relying on it.

---

## Data safety

The defaults favour keeping acknowledged writes over accepting every write. The earlier defaults could lose acknowledged writes in three ways: a partitioned master kept accepting writes, a full shard evicted keys, and a full disk blocked all writes. Each is covered below, together with what the new default costs.

### Write safety during a network partition

Redis Cluster replicates asynchronously. A master that is cut off from the rest of the cluster but still reachable by clients keeps acknowledging writes until it notices it is isolated. Meanwhile the majority promotes its replica. When the partition heals, the old master becomes a replica and **discards every write it accepted while isolated**. With the old defaults (no `min-replicas-to-write`, 15 s `cluster-node-timeout`), an isolated master accepted writes for about 23 s and 1,433 acknowledged writes were lost.

The chart now sets:

| Value | Default | Effect |
|---|---|---|
| `redisConfig.minReplicasToWrite` | `1` | A master rejects writes with `NOREPLICAS` unless at least one replica is connected and acknowledging replication. `0` disables the check. The chart creates one replica per master, so values above `1` are rejected at install. |
| `redisConfig.minReplicasMaxLag` | `10` | Seconds since a replica's last acknowledgement before it stops counting. An isolated master stops accepting writes after about this long. |
| `redisConfig.clusterNodeTimeout` | `15000` | Milliseconds before an unreachable node is marked failed and its replica is promoted. |

**Trade-offs:**

- **Writes stop on a shard whose replica is down.** While a master has no connected replica, every write to its slots fails with `NOREPLICAS Not enough good replicas to write`. Reads keep working. On a single-node kind cluster, deleting a replica pod blocked writes to its shard for about 7 s while the pod restarted. This also happens during rolling restarts (once per replica), node drains, and any time a replica cannot return (for example a lost node or disk), until a replica is back. Set `minReplicasToWrite: 0` if availability matters more than bounding loss.
- **Loss is bounded, not eliminated.** An isolated master can still acknowledge up to about `minReplicasMaxLag` seconds of writes that are lost on failover, and any write in flight during a normal failover can be lost because replication is asynchronous. A lower `minReplicasMaxLag` shrinks the window but makes short replication stalls reject writes.
- **`clusterNodeTimeout`** controls how quickly a failed master is replaced, and how soon an isolated master notices it has lost the majority and stops serving (about 23 s at `15000` in testing). An isolated master stops accepting writes at whichever comes first: `minReplicasMaxLag`, or that point. Lower values shrink both, but turn short network blips into failovers.

**For writes that must survive a failover, use `WAIT`.** After the write, send `WAIT 1 <timeout-ms>` on the same connection. It returns the number of replicas that acknowledged the write; treat a result of `0` as "not durable" and retry or report an error. `WAIT` makes loss much less likely but is still not a strong-consistency guarantee: a replica that acknowledged the write can still lose an election to one that did not.

### Memory limit and eviction

`redisConfig.maxmemoryPolicy` sets what Redis does when `redisConfig.maxmemory` is reached. The default is **`noeviction`**: once the shard is full, writes that need more memory fail with `OOM command not allowed when used memory > 'maxmemory'`. Reads and deletes keep working, and no stored key is dropped.

Any other policy (`allkeys-lru`, `allkeys-lfu`, `allkeys-random`, `volatile-*`) **turns the cluster into a cache**. Redis deletes keys to make room for new ones, the client that wrote them gets no error, and the keys are simply gone. The old default, `allkeys-lru`, silently evicted 66% of acknowledged writes in a shard filled past `maxmemory`. With `noeviction`, the same test evicted no keys and lost none of 7,208 acknowledged writes; the 240 writes that arrived while the shard was full were rejected with `OOM` errors.

Only choose an eviction policy when every key can be recomputed or reloaded. Either way, alert on `used_memory` approaching `maxmemory`, and on `evicted_keys` (from `INFO stats`) when an eviction policy is set.

Keep `resources.limits.memory` well above `maxmemory`. Replication buffers, forks for RDB and AOF rewrites, and fragmentation all use memory outside `maxmemory`.

### Disk sizing

Each pod's PVC holds the RDB snapshot (`dump.rdb`) and the multi-part AOF (`appendonlydir/`). At the worst moment, an AOF rewrite or snapshot, they hold:

- the RDB snapshot, up to the dataset size;
- the AOF base file, up to the dataset size;
- the AOF increment files, which grow until the next rewrite (by default a rewrite starts when they reach the size of the base);
- the new base file being written by the rewrite, up to the dataset size.

**Rule of thumb: `persistence.size` ≥ 3 × `maxmemory`, plus margin.** The default is `512Mi` for `96mb` of `maxmemory`. The chart fails the install or upgrade when `persistence.size` is below 3 × `maxmemory`, with a message that gives the minimum. The check is skipped when `persistence.enabled` is `false` or `maxmemory` is `0`, and can be turned off with `persistence.validateSize: false`.

The old default of `100Mi` could not hold a full `96mb` shard. When the disk filled:

- the AOF rewrite failed first (it needs room for a second copy);
- then every write, **including `DEL`**, was rejected with `MISCONF`, so the data could not be trimmed;
- probes kept passing and there was no failover, so the shard stayed write-dead until someone intervened.

Prefer a StorageClass with `allowVolumeExpansion: true`, and alert on PVC usage (for example `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.7`).

#### Recovering a full disk

The cleanest fix is to expand the volume, if the StorageClass allows it:

```bash
kubectl patch pvc data-redis-cluster-<n> \
  -p '{"spec":{"resources":{"requests":{"storage":"1Gi"}}}}'
```

If it cannot be expanded, free space from inside Redis (run against the affected pod; add `-a`/TLS flags as needed):

1. Let writes through and stop AOF writes:
   ```bash
   kubectl exec redis-cluster-<n> -c redis -- redis-cli config set stop-writes-on-bgsave-error no
   kubectl exec redis-cluster-<n> -c redis -- redis-cli config set appendonly no
   ```
2. Delete data until the dataset fits comfortably (`DEL`/`UNLINK` now succeed).
3. Remove the AOF increment files that Redis no longer uses. Redis 7 keeps them after AOF is disabled, so the disk stays full otherwise:
   ```bash
   kubectl exec redis-cluster-<n> -c redis -- sh -c 'rm -f /data/appendonlydir/appendonly.aof.*.incr.aof'
   ```
4. Turn AOF back on (this rewrites a fresh base from memory) and take a snapshot:
   ```bash
   kubectl exec redis-cluster-<n> -c redis -- redis-cli config set appendonly yes
   kubectl exec redis-cluster-<n> -c redis -- redis-cli bgsave
   ```
   Check that `aof_last_bgrewrite_status:ok` and `rdb_last_bgsave_status:ok` appear in `redis-cli info persistence`.
5. Restore the safety setting:
   ```bash
   kubectl exec redis-cluster-<n> -c redis -- redis-cli config set stop-writes-on-bgsave-error yes
   ```

Then size the volume properly so it does not happen again.

### Upgrading a release installed with the old defaults

These defaults change behaviour for existing releases:

- **`persistence.size` (`100Mi` → `512Mi`).** Kubernetes does not allow changing the volume size of an existing StatefulSet, so `helm upgrade` with the new default fails. Either keep the old size and lower `maxmemory` so the check passes (`--set persistence.size=100Mi --set redisConfig.maxmemory=32mb`), or grow the volumes first:
  ```bash
  for n in 0 1 2 3 4 5; do
    kubectl patch pvc data-redis-cluster-$n -p '{"spec":{"resources":{"requests":{"storage":"512Mi"}}}}'
  done
  kubectl delete statefulset redis-cluster --cascade=orphan   # pods keep running
  helm upgrade redis-cluster helm/redis-cluster/
  ```
  `persistence.validateSize=false` skips the check, but a full disk can then block all writes.
- **`maxmemoryPolicy` (`allkeys-lru` → `noeviction`).** A full shard now returns `OOM` errors instead of evicting keys. If the cluster really is a cache, set `redisConfig.maxmemoryPolicy=allkeys-lru` explicitly.
- **`minReplicasToWrite` (unset → `1`).** Writes to a shard now fail while its replica is down.

Pods read `redis.conf` only when they start, so `helm upgrade` alone does not apply the new settings. Restart the pods one at a time (`kubectl rollout restart statefulset redis-cluster`), or apply them live: `maxmemory-policy`, `min-replicas-to-write`, `min-replicas-max-lag` and `cluster-node-timeout` can all be changed with `CONFIG SET` on every pod. Restarting a replica blocks writes to its shard for a few seconds while `minReplicasToWrite` is `1`.

---

## Init Container (default bootstrap)

The StatefulSet includes an **initContainer** named `cluster-bootstrap` that runs **only on `redis-cluster-0`**.

### What it does

1. **Idempotency check** - If `redis-cluster-0`'s `nodes.conf` already lists other nodes, it exits immediately. The main container reconnects the node.
2. **Checks that no cluster exists** - Queries every peer until all respond. If **any** peer has slots or knows other nodes, a cluster already exists (for example, `redis-cluster-0` lost its disk), so it exits without creating anything and leaves the join to `start.sh` (see [Replacing a node that lost its disk](#replacing-a-node-that-lost-its-disk)).
3. **Forms the cluster** from a temporary Redis instance (with the same announce settings as the main container), using manual Redis cluster commands:
   - `CLUSTER MEET` - Introduces each peer to the seed node
   - `CLUSTER ADDSLOTSRANGE` - Assigns hash slots to the master nodes
   - `CLUSTER REPLICATE` - Attaches replicas to their respective masters
4. **Cleans up** - Shuts down the temporary Redis instance and allows the main container to start.

Every command fails the script on a Redis error reply. (`redis-cli` prints error replies such as `ERR Slot 0 is already busy` but still exits 0, so `set -e` alone never caught them.) A failed init container is restarted by the kubelet. If creation stops after the first `CLUSTER MEET`, the nodes already know each other, so later runs treat them as an existing cluster and do nothing; see [Cluster not forming](#cluster-not-forming).

### Why not `redis-cli --cluster create`?

The standard `redis-cli --cluster create` utility hangs when nodes are configured to announce hostnames rather than IPs. The initContainer therefore uses the lower-level cluster management commands directly.

---

## Bootstrap Job (alternative)

If you prefer **not** to use the initContainer, you can enable an optional Kubernetes **Job** that performs cluster creation after Helm installation:

```bash
helm install redis-cluster helm/redis-cluster/ \
  --set bootstrapJob.enabled=true
```

### What the Job does

The Job runs the same [`bootstrap.sh`](templates/scripts-configmap.yaml) as the initContainer, against `redis-cluster-0`'s running server:
1. Waits for all StatefulSet pods to respond, and exits without changes if any of them already belongs to a cluster (idempotency, including on `helm upgrade`)
2. Forms the cluster with `CLUSTER MEET`, `CLUSTER ADDSLOTSRANGE` and `CLUSTER REPLICATE`

### Important

- The Job and the initContainer are **mutually exclusive**. Enabling the Job automatically removes the initContainer from the StatefulSet.
- The Job is registered as a Helm `post-install,post-upgrade` hook.
- Do not install with `helm install --wait`: Helm waits for the pods to be Ready before it runs the hook, and they only become Ready once the hook has created the cluster.

---

## Customizing Values

| Parameter | Default | Description |
|-----------|---------|-------------|
| `redisCluster.replicas` | `6` | Total nodes (must be even and ≥ 6 for `--cluster-replicas 1`) |
| `image.repository` | `redis-cluster` | Container image repository |
| `image.tag` | `7.2.16` | Container image tag |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy |
| `persistence.enabled` | `true` | Enable PVC per pod |
| `persistence.size` | `512Mi` | PVC size per pod; must be at least 3 × `redisConfig.maxmemory` ([Disk sizing](#disk-sizing)) |
| `persistence.storageClass` | `standard` | StorageClass name |
| `persistence.validateSize` | `true` | Fail the install or upgrade when `persistence.size` is below 3 × `redisConfig.maxmemory` |
| `podDisruptionBudget.enabled` | `true` | Enable PDB |
| `networkPolicy.enabled` | `true` | Enable NetworkPolicy |
| `networkPolicy.allowedClients` | `[]` | NetworkPolicy `from` peers allowed to reach port 6379 (see [NetworkPolicy](#networkpolicy)) |
| `networkPolicy.egress.enabled` | `true` | Enable egress rules (DNS + intra-cluster only) |
| `terminationGracePeriodSeconds` | `60` | Pod shutdown budget; the preStop handover gets this minus 10 s (half of it when 20 s or less) |
| `bootstrapJob.enabled` | `false` | Use Job instead of initContainer |
| `tls.authClients` | `no` | Client certificate auth: `no`, `optional`, or `yes` |
| `clusterDomain` | `cluster` | Kubernetes cluster domain suffix (`svc.<domain>.local`) |
| `auth.enabled` | `false` | Enable Redis password authentication |
| `auth.password` | `""` | Redis password (also used for `masterauth`); stored in a chart-managed Secret |
| `auth.existingSecret` | `""` | Existing Secret with the password; overrides `auth.password` |
| `auth.existingSecretPasswordKey` | `password` | Key of the password in `auth.existingSecret` |
| `tls.reload.enabled` | `true` | Reload the certificate in place when the TLS Secret changes |
| `tls.reload.intervalSeconds` | `30` | How often to check the mounted certificate files |
| `redisConfig.maxmemory` | `"96mb"` | Redis `maxmemory` directive |
| `redisConfig.maxmemoryPolicy` | `noeviction` | What happens at `maxmemory`; any other policy silently drops keys ([Memory limit and eviction](#memory-limit-and-eviction)) |
| `redisConfig.minReplicasToWrite` | `1` | Reject writes on a master without a connected replica (`0` or `1`) ([Write safety](#write-safety-during-a-network-partition)) |
| `redisConfig.minReplicasMaxLag` | `10` | Seconds of replica silence before it stops counting toward `minReplicasToWrite` |
| `redisConfig.clusterNodeTimeout` | `15000` | Milliseconds before an unreachable node is marked failed |
| `resources` | *(see values.yaml)* | CPU/memory limits and requests |
| `affinity` | *(built-in defaults)* | Pod anti-affinity rules |

### Example: deploy with 8 nodes and custom resources

```bash
helm install redis-cluster helm/redis-cluster/ \
  --set redisCluster.replicas=8 \
  --set resources.limits.cpu=1 \
  --set resources.limits.memory=1Gi \
  --set resources.requests.cpu=500m \
  --set resources.requests.memory=512Mi
```

---

## Security Context

All pods run with:
- `runAsUser: 999`
- `runAsGroup: 999`
- `fsGroup: 999`

These IDs match the `redis` user created inside the container image.

---

## Probes

- **LivenessProbe** - `redis-cli ping` over a local Unix socket (`/tmp/redis.sock`). It restarts the container unless the reply is `PONG` (or `LOADING` while the dataset loads), so a node stuck on `BUSY` is restarted. The socket is plaintext, so liveness does not depend on the TLS certificate: an expired certificate does not restart every pod at once.
- **ReadinessProbe** - Checks `cluster_state:ok` via `redis-cli cluster info` on the client port, over TLS when enabled (marks the pod not ready until it has fully joined the cluster, or while its certificate does not verify)

---

## TLS

The chart supports TLS-encrypted client connections. The cluster bus (port 16379) remains plaintext by default; inter-node traffic is protected by the NetworkPolicy.

### Using an existing TLS Secret

Create a Kubernetes Secret containing your certificate, key, and CA certificate:

```bash
kubectl create secret generic redis-cluster-tls \
  --from-file=tls.crt=server.crt \
  --from-file=tls.key=server.key \
  --from-file=ca.crt=ca.crt
```

Install the chart with TLS enabled:

```bash
helm install redis-cluster helm/redis-cluster/ \
  --set tls.enabled=true \
  --set tls.existingSecret=redis-cluster-tls
```

### Using cert-manager

If you have [cert-manager](https://cert-manager.io/) installed, the chart can auto-generate a wildcard certificate:

```bash
helm install redis-cluster helm/redis-cluster/ \
  --set tls.enabled=true \
  --set tls.certManager.enabled=true \
  --set tls.certManager.issuerRef.name=my-issuer \
  --set tls.certManager.issuerRef.kind=ClusterIssuer
```

The generated certificate will include SANs for:
- `*.redis-cluster.default.svc.<clusterDomain>.local`
- `redis-cluster.default.svc.<clusterDomain>.local`

### Certificate rotation

Redis reads its certificate only at startup. With `tls.reload.enabled` (the default), each pod checks the mounted Secret every `tls.reload.intervalSeconds` and, when the files change, reloads them in place with `CONFIG SET tls-cert-file ... tls-key-file ... tls-ca-cert-file ...`, without a restart. This covers `tls.existingSecret` rotated by hand or by an external tool, and cert-manager renewals. Kubelet takes up to about a minute to update the mounted files, so a renewed certificate is served within about 90 s of the Secret change. Existing connections keep their session; new connections get the new certificate. The pod logs `TLS certificate files changed; reloaded.` on success, or the Redis error (for example a key that does not match the certificate) and keeps serving the old certificate.

To check which certificate a pod serves:

```bash
kubectl exec redis-cluster-0 -c redis -- sh -c \
  'echo | openssl s_client -connect 127.0.0.1:6379 2>/dev/null | openssl x509 -noout -serial -enddate'
```

Renew well before expiry (cert-manager does so at two thirds of the lifetime by default). If you disable the reload, a new certificate is served only after a restart. Restart one pod at a time, for example with `kubectl rollout restart statefulset/redis-cluster`, which waits for each pod to be ready before moving on. A tool such as [Reloader](https://github.com/stakater/Reloader) can trigger that on Secret changes.

### Full TLS (cluster bus)

To also encrypt the cluster bus, enable `tls.clusterBus`. **Warning:** your certificates must include SANs that match every pod's hostname, otherwise inter-node handshake will fail.

```bash
helm install redis-cluster helm/redis-cluster/ \
  --set tls.enabled=true \
  --set tls.clusterBus=true \
  --set tls.existingSecret=redis-cluster-tls
```

### Client Certificate Authentication (mTLS)

You can configure whether Redis requires client certificates for TLS connections:

| Mode | Behavior |
|------|----------|
| `no` (default) | Clients do not need to present a certificate. |
| `optional` | Clients may present a certificate; if they do, it is validated. |
| `yes` | All clients must present a valid certificate signed by the CA. |

When `authClients` is set to `optional` or `yes`, the chart automatically configures internal `redis-cli` connections (probes, bootstrap script, test pod) to present the server's own certificate as a client certificate. This works with cert-manager-generated certificates which include both server-auth and client-auth key usages.

```bash
helm install redis-cluster helm/redis-cluster/ \
  --set tls.enabled=true \
  --set tls.authClients=optional \
  --set tls.existingSecret=redis-cluster-tls
```

### TLS Hardening

When TLS is enabled, the chart automatically applies hardened defaults:

- **TLS versions**: Only TLS 1.2 and TLS 1.3 are allowed
- **Cipher preference**: Server selects the cipher (`tls-prefer-server-ciphers yes`)
- **TLS 1.2 ciphers**: ECDHE + AES-GCM only (Forward Secrecy + AEAD)
- **TLS 1.3 ciphersuites**: `TLS_AES_256_GCM_SHA384`, `TLS_CHACHA20_POLY1305_SHA256`, `TLS_AES_128_GCM_SHA256`
- **TLS replication**: Replica→master traffic is encrypted via `tls-replication yes`
- **Session caching**: Enabled by default (20,480 sessions, 300s timeout) for lower handshake overhead

You can disable or tune session caching:

```bash
helm install redis-cluster helm/redis-cluster/ \
  --set tls.enabled=true \
  --set tls.sessionCaching.enabled=true \
  --set tls.sessionCaching.size=20480 \
  --set tls.sessionCaching.timeout=300
```

---

## Security Hardening

This chart includes several production-hardening defaults:

### Container Security

- **Non-root user** (UID/GID 999)
- **Read-only root filesystem**
- **RuntimeDefault seccomp profile**
- **All capabilities dropped**
- **`allowPrivilegeEscalation: false`**
- **Resource limits** (500m CPU / 512Mi memory)

### NetworkPolicy

By default, the chart restricts both ingress and egress:

| Direction | Allowed |
|-----------|---------|
| Ingress | Redis pods of the release on ports 6379/16379; bootstrap Job, helm test pod and `networkPolicy.allowedClients` on port 6379 |
| Egress | DNS (UDP 53) and intra-cluster pods on ports 6379/16379 |

### Redis Password Authentication

Enable password protection for Redis:

```bash
helm install redis-cluster helm/redis-cluster/ \
  --set auth.enabled=true \
  --set auth.password=your-secret-password
```

The chart stores `auth.password` in a Secret named `<release>-redis-cluster-auth`. To manage the Secret yourself, create it and point the chart at it instead:

```bash
kubectl create secret generic redis-password --from-literal=password=your-secret-password
helm install redis-cluster helm/redis-cluster/ \
  --set auth.enabled=true \
  --set auth.existingSecret=redis-password \
  --set auth.existingSecretPasswordKey=password
```

The password stays out of ConfigMaps, pod specs, command lines and Kubernetes events:
- Pods get it through `secretKeyRef` env vars (`REDIS_PASSWORD`, `REDISCLI_AUTH`).
- The start and bootstrap scripts append `requirepass` and `masterauth` to the node's own copy of `redis.conf` (`/data/redis.conf`, mode 600) at startup.
- Probes, scripts and the Helm test pod authenticate through `REDISCLI_AUTH` instead of `redis-cli -a`.

Because `REDISCLI_AUTH` is set in the container, you can run commands without passing the password:

```bash
kubectl exec redis-cluster-0 -c redis -- redis-cli -s /tmp/redis.sock cluster info
```

Pods read the password only at startup. Changing it in the Secret does not change it in running pods, and a rolling restart alone would leave nodes with different passwords. To rotate it, `CONFIG SET requirepass` and `masterauth` on every node first, then update the Secret.

### ServiceAccount Token Automount

The ServiceAccount token is **not mounted into pods** by default (`automount: false`) because Redis does not need to call the Kubernetes API.

---

## Troubleshooting

### Pods stuck in `Pending`

If you see `0/1 nodes are available: 1 node(s) didn't match pod anti-affinity rules`, you are running on a single-node cluster. Re-install with affinity disabled:

```bash
helm uninstall redis-cluster
kubectl delete pvc -l app.kubernetes.io/name=redis-cluster
helm install redis-cluster helm/redis-cluster/ --set-json affinity='{}'
```

### Cluster not forming

Check the initContainer logs on `redis-cluster-0`:

```bash
kubectl logs redis-cluster-0 -c cluster-bootstrap
```

Or, if using the Job:

```bash
kubectl logs -l app.kubernetes.io/name=redis-cluster-bootstrap
```

If the logs say a peer `already belongs to a cluster` but no node has slots, an earlier creation attempt stopped after `CLUSTER MEET`. The bootstrap never runs creation steps against nodes that already know each other, so reset them by hand (with no slots assigned, no node holds data yet), then delete `redis-cluster-0` to rerun the bootstrap:

```bash
for i in 0 1 2 3 4 5; do kubectl exec redis-cluster-$i -c redis -- redis-cli CLUSTER RESET HARD; done
kubectl delete pod redis-cluster-0
```

### Pods crash-loop with `Cluster announce IP must be a valid IPv4 or IPv6 address`

The image runs Redis 7.2.14 or later with an older version of this chart that set `cluster-announce-ip` to a hostname. Upgrade to the current chart, which sets it to the pod IP. See [Redis version notes](#redis-version-notes).

### Writes fail with `NOREPLICAS Not enough good replicas to write`

The master for that key has no replica that acknowledged replication within `redisConfig.minReplicasMaxLag` seconds. Check the shard's replica with `redis-cli cluster nodes` and `redis-cli info replication` on the master. Writes resume once the replica is back. See [Write safety](#write-safety-during-a-network-partition).

### Writes fail with `OOM command not allowed when used memory > 'maxmemory'`

The shard is at `redisConfig.maxmemory` and the policy is `noeviction`. Delete data, raise `maxmemory` (and `persistence.size` and `resources.limits.memory` with it), or add shards. See [Memory limit and eviction](#memory-limit-and-eviction).

### Writes (even `DEL`) fail with `MISCONF`

The pod's disk is full. See [Recovering a full disk](#recovering-a-full-disk).

### Cluster down after all pods restart

After a full restart (for example, scaling to 0 and back), each node re-introduces its peers by their current IPs. Check that this happened:

```bash
kubectl logs redis-cluster-1 -c redis | grep Rejoined
```

You should see one `Rejoined ...` line per peer. A node logs nothing until that peer answers `PING`, so a missing line points to a peer that is not up or not resolvable in DNS.

After a full restart, `cluster_state:ok` (and pod readiness) can briefly report healthy before the `cluster-node-timeout` (`redisConfig.clusterNodeTimeout`, 15 s by default) expires, because nodes have not yet noticed their peers are gone. Check `redis-cli cluster nodes` for `fail` or `fail?` flags rather than relying on the first readiness result.

---

## Files in this Chart

```
helm/redis-cluster/
├── Chart.yaml
├── values.yaml
├── README.md
└── templates/
    ├── _helpers.tpl
    ├── certificate.yaml
    ├── configmap.yaml
    ├── job.yaml
    ├── networkpolicy.yaml
    ├── NOTES.txt
    ├── pdb.yaml
    ├── scripts-configmap.yaml
    ├── secret.yaml
    ├── service.yaml
    ├── serviceaccount.yaml
    ├── statefulset.yaml
    └── tests/
        └── test-connection.yaml
```
