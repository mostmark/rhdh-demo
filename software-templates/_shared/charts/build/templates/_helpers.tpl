{{/* Shell functions for the pipeline scripts: exists <tag>, copy <from> <to>, restart <ns> */}}
{{- define "build.functions" -}}
set -eu
{{- if eq .Values.registry "quay" }}
AUTH=".docker/config.json"
exists() { oc image info -a "$AUTH" "{{ .Values.image.repository }}:$1" >/dev/null 2>&1; }
copy() {
  oc image mirror -a "$AUTH" --keep-manifest-list=true "{{ .Values.image.repository }}:$1" "{{ .Values.image.repository }}:$2" >/dev/null
  echo "image {{ .Values.image.repository }}:$2 <- :$1"
}
{{- else }}
exists() { oc get istag "{{ .Values.image.stream }}:$1" >/dev/null 2>&1; }
copy() { oc tag "{{ .Values.image.stream }}:$1" "{{ .Values.image.stream }}:$2" >/dev/null; echo "image {{ .Values.image.stream }}:$2 <- :$1"; }
{{- end }}
restart() {
  if ! oc get deployment/{{ .Values.deployment }} -n "$1" >/dev/null 2>&1; then
    echo "$1: no Deployment yet; Argo CD creates it with the new image"; return
  fi
  if [ "$(oc get deployment/{{ .Values.deployment }} -n "$1" -o jsonpath='{.spec.replicas}')" = 0 ]; then
    oc patch deployment/{{ .Values.deployment }} -n "$1" --type merge -p '{"spec":{"replicas":1}}' >/dev/null
    echo "$1: first promotion, scaled up"
  else
    oc rollout restart deployment/{{ .Values.deployment }} -n "$1"
  fi
  oc rollout status deployment/{{ .Values.deployment }} -n "$1" --timeout=5m
}
{{- end }}

{{/* Task that writes the Quay robot's docker config to <source>/.docker/config.json */}}
{{- define "build.quayAuthTask" -}}
- name: registry-auth
  taskRef:
    resolver: cluster
    params:
      - {name: kind, value: task}
      - {name: name, value: openshift-client}
      - {name: namespace, value: openshift-pipelines}
  params:
    - name: SCRIPT
      value: |
        mkdir -p .docker
        oc get secret quay-ci-push -n quay -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d \
          > ".docker/config.json"
        echo "Quay credentials of the CI robot ready"
  workspaces:
    - {name: manifest_dir, workspace: source}
{{- end }}
