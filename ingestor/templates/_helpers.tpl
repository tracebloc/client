{{- /*
Shared template helpers for the tracebloc/ingestor chart.

Naming:
  {release}-config  — ConfigMap holding the ingest.yaml the post-install
                      hook reads + POSTs.
  {release}-submit  — Job that runs the helm post-install hook (the POST).
                      Resulting ingestor Job created by jobs-manager has
                      its own name (idempotency-key-derived) and is NOT
                      managed by this chart.
*/ -}}

{{- define "ingestor.fullname" -}}
{{ .Release.Name }}
{{- end -}}

{{- define "ingestor.configMapName" -}}
{{ .Release.Name }}-config
{{- end -}}

{{- define "ingestor.hookJobName" -}}
{{ .Release.Name }}-submit
{{- end -}}

{{- define "ingestor.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{ .Values.serviceAccount.name }}
{{- else -}}
{{ .Values.serviceAccount.name | required "serviceAccount.name is required when serviceAccount.create=false" }}
{{- end -}}
{{- end -}}

{{- /*
Resolved idempotency key.

Default behavior:
  - First helm install: stamp a fresh "<release>-<unix-epoch>" key.
  - helm upgrade of the same release: REUSE the existing key by looking
    up the post-install hook ConfigMap from the previous render. This
    preserves replay semantics — jobs-manager sees the same key on
    upgrade and returns 200 (replay) rather than spawning a new run.
  - helm install after uninstall: lookup misses (ConfigMap was deleted
    on uninstall), so we fall through to a fresh now-based key. No
    collision with the previous run because the epoch differs.

Earlier versions defaulted to `now | unixEpoch` on every render. That
worked for installs but accidentally created a NEW key on
`helm upgrade --reuse-values` (Helm preserves the stored value `""`,
not the previously-rendered key, so the template re-evaluates `now`).
The result: customers running `helm upgrade` thinking it was a no-op
got duplicate ingestion runs. Bugbot caught it on PR #137. See #139.

Helm template (no cluster connection) returns empty for lookup, so
local previews always re-stamp with a fresh key — matches the
in-cluster install path the first time around.

Explicit override is honored verbatim; set `idempotencyKey` to a
stable UUID when you want strict at-most-once semantics across
uninstall/reinstall cycles.
*/ -}}
{{- define "ingestor.idempotencyKey" -}}
{{- if .Values.idempotencyKey -}}
{{ .Values.idempotencyKey }}
{{- else -}}
{{- $existing := lookup "v1" "ConfigMap" .Release.Namespace (include "ingestor.configMapName" .) -}}
{{- /* The ConfigMap key is literally "body.json" (a single key with a dot in
       its name, not a nested path), so use `index` rather than dot-access.
       The fromJson call then parses the JSON body and we read its
       idempotency_key field. Guards against missing data map (e.g. an
       in-flight create) by defaulting through `dict`. */ -}}
{{- if and $existing (hasKey ($existing.data | default dict) "body.json") -}}
{{- (fromJson (index $existing.data "body.json")).idempotency_key -}}
{{- else -}}
{{ printf "%s-%s" .Release.Name (now | unixEpoch) }}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "ingestor.labels" -}}
app.kubernetes.io/name: ingestor
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end -}}
