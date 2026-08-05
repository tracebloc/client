# Production-ready installation: tracebloc Helm chart

This guide covers installing the **tracebloc** unified Helm chart (AKS, EKS, bare-metal, OpenShift) in a production-ready way.

> **Don't have a Kubernetes cluster yet?** The standalone installer provisions a cluster, installs GPU drivers, deploys a full tracebloc client, and installs the [tracebloc CLI](https://github.com/tracebloc/cli) — in a single command:
>
> - **macOS / Linux:** `bash <(curl -fsSL https://tracebloc.io/i.sh)`
> - **Windows (PowerShell):** `irm https://tracebloc.io/i.ps1 | iex`
> - **Windows (Command Prompt):** `powershell -ExecutionPolicy Bypass -Command "irm https://tracebloc.io/i.ps1 | iex"`
> - **Windows via WSL2 (recommended — avoids Docker Desktop licensing):** Docker Desktop's commercial licence is a blocker for large hospital systems. Inside a **WSL2** Linux distro the environment *is* Linux, so tracebloc installs **rootless**, with no Docker Desktop licence. One-time Windows admin step (the Windows equivalent of the Linux "prepare-host"): in an elevated PowerShell run `wsl --install`, reboot, then **inside** your WSL2 distro run the **macOS / Linux** command above. The installer detects WSL2 and prefers rootless — it reuses Docker Desktop's WSL integration only if it's already present.
>
> **On Windows the installer needs Administrator rights.** Open an elevated shell first — press **Win+X → Terminal (Admin)** (or search "PowerShell" in Start and press **Ctrl+Shift+Enter**), accept the User Account Control prompt, then paste the command. If you run it un-elevated, the installer now **offers to relaunch itself as Administrator** (one UAC prompt) rather than failing. The Command-Prompt form above also works from `cmd.exe`, so a paste into the wrong shell still runs instead of erroring. (The **WSL2** route above avoids the Docker Desktop licence and runs rootless — no Windows Administrator needed beyond the one-time `wsl --install`.)
>
> See the [README's Quick install section](../README.md#quick-install) for what it does. Continue here if you're deploying into an existing cluster.

---

## Prerequisites

- **Kubernetes** cluster (>= 1.24)
- **kubectl** configured for the cluster
- **Helm 3.x**
- Required credentials (see [Required configuration](#required-configuration))
- A CNI that enforces NetworkPolicy if you want the training-pod egress lockdown to actually block traffic — see [SECURITY.md § Per-platform caveats](SECURITY.md#5-per-platform-caveats)

**Migrating from another chart?** Read [MIGRATIONS.md](MIGRATIONS.md) first. Skipping the pre-flight `resource-policy: keep` check can delete your PVCs during uninstall, even if you live-annotated them.

---

## Network requirements (egress allowlist)

The standalone installer runs a **preflight** check that verifies this connectivity before doing any work, and fails fast (naming the blocked host) if egress is missing. On a locked-down VM, allow outbound **HTTPS (443)** to:

| Host | Why |
|---|---|
| `registry-1.docker.io` (Docker Hub) | k3s, mysql-client, busybox + the tracebloc client images |
| `ghcr.io` | k3d node images + the ingestor image |
| `api.tracebloc.io` (`dev-api`/`stg-api` for non-prod) | client credential check + the running client's platform connection |
| `tracebloc.github.io` | the tracebloc Helm chart repository |

On **Linux**, the installer also fetches tooling from `get.docker.com`, `raw.githubusercontent.com`, `dl.k8s.io`, and `get.helm.sh` — but only when Docker / k3d / kubectl / Helm aren't already installed.

**Behind a corporate proxy?** Set `HTTP_PROXY` / `HTTPS_PROXY` before running (the installer auto-augments `NO_PROXY` with the cluster-internal ranges). On a **TLS-inspecting** (break-and-inspect) network, also point the installer at your corporate CA bundle with **`TRACEBLOC_CA_BUNDLE=/path/to/corporate-ca.pem`** (a PEM file; `CURL_CA_BUNDLE` is also honored). The installer mounts it into the k3d nodes and configures containerd to trust it, so in-cluster image pulls don't fail `x509: certificate signed by unknown authority`. Without it, the install stops with a message naming the CA and the env var — never a generic "image couldn't be pulled." Ask your IT team for the bundle if unsure.

> **Also trust the CA in the Docker daemon itself.** `TRACEBLOC_CA_BUNDLE` fixes pulls made *inside* the cluster, but k3d first pulls its **own** runtime images (`rancher/k3s`, `k3d-tools`, `k3d-proxy`) using the **host Docker daemon**, which doesn't read that variable. On a TLS-inspecting network that pull can fail `x509` during `k3d cluster create`, before any node boots — the installer detects this and points you here. Fix it once, at the daemon:
> - **Linux (native Docker)** — add the CA to your distro's system trust store, then `sudo systemctl restart docker`:
>   - Debian/Ubuntu: `sudo cp <corporate-ca>.pem /usr/local/share/ca-certificates/tracebloc-corp-ca.crt && sudo update-ca-certificates`
>   - RHEL/Fedora: `sudo cp <corporate-ca>.pem /etc/pki/ca-trust/source/anchors/tracebloc-corp-ca.crt && sudo update-ca-trust`
> - **Docker Desktop (macOS / Windows / Linux):** the daemon runs in a VM the installer can't reach. Trust the CA in the host OS store — the **macOS keychain** (set "Always Trust"), the **Windows Trusted Root** store (`certlm.msc`), or the **Linux system trust store** (the native-Docker commands above) — then restart Docker Desktop, which re-reads the host store on start. See [docs.docker.com](https://docs.docker.com/).
> - **Colima (headless macOS):** the daemon runs in a Lima VM that does **not** read the macOS keychain. Add the CA *inside* the VM — `colima ssh`, copy the PEM into the VM's system trust store and refresh it — then `colima restart`.

### Blocked container registry (mirror / air-gapped)

Some sites hard-block Docker Hub / GHCR outright — the images aren't reachable directly at all (this is different from a proxy or TLS-inspection, which the section above covers). The preflight check detects a blocked registry and points you here rather than failing with a raw pull error. Two options:

**1. A private/mirror registry your site *can* reach.** Mirror the tracebloc images into it, then point the install at the mirror by supplying a values file (`TRACEBLOC_VALUES_FILE=/path/to/mirror-values.yaml`) that overrides each image's registry:

```yaml
# mirror-values.yaml — repoint every image at your mirror (which must host the
# same tags/digests). docker.io images use images.<name>.registry; the ingestor
# carries its registry in the repository field.
images:
  jobsManager:  { registry: mirror.corp.example }
  podsMonitor:  { registry: mirror.corp.example }
  requestsProxy: { registry: mirror.corp.example }
  mysql:        { registry: mirror.corp.example }
  busybox:      { registry: mirror.corp.example }
  ingestor:     { repository: mirror.corp.example/tracebloc/ingestor }
# If the mirror needs credentials, add a pull secret:
dockerRegistry:
  create: true
  server: mirror.corp.example
  username: <user>
  password: <token>
```

**2. A fully air-gapped site (no reachable mirror).** Pre-load the images into the cluster's node(s) as an offline bundle. *(This path is being wired up — track [#585](https://github.com/tracebloc/client/issues/585).)*

> **Honest limit:** a site that blocks the registries **and** offers no reachable mirror **and** won't accept an offline bundle cannot be served — the software isn't reachable by definition. Everything short of that is handleable.

---

## 1. Add the Helm repository (recommended for production)

The chart repository is hosted at [tracebloc/client](https://github.com/tracebloc/client). After the chart is published (see [Publishing the chart](#publishing-the-chart)), add the repo and install from it so you get versioning and `helm upgrade` support.

```bash
# Add the official Tracebloc chart repository
helm repo add tracebloc https://tracebloc.github.io/client
helm repo update

# Install with a release name and namespace
helm install my-tracebloc tracebloc/client \
  --namespace tracebloc \
  --create-namespace \
  -f my-values.yaml
```

---

## 2. Install from a packaged chart (`.tgz`)

Useful for air-gapped or controlled deployments when you have the chart artifact.

```bash
# After downloading tracebloc-<version>.tgz from Releases or your artifact store
helm install my-tracebloc ./tracebloc-2.0.0.tgz \
  --namespace tracebloc \
  --create-namespace \
  -f my-values.yaml
```

---

## 3. Install from chart source (development / CI)

When working from a clone of the repo:

```bash
helm install my-tracebloc ./client \
  --namespace tracebloc \
  --create-namespace \
  -f my-values.yaml
```

---

## Required configuration

Production installs **must** override at least:

| Value | Description | Example |
|-------|-------------|---------|
| `clientId` | Tracebloc client ID | From Tracebloc console |
| `clientPassword` | Client password | From Tracebloc console |
| `dockerRegistry.server` | Registry URL | `https://index.docker.io/v1/` |
| `dockerRegistry.username` | Registry username | Your Docker Hub or registry user |
| `dockerRegistry.password` | Registry password or token | Token, not plain password in prod |
| `dockerRegistry.email` | Registry email | Optional |

Use a values file and **never** commit secrets. Prefer sealed secrets or a secret manager in production.

**Example minimal values file** (`my-values.yaml`):

```yaml
clientId: "<your-client-id>"
clientPassword: "<your-client-password>"
dockerRegistry:
  server: https://index.docker.io/v1/
  username: "<registry-username>"
  password: "<registry-token>"
  email: "<optional-email>"
```

For platform-specific settings (AKS, EKS, bare-metal, OpenShift), see `client/ci/*-values.yaml` and [MIGRATION.md](../client/MIGRATION.md).

---

## Upgrade and rollback

```bash
# Upgrade to a new chart version (repo install)
helm repo update
helm upgrade my-tracebloc tracebloc/client -n tracebloc -f my-values.yaml

# Upgrade when using a tgz
helm upgrade my-tracebloc ./tracebloc-2.0.1.tgz -n tracebloc -f my-values.yaml

# Rollback one revision
helm rollback my-tracebloc -n tracebloc
```

---

## Uninstall

```bash
helm uninstall my-tracebloc -n tracebloc
```

PVCs are annotated with `helm.sh/resource-policy: keep` and are **not** deleted by `helm uninstall`. Remove them manually if needed.

---

## Verification

```bash
# Check release status
helm status my-tracebloc -n tracebloc

# List pods
kubectl get pods -n tracebloc -l app.kubernetes.io/instance=my-tracebloc
kubectl get pods -n tracebloc -l app=manager
kubectl get pods -n tracebloc -l app=mysql-client
```

---

## Namespace Pod Security Admission labels

Training Jobs run untrusted user-supplied ML code. In addition to the per-pod `securityContext` the chart already applies, you can layer on Kubernetes [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/) labels on the release namespace for defense-in-depth.

The chart supports two paths:

### New (greenfield) install — chart creates the namespace

Set `namespace.create: true` in your values file. The chart will template a `Namespace` resource with:

- `pod-security.kubernetes.io/warn: restricted` — kubectl warnings on violations
- `pod-security.kubernetes.io/audit: restricted` — audit-log events on violations
- `helm.sh/resource-policy: keep` — `helm uninstall` leaves the namespace and its data intact

Default profile for warn/audit is `restricted`. Enforce (hard rejection) is deliberately left off — the mysql init container runs as UID 0 and would be rejected. The resource-monitor DaemonSet previously blocked enforce too (it uses `hostPath`), but now lives in its own dedicated privileged namespace (`nodeAgents.namespace.name`, default `tracebloc-node-agents`), so it no longer constrains the release namespace.

```yaml
# my-values.yaml
namespace:
  create: true
  podSecurity:
    warn: restricted
    audit: restricted
    # enforce: "" — leave off until the mysql init is refactored
```

### Node-agents namespace (resource-monitor)

The `tracebloc-resource-monitor` DaemonSet mounts `hostPath` volumes (`/proc`, `/sys`) which Pod Security Admission's `restricted` profile bans outright. The chart isolates it in a dedicated **privileged** namespace (default `tracebloc-node-agents`) so it does not constrain the restricted profile on the release namespace.

```yaml
# my-values.yaml (defaults shown)
nodeAgents:
  namespace:
    create: true                 # set false if managing the namespace out-of-band
    name: tracebloc-node-agents
```

When `create: false`, create the namespace yourself with the required PSA labels:

```bash
kubectl create namespace tracebloc-node-agents
kubectl label namespace tracebloc-node-agents \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=privileged
```

**Upgrading an existing release** (where the DaemonSet currently lives in the release namespace): Helm will delete the old DaemonSet / ServiceAccount / RoleBinding from the release namespace and recreate them in the node-agents namespace. Expect a brief gap in node metrics during the upgrade (DaemonSet rollout time; ~15s terminationGracePeriod + pod startup). The ClusterRole/ClusterRoleBinding keep the same name and are updated in place.

### Existing namespace — apply labels with kubectl

If the namespace already exists (pre-created by `kubectl create namespace` or `helm install --create-namespace`), leave `namespace.create: false` (the default) and apply the labels yourself:

```bash
kubectl label namespace tracebloc \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

---

## Publishing the chart (maintainers)

The chart repository used for installation is **[tracebloc/client](https://github.com/tracebloc/client)**. Charts are served from that repo’s GitHub Pages at `https://tracebloc.github.io/client`.

To make the chart available via `helm repo add tracebloc https://tracebloc.github.io/client`:

1. **In the tracebloc/client repo:**
   Enable **GitHub Pages** → **Settings** → **Pages** → **Source**: branch `gh-pages` (root).

2. **Create a release or push a tag**  
   - **Option A:** Create a **GitHub Release** (e.g. `v2.0.0`).  
   - **Option B:** Push a tag: `git tag tracebloc-v2.0.0 && git push origin tracebloc-v2.0.0`  
   The [Release Helm Chart](../.github/workflows/release-helm-chart.yaml) workflow runs on tags `v*` and `tracebloc-v*` and on release `published`.

3. **Workflow actions**  
   - Lints the chart  
   - Packages `tracebloc`  
   - Updates `index.yaml` on `gh-pages` (merge with existing)  
   - Pushes the new `.tgz` and index to `gh-pages`  
   - On tag push: uploads the `.tgz` to the GitHub Release

4. **First time only:** ensure the `gh-pages` branch exists. The workflow creates it if missing.

After that, users can run:

```bash
helm repo add tracebloc https://tracebloc.github.io/client
helm install my-tracebloc tracebloc/client -n tracebloc -f my-values.yaml
```

---

## Pre-install checklist (production)

- [ ] Values file prepared with real `clientId`, `clientPassword`, and `dockerRegistry` (no placeholders).
- [ ] Secrets injected via a secure mechanism (e.g. CI secrets, sealed secrets), not committed.
- [ ] Platform-specific options set (e.g. `storageClass`, `hostPath` for bare-metal, OpenShift `openshift.scc`).
- [ ] Namespace created or `--create-namespace` used.
- [ ] Resource requests/limits and storage sizes reviewed in `values.yaml` (e.g. `pvc.mysql`, `pvc.logs`, `pvc.data`).
- [ ] **MySQL storage is on a LOCAL disk.** The k3d installer's `HOST_DATA_DIR` (and the chart's mysql/logs hostPath) must be local — MySQL/InnoDB corrupts on NFS/CIFS, and the installer preflight fails fast if it is on a network filesystem. To keep large datasets on a network mount, point the installer's `HOST_DATASET_DIR` at that mount: only the dataset volume moves there; MySQL + logs stay local (backend#743).
- [ ] Lint and template checked: `helm lint ./client -f my-values.yaml` and `helm template my-tracebloc ./client -f my-values.yaml`.

---

## Next: ingest your first dataset

With the client running, the typical follow-up is to land a dataset in the cluster's local MySQL so training jobs can read it. The `tracebloc/ingestor` subchart wraps that flow — customers describe the dataset in ~8 lines of YAML and run a single `helm install`. No Dockerfile, no Python script.

The chart **does not transport data into the cluster** — it points at data already accessible on the cluster's shared PVC (`client-pvc` by default, mounted at `/data/shared/` inside the ingestor Pod). Stage your CSV + image / text / annotation files there first; the ingestor chart README documents the `kubectl cp` pattern and production sync alternatives.

### Staging on a local (hostpath) install

On a laptop install (`hostPath.enabled: true`, the default for the OS installers) `/data/shared/` is just a folder on your machine — the dataset dir is `HOST_DATA_DIR\data\<dataset>` on Windows, `$HOST_DATA_DIR/data/<dataset>` on macOS/Linux — so you stage a dataset by copying it there directly (no `kubectl cp` needed).

Use **idempotent** commands so re-running the step (for example after the installer got re-run) never errors on an already-staged dataset:

**Windows (PowerShell)** — `New-Item -Force` doesn't fail when the folder already exists, and `robocopy` merges into an existing target instead of throwing `already exists`:

```powershell
$dst = "$env:USERPROFILE\.tracebloc\data\shapes-demo"    # HOST_DATA_DIR\data\<dataset>
New-Item -ItemType Directory -Force -Path $dst | Out-Null
robocopy "$env:USERPROFILE\Downloads\sample_dataset\shapes-demo" $dst /E
# robocopy exit codes 0-7 are success (>=8 is a real error); safe to re-run.
```

> Plain `mkdir` and `Copy-Item -Recurse` are **not** idempotent — a second run throws `An item with the specified name … already exists` even though the earlier copy succeeded. That error is harmless (the data is already staged), but the commands above avoid it.

**macOS / Linux** — `mkdir -p` and `cp -R` (or `rsync -a`) are already idempotent:

```bash
dst="$HOME/.tracebloc/data/shapes-demo"                  # $HOST_DATA_DIR/data/<dataset>
mkdir -p "$dst"
cp -R ~/Downloads/sample_dataset/shapes-demo/. "$dst/"
```

Example: once you've staged a cats-vs-dogs image classification dataset under `/data/shared/cats-dogs/` on the PVC, the `ingest.yaml` describes what's there:

```yaml
# my-cats-dogs.yaml
apiVersion: tracebloc.io/v1
kind: IngestConfig
category: image_classification
table: cats_dogs_train
intent: train
csv: /data/shared/cats-dogs/labels.csv
images: /data/shared/cats-dogs/images/
label: label
```

```bash
helm install my-cats-dogs tracebloc/ingestor \
  --namespace tracebloc \
  --set-file ingestConfig=./my-cats-dogs.yaml
```

The ingestor runs once: validates the data, copies files into the destination directory on the PVC, inserts rows into MySQL, sends metadata to the tracebloc backend, then exits. Repeat per dataset.

Full ingestor documentation, including the schema for every supported category, the auto-update model that keeps the ingestor image current without per-install overrides, and verification commands → **[ingestor/README.md](../ingestor/README.md)**.

Category-specific YAML examples (image classification, object detection, tabular regression, semantic segmentation, text classification, masked language modeling, etc.) → **[tracebloc/data-ingestors templates](https://github.com/tracebloc/data-ingestors/tree/master/templates)**.
