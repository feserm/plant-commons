# plant-commons Helm chart

Deploys the Plant Commons (customised RSD v6.7.4) services to Kubernetes:
**backend** (PostgREST), **auth**, **frontend**, **background-services** and, by default, a **database** (StatefulSet + PVC).
On the target platform (PDB, RKE2 at de.NBI Bielefeld) the database is the platform's external CloudNativePG cluster
(`database.enabled=false` + `externalDatabase`, TLS with verification; [database.md](../../../docs/plant-commons/database.md)) and the
routes and certificate come from the platform's service registry ([`deploy/routing/routes.yaml`](../../routing/routes.yaml)); the chart renders no database and no routing then.
Optional, off by default: **scrapers**, **swagger**, NetworkPolicies, a database migration Job (stub), and Traefik routing + cert-manager certificate (not used on the platform).
Everything platform-specific is in [chart.md](../../../docs/plant-commons/chart.md) section 11 and `examples/values-plant-commons.yaml`.

The full reference (every value, how it maps to the docs, install checklist) is
[docs/plant-commons/chart.md](../../../docs/plant-commons/chart.md). This README is the short version.
Phase 5 of [implementation.md](../../../implementation.md); nothing here has been applied to a cluster.

## What it does and does not do

| Does | Does not |
|---|---|
| Deploy the five core services with the settings measured in Phases 2 and 4 | Create the Secret (you do), the namespace, DNS, the ORCID client |
| ORCID only (`ORCID:INVITE_ONLY`); **refuses** `LOCAL`, any other provider, `RSD_ENVIRONMENT=dev` | Run the schema migration for upgrades (there is no runner upstream) |
| Keep every secret out of ConfigMaps, git and values (references an existing Secret) | Create the first admin (SQL in `examples/first-admin.sql`, you run it) |
| ClusterIP Services only; no database or debug port reachable outside the cluster | Run the documentation service, codemeta, or the mail stack (rabbitmq/mail/publisher) |
| Fixed Service names + named ports matching `deploy/routing/routes.yaml` (the platform generates routes/TLS from it) | Render Ingress/IngressRoute/Middleware/Certificate (`routing.enabled=false`; an untested Traefik alternative exists) |
| External database mode: TLS everywhere, owner/authenticator credentials from the CNPG/vault Secrets | Create, initialise (`deploy/postgres/init.sql`, the platform runs it), or back up that database |

Not implemented, by decision: **codemeta** (nothing in the UI calls it), the **mail stack** (no e-mail is part of the plan),
**documentation** (not run). Consequence: the frontend's hard-coded `/documentation/...` links will return 404 (open question 17).

## Install (commands are printed here, not run by anything)

```bash
# 1. Platform: the namespace, the Secrets (plant-commons-secrets with PGRST_JWT_SECRET and AUTH_ORCID_CLIENT_SECRET,
#    the CNPG ones, see chart.md "Secrets"), the CNPG cluster, deploy/postgres/init.sql run once as superuser.
#    (Local kind test only: secrets.create=true or a hand-made Secret with the four keys, database.enabled=true.)

# 2. Platform values + the tag of the CI build (digests optional)
helm upgrade --install plant-commons deploy/helm/plant-commons -n plant-commons \
  -f deploy/helm/plant-commons/examples/values-plant-commons.yaml --set image.tag=sha-<short sha>

# 3. Roll back
helm -n plant-commons history plant-commons
helm -n plant-commons rollback plant-commons <revision>
```

Rollback does not undo a database migration. `helm uninstall` leaves the Secrets and the CNPG cluster (the platform's); with `database.enabled=true` it also leaves the PVC (volume claim templates are not owned by the release).

## Required values

`image.namespace` (placeholder `CHANGE_ME` is refused), `image.tag` (`latest` is refused; optional `image.digests.<component>` pins `repo:tag@digest`), `existingSecret`,
`orcid.clientId`; on the platform `database.enabled=false`. `host` defaults to `plant-commons.ipk-gatersleben.de` and must be a bare host name.
`helm lint` and `helm template` fail with a message until these are set; `ci/values-ci.yaml` holds obviously fake values for CI.

## Design choices

- **Secrets.** One existing Secret, key names equal to the variable names. Each pod gets only the keys it needs, via
  `secretKeyRef` (never `envFrom` of the whole Secret). `PGRST_DB_URI` is assembled **in the pod spec** with
  Kubernetes `$(VAR)` expansion from `POSTGRES_AUTHENTICATOR_PASSWORD` instead of being stored as a fifth key: the password then lives in
  exactly one place and cannot drift from the database's. (Safe because the value is `[A-Za-z0-9]`.)
  `secrets.create=true` renders a Secret from values for **local kind tests only**: it puts the credentials into the Helm release secret.
- **Database (only with `database.enabled=true`, local tests).** Runs as uid/gid 999 from the start with `fsGroup: 999` (instead of root plus the capabilities the entrypoint needs for chown/gosu):
  fewer privileges, and measured to work: the init `sed` in `000-fill-authenticator-password.sh` ran fine as uid 999,
  the authenticator role logged in with the substituted password. `readOnlyRootFilesystem` stays off for the database
  because that very `sed --in-place` writes into `/docker-entrypoint-initdb.d`. Needs a storage class whose volumes honour `fsGroup`.
  Probes use `pg_isready -h 127.0.0.1` (TCP): measured, the default unix-socket form reports "accepting connections" while the first-start init scripts
  are still running on a temporary, socket-only server. A `preStop` hook runs `pg_ctl stop -m fast` so that a SIGTERM cannot leave PostgreSQL waiting for clients (smart shutdown) until the kill.
- **"Backend needs the database at startup."** No init container: measured, PostgREST keeps retrying the connection itself,
  `/live` stays 200 and `/ready` is 503 until the database answers, then it recovers without a restart. Readiness keeps traffic away; a startup probe protects the start.
  background-services also starts without a database (its first job runs after a 30 s delay).
- **auth / background-services** use exec-form `args` (not `command`), keeping the image's cacert ENTRYPOINT and making the JVM PID 1 (images.md 6.1).
  The JDWP entrypoint and port 5005 do not exist in the chart, and the chart refuses them in values.
- **JVM memory.** `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=70.0` (a value) instead of editing the image: the JVM default is 25 % of the container limit.
  The memory and CPU limits are starting estimates, **not measured**; tune them after the first real run (Phase 6). Every container has an explicit
  CPU limit because the platform's namespace LimitRange would otherwise impose 500m (the JVM sizes GC/threads from the CPU limit; auth and the frontend get 1 CPU so that startup is not throttled).
- **Replicas.** frontend and backend are stateless (no local state in the code; auth is too), so 2 replicas are possible; the default is 1 for all, pending your answer.
  A PodDisruptionBudget is available per service but refuses to render with fewer than 2 replicas (it would block node drains).
  database, background-services and scrapers are always 1 (`Recreate` for the last two so that never two run at once).
- **Frontend** gets emptyDirs at `/tmp` and `/app/.next/cache`: measured, with a read-only root filesystem the Next.js image optimiser fails with
  `unhandledRejection ... mkdir '/app/.next/cache'` without it.
- **Scrapers** run as root with `SETUID`+`SETGID` added back and a writable root filesystem (cron; measured: no jobs run without those two capabilities).
  **Swagger** needs a writable root and `CHOWN`/`SETUID`/`SETGID` (its entrypoint rewrites files). Both are off by default.
  The scrapers image's shell-form CMD means SIGTERM may not reach `cron`; pod shutdown can take the full grace period (harmless).

## Routing and TLS (platform: from `deploy/routing/routes.yaml`)

`routing.enabled=false`, and it stays so on the platform: the service registry generates the routes and the certificate from
[`deploy/routing/routes.yaml`](../../routing/routes.yaml) (derived from [routing.md](../../../docs/plant-commons/routing.md), taken over unchanged), pointing
at the Services `auth:7000`, `backend:3500`, `frontend:3000`. Their names do not depend on the release name; `ci/check.sh` compares the file with the rendered Services.
`templates/routing.yaml` (Traefik `IngressRoute`/`Middleware` + cert-manager `Certificate`, every cluster input a value without default) remains as an untested alternative for clusters
without such a registry. Without any routing the site is **not reachable**.

## First admin

`ORCID:INVITE_ONLY` has a chicken-and-egg problem: creating invites needs an admin. After the first successful install, edit the ORCID iD and name in
`examples/first-admin.sql` and run it **once** as the database owner `rsd` (this needs your explicit go-ahead on the cluster; it is not part of the chart). With the platform database, ask the platform to run
it through its own access path (e.g. `kubectl cnpg psql`, or `kubectl exec` into the primary pod: `psql -U rsd -d rsd-db < first-admin.sql`, with the owner's password from `plant-commons-pg-app`).
`rsd` owns all tables, so the INSERTs work (not tested against the platform database). With `database.enabled=true`:

```bash
kubectl -n plant-commons exec -i plant-commons-database-0 -- \
  psql -U rsd -d rsd-db < deploy/helm/plant-commons/examples/first-admin.sql
```

(`rsd` / `rsd-db` are `database.user` / `database.name`.) Then log in through ORCID with that iD.

## Database upgrades

The schema is only created once (the `database` image on the first start with an **empty** data directory, or `deploy/postgres/init.sql` on the platform database, which the platform runs
as superuser); there is no migration runner and the chart does not invent one. `init.sql` is a build artefact: regenerate it with `deploy/postgres/build-init-sql.sh` on every upstream update.
With `database.enabled=true` the passwords are also applied only at first init (rotation = `ALTER ROLE ...` by hand, then restart the consumers).
For an RSD upgrade:

1. Read upstream's release notes and fetch the migration SQL for the release: upstream publishes it per release in
   `database-migration/` of <https://github.com/research-software-directory/RSD-production> (not part of this repo; check it for your version jump).
2. **Back up first** (on the platform: ask for a fresh dump besides the nightly one; otherwise `pg_dump`). A rollback of the images does not undo a migration.
3. Apply the SQL as the owner `rsd` (the objects are owned by it, `deploy/postgres/init.sql` builds the schema that way; a migration that needs superuser, e.g. `CREATE ROLE`, must be run by the platform),
   either by hand (`kubectl exec -i ...-database-0 -- psql -U rsd -d rsd-db --single-transaction -v ON_ERROR_STOP=1 < migration.sql`)
   or with the **opt-in stub Job**: create a ConfigMap `kubectl -n plant-commons create configmap rsd-migration --from-file=migration.sql=<file>`
   and set `dbMigration.enabled=true`, `dbMigration.configMapName=rsd-migration`, a fresh `dbMigration.name` per run.
   The Job is an **untested stub** (never run in a cluster; the `psql` arguments were only reviewed). It runs the file as one transaction with `ON_ERROR_STOP`.
4. Deploy the new image tag.

## Optional NetworkPolicies

`networkPolicy.enabled=true` renders default-deny ingress **and egress** plus allow rules for the traffic that really exists (table in chart.md 11.1):
backend <- frontend, auth, scrapers, Traefik; auth <- frontend, Traefik; frontend <- Traefik; backend, background-services and the migration Job -> the database (the platform's CNPG pods
`cnpg.io/cluster: plant-commons-pg` on 5432, or the chart's own database pod); everybody -> kube-dns; TCP 443 to the internet (everything except the private ranges) for auth, frontend and scrapers only.
Defaults in `values.yaml` are the platform's real values (Traefik in `traefik`, CoreDNS in `kube-system`, no Prometheus rule because nothing exposes metrics).

## Tests without a cluster

```bash
deploy/helm/plant-commons/ci/check.sh      # needs helm 3.16 and yq v4 on PATH (HELM=/YQ= to override)
```

Lints, renders every optional part and the external-database shape, runs ~50 negative tests (render must fail), asserts security and wiring properties on the rendered YAML,
diffs the env var names per service against `configuration.md`, and compares `deploy/routing/routes.yaml` with the rendered Services. `examples/values-kind.yaml` is for a local kind smoke test (see chart.md; not run).
