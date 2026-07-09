#!/usr/bin/env bash
# Create the Talos homelab cluster (Docker provisioner) and install Cilium.
# Usage: ./scripts/cluster-up.sh            # 1 control plane + 1 worker
#        WORKERS=2 ./scripts/cluster-up.sh  # scale out (recreate with 2 workers)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
WORKERS="${WORKERS:-1}"
CILIUM_VERSION="${CILIUM_VERSION:-1.19.5}"

talosctl cluster create docker \
  --name "${CLUSTER_NAME}" \
  --workers "${WORKERS}" \
  --cpus-controlplanes 2.0 \
  --memory-controlplanes 2.0GiB \
  --cpus-workers 2.0 \
  --memory-workers 2.5GiB \
  --config-patch "@${REPO_ROOT}/talos/patches/cluster.yaml"

# Credentials are secrets; keep them readable by this user only.
chmod 600 "${HOME}/.talos/config" "${HOME}/.kube/config"

# Nodes stay NotReady until a CNI exists, and Argo CD can't schedule pods
# without one -- so Cilium is installed here, then adopted by Argo CD later.
helm repo add cilium https://helm.cilium.io >/dev/null
helm repo update cilium >/dev/null
helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --values "${REPO_ROOT}/cilium/values.yaml" \
  --wait --timeout 5m

kubectl wait --for=condition=Ready nodes --all --timeout=300s

# Docker provisioner assigns 10.5.0.2 to the control plane, then workers in order.
WORKER_IPS=$(for i in $(seq 1 "${WORKERS}"); do printf '10.5.0.%d,' "$((i + 2))"; done | sed 's/,$//')
talosctl -n 10.5.0.2 health --control-plane-nodes 10.5.0.2 --worker-nodes "${WORKER_IPS}"
echo "Cluster '${CLUSTER_NAME}' is up. Re-bootstrap GitOps with:"
echo "  kubectl apply -f ${REPO_ROOT}/bootstrap/root-app.yaml"
