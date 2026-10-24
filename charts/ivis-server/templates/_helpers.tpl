{{- define "server.name" -}}{{ .Values.name }}{{- end -}}
{{- define "server.labels" -}}
app.kubernetes.io/name: {{ include "server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "server.image" -}}
{{- if .Values.image.digest -}}
{{ printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else -}}
{{ printf "%s:%s" .Values.image.repository .Values.image.tag }}
{{- end -}}
{{- end -}}
{{- define "server.hash" -}}
{{- $parts := list (toJson .Values) (toJson .Chart) -}}
{{- range $path, $_ := .Files.Glob "files/**" -}}
{{- $parts = append $parts ($.Files.Get $path) -}}
{{- end -}}
{{- range $path, $_ := .Files.Glob "templates/**" -}}
{{- $parts = append $parts ($.Files.Get $path) -}}
{{- end -}}
{{ join "\n" $parts | sha256sum | trunc 12 }}
{{- end -}}
{{- define "server.validate" -}}
{{- if has (lower .Values.clickhouse.signalsDatabase) (list "system" "information_schema") -}}
{{- fail "clickhouse.signalsDatabase must be an application database" -}}
{{- end -}}
{{- if and .Values.kumec.enabled (or (not .Values.signals.enabled) (not .Values.inventory.enabled)) -}}
{{- fail "kumec.enabled requires signals.enabled and inventory.enabled" -}}
{{- end -}}
{{- range $topic, $adapter := .Values.signals.topicAdapters -}}
{{- if not (has $topic $.Values.signals.topics) -}}{{ fail "signals.topicAdapters keys must appear in signals.topics" }}{{- end -}}
{{- end -}}
{{- end -}}
{{- define "server.security" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
fsGroup: 10001
seccompProfile: {type: RuntimeDefault}
{{- end -}}
{{- define "server.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities: {drop: [ALL]}
{{- end -}}
{{- define "server.mounts" -}}
- {name: runtime, mountPath: /opt/ivis, readOnly: true}
- {name: postgres, mountPath: /credentials/postgres, readOnly: true}
- {name: clickhouse, mountPath: /credentials/clickhouse, readOnly: true}
- {name: tmp, mountPath: /tmp}
{{- end -}}
{{- define "server.volumes" -}}
- name: runtime
  configMap: {name: {{ .Values.name }}-runtime}
- name: postgres
  secret:
    secretName: {{ .Values.postgres.credentials.existingSecret }}
    defaultMode: 0440
    items:
{{- if eq .Values.postgres.credentials.mode "dsn" }}
      - {key: {{ .Values.postgres.credentials.dsnKey | quote }}, path: dsn}
{{- else }}
      - {key: {{ .Values.postgres.credentials.usernameKey | quote }}, path: username}
      - {key: {{ .Values.postgres.credentials.passwordKey | quote }}, path: password}
{{- end }}
- name: clickhouse
  secret:
    secretName: {{ .Values.clickhouse.credentials.existingSecret }}
    defaultMode: 0440
    items:
      - {key: {{ .Values.clickhouse.credentials.usernameKey | quote }}, path: username}
      - {key: {{ .Values.clickhouse.credentials.passwordKey | quote }}, path: password}
- name: tmp
  emptyDir: {sizeLimit: {{ .Values.tmpSizeLimit }}}
{{- end -}}
