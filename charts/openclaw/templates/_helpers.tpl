{{/*
charts/openclaw/templates/_helpers.tpl
*/}}

{{/*
Common labels applied to all resources.
*/}}
{{- define "openclaw.labels" -}}
app.kubernetes.io/name: openclaw
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}
