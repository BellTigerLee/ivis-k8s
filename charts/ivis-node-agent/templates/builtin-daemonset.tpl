{{- if eq .Values.agent.mode "builtin" -}}
{{- $mods := include "ivis.modules" . | fromJsonArray -}}
{{- $active := gt (len $mods) 0 -}}
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: {{ .Values.name }}
  namespace: {{ .Release.Namespace | quote }}
spec:
  selector:
    matchLabels: {app.kubernetes.io/name: {{ .Values.name }}}
  updateStrategy: {type: RollingUpdate}
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
      terminationGracePeriodSeconds: 30
      {{- if $active }}
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
          args: [--builtin-config, /etc/ivis/agent.yaml]
          env:
            - {name: GOMAXPROCS, value: "2"}
            {{- if $active }}
            - name: NODE_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
            {{- end }}
          resources:
            {{- toYaml .Values.agent.resources | nindent 12 }}
          securityContext:
            {{- include "ivis.securityContext" (dict "root" $active "kernel" $active) | nindent 12 }}
            {{- if $active }}
            runAsGroup: {{ .Values.agent.runAsGroup }}
            {{- end }}
          ports: [{name: health, containerPort: 8082}]
          readinessProbe:
            httpGet: {path: /readyz, port: health}
            periodSeconds: 2
          volumeMounts:
            - {name: config, mountPath: /etc/ivis, readOnly: true}
            {{- if $active }}
            - {name: proc, mountPath: /host/proc, readOnly: true}
            - {name: cgroup, mountPath: /host/cgroup, readOnly: true}
            - {name: runtime, mountPath: /host/run/runtime.sock, readOnly: true}
            - {name: btf, mountPath: /sys/kernel/btf, readOnly: true}
            {{- range $mods }}
            {{- if .requires_tracefs }}
            - {name: tracefs, mountPath: /sys/kernel/tracing, readOnly: true}
            {{- end }}
            {{- end }}
            - {name: token, mountPath: /var/run/secrets/kubernetes.io/serviceaccount, readOnly: true}
            {{- range $name, $ref := .Values.security }}
            - {name: {{ printf "secret-%s" $name }}, mountPath: {{ printf "/etc/ivis-secrets/%s" $name }}, readOnly: true}
            {{- end }}
            {{- end }}
      volumes:
        - name: config
          configMap: {name: {{ .Values.name }}}
        {{- if $active }}
        - {name: proc, hostPath: {path: /proc, type: Directory}}
        - {name: cgroup, hostPath: {path: /sys/fs/cgroup, type: Directory}}
        - {name: runtime, hostPath: {path: {{ .Values.runtimeSocket | quote }}, type: Socket}}
        - {name: btf, hostPath: {path: /sys/kernel/btf, type: Directory}}
        {{- $tracefs := false }}
        {{- range $mods }}{{- if .requires_tracefs }}{{- $tracefs = true }}{{- end }}{{- end }}
        {{- if $tracefs }}
        - {name: tracefs, hostPath: {path: /sys/kernel/tracing, type: Directory}}
        {{- end }}
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
        {{- range $name, $ref := .Values.security }}
        - name: {{ printf "secret-%s" $name }}
          secret:
            secretName: {{ $ref.name | quote }}
            items: [{key: {{ $ref.key | quote }}, path: value}]
        {{- end }}
        {{- end }}
{{- end }}
