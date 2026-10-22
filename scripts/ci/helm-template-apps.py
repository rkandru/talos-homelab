#!/usr/bin/env python3
"""Render every Helm-sourced Argo CD Application in apps/ with `helm template`.

Called by the `helm` stage of scripts/ci/check.sh. For each Helm source it
reproduces what Argo CD would feed Helm: the chart and pinned version, the
release name, the destination namespace, `valuesObject` / `values`, and
`valueFiles` from this repo (`$values/...` refs). A values file that does not
parse, or values that a chart's values.schema.json rejects, fails here before
Argo CD ever sees them.

Sources that are plain git paths are not rendered: the ones in this repo are
covered by the kubeconform stage, and the ones in other repos are not this
repo's content.
"""
import glob
import os
import subprocess
import sys
import tempfile

import yaml  # PyYAML, installed alongside yamllint

THIS_REPO = "https://github.com/rkandru/talos-homelab.git"
KUBERNETES_VERSION = "1.36.1"


def helm_sources(app):
    spec = app.get("spec", {})
    sources = spec.get("sources") or [spec.get("source", {})]
    refs = {s["ref"]: s for s in sources if "ref" in s}
    return [s for s in sources if "chart" in s], refs


def value_file_path(app_file, ref_value, refs):
    """Map a `$values/cilium/values.yaml` style entry to a local path."""
    if not ref_value.startswith("$"):
        raise ValueError(f"{app_file}: chart-relative valueFiles are not supported: {ref_value}")
    ref, _, rel = ref_value[1:].partition("/")
    source = refs.get(ref)
    if source is None or source.get("repoURL") != THIS_REPO:
        raise ValueError(f"{app_file}: valueFiles ref ${ref} does not point at this repo")
    return rel


def render(app_file, app, source, refs, tmp):
    helm = source.get("helm", {})
    release = helm.get("releaseName") or app["metadata"]["name"]
    namespace = app["spec"].get("destination", {}).get("namespace", "default")
    repo, chart, version = source["repoURL"], source["chart"], source["targetRevision"]

    if repo.startswith(("http://", "https://")):
        cmd = ["helm", "template", release, chart, "--repo", repo]
    else:
        cmd = ["helm", "template", release, f"oci://{repo.rstrip('/')}/{chart}"]
    cmd += ["--version", str(version), "--namespace", namespace,
            "--kube-version", KUBERNETES_VERSION]

    described = []
    for entry in helm.get("valueFiles", []):
        path = value_file_path(app_file, entry, refs)
        cmd += ["--values", path]
        described.append(path)
    for key in ("valuesObject", "values"):
        if key in helm:
            inline = os.path.join(tmp, f"{release}-{key}.yaml")
            with open(inline, "w") as f:
                f.write(helm[key] if isinstance(helm[key], str) else yaml.safe_dump(helm[key]))
            cmd += ["--values", inline]
            described.append(f"{app_file} spec.source.helm.{key}")
    for param in helm.get("parameters", []):
        cmd += ["--set", f"{param['name']}={param['value']}"]

    result = subprocess.run(cmd, capture_output=True, text=True)
    label = f"{app_file}: {chart}@{version}"
    if result.returncode != 0:
        print(f"FAIL {label} (values: {', '.join(described) or 'chart defaults'})")
        print("     " + result.stderr.strip().replace("\n", "\n     "))
        return False
    print(f"ok   {label}")
    return True


def main():
    ok = True
    with tempfile.TemporaryDirectory() as tmp:
        for app_file in sorted(glob.glob("apps/*.yaml")):
            with open(app_file) as f:
                apps = [d for d in yaml.safe_load_all(f) if d and d.get("kind") == "Application"]
            for app in apps:
                try:
                    sources, refs = helm_sources(app)
                    for source in sources:
                        ok = render(app_file, app, source, refs, tmp) and ok
                except ValueError as err:
                    print(f"FAIL {err}")
                    ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
