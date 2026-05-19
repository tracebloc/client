{{- define "imagePullSecret" }}
{{- with .Values.dockerRegistry }}
{{- printf "{\"auths\":{\"%s\":{\"username\":\"%s\",\"password\":\"%s\",\"email\":\"%s\",\"auth\":\"%s\"}}}" .server .username .password .email (printf "%s:%s" .username .password | b64enc) | b64enc }}
{{- end }}
{{- end }}

{{- define "tracebloc.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{- define "tracebloc.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "tracebloc.secretName" -}}
{{ .Release.Name }}-secrets
{{- end }}

{{- define "tracebloc.serviceAccountName" -}}
{{ .Release.Name }}-jobs-manager
{{- end }}

{{/*
  Name of the shared ServiceAccount the parent chart creates for ingestor
  subchart releases. Single source of truth — used by:
    - templates/ingestor-serviceaccount.yaml (creates the SA)
    - templates/ingestion-authz-configmap.yaml (default authz entry)
  The ingestor subchart's post-install hook runs as this SA; jobs-manager
  validates its token via TokenReview against `ingestionAuthz.allowed`.
  Nil-guarded: pre-#129 stored values from `--reuse-values` upgrades won't
  have `ingestionAuthz.serviceAccountName`, so default to "ingestor".
*/}}
{{- define "tracebloc.ingestorServiceAccountName" -}}
{{- (default dict .Values.ingestionAuthz).serviceAccountName | default "ingestor" -}}
{{- end }}

{{/*
  Release-scoped name for the resource-monitor DaemonSet, ServiceAccount,
  ClusterRoleBinding subject, and selector/pod labels. Multiple releases
  on the same cluster share the tracebloc-node-agents namespace; before
  this naming, two releases collided on the literal `tracebloc-resource-monitor`
  name and Helm refused the second install with "exists, not owned".
  See the v1.2.0 release notes / hasan-prod migration case study.
*/}}
{{- define "tracebloc.resourceMonitorName" -}}
{{ .Release.Name }}-resource-monitor
{{- end }}

{{- define "tracebloc.rbacName" -}}
{{ .Release.Name }}-jobs-manager-rbac
{{- end }}

{{- define "tracebloc.clientDataPvc" -}}
client-pvc
{{- end }}

{{- define "tracebloc.clientDataPvName" -}}
{{ .Release.Name }}-data-pv
{{- end }}

{{- define "tracebloc.clientDataStorage" -}}
{{ .Values.pvc.data | default "50Gi" }}
{{- end }}

{{- define "tracebloc.clientLogsPvc" -}}
client-logs-pvc
{{- end }}

{{- define "tracebloc.clientLogsPvName" -}}
{{ .Release.Name }}-logs-pv
{{- end }}

{{- define "tracebloc.clientLogsStorage" -}}
{{ .Values.pvc.logs | default "10Gi" }}
{{- end }}

{{- define "tracebloc.mysqlPvc" -}}
mysql-pvc
{{- end }}

{{- define "tracebloc.mysqlPvName" -}}
{{ .Release.Name }}-mysql-pv
{{- end }}

{{- define "tracebloc.mysqlStorage" -}}
{{ .Values.pvc.mysql | default "2Gi" }}
{{- end }}

{{- define "tracebloc.registrySecretName" -}}
{{ .Release.Name }}-regcred
{{- end }}

{{/*
  Release-scoped name shared by the auto-upgrade CronJob, ServiceAccount,
  ClusterRoleBinding, and the ConfigMap holding the upgrade script. Kept
  in one helper so the four resources stay in lockstep — the CRB references
  the SA by name, and the CronJob mounts the ConfigMap by name.
*/}}
{{- define "tracebloc.autoUpgradeName" -}}
{{ .Release.Name }}-auto-upgrade
{{- end }}

{{/*
  StorageClass name: when storageClass.create is true, use a release-unique name
  so each release gets its own StorageClass (avoids Helm ownership conflicts).
  When create is false, use the user-provided storageClass.name for an existing class.
*/}}
{{- define "tracebloc.storageClassName" -}}
{{- if .Values.storageClass.create -}}
{{ .Release.Name }}-storage-class
{{- else -}}
{{ .Values.storageClass.name }}
{{- end -}}
{{- end -}}

{{/* Whether to create registry secret and add imagePullSecrets. Only when dockerRegistry is present and create is true; omit dockerRegistry or set create: false for public images. */}}
{{- define "tracebloc.useImagePullSecrets" -}}
{{- if and .Values.dockerRegistry (default false .Values.dockerRegistry.create) -}}
true
{{- end -}}
{{- end }}

{{/*
Image reference — defaults to docker.io when no registry is provided.
When `digest` (sha256:...) is set, renders registry/repo@digest (immutable pin,
preferred for security). Otherwise falls back to registry/repo:tag, where tag
defaults to "prod" when CLIENT_ENV is omitted or empty.
Usage: {{ include "tracebloc.image" (dict "repository" "tracebloc/jobs-manager" "tag" .Values.env.CLIENT_ENV "digest" .Values.images.jobsManager.digest "registry" "docker.io") }}
*/}}
{{- define "tracebloc.image" -}}
{{- $registry := .registry | default "docker.io" -}}
{{- $digest := .digest | default "" -}}
{{- if $digest -}}
{{ $registry }}/{{ .repository }}@{{ $digest }}
{{- else -}}
{{ $registry }}/{{ .repository }}:{{ .tag | default "prod" }}
{{- end -}}
{{- end }}
