# tracebloc Client — Security Architecture

**Audience:** security engineers, platform operators, and customers evaluating the tracebloc client for deployment in their own Kubernetes environment.

**Scope:** the defenses that protect a customer cluster against malicious code submitted by external data scientists who train models on that cluster.

## TL;DR

The tracebloc platform lets external data scientists upload **Python code, model weights, and training plans** that run inside a customer's Kubernetes cluster. Everything submitted by the data scientist is treated as **untrusted** — it executes only inside an ephemeral "training pod" that is isolated from the rest of the customer environment by multiple layers:

| Layer | What it does | Mechanism |
|---|---|---|
| Identity | Training pods carry no Kubernetes API token | `automountServiceAccountToken: false` |
| Runtime | Non-root, no privileges, no capabilities, seccomp-default | Pod + container `securityContext` |
| Filesystem | Read-only root filesystem for the 3 new-architecture training images | `readOnlyRootFilesystem: true` + scoped `emptyDir` mounts |
| Storage | Dataset volume mounted read-only | `readOnly: true` on the shared PVC mount |
| Network | Default-deny ingress + narrow egress allow-list (DNS + external HTTPS only) | Kubernetes `NetworkPolicy` |
| Admission | Namespace-level Pod Security Admission tripwire | `pod-security.kubernetes.io/warn` + `audit` labels |

Every layer is implemented at the pod spec / chart level — no change to training code is required to benefit, and there is nothing the customer must configure beyond installing the chart on a cluster whose CNI enforces NetworkPolicy.

---

## 1. Threat model

### 1.1 What we defend against

A data scientist submits a malicious Python module that is distributed to one or more customer edges for training. The submitted code:

- Has full control over the Python process inside the training pod (`os.environ`, `open()`, `socket`, `subprocess`, etc.).
- Runs on the customer's own infrastructure, with access to whatever the pod spec grants.
- Cannot be prevented with static analysis — backend-side Bandit scanning is known to be bypassable (base64-encoded payloads, dynamic imports, `__import__` at the expression level).

The attacker's goals we care about:

1. **Exfiltrate the customer's training data** over the network.
2. **Impersonate the customer's edge** to the tracebloc backend or on Azure Service Bus.
3. **Steal the customer's Azure Service Bus credentials** to forge messages affecting other customers.
4. **Pivot to other Kubernetes workloads** in the customer cluster (cluster-level escalation).
5. **Poison another experiment's** data, weights, or outputs on the same edge.
6. **Persist** across training-pod termination.

### 1.2 Trusted components

The following parts of the system are treated as trusted and are **not** in scope for these defenses:

- The tracebloc backend (`*.tracebloc.io`) and its Azure infrastructure (Service Bus, App Insights, Application Runner).
- The **jobs-manager** and **pods-monitor** containers (tracebloc/jobs-manager, tracebloc/pods-monitor).
- The **resource-monitor** DaemonSet (tracebloc/resource-monitor).
- The customer's own Kubernetes cluster, including its worker nodes and admins.
- Tracebloc engineers publishing the training base images (`tracebloc/*-cpu`, `tracebloc/*-gpu`) and the chart artifact.
- The Helm chart itself and the values the customer provides at install time.

> **Delivery integrity is verified, not assumed.** Trusting "the chart artifact"
> and "the installer scripts" means trusting the bytes that actually reach the
> box — so the `curl | bash` bootstrap pins to an immutable release tag and
> verifies every sub-script against a cosign-signed manifest before running the
> privileged steps (credential mint/write, Helm). See [§4.8](#48-installer-supply-chain-integrity-g8)
> and [docs/SUPPLY_CHAIN.md](SUPPLY_CHAIN.md). This addresses RFC-0001 R8 (the
> dominant supply-chain gap for a regulated buyer), tracked as backend#889.

### 1.3 Untrusted components

- **The Python file, weight file, and training plan submitted by an external data scientist.**
- **The training pod** that runs that submission — a Kubernetes `Job` spawned at request time by the jobs-manager.
- Any package the submitted code attempts to `import` from its image-provided environment.

### 1.4 Explicitly out of scope

- Protecting the platform against a compromised **tracebloc engineer** (insider threat at the vendor).
- Protecting the platform against a compromised **customer admin** (insider threat at the deploying organization).
- Kernel-level container-escape CVEs (see §7.6 for mitigations).
- Side-channel attacks (speculative execution, cache timing, etc.).
- Denial-of-service by resource exhaustion from legitimate-shaped training code.

---

## 2. Design goals for the training-pod sandbox

Seven explicit goals. Every defense in this document ties back to one or more of these.

| # | Goal | Status on new-architecture (use_cases/) tasks | Status on legacy tasks |
|---|---|---|---|
| G1 | No long-lived edge credentials in training-pod env | 🟡 In progress (see [§8 residual risks](#8-residual-risks)) | 🟡 In progress |
| G2 | No network egress except pre-approved in-cluster paths | ✅ Shipped — [NetworkPolicy](#42-network-egress-control) |
| G3 | No Kubernetes API access from training pods | ✅ Shipped — [SA token off](#43-kubernetes-api-access) |
| G4 | Non-root, no capabilities, seccomp, read-only rootfs | ✅ / ✅ / ✅ / ✅ | ✅ / ✅ / ✅ / ❌ (pending task-by-task migration) |
| G5 | No cross-experiment read access | 🟡 Dataset sharing is by design; access is scoped to experiments the data scientist is authorized for |
| G6 | No write access outside experiment scratch | ✅ Shipped — shared-volume is readOnly |
| G7 | No cross-tenant Service Bus forgeability | 🟡 Pending backend work |

Green = hard guarantee via chart or pod spec. Yellow = known remaining risk addressed in §8.

---

## 3. Architecture overview

The customer deploys a single Helm chart (this repo) that creates, in their cluster namespace:

- **jobs-manager** (Deployment) — long-running listener on Azure Service Bus; spawns training `Job` objects in response to backend messages.
- **pods-monitor** (sidecar in jobs-manager) — watches training pod lifecycle.
- **mysql-client** (Deployment) — local MySQL for dataset metadata.
- **resource-monitor** (DaemonSet) — per-node metrics collection. Requires `metrics-server` (polls `/apis/metrics.k8s.io/v1beta1`); the chart fails the install up front if it's missing. Disable via `resourceMonitor: false` on clusters where metrics-server cannot be installed. Note the *post*-install failure mode is silent: if metrics-server is later removed or broken, these pods keep reporting `Running` (no liveness or readiness probe) and simply stop sending heartbeats. Monitor heartbeat freshness, not pod restarts — there is no crash-loop to alert on.
- Supporting: ServiceAccount, RBAC Role/ClusterRole, PVCs, Secrets, optional NetworkPolicy, optional Namespace.

When the backend assigns an experiment to this edge, jobs-manager creates a Kubernetes `Job`. The resulting pod runs a training image (`tracebloc/client-<category>-<arch>`) that executes the uploaded user code.

The rest of this document covers how the chart and jobs-manager constrain that pod.

---

## 4. Defense layers

### 4.1 Credential isolation (G1)

Training pods do **not** carry long-lived tracebloc backend credentials. The jobs-manager is the only component authenticated to the backend; the narrow credentials a training pod needs are minted per-experiment and passed via environment variables.

The work to remove legacy `CLIENT_ID` / `CLIENT_PASSWORD` injection from training pods is in progress as a separate effort; see §8 for the residual risk until it lands.

#### 4.1.1 MySQL database identity model

The in-cluster MySQL (`mysql-client`, §3) holds two databases — `metadata` (pod tokens, Service Bus connection lookups, ingestion-run bookkeeping, per-experiment credential records) and `training_test_datasets` (the ingested dataset tables). Historically every component reached both through a single account, **`edgeuser`**, provisioned root-equivalent (`ALL PRIVILEGES ON *.* WITH GRANT OPTION`). A compromised component — or a training pod that reached MySQL — authenticating as `edgeuser` would hold the whole instance.

The target model is least-privilege, one identity per job, with `edgeuser` retired. The identities:

| Identity | Scope | Used by | Status |
|---|---|---|---|
| **per-experiment user** | `SELECT` on one experiment's physical table(s) only | training pods (injected via per-job Secret as `MYSQL_USER`/`MYSQL_PASSWORD`) | Shipped (RFC-0003 D10, backend#1181). On for `dev`/`stg`/`prod` via `perExperimentDbCredsByEnv` — baked once staging and prod DROPped edgeuser (backend#2776/#2800) |
| **`tb_credmgr`** | `CREATE USER` + `SELECT … WITH GRANT OPTION` on `training_test_datasets.*` — mints the per-experiment users, nothing else | jobs-manager | Shipped with `perExperimentDbCreds` |
| **`tb_meta`** | `ALL PRIVILEGES` on `metadata.*` only (no `*.*`, no `GRANT OPTION`) | jobs-manager + requests-proxy metadata work | **Consumed** since S2 (client-runtime#305/#308, client#664). On for `dev`/`stg`/`prod` via `serviceDbAccountsByEnv` (prod baked after backend#2800) |
| **`tb_ingest`** | `ALL PRIVILEGES` on `training_test_datasets.*` only (no `*.*`, no `GRANT OPTION`) | jobs-manager dataset work + spawned ingestion Jobs | **Consumed** since S2 (client-runtime#305/#308, client#664). On for `dev`/`stg`/`prod` via `serviceDbAccountsByEnv` (prod baked after backend#2800) |
| **`edgeuser`** | `ALL PRIVILEGES ON *.*` — root-equivalent | **existing un-migrated edges only** — a fresh install on any of `dev`/`stg`/`prod` now authenticates as `tb_meta`/`tb_ingest` | Legacy; retirement in progress (§8.10) |

The dedicated accounts are minted by jobs-manager at startup via runtime DDL (mirroring `ensure_tb_credmgr_account`), created `IDENTIFIED WITH mysql_native_password` so they survive the 5.7→8.4 datadir migration (backend#723), each reset to exactly its one-database grant on every startup. Minting is gated on `serviceDbAccounts`, which resolves **per environment** via `serviceDbAccountsByEnv` (`dev`/`stg`/`prod` on — prod baked after backend#2800) unless an operator sets the flag explicitly. It is **no longer purely additive**: S2 shipped, so wherever the flag is on the consumers authenticate as the dedicated identities.

> **Ordering constraint — read before flipping a fleet or repinning an ingestor.** An ingestor **built from data-ingestors#468 or later requires** `DB_USER`/`DB_PASSWORD` (that PR removed the `edgeuser` fallback), and jobs-manager injects them only when this flag is **on**. Such an ingestor with the flag **off** fails every ingestion Job at `Config()` before reading a byte. That is what happened to dev and staging on 2026-08-11 (backend#1752): both float on the `:dev`/`:stg` **branch** channels, which build from `develop`, so they took the change within hours — while prod was spared only because it is digest-pinned.
>
> **The requirement attaches to a BUILD, not to a version number.** #468 merged **2026-08-11**, one day *after* **v0.8.4** was cut on 08-10, so **no tagged `0.8.x` release carries it** — verified 2026-08-12 by reading `tracebloc_ingestor/config.py` at both v0.8.2 and v0.8.4, which still read `os.environ.get("DB_USER", "edgeuser")`. An earlier revision of this note said the requirement began "from version 0.8.0"; that was wrong, and taken literally it made the client#490 repin to v0.8.2 look like a prod-breaker while also contradicting the `0.8.2` ceiling stated in the next paragraph.
>
> **The ceiling, and the fact that it has already been crossed.** This is a bounded range, not an open one:
>
> | release | `DB_USER` resolution (read from `tracebloc_ingestor/config.py` at the tag) | safe with the flag OFF |
> |---|---|---|
> | `v0.8.0` – `v0.8.4` | `os.environ.get("DB_USER", "edgeuser")` | **yes** — `v0.8.4` is the ceiling |
> | `v0.8.8` and later | `self._require_env("DB_USER")` — raises | **NO** |
>
> **`v0.8.8` exists and is past the ceiling** (released 2026-08-12 16:13 UTC, `sha256:4beb85da…`), and the `channelTags.prod: "0.8"` **float now resolves to it** — verified live against ghcr, not inferred. So this is no longer a hypothetical future release: the unsafe build is what the float points at today. Prod is unaffected only because `prodDigest` pins `v0.8.2` and `prodPin` defaults to `true` (backend#1853).
>
> Read the ceiling as "safe **up to** v0.8.4", never as "recent releases are fine". And do not re-derive the boundary from a version number in this file — check whether the release you are moving to predates #468, and do not assume the newest tag is inside the range.
>
> **This table is not the watcher.** A hand-maintained version list goes stale silently and then reads as reassurance. `scripts/check-digest-drift.sh` runs on a schedule and reports whenever a float stops resolving to the pinned digest — deliberately without asserting anything about `DB_USER`, because the next thing to move will not be `DB_USER` (backend#1853).
>
> **The ingestor float-vs-pin divergence is acknowledged, not reported (backend#2673).** Because holding `prodDigest` behind the `0.8` float is intentional and open-ended, that one divergence would otherwise red the watch every night — training everyone to ignore it and masking a *new*, actionable drift on another pin behind the standing red (the backend#2386 failure mode). So `images.ingestor` carries an `ackDrift: {line, reason}` block, and the watcher treats this pin's float-vs-pin divergence as **expected**: the run is GREEN and prints `ACKNOWLEDGED` with the reason. This is **not** a blanket mute — it is scoped to this one pin, it **lapses** if `channelTags.prod` is moved off the acknowledged `line` (the boundary below is line-specific and must be re-derived), the watcher **still re-verifies every run** that the pin resolves to a healthy multi-arch index, and **any other pin drifting — or this pin ceasing to resolve — still reds.** When the boundary is resolved — a prod-safe `0.8.x` is cut, or every prod edge has actually adopted `serviceDbAccounts=true` — delete the `ackDrift` block in the same change that advances the pin. Note the chart-default flip alone does **not** resolve it: a plain `--reuse-values` upgrade replays an existing edge's stored `serviceDbAccountsByEnv.prod: false` and never injects the new default, so those edges still get no `DB_USER` and still need the v0.8.2 fallback (backend#947).
>
> **Therefore: turn this flag on for a fleet BEFORE its ingestor moves to a build containing #468, never after.** For prod that means before `images.ingestor.prodDigest` moves to such a build. client#490 pins **v0.8.2**, which is deliberately conservative rather than the boundary: the newest safe release is **v0.8.4**, and the newest release *of any kind* is v0.8.8, which is **not** safe. The invariant is checked in CI by `client-runtime/tests/test_ingestor_env_contract.py` against the contract `data-ingestors` publishes as `runtime_env.v1.json` (backend#1754).

**Staged retirement (backend#1528, RFC-0003 D10 close-out):** **S1** mint `tb_meta` + `tb_ingest` (done) → **S2** switch jobs-manager, requests-proxy, and spawned ingestion Jobs off the hardcoded `edgeuser` constants onto the injected identities, and re-parent the `tb_credmgr` bootstrap → **S3** `REVOKE` `edgeuser` to nothing and `DROP USER`, fleet-staged. `edgeuser` must retain `CREATE USER` + `GRANT OPTION` until the bootstrap is re-parented, so the revoke is deliberately last.

### 4.2 Network egress control (G2)

**Mechanism:** Kubernetes `NetworkPolicy` selected on the `tracebloc.io/workload: training` label, which the jobs-manager attaches to every spawned training pod.

**Policy:**

```yaml
spec:
  podSelector:
    matchLabels:
      tracebloc.io/workload: training
  policyTypes: [Ingress, Egress]
  ingress: []    # deny all inbound
  egress:
    - to:   # DNS only
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
          podSelector: {matchLabels: {k8s-app: kube-dns}}
      ports:
        - {port: 53, protocol: UDP}
        - {port: 53, protocol: TCP}
    - to:   # external HTTPS only; NOT in-cluster pod/service CIDRs
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]
      ports:
        - {port: 443, protocol: TCP}
```

**What this blocks:**

- Pod-to-pod traffic (can't reach jobs-manager's pod IP)
- ClusterIP services (can't reach MySQL, can't reach the Kubernetes apiserver's service IP)
- Non-443 egress (no SSH, no direct SMTP, no arbitrary ports)
- All incoming connections

**What this still allows:**

- DNS lookups (needed to resolve backend + Azure endpoints)
- In-cluster egress to MySQL (3306), the requests-proxy (8888), and the egress gateway (3128)
- Outbound HTTPS/443 to the public internet — **dropped by default as of 1.9.96 (`networkPolicy.training.allowExternalHttps: false`, deny-by-default).** Training pods reach external services only through the in-cluster egress gateway; set `allowExternalHttps: true` to opt a fleet back out (see §8.2).

**Enforcement prerequisite:** every bullet above is a *request* to the CNI, not a guarantee. It holds only on a CNI that enforces **egress** NetworkPolicy — Calico, Cilium, OpenShift OVN-Kubernetes, Azure CNI created with a network policy, or the **EKS VPC CNI managed add-on with `enableNetworkPolicy=true`**. See [§5.1](#enforcing-cnis) for the full list and the EKS caveat, and §6.2 for how to verify it on a given cluster. On a non-enforcing CNI the policy object exists and blocks nothing.

**Configuration:** `networkPolicy.training.enabled: true` (the default). Egress lockdown: `networkPolicy.training.allowExternalHttps` + `egressProxy.*` (see §8.2).

### 4.3 Kubernetes API access (G3)

Training pods set `automountServiceAccountToken: false` on the pod spec. No token is mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token`. Training code cannot introspect or authenticate to the apiserver.

The guarantee is enforced in two places — the base [`job.yaml`](../client-runtime/job.yaml) template and defensively again in the jobs-manager's `_prepare_job_config` — so the protection holds even if the template is edited.

### 4.4 Container runtime hardening (G4)

Every training pod has the following `securityContext` applied at admission time by the jobs-manager:

**Pod-level:**
```yaml
securityContext:
  runAsNonRoot: true
  seccompProfile: {type: RuntimeDefault}
```

**Container-level:**
```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities: {drop: [ALL]}
  readOnlyRootFilesystem: true    # new-architecture categories only (see below)
```

`readOnlyRootFilesystem: true` is applied only to training pods whose `category` is in the new-architecture allow-list (`tabular_classification`, `tabular_regression`, `text_classification`). Legacy categories write weight files inside the image filesystem and cannot yet accommodate a read-only rootfs; see §8.4.

When enabled, the training pod also gets three `emptyDir` mounts to host framework caches and experiment outputs:

| Mount path | Why |
|---|---|
| `/home/appuser` | HuggingFace / Transformers / Torch caches (via `HOME`, `HF_HOME`, `TRANSFORMERS_CACHE` in the Dockerfile) |
| `/tmp` | matplotlib, numpy, and other framework scratch |
| `/data/scratch` | per-experiment working directory — weights, model files, intermediate state (training code reads `EXPERIMENT_SCRATCH_PATH=/data/scratch` and roots its writes there) |

All three mounts are `emptyDir` volumes **backed by node disk** — not tmpfs — and are destroyed with the pod. Each carries a `sizeLimit` (backend#2223); before that they were unbounded, which is how an ephemeral-storage eviction came to be reported to a user as "CPU Overload" (backend#2053).

> Disk-backed is the **correct** choice and must stay that way. `medium: Memory` would charge every file written there against the pod's *memory* limit, so a resume checkpoint (RFC §X3 writes roughly 3× model size — ~3.6 GiB for BERT-large) would OOM the very run the checkpoint exists to save. This sentence previously read "tmpfs-backed", which was simply wrong about the code; if you are tempted to "fix" the code to match an older copy of this doc, don't.

### 4.5 Storage isolation (G5, G6)

**Read-only dataset mount.** The shared-volume PVC (`/data/shared`) holds dataset inputs shared across all experiments on the edge. Training pods mount it read-only:

```yaml
volumeMounts:
  - name: shared-volume
    mountPath: /data/shared
    readOnly: true
```

This prevents a malicious training pod from overwriting dataset files, planting backdoors in weight files used by other experiments, or writing executable content to shared storage.

**Writable logs PVC.** `/data/logs` is writable because training code legitimately writes per-experiment log files there. Nothing else in the threat model relies on this volume being read-only.

**Read-side isolation.** Training pods can read files under `/data/shared/<table_name>/` for the dataset they were assigned. Dataset sharing across experiments is by design — multiple experiments on the same dataset read from the same location for efficiency. The tracebloc backend controls which dataset a data scientist is authorized to see; the client-side enforcement is access (the experiment assignment itself), not on-disk separation.

### 4.6 Cross-tenant forgeability (G7)

**Still in progress.** Today the Azure Service Bus connection strings training pods use for `experiments_queue` and `flops_queue` are global settings shared across every edge in a tracebloc environment, not per-edge. A compromised training pod can extract them and post forged messages that the backend will attribute to any edge.

The planned fix is a backend-side endpoint that mints short-TTL, send-only, entity-scoped SAS tokens per experiment. Training pods receive only a scoped token that can be revoked centrally. See §8.1.

### 4.7 Admission-time tripwire (defense in depth)

Kubernetes Pod Security Admission labels the namespace so every new pod is evaluated against the `restricted` profile:

```yaml
pod-security.kubernetes.io/warn:  restricted
pod-security.kubernetes.io/audit: restricted
```

`warn` surfaces violations in `kubectl` output; `audit` writes them to the cluster audit log. These are **visibility**, not enforcement — a tripwire against accidental regressions in pod specs.

`enforce: restricted` is on by default on CSI-backed deployments (EKS/AKS/OC); bare-metal overrides it off via `ci/bm-values.yaml`. See §6.6 and §8.5.

### 4.8 Installer supply-chain integrity (G8)

**Threat.** The `curl | bash` bootstrap (`scripts/install.sh`) is the most
privileged code in the product: the sub-scripts it fetches mint the machine
credential, write it to disk, and run Helm as a cluster admin. If the bytes that
reach the box can be altered — by moving a mutable branch ref or by an on-path
attacker — none of the in-cluster defenses above matter, because the attacker
runs first, as root.

**Mechanism (RFC-0001 R8, backend#889):**

- **Immutable ref.** The bootstrap fetches every sub-script from a pinned release
  **tag** (content-addressable), never a mutable branch. A branch / non-`vX.Y.Z`
  ref is refused unless an operator sets `TRACEBLOC_ALLOW_UNVERIFIED=1` (a loud,
  developer-only escape hatch).
- **Signed manifest.** Each sub-script's sha256 is checked against a
  `manifest.sha256` published on the release. A tampered sub-script, or one
  missing from the manifest, **aborts the install before any privileged step**.
- **Authenticated + fail-closed.** The manifest is verified with a **cosign
  keyless signature** (same Sigstore chain as the CLI binary). If cosign is
  absent the bootstrap bootstraps a pinned, checksum-verified cosign; if it can
  neither find nor bootstrap cosign it **fails closed** rather than degrading to
  a same-channel checksum.

**Where implemented:** `scripts/install.sh` (verification), `scripts/gen-manifest.sh`
(manifest generation), `.github/workflows/release-helm-chart.yaml`
(`sign-installer-manifest` job: generate + sign + stamp + attach), and the CLI's
own installer for the leaf binary (`tracebloc/cli` `scripts/install.sh`, made
mandatory under the same ticket). Full model + release-pipeline + key-management
follow-ups: [docs/SUPPLY_CHAIN.md](SUPPLY_CHAIN.md).

---

## 5. Per-platform caveats

NetworkPolicy and Pod Security Admission behave differently depending on the customer's Kubernetes distribution and CNI.

### 5.1 NetworkPolicy enforcement

| Platform | Default CNI | Enforces NetworkPolicy? | Operator action |
|---|---|---|---|
| **AKS** | Azure CNI | Only with `--network-policy azure` or Calico add-on **enabled at cluster-create time** | Create the cluster with one of these options |
| **EKS** | AWS VPC CNI | **Not by default.** VPC CNI enforces only as the **managed add-on with `enableNetworkPolicy=true`** (v1.14+). A self-managed VPC CNI DaemonSet does **not** — the flag alone is insufficient without the control-plane PolicyEndpoint controller the managed add-on installs | Set `enableNetworkPolicy=true` on the `vpc-cni` managed add-on, or install Calico / Cilium; or leave `networkPolicy.training.enabled: false` and accept the residual risk |
| **Bare-metal** | depends on install | Calico / Cilium / kube-router: yes. Flannel alone: no | If Flannel-only, install a NetworkPolicy engine or disable the toggle |
| **OpenShift** | OVN-Kubernetes | Yes (default) | No action — selector defaults differ, see below |

**OpenShift DNS selector:** The CoreDNS selector must be overridden in [`ci/oc-values.yaml`](../client/ci/oc-values.yaml):

```yaml
networkPolicy:
  training:
    dnsNamespace: openshift-dns
    dnsSelector:
      dns.operator.openshift.io/daemonset-dns: default
    clusterCidrs:
      - "10.128.0.0/14"   # OpenShift default pod CIDR
      - "172.30.0.0/16"   # OpenShift default service CIDR
```

<a id="enforcing-cnis"></a>**Which CNIs enforce *egress* NetworkPolicy** — the concrete list the §4.2 and §8.2 layers require:

- **Calico** (any distribution, including the EKS add-on)
- **Cilium**
- **OpenShift OVN-Kubernetes** (default on OCP)
- **Azure CNI** with `--network-policy azure` or `calico`, set **at cluster-create time**
- **AWS VPC CNI** — **only** as the **managed EKS add-on with `enableNetworkPolicy=true`** (v1.14+). The bare DaemonSet env flag on a self-managed VPC CNI install is **not** enough: enforcement needs the control-plane PolicyEndpoint controller that the managed add-on brings. In the add-on's default `standard` mode a brand-new pod is allowed all traffic until its per-pod policy is programmed (a few-second reconcile) — real training pods start far slower than that window, and the `egress-enforcement` seal check retries across it.
- **k3s / kube-router, Antrea, Weave** — enforce, but verify per §6.2 rather than assuming.

Anything else — notably **Flannel alone** and a **self-managed AWS VPC CNI** — does not enforce.

**Silent-no-enforcement risk:** If `networkPolicy.training.enabled: true` on a cluster whose CNI does not enforce, the policy is created but ignored. Customers must verify their CNI enforces NetworkPolicy before relying on this layer. We default the EKS `ci/eks-values.yaml` to `enabled: false` for this reason.

> Verified 2026-06 on `tb-client-dev-templates` (then EKS **self-managed** VPC CNI, NetworkPolicy disabled): a DNS-only egress NetworkPolicy did **not** block `https://example.com` — the probe returned `200`. On such a fleet, flipping `allowExternalHttps=false` is **cosmetic**: the rule renders and nothing enforces it.
>
> **Updated 2026-08 — both tracebloc EKS fleets now enforce.** `tb-client-dev-templates` (dev/staging) and `tracebloc-clients-prod` (prod) have since moved to the **managed** `vpc-cni` add-on with `enableNetworkPolicy=true` (verified via `aws eks describe-addon --cluster-name <c> --addon-name vpc-cni --query addon.configurationValues` → `{"enableNetworkPolicy":"true"}`). Egress NetworkPolicy is now **enforced** on both — the "cosmetic" caveat above applied to the older self-managed CNI, not to the current state. (Standard-mode reconcile window still applies; the `egress-enforcement` seal check retries across it.)

### 5.2 Pod Security Admission

PSA requires Kubernetes 1.25+. On older clusters the labels are inert (no warnings, no audit events). The chart does not error out on older clusters; it just loses this layer.

### 5.3 `runAsUser` and OpenShift arbitrary UIDs

The chart does **not** set `runAsUser` on training pods. Training images declare `USER 1001` in their Dockerfiles, and OpenShift's SCC assigns arbitrary UIDs at admission time. Both strategies work because the image's filesystem is group-`0`-writable (`chgrp -R 0 /app && chmod -R g=u /app`) per the Dockerfile pattern.

### 5.4 Bare-metal hostPath

When `hostPath.enabled: true`, the PVCs backing `/data/shared`, `/data/logs`, and MySQL data are rooted at `/tracebloc/<release>/*` on the node filesystem. Training pods still mount those volumes through the PVC abstraction — the read-only enforcement applies. Operators should be aware that compromising the node directly (outside of tracebloc's threat model) gives filesystem-level access to the same data.

**Network-mounted datasets (backend#743).** MySQL/InnoDB must stay on a local disk — file-locking and `O_DIRECT` over NFS are unsafe — so the installer preflight fails fast when `HOST_DATA_DIR` is on a network filesystem (override: `TRACEBLOC_ALLOW_NETWORK_FS=1`). Large datasets may instead live on a customer network (NFS) mount via `HOST_DATASET_DIR`: only the dataset PV base path (`hostPath.datasetPath`, mounted at `/data/shared`) is relocated there, while mysql + logs stay on the local `/tracebloc` tree. Under NFS `root_squash` a non-admin researcher has access only as their own uid and cannot grant the fixed uid `999` access, so the installer passes the host user's uid/gid to jobs-manager, which runs spawned **ingestion** pods as that uid — dataset writes then land as the user who owns the export, with no chown and no root mapping. Training pods still mount `/data/shared` read-only and keep their arbitrary-UID posture (§5.3); only the ingestion writer is pinned to the host uid.

---

## 6. What operators must do themselves

The chart ships safe defaults, but a few things require operator attention at install or operationally.

### 6.1 Rotate secrets before trusting the install

If `clientId` / `clientPassword` are leaked after install (published to a dashboard, shared in a ticket, committed to a private config repo), rotate them on the tracebloc console and re-apply the Secret:

```bash
kubectl -n <ns> create secret generic <release>-secrets \
  --from-literal=CLIENT_ID=<new-id> \
  --from-literal=CLIENT_PASSWORD=<new-password> \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n <ns> rollout restart deployment/<release>-jobs-manager
```

Rotating replaces the credential; it does **not** remove the copies already stored in the release's retained revisions. If this install passes `clientId`/`clientPassword` as values, see §6.7 for how to stop it doing that.

### 6.2 Verify CNI enforces NetworkPolicy

Before trusting §4.2, verify the cluster's CNI actually enforces. Create a test pod with the training label and confirm a blocked destination is blocked:

```bash
kubectl -n <ns> run np-test --rm -it \
  --labels="tracebloc.io/workload=training" \
  --image=nicolaka/netshoot -- bash

# Inside the pod:
timeout 5 bash -c 'cat < /dev/tcp/mysql-client/3306' && echo FAIL || echo OK   # expect OK
timeout 5 bash -c 'cat < /dev/tcp/8.8.8.8/443'       && echo OK   || echo FAIL  # expect OK
timeout 5 bash -c 'cat < /dev/tcp/8.8.8.8/80'        && echo FAIL || echo OK   # expect OK
```

If any assertion reads the wrong way, the CNI is not enforcing — investigate before relying on §4.2.

<a id="egress-preflight-probe"></a>**Egress pre-flight probe (required gate before the §8.2 lockdown).** The check above proves the *allowed* rules behave; it does **not** prove the CNI can **block** egress, which is the whole point of the lockdown. Run this in a throwaway namespace on **every fleet** before flipping `allowExternalHttps=false`:

```bash
NS=np-preflight
kubectl create namespace "$NS"

# A DNS-only egress policy over everything in the namespace.
kubectl -n "$NS" apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: dns-only-egress
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - ports:
        - {port: 53, protocol: UDP}
        - {port: 53, protocol: TCP}
EOF

# Give the CNI a moment to program the per-pod policy (AWS VPC CNI in its
# default "standard" mode allows a new pod all traffic until it reconciles),
# then probe. -k so a cert error is not misread as a block.
kubectl -n "$NS" run probe --rm -i --restart=Never   --image=curlimages/curl:8.20.0 --   sh -c 'sleep 15; curl --noproxy "*" -k -sS -m 5 -o /dev/null -w "%{http_code}\n" https://1.1.1.1; echo "exit=$?"'

kubectl delete namespace "$NS"
```

**It MUST fail to connect** (`exit=7` connection refused or `exit=28` timeout). If it prints an HTTP code — `200`, or any TLS-layer error meaning the TCP connect succeeded — **the CNI is not enforcing egress**: fix the CNI first (§5.1), because flipping the lockdown on this fleet would be cosmetic.

Note the failure modes this probe shares with the `egress-enforcement` seal check: `exit=6` is a DNS failure (**inconclusive**, not a pass), and a connection refused against a host that simply *has nothing listening on :443* is a **false pass** — see §8.2.

### 6.3 Apply PSA labels on existing namespaces

The chart only creates a `Namespace` resource when `namespace.create: true` is explicitly set, and only on greenfield installs. If the namespace was pre-created by `kubectl create namespace` or `helm install --create-namespace`, apply the labels yourself:

```bash
# CSI-backed deployments (EKS/AKS/OC): enforce is safe.
kubectl label namespace <ns> \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/enforce=restricted

# Bare-metal (hostPath): skip enforce -- the privileged init-mysql-data
# chown container required on hostPath (kubernetes/kubernetes#138411)
# would be rejected. warn+audit still give visibility.
kubectl label namespace <ns> \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

### 6.4 Monitor audit log + kubectl warnings

If PSA is active, watch for audit events and kubectl warnings indicating a pod spec has regressed out of the restricted profile. These are signals that something has drifted — investigate promptly.

### 6.5 Pin or trust the chart version

Chart versions bundle specific Dockerfile + jobs-manager builds. Mixing an old chart with new images or vice-versa may leave hardening gaps. Prefer `helm install` from a pinned chart version and coordinate upgrades.

### 6.6 `enforce: restricted` on bare-metal

`enforce: restricted` is the chart default for CSI-backed deployments. Bare-metal installs (`hostPath.enabled: true`) cannot use enforce because the privileged `init-mysql-data` container — required because kubelet does not apply `fsGroup` to hostPath volumes ([kubernetes/kubernetes#138411](https://github.com/kubernetes/kubernetes/issues/138411)) — would be rejected. `ci/bm-values.yaml` overrides `namespace.podSecurity.enforce` to `""` accordingly. `warn` and `audit` remain on so violations are still logged.

Node-level agents (`tracebloc-resource-monitor` DaemonSet) run in a separate namespace (`tracebloc-node-agents`) at `enforce: privileged` — they legitimately need hostPath access to `/proc` / `/sys` / cgroups. The release namespace stays clean.

### 6.7 Move an existing install off values-stored credentials

`clientId` and `clientPassword` used to be `required` with no fallback, so they had to be supplied as values on **every install and every upgrade** — which means they were necessarily written into the Helm release's user-supplied values, in cleartext, in **every retained revision**. Anyone with `get secret` in the namespace could read them, and a single `helm get values` — which reads like a harmless configuration query — prints them in full.

The chart now resolves both three ways (values → the live Secret → hard failure; see the notes on `clientId` in `values.yaml`), so a credential need never enter release values. **That capability does nothing on its own: an install that already passes them keeps writing them.** This is the migration.

**1. Put the credentials in the Secret, if they are not already there.** On an install that has been running, they are — the chart wrote them. Confirm rather than assume:

```bash
kubectl -n <ns> get secret <release>-secrets \
  -o jsonpath='{.data.CLIENT_ID}' | base64 -d
```

Empty output means tier 2 has nothing to resolve from, and dropping the values would make the next upgrade **fail** rather than degrade. Create them first, using the labelled/annotated form in `values.yaml` so Helm adopts the Secret instead of colliding with it.

**2. Upgrade without the two values.** Do not pass `--reuse-values`: that would carry the old cleartext forward into the new revision, which is the thing being removed.

```bash
helm upgrade <release> tracebloc/client -n <ns> \
  -f your-values.yaml        # with clientId/clientPassword REMOVED
```

> On a fleet that has been running, this upgrade can abort with a server-side apply conflict (`conflict with "kubectl-patch" …`) if a field the chart renders was taken over out-of-band. The abort is **not** atomic — Helm stops at the first conflict and leaves whatever it already applied in place, so a failed run can still have removed the two values. See [MIGRATIONS.md § server-side apply conflict](MIGRATIONS.md#helm-upgrade-aborts-with-a-server-side-apply-conflict) for the cause and the `--server-side=true --force-conflicts` recovery.

**3. Verify the new revision is clean.** This is the check that matters, and it is one command:

```bash
helm get values <release> -n <ns> | grep -E 'clientId|clientPassword'
# no output = this revision no longer stores them
```

**4. The old revisions still hold them.** Rotation does not clear history and neither does this upgrade — every retained revision keeps the values it was installed with. Two honest options:

- **Rotate on the console** (§6.1) so the stored copies are worthless, *and* let the old revisions age out of `--history-max` (10 by default, so ten more upgrades).
- **Or reinstall** the release if you need the history gone now. `helm uninstall` deletes the revision Secrets outright; there is no supported way to rewrite one in place.

Prefer rotation. A reinstall is disruptive and the cleartext is only useful to someone who already has `get secret` in the namespace.

**A limit worth knowing before you plan around it.** Tier 2 is a `lookup`, so it needs a live cluster. It is inert under `helm template`, `--dry-run`, ArgoCD's default renderer and Flux post-render alike — and unlike the chart's other five credentials these two cannot degrade there, because the backend issues them and tier 3 is a hard failure. **A GitOps install that renders without cluster access must keep both in its values, and for it this section does not apply.** Server-side apply, or `helm upgrade` run from CI against the cluster, is what makes the value-free path reachable.

### 6.8 Bring your own registry credential

`dockerRegistry.password` has the same shape of exposure and its own escape hatch, which is easy to miss because the default path does not use it:

```yaml
dockerRegistry:
  create: false                    # do not build a Secret from values
  existingSecret: my-pull-secret   # a kubernetes.io/dockerconfigjson you own
```

With `create: true` the registry PAT is supplied as a value and lands in release values exactly like the two above. With `existingSecret` it never enters Helm at all.

Note the chart's own default is `create: false` — an install that needs no pull secret sets nothing and has no exposure here. `create: true` is an override, and it is the path any fleet pulling from a private registry takes, which is why this section exists.

Worth doing on any install whose registry credential is more than a read-only pull token: Docker Desktop mints Read/Write/**Delete** PATs with no expiry by default, so a leaked one is not merely a read of your images.

---

## 7. Verification: check each layer is active

After a fresh install, the following `kubectl` checks confirm each defense layer is in place.

The chart also ships an in-cluster conformance suite — the **seal check** — that automates the enforcement-level verifications as `helm test` hook Jobs (egress-enforcement probe, backend-reachability check, storage assertions), each labelled `tracebloc.io/seal-check` for tooling to enumerate. Run it with `helm test <release> --logs`; a guarantee that cannot be verified fails loudly (unsealed), never silently passes. See [SEAL-CHECK.md](SEAL-CHECK.md) for the contract, coverage, and runbooks (RFC-0003 §8.2–8.4 / backend#1184).

### 7.1 Training pod has the workload label

```bash
# After at least one experiment has been assigned:
kubectl -n <ns> get jobs -l app=client -o json \
  | jq '.items[].spec.template.metadata.labels."tracebloc.io/workload"'
# expected: "training" (not null)
```

### 7.2 NetworkPolicy exists and targets training pods

```bash
kubectl -n <ns> get networkpolicy <release>-training-egress -o yaml \
  | grep -A2 'podSelector'
# expected: tracebloc.io/workload: training
```

### 7.3 Training pods have no service-account token

```bash
kubectl -n <ns> get job -l app=client -o json \
  | jq '.items[].spec.template.spec.automountServiceAccountToken'
# expected: false
```

### 7.4 Training pods have the restricted securityContext

```bash
kubectl -n <ns> get job -l app=client -o json \
  | jq '.items[].spec.template.spec.securityContext'
# expected: includes runAsNonRoot:true, seccompProfile.type:"RuntimeDefault"

kubectl -n <ns> get job -l app=client -o json \
  | jq '.items[].spec.template.spec.containers[0].securityContext'
# expected: allowPrivilegeEscalation:false, capabilities.drop:["ALL"]
# expected on new-arch: readOnlyRootFilesystem:true
```

### 7.5 Shared data mount is read-only

```bash
kubectl -n <ns> get job -l app=client -o json \
  | jq '.items[].spec.template.spec.containers[0].volumeMounts[]
        | select(.name=="shared-volume")'
# expected: readOnly: true
```

### 7.6 Namespace has PSA labels

```bash
kubectl get namespace <ns> -o json \
  | jq '.metadata.labels | with_entries(select(.key | startswith("pod-security.kubernetes.io")))'
# expected: warn and audit keys set to "restricted"
```

### 7.7 No consumer resolves to the legacy shared MySQL identity

Before revoking or dropping `edgeuser` on a fleet (§8.10 step 3), run the readiness
verifier. It evaluates all three acceptance criteria against the live fleet and prints one
verdict:

```bash
docs/migration-tools/edgeuser-drop-readiness.sh \
  --context <kube-context> --namespace <ns> \
  --baseline-datasets <N> --baseline-metadata <N> --baseline-identity root \
  --phase pre-revoke
```

It is **read-only** — it performs no `REVOKE`, no `DROP`, and no writes of any kind — and it
**fails closed**: an absent pod, a refused `exec`, a log that cannot be read **or that is empty over the `--since` window** (an aged-out cycle or a restarted pod is *not* a clean one), no RUNNING ingestion pod, an ingestion `DB_USER` that is absent rather than wrong, or a baseline you did not
supply each count as a finding, never as a pass. It never prints a password value, and never
places one on a command line: the MySQL passwords it must connect with are fed to the in-pod
client over stdin, so no secret reaches `kubectl`'s argv (the operator host's `ps`, or the API
server's `exec` audit log). For every `*_PASSWORD` variable it asserts only SET or UNSET.

Three things about it are worth knowing before you trust a verdict:

- **The variable list is derived from the deployed pods' own environment**, not from a list
  written inside the script, so a credential variable added to the chart later is covered the
  day it ships.
- **The table counts are read as `tb_ingest` / `tb_meta`, not as `root`.** `information_schema`
  is privilege-filtered, so a count read as `root` is the total and can never reveal a
  shrink — root sees everything by definition. This is why `--baseline-identity` is mandatory:
  a root count and a `tb_ingest` count are different measurements.
- **The baselines have no defaults.** They are the S0 reference captured for *that* fleet, and
  the script refuses to run without them rather than compare against a number baked into it.

Re-run with `--phase post-revoke` after the revoke, and `--phase post-drop` after the drop —
the last phase additionally asserts `edgeuser` is gone from `mysql.user`.

> The criterion this replaced could not fail. A point-in-time
> `information_schema.processlist` sample showed no `edgeuser` on a fleet where `edgeuser` was
> still root-equivalent and in active use, because consumers connect per-operation and
> disconnect — it would have passed before any of the retirement work started. The script keeps
> that query only as a labelled smoke test: an empty result is recorded as *not* evidence of
> absence, while a non-empty one is a real finding.

---

## 8. Residual risks

Known gaps between the current state and a fully-hardened setup, with the owner of the follow-up.

### 8.1 Global Service Bus connection strings (G7) — **backend team**

`experiments_queue_conn_str` and `flops_conn_str` returned by `/api-token-auth/` are Django settings shared across every edge in a tracebloc environment. A compromised training pod can extract them and send forged messages that the backend will attribute to any edge, potentially affecting other customers.

**Mitigation plan:** backend endpoint that mints short-TTL, entity-scoped, send-only SAS tokens per experiment. Backend team owns the design and implementation.

**Interim mitigation:** with the §8.2 egress lockdown enabled (`networkPolicy.training.allowExternalHttps: false`), a training pod can no longer reach Azure Service Bus directly — SB traffic goes through the in-cluster requests-proxy (which holds the connection strings), and the conn-strings are no longer injected into the pod. Until a fleet enables the lockdown the NetworkPolicy still allows direct outbound HTTPS. The scoped/short-TTL SAS-token plan above remains the durable fix. See §8.2.

### 8.2 Training-pod outbound HTTPS (G2) — **deny-by-default shipped (1.9.96); per-fleet enforcement still gated**

As of chart **1.9.96** the shipped defaults are deny-by-default (`egressProxy.routeWorkloads: true` + `networkPolicy.training.allowExternalHttps: false`, RFC-0003 D6 / client-runtime#199): a new or upgraded install routes training egress through the gateway allowlist and drops the direct external-443 rule, so a malicious pod can no longer `requests.post()` to an arbitrary endpoint. **This is a config default, not a guarantee** — it only *enforces* on a CNI that enforces egress NetworkPolicy (§5.1); on a non-enforcing fleet the rule renders and blocks nothing. Existing fleets and non-enforcing CNIs still require the per-fleet gated rollout below. Charts `≥ 1.7.0` and `< 1.9.96` shipped the mechanism permissive (`routeWorkloads: false`, `allowExternalHttps: true`).

**Mechanism (chart 1.7.0, client-runtime#102):** an in-cluster **egress gateway** (`egressProxy` — a squid forward proxy) permits HTTPS CONNECT only to an FQDN allowlist (backend + App Insights) and chains to a corporate proxy via `cache_peer`. With routing on, jobs-manager injects `HTTPS_PROXY=egress-proxy-service:3128` into each training pod (and drops the raw `HTTP_PROXY_HOST`), so backend + App-Insights traffic flows through the gateway; Service Bus already goes via the requests-proxy. The pod then needs no direct internet, and the external-443 rule can be dropped.

**Rollout (per fleet, progressive — each step reversible):**

**Gate 0 — CNI enforcement pre-flight (required, before anything else).** Run the [§6.2 egress pre-flight probe](#egress-preflight-probe) on this fleet. It must fail to connect. If it returns `200`, this fleet's CNI does **not** enforce egress and steps 1–3 buy nothing: the rule renders, nothing blocks, and the fleet reads as locked down when it is not. Fix the CNI first (§5.1 — on EKS, that usually means moving to the `vpc-cni` managed add-on with `enableNetworkPolicy=true`). Do not proceed on a fleet that fails this gate.

1. Upgrade to ≥ 1.9.96 — the gateway deploys with routing **on** by default (`egressProxy.routeWorkloads: true`). (On `≥ 1.7.0` and `< 1.9.96` it deploys inert; set `routeWorkloads: true` explicitly there.)
2. Set `egressProxy.routeWorkloads: true`; verify a training run completes via the gateway.
3. **Drain first.** Wait for in-flight experiments to finish (`kubectl -n <ns> get pods -l tracebloc.io/workload=training`). Step 4 changes the policy for *running* pods too, so a training pod mid-run that still reaches the internet directly — one whose image or user code has not picked up `HTTPS_PROXY` — fails at the moment of the flip rather than at submit time. Select **pods, not Jobs**: jobs-manager sets `tracebloc.io/workload: training` on the pod template only (`job.yaml`, `jobs_manager._prepare_job_config`), never on the Job object — which is all the NetworkPolicy needs, since its `podSelector` matches the pod. `get jobs -l …` therefore returns nothing even mid-run, which reads as a false all-clear.
4. Set `networkPolicy.training.allowExternalHttps: false` to drop the external-443 rule.
5. **Verify, do not assume.** The `egress-enforcement` seal check renders exactly when the lockdown is on:

   ```bash
   helm test <release> -n <ns> --logs --filter name=<release>-egress-enforcement-check
   ```

   `OK  egress lockdown verified …` → **G2** holds on this fleet. `WARNING  EGRESS LOCKDOWN NOT ENFORCED` or `INCONCLUSIVE` → treat the fleet as **unsealed** and roll back (below). See [SEAL-CHECK.md](SEAL-CHECK.md) for the contract.
6. Run one real training experiment end to end through the gateway before declaring the fleet done.

**Rollback (any step, at any time):** set `networkPolicy.training.allowExternalHttps: true` and upgrade — the external-443 rule returns within a CNI reconcile and training pods reach the internet directly again. Nothing persists, no data migrates, and the gateway can stay deployed and routing. Use `--reset-then-reuse-values` (Helm ≥ 3.14) rather than `--reuse-values`, which would re-apply the stored `false`.

**Probe-host caveat (false pass).** Both the pre-flight probe and the `egress-enforcement` check read a refused TCP connect (curl exit 7) as "egress is blocked". A probe host that has **nothing listening on :443** refuses the same way, so it **passes without testing anything**. `enforcementProbeHost` must be a host that genuinely *accepts* TCP :443 when egress is open — the `1.1.1.1` default does. Before trusting a custom value, confirm it is reachable with the lockdown OFF; if that probe *also* fails to connect, the host is wrong, not the CNI. A DNS failure (exit 6) is reported INCONCLUSIVE and fails the check rather than passing it.

**Residual:** the pod still holds `BACKEND_TOKEN` (it authenticates to the backend through the gateway). Scoping / short-TTL of that token is tracked under §8.1.

### 8.3 Backend token lifetime (SEC-06) — **mitigated for web sessions; residual tracked (backend team)**

Previously the tracebloc backend issued Django REST Framework `authtoken` credentials with no TTL, so a leaked token was valid forever until manually deleted from the DB.

**Mitigated for interactive web sessions (backend#933 + frontend-app#575, shipped via backend#590).** Data-scientist web logins now receive a bounded, revocable **30-day `ClientAccessToken`** (Bearer). It can be revoked via `/auth/revoke`, `/logout/`, a password change, or a Django-admin action; there is no refresh token by design, so re-login simply mints a fresh token. The frontend sends a scheme-aware `Authorization: <token_scheme> <token>` header and centrally handles `401 → re-login`.

**Intentionally unchanged — edge devices and bots.** Non-interactive service credentials (edge devices, bots) deliberately keep the legacy long-lived DRF `Token`: these are machine identities with no interactive re-login path, so a bounded web-session token doesn't apply. This is by design, not an oversight.

**Residual risk (open — backend team).** The web-session token is still stored in JS-readable storage (localStorage + a non-`httpOnly` cookie), so it remains exfiltratable via XSS. Moving it out of script-reachable storage is tracked as the **SEC-06 residual follow-up** in tracebloc/backend (successor to backend#590).

### 8.4 Legacy training image architecture (G4 partial) — **legacy-migration team**

Six task types still run on the legacy `common/ping.py` architecture and write weight files inside the image at `/app/common/<experiment_id>/`. These categories cannot receive `readOnlyRootFilesystem: true` until they migrate to the `use_cases/` pattern (which honors `EXPERIMENT_SCRATCH_PATH`).

- Affected: `image_classification`, `keypoint_detection`, `object_detection`, `semantic_segmentation`, `time_series_forecasting`, `time_to_event_prediction`
- Already migrated: `tabular_classification`, `tabular_regression`, `text_classification`

Adding a migrated category to `READONLY_ROOTFS_CATEGORIES` in the jobs-manager is the only code change needed to promote it once migrated. A separate engineering team owns the migration.

### 8.5 PSA `enforce: restricted` on bare-metal — **operator**

`enforce: restricted` is the chart default for CSI-backed deployments (EKS/AKS/OC). Bare-metal installs cannot use enforce because kubelet does not apply `fsGroup` to hostPath volumes ([kubernetes/kubernetes#138411](https://github.com/kubernetes/kubernetes/issues/138411)), forcing the chart to render a privileged `init-mysql-data` chown container on the hostPath path. `ci/bm-values.yaml` overrides enforce to `""` so the install works; `warn` and `audit` remain on. If / when upstream fixes the hostPath fsGroup gap (or the chart moves to a rootless mysql image that doesn't need the chown), bare-metal can join the enforce default.

### 8.6 NetworkPolicy silent no-op on unsupported CNI — **operator**

If the customer enables the policy on a CNI that doesn't enforce (default EKS, Flannel-only bare-metal), the chart creates the resource but nothing is blocked. Customers must verify per §6.2.

### 8.7 Kernel-level container escape — **out of scope today**

`readOnlyRootFilesystem`, capability drop, and seccomp-default substantially reduce the exploitable attack surface for kernel CVEs, but a zero-day in the container runtime could still escape a training pod to the node. Defense-in-depth via user-namespace-based runtimes (gVisor, Kata Containers) is available: set `env.RUNTIME_CLASS_NAME` in your values to a RuntimeClass the customer has installed. Not enabled by default because RuntimeClass availability varies by cluster.

### 8.8 DoS via resource exhaustion — **out of scope**

A malicious model can consume resources up to whatever bound applies to each one. This section used to claim a single blanket property — *"`resources.limits` are always applied"* — which was **never true of disk** and, on client-runtime images containing #378 (backend#2418), is not true of CPU either. The honest statement is per resource, and two rows carry a version qualifier because they describe the *runtime image*, not this chart — see the note under the table:

| Resource | Bound | Enforced by |
|---|---|---|
| **Memory** | Hard limit; `requests == limits` | cgroup `memory.max` → OOMKill. **Unchanged**, and load-bearing: this is what stops one tenant consuming another's memory |
| **CPU** | **From client-runtime images containing #378 (backend#2418):** proportional share, **no ceiling**; ≥1/N under contention with N contenders. **Earlier images apply `requests == limits`** — a hard quota | cgroup `cpu.weight` on newer images, `cpu.max` on earlier ones. N is bounded by the L4.1 concurrency cap (backend#2419), not by this section |
| **Disk** | **From client-runtime images containing #380 (backend#2223):** hard limit; pod-level `ephemeral-storage` request **and** limit, plus a `sizeLimit` on each of the three scratch `emptyDir`s. **Earlier images bound it nowhere** | kubelet eviction on the pod-level limit; `sizeLimit` on each volume. Same version-qualifier reason as the CPU row: the bound is applied by `jobs_manager.py` in the runtime image, not by anything this chart renders |

**Disk is bounded now, and the row above was stale until backend#2223 closed.** It read *"not bounded at all — there is no `ephemeral-storage` request or limit anywhere, and the resource grammar cannot express one"*, which was true when written and stopped being true in three steps: `client-runtime#380` added the pod-level request/limit and a `sizeLimit` per scratch volume, `client#812` opened the resource grammar to `ephemeral-storage`, and `backend#2477` gave an eviction its own `disk` failure class so it stops being reported as CPU (the backend#2053 mislabel). Bounding disk is what makes a disk failure **attributable**: a pod now exceeds its *own* limit rather than filling the node, and the report says so.

**Why the CPU and Disk rows are version-qualified and always will be.** The chart and the runtime are versioned separately, and both rows describe behaviour owned by the client-runtime image — `node_sizing.py` for CPU, `jobs_manager.py` for disk — not by anything the chart renders. A customer on chart 1.9.66 with an older runtime image gets the hard CPU quota — and no disk bound at all — however this file reads, and upgrading the chart alone will never change either. So the qualifier is not a note about a merge window that can be deleted once client-runtime#378 and #380 land: it stays correct before that merge, after it, and on a fleet running mixed image versions, which is the only form of the sentence that is true of every deployment at once. (Same treatment, and the same reason, as the ingestor-build ordering paragraph in §4.)

Envelope provenance, for completeness: `cpu=1,memory=2Gi` by default — the contract floor, since backend#2254 (it was `cpu=2,memory=8Gi`, which exceeded a default Docker Desktop VM) — or whatever the operator pins via `env.RESOURCE_REQUESTS`/`env.RESOURCE_LIMITS` (both installers write that pair, sized to the machine at install time). Sizing from node allocatable is available but gated OFF behind `env.DERIVE_JOB_ENVELOPE` and only consulted when the pair is unset (backend#2167, backend#2250). The CPU row above describes the derive path; an operator-pinned `env.RESOURCE_LIMITS` is an explicit statement and still applies a hard CPU ceiling.

**Why dropping the CPU ceiling does not widen the threat model.** A CPU quota looks like isolation and mostly is not:

- **Memory is untouched.** The DoS vector that matters stays closed — a tenant cannot consume another's memory, OOM it, or exceed its own limit.
- **Noisy-neighbour is bounded by construction, not by trust.** Equal weights give each of N contenders ≥1/N of CPU time whatever the code does. A quota bounds the *ceiling*; a weight bounds the *floor*, which is the property a victim actually needs.
- **Eviction changes class, not exposure.** kubelet ranks memory-pressure eviction by usage *above* requests, and a pod whose memory request equals its need never exceeds it. `priority-class.yaml` already designates training pods the preemption victims, to protect mysql.
- **Deliberate CPU-burning is charged, and the alignment is exact.** The compute budget meters `CPU_FLOPS_BENCHMARK × cpu_usage × time` — burning CPU is precisely what it bills. A tenant degrading a rival spends their own allocation and gets paused when it runs out (`experiment_utils.py` refuses a start at ≥99% of allocation and accumulates atomically under `select_for_update`).

Rejected alternative, recorded: keeping `limits` at a generous fraction would have preserved the old sentence literally, but CPU quota throttles in **bursts** and multi-threaded processes suffer most — our pods run N dataloader workers plus a torch thread pool — so a ceiling reintroduces a fraction of the very problem backend#2418 exists to remove.

A pod running at 100% of its memory limit is expected behavior for training; OOMKill or eviction is the Kubernetes-native response. The chart does not attempt to detect or prevent resource-intensive pathological inputs.

### 8.9 Cosign-bootstrap trust root on boxes without cosign — **security / operator**

When cosign is not already installed, the bootstrap (§4.8) downloads a pinned
cosign from the sigstore GitHub release and verifies it against
`cosign_checksums.txt` fetched over the **same TLS channel**. This is a pragmatic
trust root — strictly better than the previous "no verification at all" — but it
is not signature-rooted (you can't verify cosign's signature without cosign). A
sufficiently capable on-path attacker who can also forge a TLS chain to GitHub
could substitute both. **Mitigation for regulated buyers:** pre-install cosign
from the OS package manager (or an internal mirror) before running the
installer, so the bootstrap uses a cosign you already trust. Documented in
[docs/SUPPLY_CHAIN.md §6](SUPPLY_CHAIN.md#6-operator-guidance--verifying-a-release-by-hand).

### 8.10 `edgeuser` MySQL root-equivalence (G1) — **security / platform, rollout in progress**

The in-cluster MySQL identity `edgeuser` is provisioned root-equivalent (`ALL PRIVILEGES ON *.* WITH GRANT OPTION`). A fresh install on any environment now authenticates the data plane as `tb_meta`/`tb_ingest` (`serviceDbAccounts` is baked on for `dev`/`stg`/`prod`), but existing un-migrated edges — and any edge upgraded with plain `--reuse-values` or carrying an operator-set `serviceDbAccountsByEnv.<env>: false` — still authenticate jobs-manager, requests-proxy, and the ingestion pods as `edgeuser` (§4.1.1). Any of those components compromised while holding `edgeuser` holds the whole MySQL instance — both the metadata DB and every customer's dataset tables.

**Mechanism (backend#1528, RFC-0003 D10 close-out):** dedicated least-privilege identities — `tb_meta` (metadata DB) and `tb_ingest` (dataset DB) — that each own exactly one database, plus the already-shipped `tb_credmgr` (mints per-experiment users) and per-experiment training-pod users. See §4.1.1 for the full model.

**Rollout (per fleet, staged, each step reversible until S3):**
1. **S1 — mint (done).** jobs-manager mints `tb_meta` + `tb_ingest` at startup under `serviceDbAccounts`.
2. **S2 — switch consumers (done; baked on for `dev`/`stg`/`prod` — prod after backend#2800; existing edges migrate on upgrade).** Move jobs-manager and requests-proxy off the hardcoded `edgeuser` constants onto `tb_meta`/`tb_ingest`; stamp `tb_ingest` onto spawned ingestion Jobs (`DB_USER`/`DB_PASSWORD`); re-parent the `tb_credmgr` bootstrap. Verify heartbeat `information_schema` dataset visibility, not just "no exceptions" — over-revoking degrades silently.
3. **S3 — retire.** With `perExperimentDbCreds` + `serviceDbAccounts` universally on and S2 shipped, `REVOKE` `edgeuser` to nothing and `DROP USER`. Prod-irreversible; gated on a `SHOW GRANTS FOR 'edgeuser'@'%'` snapshot as the rollback reference. Confirm readiness with [§7.7](#77-no-consumer-resolves-to-the-legacy-shared-mysql-identity) — `docs/migration-tools/edgeuser-drop-readiness.sh` — rather than by eye; it is the machine form of the three-criteria gate and fails closed.

**Residual until S3 completes fleet-wide:** the root-equivalent account still exists, and existing un-migrated edges (on any env) — including any upgraded with plain `--reuse-values` or pinned `serviceDbAccountsByEnv.<env>: false` — still authenticate as it. `edgeuser` intentionally retains `CREATE USER` + `GRANT OPTION` until the `tb_credmgr` bootstrap is re-parented (S2), so the revoke is deliberately the last step.

---

## 9. If you suspect compromise

If a specific training run is suspected of malicious behavior:

1. **Stop the training job** via the tracebloc console or:
   ```bash
   kubectl -n <ns> delete job <job-name>
   ```
2. **Snapshot the pod logs** before the pod is garbage-collected (default `ttlSecondsAfterFinished: 30`):
   ```bash
   kubectl -n <ns> logs --previous <pod-name> > suspect-pod.log
   ```
3. **Rotate `clientId` / `clientPassword`** if you have any reason to believe the pod exfiltrated them:
   - Change the password on the tracebloc console (backend team can invalidate the old token)
   - Update the Kubernetes Secret per §6.1
4. **Check the audit log** for PSA violations or anomalous K8s API calls (though training pods have no token, so this should be a no-op):
   ```bash
   # Depends on cluster audit policy configuration
   ```
5. **Report the model to the tracebloc security team** with the job name, experiment ID, and pod logs so the model file can be quarantined on the backend and the data scientist's submission blocked.

---

## 10. Where each defense is implemented

Cross-reference for reviewers and contributors.

| Layer | Code path |
|---|---|
| Workload label on training pod | [`client-runtime:jobs_manager._prepare_job_config`](https://github.com/tracebloc/client-runtime/blob/develop/jobs_manager.py) |
| `automountServiceAccountToken: false` | same |
| Pod + container securityContext | same |
| Shared volume `readOnly` | same |
| `readOnlyRootFilesystem` + emptyDir mounts | same (gated by `READONLY_ROOTFS_CATEGORIES`) |
| Training-pod NetworkPolicy | [`client:templates/network-policy-training.yaml`](../client/templates/network-policy-training.yaml) |
| Namespace PSA labels | [`client:templates/namespace.yaml`](../client/templates/namespace.yaml) (opt-in) |
| Experiment scratch-path env | [`tracebloc-client:core/utils/general.py`](https://github.com/tracebloc/tracebloc-client/blob/develop/core/utils/general.py) |
| Stripped Dockerfile CMD credentials | [`tracebloc-client:*.cpu.Dockerfile`, `*.gpu.Dockerfile`](https://github.com/tracebloc/tracebloc-client) |
| MySQL identity minting (`tb_credmgr` / `tb_meta` / `tb_ingest`, per-experiment users) | [`client-runtime:sql_utils.ensure_*_account`](https://github.com/tracebloc/client-runtime/blob/develop/sql_utils.py) |
| Service-account minting gate (`serviceDbAccounts`) | [`client:templates/jobs-manager-deployment.yaml`, `templates/secrets.yaml`](../client/templates/jobs-manager-deployment.yaml) |

---

## 11. Document history

- **2026-04** — Initial version. Documents the training-pod sandbox as shipped in client chart ≥ 1.0.4 and client-runtime images built from `develop` at that date. Reflects the narrow threat model (trusted platform, untrusted external data scientist submissions).
- **2026-08** — Documented the MySQL database identity model (§4.1.1) and the `edgeuser` root-equivalence retirement (§8.10) — RFC-0003 D10 close-out, backend#1528.
- **2026-08** — Flipped the shipped chart defaults to **deny-by-default egress** (`egressProxy.routeWorkloads: true` + `networkPolicy.training.allowExternalHttps: false`, chart 1.9.96) so new/upgraded installs are locked down out of the box (RFC-0003 D6 / client-runtime#199). Per-fleet enforcement still follows the §8.2 gated rollout (CNI pre-flight → verify a run → drop the rule → seal-check); non-enforcing CNIs render the rule without blocking.
- **2026-08** — Sharpened the §8.2 egress-lockdown guidance (tracebloc/client#248): named the enforcing CNIs concretely in §5.1 (including the EKS `vpc-cni` managed add-on `enableNetworkPolicy=true` prerequisite), added the §6.2 egress pre-flight probe as a required gate before the flip, and gave §8.2 a drain → flip → verify → rollback rollout with the probe-host false-pass caveat. Fleet runbook in [SEAL-CHECK.md](SEAL-CHECK.md).

---

## 12. Questions or reports

For questions about this document, issues with a specific defense, or to report a suspected vulnerability, contact the tracebloc security team at **security@tracebloc.com**. Do not file public issues for security-relevant reports.
