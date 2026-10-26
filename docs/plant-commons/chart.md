# Plant Commons: Helm chart reference

Phase 5. Chart: [`deploy/helm/plant-commons/`](../../deploy/helm/plant-commons/) (version 0.1.0, appVersion 6.7.4, short
README next to it). **Nothing was applied to a cluster**: the chart was linted, rendered and checked with
`deploy/helm/plant-commons/ci/check.sh` (helm 3.16.2 and yq 4.44.3 from local images), and several container
settings were measured with plain `docker run` (section 8). Companion docs: [services.md](services.md),
[configuration.md](configuration.md), [routing.md](routing.md), [images.md](images.md).

## 1. How the chart maps to the other docs

| Doc | What the chart takes from it |
|---|---|
| services.md | Which services exist: database (StatefulSet+PVC), backend, auth, frontend, background-services always; scrapers (1-replica Deployment running cron) and swagger optional; codemeta, mail stack, documentation, nginx not implemented. ClusterIP only; no 5005, no published DB port. Probes, `PGRST_SERVER_HOST=0.0.0.0`, PGDATA subdirectory, no JDWP. |
| configuration.md | Every env var. "Source = ConfigMap" rows go into one ConfigMap per service (`templates/_config.tpl`), "Secret" rows are single `secretKeyRef` entries (key name = variable name), "chart" rows are literals in the pod spec (`PGRST_DB_URI`, `PGRST_DB_PRE_REQUEST`, `PGRST_SERVER_HOST`, `PGRST_DB_POOL*`, `PGDATA`). `ci/check.sh` diffs the rendered env names against these tables (section 7). |
| routing.md | `templates/routing.yaml` (optional, off): Traefik `IngressRoute` + `Middleware` (StripPrefix `/api/v1`, `/image`, `/swagger`; request header `Accept: application/octet-stream` on `/image`; Buffering 40M on `/api/v1` and `/api/v2`; `/auth` and `/api/v2` prefixes kept) and a cert-manager `Certificate`. Compress and the `Content-Location` handling are not implemented (optional/dropped in routing.md). |
| images.md | Image names `<registry>/<namespace>/plant-commons-<service>:<tag>` with one `image.tag` (the `sha-<short sha>` tag); exec-form `args` for auth and background-services (6.1); the measured uid/securityContext table (6). |

## 2. Values

Defaults are in [`values.yaml`](../../deploy/helm/plant-commons/values.yaml); each value there is commented with its source.
[`values.schema.json`](../../deploy/helm/plant-commons/values.schema.json) rejects unknown keys and the unsafe values at lint time, and
`templates/_validate.tpl` repeats the security-relevant checks at render time (they also hold with `--skip-schema-validation`).

**Required for a real install** (no usable default): `image.tag`, `existingSecret`, `orcid.clientId`.

### General

| Value | Default | Purpose |
|---|---|---|
| `host` | `plant-commons.ipk-gatersleben.de` | Bare host name (no scheme/path/trailing slash; both schema and template refuse anything else). Derives `HOST_URL=https://<host>`, `RSD_REVERSE_PROXY_URL`, swagger `API_URL`, the route host and certificate name. |
| `image.registry` | `ghcr.io` | Registry host. |
| `image.namespace` | `feserm/plant-commons` | Path below the registry (confirmed); the placeholder `CHANGE_ME` is still refused. |
| `image.tag` | `""` (required) | `sha-<short sha>` for all services; `latest` refused. |
| `image.pullPolicy` | `IfNotPresent` | |
| `imagePullSecrets` | `[]` | Optional; public ghcr.io images need none. |
| `existingSecret` | `""` (required) | Name of the existing Secret (section 3). |
| `secrets.create` / `secrets.values.*` | `false` / empty | **Local tests only**: renders a Secret from values (credentials end up in the Helm release secret). Refuses non-`[A-Za-z0-9]` values and a JWT secret under 32 characters; cannot be combined with `existingSecret`. |
| `orcid.clientId` | `""` (required) | Production ORCID client id (`APP-` + 16 characters). |
| `orcid.wellKnownUrl` | `https://orcid.org/.well-known/openid-configuration` | Production, not sandbox. |
| `urls.postgrest` | `""` | `POSTGREST_URL`; empty = `http://backend:3500` derived from the Service name and `backend.port`. |
| `serviceNamePrefix` | `""` | Prefix for Service names (only for a second release in one namespace). |
| `nameOverride`, `fullnameOverride` | `""` | Usual Helm naming overrides (workloads are `<fullname>-<component>`; Services are the short names). |
| `nodeSelector`, `tolerations`, `affinity` | empty | Applied to all pods. |

### Per service (`database`, `backend`, `auth`, `frontend`, `backgroundServices`, `scrapers`, `swagger`)

| Value | Default | Purpose |
|---|---|---|
| `database.name`, `database.user` | `rsd-db`, `rsd` | `POSTGRES_DB`, `POSTGRES_USER` (ConfigMap). `name` must be `[a-z0-9-]`. |
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
| `<svc>.resources` | see values.yaml | `requests`/`limits` (memory required in both). Starting estimates, **not measured**. No CPU limits by default. |
| `<svc>.podSecurityContext`, `<svc>.securityContext` | see values.yaml | The measured settings from images.md section 6; the schema requires `allowPrivilegeEscalation: false`, `drop: [ALL]` and a seccomp profile. |
| `<svc>.strategy` (frontend, backend, auth) | RollingUpdate, surge 1, unavailable 0 | background-services and scrapers are hard `Recreate`, 1 replica. |
| `<svc>.podDisruptionBudget` (frontend, backend, auth) | disabled, `minAvailable: 1` | Refuses to render with `replicas < 2`. |
| `<svc>.terminationGracePeriodSeconds` | 30 (120 database) | |
| `scrapers.enabled` | `false` | 1-replica Deployment running `cron -f`. |
| `scrapers.maxRequests.*`, `crossrefContactEmail` | `6` each | `MAX_REQUESTS_*`; `ENABLE_NASSA_SCRAPER`/`ENABLE_ESCAPE_OSSR_SCRAPER` are fixed `false`. Optional Secret keys: `API_CREDENTIALS_GITHUB`, `ZENODO_ACCESS_TOKEN`, `OPENALEX_API_KEY`, `LIBRARIES_IO_ACCESS_TOKEN`. |
| `swagger.enabled`, `swagger.image` | `false`, `swaggerapi/swagger-ui:v5.32.6` | Interactive API browser behind `/swagger/` (needs routing). |

### Optional parts

| Value | Default | Purpose |
|---|---|---|
| `dbMigration.enabled`, `name`, `configMapName`, `configMapKey` | `false`, `manual`, `""`, `migration.sql` | Opt-in **untested stub** Job running a user-supplied SQL ConfigMap through psql (README "Database upgrades"). |
| `networkPolicy.enabled` | `false` | Default-deny ingress + the allow rules that really exist. |
| `networkPolicy.ingressFrom` | `[]` | Required when enabled: `from` peers of your ingress controller. |
| `networkPolicy.egress.enabled`, `.dns`, `.orcid`, `.scrapers` | `false`, kube-dns peer, `[]`, `[]` | Egress restriction; `orcid` (peers for `orcid.org:443`, cluster-specific, not guessed) is required when enabled. |
| `routing.enabled` | `false` | Renders `templates/routing.yaml`. |
| `routing.apiVersion` | `traefik.io/v1alpha1` | Depends on the Traefik version. |
| `routing.entryPoints` | `[]` | Required when enabled. |
| `routing.annotations`, `routing.labels` | `{}` | Applied to IngressRoute, Middlewares, Certificate (placeholder for a service-registry scheme; none is invented). |
| `routing.maxRequestBodyBytes` | `41943040` | Buffering cap on `/api/v1`, `/api/v2`; `0` removes it. |
| `routing.tls.secretName` | `""` | Empty = `<fullname>-tls`. |
| `routing.certificate.enabled`, `.issuerRef.{name,kind,group}` | `true`, `""`/`ClusterIssuer`/`cert-manager.io` | `issuerRef.name` required when enabled. |

### Answered cluster inputs (2026-10-26)

`examples/values-plant-commons.yaml` holds them: namespace `plant-commons`, images `ghcr.io/feserm/plant-commons`, database PVC 10Gi,
1 replica each, ORCID client `APP-T1MHJINJKL8PTMXA` (production, both redirect URIs registered), routing/TLS from **one entry in the
cluster-local service registry outside the chart** (`routing.enabled=false`; the entry needs the host and the path/target table in routing.md),
NetworkPolicy ingress+egress with "public HTTPS" egress (`0.0.0.0/0`, TCP 443). Still open: the ingress controller's labels for `networkPolicy.ingressFrom`,
who owns the ORCID client / holds its secret, the first-admin iD. Database storage class: `local-ephemeral`, confirmed by the user (`nfs-rwx` rejected); the name suggests node-local,
non-replicated storage, so a backup plan matters (Phase 6).

## 3. Secrets: creation

The Secret is created outside the chart, never committed, and holds exactly these keys. Values must be `[A-Za-z0-9]`
(upstream restriction, configuration.md section 5); `openssl rand -hex 32` produces 64 such characters, which also satisfies
PostgREST's 32-character minimum for the JWT secret. Generate one value per key. Printed here, not run:

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

(Store the values in IPK's secret store as well; they are needed again for `ALTER ROLE` rotations and disaster recovery.)
The chart cannot check that the keys exist before install; a missing key shows up as `CreateContainerConfigError`
on the pod. `PGRST_DB_URI` is **not** a Secret key: it is assembled in the backend pod spec as
`postgres://rsd_authenticator:$(POSTGRES_AUTHENTICATOR_PASSWORD)@database:5432/rsd-db` (Kubernetes `$(VAR)` expansion), so the
password exists in one place only. Rotation and the first-init-only behaviour: configuration.md section 5.

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
manual migration (README "Database upgrades"): the images alone never migrate. `helm uninstall` removes everything except the
Secret you created and the database PVC.

## 5. First-install checklist

1. **Namespace and Secret** (section 3). Question: namespace name.
2. **ORCID client** (question 5/14): production client with **both** redirect URIs registered, exactly:
   `https://plant-commons.ipk-gatersleben.de/auth/login/orcid` and `https://plant-commons.ipk-gatersleben.de/auth/couple/orcid`.
   Decide who owns the client and who holds the client secret.
3. **DNS**: `plant-commons.ipk-gatersleben.de` to the ingress.
4. **Routing/TLS**: blocked on questions 3 and 13. Either enable `routing.*` with the real entrypoint and **IssuerRef** names, or use whatever
   mechanism IPK's service registry prescribes (then keep `routing.enabled=false`). The site needs HTTPS (the cookies are `Secure`).
5. **Install** (section 4). Watch: `kubectl -n plant-commons get pods -w`. The first start initialises the schema (the database startup probe allows 5 minutes).
6. **Check ORCID discovery**: `curl -s https://plant-commons.ipk-gatersleben.de/auth/providers` must list `orcid`, not `[]`
   (discovery runs once at auth pod start, with no retry; fix egress to `orcid.org:443` and restart the auth pod if it is empty). Before routing exists use
   `kubectl -n plant-commons port-forward svc/auth 7000:7000` and `curl localhost:7000/auth/providers`.
7. **First admin** (question 6/10): edit `deploy/helm/plant-commons/examples/first-admin.sql` (your ORCID iD and name) and run it once as the
   superuser (README "First admin"; only with your explicit go-ahead). Then log in with ORCID and create invites under Administration.
8. **Smoke**: `/` loads, `/api/v1/` returns the OpenAPI document, an image from `/image/rpc/get_image?uid=...` is served (Accept override), a login round-trip works.
9. Note the frontend's `/documentation/...` links return 404 (documentation not run, question 17).

## 6. What the chart deliberately does not do

- No Secret creation in real use, no namespace, no DNS, no ORCID client, no ServiceAccount/RBAC (no pod needs the Kubernetes API: `automountServiceAccountToken: false`).
- No schema migration, no database backup, no password rotation (all manual, documented).
- No Ingress/Gateway objects, and no routing unless you enable `routing.enabled` (CRDs of Traefik and cert-manager required then).
- No documentation, codemeta, nginx, mail stack (rabbitmq/mail/publisher), data-generation; no JDWP; no published database/admin port.
- No `imagePullSecrets` by default; no digest pinning of images; no image signature check.
- No HorizontalPodAutoscaler; the defaults are one replica each.
- No `ORCID_*`/`LINKEDIN_*` for the frontend and no unused provider variables (the code does not read them); no `RSD_VERSION` (baked into the image).

## 7. Validation results (no cluster)

`deploy/helm/plant-commons/ci/check.sh` (also run by the `chart` job in `.github/workflows/plant-commons-images.yml`):

- `helm lint` clean for the CI values, the kind values and all optional parts on; and it **fails** without the required values.
- Renders: default, kind, everything optional on, scrapers, swagger, networkPolicy, routing (with `--api-versions` for the CRDs; not needed to render), replicas 2.
- 33 negative tests, each failing with a clear message in the schema and (for the security-relevant ones) in the template guard too:
  `LOCAL` or another provider, `RSD_ENVIRONMENT=dev`, host with trailing slash / scheme / empty, empty or `latest` tag, namespace placeholder, missing
  `existingSecret`, `existingSecret` together with `secrets.create`, unsafe fake secrets, missing ORCID client id, JDWP/5005 in args or JAVA_TOOL_OPTIONS,
  a PDB with one replica, routing/networkPolicy/dbMigration with missing inputs, an unknown value (typo).
- Positive assertions: no `command:` anywhere; auth/background-services `args` as decided; no secret key name or value in any ConfigMap; every container has
  `securityContext` and resources, drop ALL, no privilege escalation; seccomp RuntimeDefault and no service-account token on every pod; only ClusterIP Services,
  none exposes 3501; no hostPort/hostNetwork; PVC claim and PGDATA; `PGRST_SERVER_HOST=0.0.0.0`; probes on the admin port; no `jdwp` or `5005`.
- Env names per service equal the sets in configuration.md. Deliberate extras: `POSTGRES_AUTHENTICATOR_PASSWORD` on the backend (only to expand inside
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

Answers to the open questions (routing inputs, namespace, storage class, NetworkPolicy and its ORCID egress, replicas, ORCID client ownership and redirect URIs,
client secret holder, first-admin iD); the Secret; making the ghcr.io packages (one per image) public after the first push; first install; `GET /auth/providers`;
first-admin SQL; persistence check across a database pod restart; a backup/restore plan for the PVC (nothing exists yet); tuning the resource numbers after observing
real usage; a decision about the `/documentation/...` 404s before launch.
