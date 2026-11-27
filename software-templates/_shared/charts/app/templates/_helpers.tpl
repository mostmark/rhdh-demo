{{- define "app.labels" -}}
app: {{ .Values.component }}
app.kubernetes.io/name: {{ .Values.component }}
app.kubernetes.io/instance: {{ .Values.component }}-{{ .Values.environment }}
app.kubernetes.io/part-of: {{ .Values.partOf }}
app.openshift.io/runtime: {{ .Values.runtime }}
backstage.io/kubernetes-id: {{ .Values.component }}
rhdh-demo/environment: {{ .Values.environment }}
{{- end }}
