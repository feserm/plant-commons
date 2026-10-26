{{/*
Non-secret configuration per component: the "Source = ConfigMap" rows of
docs/plant-commons/configuration.md section 2. Each helper returns a YAML map; the same text feeds the
ConfigMap and the pod checksum annotation, so they cannot diverge.
*/}}

{{- define "pc.config.database" -}}
POSTGRES_DB: {{ .Values.database.name }}
POSTGRES_USER: {{ .Values.database.user }}
{{- end -}}

{{- define "pc.config.backend" -}}
PGRST_DB_ANON_ROLE: {{ .Values.backend.dbAnonRole }}
PGRST_DB_SCHEMA: {{ .Values.backend.dbSchema }}
PGRST_SERVER_PORT: {{ .Values.backend.port | quote }}
PGRST_ADMIN_SERVER_PORT: {{ .Values.backend.adminPort | quote }}
{{- end -}}

{{- define "pc.config.auth" -}}
RSD_AUTH_PROVIDERS: {{ .Values.auth.providers | quote }}
RSD_ENVIRONMENT: {{ .Values.auth.environment | quote }}
ORCID_CLIENT_ID: {{ .Values.orcid.clientId | quote }}
ORCID_WELL_KNOWN_URL: {{ .Values.orcid.wellKnownUrl | quote }}
HOST_URL: {{ include "pc.hostUrl" . | quote }}
POSTGREST_URL: {{ include "pc.postgrestUrl" . | quote }}
RSD_API_ACCESS_TOKEN_ENABLED: {{ .Values.auth.apiAccessTokenEnabled | quote }}
{{- end -}}

{{- define "pc.config.backgroundServices" -}}
POSTGRES_DB_HOST: {{ include "pc.svc" (dict "ctx" . "c" "database") }}
POSTGRES_DB_HOST_PORT: "5432"
POSTGRES_DB: {{ .Values.database.name }}
POSTGRES_USER: {{ .Values.database.user }}
{{- end -}}

{{- define "pc.config.frontend" -}}
POSTGREST_URL: {{ include "pc.postgrestUrl" . | quote }}
RSD_AUTH_URL: {{ include "pc.rsdAuthUrl" . | quote }}
RSD_REVERSE_PROXY_URL: {{ include "pc.hostUrl" . | quote }}
{{- with .Values.frontend.crossrefContactEmail }}
CROSSREF_CONTACT_EMAIL: {{ . | quote }}
{{- end }}
{{- if and .Values.frontend.matomoUrl .Values.frontend.matomoId }}
MATOMO_URL: {{ .Values.frontend.matomoUrl | quote }}
MATOMO_ID: {{ .Values.frontend.matomoId | quote }}
{{- end }}
{{- end -}}

{{- define "pc.config.scrapers" -}}
POSTGREST_URL: {{ include "pc.postgrestUrl" . | quote }}
{{- range $k, $n := .Values.scrapers.maxRequests }}
MAX_REQUESTS_{{ $k }}: {{ $n | quote }}
{{- end }}
ENABLE_NASSA_SCRAPER: "false"
ENABLE_ESCAPE_OSSR_SCRAPER: "false"
{{- with .Values.scrapers.crossrefContactEmail }}
CROSSREF_CONTACT_EMAIL: {{ . | quote }}
{{- end }}
{{- end -}}

{{- define "pc.config.swagger" -}}
API_URL: {{ printf "%s/api/v1" (include "pc.hostUrl" .) | quote }}
{{- end -}}
