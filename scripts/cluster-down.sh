#!/usr/bin/env bash
# Destroy the cluster entirely (containers and state are deleted).
# All workloads are restored from git on the next cluster-up + bootstrap.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
talosctl cluster destroy --name "${CLUSTER_NAME}"
