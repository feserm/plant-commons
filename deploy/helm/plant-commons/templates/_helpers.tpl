{{/* PLANT-COMMONS chart helpers. Everything shared between the services lives here. */}}

{{/* Release-scoped name prefix for workloads, ConfigMaps, Secret. */}}
{{- define "pc.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Workload name: pc.name (dict "ctx" $ "c" "auth") */}}
{{- define "pc.name" -}}
{{- printf "%s-%s" (include "pc.fullname" .ctx) .c | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Service name (the in-cluster DNS name): pc.svc (dict "ctx" $ "c" "auth") */}}
{{- define "pc.svc" -}}
{{- printf "%s%s" .ctx.Values.serviceNamePrefix .c -}}
{{- end -}}

{{/* Fixed container ports of the images (backend ports are values). */}}
{{- define "pc.port" -}}
{{- $p := dict "database" 5432 "auth" 7000 "frontend" 3000 "swagger" 8080 "backend" .ctx.Values.backend.port -}}
{{- index $p .c -}}
{{- end -}}

{{- define "pc.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .ctx.Chart.Name .ctx.Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .ctx.Chart.Name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .c }}
app.kubernetes.io/part-of: plant-commons
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
{{- end -}}

{{- define "pc.selectorLabels" -}}
app.kubernetes.io/name: {{ .ctx.Chart.Name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .c }}
{{- end -}}

{{/*
Image reference: pc.image (dict "ctx" $ "c" "auth") -> <registry>/<namespace>/plant-commons-auth:<tag>[@<digest>]
The optional per-component digest (image.digests.<c>) is appended; the tag is kept for readability, the digest is
what the container runtime verifies.
*/}}
{{- define "pc.image" -}}
{{- $i := .ctx.Values.image -}}
{{- $d := get ($i.digests | default dict) .c -}}
{{- printf "%s/%s/plant-commons-%s:%s" (required "image.registry is required" $i.registry) (required "image.namespace is required" $i.namespace) .c (required "image.tag is required (the sha-<short sha> tag of the CI build)" $i.tag) -}}
{{- if $d }}@{{ $d }}{{ end -}}
{{- end -}}

{{/* https://<host>, no trailing slash. */}}
{{- define "pc.hostUrl" -}}
{{- printf "https://%s" (required "host is required" .Values.host) -}}
{{- end -}}

{{- define "pc.postgrestUrl" -}}
{{- if .Values.urls.postgrest -}}
{{- .Values.urls.postgrest -}}
{{- else -}}
{{- printf "http://%s:%v" (include "pc.svc" (dict "ctx" . "c" "backend")) .Values.backend.port -}}
{{- end -}}
{{- end -}}

{{- define "pc.rsdAuthUrl" -}}
{{- if .Values.auth.rsdAuthUrl -}}
{{- .Values.auth.rsdAuthUrl -}}
{{- else -}}
{{- printf "http://%s:7000/auth" (include "pc.svc" (dict "ctx" . "c" "auth")) -}}
{{- end -}}
{{- end -}}

{{/* Name of the Secret holding the credentials. */}}
{{- define "pc.secretName" -}}
{{- if .Values.secrets.create -}}
{{- printf "%s-secrets" (include "pc.fullname" .) -}}
{{- else -}}
{{- required "existingSecret is required (name of an existing Secret with POSTGRES_PASSWORD, POSTGRES_AUTHENTICATOR_PASSWORD, PGRST_JWT_SECRET, AUTH_ORCID_CLIENT_SECRET), or set secrets.create=true for local tests only" .Values.existingSecret -}}
{{- end -}}
{{- end -}}

{{/* ConfigMap name of a component. */}}
{{- define "pc.configName" -}}
{{- include "pc.name" . -}}
{{- end -}}

{{/*
ConfigMap of one component: pc.configmap (dict "ctx" $ "c" "auth" "data" <dict>).
The data dict holds NON-secret values only; every value is quoted so it is a string.
*/}}
{{- define "pc.configmap" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "pc.configName" . }}
  labels:
    {{- include "pc.labels" . | nindent 4 }}
data:
  {{- range $k, $v := .data }}
  {{ $k }}: {{ $v | toString | quote }}
  {{- end }}
{{- end -}}

{{/* Checksum of a component's config + secret name, to roll pods when the config changes. */}}
{{- define "pc.configChecksum" -}}
{{- .data | toYaml | sha256sum -}}
{{- end -}}

{{/*
Container env: ConfigMap via envFrom, Secret keys one by one (least privilege: a pod only sees the keys
it needs, never envFrom of the whole Secret), then literal chart-fixed variables. Order matters: Secret
variables come BEFORE the literals so that `$(VAR)` references in a literal (PGRST_DB_URI) resolve.
  pc.env (dict "ctx" $ "c" "auth" "config" true "secrets" (list ...) "optionalSecrets" (list ...) "secretRefs" (list ...) "env" (dict ...))
*/}}
{{- define "pc.env" -}}
{{- if .config }}
envFrom:
  - configMapRef:
      name: {{ include "pc.configName" . }}
{{- end }}
{{- if or .secrets .optionalSecrets .secretRefs .env }}
env:
  {{- range .secrets }}
  - name: {{ . }}
    valueFrom:
      secretKeyRef:
        name: {{ include "pc.secretName" $.ctx }}
        key: {{ . }}
  {{- end }}
  {{- range .optionalSecrets }}
  - name: {{ . }}
    valueFrom:
      secretKeyRef:
        name: {{ include "pc.secretName" $.ctx }}
        key: {{ . }}
        optional: true
  {{- end }}
  {{- /* PLANT-COMMONS: secretRefs = list of {name, secret, key} for Secrets that are NOT existingSecret (external database) */}}
  {{- range .secretRefs }}
  - name: {{ .name }}
    valueFrom:
      secretKeyRef:
        name: {{ .secret | quote }}
        key: {{ .key | quote }}
  {{- end }}
  {{- range $k, $v := .env }}
  - name: {{ $k }}
    value: {{ $v | toString | quote }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Pod template shared by Deployments and the StatefulSet.
  pc.podTemplate (dict "ctx" $ "c" "auth" "v" .Values.auth "image" ... "args" list "ports" (list (dict "name" "http" "port" 7000))
                       "envBlock" <string> "checksum" <string> "probes" <dict> "emptyDirs" (list "/tmp")
                       "extraVolumeMounts" <yaml string> "extraVolumes" <yaml string> "lifecycle" <dict>)
*/}}
{{- define "pc.podTemplate" -}}
metadata:
  labels:
    {{- include "pc.selectorLabels" . | nindent 4 }}
  {{- if .checksum }}
  annotations:
    checksum/config: {{ .checksum }}
  {{- end }}
spec:
  automountServiceAccountToken: false
  enableServiceLinks: false
  {{- with .ctx.Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- toYaml .v.podSecurityContext | nindent 4 }}
  {{- if hasKey .v "terminationGracePeriodSeconds" }}
  terminationGracePeriodSeconds: {{ .v.terminationGracePeriodSeconds }}
  {{- end }}
  containers:
    - name: {{ .c }}
      image: {{ .image | quote }}
      imagePullPolicy: {{ .ctx.Values.image.pullPolicy }}
      {{- with .args }}
      args:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .ports }}
      ports:
        {{- range . }}
        - name: {{ .name }}
          containerPort: {{ .port }}
          protocol: TCP
        {{- end }}
      {{- end }}
      {{- .envBlock | trim | nindent 6 }}
      {{- range $name, $probe := .probes }}
      {{ $name }}:
        {{- toYaml $probe | nindent 8 }}
      {{- end }}
      {{- with .lifecycle }}
      lifecycle:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      resources:
        {{- toYaml .v.resources | nindent 8 }}
      securityContext:
        {{- toYaml .v.securityContext | nindent 8 }}
      {{- if or .emptyDirs .extraVolumeMounts }}
      volumeMounts:
        {{- range $i, $p := .emptyDirs }}
        - name: tmp-{{ $i }}
          mountPath: {{ $p }}
        {{- end }}
        {{- with .extraVolumeMounts }}
        {{- . | nindent 8 }}
        {{- end }}
      {{- end }}
  {{- if or .emptyDirs .extraVolumes }}
  volumes:
    {{- range $i, $p := .emptyDirs }}
    - name: tmp-{{ $i }}
      emptyDir: {}
    {{- end }}
    {{- with .extraVolumes }}
    {{- . | nindent 4 }}
    {{- end }}
  {{- end }}
  {{- with .ctx.Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .ctx.Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .ctx.Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}

{{/*
Deployment: same dict as pc.podTemplate plus "replicas" and optional "strategy".
*/}}
{{- define "pc.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "pc.name" . }}
  labels:
    {{- include "pc.labels" . | nindent 4 }}
spec:
  replicas: {{ .replicas }}
  revisionHistoryLimit: 3
  {{- with .strategy }}
  strategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "pc.selectorLabels" . | nindent 6 }}
  template:
    {{- include "pc.podTemplate" . | nindent 4 }}
{{- end -}}

{{/* ClusterIP Service: pc.service (dict "ctx" $ "c" "auth" "ports" (list (dict "name" "http" "port" 7000))) */}}
{{- define "pc.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "pc.svc" . }}
  labels:
    {{- include "pc.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  selector:
    {{- include "pc.selectorLabels" . | nindent 4 }}
  ports:
    {{- range .ports }}
    - name: {{ .name }}
      port: {{ .port }}
      targetPort: {{ .name }}
      protocol: TCP
    {{- end }}
{{- end -}}
