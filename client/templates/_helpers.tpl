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
  Release-scoped name shared by the image-refresh CronJob, ServiceAccount,
  Role, RoleBinding, and ConfigMap. Same lockstep reasoning as
  tracebloc.autoUpgradeName above. Distinct from auto-upgrade because the
  two CronJobs have different cadences, different RBAC scopes (image-refresh
  is namespace-scoped, auto-upgrade is cluster-admin), and customers may
  reasonably disable one but not the other.
*/}}
{{- define "tracebloc.imageRefreshName" -}}
{{ .Release.Name }}-image-refresh
{{- end }}

{{/*
  Whether the image-refresh CronJob has anything to do. When ALL THREE
  managed images (jobs-manager, pods-monitor, ingestor) are
  digest-pinned, the operator has explicitly opted into reproducible
  pinning for every image this CronJob would refresh, so we render
  nothing — no CronJob, no RBAC, no ConfigMap. When at least one is
  unpinned, the CronJob is rendered and the script skips the pinned
  images at runtime via env flags.

  Three pins because #158 added ingestor refresh on top of #154's
  jobs-manager + pods-monitor. Keep this list in sync if more images
  come under auto-refresh in future.

  Nil-guarded with `default dict` on every dereference: these are
  newer top-level keys, and a customer who runs
  `helm upgrade --reuse-values` (instead of the recommended
  --reset-then-reuse-values that autoUpgrade itself uses) could replay
  stored values from before the keys existed. Without the guard,
  `.Values.imageRefresh.enabled` would still nil-coalesce safely, but
  `.Values.images.<image>.digest` could crash if `.Values.images` were
  ever absent. Belt-and-suspenders — see the "nil-guard every new
  top-level value key" rule in CLAUDE.md.
*/}}
{{- define "tracebloc.imageRefreshEnabled" -}}
{{- $ir := default dict .Values.imageRefresh -}}
{{- $imgs := default dict .Values.images -}}
{{- $jm := default dict $imgs.jobsManager -}}
{{- $pm := default dict $imgs.podsMonitor -}}
{{- $in := default dict $imgs.ingestor -}}
{{/*
  Per-image pin signals (each one means "skip auto-refresh for this image"):
  * jobs-manager / pods-monitor: digest set (non-empty) — same signal as
    the deployment uses to switch imagePullPolicy to IfNotPresent.
  * ingestor: explicit `autoRefresh: false` flag — asymmetric because
    ingestor.digest must be non-empty for jobs-manager to work, so we
    can't use digest-presence as the signal there.
*/}}
{{- $jmPinned := $jm.digest -}}
{{- $pmPinned := $pm.digest -}}
{{/*
  Can't use `default true $in.autoRefresh` here — Go templates treat
  the bool `false` as falsy, so `default true false` returns `true`
  and flips the pin state on the explicit-disable case. Instead test
  for the literal `false` directly; absence (nil) and explicit `true`
  both fall through to "not pinned".
*/}}
{{- $inPinned := eq $in.autoRefresh false -}}
{{- if not $ir.enabled -}}
{{- else if and (and $jmPinned $pmPinned) $inPinned -}}
{{- else -}}
true
{{- end -}}
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

{{/*
tracebloc.proxyEnv — corporate-proxy env for egress-needing workloads.
Derives HTTP(S)_PROXY + an auto-augmented NO_PROXY from .Values.env.HTTP_PROXY_*
so workload pods can reach the backend / registries through a corporate proxy.
Renders nothing when HTTP_PROXY_HOST is unset (non-proxy installs unchanged).
NO_PROXY always carries the cluster-internal ranges so in-cluster + MySQL
traffic never traverses the proxy (mirrors scripts/lib/cluster.sh defaults).
Usage inside a container's env: list:
  {{- include "tracebloc.proxyEnv" . | nindent 8 }}
*/}}
{{- define "tracebloc.proxyEnv" -}}
{{- if .Values.env.HTTP_PROXY_HOST }}
{{- $host := .Values.env.HTTP_PROXY_HOST -}}
{{- $port := .Values.env.HTTP_PROXY_PORT | default "" -}}
{{- $user := .Values.env.HTTP_PROXY_USERNAME | default "" -}}
{{- $pass := .Values.env.HTTP_PROXY_PASSWORD | default "" -}}
{{- $hostport := $host -}}
{{- if $port }}{{- $hostport = printf "%s:%v" $host $port -}}{{- end -}}
{{- $cred := "" -}}
{{- if $user }}{{- $cred = printf "%s:%s@" $user $pass -}}{{- end -}}
{{- $url := printf "http://%s%s" $cred $hostport -}}
{{- $noProxy := "localhost,127.0.0.1,0.0.0.0,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.svc.cluster.local,.cluster.local,host.k3d.internal" -}}
{{- with .Values.env.NO_PROXY }}{{- $noProxy = printf "%s,%s" . $noProxy -}}{{- end }}
- name: HTTP_PROXY
  value: {{ $url | quote }}
- name: HTTPS_PROXY
  value: {{ $url | quote }}
- name: http_proxy
  value: {{ $url | quote }}
- name: https_proxy
  value: {{ $url | quote }}
- name: NO_PROXY
  value: {{ $noProxy | quote }}
- name: no_proxy
  value: {{ $noProxy | quote }}
{{- end }}
{{- end -}}
