# MONITORING — Talos + Kubernetes metrics → Grafana Cloud

Set up on 2026-07-09. Metrics only (no logs/traces yet). Destination is the
Grafana Cloud stack **rahulkandru.grafana.net** (Prometheus/Mimir endpoint
`prometheus-prod-43-prod-ap-south-1`, instance ID `2838151`).

> **Current mode: Talos metrics only** (node-exporter machine metrics + etcd).
> Kubernetes metrics (kubelet, cAdvisor, kube-state-metrics, API server) are
> configured but switched off to stay inside the stack's 15,000 active-series
> limit, which is shared with two other senders on this account (see issue 7).
> To switch K8s metrics on: in `monitoring/values.yaml` set
> `clusterMetrics.enabled: true` and
> `telemetryServices.kube-state-metrics.deploy: true`, then commit + push.

## Architecture

No Prometheus or Grafana runs in the cluster. **Grafana Alloy** (deployed by
Grafana's `k8s-monitoring` Helm chart v4.2.1, managed as the `monitoring` Argo
CD app) scrapes everything locally and remote-writes to Grafana Cloud:

```
node-exporter (DaemonSet, all nodes)  ─┐
kube-state-metrics (Deployment)       ─┤
kubelet + cAdvisor (:10250, mTLS)     ─┼→ Alloy (alloy-metrics) ─remote_write→ Grafana Cloud
kube-apiserver (:6443)                ─┤
etcd (:2381, Talos system service)    ─┘
```

Chart values: `monitoring/values.yaml`. Extra scrape targets:
`manifests/monitoring/`. The chart also deploys the Alloy operator, which owns
the `alloy-metrics` StatefulSet via an `Alloy` custom resource.

## What is monitored and why

Coverage follows OneUptime's Talos monitoring series
([overview](https://oneuptime.com/blog/post/2026-03-03-monitor-kubernetes-cluster-metrics-on-talos-linux/view),
[Prometheus on Talos](https://oneuptime.com/blog/post/2026-03-03-monitor-talos-linux-with-prometheus/view),
[etcd](https://oneuptime.com/blog/post/2026-03-03-monitor-etcd-performance-in-talos-linux/view)):

| Layer | Source | Key metrics to watch |
|---|---|---|
| **Talos machine** | node-exporter (9100) | CPU, memory pressure `1 - MemAvailable/MemTotal`, disk usage/IO, network throughput |
| **etcd** (Talos service) | etcd metrics (2381) | `etcd_disk_wal_fsync_duration_seconds` P99 < 10ms, leader changes < 3/h, DB size, failed proposals |
| **API server** | apiserver (6443) | request latency + rates, error ratio |
| **Kubelet/runtime** | kubelet + cAdvisor (10250) | container CPU/mem vs requests, throttling |
| **K8s object state** | kube-state-metrics | pod restarts `increase(kube_pod_container_status_restarts_total[1h])`, OOM kills, node readiness, deployment replica drift |

Talos itself (machined/apid) exposes no Prometheus endpoint; machine-level
health beyond node-exporter comes from `talosctl health` / `talosctl dmesg`
(spot checks), which is consistent with what the OneUptime posts recommend.

## Talos-specific plumbing this needed

1. **etcd metrics endpoint** — etcd is a Talos-managed system service, not a
   pod. Machine config patch (in `talos/patches/cluster.yaml`, also applied
   live with `talosctl -n 10.5.0.2 patch machineconfig`):
   ```yaml
   cluster:
     etcd:
       extraArgs:
         listen-metrics-urls: http://0.0.0.0:2381
   ```
   Because there's no pod, discovery uses a selector-less Service + manual
   Endpoints (`manifests/monitoring/etcd-metrics.yaml`) annotated with
   `k8s.grafana.com/scrape: "true"`, picked up by Alloy's annotation
   autodiscovery.
2. **Privileged namespace** — node-exporter needs `hostPID` and hostPath
   mounts of `/proc`,`/sys`; Talos enforces PSA `baseline` cluster-wide, so
   the `monitoring` namespace is labeled
   `pod-security.kubernetes.io/enforce: privileged` (managed by the Argo app's
   `managedNamespaceMetadata`).
3. **Control-plane node metrics** — the control plane is tainted; the
   node-exporter DaemonSet gets `tolerations: [{operator: Exists, effect:
   NoSchedule}]` so machine metrics cover it too.

## Credentials

The write credential is a Grafana Cloud access-policy token
(`metrics:write` scope only) stored in the `grafana-cloud-metrics` Secret in
the `monitoring` namespace — **never committed**. Recreate after a cluster
rebuild:

```sh
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl label ns monitoring pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl -n monitoring create secret generic grafana-cloud-metrics \
  --from-literal=username=2838151 \
  --from-literal=password='<glc_... token>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Rotate by generating a new token at grafana.com (Access Policies) and
re-running the secret command. Note: the current token was pasted in a chat
session — rotate it when convenient.

## Where to look in Grafana Cloud

- **Dashboards → Talos Homelab** (uid `talos-homelab`): custom dashboard,
  source-controlled at `grafana/dashboards/talos-homelab.json` and pushed via
  the Grafana API. Overview stats, Talos machine (CPU/memory/disk/network),
  etcd (WAL fsync p99 vs the 10ms line, proposals, DB size, leader changes),
  plus a collapsed Kubernetes row that populates when the K8s toggle is on.
  To update: edit the JSON (or regenerate) and POST it with a service-account
  token: `curl -X POST -H "Authorization: Bearer $(cat ~/.grafana-sa-token)"
  -H 'Content-Type: application/json'
  https://rahulkandru.grafana.net/api/dashboards/db
  -d "{\"dashboard\": $(cat grafana/dashboards/talos-homelab.json),
  \"overwrite\": true}"`
- **Dashboards → Kubernetes Monitoring** (Infrastructure → Kubernetes): the
  chart emits the metric/label set these built-in views expect — but only
  once the K8s metrics toggle is on. Note the cluster label is
  `talos-homelab` (the leftover Docker Desktop sender squats on `homelab`).
- **Explore** with the `grafanacloud-rahulkandru-prom` datasource; useful
  starters:
  - `up{cluster="homelab"}` — every scrape target's liveness, in one query
  - `etcd_disk_wal_fsync_duration_seconds{cluster="homelab"}` P99:
    `histogram_quantile(0.99, sum(rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) by (le))`
  - `node_memory_MemAvailable_bytes{cluster="homelab"}`
  - `increase(kube_pod_container_status_restarts_total{cluster="homelab"}[1h])`

## Issues hit during this setup & fixes

1. **etcd ignored the config patch until restarted.** `talosctl patch
   machineconfig` reported "applied without a reboot", but etcd kept running
   with its old flags, and `talosctl service etcd restart` is refused
   ("doesn't support restart operation via API"). *Fix*: `docker restart
   homelab-controlplane-1` — in Docker mode a container restart is the
   equivalent of a node reboot; etcd came back with
   `listen-metrics-urls=http://0.0.0.0:2381`.
2. **False "no metrics" scare.** The first verification curl via `kubectl run
   --rm -i` printed nothing — output-streaming raced pod deletion. Running the
   pod without `-i` and reading `kubectl logs` showed the metrics were there
   all along. Lesson: don't trust `kubectl run --rm -i` output for
   verification.
3. **Chart validation: annotation autodiscovery requires clustering.**
   `helm template` failed with "requires clustering to be enabled on the
   alloy-metrics collector". *Fix*: `collectors.alloy-metrics.presets:
   [clustered]`.
4. **Chart v4 values restructure.** `clusterMetrics.kube-state-metrics.deploy`
   / `node-exporter.deploy` (the v2/v3 layout most docs show) no longer
   deploys the exporters — v4 moved deployment control to a top-level
   `telemetryServices:` map. The chart's own validation error message pointed
   at the new location. Rendering locally with `helm template` before pushing
   caught both this and issue 3 without touching the cluster.
5. **Argo CD silently dropped the etcd Endpoints object.** The `monitoring`
   app reported Synced/Healthy, but `kubectl get endpoints etcd-metrics`
   returned NotFound — the app status showed
   `ExcludedResourceWarning: Resource /Endpoints etcd-metrics is excluded in
   the settings`. Argo CD's default `resource.exclusions` skips
   Endpoints/EndpointSlice (they're normally controller-managed churn), which
   breaks the selector-less-Service pattern for scraping node-local services.
   *Fix*: override `configs.cm."resource.exclusions"` in `argocd/values.yaml`
   with the default list minus the Endpoints block (Argo CD manages itself, so
   this was just a git commit). Lesson: Synced/Healthy does not mean every
   manifest applied — check for `ExcludedResourceWarning` conditions.
6. **node-exporter deployed but silently unscraped.** After the first sync,
   Alloy's scrape pools showed apiserver/kubelet/cAdvisor/kube-state-metrics/
   etcd — but no node-exporter, even though its DaemonSet was running. In
   chart v4, scraping node-exporter is a *separate feature* (`hostMetrics:`),
   not part of `clusterMetrics` — and enabling the feature alone renders an
   *empty* pipeline (`sources="%!s(<nil>)"` in the render); its source must
   also be turned on. *Fix*: `hostMetrics: {enabled: true, linuxHosts:
   {enabled: true}}`, verified by `helm template` showing
   `prometheus.scrape "node_exporter"` before pushing. Caught by
   checking `prometheus_target_scrape_pool_targets` on Alloy's own :12345
   metrics endpoint — worth doing after any chart change, since a missing
   scrape pool produces no error anywhere.
7. **Remote write stalled: shared active-series limit.** ~30 min after
   setup, Alloy's `highest_sent_timestamp` froze and
   `samples_retried_total` climbed while `samples_failed_total` stayed 0.
   Logs showed the cause:
   `429 ... tenant exceeded the active series limit, set to 15000`.
   The stack turned out to have **two other active senders** from an earlier
   Grafana Cloud onboarding: the k8s-monitoring chart v3.7.3 (with Kepler and
   OpenCost — both series-hungry) running in Docker Desktop's built-in
   Kubernetes (`desktop-*` nodes, also labeled `cluster="homelab"`!), and a
   brew-installed Alloy on the Mac itself pushing host metrics. *Resolution
   chosen*: keep the other senders, trim this cluster to Talos-only metrics
   (the toggle at the top of this file), and restart the Alloy pod to drop
   the WAL backlog of buffered K8s samples. Lessons: `failed=0` doesn't mean
   delivery is healthy (429s retry forever, silently); and check
   `count by (job) (up)` for *unexpected* senders before trusting a
   shared-tenant stack. Beware the `desktop-*` cluster shares the
   `cluster="homelab"` label — filter dashboards by `instance=~"homelab.*"`
   or job where it matters.
