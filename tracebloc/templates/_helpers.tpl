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

{{- define "tracebloc.registrySecretName" -}}
{{ .Release.Name }}-regcred
{{- end }}

{{/*
Image reference — defaults to docker.io when no registry is provided.
Usage: {{ include "tracebloc.image" (dict "repository" "tracebloc/jobs-manager" "tag" .Values.jobsManager.tag "registry" "docker.io") }}
*/}}
{{- define "tracebloc.image" -}}
{{ .registry | default "docker.io" }}/{{ .repository }}:{{ .tag | default "prod" }}
{{- end }}
