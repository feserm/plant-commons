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

{{- /* images: optional per-component digests */ -}}
{{- range $c, $d := ($v.image.digests | default dict) -}}
{{- if not (has $c (list "auth" "backend" "frontend" "background-services" "scrapers" "database")) -}}
{{- fail (printf "image.digests.%s: unknown component (auth, backend, frontend, background-services, scrapers, database)." $c) -}}
{{- end -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" (toString $d)) -}}
{{- fail (printf "image.digests.%s=%q must look like sha256:<64 lowercase hex digits>." $c (toString $d)) -}}
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
{{- /* PLANT-COMMONS: with the external database the two database passwords are not part of this Secret */ -}}
{{- $needed := list "POSTGRES_PASSWORD" "POSTGRES_AUTHENTICATOR_PASSWORD" "PGRST_JWT_SECRET" "AUTH_ORCID_CLIENT_SECRET" -}}
{{- if not $v.database.enabled -}}{{- $needed = list "PGRST_JWT_SECRET" "AUTH_ORCID_CLIENT_SECRET" -}}{{- end -}}
{{- range $k := $needed -}}
{{- if not (index $v.secrets.values $k) -}}{{- fail (printf "secrets.create=true needs secrets.values.%s" $k) -}}{{- end -}}
{{- end -}}
{{- range $k := without $needed "AUTH_ORCID_CLIENT_SECRET" -}}
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
{{- /* PLANT-COMMONS: external database. TLS with verification is the only mode (the cluster rejects the rest). */ -}}
{{- if not $v.database.enabled -}}
{{- $e := $v.externalDatabase -}}
{{- if not (has (toString $e.sslMode) (list "verify-full" "verify-ca")) -}}
{{- fail (printf "externalDatabase.sslMode=%q is not allowed: verify-full or verify-ca only (the platform database rejects unencrypted connections and an unverified TLS connection is no protection)." (toString $e.sslMode)) -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$" (toString $e.host)) -}}
{{- fail "externalDatabase.host must be a DNS name (e.g. plant-commons-pg-rw)." -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9-]+$" (toString $e.name)) -}}
{{- fail "externalDatabase.name must match [a-z0-9-]+." -}}
{{- end -}}
{{- if not (regexMatch "^[a-z_][a-z0-9_]*$" (toString $e.user)) -}}
{{- fail "externalDatabase.user must be a role name ([a-z_][a-z0-9_]*)." -}}
{{- end -}}
{{- range $k, $name := dict "caSecret.name" $e.caSecret.name "caSecret.key" $e.caSecret.key "ownerSecret.name" $e.ownerSecret.name "ownerSecret.passwordKey" $e.ownerSecret.passwordKey "authenticatorSecret.name" $e.authenticatorSecret.name "authenticatorSecret.key" $e.authenticatorSecret.key -}}
{{- if not $name -}}{{- fail (printf "externalDatabase.%s is required with database.enabled=false." $k) -}}{{- end -}}
{{- end -}}
{{- if and $v.secrets.create (or $v.secrets.values.POSTGRES_PASSWORD $v.secrets.values.POSTGRES_AUTHENTICATOR_PASSWORD) -}}
{{- fail "secrets.values.POSTGRES_PASSWORD / POSTGRES_AUTHENTICATOR_PASSWORD are for database.enabled=true only; with the external database they come from externalDatabase.ownerSecret / authenticatorSecret." -}}
{{- end -}}
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
{{- if not $v.networkPolicy.egress.dns -}}
{{- fail "networkPolicy.egress.enabled needs networkPolicy.egress.dns (CoreDNS peers): without DNS nothing resolves." -}}
{{- end -}}
{{- if and (not $v.database.enabled) (not $v.networkPolicy.egress.database) -}}
{{- fail "networkPolicy.egress.enabled with database.enabled=false needs networkPolicy.egress.database (peers of the external database pods, port 5432)." -}}
{{- end -}}
{{- if not $v.networkPolicy.egress.internet.cidr -}}
{{- fail "networkPolicy.egress.internet.cidr is required (auth needs https to orcid.org)." -}}
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
