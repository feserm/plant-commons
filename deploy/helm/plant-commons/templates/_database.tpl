{{/*
PLANT-COMMONS database access helpers: one place that knows whether the database is the chart's own
(database.enabled=true: plain connection inside the namespace, passwords from existingSecret) or an external
CloudNativePG cluster (database.enabled=false: TLS with certificate verification, credentials from the Secrets of
externalDatabase). Used by the backend, background-services and the dbMigration Job.
*/}}

{{- define "pc.db.host" -}}
{{- if .Values.database.enabled -}}{{ include "pc.svc" (dict "ctx" . "c" "database") }}{{- else -}}{{ .Values.externalDatabase.host }}{{- end -}}
{{- end -}}

{{- define "pc.db.port" -}}
{{- if .Values.database.enabled -}}5432{{- else -}}{{ .Values.externalDatabase.port }}{{- end -}}
{{- end -}}

{{- define "pc.db.name" -}}
{{- if .Values.database.enabled -}}{{ .Values.database.name }}{{- else -}}{{ .Values.externalDatabase.name }}{{- end -}}
{{- end -}}

{{/* Owner user name when it is a literal (empty when it is read from the Secret). */}}
{{- define "pc.db.userLiteral" -}}
{{- if .Values.database.enabled -}}{{ .Values.database.user }}
{{- else if not .Values.externalDatabase.ownerSecret.usernameKey -}}{{ .Values.externalDatabase.user }}{{- end -}}
{{- end -}}

{{/* Fixed path of the CA certificate inside the pods (the Secret key is mapped to this file name). */}}
{{- define "pc.db.caDir" -}}/etc/plant-commons/db-ca{{- end -}}
{{- define "pc.db.caFile" -}}{{ include "pc.db.caDir" . }}/ca.crt{{- end -}}

{{/* libpq/JDBC connection parameters: empty for the chart's own database, TLS with verification for the external one. */}}
{{- define "pc.db.sslParams" -}}
{{- if not .Values.database.enabled -}}sslmode={{ .Values.externalDatabase.sslMode }}&sslrootcert={{ include "pc.db.caFile" . }}{{- end -}}
{{- end -}}

{{/* Volume + mount (YAML strings for pc.podTemplate extraVolumes / extraVolumeMounts); empty for the chart's own database. */}}
{{- define "pc.db.caVolumeMounts" -}}
{{- if not .Values.database.enabled -}}
- name: db-ca
  mountPath: {{ include "pc.db.caDir" . }}
  readOnly: true
{{- end -}}
{{- end -}}
{{- define "pc.db.caVolumes" -}}
{{- if not .Values.database.enabled -}}
- name: db-ca
  secret:
    secretName: {{ .Values.externalDatabase.caSecret.name | quote }}
    defaultMode: 0444
    items:
      - key: {{ .Values.externalDatabase.caSecret.key | quote }}
        path: ca.crt
{{- end -}}
{{- end -}}

{{/*
secretRefs (YAML list for pc.env) for the OWNER credentials: POSTGRES_PASSWORD, and POSTGRES_USER when the user
name is read from the Secret. Chart's own database: POSTGRES_PASSWORD from existingSecret.
*/}}
{{- define "pc.db.ownerRefs" -}}
{{- if .Values.database.enabled -}}
- {name: POSTGRES_PASSWORD, secret: {{ include "pc.secretName" . | quote }}, key: POSTGRES_PASSWORD}
{{- else -}}
{{- $o := .Values.externalDatabase.ownerSecret }}
{{- if $o.usernameKey }}
- {name: POSTGRES_USER, secret: {{ $o.name | quote }}, key: {{ $o.usernameKey | quote }}}
{{- end }}
- {name: POSTGRES_PASSWORD, secret: {{ $o.name | quote }}, key: {{ $o.passwordKey | quote }}}
{{- end -}}
{{- end -}}

{{/* secretRefs for the POSTGRES_AUTHENTICATOR_PASSWORD variable of the backend. */}}
{{- define "pc.db.authenticatorRefs" -}}
{{- if .Values.database.enabled -}}
- {name: POSTGRES_AUTHENTICATOR_PASSWORD, secret: {{ include "pc.secretName" . | quote }}, key: POSTGRES_AUTHENTICATOR_PASSWORD}
{{- else -}}
- {name: POSTGRES_AUTHENTICATOR_PASSWORD, secret: {{ .Values.externalDatabase.authenticatorSecret.name | quote }}, key: {{ .Values.externalDatabase.authenticatorSecret.key | quote }}}
{{- end -}}
{{- end -}}
