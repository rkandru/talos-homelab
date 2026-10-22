#!/usr/bin/env bash
# Suspend the cluster without losing state: stops the node containers.
# etcd data and all workloads survive; resume with cluster-start.sh.
# (Quitting Docker Desktop entirely has the same effect.)
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
CONTAINERS=$(docker ps --filter "label=talos.cluster.name=${CLUSTER_NAME}" -q)
if [ -z "${CONTAINERS}" ]; then
  echo "No running containers found for cluster '${CLUSTER_NAME}'." >&2
  exit 1
fi
# One container ID per word: the split is the point.
# shellcheck disable=SC2086
docker stop ${CONTAINERS}
echo "Cluster '${CLUSTER_NAME}' stopped. Resume with scripts/cluster-start.sh"
