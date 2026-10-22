# talos-homelab

A small [Talos Linux](https://www.talos.dev) Kubernetes cluster running in Docker
on a MacBook (Apple Silicon), managed with GitOps via [Argo CD](https://argo-cd.readthedocs.io).
Homelab only — no critical workloads.

- **Topology**: 1 control plane + 1 worker (scalable to 2 workers)
- **CNI**: Cilium (eBPF, kube-proxy replacement, NetworkPolicy enforcement, Hubble)
- **GitOps**: app-of-apps — everything under `apps/` is synced by Argo CD from this repo
- **Versions**: pinned — Talos image via talosctl (v1.13.5), Kubernetes 1.36.x,
  Cilium 1.19.5, Argo CD chart 10.1.2 (v3.4.4), podinfo 6.14.0

See [NOTES.md](NOTES.md) for how the cluster bootstraps under the hood
(PKI/certs, control-plane bring-up order, Cilium internals), and
[MONITORING.md](MONITORING.md) for the metrics pipeline to Grafana Cloud
(what's monitored, why, credentials, issues log).

## Layout

```
scripts/            cluster lifecycle (up / down / stop / start)
scripts/ci/         the CI gate (check.sh) and its tests
talos/patches/      Talos machine-config patches (CNI none, kube-proxy off)
cilium/values.yaml  Cilium Helm values (Talos-specific)
argocd/values.yaml  Argo CD Helm values (port-forward only, no ingress)
bootstrap/          root app-of-apps Application (applied once by hand)
apps/               Argo CD Applications (cilium, argocd, network-policies, podinfo)
manifests/          plain manifests synced by apps (network policies)
.github/            CI workflow (the gate) and CODEOWNERS
```

## Daily use

| Action | Command |
|---|---|
| Create cluster | `./scripts/cluster-up.sh` |
| Suspend (keep state) | `./scripts/cluster-stop.sh` |
| Resume | `./scripts/cluster-start.sh` |
| Destroy completely | `./scripts/cluster-down.sh` |
| Argo CD UI | `kubectl port-forward svc/argocd-server -n argocd 8080:443` → https://localhost:8080 |
| Hubble UI | `kubectl port-forward svc/hubble-ui -n kube-system 12000:80` → http://localhost:12000 |
| Cluster health | `talosctl health` / `kubectl get nodes` |
| App status | `kubectl get applications -n argocd` |

**Suspend vs destroy**: `cluster-stop.sh` just stops the node containers — etcd
data and all workloads survive, and `cluster-start.sh` brings everything back in
under a minute. Quitting Docker Desktop has the same effect as stop. Destroy
deletes all state; after recreating, re-apply the root app (below) and Argo CD
restores every application from git.

## Bootstrap (after create/recreate)

```sh
./scripts/cluster-up.sh                      # cluster + Cilium
helm upgrade --install argocd argo/argo-cd \
  --version 10.1.2 -n argocd --create-namespace -f argocd/values.yaml
kubectl -n argocd apply -f <repo-credentials-secret>   # private repo access, see below
kubectl apply -f bootstrap/root-app.yaml     # everything else syncs from git
```

The initial Argo CD install is manual because Argo CD can't manage itself into
existence; afterwards `apps/argocd.yaml` adopts the release and upgrades are
git commits.

### Private repo access

Argo CD needs credentials to read this private repo — a Secret labeled
`argocd.argoproj.io/secret-type: repository` in the `argocd` namespace with
`url`, `username`, and `password` (a GitHub token). Prefer a **fine-grained PAT**
scoped to only this repo with read-only contents permission. Rotate by
regenerating the token and updating the secret:

```sh
kubectl -n argocd create secret generic repo-talos-homelab \
  --from-literal=type=git \
  --from-literal=url=https://github.com/rkandru/talos-homelab.git \
  --from-literal=username=rkandru \
  --from-literal=password=<fine-grained-PAT> \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd label secret repo-talos-homelab argocd.argoproj.io/secret-type=repository --overwrite
```

## Scaling workers

The Docker provisioner can't add nodes to a running cluster. Because all state
lives in git, scale by recreating:

```sh
./scripts/cluster-down.sh
WORKERS=2 ./scripts/cluster-up.sh
# reinstall argocd + repo secret + root app (Bootstrap section above)
```

## Administration

Routine tasks, roughly in order of how often you'll need them:

- **Suspend/resume on demand** — `cluster-stop.sh` / `cluster-start.sh` (see Daily use).
- **Upgrade an app or Cilium/Argo CD** — bump `targetRevision` in the matching
  file under `apps/` (and values in `cilium/` or `argocd/`), commit, push. Argo CD
  syncs it. Nothing is upgraded by hand after bootstrap.
- **Upgrade Kubernetes/Talos** — container mode doesn't support in-place
  `talosctl upgrade`; recreate the cluster with a newer talosctl
  (`brew upgrade siderolabs/tap/talosctl`, then down/up as in Scaling).
- **etcd snapshot (backup)** — `talosctl etcd snapshot ~/talos-etcd-backup.db`.
  For this disposable homelab git is the real backup, but snapshots are useful
  before risky experiments.
- **Rotate the Argo CD admin password** — log in to the UI → User Info → Update
  password. Afterwards delete the bootstrap secret:
  `kubectl -n argocd delete secret argocd-initial-admin-secret`.
- **Rotate GitHub repo credentials** — regenerate the fine-grained PAT and
  re-run the secret command in "Private repo access".
- **Rotate Talos client credentials** — `talosctl config new` issues a fresh
  client cert; kubeconfig via `talosctl kubeconfig`. Keep both files `chmod 600`
  (cluster-up does this).
- **Check overall health** — `talosctl health`, `kubectl get nodes`,
  `kubectl get applications -n argocd`, `cilium status` (if cilium CLI installed)
  or `kubectl -n kube-system get pods -l k8s-app=cilium`.
- **Reclaim disk** — after destroying clusters: `docker system prune` (careful:
  affects all Docker resources, not just Talos).

## CI gate

Every pull request and push to `main` runs `.github/workflows/ci.yaml`, whose
`ci-gate` job runs `scripts/ci/check.sh`:

| Stage | What it catches |
|---|---|
| `yamllint` | YAML that does not parse, plus the rules in `.yamllint.yaml` |
| `kubeconform` | invalid objects under `apps/`, `bootstrap/`, `manifests/`, checked against Kubernetes 1.36 and CRD schemas (a misspelt Argo CD field fails, though Argo would silently ignore it) |
| `helm` | `helm template` of every Helm-sourced Argo app with its real values: broken values files and values the chart's schema rejects |
| `shellcheck` | every `*.sh` |

Run it locally before pushing (`./scripts/ci/check.sh`, or one stage, e.g.
`./scripts/ci/check.sh helm`). The tool versions are pinned in the workflow.
After changing the gate itself, run `./scripts/ci/test-check.sh`, which feeds
the gate one deliberately broken copy of the repo per case.

This matters more here than in most repos: this is the Agent Factory's Pilot
Repo (agentic-devops ADR 0010), and whatever merges to `main` is synced onto
the cluster the factory runs on. `.github/CODEOWNERS` assigns the Protected
Paths (kagent, agentgateway, Cilium, `bootstrap/`, `talos/`, and the gate
itself) to the operator. Labels and branch protection are set by
`agentic-devops/scripts/factory-repo-setup.sh rkandru/talos-homelab ci-gate`.
Branch protection on a private repo needs GitHub Pro.

## Security posture

Sensible for a localhost homelab; not a production hardening guide.

- Talos: API-only management (mTLS, no SSH), control plane tainted, Pod Security
  Admission enforcing `baseline` by default, RBAC on.
- The two published ports (Kubernetes API, Talos API) both require client
  certificates — anonymous connections are rejected. Docker Desktop publishes
  them on all interfaces by default; to force localhost-only binding, add
  `"ip": "127.0.0.1"` to the Docker daemon config (Docker Desktop → Settings →
  Docker Engine) and recreate the cluster.
- Argo CD reachable only via port-forward; TLS kept on; initial admin secret
  deleted after password change; Dex/SSO off.
- Cilium enforces NetworkPolicy (see `manifests/network-policies/` for the
  default-deny + explicit-allow example in the `demo` namespace).
- Credentials (`~/.talos/config`, `~/.kube/config`) are user-read-only and
  gitignored.
- Docker-mode caveats: nodes are privileged containers sharing Docker Desktop's
  Linux VM kernel; no disk encryption/Secure Boot. Move to VMs (UTM/QEMU) if
  that ever matters.

## Later ideas

- Argo CD SSO instead of the admin user
- VM-based Talos (UTM/QEMU) for closer-to-metal behavior (upgrades, disk encryption)
