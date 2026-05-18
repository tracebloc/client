# tracebloc/ingestor Helm chart

A thin chart that submits one data-ingestion run to your tracebloc client cluster. Wraps the `POST /internal/submit-ingestion-run` endpoint on jobs-manager (client-runtime#21) so the customer-facing UX is:

```bash
helm install my-dataset tracebloc/ingestor \
  --namespace tracebloc \
  --set-file ingestConfig=./my-ingest.yaml \
  --set image.digest=sha256:<digest>
```

## What this chart owns

| Resource | Owner | Lifecycle |
|---|---|---|
| `ConfigMap/<release>-config` (holds `ingest.yaml`) | this chart | created by `helm install`, deleted by `helm uninstall` |
| `Job/<release>-submit` (post-install hook that POSTs) | this chart | created post-install, removed before each `helm upgrade` |
| `ServiceAccount/<serviceAccount.name>` | this chart (optional, default true) | created by `helm install`, deleted by `helm uninstall` |
| `ConfigMap/ingest-config-<hash>` (per-run, mounted into the ingestor Pod) | **jobs-manager** | created by jobs-manager on accept; not managed by Helm |
| `Secret/ingest-token-<hash>` (per-run, holds `BACKEND_TOKEN`) | **jobs-manager** | same |
| `Job/ingest-job-<hash>` (the actual ingestor) | **jobs-manager** | same |
| **Ingested data** (rows in cluster-internal MySQL + metadata POSTed to the backend) | **the cluster** | persists past `helm uninstall` |

**`helm uninstall my-dataset` will not delete the running ingestor Job or any ingested data.** It removes only the config + hook artifacts above. Document this with operators so they don't expect uninstall to act as a "cancel ingestion" button.

## How the install works end-to-end

1. `helm install` renders `ConfigMap/<release>-config` containing the customer's `ingest.yaml` body.
2. Helm fires the `post-install` hook: a Job that runs as the chart's ServiceAccount.
3. The hook reads its SA token from the projected volume and the `ingest.yaml` from the ConfigMap mount.
4. The hook POSTs `{ ingest_config, idempotency_key, image_digest }` to `jobs-manager:8080/internal/submit-ingestion-run`.
5. **jobs-manager** validates the SA token via Kubernetes TokenReview, then checks the (SA, table) pair against the cluster's `ingestionAuthz` policy (a ConfigMap rendered by the parent `tracebloc/client` chart).
6. If authorized, jobs-manager validates the YAML against the `ingest.v1` JSON schema, mints a backend token, creates the per-run ConfigMap + Secret + Job, records the run for idempotency, and returns `201` (or `200` if this idempotency_key has been seen before).
7. The hook treats `2xx` as success and exits 0; `helm install` reports success. Non-`2xx` exits 1 and `helm install` fails with the response body in the output.

The customer never builds an image. The customer never writes a Dockerfile. The customer writes ~8 lines of YAML.

## Required values

| Value | Description |
|---|---|
| `ingestConfig` | The full `ingest.yaml` body. **Set via `--set-file`** — the body almost always contains YAML special characters that don't survive `--set`. |
| `image.digest` | A `sha256:<64-hex>` digest of a `ghcr.io/tracebloc/ingestor` release. Tags are rejected by jobs-manager. See the [data-ingestors releases page](https://github.com/tracebloc/data-ingestors/releases) for current digests. |

## Frequently-overridden values

| Value | Default | When to override |
|---|---|---|
| `jobsManager.endpoint` | `http://jobs-manager.tracebloc.svc.cluster.local:8080` | The parent `tracebloc/client` release isn't in the `tracebloc` namespace, or you're testing against a port-forward. |
| `serviceAccount.name` | `ingestor` | The cluster's `ingestionAuthz` policy expects a different SA name. (Default matches the parent chart's default.) |
| `image.repository` | `ghcr.io/tracebloc/ingestor` | Air-gapped mirror. |
| `idempotencyKey` | `<release>-<revision>` | You want strict at-most-once semantics across re-installs under the same release name. |
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

Removes the chart's ConfigMap + hook Job + ServiceAccount. Does **not** remove the running ingestor Job, its outputs, or the metadata posted to the backend — those are owned by jobs-manager and the cluster respectively.

To cancel an in-flight run, work with jobs-manager directly:

```bash
kubectl -n tracebloc delete job -l tracebloc.io/ingestion-run=<key>
```

## Related

- [tracebloc/data-ingestors](https://github.com/tracebloc/data-ingestors) — the ingestor image and YAML schema.
- [tracebloc/client-runtime#21](https://github.com/tracebloc/client-runtime/pull/35) — the `submit-ingestion-run` endpoint this chart calls.
- [tracebloc/client](https://github.com/tracebloc/client) — the parent chart that runs jobs-manager and renders the `ingestionAuthz` policy.
