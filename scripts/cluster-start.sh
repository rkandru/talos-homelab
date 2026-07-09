#!/usr/bin/env bash
# Resume a cluster previously suspended with cluster-stop.sh.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
CONTAINERS=$(docker ps -a --filter "label=talos.cluster.name=${CLUSTER_NAME}" --filter "status=exited" -q)
if [ -z "${CONTAINERS}" ]; then
  echo "No stopped containers found for cluster '${CLUSTER_NAME}'." >&2
  exit 1
fi
docker start ${CONTAINERS}

echo "Waiting for Kubernetes API and nodes..."
# The apiserver takes ~30s to come back; kubectl wait aborts on connection
# errors, so poll until the API answers before waiting on node readiness.
for _ in $(seq 1 60); do
  kubectl get --raw /readyz >/dev/null 2>&1 && break
  sleep 5
done
kubectl wait --for=condition=Ready nodes --all --timeout=300s
echo "Cluster '${CLUSTER_NAME}' resumed."
