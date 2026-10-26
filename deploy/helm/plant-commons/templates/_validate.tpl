{{/*
Render-time guards. They run in addition to values.schema.json so they still protect when the schema
is skipped (--skip-schema-validation) and give a clearer message for the security-relevant ones.
*/}}
{{- define "pc.validate" -}}
{{- $v := .Values -}}

{{- /* auth: ORCID only, never LOCAL, never dev */ -}}
{{- if contains "LOCAL" (upper $v.auth.providers) -}}
{{- fail (printf "auth.providers=%q contains LOCAL: local (passwordless) accounts must never be enabled in the cluster. Use ORCID:INVITE_ONLY or ORCID:EVERYONE." $v.auth.providers) -}}
{{- end -}}
{{- if not (regexMatch "^ORCID:(INVITE_ONLY|EVERYONE)$" $v.auth.providers) -}}
{{- fail (printf "auth.providers=%q is not allowed: ORCID only, exactly ORCID:INVITE_ONLY or ORCID:EVERYONE (docs/plant-commons/configuration.md section 3)." $v.auth.providers) -}}
{{- end -}}
{{- if eq (lower (toString $v.auth.environment)) "dev" -}}
{{- fail "auth.environment=dev is not allowed: RSD_ENVIRONMENT=dev makes the first login an admin. Use prod." -}}
{{- end -}}
{{- if not $v.auth.environment -}}
{{- fail "auth.environment must not be empty (prod)." -}}
{{- end -}}
{{- if not (regexMatch "^APP-[0-9A-Z]{16}$" (toString $v.orcid.clientId)) -}}
{{- fail "orcid.clientId is required and must look like APP-XXXXXXXXXXXXXXXX (the production ORCID client id)." -}}
{{- end -}}
{{- range $v.auth.args }}{{ if or (contains "jdwp" (lower (toString .))) (contains "5005" (toString .)) }}
{{- fail "auth.args must not contain a JDWP debug agent or port 5005 (docs/plant-commons/services.md)." -}}
{{- end }}{{ end -}}
{{- range $v.backgroundServices.args }}{{ if or (contains "jdwp" (lower (toString .))) (contains "5005" (toString .)) }}
{{- fail "backgroundServices.args must not contain a JDWP debug agent or port 5005." -}}
{{- end }}{{ end -}}
{{- if or (contains "jdwp" (lower (toString $v.auth.javaToolOptions))) (contains "jdwp" (lower (toString $v.backgroundServices.javaToolOptions))) -}}
{{- fail "javaToolOptions must not contain a JDWP debug agent." -}}
{{- end -}}

{{- /* public host: bare host name only, so HOST_URL has no trailing slash and no double scheme */ -}}
{{- if not (regexMatch "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$" (toString $v.host)) -}}
{{- fail (printf "host=%q must be a bare host name such as plant-commons.ipk-gatersleben.de: no scheme (https://), no path, no trailing slash, no port. HOST_URL is derived as https://<host>; a trailing slash would break the ORCID redirect URI." (toString $v.host)) -}}
{{- end -}}
{{- range $k, $u := dict "urls.postgrest" $v.urls.postgrest "auth.rsdAuthUrl" $v.auth.rsdAuthUrl -}}
{{- if and $u (not (regexMatch "^https?://[^/]+(/[^/]+)*$" $u)) -}}
{{- fail (printf "%s=%q must be an http(s) URL without a trailing slash." $k $u) -}}
{{- end -}}
{{- end -}}

{{- /* images */ -}}
{{- if or (not $v.image.namespace) (hasPrefix "CHANGE_ME" $v.image.namespace) -}}
{{- fail "image.namespace is still the placeholder CHANGE_ME: set it to the path below the registry (e.g. <owner>/<repo>, see docs/plant-commons/images.md)." -}}
{{- end -}}
{{- if not $v.image.tag -}}
{{- fail "image.tag is required: the sha-<short sha> tag of the CI build (same for all services)." -}}
{{- end -}}
{{- if eq (toString $v.image.tag) "latest" -}}
{{- fail "image.tag=latest is refused: deploy an immutable sha-<short sha> tag." -}}
{{- end -}}

{{- /* secrets */ -}}
{{- if and $v.secrets.create $v.existingSecret -}}
{{- fail "Set either secrets.create=true (local tests only) or existingSecret, not both." -}}
{{- end -}}
{{- if $v.secrets.create -}}
{{- range $k, $val := $v.secrets.values -}}
{{- if not $val -}}{{- fail (printf "secrets.create=true needs secrets.values.%s" $k) -}}{{- end -}}
{{- end -}}
{{- range $k := list "POSTGRES_PASSWORD" "POSTGRES_AUTHENTICATOR_PASSWORD" "PGRST_JWT_SECRET" -}}
{{- if not (regexMatch "^[A-Za-z0-9]+$" (toString (index $v.secrets.values $k))) -}}
{{- fail (printf "secrets.values.%s must be [A-Za-z0-9] only (docs/plant-commons/configuration.md section 5)." $k) -}}
{{- end -}}
{{- end -}}
{{- if lt (len (toString $v.secrets.values.PGRST_JWT_SECRET)) 32 -}}
{{- fail "secrets.values.PGRST_JWT_SECRET must be at least 32 characters (PostgREST)." -}}
{{- end -}}
{{- end -}}
{{- $_ := include "pc.secretName" . -}}

{{- /* database */ -}}
{{- if not (regexMatch "^[a-z0-9-]+$" (toString $v.database.name)) -}}
{{- fail "database.name must match [a-z0-9-]+ (it is sed-substituted into SQL at first init)." -}}
{{- end -}}

{{- /* pod disruption budgets only make sense with >= 2 replicas (otherwise they block node drains) */ -}}
{{- range $c := list "frontend" "backend" "auth" -}}
{{- $s := index $.Values $c -}}
{{- if and $s.podDisruptionBudget.enabled (lt (int $s.replicas) 2) -}}
{{- fail (printf "%s.podDisruptionBudget.enabled needs %s.replicas >= 2: with one replica the budget blocks every node drain." $c $c) -}}
{{- end -}}
{{- end -}}

{{- /* optional database migration job */ -}}
{{- if and $v.dbMigration.enabled (not $v.dbMigration.configMapName) -}}
{{- fail "dbMigration.enabled needs dbMigration.configMapName (an existing ConfigMap holding the SQL)." -}}
{{- end -}}

{{- /* network policies */ -}}
{{- if $v.networkPolicy.enabled -}}
{{- if not $v.networkPolicy.ingressFrom -}}
{{- fail "networkPolicy.enabled needs networkPolicy.ingressFrom (the ingress controller peers); default-deny ingress would otherwise cut the site off. See values.yaml." -}}
{{- end -}}
{{- if $v.networkPolicy.egress.enabled -}}
{{- if not $v.networkPolicy.egress.orcid -}}
{{- fail "networkPolicy.egress.enabled needs networkPolicy.egress.orcid (peers for orcid.org:443); the auth pod cannot log anyone in without it and discovery runs only once at start. Not guessed here, see values.yaml." -}}
{{- end -}}
{{- if and $v.scrapers.enabled (not $v.networkPolicy.egress.scrapers) -}}
{{- fail "networkPolicy.egress.enabled with scrapers.enabled needs networkPolicy.egress.scrapers." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* routing: every cluster specific input must be given, none is guessed */ -}}
{{- if $v.routing.enabled -}}
{{- if not $v.routing.entryPoints -}}
{{- fail "routing.enabled needs routing.entryPoints (open question 3/13, docs/plant-commons/routing.md)." -}}
{{- end -}}
{{- if and $v.routing.certificate.enabled (not $v.routing.certificate.issuerRef.name) -}}
{{- fail "routing.certificate.enabled needs routing.certificate.issuerRef.name (open question 3), or set routing.certificate.enabled=false." -}}
{{- end -}}
{{- end -}}
{{- end -}}
