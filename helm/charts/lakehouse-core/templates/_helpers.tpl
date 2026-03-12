{{/*
_helpers.tpl — Common template helpers for lakehouse-core chart
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "lakehouse-core.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "lakehouse-core.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Chart label
*/}}
{{- define "lakehouse-core.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources
*/}}
{{- define "lakehouse-core.labels" -}}
helm.sh/chart: {{ include "lakehouse-core.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: open-lakehouse-platform
environment: {{ .Values.global.environment | default "staging" }}
{{- end }}

{{/*
Selector labels for a given component
Usage: {{ include "lakehouse-core.selectorLabels" (dict "component" "trino" "context" .) }}
*/}}
{{- define "lakehouse-core.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .context.Release.Name }}
{{- end }}

{{/*
Standard pod security context (restricted profile)
*/}}
{{- define "lakehouse-core.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 1000
runAsGroup: 1000
fsGroup: 1000
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
Standard container security context (restricted profile)
*/}}
{{- define "lakehouse-core.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
runAsUser: 1000
capabilities:
  drop:
    - ALL
{{- end }}

{{/*
Standard rolling update strategy
*/}}
{{- define "lakehouse-core.rollingUpdateStrategy" -}}
type: RollingUpdate
rollingUpdate:
  maxSurge: 1
  maxUnavailable: 0
{{- end }}

{{/*
TLS volume + volumeMount for a given service
Usage: {{ include "lakehouse-core.tlsVolume" (dict "service" "trino" "context" .) }}
*/}}
{{- define "lakehouse-core.tlsVolumeMount" -}}
- name: tls-certs
  mountPath: /etc/ssl/service
  readOnly: true
{{- end }}

{{- define "lakehouse-core.tlsVolume" -}}
- name: tls-certs
  secret:
    secretName: {{ .service }}-tls
{{- end }}
