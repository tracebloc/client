# tracebloc/ingestor Helm chart

A thin chart that submits one data-ingestion run to your tracebloc client cluster. Wraps the `POST /internal/submit-ingestion-run` endpoint on jobs-manager (client-runtime#21) so the customer-facing UX is:

```bash
helm install my-dataset tracebloc/ingestor \
  --namespace tracebloc \
  --set-file ingestConfig=./my-ingest.yaml
```

**The ingestor image is managed centrally** by the tracebloc client chart's auto-upgrade flow — you don't need to pin a digest for each install. New ingestor releases roll out automatically when the cluster's daily auto-upgrade cronjob (`autoUpgrade.enabled: true` in the client chart) bumps the chart version. See [Pinning a specific image version](#pinning-a-specific-image-version) below for the override path.

## Prerequisites

> **Install the `tracebloc/client` parent chart (1.3.4 or newer) into the
> target namespace before installing this chart.** The parent chart
> creates the `ingestor` ServiceAccount this chart's post-install hook
> runs as, and renders the `ingestionAuthz` ConfigMap that authorizes
> it. Without those preconditions the hook either has no SA to mount
> or fails authentication at jobs-manager.

The SA is shared by every `tracebloc/ingestor` release in the namespace
— that's the point. Before 0.2.0 this chart created the SA itself,
which broke as soon as a second ingestor release tried to install
([tracebloc/client#129](https://github.com/tracebloc/client/issues/129)).

## Stage your data on the shared PVC

This chart **does not transport data into the cluster.** It points at data already accessible to the cluster's shared PVC (`client-pvc` by default, mounted at `/data/shared/` inside every pod that uses it, including the ingestor Pod that jobs-manager spawns).

Before running `helm install tracebloc/ingestor`, you need your raw files (the CSV plus any images / texts / annotations / masks / sequences the category requires) under `/data/shared/<your-prefix>/` on that PVC. The `csv:`, `images:` (etc.) paths in your `ingest.yaml` are paths *inside the ingestor Pod's filesystem*, which is the PVC mount.

How to stage depends on dataset size and your environment. Two common patterns:

### Pattern 1: `kubectl cp` via a pvc-shell pod (small datasets, one-off)

Spin up a throwaway pod that mounts the PVC, copy files in, tear it down:

```yaml
# /tmp/pvc-shell.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pvc-shell
  namespace: tracebloc
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: shell
      image: alpine:3.19
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: shared
          mountPath: /data/shared
  volumes:
    - name: shared
      persistentVolumeClaim:
        claimName: client-pvc
```

```bash
kubectl apply -f /tmp/pvc-shell.yaml
kubectl -n tracebloc wait --for=condition=Ready pod/pvc-shell --timeout=60s

kubectl -n tracebloc exec pvc-shell -- \
  mkdir -p /data/shared/my-dataset/images

kubectl -n tracebloc cp ./local-images/   pvc-shell:/data/shared/my-dataset/
kubectl -n tracebloc cp ./local-labels.csv pvc-shell:/data/shared/my-dataset/labels.csv

# Verify what landed
kubectl -n tracebloc exec pvc-shell -- ls /data/shared/my-dataset/

kubectl -n tracebloc delete pod pvc-shell
```

Now `csv: /data/shared/my-dataset/labels.csv` + `images: /data/shared/my-dataset/images/` in your `ingest.yaml` will resolve.

### Pattern 2: Init container with cloud-storage sync (production / large datasets)

For datasets too large to `kubectl cp` (and any production workflow with versioned data), run a one-shot Pod whose init or main container pulls from S3 / GCS / Azure Blob into the PVC. Customers typically wire this into their CI / GitOps tool so the data syncs before the ingestion `helm install` runs. The chart itself stays out of this — it's a precondition, not a chart responsibility.

### Where the PVC name comes from

The default `client-pvc` is set by the parent client chart's PVC block (see `values.yaml#pvc`). If your install renamed it, the ingestor Pod will mount whatever the parent chart configured via `CLIENT_PVC` on jobs-manager. In the rare case of a custom name, `kubectl -n tracebloc get pvc` shows what's actually bound, and that's the value to use as `claimName:` in the pvc-shell manifest above.

## What this chart owns

| Resource | Owner | Lifecycle |
|---|---|---|
| `ConfigMap/<release>-config` (holds `ingest.yaml`) | this chart | created by `helm install`, deleted by `helm uninstall` |
| `Job/<release>-submit` (post-install hook that POSTs) | this chart | created post-install, removed before each `helm upgrade` |
| `ServiceAccount/<serviceAccount.name>` | **parent `tracebloc/client` chart** (as of 0.2.0; this chart can still create it via `serviceAccount.create: true` when targeting a pre-1.3.4 parent) | tied to the parent client release |
| `ConfigMap/ingest-config-<hash>` (per-run, mounted into the ingestor Pod) | **jobs-manager** | created by jobs-manager on accept; not managed by Helm |
| `Secret/ingest-token-<hash>` (per-run, holds `BACKEND_TOKEN`) | **jobs-manager** | same |
| `Job/ingest-job-<hash>` (the actual ingestor) | **jobs-manager** | same |
| **Ingested data** (rows in cluster-internal MySQL + metadata POSTed to the backend) | **the cluster** | persists past `helm uninstall` |

**`helm uninstall my-dataset` will not delete the running ingestor Job or any ingested data.** It removes only the config + hook artifacts above. Document this with operators so they don't expect uninstall to act as a "cancel ingestion" button.

## How the install works end-to-end

1. `helm install` renders `ConfigMap/<release>-config` containing the customer's `ingest.yaml` body.
2. Helm fires the `post-install` hook: a Job that runs as the chart's ServiceAccount.
3. The hook reads its SA token from the projected volume and the `ingest.yaml` from the ConfigMap mount.
4. The hook POSTs `{ ingest_config, idempotency_key }` (and `image_digest` if you explicitly pinned one) to `jobs-manager:8080/internal/submit-ingestion-run`.
5. **jobs-manager** validates the SA token via Kubernetes TokenReview, then checks the (SA, table) pair against the cluster's `ingestionAuthz` policy (a ConfigMap rendered by the parent `tracebloc/client` chart).
6. If authorized, jobs-manager validates the YAML against the `ingest.v1` JSON schema, resolves the image digest (the body's value if you pinned one, otherwise the cluster's configured default from `INGESTOR_IMAGE_DIGEST`), mints a backend token, creates the per-run ConfigMap + Secret + Job, records the run for idempotency, and returns `201` (or `200` if this idempotency_key has been seen before).
7. The hook treats `2xx` as success and exits 0; `helm install` reports success. Non-`2xx` exits 1 and `helm install` fails with the response body in the output.

The customer never builds an image. The customer never writes a Dockerfile. The customer writes ~8 lines of YAML.

## How updates work

The ingestor has two independent update lifecycles, and customers usually only need to think about one.

**Image: always current, automatically.** jobs-manager spawns each ingestion Job by the floating `ghcr.io/tracebloc/ingestor` tag with `imagePullPolicy: Always`, so every run resolves the current published image at spawn time. New ingestor releases under that tag are picked up on your next ingestion — no digest to pin, no version to track, and no redeploy of anything you've already installed. A cluster `helm upgrade` cannot revert the image, because there is no pinned digest to reset (the failure mode the old `INGESTOR_IMAGE_DIGEST`-pinning design had).

**Chart: refresh your local cache before each install.** Helm's repo cache on _your workstation_ is independent of the cluster. Run `helm repo update` before each install to pick up new chart features (new values, new templates, new defaults). A stale cache still works — it just locks you out of chart-level options added since you last refreshed. **The image you run does not depend on the chart version**: jobs-manager spawns the current image by floating tag regardless of which subchart version submitted the request.

This stratification is intentional. The image picks up bugfixes and security patches without anyone restating their dataset configs; the chart only changes when there's a real protocol or UX shift.

### What about previously-installed ingestor releases?

Nothing to upgrade. The chart is fire-and-forget: each `helm install` POSTs once to jobs-manager, the ingestor Job runs to completion, and the chart artifacts (ConfigMap + completed hook Job) become inert. There's no controller to update, no deployment to roll, no scheduled work to bump. `helm upgrade <release>` would replay the same submission as a 200 no-op (the idempotency key was stamped at install time and is preserved under `--reuse-values`).

## Required values

| Value | Description |
|---|---|
| `ingestConfig` | The full `ingest.yaml` body. **Set via `--set-file`** — the body almost always contains YAML special characters that don't survive `--set`. |

## Pinning a specific image version

The dominant install path leaves `image.digest` empty and lets jobs-manager spawn the cluster's current ingestor version by its floating tag (`imagePullPolicy: Always`). Override only when you have a specific reason:

| Scenario | What to do |
|---|---|
| Reproducing an older ingestion run for audit / debugging | `--set image.digest=sha256:<old-digest>` |
| Testing a new ingestor release before cluster-wide rollout | `--set image.digest=sha256:<new-digest>` |
| Air-gapped mirror with frozen versions | Use both `--set image.repository=...` and `--set image.digest=sha256:...` |

When set, the digest must be the full canonical form (`sha256:` + 64 lowercase hex chars). Tags like `v0.3.0` are rejected by jobs-manager. See the [data-ingestors releases page](https://github.com/tracebloc/data-ingestors/releases) for current digests.

## Frequently-overridden values

| Value | Default | When to override |
|---|---|---|
| `jobsManager.endpoint` | `http://jobs-manager.<release-namespace>.svc.cluster.local:8080` (auto-resolved) | The ingestor release and the parent `tracebloc/client` release live in different namespaces, or you're testing against a port-forward. |
| `serviceAccount.name` | `ingestor` | The cluster's `ingestionAuthz` policy expects a different SA name. (Default matches the parent chart's default.) |
| `image.repository` | `ghcr.io/tracebloc/ingestor` | Air-gapped mirror. |
| `idempotencyKey` | `<release>-<unix-epoch>` (regenerated every install) | You want strict at-most-once semantics across reinstalls of the same release name — pass a stable UUID so jobs-manager replays the original run instead of starting a new one. |
| `hookTimeoutSeconds` | `30` | Slow networks or large schemas. |

See `values.yaml` for the full set.

## Verifying after install

```bash
# Helm-side artifacts (this chart's footprint):
kubectl -n tracebloc get configmap,job,serviceaccount -l app.kubernetes.io/instance=my-dataset

# jobs-manager-side artifacts (the actual run):
kubectl -n tracebloc get jobs -l tracebloc.io/ingestion-run

# Watch the ingestion run progress:
kubectl -n tracebloc logs -l tracebloc.io/ingestion-run --tail=-1
```

## Uninstalling

```bash
helm uninstall my-dataset --namespace tracebloc
```

Removes the chart's ConfigMap + hook Job. The shared `ingestor` ServiceAccount is owned by the parent `tracebloc/client` release (as of 0.2.0) and stays put for other ingestor releases in the namespace. Does **not** remove the running ingestor Job, its outputs, or the metadata posted to the backend — those are owned by jobs-manager and the cluster respectively.

To cancel an in-flight run, work with jobs-manager directly:

```bash
kubectl -n tracebloc delete job -l tracebloc.io/ingestion-run=<key>
```

## Related

- [tracebloc/data-ingestors](https://github.com/tracebloc/data-ingestors) — the ingestor image and YAML schema.
- [tracebloc/client-runtime#21](https://github.com/tracebloc/client-runtime/pull/35) — the `submit-ingestion-run` endpoint this chart calls.
- [tracebloc/client](https://github.com/tracebloc/client) — the parent chart that runs jobs-manager and renders the `ingestionAuthz` policy.
