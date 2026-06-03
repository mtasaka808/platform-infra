{{- define "cdm-service.fullname" -}}{{- .Release.Name }}{{- end }}
{{- define "cdm-service.labels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
{{- define "cdm-service.selectorLabels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "cdm-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}{{ .Release.Name }}{{- else }}default{{- end }}
{{- end }}
