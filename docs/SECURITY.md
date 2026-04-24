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
- **resource-monitor** (DaemonSet) — per-node metrics collection.
- Supporting: ServiceAccount, RBAC Role/ClusterRole, PVCs, Secrets, optional NetworkPolicy, optional Namespace.

When the backend assigns an experiment to this edge, jobs-manager creates a Kubernetes `Job`. The resulting pod runs a training image (`tracebloc/client-<category>-<arch>`) that executes the uploaded user code.

The rest of this document covers how the chart and jobs-manager constrain that pod.

---

## 4. Defense layers

### 4.1 Credential isolation (G1)

Training pods do **not** carry long-lived tracebloc backend credentials. The jobs-manager is the only component authenticated to the backend; the narrow credentials a training pod needs are minted per-experiment and passed via environment variables.

The work to remove legacy `CLIENT_ID` / `CLIENT_PASSWORD` injection from training pods is in progress as a separate effort; see §8 for the residual risk until it lands.

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
- Outbound HTTPS/443 to the public internet (needed today for the training container to reach the tracebloc backend and Azure Service Bus; see §8.2)

**Configuration:** `networkPolicy.training.enabled: true` (the default).

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

All three mounts are tmpfs-backed emptyDirs and are destroyed with the pod.

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

---

## 5. Per-platform caveats

NetworkPolicy and Pod Security Admission behave differently depending on the customer's Kubernetes distribution and CNI.

### 5.1 NetworkPolicy enforcement

| Platform | Default CNI | Enforces NetworkPolicy? | Operator action |
|---|---|---|---|
| **AKS** | Azure CNI | Only with `--network-policy azure` or Calico add-on **enabled at cluster-create time** | Create the cluster with one of these options |
| **EKS** | AWS VPC CNI | **No** — VPC CNI alone does not enforce NetworkPolicy | Install Calico add-on or Cilium; or leave `networkPolicy.training.enabled: false` and accept the residual risk |
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

**Silent-no-enforcement risk:** If `networkPolicy.training.enabled: true` on a cluster whose CNI does not enforce, the policy is created but ignored. Customers must verify their CNI enforces NetworkPolicy before relying on this layer. We default the EKS `ci/eks-values.yaml` to `enabled: false` for this reason.

### 5.2 Pod Security Admission

PSA requires Kubernetes 1.25+. On older clusters the labels are inert (no warnings, no audit events). The chart does not error out on older clusters; it just loses this layer.

### 5.3 `runAsUser` and OpenShift arbitrary UIDs

The chart does **not** set `runAsUser` on training pods. Training images declare `USER 1001` in their Dockerfiles, and OpenShift's SCC assigns arbitrary UIDs at admission time. Both strategies work because the image's filesystem is group-`0`-writable (`chgrp -R 0 /app && chmod -R g=u /app`) per the Dockerfile pattern.

### 5.4 Bare-metal hostPath

When `hostPath.enabled: true`, the PVCs backing `/data/shared`, `/data/logs`, and MySQL data are rooted at `/tracebloc/<release>/*` on the node filesystem. Training pods still mount those volumes through the PVC abstraction — the read-only enforcement applies. Operators should be aware that compromising the node directly (outside of tracebloc's threat model) gives filesystem-level access to the same data.

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

---

## 7. Verification: check each layer is active

After a fresh install, the following `kubectl` checks confirm each defense layer is in place.

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

---

## 8. Residual risks

Known gaps between the current state and a fully-hardened setup, with the owner of the follow-up.

### 8.1 Global Service Bus connection strings (G7) — **backend team**

`experiments_queue_conn_str` and `flops_conn_str` returned by `/api-token-auth/` are Django settings shared across every edge in a tracebloc environment. A compromised training pod can extract them and send forged messages that the backend will attribute to any edge, potentially affecting other customers.

**Mitigation plan:** backend endpoint that mints short-TTL, entity-scoped, send-only SAS tokens per experiment. Backend team owns the design and implementation.

**Interim mitigation:** the `NetworkPolicy` in §4.2 still allows outbound HTTPS, so a training pod can reach Azure Service Bus directly. The only way to hard-block forgery before backend support lands is to deny external egress entirely — not currently possible because training pods legitimately call the backend + App Insights + Service Bus. See §8.2.

### 8.2 Training pods still have outbound HTTPS (G2) — **platform team**

The NetworkPolicy blocks in-cluster traffic and non-443 egress but must allow outbound HTTPS to let training pods function (backend API, Azure Service Bus, App Insights). A malicious pod can still `requests.post()` to an arbitrary endpoint.

**Final fix:** route all training-pod ↔ tracebloc communication through the jobs-manager sidecar, so training pods egress only to a cluster-internal IP and hold no external-facing credentials. Medium-size architectural change; not scheduled for this quarter.

### 8.3 Backend tokens never expire — **backend team**

The tracebloc backend uses Django REST Framework's `authtoken` with no TTL. A leaked token is valid forever until manually deleted from the DB.

**Mitigation plan:** backend adds a revocation endpoint + evaluates switching to `djangorestframework-simplejwt` for TTL-bound tokens. Backend team owns.

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

A malicious model can allocate memory / consume CPU up to the pod's resource limits. `resources.limits` are applied (defaults `cpu=2,memory=8Gi`). A pod running at 100% of its limits is expected behavior for training; OOMKill or eviction is the Kubernetes-native response. The chart does not attempt to detect or prevent resource-intensive pathological inputs.

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

---

## 11. Document history

- **2026-04** — Initial version. Documents the training-pod sandbox as shipped in client chart ≥ 1.0.4 and client-runtime images built from `develop` at that date. Reflects the narrow threat model (trusted platform, untrusted external data scientist submissions).

---

## 12. Questions or reports

For questions about this document, issues with a specific defense, or to report a suspected vulnerability, contact the tracebloc security team at **security@tracebloc.com**. Do not file public issues for security-relevant reports.
