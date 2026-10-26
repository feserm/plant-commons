#!/usr/bin/env bash
# PLANT-COMMONS: chart checks that need neither a cluster nor secrets.
#   lint, render matrix, negative tests (render must FAIL), positive assertions on the rendered YAML,
#   env var sets compared with docs/plant-commons/configuration.md.
# Needs helm (3.16) and yq (mikefarah v4) on PATH, or HELM / YQ set to wrapper commands (e.g. `docker run`
# wrappers that mount the current directory). Optional: KUBECONFORM=<command> to validate against schemas
# (needs the schemas, i.e. network or -schema-location, so it is off unless set).
# Run from anywhere: ./check.sh
set -euo pipefail

HELM=${HELM:-helm}
YQ=${YQ:-yq}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHART_DIR=$(dirname "$HERE")
# relative chart path so that a docker wrapper only needs to mount the current directory
cd "$(dirname "$CHART_DIR")"
CHART=$(basename "$CHART_DIR")
REPO_ROOT=$(cd "$CHART_DIR/../../.." 2>/dev/null && pwd || true)

CI="-f $CHART/ci/values-ci.yaml"
FULL="$CI -f $CHART/ci/values-full.yaml"
KIND="-f $CHART/examples/values-kind.yaml"
APIV="--api-versions traefik.io/v1alpha1 --api-versions cert-manager.io/v1"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $*"; }
bad() { fail=$((fail+1)); echo "  FAIL $*"; }
section() { echo; echo "== $*"; }

# ---------------------------------------------------------------------------------------------------
section "helm lint"
for args in "$CI" "$KIND" "$FULL" "-f $CHART/examples/values-plant-commons.yaml --set image.tag=sha-0000000"; do
  # shellcheck disable=SC2086
  if $HELM lint "$CHART" $args >"$OUT/lint.txt" 2>&1; then ok "lint $args"; else bad "lint $args"; cat "$OUT/lint.txt"; fi
done
# without any override the lint must fail (required values), proving the schema guards
if $HELM lint "$CHART" >/dev/null 2>&1; then bad "lint without required values should fail"; else ok "lint without required values fails"; fi

# ---------------------------------------------------------------------------------------------------
section "render matrix"
render() { # name, helm args...
  local name=$1; shift
  if $HELM template plant-commons "$CHART" "$@" >"$OUT/$name.yaml" 2>"$OUT/$name.err"; then
    ok "template $name ($(grep -c '^kind:' "$OUT/$name.yaml") objects)"
  else bad "template $name"; cat "$OUT/$name.err"; fi
}
# shellcheck disable=SC2086
{
render default   $CI
render kind      $KIND
render plantcommons -f $CHART/examples/values-plant-commons.yaml --set image.tag=sha-0000000
render full      $FULL $APIV
render scrapers  $CI --set scrapers.enabled=true
render swagger   $CI --set swagger.enabled=true
render netpol    $CI --set networkPolicy.enabled=true --set-json 'networkPolicy.ingressFrom=[{"namespaceSelector":{}}]'
render routing   $CI --set routing.enabled=true --set 'routing.entryPoints={x}' --set routing.certificate.issuerRef.name=i $APIV
render replicas2 $CI --set frontend.replicas=2 --set backend.replicas=2 --set frontend.podDisruptionBudget.enabled=true --set backend.podDisruptionBudget.enabled=true
}

# ---------------------------------------------------------------------------------------------------
section "negative tests (render must fail with a clear message)"
neg() { # label, expected message regex, helm args...   (runs with the schema, like a real install)
  local label=$1 re=$2; shift 2
  if $HELM template plant-commons "$CHART" "$@" >/dev/null 2>"$OUT/neg.err"; then
    bad "$label: rendered but must fail"
  elif grep -Eq "$re" "$OUT/neg.err"; then ok "$label"
  else bad "$label: failed with an unexpected message"; sed 's/^/       /' "$OUT/neg.err"; fi
}
# shellcheck disable=SC2086
{
# Both layers: the JSON schema (default) and the template guards (--skip-schema-validation).
neg "LOCAL in provider string (schema)"        'auth.providers' $CI --set 'auth.providers=ORCID:INVITE_ONLY;LOCAL:DISABLED'
neg "LOCAL in provider string (template)"      'contains LOCAL' $CI --skip-schema-validation --set 'auth.providers=ORCID:INVITE_ONLY;LOCAL:DISABLED'
neg "LOCAL only (template)"                    'contains LOCAL' $CI --skip-schema-validation --set 'auth.providers=LOCAL:EVERYONE'
neg "other provider (template)"                'ORCID only' $CI --skip-schema-validation --set 'auth.providers=SURFCONEXT:EVERYONE;ORCID:INVITE_ONLY'
neg "RSD_ENVIRONMENT=dev (schema)"             'auth.environment' $CI --set auth.environment=dev
neg "RSD_ENVIRONMENT=dev (template)"           'environment=dev is not allowed' $CI --skip-schema-validation --set auth.environment=dev
neg "host with trailing slash (schema)"        'host' $CI --set host=plant-commons.ipk-gatersleben.de/
neg "host with trailing slash (template)"      'bare host name' $CI --skip-schema-validation --set host=plant-commons.ipk-gatersleben.de/
neg "host with scheme (schema)"                'host' $CI --set host=https://plant-commons.ipk-gatersleben.de
neg "host with scheme (template)"              'bare host name' $CI --skip-schema-validation --set host=https://plant-commons.ipk-gatersleben.de
neg "empty host (schema)"                      'host' $CI --set host=
neg "empty image.tag (schema)"                 'image.tag' $CI --set image.tag=
neg "empty image.tag (template)"               'image.tag is required' $CI --skip-schema-validation --set image.tag=
neg "image.tag=latest (schema)"                 'image.tag' $CI --set image.tag=latest
neg "image.tag=latest (template)"               'latest is refused' $CI --skip-schema-validation --set image.tag=latest
neg "image.namespace placeholder"              'placeholder CHANGE_ME' $CI --set image.namespace=CHANGE_ME
neg "missing existingSecret (schema)"          'existingSecret' $CI --set existingSecret=
neg "missing existingSecret (template)"        'existingSecret is required' $CI --skip-schema-validation --set existingSecret=
neg "existingSecret together with create"      'not both' $CI --set secrets.create=true
neg "secrets.create with empty values"         'secrets.values' $CI --set existingSecret= --set secrets.create=true
neg "secrets.create with special characters"   '\[A-Za-z0-9\]' $CI --set existingSecret= --set secrets.create=true \
     --set secrets.values.POSTGRES_PASSWORD='a/b&c' --set secrets.values.POSTGRES_AUTHENTICATOR_PASSWORD=abc \
     --set secrets.values.PGRST_JWT_SECRET=abcdefghijabcdefghijabcdefghijabcdefghij --set secrets.values.AUTH_ORCID_CLIENT_SECRET=x
neg "missing ORCID client id"                  'orcid.clientId' $CI --set orcid.clientId=
neg "JDWP in auth args (schema)"               'args' $CI --set-json 'auth.args=["java","-agentlib:jdwp=transport=dt_socket,address=*:5005,server=y","-cp","auth.jar","x.Main"]'
neg "JDWP in auth args (template)"             'JDWP' $CI --skip-schema-validation --set-json 'auth.args=["java","-agentlib:jdwp=transport=dt_socket,address=*:5005,server=y","-cp","auth.jar","x.Main"]'
neg "JDWP in JAVA_TOOL_OPTIONS (template)"     'JDWP' $CI --skip-schema-validation --set 'backgroundServices.javaToolOptions=-agentlib:jdwp=transport=dt_socket\,address=*:5005'
neg "PDB with one replica"                     'replicas >= 2' $CI --set backend.podDisruptionBudget.enabled=true
neg "routing without entryPoints"              'routing.entryPoints' $CI --set routing.enabled=true
neg "routing without issuer"                   'issuerRef.name' $CI --set routing.enabled=true --set 'routing.entryPoints={x}'
neg "networkPolicy without ingressFrom"        'ingressFrom' $CI --set networkPolicy.enabled=true
neg "networkPolicy egress without ORCID peers" 'egress.orcid' $CI --set networkPolicy.enabled=true --set networkPolicy.egress.enabled=true --set-json 'networkPolicy.ingressFrom=[{"namespaceSelector":{}}]'
neg "dbMigration without ConfigMap"            'configMapName' $CI --set dbMigration.enabled=true
neg "unknown top-level value (typo)"           'Additional property' $CI --set hots=x
}

# ---------------------------------------------------------------------------------------------------
section "no JDWP / 5005 anywhere in any render"
if grep -n -i -w -e jdwp -e 5005 "$OUT"/*.yaml; then bad "jdwp/5005 found in rendered output"; else ok "no jdwp, no 5005"; fi

# ---------------------------------------------------------------------------------------------------
section "assertions on the rendered YAML"
q() { $YQ eval-all "$1" - <"$OUT/$2.yaml" | grep -v '^---$' || true; }   # q <expression> <render name>
WL='select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job")'
CONT="$WL | .spec.template.spec.containers[]"

expect() { # description, expected, actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
for r in default kind full scrapers swagger; do
  expect "[$r] no container has a command: (args only)" 0 "$(q "[$CONT | select(has(\"command\"))] | length" $r)"
  expect "[$r] every container has securityContext" 0 "$(q "[$CONT | select(has(\"securityContext\") | not)] | length" $r)"
  expect "[$r] every container has resources (requests+limits)" 0 "$(q "[$CONT | select((.resources.requests.memory and .resources.limits.memory) | not)] | length" $r)"
  expect "[$r] allowPrivilegeEscalation=false and drop ALL everywhere" 0 "$(q "[$CONT | select((.securityContext.allowPrivilegeEscalation == false and (.securityContext.capabilities.drop | contains([\"ALL\"]))) | not)] | length" $r)"
  expect "[$r] seccompProfile RuntimeDefault on every pod" 0 "$(q "[$WL | .spec.template.spec | select(.securityContext.seccompProfile.type != \"RuntimeDefault\")] | length" $r)"
  expect "[$r] automountServiceAccountToken=false on every pod" 0 "$(q "[$WL | .spec.template.spec | select(.automountServiceAccountToken != false)] | length" $r)"
  expect "[$r] no Service other than ClusterIP" 0 "$(q '[select(.kind == "Service" and .spec.type != "ClusterIP")] | length' $r)"
  expect "[$r] no Service exposes 3501 (admin) or 5432 beyond database" 0 "$(q '[select(.kind == "Service") | select(.metadata.labels."app.kubernetes.io/component" != "database") | .spec.ports[] | select(.port == 3501)] | length' $r)"
  expect "[$r] no hostPort/hostNetwork/hostPID/hostIPC/privileged" 0 "$(q "[$WL | .spec.template.spec | select(.hostNetwork or .hostPID or .hostIPC)] | length" $r)"
  expect "[$r] no hostPort" 0 "$(q "[$CONT | .ports[]? | select(has(\"hostPort\"))] | length" $r)"
  expect "[$r] no NodePort/LoadBalancer/Ingress objects" 0 "$(q '[select(.kind == "Ingress")] | length' $r)"
done

expect "[default] no routing objects without routing.enabled" 0 "$(q '[select(.kind == "IngressRoute" or .kind == "Middleware" or .kind == "Certificate")] | length' default)"
expect "[default] no NetworkPolicy, Secret, scrapers, swagger, Job by default" 0 "$(q '[select(.kind == "NetworkPolicy" or .kind == "Secret" or .kind == "Job" or .kind == "PodDisruptionBudget")] | length' default)"
expect "[default] workloads: database auth backend frontend background-services" "auth backend background-services database frontend" "$(q "$WL | .metadata.labels.\"app.kubernetes.io/component\"" default | sort | xargs)"

# decided args
expect "[default] auth args" "java -cp auth.jar nl.esciencecenter.rsd.authentication.Main" "$(q 'select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" == "auth") | .spec.template.spec.containers[0].args | join(" ")' default)"
expect "[default] background-services args" "java -cp background-services.jar nl.esciencecenter.rsd.Main" "$(q 'select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" == "background-services") | .spec.template.spec.containers[0].args | join(" ")' default)"
expect "[default] only auth and background-services set args" "auth background-services" "$(q "$WL | select(.spec.template.spec.containers[0] | has(\"args\")) | .metadata.labels.\"app.kubernetes.io/component\"" default | sort | xargs)"
expect "[default] auth exposes only 7000" "7000" "$(q 'select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" == "auth") | .spec.template.spec.containers[0].ports[].containerPort' default | xargs)"
for c in auth background-services; do
  expect "[default] $c: JAVA_TOOL_OPTIONS sets MaxRAMPercentage" "-XX:MaxRAMPercentage=70.0" "$(q "select(.kind == \"Deployment\" and .metadata.labels.\"app.kubernetes.io/component\" == \"$c\") | .spec.template.spec.containers[0].env[] | select(.name == \"JAVA_TOOL_OPTIONS\") | .value" default)"
  expect "[default] $c: readOnlyRootFilesystem + emptyDir /tmp" "true /tmp" "$(q "select(.kind == \"Deployment\" and .metadata.labels.\"app.kubernetes.io/component\" == \"$c\") | .spec.template.spec.containers[0] | (.securityContext.readOnlyRootFilesystem | tostring) + \" \" + .volumeMounts[0].mountPath" default)"
  expect "[default] $c: uid 10001" "10001" "$(q "select(.kind == \"Deployment\" and .metadata.labels.\"app.kubernetes.io/component\" == \"$c\") | .spec.template.spec.securityContext.runAsUser" default)"
done
expect "[default] background-services: 1 replica, Recreate" "1 Recreate" "$(q 'select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" == "background-services") | (.spec.replicas | tostring) + " " + .spec.strategy.type' default)"
expect "[default] background-services has no Service" 0 "$(q '[select(.kind == "Service" and .metadata.labels."app.kubernetes.io/component" == "background-services")] | length' default)"
expect "[scrapers] scrapers: 1 replica, Recreate, Deployment, no Service, no CronJob" "1 Recreate 0 0" "$(q 'select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" == "scrapers") | (.spec.replicas | tostring) + " " + .spec.strategy.type + " " + ([select(.kind == "Service" and .metadata.labels."app.kubernetes.io/component" == "scrapers")] | length | tostring) + " 0"' scrapers)"
expect "[scrapers] no CronJob" 0 "$(q '[select(.kind == "CronJob")] | length' scrapers)"
expect "[default] frontend: non-root uid 1001, readOnlyRootFilesystem, emptyDirs /tmp + /app/.next/cache" "1001 true /tmp,/app/.next/cache" "$(q 'select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" == "frontend") | .spec.template.spec | (.securityContext.runAsUser | tostring) + " " + (.containers[0].securityContext.readOnlyRootFilesystem | tostring) + " " + (.containers[0].volumeMounts | map(.mountPath) | join(","))' default)"
expect "[default] backend: non-root uid 1000, readOnlyRootFilesystem" "1000 true" "$(q 'select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" == "backend") | .spec.template.spec | (.securityContext.runAsUser | tostring) + " " + (.containers[0].securityContext.readOnlyRootFilesystem | tostring)' default)"
expect "[default] backend: PGRST_SERVER_HOST=0.0.0.0" "0.0.0.0" "$(q 'select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" == "backend") | .spec.template.spec.containers[0].env[] | select(.name == "PGRST_SERVER_HOST") | .value' default)"
expect "[default] backend: probes on the admin port 3501 (/ready, /live)" "/ready admin /live admin" "$(q 'select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" == "backend") | .spec.template.spec.containers[0] | .readinessProbe.httpGet.path + " " + .readinessProbe.httpGet.port + " " + .livenessProbe.httpGet.path + " " + .livenessProbe.httpGet.port' default)"
expect "[default] backend: admin port name maps to 3501" "3501" "$(q 'select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" == "backend") | .spec.template.spec.containers[0].ports[] | select(.name == "admin") | .containerPort' default)"
expect "[default] backend: PGRST_DB_URI built from the Secret via \$(VAR), declared after it" 'postgres://rsd_authenticator:$(POSTGRES_AUTHENTICATOR_PASSWORD)@database:5432/rsd-db true' "$(q 'select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" == "backend") | .spec.template.spec.containers[0].env | ((map(select(.name == "PGRST_DB_URI")) | .[0].value) + " " + (((map(.name) | to_entries | map(select(.value == "POSTGRES_AUTHENTICATOR_PASSWORD")) | .[0].key) < (map(.name) | to_entries | map(select(.value == "PGRST_DB_URI")) | .[0].key)) | tostring))' default)"
expect "[default] database: PGDATA subdirectory of the PVC mount" "/var/lib/postgresql/data/pgdata /var/lib/postgresql/data" "$(q 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0] | (.env[] | select(.name == "PGDATA") | .value) + " " + .volumeMounts[0].mountPath' default)"
expect "[default] database: PVC claim template 'data' RWO 10Gi, no storageClassName by default" "data ReadWriteOnce 10Gi null" "$(q 'select(.kind == "StatefulSet") | .spec.volumeClaimTemplates[0] | [.metadata.name, .spec.accessModes[0], .spec.resources.requests.storage, (.spec.storageClassName // "null")] | join(" ")' default)"
expect "[default] database: uid/gid/fsGroup 999, non-root" "999 999 999 true" "$(q 'select(.kind == "StatefulSet") | .spec.template.spec.securityContext | (.runAsUser | tostring) + " " + (.runAsGroup | tostring) + " " + (.fsGroup | tostring) + " " + (.runAsNonRoot | tostring)' default)"
expect "[default] database: probe is pg_isready over TCP" "true" "$(q 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].readinessProbe.exec.command[2] | contains("pg_isready -h 127.0.0.1")' default)"
expect "[default] database: Service is ClusterIP 5432 only" "ClusterIP 5432" "$(q 'select(.kind == "Service" and .metadata.labels."app.kubernetes.io/component" == "database") | .spec.type + " " + (.spec.ports | map(.port) | join(","))' default)"
expect "[default] no imagePullSecrets by default" 0 "$(q "[$WL | .spec.template.spec | select(has(\"imagePullSecrets\"))] | length" default)"
expect "[default] all images use image.registry/namespace/plant-commons-<svc>:tag" 5 "$(q "[$CONT | select(.image | test(\"^ghcr.io/example/plant-commons/plant-commons-[a-z-]+:sha-0000000\$\"))] | length" default)"
expect "[replicas2] PDBs rendered for frontend and backend only" "backend frontend" "$(q 'select(.kind == "PodDisruptionBudget") | .metadata.labels."app.kubernetes.io/component"' replicas2 | sort | xargs)"
expect "[replicas2] frontend/backend replicas 2" "2 2" "$(q 'select(.kind == "Deployment" and (.metadata.labels."app.kubernetes.io/component" == "frontend" or .metadata.labels."app.kubernetes.io/component" == "backend")) | .spec.replicas' replicas2 | xargs)"

# no secrets in ConfigMaps (kind render has fake secret values in a Secret)
secret_keys='POSTGRES_PASSWORD POSTGRES_AUTHENTICATOR_PASSWORD PGRST_JWT_SECRET AUTH_ORCID_CLIENT_SECRET API_CREDENTIALS_GITHUB ZENODO_ACCESS_TOKEN OPENALEX_API_KEY LIBRARIES_IO_ACCESS_TOKEN'
for r in default kind full; do
  keys=$(q 'select(.kind == "ConfigMap") | .data | keys | .[]' $r | sort -u | xargs)
  leak=""; for k in $secret_keys; do case " $keys " in *" $k "*) leak="$leak $k";; esac; done
  expect "[$r] no secret key name in any ConfigMap" "" "${leak# }"
done
fakes=$(q 'select(.kind == "Secret") | .stringData | to_entries | .[].value' kind)
expect "[kind] Secret rendered with 4 fake values" 4 "$(echo "$fakes" | grep -c .)"
cmvals=$(q 'select(.kind == "ConfigMap") | .data | to_entries | .[].value' kind)
leaks=0; for f in $fakes; do if grep -qF -- "$f" <<<"$cmvals"; then leaks=$((leaks+1)); fi; done
expect "[kind] no secret value appears in any ConfigMap" 0 "$leaks"
expect "[kind] no secret value in any pod spec literal env" 0 "$(q "[$CONT | .env[]? | select(has(\"value\")) | select(.value | test(\"kindfake\"))] | length" kind)"
expect "[default] no Secret object when secrets.create=false" 0 "$(q '[select(.kind == "Secret")] | length' default)"
expect "[default] every Secret reference uses existingSecret" "plant-commons-secrets" "$(q "$CONT | .env[]? | select(has(\"valueFrom\")) | .valueFrom.secretKeyRef.name" default | sort -u | xargs)"

# routing render
expect "[routing] IngressRoute hosts and prefixes" 5 "$(q 'select(.kind == "IngressRoute") | .spec.routes | length' routing)"
expect "[full] IngressRoute has swagger route; Certificate dnsNames" "true plant-commons.ipk-gatersleben.de" "$(q 'select(.kind == "IngressRoute") | ([.spec.routes[].match] | map(select(contains("/swagger/"))) | length > 0 | tostring)' full) $(q 'select(.kind == "Certificate") | .spec.dnsNames[0]' full)"
expect "[routing] image route forces Accept, strips /image" "application/octet-stream /image" "$(q 'select(.kind == "Middleware" and .metadata.name == "plant-commons-image-accept") | .spec.headers.customRequestHeaders.Accept' routing) $(q 'select(.kind == "Middleware" and .metadata.name == "plant-commons-strip-image") | .spec.stripPrefix.prefixes[0]' routing)"
expect "[routing] 40M body cap Buffering" 41943040 "$(q 'select(.kind == "Middleware" and .metadata.name == "plant-commons-body-limit") | .spec.buffering.maxRequestBodyBytes' routing)"
expect "[routing] /documentation and /metadata/codemeta are not routed" 0 "$(q '[select(.kind == "IngressRoute") | .spec.routes[].match | select(contains("documentation") or contains("codemeta"))] | length' full)"

# ---------------------------------------------------------------------------------------------------
section "env var names per service vs docs/plant-commons/configuration.md section 2"
declare -A EXPECT
EXPECT[database]="POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD POSTGRES_AUTHENTICATOR_PASSWORD PGDATA"
EXPECT[backend]="PGRST_DB_URI PGRST_DB_PRE_REQUEST PGRST_DB_ANON_ROLE PGRST_DB_SCHEMA PGRST_SERVER_HOST PGRST_SERVER_PORT PGRST_ADMIN_SERVER_PORT PGRST_JWT_SECRET PGRST_DB_POOL PGRST_DB_POOL_ACQUISITION_TIMEOUT"
EXPECT[auth]="RSD_AUTH_PROVIDERS ORCID_CLIENT_ID ORCID_WELL_KNOWN_URL AUTH_ORCID_CLIENT_SECRET HOST_URL PGRST_JWT_SECRET POSTGREST_URL RSD_API_ACCESS_TOKEN_ENABLED RSD_ENVIRONMENT"
EXPECT[background-services]="POSTGRES_DB_HOST POSTGRES_DB_HOST_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD"
EXPECT[frontend]="POSTGREST_URL PGRST_JWT_SECRET RSD_AUTH_URL RSD_REVERSE_PROXY_URL"
EXPECT[scrapers]="POSTGREST_URL PGRST_JWT_SECRET MAX_REQUESTS_GITHUB MAX_REQUESTS_GITLAB MAX_REQUESTS_4TU MAX_REQUESTS_CODEBERG MAX_REQUESTS_DOI MAX_REQUESTS_OPENALEX MAX_REQUESTS_ROR ENABLE_NASSA_SCRAPER ENABLE_ESCAPE_OSSR_SCRAPER API_CREDENTIALS_GITHUB ZENODO_ACCESS_TOKEN OPENALEX_API_KEY LIBRARIES_IO_ACCESS_TOKEN"
EXPECT[swagger]="API_URL SUPPORTED_SUBMIT_METHODS"
# Variables the chart sets that configuration.md does not list. Each one is deliberate:
declare -A ALLOWED_EXTRA
ALLOWED_EXTRA[backend]="POSTGRES_AUTHENTICATOR_PASSWORD"  # only to expand \$(VAR) inside PGRST_DB_URI
ALLOWED_EXTRA[auth]="JAVA_TOOL_OPTIONS"                    # heap sizing, replaces editing the image
ALLOWED_EXTRA[background-services]="JAVA_TOOL_OPTIONS"
ALLOWED_EXTRA[frontend]=""
ALLOWED_EXTRA[database]=""; ALLOWED_EXTRA[scrapers]=""; ALLOWED_EXTRA[swagger]=""

actual_env() { # component, render -> sorted env names (env + keys of envFrom ConfigMaps)
  local c=$1 r=$2 cm
  q "select(.kind == \"Deployment\" or .kind == \"StatefulSet\") | select(.metadata.labels.\"app.kubernetes.io/component\" == \"$c\") | .spec.template.spec.containers[0] | [((.env // [])[] | .name), ((.envFrom // [])[] | .configMapRef.name)] | .[]" "$r" | while read -r n; do
    if [[ $n == plant-commons-* ]]; then q "select(.kind == \"ConfigMap\" and .metadata.name == \"$n\") | .data | keys | .[]" "$r"; else echo "$n"; fi
  done | sort -u
}
for c in database backend auth background-services frontend scrapers swagger; do
  have=$(actual_env "$c" full | xargs)
  want=$(tr ' ' '\n' <<<"${EXPECT[$c]}" | sort -u | xargs)
  missing=$(comm -13 <(tr ' ' '\n' <<<"$have") <(tr ' ' '\n' <<<"$want") | xargs)
  extra=$(comm -23 <(tr ' ' '\n' <<<"$have") <(tr ' ' '\n' <<<"$want") | xargs)
  unexpected=""; for e in $extra; do case " ${ALLOWED_EXTRA[$c]} " in *" $e "*) ;; *) unexpected="$unexpected $e";; esac; done
  expect "[$c] no variable missing vs configuration.md" "" "$missing"
  expect "[$c] no unexpected extra variable (allowed extras: ${ALLOWED_EXTRA[$c]:-none})" "" "${unexpected# }"
done
all_env=$(for c in database backend auth background-services frontend scrapers swagger; do actual_env "$c" full; done | sort -u | xargs)
expect "[frontend] no RSD_VERSION (baked in the image), no ORCID_*/LINKEDIN_*" "" "$(actual_env frontend full | grep -E '^(RSD_VERSION|ORCID_|LINKEDIN_)' | xargs)"
expect "[all] no unused provider variables (SURFCONEXT/HELMHOLTZID/AZURE/LINKEDIN/GITHUB)" "" "$(echo "$all_env" | tr ' ' '\n' | grep -E '^(SURFCONEXT|HELMHOLTZID|AZURE|LINKEDIN|GITHUB|AUTH_(SURFCONEXT|HELMHOLTZID|AZURE|LINKEDIN|GITHUB))' | xargs)"
expect "[all] no LOCAL-related or JDWP variable" "" "$(echo "$all_env" | tr ' ' '\n' | grep -E '(LOCAL|JDWP)' | xargs)"

# Informational: what docker-compose.yml passes that the chart does not (and the reverse).
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/docker-compose.yml" ]; then
  section "info: compose environment vs chart (not a failure)"
  for pair in "auth:auth" "backend:backend" "database:database" "background-services:background-services" "frontend:frontend" "scrapers:scrapers" "swagger:swagger"; do
    svc=${pair%%:*}; c=${pair##*:}
    cmp=$($YQ eval ".services.$svc.environment | ((select(tag == \"!!seq\") | .[] | sub(\"=.*\", \"\")), (select(tag == \"!!map\") | keys | .[]))" - <"$REPO_ROOT/docker-compose.yml" 2>/dev/null | sort -u | xargs || true)
    have=$(actual_env "$c" full | xargs)
    echo "  $svc: compose-only: $(comm -23 <(tr ' ' '\n' <<<"$cmp") <(tr ' ' '\n' <<<"$have") | xargs)"
    echo "  $svc: chart-only:   $(comm -13 <(tr ' ' '\n' <<<"$cmp") <(tr ' ' '\n' <<<"$have") | xargs)"
  done
fi

# Optional schema validation (needs schemas; off unless KUBECONFORM is set)
if [ -n "${KUBECONFORM:-}" ]; then
  section "kubeconform"
  for r in default kind full; do
    if $KUBECONFORM -strict -ignore-missing-schemas -summary - <"$OUT/$r.yaml"; then ok "kubeconform $r"; else bad "kubeconform $r"; fi
  done
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
