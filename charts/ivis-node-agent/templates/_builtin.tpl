{{/* Single-process compact configuration. No feature code in Helm. */}}
{{- define "ivis.builtinConfig" -}}
{{- $mods := include "ivis.modules" . | fromJsonArray -}}
{{- range $mods }}
{{- if and (eq .id "cpu") (not (has (default "timing" .feature.mode) (list "timing" "counts"))) }}{{ fail "CPU mode must be timing or counts" }}{{ end }}
{{- end }}
{{- if .Values.agent.delivery.directory -}}{{ fail "builtin compact is same-run only; durable legacy delivery is unsupported" }}{{- end -}}
{{- $otlp := deepCopy .Values.agent.otlp -}}
{{- if and (eq $otlp.protocol "grpc") (not $otlp.use_protobuf) -}}{{ fail "OTLP JSON requires HTTP; gRPC requires use_protobuf=true" }}{{- end -}}
{{- range $key, $file := dict "ca" "ca_file" "certificate" "cert_file" "key" "key_file" "headers" "headers_file" -}}
{{- if hasKey $.Values.security $key -}}{{- $_ := set $otlp $file (printf "/etc/ivis-secrets/%s/value" $key) -}}{{- end -}}
{{- end }}
cluster_uid: {{ .Values.agent.clusterUID | quote }}
node_uid: {{ .Values.agent.nodeUID | quote }}
proc_root: /host/proc
cgroup_root: /host/cgroup
runtime_socket: /host/run/runtime.sock
listen: ":8082"
max_entries: {{ .Values.agent.maxEntries }}
queue_size: {{ .Values.agent.queueSize }}
interval_seconds: {{ .Values.agent.intervalSeconds }}
aggregation:
  window: {{ .Values.agent.aggregation.window | quote }}
export:
  interval: {{ .Values.agent.export.interval | quote }}
  max_batch_bytes: {{ int64 .Values.agent.export.maxBatchBytes }}
  max_request_bytes: {{ int64 .Values.agent.export.maxRequestBytes }}
otlp:
{{ toYaml $otlp | indent 2 }}
modules:
{{- if not $mods }}
  {}
{{- else }}
{{- range $mods }}
  {{ .id }}:
    enabled: true
    feature: {{ .feature | toJson }}
{{- if eq .id "cpu" }}
    config:
      window: {{ dig "cpu" "config" "window" $.Values.agent.aggregation.window $.Values.modules | quote }}
      max_entries: {{ .feature.max_entries }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}
