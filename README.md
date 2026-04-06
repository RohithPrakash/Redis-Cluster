# Redis Cluster on Kubernetes

This repository contains a **production-ready container image** and **Helm chart** for deploying a Redis Cluster on Kubernetes.

---

## What's Included

| Component | Path | Description |
|-----------|------|-------------|
| **Dockerfile** | [`dockerfile`](./dockerfile) | AlmaLinux 9 based image with Redis 7.2 |
| **Helm Chart** | [`cluster/redis-cluster/`](./cluster/redis-cluster/) | Full Kubernetes deployment chart |

---

## Dockerfile

The [`dockerfile`](./dockerfile) at the repository root builds the Redis container image used by the Helm chart.

### Base Image
- **`almalinux:9`** - enterprise-grade, RHEL-compatible Linux distribution

### What it does
1. Enables the AlmaLinux `redis:7` module stream to install **Redis 7.2.11**
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
docker build -t redis-cluster:7.2 -f dockerfile .
```

### Load into a local kind cluster

```bash
kind load docker-image redis-cluster:7.2
```

---

## Helm Chart

For full documentation on deploying, configuring, and operating the Redis Cluster on Kubernetes, see the Helm chart's dedicated README:

👉 **[cluster/redis-cluster/README.md](./cluster/redis-cluster/README.md)**

It covers:
- Installation and uninstallation commands
- Architecture (StatefulSet, headless Service, PVCs, PDB, NetworkPolicy)
- ConfigMap and Redis configuration
- How the initContainer bootstrap works
- How the optional Kubernetes Job bootstrap works
- Customizing `values.yaml`
- Troubleshooting

---

## Quick Start

```bash
# 1. Build and load the image
docker build -t redis-cluster:7.2 -f dockerfile .
kind load docker-image redis-cluster:7.2

# 2. Install the Helm chart
helm install redis-cluster cluster/redis-cluster/

# If the Kubernetes cluster has a single node

helm install redis-cluster cluster/redis-cluster/ --set-json affinity='{}'

# 3. Verify cluster health
kubectl exec -it redis-cluster-0 -- redis-cli cluster info
kubectl exec -it redis-cluster-0 -- redis-cli cluster nodes
```

---

## Repository Structure

```
.
├── dockerfile                          # AlmaLinux 9 + Redis 7.2 image
├── README.md                           # You are here
└── cluster/redis-cluster/
    ├── README.md                       # Helm chart documentation
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── statefulset.yaml
        ├── service.yaml
        ├── configmap.yaml
        ├── scripts-configmap.yaml
        ├── pdb.yaml
        ├── networkpolicy.yaml
        ├── job.yaml
        └── ...
```
