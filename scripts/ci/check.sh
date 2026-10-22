#!/usr/bin/env bash
# The CI gate for this repo, run by .github/workflows/ci.yaml on every pull
# request and push to main, and runnable locally before pushing:
#   ./scripts/ci/check.sh            # every stage
#   ./scripts/ci/check.sh helm       # one stage
#
# Why it exists: everything merged to main is auto-synced onto the cluster by
# Argo CD, including what the Agent Factory proposes (agentic-devops ADR 0010).
# Green here has to mean "this will at least render and validate".
#
# Tools (versions pinned in the workflow): Python 3 with PyYAML, yamllint,
# kubeconform, helm and shellcheck.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"

# files PATTERN... — NUL-separated repo files matching any find -name PATTERN.
files() {
  local expr=() pattern
  for pattern in "$@"; do
    [ "${#expr[@]}" -gt 0 ] && expr+=(-o)
    expr+=(-name "${pattern}")
  done
  find . -path ./.git -prune -o -type f \( "${expr[@]}" \) -print0 | sort -z
}

stage_yamllint() {
  # --strict: a warning fails the gate too. Rules live in .yamllint.yaml.
  files '*.yaml' '*.yml' | xargs -0 yamllint --strict --format parsable
}

# Kubernetes schemas for the cluster's version, plus CRD schemas (Argo CD
# Application, CiliumNetworkPolicy, ...) from a pinned commit of the
# community CRDs catalog, so a catalog change cannot turn the gate red.
KUBERNETES_VERSION="1.36.1"
CRDS_CATALOG="https://raw.githubusercontent.com/datreeio/CRDs-catalog/501527ab9c40c827144c8f45945b25a023e344ce"

stage_kubeconform() {
  local cache="${KUBECONFORM_CACHE:-${TMPDIR:-/tmp}/kubeconform-cache}"
  mkdir -p "${cache}"
  # Values files (cilium/, argocd/, monitoring/) and Talos patches are not
  # Kubernetes objects; everything that Argo CD applies from this repo is.
  find apps bootstrap manifests -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 \
    | sort -z \
    | xargs -0 kubeconform -strict -summary -output text -cache "${cache}" \
        -kubernetes-version "${KUBERNETES_VERSION}" \
        -schema-location default \
        -schema-location "${CRDS_CATALOG}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
}

stage_helm() {
  # Needs Python with PyYAML, which the yamllint install provides.
  "${PYTHON:-python3}" scripts/ci/helm-template-apps.py
}

stage_shellcheck() {
  files '*.sh' | xargs -0 shellcheck --external-sources
}

STAGES=(yamllint kubeconform helm shellcheck)
selected="${1:-all}"
if [ "${selected}" = "all" ]; then
  run=("${STAGES[@]}")
else
  run=("${selected}")
fi

failed=()
for stage in "${run[@]}"; do
  if ! declare -F "stage_${stage}" >/dev/null; then
    echo "unknown stage '${stage}' (stages: ${STAGES[*]} all)" >&2
    exit 2
  fi
  echo "::group::${stage}"
  if "stage_${stage}"; then
    echo "::endgroup::"
  else
    echo "::endgroup::"
    echo "::error::${stage} failed"
    failed+=("${stage}")
  fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "gate failed: ${failed[*]}" >&2
  exit 1
fi
echo "gate passed: ${run[*]}"
