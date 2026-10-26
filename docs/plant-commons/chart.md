# Plant Commons: Helm chart reference

Phase 5, adapted to the target platform (PDB, RKE2 at de.NBI Bielefeld) in Phase 6 (section 11). Chart: [`deploy/helm/plant-commons/`](../../deploy/helm/plant-commons/) (version 0.1.0, appVersion 6.7.4, short
README next to it). **Nothing was applied to a cluster**: the chart was linted, rendered and checked with
`deploy/helm/plant-commons/ci/check.sh` (helm 3.16.2 and yq 4.44.3 from local images), and several container
settings were measured with plain `docker run` (section 8). Companion docs: [services.md](services.md),
[configuration.md](configuration.md), [routing.md](routing.md), [images.md](images.md).

## 1. How the chart maps to the other docs

| Doc | What the chart takes from it |
|---|---|
| services.md | Which services exist: database (StatefulSet+PVC, **only with `database.enabled=true`; the platform uses an external CloudNativePG cluster**, [database.md](database.md)), backend, auth, frontend, background-services always; scrapers (1-replica Deployment running cron) and swagger optional; codemeta, mail stack, documentation, nginx not implemented. ClusterIP only; no 5005, no published DB port. Probes, `PGRST_SERVER_HOST=0.0.0.0`, PGDATA subdirectory, no JDWP. |
| configuration.md | Every env var. "Source = ConfigMap" rows go into one ConfigMap per service (`templates/_config.tpl`), "Secret" rows are single `secretKeyRef` entries (key name = variable name), "chart" rows are literals in the pod spec (`PGRST_DB_URI`, `PGRST_DB_PRE_REQUEST`, `PGRST_SERVER_HOST`, `PGRST_DB_POOL*`, `PGDATA`). `ci/check.sh` diffs the rendered env names against these tables (section 7). |
| routing.md | **On the platform the chart renders no routing**: [`deploy/routing/routes.yaml`](../../deploy/routing/routes.yaml) (derived from routing.md) is taken over by the platform's service registry. `templates/routing.yaml` (optional, off, untested): Traefik `IngressRoute` + `Middleware` (StripPrefix `/api/v1`, `/image`, `/swagger`; request header `Accept: application/octet-stream` on `/image`; Buffering 40M on `/api/v1` and `/api/v2`; `/auth` and `/api/v2` prefixes kept) and a cert-manager `Certificate`. Compress and the `Content-Location` handling are not implemented (optional/dropped in routing.md). |
| database.md | External database mode: TLS, `deploy/postgres/init.sql`, roles, owner rights. |
| images.md | Image names `<registry>/<namespace>/plant-commons-<service>:<tag>[@<digest>]` with one `image.tag` (the `sha-<short sha>` tag) and optional per-component `image.digests`; exec-form `args` for auth and background-services (6.1); the measured uid/securityContext table (6). |

## 2. Values

Defaults are in [`values.yaml`](../../deploy/helm/plant-commons/values.yaml); each value there is commented with its source.
[`values.schema.json`](../../deploy/helm/plant-commons/values.schema.json) rejects unknown keys and the unsafe values at lint time, and
`templates/_validate.tpl` repeats the security-relevant checks at render time (they also hold with `--skip-schema-validation`).

**Required for a real install** (no usable default): `image.tag`, `existingSecret`, `orcid.clientId`; on the platform also `database.enabled=false` (then `externalDatabase`
has working defaults for the platform's names).

### General

| Value | Default | Purpose |
|---|---|---|
| `host` | `plant-commons.ipk-gatersleben.de` | Bare host name (no scheme/path/trailing slash; both schema and template refuse anything else). Derives `HOST_URL=https://<host>`, `RSD_REVERSE_PROXY_URL`, swagger `API_URL`, the route host and certificate name. |
| `image.registry` | `ghcr.io` | Registry host. |
| `image.namespace` | `feserm/plant-commons` | Path below the registry (confirmed); the placeholder `CHANGE_ME` is still refused. |
| `image.tag` | `""` (required) | `sha-<short sha>` for all services; `latest` refused. |
| `image.digests.<component>` | `{}` | Optional pin per component (`auth`, `backend`, `frontend`, `background-services`, `scrapers`, `database`; the last only for the migration Job / chart database). Rendered `repo:tag@sha256:...`; must match `sha256:<64 hex>`, unknown components refused. |
| `image.pullPolicy` | `IfNotPresent` | |
| `imagePullSecrets` | `[]` | Optional; public ghcr.io images need none. |
| `existingSecret` | `""` (required) | Name of the existing Secret (section 3): `PGRST_JWT_SECRET`, `AUTH_ORCID_CLIENT_SECRET` (+ the two database passwords only with `database.enabled=true`). |
| `secrets.create` / `secrets.values.*` | `false` / empty | **Local tests only**: renders a Secret from values (credentials end up in the Helm release secret). Refuses non-`[A-Za-z0-9]` values and a JWT secret under 32 characters; cannot be combined with `existingSecret`. |
| `orcid.clientId` | `""` (required) | Production ORCID client id (`APP-` + 16 characters). |
| `orcid.wellKnownUrl` | `https://orcid.org/.well-known/openid-configuration` | Production, not sandbox. |
| `urls.postgrest` | `""` | `POSTGREST_URL`; empty = `http://backend:3500` derived from the Service name and `backend.port`. |
| `serviceNamePrefix` | `""` | Prefix for Service names. Leave empty on the platform: Service names `frontend`, `backend`, `auth` (`swagger`, `database`) are independent of the release name and are what `deploy/routing/routes.yaml` refers to. |
| `nameOverride`, `fullnameOverride` | `""` | Usual Helm naming overrides (workloads are `<fullname>-<component>`; Services are the short names). |
| `nodeSelector`, `tolerations`, `affinity` | empty | Applied to all pods. None needed on the platform (control-plane nodes are tainted, workers are untainted). |

### Per service (`database`, `backend`, `auth`, `frontend`, `backgroundServices`, `scrapers`, `swagger`)

| Value | Default | Purpose |
|---|---|---|
| `database.enabled` | `true` | The chart's own PostgreSQL (StatefulSet, Service, PVC). **`false` on the platform**: nothing of it is rendered, `externalDatabase` is used. |
| `database.name`, `database.user` | `rsd-db`, `rsd` | `POSTGRES_DB`, `POSTGRES_USER` (ConfigMap) of the chart's own database. `name` must be `[a-z0-9-]`. |
| `database.persistence.size` | `10Gi` | PVC size (placeholder estimate; question 7). |
| `database.persistence.storageClass` | `""` | Empty = cluster default (question 7). |
| `database.persistence.accessModes` | `[ReadWriteOnce]` | |
| `database.terminationGracePeriodSeconds` | `120` | Time for the fast shutdown. |
| `backend.replicas` | `1` | 2 is possible (stateless). |
| `backend.dbAnonRole`, `dbSchema`, `port`, `adminPort` | `rsd_web_anon`, `public`, `3500`, `3501` | `PGRST_DB_ANON_ROLE`, `PGRST_DB_SCHEMA`, `PGRST_SERVER_PORT`, `PGRST_ADMIN_SERVER_PORT`. The admin port never gets a Service. |
| `backend.dbPool`, `dbPoolAcquisitionTimeout` | `30`, `30` | `PGRST_DB_POOL`, `PGRST_DB_POOL_ACQUISITION_TIMEOUT`. |
| `auth.replicas` | `1` | |
| `auth.providers` | `ORCID:INVITE_ONLY` | `RSD_AUTH_PROVIDERS`; only `ORCID:INVITE_ONLY` or `ORCID:EVERYONE` is accepted, `LOCAL` or anything else is refused. |
| `auth.environment` | `prod` | `RSD_ENVIRONMENT`; `dev` refused. |
| `auth.apiAccessTokenEnabled` | `true` | `RSD_API_ACCESS_TOKEN_ENABLED`; also controls the `/api/v2` route. |
| `auth.rsdAuthUrl` | `""` | `RSD_AUTH_URL` for the frontend; empty = `http://auth:7000/auth` (question 9). |
| `auth.args`, `backgroundServices.args` | the exec-form java commands (images.md 6.1) | Container `args`; JDWP/5005 refused. |
| `auth.javaToolOptions`, `backgroundServices.javaToolOptions` | `-XX:MaxRAMPercentage=70.0` | `JAVA_TOOL_OPTIONS`. |
| `frontend.replicas` | `1` | 2 is possible. |
| `frontend.crossrefContactEmail`, `matomoUrl`, `matomoId` | empty | Only emitted when set (Matomo needs both URL and id). |
| `<svc>.resources` | see values.yaml | `requests`/`limits`; memory **and CPU limit** are required (schema): without an explicit CPU limit the namespace LimitRange would impose 500m. Starting estimates, **not measured**. There are no init containers; the migration Job has `dbMigration.resources`. |
| `<svc>.podSecurityContext`, `<svc>.securityContext` | see values.yaml | The measured settings from images.md section 6; the schema requires `allowPrivilegeEscalation: false`, `drop: [ALL]` and a seccomp profile. |
| `<svc>.strategy` (frontend, backend, auth) | RollingUpdate, surge 1, unavailable 0 | background-services and scrapers are hard `Recreate`, 1 replica. |
| `<svc>.podDisruptionBudget` (frontend, backend, auth) | disabled, `minAvailable: 1` | Refuses to render with `replicas < 2`. |
| `<svc>.terminationGracePeriodSeconds` | 30 (120 database) | |
| `scrapers.enabled` | `false` | 1-replica Deployment running `cron -f`. |
| `scrapers.maxRequests.*`, `crossrefContactEmail` | `6` each | `MAX_REQUESTS_*`; `ENABLE_NASSA_SCRAPER`/`ENABLE_ESCAPE_OSSR_SCRAPER` are fixed `false`. Optional Secret keys: `API_CREDENTIALS_GITHUB`, `ZENODO_ACCESS_TOKEN`, `OPENALEX_API_KEY`, `LIBRARIES_IO_ACCESS_TOKEN`. |
| `swagger.enabled`, `swagger.image` | `false`, `swaggerapi/swagger-ui:v5.32.6` | Interactive API browser behind `/swagger/` (needs routing). |

### External database (`database.enabled=false`)

| Value | Default | Purpose |
|---|---|---|
| `externalDatabase.host`, `port` | `plant-commons-pg-rw`, `5432` | The CNPG read-write Service in the release namespace. |
| `externalDatabase.name`, `user` | `rsd-db`, `rsd` | Database and owner role. `user` is used only if `ownerSecret.usernameKey` is empty. |
| `externalDatabase.sslMode` | `verify-full` | `verify-full` or `verify-ca`; nothing weaker is accepted (the cluster rejects unencrypted connections). |
| `externalDatabase.caSecret` | `{name: plant-commons-pg-ca, key: ca.crt}` | CA certificate, mounted read-only at `/etc/plant-commons/db-ca/ca.crt` into backend, background-services and the migration Job. |
| `externalDatabase.ownerSecret` | `{name: plant-commons-pg-app, usernameKey: username, passwordKey: password}` | Owner credentials (generated by CNPG): background-services, migration Job. |
| `externalDatabase.authenticatorSecret` | `{name: plant-commons-pg-role-rsd-authenticator, key: password}` | Password of `rsd_authenticator` (platform, from the vault): backend only. |

All Secrets must exist in the release namespace before the pods start (a missing one shows up as `CreateContainerConfigError`). Details: [database.md](database.md).

### Optional parts

| Value | Default | Purpose |
|---|---|---|
| `dbMigration.enabled`, `name`, `configMapName`, `configMapKey`, `resources` | `false`, `manual`, `""`, `migration.sql`, 100m/128Mi req, 500m/256Mi limit | Opt-in **untested stub** Job running a user-supplied SQL ConfigMap through psql (README "Database upgrades"). With `database.enabled=false` it connects to `externalDatabase` as the owner over TLS (`PGSSLMODE`, `PGSSLROOTCERT`, `PGPASSWORD` from the owner Secret). Image: `plant-commons-database` (only for its psql). |
| `networkPolicy.enabled` | `false` | Default-deny ingress (and egress, below) + the allow rules that really exist (section 11.3). |
| `networkPolicy.ingressFrom` | Traefik peer: namespace `traefik` (label `kubernetes.io/metadata.name`), pods `app.kubernetes.io/name: traefik` | Required when enabled: `from` peers of the ingress controller. |
| `networkPolicy.egress.enabled` | `true` | Default-deny egress with allow rules (only effective when `networkPolicy.enabled`). |
| `networkPolicy.egress.dns` | kube-system / `k8s-app: kube-dns` | DNS peers, UDP+TCP 53, every pod. |
| `networkPolicy.egress.database` | `podSelector: cnpg.io/cluster=plant-commons-pg` | Peers of the external database pods, port 5432 (same namespace); ignored with `database.enabled=true` (then the chart's own pod). |
| `networkPolicy.egress.internet.cidr`, `.except` | `0.0.0.0/0`, the six private/internal ranges | TCP 443 for auth, frontend and (if enabled) scrapers. Replaces the former `egress.orcid`/`egress.scrapers` (removed). |
| `routing.enabled` | `false` | **Stays false on the platform.** Renders `templates/routing.yaml` (untested alternative). |
| `routing.apiVersion` | `traefik.io/v1alpha1` | Depends on the Traefik version. |
| `routing.entryPoints` | `[]` | Required when enabled. |
| `routing.annotations`, `routing.labels` | `{}` | Applied to IngressRoute, Middlewares, Certificate (placeholder for a service-registry scheme; none is invented). |
| `routing.maxRequestBodyBytes` | `41943040` | Buffering cap on `/api/v1`, `/api/v2`; `0` removes it. |
| `routing.tls.secretName` | `""` | Empty = `<fullname>-tls`. |
| `routing.certificate.enabled`, `.issuerRef.{name,kind,group}` | `true`, `""`/`ClusterIssuer`/`cert-manager.io` | `issuerRef.name` required when enabled. |

### Answered cluster inputs

`examples/values-plant-commons.yaml` holds them (Phase 6 state, section 11): images `ghcr.io/feserm/plant-commons`, `existingSecret: plant-commons-secrets`, ORCID client
`APP-T1MHJINJKL8PTMXA` (production, both redirect URIs registered), `database.enabled: false` with the CNPG `externalDatabase`, `routing.enabled: false`
(routes and certificate come from the platform's service registry via `deploy/routing/routes.yaml`), NetworkPolicies on with the real cluster values.
`image.tag` and `image.digests` are left empty (set per release). Still open: who owns the ORCID client / holds its secret, the first-admin iD.
The earlier `local-ephemeral` PVC storage class is obsolete (no PVC on the platform).

## 3. Secrets: creation

**On the platform all Secrets are created by the platform from its vault / by CNPG, never by hand and never committed.** They must exist in the release namespace:

| Secret | Created by | Keys | Used by |
|---|---|---|---|
| `plant-commons-secrets` (`existingSecret`) | platform, from its vault | `PGRST_JWT_SECRET` (>= 32 characters, `[A-Za-z0-9]`), `AUTH_ORCID_CLIENT_SECRET`; optional scraper keys `API_CREDENTIALS_GITHUB`, `ZENODO_ACCESS_TOKEN`, `OPENALEX_API_KEY`, `LIBRARIES_IO_ACCESS_TOKEN` | auth, backend, frontend, scrapers (each pod gets only the keys it needs) |
| `plant-commons-pg-app` (`externalDatabase.ownerSecret`) | CNPG | `username`, `password` (CNPG also adds `dbname`, `host`, `uri`, ...; unused) | background-services, migration Job |
| `plant-commons-pg-role-rsd-authenticator` (`externalDatabase.authenticatorSecret`) | platform, from its vault, as the password of the CNPG managed role `rsd_authenticator` | `password` (`[A-Za-z0-9]`, it is part of `PGRST_DB_URI`) | backend |
| `plant-commons-pg-ca` (`externalDatabase.caSecret`) | platform / CNPG | `ca.crt` | backend, background-services, migration Job (mounted read-only) |

The database passwords are **not** keys of `existingSecret` any more (they are with `database.enabled=true`, below). The chart cannot check that the keys exist before
install; a missing key shows up as `CreateContainerConfigError` on the pod. `PGRST_DB_URI` is **not** a Secret key: it is assembled in the backend pod spec as
`postgres://rsd_authenticator:$(POSTGRES_AUTHENTICATOR_PASSWORD)@plant-commons-pg-rw:5432/rsd-db?sslmode=verify-full&sslrootcert=/etc/plant-commons/db-ca/ca.crt`
(Kubernetes `$(VAR)` expansion), so the password exists in one place only. Rotation: the vault/CNPG side, then restart the backend.

**Chart's own database (`database.enabled=true`, kind/local only):** `existingSecret` additionally needs `POSTGRES_PASSWORD` and `POSTGRES_AUTHENTICATOR_PASSWORD`
(`[A-Za-z0-9]`, applied only at the first init, configuration.md section 5). Example, printed here, not run:

```bash
kubectl create namespace plant-commons
umask 077
openssl rand -hex 32 > pg.pw; openssl rand -hex 32 > auth-db.pw; openssl rand -hex 32 > jwt.secret
printf '%s' '<ORCID client secret>' > orcid.secret       # from ORCID; keep it out of shell history
kubectl -n plant-commons create secret generic plant-commons-secrets \
  --from-file=POSTGRES_PASSWORD=pg.pw \
  --from-file=POSTGRES_AUTHENTICATOR_PASSWORD=auth-db.pw \
  --from-file=PGRST_JWT_SECRET=jwt.secret \
  --from-file=AUTH_ORCID_CLIENT_SECRET=orcid.secret
shred -u pg.pw auth-db.pw jwt.secret orcid.secret
```

## 4. Install, upgrade, roll back (printed, never run by this repo)

```bash
# values you keep outside git, e.g. my-values.yaml:
#   image: {namespace: <owner>/<repo>, tag: sha-<short sha>}
#   existingSecret: plant-commons-secrets
#   orcid: {clientId: APP-XXXXXXXXXXXXXXXX}
helm lint     deploy/helm/plant-commons -f my-values.yaml
helm template plant-commons deploy/helm/plant-commons -n plant-commons -f my-values.yaml | less
helm upgrade --install plant-commons deploy/helm/plant-commons -n plant-commons -f my-values.yaml    # only with your go-ahead
helm -n plant-commons history  plant-commons
helm -n plant-commons rollback plant-commons <revision>        # does not undo a database migration
```

Upgrade of the application: build and push images for the new commit, change `image.tag`, run the same `helm upgrade`.
Pods roll when their ConfigMap changes (checksum annotation). An RSD release that changes the schema also needs the
manual migration (README "Database upgrades"): the images alone never migrate. `helm uninstall` removes everything the chart rendered; the
Secrets, the CNPG cluster and its data belong to the platform and stay.

## 5. First-install checklist

1. **Namespace and Secrets** (section 3), the CNPG cluster `plant-commons-pg` (database `rsd-db`, owner `rsd`) and **`deploy/postgres/init.sql`** run once as superuser
   (database.md section 2; the chart never initialises an external database, and the backend stays unready until it is done).
2. **ORCID client** (question 5/14): production client with **both** redirect URIs registered, exactly:
   `https://plant-commons.ipk-gatersleben.de/auth/login/orcid` and `https://plant-commons.ipk-gatersleben.de/auth/couple/orcid`.
   Decide who owns the client and who holds the client secret.
3. **DNS**: `plant-commons.ipk-gatersleben.de` to the ingress.
4. **Routing/TLS**: the platform registers `deploy/routing/routes.yaml` in its service registry (keep `routing.enabled=false`). The site needs HTTPS (the cookies are `Secure`).
5. **Install** (section 4). Watch: `kubectl -n plant-commons get pods -w`. With the external database the backend becomes ready as soon as it can log in over TLS and sees the schema.
6. **Check ORCID discovery**: `curl -s https://plant-commons.ipk-gatersleben.de/auth/providers` must list `orcid`, not `[]`
   (discovery runs once at auth pod start, with no retry; fix egress to `orcid.org:443` and restart the auth pod if it is empty). Before routing exists use
   `kubectl -n plant-commons port-forward svc/auth 7000:7000` and `curl localhost:7000/auth/providers`.
7. **First admin** (question 6/10): edit `deploy/helm/plant-commons/examples/first-admin.sql` (your ORCID iD and name) and run it once as the
   database owner `rsd` or the superuser (README "First admin"; only with your explicit go-ahead). Then log in with ORCID and create invites under Administration.
8. **Smoke**: `/` loads, `/api/v1/` returns the OpenAPI document, an image from `/image/rpc/get_image?uid=...` is served (Accept override), a login round-trip works.
9. Note the frontend's `/documentation/...` links return 404 (documentation not run, question 17).

## 6. What the chart deliberately does not do

- No Secret creation in real use, no namespace, no DNS, no ORCID client, no ServiceAccount/RBAC (no pod needs the Kubernetes API: `automountServiceAccountToken: false`).
- No schema migration, no database backup (the platform does nightly `pg_dump`; no PVC or backup topic in the chart), no password rotation (all manual, documented).
- No Ingress/Gateway/IngressRoute/Middleware/Certificate objects: the platform generates routes and certificate from `deploy/routing/routes.yaml` (`routing.enabled=false`).
- No database on the platform (`database.enabled=false`): no StatefulSet, Service or PVC; the schema comes from `deploy/postgres/init.sql`, run by the platform.
- No documentation, codemeta, nginx, mail stack (rabbitmq/mail/publisher), data-generation; no JDWP; no published database/admin port.
- No `imagePullSecrets` by default; digest pinning is optional (`image.digests`), no image signature check.
- No HorizontalPodAutoscaler; the defaults are one replica each.
- No `ORCID_*`/`LINKEDIN_*` for the frontend and no unused provider variables (the code does not read them); no `RSD_VERSION` (baked into the image).

## 7. Validation results (no cluster)

`deploy/helm/plant-commons/ci/check.sh` (234 checks passed, 0 failed in the last run, helm 3.16.2 / yq 4.44.3 from local images; also run by the `chart` job in `.github/workflows/plant-commons-images.yml`):

- `helm lint` clean for the CI values, the kind values, all optional parts on, the external-database shape (`ci/values-external.yaml`) and `examples/values-plant-commons.yaml`; and it **fails** without the required values.
- Renders (11): default, kind, the platform example, everything optional on, the external-database shape with scrapers/swagger/migration Job/NetworkPolicies, image digests, scrapers, swagger, networkPolicy, routing (with `--api-versions` for the CRDs; not needed to render), replicas 2.
- 44 negative tests, each failing with a clear message in the schema and (for the security-relevant ones) in the template guard too:
  `LOCAL` or another provider, `RSD_ENVIRONMENT=dev`, host with trailing slash / scheme / empty, empty or `latest` tag, namespace placeholder, missing
  `existingSecret`, `existingSecret` together with `secrets.create`, unsafe fake secrets, missing ORCID client id, JDWP/5005 in args or JAVA_TOOL_OPTIONS,
  a PDB with one replica, routing/networkPolicy/dbMigration with missing inputs, an unknown value (typo), a removed value (`networkPolicy.egress.orcid`), a missing CPU limit
  (backend, migration Job), `sslMode` other than `verify-full`/`verify-ca`, missing CA/authenticator Secret names, database passwords in `secrets.values` with the external database,
  malformed or unknown image digests, networkPolicy without DNS or external-database peers.
- Positive assertions: no `command:` anywhere; auth/background-services `args` as decided; no secret key name or value in any ConfigMap; every container has
  `securityContext` and resources, drop ALL, no privilege escalation; seccomp RuntimeDefault and no service-account token on every pod; only ClusterIP Services,
  none exposes 3501; no hostPort/hostNetwork; PVC claim and PGDATA; `PGRST_SERVER_HOST=0.0.0.0`; probes on the admin port; no `jdwp` or `5005`.
- External-database shape (platform): no StatefulSet/PVC/database Service; `PGRST_DB_URI` with `sslmode=verify-full&sslrootcert=...`; CA Secret mounted read-only into exactly backend, background-services and the Job;
  `POSTGRES_DB_JDBC_PARAMS`, `PGSSLMODE`, `PGSSLROOTCERT` set; database passwords never read from `existingSecret`; only the expected Secret names referenced; every container (init/job included) has CPU
  request and limit; every Service port named; every route target of `deploy/routing/routes.yaml` is a rendered Service:port and the host matches; digests rendered only where set; NetworkPolicies: one per pod,
  ingress+egress, Traefik reaches exactly frontend/backend/auth(/swagger), database egress only to the CNPG pods from backend/background-services/Job, the internet rule (six exclusions, 443) only for auth/frontend/scrapers.
- Env names per service equal the sets in configuration.md. Deliberate extras (chart's own database render): `POSTGRES_AUTHENTICATOR_PASSWORD` on the backend (only to expand inside
  `PGRST_DB_URI`) and `JAVA_TOOL_OPTIONS` on auth and background-services. Left out on purpose (the "compose passes it, no code reads it" set): the frontend's
  `ORCID_*`, `LINKEDIN_*`, auth's unused providers' variables, `RSD_VERSION` (baked in), compose's `PGRST_SERVER_HOST=backend`, `POSTGRES_DB_HOST*` for the
  backend (replaced by the assembled URI).
- **kubeconform could not be used offline**: `ghcr.io/yannh/kubeconform:v0.6.7` contains no schemas and downloads them from raw.githubusercontent.com. It is a
  commented step in the workflow (needs network), not enabled. So the rendered objects were **not** validated against the Kubernetes API schemas; `helm lint` and the
  structure assertions are what is checked.

## 8. Measurements behind the settings (docker only, 2026-10-26)

| Question | Result |
|---|---|
| Database as uid 999, `--cap-drop ALL`, `no-new-privileges`, PGDATA in a subdirectory next to `lost+found`, volume owned by 999 | Init completed; the init-script `sed` worked; `rsd_authenticator` logged in with the substituted password; schema present (64 public tables). |
| `pg_isready` probe form | Default (unix socket) answered "accepting connections" while the init scripts were still running; `-h 127.0.0.1` answered "no response" until init finished. The chart uses TCP. |
| Fast shutdown | `pg_ctl -D $PGDATA stop -m fast` inside the container: exit in 0.2 s, container `Exited (0)`, clean shutdown log. Image stop signal is SIGINT. |
| Backend as uid 1000, read-only root, drop ALL, `PGRST_SERVER_HOST=0.0.0.0` | API (3500) and admin (3501 `/live`, `/ready`) reachable from another container: 200/200/200. |
| Backend with the database down | `/live` 200, `/ready` 503, process keeps running and retries; after the database came up `/ready` became 200 without a restart. So no init container. |
| background-services as uid 10001, read-only root, `/tmp` tmpfs, database down | Started and scheduled its jobs (first run after 30 s). So no init container. |
| Frontend read-only, no `/app/.next/cache` mount | `/_next/image` returned 200 but logged `unhandledRejection: ENOENT mkdir '/app/.next/cache'` and `Failed to write image to cache`; with the emptyDir (tmpfs) no error. Hence the emptyDir. `/api/fe` (static JSON, no database) works for probes and reports `rsd_version: 6.7.2`. |
| Scrapers: cron with `--cap-drop ALL` | The cron job did **not** run; with `SETUID`+`SETGID` added it ran (also with more capabilities; two suffice). |
| Swagger: read-only root with uid 101, or drop ALL without capabilities | Container exits (its entrypoint rewrites files); root with `CHOWN`+`SETUID`+`SETGID` added back works (HTTP 200). |

Not measured: memory/CPU needs of any service (the numbers in values.yaml are estimates), behaviour on a real CSI volume with `fsGroup`, NetworkPolicy enforcement, the
Traefik/cert-manager objects against real CRDs, the migration Job stub, and a real ORCID login.

## 9. Local kind smoke test (printed only: do not run without asking; no cluster was used)

`examples/values-kind.yaml` selects the images `deploy/build-images.sh` builds locally (`registry.invalid/plant-commons/plant-commons-<svc>`), `IfNotPresent`, fake
secrets via `secrets.create=true`, tiny resources, routing off, and ORCID with a dummy client (LOCAL is refused even here, so no login is possible; the point is that
the pods start, the schema initialises and the probes pass).

```bash
./deploy/build-images.sh                                   # local images, tag sha-<short sha>[-dirty]
kind create cluster --name plant-commons-test
for s in database backend auth frontend background-services; do
  kind load docker-image registry.invalid/plant-commons/plant-commons-$s:<tag> --name plant-commons-test; done
helm upgrade --install pc deploy/helm/plant-commons -n pc --create-namespace \
  -f deploy/helm/plant-commons/examples/values-kind.yaml --set image.tag=<tag>
kubectl -n pc get pods -w
kubectl -n pc port-forward svc/frontend 3000:3000          # http://localhost:3000
kind delete cluster --name plant-commons-test
```

Things this test would confirm that the docker measurements could not: probe wiring, `fsGroup` with kind's local-path volumes, `$(VAR)` expansion in
`PGRST_DB_URI`, Service DNS names, and the read-only filesystems under the kubelet.

## 10. Manual steps still needed for Phase 6

Run `deploy/postgres/init.sql` (database.md); get the Secrets in place (section 3); who owns the ORCID client and holds its secret; the first-admin iD; making the ghcr.io packages
(one per image) public after the first push; first install; `GET /auth/providers`; first-admin SQL; tuning the resource numbers after observing real usage; a decision about the
`/documentation/...` 404s before launch. Database backups, storage and restore are the platform's (nightly `pg_dump`, local disks, 2 instances): there is no PVC and no backup topic
in this chart; ask the platform for the restore procedure and test one restore into a scratch database before launch.

## 11. Target platform (PDB, RKE2 at de.NBI Bielefeld)

Facts given by the platform team and what the chart does with them (nothing here was applied or tested against the cluster):

| Platform fact | In the chart |
|---|---|
| No application-managed PostgreSQL; a CNPG cluster per service (PostgreSQL 17.11, 2 instances, local disks, nightly `pg_dump`), TLS only | `database.enabled=false` + `externalDatabase` (section 2, database.md): no StatefulSet/Service/PVC; verified TLS from backend, background-services, migration Job |
| Routes and certificate from the service registry | `routing.enabled=false`; `deploy/routing/routes.yaml` (routing.md); fixed Service names and named ports |
| Traefik in namespace `traefik`; CoreDNS (`kube-system`, `k8s-app: kube-dns`); Prometheus in `monitoring` | NetworkPolicy defaults (11.1) |
| Namespace LimitRange defaults CPU limits to 500m | every container has an explicit CPU request and limit; the schema requires `limits.cpu` |
| PSA `baseline` enforced | everything runs as non-root with `drop: [ALL]`, `RuntimeDefault` seccomp, read-only root filesystem where measured possible (restricted-compliant). Exceptions, both **off by default** and already so before: `scrapers` (root, `SETUID`/`SETGID` for cron) and `swagger` (root, `CHOWN`/`SETUID`/`SETGID`) are baseline-compliant but not restricted-compliant; the database StatefulSet (chart's own database only) writable root fs |
| Control-plane nodes are tainted | no `nodeSelector`/`tolerations` set (values stay empty) |
| Secrets from the platform's vault | `existingSecret: plant-commons-secrets` (JWT, ORCID client secret); database passwords from the two CNPG/vault Secrets (section 3) |
| Backups by the platform | none in the chart |

### 11.1 NetworkPolicies (`networkPolicy.enabled=true`, ingress + egress)

One policy per component, default deny both ways, then:

| Component | Ingress from | Egress to (besides DNS UDP/TCP 53 to `kube-system`/`k8s-app: kube-dns`) |
|---|---|---|
| frontend | Traefik (`traefik` namespace, pods `app.kubernetes.io/name: traefik`), port 3000 | backend:3500, auth:7000, **internet TCP 443** |
| backend | frontend, auth, scrapers (if enabled), Traefik, port 3500 | CNPG pods (`cnpg.io/cluster: plant-commons-pg`, same namespace) 5432 |
| auth | frontend, Traefik, port 7000 | backend:3500, **internet TCP 443** |
| background-services | nothing | CNPG pods 5432 |
| scrapers (if enabled) | nothing | backend:3500, **internet TCP 443** |
| swagger (if enabled) | Traefik, port 8080 | nothing |
| db-migration Job (if enabled) | nothing | CNPG pods 5432 |
| database (only with `database.enabled=true`) | backend, background-services, Job, port 5432 | nothing |

"Internet" is `0.0.0.0/0` except `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`, `127.0.0.0/8`, TCP 443 only (ORCID is behind
Cloudflare, so there are no fixed addresses; the exclusions keep the pods away from the cluster, nodes and metadata services). Notes:

- **Why the frontend gets internet**: its server side calls external hosts: `app/api/fe/cite` (`https://doi.org/...`), `app/api/fe/mention/find_by_title` and
  `.../crossref` (Crossref, DataCite, OpenAlex via `utils/getOpenalex.ts`), `utils/getOpenalex.ts` (`api.openalex.org`), and `app/api/fe/markdown/raw`, which fetches a
  user-given markdown URL (GitHub, GitLab, any host). The auth service needs `orcid.org` (OIDC discovery once at start). No other component calls out
  (checked: backend, background-services have no outbound HTTP; scrapers need GitHub/GitLab/Zenodo/Crossref/OpenAlex/ROR). The frontend also has a `/plugin/` fetch to
  `RSD_REVERSE_PROXY_URL` (the public host), only for configured plugins (none), so it is not allowed for.
- background-services and scrapers do **not** need the links the brief lists as "-> backend and DB" for both: background-services only talks to the database
  (JDBC, no PostgREST call in its code), scrapers only to the backend (`POSTGREST_URL`, no database variables).
- The platform handles ingress to the database pods (operator, Prometheus); the chart renders no policy for them.
- **Prometheus**: not applicable. No component publishes metrics through a Service or ServiceMonitor (PostgREST's admin port 3501 has no Service, database metrics are the
  platform's), so no rule for the `monitoring` namespace exists. Add one only together with a ServiceMonitor.
- Kubelet probes and traffic from the node are not affected by NetworkPolicies on canal/Calico. Whether RKE2's canal enforces **egress** `ipBlock ... except` as written, and whether
  NodeLocal DNS is in use (it would need another DNS peer), is not verified.
- Default `networkPolicy.enabled` stays `false`; `examples/values-plant-commons.yaml` sets it to `true` with these values.
