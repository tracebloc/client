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
Resolved idempotency key. Defaults to "<release>-<revision>" so each
helm install / upgrade submits a fresh run; explicit override is
honored verbatim.
*/ -}}
{{- define "ingestor.idempotencyKey" -}}
{{- if .Values.idempotencyKey -}}
{{ .Values.idempotencyKey }}
{{- else -}}
{{ printf "%s-%d" .Release.Name .Release.Revision }}
{{- end -}}
{{- end -}}

{{- define "ingestor.labels" -}}
app.kubernetes.io/name: ingestor
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end -}}
