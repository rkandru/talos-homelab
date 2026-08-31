#!/usr/bin/env bash
# Create the Talos homelab cluster (Docker provisioner) and install Cilium.
# Usage: ./scripts/cluster-up.sh            # 1 control plane + 1 worker
#        WORKERS=2 ./scripts/cluster-up.sh  # scale out (recreate with 2 workers)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
WORKERS="${WORKERS:-1}"
CILIUM_VERSION="${CILIUM_VERSION:-1.19.5}"

# SIZING — read before lowering these.
#
# These flags become hard Docker memory limits on the node containers. The trap:
# each Talos node reports the DOCKER VM's total memory (~7.4Gi) as Kubernetes
# `allocatable`, NOT its own container limit. So `kubectl describe node` shows
# roughly 3x the memory that actually exists, and the scheduler will happily
# place pods until the kubelet itself is starved — which presents as the node
# going NotReady with "Kubelet stopped posting node status", not as an OOMKill.
#
# That happened on 2026-08-31 when Keycloak (1280Mi request) was deployed onto a
# 2.5GiB worker that was already over-committed. See agentic-devops
# docs/PLATFORM-BUILD-NOTES.md step 17.
#
# Budget: controlplane 2.5GiB + worker 4.5GiB = 7GiB inside an 8.2GB Docker
# Desktop VM, leaving ~1.2GB for Docker itself. Raise the VM's memory in Docker
# Desktop settings before raising these further.
#
# `docker stats` is the source of truth for real usage. `kubectl top` / node
# allocatable are not.
#
# To resize a RUNNING cluster without recreating it (no state loss):
#   docker update --memory 4.5g --memory-swap 4.5g homelab-worker-1
#   docker update --memory 2.5g --memory-swap 2.5g homelab-controlplane-1
# Then mirror the change here, or the next cluster-up.sh silently reverts it.
talosctl cluster create docker \
  --name "${CLUSTER_NAME}" \
  --workers "${WORKERS}" \
  --cpus-controlplanes 2.0 \
  --memory-controlplanes 2.5GiB \
  --cpus-workers 2.0 \
  --memory-workers 4.5GiB \
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
