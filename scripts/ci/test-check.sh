#!/usr/bin/env bash
# Tests for the CI gate. Each case copies the repo's tracked files into a
# throwaway directory, injects one kind of breakage, runs scripts/ci/check.sh
# there, and asserts on its exit status. Run before changing the gate:
#   ./scripts/ci/test-check.sh
# Needs the same tools as the gate itself (see scripts/ci/check.sh).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0

# run_case NAME EXPECTED(pass|fail) STAGE MUTATION [BLAMED_FILE]
# MUTATION is a function run inside the copy before the gate. A failing case
# must also name BLAMED_FILE in the gate's output, so it fails for the injected
# reason and not because the gate itself is broken.
run_case() {
  local name="$1" expected="$2" stage="$3" mutation="$4" blamed="${5:-}"
  local copy="${WORK}/${name}"
  mkdir -p "${copy}"
  (cd "${REPO_ROOT}" && git ls-files -z --cached --others --exclude-standard \
    | xargs -0 -I{} rsync -R "{}" "${copy}/")
  (cd "${copy}" && "${mutation}")

  local actual=pass
  (cd "${copy}" && ./scripts/ci/check.sh "${stage}") >"${copy}.log" 2>&1 || actual=fail

  if [ "${actual}" = "${expected}" ] && { [ -z "${blamed}" ] || grep -qF "${blamed}" "${copy}.log"; }; then
    echo "ok   ${name} (${stage}: ${actual})"
  else
    echo "FAIL ${name}: expected ${expected}${blamed:+ blaming ${blamed}}, got ${actual} — gate output:"
    sed 's/^/     /' "${copy}.log"
    failures=$((failures + 1))
  fi
}

no_change() { :; }

invalid_deployment() {
  cat > manifests/demo-loadgen/broken.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken
spec:
  replicas: two
  selector:
    matchLabels:
      app: broken
  template:
    metadata:
      labels:
        app: broken
    spec:
      containers:
        - name: broken
          image: busybox:1.36
EOF
}

# A misspelt Argo field is silently ignored by Argo CD, so the gate has to know
# the Application schema to catch it.
misspelt_application_field() {
  sed -i.bak 's/^  syncPolicy:$/  syncPolice:/' apps/podinfo.yaml && rm apps/podinfo.yaml.bak
}

unparseable_values_file() {
  printf 'cluster:\n  name: talos-homelab\n   destinations: [\n' > monitoring/values.yaml
}

unparseable_manifest() {
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n data: {\n' \
    > manifests/demo-loadgen/broken.yaml
}

# Parses fine, so only the chart's values.schema.json can reject it.
schema_violating_values() {
  sed -i.bak 's/^  replicas: 1$/  replicas: two/' cilium/values.yaml && rm cilium/values.yaml.bak
}

shellcheck_error() {
  cat > scripts/broken.sh <<'EOF'
#!/usr/bin/env bash
cd $1
rm -rf $2/*
EOF
  chmod +x scripts/broken.sh
}

run_case clean-repo-passes            pass all          no_change
run_case invalid-manifest-fails       fail kubeconform  invalid_deployment         manifests/demo-loadgen/broken.yaml
run_case misspelt-argo-field-fails    fail kubeconform  misspelt_application_field apps/podinfo.yaml
run_case unparseable-yaml-fails       fail yamllint     unparseable_manifest       manifests/demo-loadgen/broken.yaml
run_case broken-helm-values-fails     fail helm         unparseable_values_file    monitoring/values.yaml
run_case schema-invalid-values-fails  fail helm         schema_violating_values    cilium/values.yaml
run_case shellcheck-error-fails       fail shellcheck   shellcheck_error           scripts/broken.sh

if [ "${failures}" -gt 0 ]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all cases passed"
