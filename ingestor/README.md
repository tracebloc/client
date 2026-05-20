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

**Image: always current, automatically.** New `ghcr.io/tracebloc/ingestor` releases roll out to your cluster via the parent `tracebloc/client` chart's auto-upgrade cronjob (`autoUpgrade.enabled: true`, default). The cronjob runs `helm repo update` + `helm upgrade tracebloc/client` daily, which writes the new digest into the `INGESTOR_IMAGE_DIGEST` env on the running `tracebloc-jobs-manager` deployment. Your next `helm install tracebloc/ingestor ...` uses the new image automatically — no digest to pin, no version to track, no redeploy of anything you've already installed.

**Chart: refresh your local cache before each install.** Helm's repo cache on _your workstation_ is independent of the cluster. The cluster's cronjob can refresh its own cache, but it cannot reach your laptop. Run `helm repo update` before each install to pick up new chart features (new values, new templates, new defaults). A stale cache still works — it just locks you out of chart-level options added since you last refreshed. **The image you run does not depend on the chart version**: jobs-manager picks the current `INGESTOR_IMAGE_DIGEST` regardless of which subchart version submitted the request.

This stratification is intentional. The image picks up bugfixes and security patches without anyone restating their dataset configs; the chart only changes when there's a real protocol or UX shift.

### What about previously-installed ingestor releases?

Nothing to upgrade. The chart is fire-and-forget: each `helm install` POSTs once to jobs-manager, the ingestor Job runs to completion, and the chart artifacts (ConfigMap + completed hook Job) become inert. There's no controller to update, no deployment to roll, no scheduled work to bump. `helm upgrade <release>` would replay the same submission as a 200 no-op (the idempotency key was stamped at install time and is preserved under `--reuse-values`).

## Required values

| Value | Description |
|---|---|
| `ingestConfig` | The full `ingest.yaml` body. **Set via `--set-file`** — the body almost always contains YAML special characters that don't survive `--set`. |

## Pinning a specific image version

The dominant install path leaves `image.digest` empty and lets jobs-manager pick the cluster's current ingestor version (set by the parent client chart's `images.ingestor.digest`, kept current by the auto-upgrade cronjob). Override only when you have a specific reason:

| Scenario | What to do |
|---|---|
| Reproducing an older ingestion run for audit / debugging | `--set image.digest=sha256:<old-digest>` |
| Testing a new ingestor release before cluster-wide rollout | `--set image.digest=sha256:<new-digest>` ahead of the auto-upgrade tick |
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
