# Redis Cluster Helm Chart

A production-ready Helm chart for deploying an **n-node Redis Cluster** on Kubernetes. The chart defaults to **6 nodes** (3 masters + 3 replicas) and uses a **StatefulSet** with stable network identities and persistent storage.

---

## Prerequisites

- Kubernetes 1.25+
- Helm 3.10+
- A container image with `redis-server` and `redis-cli` (see the [`dockerfile`](../../dockerfile) in this repo)

---

## Quick Start

### 1. Build / load the image (local kind cluster)

```bash
docker build -t redis-cluster:7.2 -f dockerfile .
kind load docker-image redis-cluster:7.2
```

### 2. Install the chart

```bash
helm install redis-cluster cluster/redis-cluster/

# If the Kubernetes cluster has a single node

helm install redis-cluster cluster/redis-cluster/ --set-json affinity='{}'
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
- Its own **PersistentVolumeClaim** (`100Mi` by default, `standard` StorageClass)

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
helm install redis-cluster cluster/redis-cluster/ \
  --set-json affinity='{}'
```

### PodDisruptionBudget

A `PodDisruptionBudget` is created with `minAvailable: n-1`, ensuring only **one** Redis node can be disrupted at a time during voluntary evictions (upgrades, node drains).

### NetworkPolicy

An optional `NetworkPolicy` restricts ingress to:
- Port `6379` from pods in the same namespace with matching labels
- Port `16379` from pods in the same namespace with matching labels

---

## ConfigMap

The chart creates a ConfigMap named `redis-cluster-config` that mounts `redis.conf` at `/etc/redis/redis.conf`. Key settings include:

```conf
port 6379
cluster-enabled yes
cluster-node-timeout 15000
cluster-require-full-coverage no
appendonly yes
protected-mode no
bind 0.0.0.0
maxmemory-policy allkeys-lru
cluster-config-file /data/nodes.conf
dir /data
cluster-preferred-endpoint-type hostname
```

### Why `cluster-preferred-endpoint-type hostname`?

In Kubernetes, pod IPs are **ephemeral**. If a pod restarts, it gets a new IP. Redis normally stores peer IPs in `nodes.conf`, which would break the cluster after a restart. By setting `cluster-preferred-endpoint-type hostname` and dynamically injecting `cluster-announce-ip` / `cluster-announce-hostname` at startup, each node advertises its **stable DNS name** instead of its ephemeral IP. This makes the cluster resilient to pod rescheduling.

---

## Init Container (default bootstrap)

The StatefulSet includes an **initContainer** named `cluster-bootstrap` that runs **only on `redis-cluster-0`**.

### What it does

1. **Idempotency check** - Starts a temporary Redis instance and checks whether `cluster_state` is already `ok` or whether it already knows multiple cluster nodes. If so, it exits immediately.
2. **Waits for peers** - Pings every pod (`redis-cluster-0` through `redis-cluster-n`) until all respond.
3. **Forms the cluster** using manual Redis cluster commands:
   - `CLUSTER MEET` - Introduces each peer to the seed node
   - `CLUSTER ADDSLOTS` - Assigns hash slots to the three master nodes
   - `CLUSTER REPLICATE` - Attaches replicas to their respective masters
4. **Cleans up** - Shuts down the temporary Redis instance and allows the main container to start.

### Why not `redis-cli --cluster create`?

The standard `redis-cli --cluster create` utility hangs when nodes are configured to announce hostnames rather than IPs. The initContainer therefore uses the lower-level cluster management commands directly.

---

## Bootstrap Job (alternative)

If you prefer **not** to use the initContainer, you can enable an optional Kubernetes **Job** that performs cluster creation after Helm installation:

```bash
helm install redis-cluster cluster/redis-cluster/ \
  --set bootstrapJob.enabled=true
```

### What the Job does

The Job runs a single pod that:
1. Waits for all StatefulSet pods to respond to `PING`
2. Checks whether the cluster is already initialized (idempotency)
3. Runs `redis-cli --cluster create ... --cluster-replicas 1 --cluster-yes`

### Important

- The Job and the initContainer are **mutually exclusive**. Enabling the Job automatically removes the initContainer from the StatefulSet.
- The Job is registered as a Helm `post-install,post-upgrade` hook.

---

## Customizing Values

| Parameter | Default | Description |
|-----------|---------|-------------|
| `redisCluster.replicas` | `6` | Total nodes (must be even and ≥ 6 for `--cluster-replicas 1`) |
| `image.repository` | `redis-cluster` | Container image repository |
| `image.tag` | `7.2` | Container image tag |
| `image.pullPolicy` | `IfNotPresent` | Image pull policy |
| `persistence.enabled` | `true` | Enable PVC per pod |
| `persistence.size` | `100Mi` | PVC size per pod |
| `persistence.storageClass` | `standard` | StorageClass name |
| `podDisruptionBudget.enabled` | `true` | Enable PDB |
| `networkPolicy.enabled` | `true` | Enable NetworkPolicy |
| `bootstrapJob.enabled` | `false` | Use Job instead of initContainer |
| `tls.authClients` | `no` | Client certificate auth: `no`, `optional`, or `yes` |
| `clusterDomain` | `cluster` | Kubernetes cluster domain suffix (`svc.<domain>.local`) |
| `resources` | `{}` | CPU/memory limits and requests |
| `affinity` | *(built-in defaults)* | Pod anti-affinity rules |

### Example: deploy with 8 nodes and custom resources

```bash
helm install redis-cluster cluster/redis-cluster/ \
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

- **LivenessProbe** - `redis-cli ping` (restarts the container if Redis is unresponsive)
- **ReadinessProbe** - Checks `cluster_state:ok` via `redis-cli cluster info` (removes the pod from Service endpoints until it has fully joined the cluster)

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
helm install redis-cluster cluster/redis-cluster/ \
  --set tls.enabled=true \
  --set tls.existingSecret=redis-cluster-tls
```

### Using cert-manager

If you have [cert-manager](https://cert-manager.io/) installed, the chart can auto-generate a wildcard certificate:

```bash
helm install redis-cluster cluster/redis-cluster/ \
  --set tls.enabled=true \
  --set tls.certManager.enabled=true \
  --set tls.certManager.issuerRef.name=my-issuer \
  --set tls.certManager.issuerRef.kind=ClusterIssuer
```

The generated certificate will include SANs for:
- `*.redis-cluster.default.svc.<clusterDomain>.local`
- `redis-cluster.default.svc.<clusterDomain>.local`

### Full TLS (cluster bus)

To also encrypt the cluster bus, enable `tls.clusterBus`. **Warning:** your certificates must include SANs that match every pod's hostname, otherwise inter-node handshake will fail.

```bash
helm install redis-cluster cluster/redis-cluster/ \
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
helm install redis-cluster cluster/redis-cluster/ \
  --set tls.enabled=true \
  --set tls.authClients=optional \
  --set tls.existingSecret=redis-cluster-tls
```

---

## Troubleshooting

### Pods stuck in `Pending`

If you see `0/1 nodes are available: 1 node(s) didn't match pod anti-affinity rules`, you are running on a single-node cluster. Re-install with affinity disabled:

```bash
helm uninstall redis-cluster
kubectl delete pvc -l app.kubernetes.io/name=redis-cluster
helm install redis-cluster cluster/redis-cluster/ --set-json affinity='{}'
```

### Cluster not forming

Check the initContainer logs on `redis-cluster-0`:

```bash
kubectl logs redis-cluster-0 -c cluster-bootstrap
```

Or, if using the Job:

```bash
kubectl logs -l app.kubernetes.io/name=redis-cluster -l app.kubernetes.io/component=bootstrap
```

---

## Files in this Chart

```
cluster/redis-cluster/
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
    ├── service.yaml
    ├── serviceaccount.yaml
    ├── statefulset.yaml
    └── tests/
        └── test-connection.yaml
```
