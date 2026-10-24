{{- if eq .Values.agent.mode "external" -}}
{{- $modules := include "ivis.modules" . | fromJsonArray -}}
{{- $active := gt (len $modules) 0 -}}
{{- $kernel := false -}}
{{- $tracefs := false -}}
{{- range $modules -}}{{- if has .profile (list "process" "kernel") -}}{{- $kernel = true -}}{{- end -}}{{- if .requiresTracefs -}}{{- $tracefs = true -}}{{- end -}}{{- end -}}
{{- if hasKey .Values.podLabels "app.kubernetes.io/name" -}}{{ fail "app.kubernetes.io/name is a reserved pod label" }}{{- end -}}
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: {{ .Values.name }}
  namespace: {{ .Release.Namespace | quote }}
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ .Values.name }}
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ .Values.name }}
        {{- with .Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      annotations:
        ivis.io/config-sha256: {{ include "ivis.configData" . | sha256sum }}
    spec:
      automountServiceAccountToken: false
      serviceAccountName: {{ ternary .Values.name "default" $active }}
      serviceAccount: {{ ternary .Values.name "default" $active }}
      terminationGracePeriodSeconds: {{ if $active }}{{ add .Values.agent.delivery.shutdown_seconds 10 }}{{ else }}10{{ end }}
      securityContext:
        fsGroup: 65532
      {{- if $kernel }}
      hostPID: true
      {{- end }}
      nodeSelector:
        {{- toYaml .Values.nodeSelector | nindent 8 }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: agent
          image: {{ include "ivis.image" (dict "root" . "image" .Values.image) | quote }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          args: [--config, /etc/ivis/agent.yaml]
          env:
            - name: GOMAXPROCS
              value: "2"
            {{- if $active }}
            - name: NODE_NAME
              valueFrom:
                fieldRef: {fieldPath: spec.nodeName}
            {{- end }}
          resources:
            {{- toYaml .Values.agent.resources | nindent 12 }}
          securityContext:
            {{- include "ivis.securityContext" (dict "root" $active "kernel" false) | nindent 12 }}
            {{- if $active }}
            runAsGroup: {{ dig "runAsGroup" 0 .Values.agent }}
            {{- end }}
          ports:
            - name: health
              containerPort: 8082
          readinessProbe:
            httpGet: {path: /readyz, port: 8082}
            periodSeconds: 2
            failureThreshold: 1
          volumeMounts:
            - {name: config, mountPath: /etc/ivis, readOnly: true}
            {{- if $active }}
            - {name: modules, mountPath: /run/ivis}
            - {name: proc, mountPath: /host/proc, readOnly: true}
            - {name: cgroup, mountPath: /host/cgroup, readOnly: true}
            - {name: runtime, mountPath: /host/run/runtime.sock, readOnly: true}
            - {name: token, mountPath: /var/run/secrets/kubernetes.io/serviceaccount, readOnly: true}
            {{- if .Values.agent.delivery.directory }}
            - {name: delivery, mountPath: /var/lib/ivis-delivery}
            {{- end }}
            {{- range $name, $ref := .Values.security }}
            - {name: {{ printf "secret-%s" $name }}, mountPath: {{ printf "/etc/ivis-secrets/%s" $name }}, readOnly: true}
            {{- end }}
            {{- end }}
        {{- range $modules }}
        - name: module-{{ .id }}
          image: {{ .imageRef | quote }}
          imagePullPolicy: {{ $.Values.image.pullPolicy }}
          args: [--config, {{ printf "/etc/ivis/%s.yaml" .id }}]
          env:
            - name: GOMAXPROCS
              value: "2"
            - name: NODE_NAME
              valueFrom:
                fieldRef: {fieldPath: spec.nodeName}
          resources:
            {{- toYaml .resources | nindent 12 }}
          securityContext:
            {{- $k := has .profile (list "process" "kernel") }}
            {{- include "ivis.securityContext" (dict "root" $k "kernel" $k) | nindent 12 }}
          readinessProbe:
            exec:
              command: [{{ .executable | quote }}, --check-health, /tmp/ivis-module-health]
            periodSeconds: 2
            failureThreshold: 1
          volumeMounts:
            - {name: config, mountPath: /etc/ivis, readOnly: true}
            - {name: modules, mountPath: /run/ivis}
            - {name: proc, mountPath: /host/proc, readOnly: true}
            - {name: {{ printf "tmp-%s" .id }}, mountPath: /tmp}
            {{- if $k }}
            - {name: cgroup, mountPath: /host/cgroup, readOnly: true}
            - {name: btf, mountPath: /sys/kernel/btf, readOnly: true}
            {{- end }}
            {{- if .requiresTracefs }}
            - {name: tracefs, mountPath: /sys/kernel/tracing, readOnly: true}
            {{- end }}
        {{- end }}
      volumes:
        - name: config
          configMap: {name: {{ .Values.name }}}
        {{- if $active }}
        - name: modules
          emptyDir: {medium: Memory}
        - name: proc
          hostPath: {path: /proc, type: Directory}
        - name: cgroup
          hostPath: {path: /sys/fs/cgroup, type: Directory}
        - name: runtime
          hostPath: {path: {{ .Values.runtimeSocket | quote }}, type: Socket}
        - name: token
          projected:
            sources:
              - serviceAccountToken: {path: token, expirationSeconds: 3600}
              - configMap:
                  name: kube-root-ca.crt
                  items: [{key: ca.crt, path: ca.crt}]
              - downwardAPI:
                  items:
                    - path: namespace
                      fieldRef: {apiVersion: v1, fieldPath: metadata.namespace}
        {{- if .Values.agent.delivery.directory }}
        - name: delivery
          emptyDir:
            sizeLimit: {{ add .Values.agent.delivery.max_bytes 8388608 | quote }}
        {{- end }}
        {{- range $name, $ref := .Values.security }}
        - name: {{ printf "secret-%s" $name }}
          secret:
            secretName: {{ $ref.name | quote }}
            items: [{key: {{ $ref.key | quote }}, path: value}]
        {{- end }}
        {{- end }}
        {{- range $modules }}
        - name: tmp-{{ .id }}
          emptyDir: {}
        {{- end }}
        {{- if $kernel }}
        - name: btf
          hostPath: {path: /sys/kernel/btf, type: Directory}
        {{- end }}
        {{- if $tracefs }}
        - name: tracefs
          hostPath: {path: /sys/kernel/tracing, type: Directory}
        {{- end }}
{{- end }}
