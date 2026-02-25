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

{{- define "tracebloc.rbacName" -}}
{{ .Release.Name }}-jobs-manager-rbac
{{- end }}

{{- define "tracebloc.clientDataPvc" -}}
client-pvc
{{- end }}

{{- define "tracebloc.clientDataStorage" -}}
{{ .Values.pvc.data | default "50Gi" }}
{{- end }}

{{- define "tracebloc.clientLogsPvc" -}}
client-logs-pvc
{{- end }}

{{- define "tracebloc.clientLogsStorage" -}}
{{ .Values.pvc.logs | default "10Gi" }}
{{- end }}

{{- define "tracebloc.mysqlPvc" -}}
mysql-pvc
{{- end }}

{{- define "tracebloc.mysqlStorage" -}}
{{ .Values.pvc.mysql | default "2Gi" }}
{{- end }}

{{- define "tracebloc.registrySecretName" -}}
{{ .Release.Name }}-regcred
{{- end }}

{{/*
Image reference — defaults to docker.io when no registry is provided.
Tag defaults to "prod" when CLIENT_ENV is omitted or empty.
Usage: {{ include "tracebloc.image" (dict "repository" "tracebloc/jobs-manager" "tag" .Values.env.CLIENT_ENV "registry" "docker.io") }}
*/}}
{{- define "tracebloc.image" -}}
{{ .registry | default "docker.io" }}/{{ .repository }}:{{ .tag | default "prod" }}
{{- end }}
