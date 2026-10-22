{{/* SPDX-License-Identifier: Apache-2.0 */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "redis-cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "redis-cluster.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "redis-cluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redis-cluster.labels" -}}
helm.sh/chart: {{ include "redis-cluster.chart" . }}
{{ include "redis-cluster.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "redis-cluster.selectorLabels" -}}
app.kubernetes.io/name: {{ include "redis-cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
redis-cli invocation with TLS flags, for use in shell scripts and probes.
When auth is enabled, redis-cli reads the password from $REDISCLI_AUTH (see
"redis-cluster.authEnv"), so it never appears on a command line.
*/}}
{{- define "redis-cluster.redisCli" -}}
{{- if .Values.tls.enabled -}}
redis-cli --tls --cacert /etc/redis/tls/{{ .Values.tls.caFilename }}{{ if ne .Values.tls.authClients "no" }} --cert /etc/redis/tls/{{ .Values.tls.certFilename }} --key /etc/redis/tls/{{ .Values.tls.keyFilename }}{{ end }}
{{- else -}}
redis-cli
{{- end -}}
{{- end }}

{{/*
Name of the Secret holding the Redis password: auth.existingSecret, or the
chart-managed Secret.
*/}}
{{- define "redis-cluster.authSecretName" -}}
{{- default (printf "%s-auth" (include "redis-cluster.fullname" .)) .Values.auth.existingSecret }}
{{- end }}

{{/*
Key of the password in the auth Secret.
*/}}
{{- define "redis-cluster.authSecretKey" -}}
{{- if .Values.auth.existingSecret }}
{{- required "auth.existingSecretPasswordKey is required with auth.existingSecret" .Values.auth.existingSecretPasswordKey }}
{{- else -}}
password
{{- end }}
{{- end }}

{{/*
Container env entries for the Redis password. REDIS_PASSWORD is used by the
scripts to write requirepass/masterauth; REDISCLI_AUTH is read by redis-cli.
Renders nothing when auth is disabled.
*/}}
{{- define "redis-cluster.authEnv" -}}
{{- if .Values.auth.enabled }}
{{- range list "REDIS_PASSWORD" "REDISCLI_AUTH" }}
- name: {{ . }}
  valueFrom:
    secretKeyRef:
      name: {{ include "redis-cluster.authSecretName" $ }}
      key: {{ include "redis-cluster.authSecretKey" $ }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding the TLS certificate files.
*/}}
{{- define "redis-cluster.tlsSecretName" -}}
{{- default (printf "%s-tls" (include "redis-cluster.fullname" .)) .Values.tls.existingSecret }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "redis-cluster.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "redis-cluster.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Shell snippet that appends requirepass/masterauth to /data/redis.conf from
$REDIS_PASSWORD (set from the auth Secret), so the password is never stored in
a ConfigMap. The value is double-quoted with \ and " escaped for redis.conf.
*/}}
{{- define "redis-cluster.appendAuthConf" -}}
chmod 600 /data/redis.conf
{{- if .Values.auth.enabled }}
: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set when auth is enabled}"
REDIS_PASSWORD_CONF=$(printf '%s' "$REDIS_PASSWORD" | sed 's/[\\"]/\\&/g')
printf 'requirepass "%s"\nmasterauth "%s"\n' "$REDIS_PASSWORD_CONF" "$REDIS_PASSWORD_CONF" >> /data/redis.conf
{{- end }}
{{- end }}
