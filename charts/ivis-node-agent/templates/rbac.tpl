{{- $modules := include "ivis.modules" . | fromJsonArray -}}
{{- if $modules }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Values.name }}
  namespace: {{ .Release.Namespace | quote }}
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ printf "%s.%s-reader" .Release.Namespace .Values.name }}
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list]
  - apiGroups: [""]
    resources: [nodes]
    verbs: [get]
  {{- if eq .Values.agent.mode "builtin" }}
  - apiGroups: [""]
    resources: [namespaces]
    resourceNames: [kube-system]
    verbs: [get]
  {{- end }}
  - apiGroups: [apps]
    resources: [replicasets, deployments, daemonsets, statefulsets]
    verbs: [get]
  - apiGroups: [batch]
    resources: [jobs, cronjobs]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ printf "%s.%s-reader" .Release.Namespace .Values.name }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ printf "%s.%s-reader" .Release.Namespace .Values.name }}
subjects:
  - kind: ServiceAccount
    name: {{ .Values.name }}
    namespace: {{ .Release.Namespace | quote }}
{{- end }}
