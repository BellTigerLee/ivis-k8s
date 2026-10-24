{{/* All helpers run inside native Helm. No plugin, shell, lookup or external files. */}}
{{- define "ivis.image" -}}
{{- $i := .image -}}
{{- $repo := required "image repository is required" $i.repository -}}
{{- $tag := default .root.Values.image.tag $i.tag -}}
{{- $digest := default "" $i.digest -}}
{{- $legacy := list "sha256:dc2a0f645cef0d9bf5d7b7c74504502a112e9f3d187ee59676aed0bec8d5da29" "sha256:7de1ec9fc4fd10c5e348bbfa76ceb5fae5b23cac018a7d87997b23a626ac3e36" "sha256:c544e18722afae9ae1050c78f5c05f8a1e3d787a969f4f35c7e43cef78643080" "sha256:0b9fe2b6649eaa9089c94f1ea594c95ab05dda20fe222f9be5c3c64560c6f040" "sha256:73795453fb5eb6ec8155f317e8d162885172b451c5bf5c6d62213b7157a4d885" -}}
{{- if and (hasPrefix "belltigerlee/ivis-" $repo) (or (has $digest $legacy) (and (not $digest) (has $tag (list "0.2.0" "0.3.0")))) -}}
{{- fail "Published 0.2.0/0.3.0 images do not support this candidate YAML/protocol; select compatible images" -}}
{{- end -}}
{{- if $digest -}}{{ printf "%s@%s" $repo $digest }}{{- else -}}{{ printf "%s:%s" $repo $tag }}{{- end -}}
{{- end -}}

{{- define "ivis.modules" -}}
{{- $root := . -}}
{{- $active := list -}}
{{- range $id := keys (.Values.modules | default dict) | sortAlpha -}}
{{- $value := index $root.Values.modules $id -}}
{{- if $value.enabled -}}
{{- $path := default (printf "files/modules/%s.yaml" $id) $value.descriptor -}}
{{- if not (regexMatch "^files/modules/[a-z][a-z0-9-]*[.]yaml$" $path) -}}{{ fail "descriptor must be a packaged files/modules/<id>.yaml file" }}{{- end -}}
{{- if and (has $id (list "process" "cpu" "syscall")) (ne $path (printf "files/modules/%s.yaml" $id)) -}}{{ fail "built-in descriptor replacement is not supported" }}{{- end -}}
{{- $raw := required (printf "missing packaged descriptor for module %s" $id) ($root.Files.Get $path) -}}
{{- $d := fromYaml $raw -}}
{{- if or (ne $d.apiVersion "ivis.module-descriptor/v1") (ne $d.module.id $id) -}}{{ fail "module descriptor version/ID mismatch" }}{{- end -}}
{{- $m := deepCopy $d.module -}}
{{- if not (has $m.profile (list "process" "kernel" "adapter")) -}}{{ fail "unsupported module profile" }}{{- end -}}
{{- if and (hasKey $m "requires_tracefs") (not (kindIs "bool" $m.requires_tracefs)) -}}{{ fail "requires_tracefs must be a boolean" }}{{- end -}}
{{- $_ := set $m "requiresTracefs" (and (hasKey $m "requires_tracefs") $m.requires_tracefs) -}}
{{- if not (regexMatch "^/[^[:space:]]+$" $m.executable) -}}{{ fail "module executable must be an absolute container path" }}{{- end -}}
{{- if not (regexMatch "^https://[^/@?#[:space:]]+(/[^?#[:space:]]*)?$" $m.source_repository) -}}{{ fail "module provenance must be a credential-free HTTPS URL" }}{{- end -}}
{{- $image := mergeOverwrite (dict "repository" $m.image.repository) (deepCopy ($value.image | default dict)) -}}
{{- $_ := set $m "imageRef" (include "ivis.image" (dict "root" $root "image" $image)) -}}
{{- $_ := set $m "resources" (mergeOverwrite (deepCopy $m.resources) (deepCopy ($value.resources | default dict))) -}}
{{- $feature := deepCopy $m.feature -}}
{{- range $key, $v := ($value.config | default dict) -}}
{{- if not (hasKey $d.settings $key) -}}{{ fail (printf "unknown setting modules.%s.config.%s" $id $key) }}{{- end -}}
{{- $s := index $d.settings $key -}}
{{- if eq $s.type "boolean" -}}
{{- if not (kindIs "bool" $v) -}}{{ fail (printf "%s must be boolean" $key) }}{{- end -}}
{{- else if eq $s.type "string" -}}
{{- if not (kindIs "string" $v) -}}{{ fail (printf "%s must be string" $key) }}{{- end -}}
{{- else if has $s.type (list "integer" "duration") -}}
{{- $n := int64 0 -}}
{{- if eq $s.type "duration" -}}
{{- if not (and (kindIs "string" $v) (regexMatch "^[0-9]+(ns|us|ms|s|m|h)$" (toString $v))) -}}{{ fail (printf "%s requires an integer duration with ns/us/ms/s/m/h unit" $key) }}{{- end -}}
{{- $unit := regexFind "[a-z]+$" $v -}}
{{- $factor := int64 (index (dict "ns" 1 "us" 1000 "ms" 1000000 "s" 1000000000 "m" 60000000000 "h" 3600000000000) $unit) -}}
{{- $digits := regexFind "^[0-9]+" $v -}}
{{- if or (gt (len $digits) 15) (gt (int64 $digits) (div (int64 $s.maximum) $factor)) -}}{{ fail (printf "%s exceeds maximum duration" $key) }}{{- end -}}
{{- $n = mul (int64 $digits) $factor -}}
{{- else -}}
{{- if or (kindIs "string" $v) (not (regexMatch "^[0-9]+$" (toString $v))) -}}{{ fail (printf "%s must be an integer" $key) }}{{- end -}}
{{- $n = int64 $v -}}
{{- end -}}
{{- if or (lt $n (int64 $s.minimum)) (gt $n (int64 $s.maximum)) -}}{{ fail (printf "%s is outside descriptor bounds" $key) }}{{- end -}}
{{- $v = $n -}}
{{- else -}}{{ fail "unsupported descriptor setting type" }}{{- end -}}
{{- $_ := set $feature $s.field $v -}}
{{- end -}}
{{- $_ := set $m "feature" $feature -}}
{{- $_ := set $m "definition" (pick $m "id" "source_repository" "sources" "schemas") -}}
{{- $active = append $active $m -}}
{{- end -}}
{{- end -}}
{{- toJson $active -}}
{{- end -}}

{{- define "ivis.agentConfig" -}}
{{- $a := .Values.agent -}}
{{- $mods := include "ivis.modules" . | fromJsonArray -}}
{{- $defs := list -}}
{{- range $mods -}}{{- $defs = append $defs .definition -}}{{- end -}}
{{- if lt (int64 $a.retentionSeconds) (add (int64 $a.enrichmentWaitSeconds) (mul 2 (int64 $a.intervalSeconds))) -}}{{ fail "retentionSeconds must cover enrichmentWaitSeconds + 2*intervalSeconds" }}{{- end -}}
{{- $otlp := deepCopy $a.otlp -}}
{{- if and (eq $otlp.protocol "grpc") (not $otlp.use_protobuf) -}}{{ fail "OTLP JSON requires HTTP; gRPC requires use_protobuf=true" }}{{- end -}}
{{- if $mods -}}
{{- if not (regexMatch "^https?://[^/@?#[:space:]]+(/[^?#[:space:]]*)?$" $otlp.endpoint) -}}{{ fail "active modules require an http(s) OTLP endpoint without credentials/query/fragment" }}{{- end -}}
{{- if and (eq $otlp.protocol "grpc") (not (regexMatch "^https?://[^/]+/?$" $otlp.endpoint)) -}}{{ fail "gRPC endpoint must not contain a path" }}{{- end -}}
{{- if ne (hasKey .Values.security "certificate") (hasKey .Values.security "key") -}}{{ fail "TLS certificate and key references must be paired" }}{{- end -}}
{{- if and (hasPrefix "http://" $otlp.endpoint) (or (hasKey .Values.security "ca") (hasKey .Values.security "certificate")) -}}{{ fail "TLS references require https" }}{{- end -}}
{{- range $key, $file := dict "ca" "ca_file" "certificate" "cert_file" "key" "key_file" "headers" "headers_file" -}}
{{- if hasKey $.Values.security $key -}}{{- $_ := set $otlp $file (printf "/etc/ivis-secrets/%s/value" $key) -}}{{- end -}}
{{- end -}}
{{- end }}
modules:
{{ toYaml $defs | indent 2 }}
socket_directory: /run/ivis
proc_root: /host/proc
cgroup_root: /host/cgroup
runtime_socket: /host/run/runtime.sock
listen: ":8082"
stdout: {{ $a.stdout }}
queue_size: {{ $a.queueSize }}
max_entries: {{ $a.maxEntries }}
interval_seconds: {{ $a.intervalSeconds }}
enrichment_wait_seconds: {{ $a.enrichmentWaitSeconds }}
retention_seconds: {{ $a.retentionSeconds }}
snapshot: false
attributes:
{{- if $a.metadata }}
{{- range $key, $value := $a.metadata }}
  {{ $key | quote }}: {{ $value | toJson }}
{{- end }}
{{- else }}
  {}
{{- end }}
otlp:
{{ toYaml $otlp | indent 2 }}
{{- if $mods }}
delivery:
{{ toYaml $a.delivery | indent 2 }}
{{- end }}
{{- end -}}

{{- define "ivis.configData" -}}
{{- if eq .Values.agent.mode "builtin" }}
agent.yaml: |
{{ include "ivis.builtinConfig" . | trim | indent 2 }}
{{- else }}
agent.yaml: |
{{ include "ivis.agentConfig" . | trim | indent 2 }}
{{- range (include "ivis.modules" . | fromJsonArray) }}
{{ .id }}.yaml: |
  module:
{{ toYaml .definition | indent 4 }}
  socket_directory: /run/ivis
  health_file: /tmp/ivis-module-health
  queue_size: {{ $.Values.agent.queueSize }}
  proc_root: /host/proc
  feature:
{{ toYaml .feature | indent 4 }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "ivis.securityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsUser: {{ if .root }}0{{ else }}65532{{ end }}
runAsNonRoot: {{ not .root }}
capabilities:
  drop: [ALL]
{{- if .kernel }}
  add: [BPF, PERFMON, SYS_RESOURCE, SYS_PTRACE, DAC_READ_SEARCH]
seccompProfile: {type: Unconfined}
appArmorProfile: {type: Unconfined}
{{- else }}
seccompProfile: {type: RuntimeDefault}
{{- end }}
{{- end -}}
