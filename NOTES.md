# NOTES — how this cluster actually bootstraps

Written from the live cluster on 2026-07-09 (Talos v1.13.5, Kubernetes v1.36.2,
Cilium 1.19.5, Argo CD v3.4.4). All command output below is real output from
this cluster, not copied from docs.

## 1. How the cluster was bootstrapped

One command did most of the work:

```sh
talosctl cluster create docker \
  --name homelab \
  --workers 1 \
  --cpus-controlplanes 2.0 --memory-controlplanes 2.0GiB \
  --cpus-workers 2.0 --memory-workers 2.5GiB \
  --config-patch @talos/patches/cluster.yaml
```

Under the hood it performed, in order:

1. **Generated a secrets bundle** — every CA and key the cluster will ever need
   (see §2), created client-side before any node exists.
2. **Rendered machine configs** — one `controlplane` and one `worker` YAML,
   embedding those secrets plus our patch (`cni.name: none`,
   `proxy.disabled: true`).
3. **Created a Docker network** (`homelab`, 10.5.0.0/24) and started two
   containers from `ghcr.io/siderolabs/talos:v1.13.5`, injecting each machine
   config via the `USERDATA` environment variable. The control plane publishes
   two host ports: `52024→6443` (Kubernetes API) and `52025→50000` (Talos API).
4. **Bootstrapped etcd** — the equivalent of `talosctl bootstrap` against
   10.5.0.2. A Talos control-plane node deliberately does *nothing* until it
   receives this one-time call; it breaks the chicken-and-egg of "who forms
   the first etcd member" (see the `--initial-cluster-state=new` evidence in §3).
5. **Waited on health checks** and merged credentials into `~/.talos/config`
   and `~/.kube/config` (both then `chmod 600`).

Then Cilium was installed by Helm (nodes can't go Ready without a CNI), Argo CD
was installed by Helm once, and from that point `bootstrap/root-app.yaml` made
git the source of truth — Argo CD now manages Cilium, itself, the network
policies, and podinfo.

## 2. Certificate / PKI management

Talos generates **five separate PKI trust domains** at `cluster create` time.
They exist as typed resources on every node (`talosctl -n 10.5.0.2 get rd | grep secrets`):

```
apicertificates.secrets.talos.dev        osrootsecrets.secrets.talos.dev
etcdrootsecrets.secrets.talos.dev        trustdcertificates.secrets.talos.dev
etcdsecrets.secrets.talos.dev            kubernetesrootsecrets.secrets.talos.dev
kubeletsecrets.secrets.talos.dev         kubernetesdynamiccerts.secrets.talos.dev
maintenancerootsecrets.secrets.talos.dev certsans.secrets.talos.dev
```

What each root is for:

| CA / key | Signs | Used by |
|---|---|---|
| **Talos (OS) CA** | apid server + client certs | `talosctl` ↔ node mTLS; your `~/.talos/config` holds a client cert with the `os:admin` role. apid rejects any connection without a client cert — this is why exposing port 50000 is survivable. |
| **Kubernetes CA** | apiserver serving cert, kubelet client certs, admin kubeconfig | everything `kubectl` |
| **etcd CA** | etcd server + peer + apiserver-client certs | etcd requires client cert auth on both client (2379) and peer (2380) ports — see `--client-cert-auth=true` in §3 |
| **Service-account key** | JWT signatures | every pod's projected token |
| **Aggregator (front-proxy) CA** | apiserver → extension apiserver auth | API aggregation layer |

Key operational facts:

- **The roots live in the machine config** (and therefore in the secrets
  bundle). Nodes keep derived certs in memory/tmpfs — there's no `/etc/kubernetes/pki`
  to steal because there's no SSH and no shell. Derived certs (e.g. apid's
  serving cert, kubelet certs) are short-lived and re-issued automatically by
  Talos controllers; `trustd` is the service that issues certs to other nodes.
- **Rotation**: client creds are re-derived on demand — `talosctl config new`
  issues a fresh talosconfig, `talosctl kubeconfig` a fresh kubeconfig.
  Root CA rotation is `talosctl rotate-ca` (full cluster operation; not needed
  in a disposable homelab — recreate instead).
- **Never commit** the secrets bundle, talosconfig, or kubeconfig: whoever has
  the bundle *is* the cluster. Our `.gitignore` covers the patterns, and both
  local files are `chmod 600`.

## 3. Control-plane bring-up order (observed)

`talosctl -n 10.5.0.2 logs machined` shows the boot sequence phases:

```
14:53:40 initialize sequence: 2 phase(s)          # machined + config load
14:53:41 boot sequence: 8 phase(s)                # memorySizeCheck → diskSizeCheck →
14:53:41 phase startEverything (8/8): 1 tasks(s)  #   env → dbus → sharedFilesystems →
14:53:57 phase startEverything (8/8): done        #   ephemeral → userSetup → startEverything
```

and the service start order inside `startEverything`:

```
14:53:41 service[machined](Running):   Health check successful
14:53:41 service[containerd](Running): Health check successful
14:53:41 service[trustd](Running):     Started task trustd    ← cert issuer for other nodes
14:53:41 service[apid](Running):       Started task apid      ← Talos API (port 50000)
14:53:42 service[cri](Running):        Health check successful
14:53:53 service[etcd](Running):       Started task etcd      ← only after bootstrap call
14:53:55 service[kubelet](Running):    Started task kubelet
14:53:58 service[etcd](Running):       Health check successful
```

So the order is: **machined → containerd → trustd/apid → CRI → etcd (on
bootstrap) → kubelet → static pods**. Notable details:

- etcd's args (from its log) show the PKI in action and the bootstrap
  moment: `--client-cert-auth=true`, `--peer-client-cert-auth=true`,
  `--initial-cluster-state=new`, certs under `/system/secrets/etcd/`.
- The kubelet then launches the control-plane **static pods**. The apiserver
  needs etcd; the controller-manager and scheduler need the apiserver, and they
  simply crash-loop politely until it answers — visible in their restart
  counts right after bootstrap:

```
kube-apiserver-homelab-controlplane-1            1/1  Running  0
kube-controller-manager-homelab-controlplane-1   1/1  Running  3 (8m29s ago)
kube-scheduler-homelab-controlplane-1            1/1  Running  4 (8m29s ago)
```

- Talos then applies its bootstrap manifests (CoreDNS; kube-proxy and Flannel
  were *skipped* because our patch disabled them), so both nodes sat
  **NotReady** — `cluster create`'s own readiness checks report `SKIP` for
  this reason — until Cilium was installed (~90 s later both nodes went Ready).
- The worker joins by talking to trustd on the control plane using a join
  token from its machine config, gets its kubelet cert issued, and registers.

## 4. Cilium deep-dive

Why the machine-config patch:

- `cluster.network.cni.name: none` — don't install Flannel; Cilium is the CNI.
- `cluster.proxy.disabled: true` — don't run kube-proxy; Cilium's eBPF
  replacement programs Service load-balancing at the socket layer (connect-time
  address rewrite) instead of iptables DNAT chains.

The chicken-and-egg this creates: Cilium's agents need the Kubernetes API, but
without kube-proxy there's no `kubernetes.default` Service routing until Cilium
itself is up. Talos solves it with **KubePrism** — a tiny apiserver
load-balancer on every node at `localhost:7445`:

```
$ talosctl -n 10.5.0.2 get kubeprismconfig
ID: k8s-loadbalancer-config   HOST: 127.0.0.1   PORT: 7445
ENDPOINTS: [{"host":"10.5.0.2","port":6443}, {"host":"localhost","port":6443}]
```

hence `k8sServiceHost: localhost / k8sServicePort: 7445` in `cilium/values.yaml`.
The other Talos-specific values: explicit `securityContext.capabilities` lists
(Talos rejects fully-privileged agents; these are the minimum caps for eBPF map
and program management) and `cgroup.autoMount.enabled: false` with
`hostRoot: /sys/fs/cgroup` (Talos already mounts cgroup v2 there; remounting
fails on a read-only root).

Observed state (`cilium-dbg status` inside the agent):

```
KubeProxyReplacement:  True   [eth0  10.5.0.3 (Direct Routing)]
Cilium:                Ok   1.19.5
IPAM:                  IPv4: 11/254 allocated from 10.244.0.0/24
Routing:               Network: Tunnel [vxlan]   Host: Legacy
Controller Status:     58/58 healthy
Hubble:                Ok   Flows/s: 16.19
Cluster health:        2/2 reachable
```

**NetworkPolicy enforcement** — Cilium compiles policies into eBPF programs
attached to each pod's veth; identity (a numeric label-set ID) travels with
each packet, so allow/deny is an O(1) map lookup rather than iptables rule
traversal. Verified against the worked example in `manifests/network-policies/`
(default-deny ingress in `demo` + allow port 9898 from inside the namespace):

- curl from a pod **inside `demo`** → `greetings from podinfo v6.14.0` ✅
- curl from a pod **in `default`** → dropped, connection timed out ✅
  (with Flannel both would have succeeded — it ignores NetworkPolicy entirely)

**Hubble** gives per-flow visibility of exactly these verdicts:
`kubectl port-forward svc/hubble-ui -n kube-system 12000:80`.

## 5. Docker mode vs metal

What's different from Talos on real hardware:

- **No kernel boot**: the "nodes" are privileged containers sharing Docker
  Desktop's LinuxKit VM kernel (`6.12.54-linuxkit`, visible in `kubectl get
  nodes -o wide`). Cilium's eBPF programs load into that one shared kernel.
- **No install/upgrade lifecycle**: `talosctl upgrade`, `reset`, disk
  encryption, and Secure Boot don't apply — there is no disk image. Upgrading
  Talos/Kubernetes = recreate the cluster (cheap here: state is in git).
- **State location**: etcd data lives in the container filesystem, which is
  why `docker stop`/`start` (scripts/cluster-stop|start.sh) suspends and
  resumes the cluster losslessly — verified: after a stop/start cycle all
  Argo CD apps returned Synced/Healthy with no intervention.
- Everything else — machined, the API-only management model, the PKI, the
  bring-up order — is identical to metal, which is what makes this a useful
  learning environment.

## 6. Issues encountered during setup & resolutions

1. **talosctl v1.13 restructured the CLI.** The documented
   `talosctl cluster create --cpus/--memory ...` form is gone; it's now a
   `docker` subcommand with renamed flags. *Resolution*: checked
   `talosctl cluster create docker --help` and used `--cpus-controlplanes`,
   `--memory-controlplanes`, `--cpus-workers`, `--memory-workers`.
2. **Create-time readiness checks reported `SKIP` / nodes NotReady.** Expected
   consequence of `cni: none` — nothing was wrong. *Resolution*: proceed to the
   Cilium install; both nodes went Ready ~90 s after.
3. **Bare `talosctl health` prints usage and fails.** In Docker mode there's no
   discovery service, so health can't infer the member list. *Resolution*:
   pass roles explicitly — `talosctl -n 10.5.0.2 health
   --control-plane-nodes 10.5.0.2 --worker-nodes 10.5.0.3` (cluster-up.sh
   builds the worker list from `$WORKERS`).
4. **Published ports bind to 0.0.0.0, not localhost.** `docker ps` showed
   `0.0.0.0:52024->6443` — Docker Desktop's default publish address, so the
   APIs are reachable from the LAN, contradicting the localhost-only goal.
   *Mitigation*: both endpoints reject clients without a valid client cert
   (mTLS), so exposure is authenticated; to remove it entirely, set
   `"ip": "127.0.0.1"` in Docker Engine settings and recreate.
5. **`kubectl wait` aborted during cluster resume.** After `docker start`, the
   apiserver takes ~30 s to answer; `kubectl wait` exits on "connection reset"
   instead of retrying. *Resolution*: cluster-start.sh polls `kubectl get
   --raw /readyz` until the API responds, then waits for node readiness.
6. **Pod Security warnings on test pods.** Running a bare curl pod in `demo`
   produced `would violate PodSecurity "restricted:latest"` warnings — Talos
   ships a PSA config that *enforces* `baseline` and *warns* on `restricted`,
   so the pod ran but got flagged. Not an error; it's the guardrail working.
7. **kube-controller-manager/scheduler restart counts of 3–4 right after
   bootstrap.** Normal ordering behavior (§3), not a crash to investigate.
