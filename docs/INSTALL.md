# Production-ready installation: tracebloc Helm chart

This guide covers installing the **tracebloc** unified Helm chart (AKS, EKS, bare-metal, OpenShift) in a production-ready way.

---

## Prerequisites

- **Kubernetes** cluster (>= 1.24)
- **kubectl** configured for the cluster
- **Helm 3.x**
- Required credentials (see [Required configuration](#required-configuration))

---

## 1. Add the Helm repository (recommended for production)

The chart repository is hosted at [tracebloc/client](https://github.com/tracebloc/client). After the chart is published (see [Publishing the chart](#publishing-the-chart)), add the repo and install from it so you get versioning and `helm upgrade` support.

```bash
# Add the official Tracebloc chart repository
helm repo add tracebloc https://tracebloc.github.io/client
helm repo update

# Install with a release name and namespace
helm install my-tracebloc tracebloc/tracebloc \
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
helm upgrade my-tracebloc tracebloc/tracebloc -n tracebloc -f my-values.yaml

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

## Publishing the chart (maintainers)

The chart repository used for installation is **[tracebloc/client](https://github.com/tracebloc/client)**. Charts are served from that repo’s GitHub Pages at `https://tracebloc.github.io/client`.

To make the chart available via `helm repo add tracebloc https://tracebloc.github.io/client`:

1. **In the repo that hosts the chart (e.g. tracebloc/client or tracebloc-helm-charts):**  
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

5. **If you develop in a different repo** (e.g. tracebloc-helm-charts): run the release workflow there to build the chart, then copy the generated `tracebloc-<version>.tgz` and updated `index.yaml` into the **tracebloc/client** repo’s `gh-pages` branch so the chart is served at `https://tracebloc.github.io/client`.

After that, users can run:

```bash
helm repo add tracebloc https://tracebloc.github.io/client
helm install my-tracebloc tracebloc/tracebloc -n tracebloc -f my-values.yaml
```

**Note:** If the chart is developed in a different repo (e.g. `tracebloc-helm-charts`), run the release workflow there to produce the `.tgz` and `index.yaml`, then copy the packaged chart and updated index into the `tracebloc/client` repo’s `gh-pages` branch (or run the same release workflow from the client repo) so the chart is served at `https://tracebloc.github.io/client`.

---

## Pre-install checklist (production)

- [ ] Values file prepared with real `clientId`, `clientPassword`, and `dockerRegistry` (no placeholders).
- [ ] Secrets injected via a secure mechanism (e.g. CI secrets, sealed secrets), not committed.
- [ ] Platform-specific options set (e.g. `storageClass`, `hostPath` for bare-metal, OpenShift `openshift.scc`).
- [ ] Namespace created or `--create-namespace` used.
- [ ] Resource requests/limits and storage sizes reviewed in `values.yaml` (e.g. `pvc.mysql`, `pvc.logs`, `pvc.data`).
- [ ] Lint and template checked: `helm lint ./client -f my-values.yaml` and `helm template my-tracebloc ./client -f my-values.yaml`.
