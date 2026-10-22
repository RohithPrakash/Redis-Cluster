<!-- SPDX-License-Identifier: Apache-2.0 -->

# Redis Cluster on Kubernetes

This repository contains a **production-ready container image** and **Helm chart** for deploying a Redis Cluster on Kubernetes.

---

## What's Included

| Component | Path | Description |
|-----------|------|-------------|
| **Dockerfile** | [`dockerfile`](./dockerfile) | AlmaLinux 9 based image with Redis 7.2.16 |
| **Helm Chart** | [`helm/redis-cluster/`](./helm/redis-cluster/) | Full Kubernetes deployment chart |

---

## Dockerfile

The [`dockerfile`](./dockerfile) at the repository root builds the Redis container image used by the Helm chart.

### Base Image
- **`almalinux:9`** - enterprise-grade, RHEL-compatible Linux distribution

### What it does
1. Enables the AlmaLinux `redis:7` module stream and installs **Redis 7.2.16**. The version is pinned (`redis-7.2.16`) so rebuilding the image always produces the same Redis. Patch releases of 7.2 have changed behaviour the chart depends on; see [Redis version notes](./helm/redis-cluster/README.md#redis-version-notes).
2. Ensures the `redis` user and group are assigned **UID/GID 999**
3. Creates `/data` as the working directory for persistent storage
4. Exposes ports:
   - `6379` - Redis client port
   - `16379` - Redis cluster bus port
5. Starts Redis server using a mounted configuration file:
   ```dockerfile
   CMD ["redis-server", "/etc/redis/redis.conf"]
   ```

### Build the image

```bash
docker build -t redis-cluster:7.2.16 -f dockerfile .
```

### Load into a local kind cluster

```bash
kind load docker-image redis-cluster:7.2.16
```

---

## Helm Chart

For full documentation on deploying, configuring, and operating the Redis Cluster on Kubernetes, see the Helm chart's dedicated README:

👉 **[helm/redis-cluster/README.md](./helm/redis-cluster/README.md)**

It covers:
- Installation and uninstallation commands
- Architecture (StatefulSet, headless Service, PVCs, PDB, NetworkPolicy)
- ConfigMap and Redis configuration
- How the initContainer bootstrap works
- How the optional Kubernetes Job bootstrap works
- How the cluster recovers when every pod restarts with a new IP
- Differences between Redis 7.2.11 and 7.2.16
- Customizing `values.yaml`
- Troubleshooting

---

## Quick Start

```bash
# 1. Build and load the image
docker build -t redis-cluster:7.2.16 -f dockerfile .
kind load docker-image redis-cluster:7.2.16

# 2. Install the Helm chart
helm install redis-cluster helm/redis-cluster/

# If the Kubernetes cluster has a single node

helm install redis-cluster helm/redis-cluster/ --set-json affinity='{}'

# 3. Verify cluster health
kubectl exec -it redis-cluster-0 -- redis-cli cluster info
kubectl exec -it redis-cluster-0 -- redis-cli cluster nodes
```

---

## Repository Structure

```
.
├── dockerfile                          # AlmaLinux 9 + Redis 7.2.16 image
├── README.md                           # You are here
└── helm/redis-cluster/
    ├── README.md                       # Helm chart documentation
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── statefulset.yaml
        ├── service.yaml
        ├── configmap.yaml
        ├── scripts-configmap.yaml      # bootstrap.sh and start.sh
        ├── pdb.yaml
        ├── networkpolicy.yaml
        ├── job.yaml
        └── ...
```
