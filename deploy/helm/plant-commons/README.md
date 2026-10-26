# plant-commons Helm chart

Deploys the Plant Commons (customised RSD v6.7.4) services to Kubernetes:
**database** (StatefulSet + PVC), **backend** (PostgREST), **auth**, **frontend**, **background-services**.
Optional, off by default: **scrapers**, **swagger**, a network policy set, a database migration Job (stub),
and Traefik routing + cert-manager certificate (blocked on open questions 3 and 13).

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
| Optional Traefik `IngressRoute`/`Middleware`/`Certificate` from `docs/plant-commons/routing.md` | Decide how routes/TLS are generated at IPK (open question 3) |

Not implemented, by decision: **codemeta** (nothing in the UI calls it), the **mail stack** (no e-mail is part of the plan),
**documentation** (not run). Consequence: the frontend's hard-coded `/documentation/...` links will return 404 (open question 17).

## Install (commands are printed here, not run by anything)

```bash
# 1. Namespace and Secret (never put the values in a file in git). 64 hex characters = [A-Za-z0-9] only,
#    which is all the upstream scripts tolerate (see chart.md "Secrets").
kubectl create namespace plant-commons
kubectl -n plant-commons create secret generic plant-commons-secrets \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 32)" \
  --from-literal=POSTGRES_AUTHENTICATOR_PASSWORD="$(openssl rand -hex 32)" \
  --from-literal=PGRST_JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=AUTH_ORCID_CLIENT_SECRET='<ORCID client secret>'

# 2. Your values (not committed): image.namespace, image.tag (sha-<short sha>), existingSecret, orcid.clientId
helm upgrade --install plant-commons deploy/helm/plant-commons -n plant-commons -f my-values.yaml

# 3. Roll back
helm -n plant-commons history plant-commons
helm -n plant-commons rollback plant-commons <revision>
```

Rollback does not undo a database migration. `helm uninstall` leaves the PVC (volume claim templates are not owned by the release).

## Required values

`image.namespace` (placeholder `CHANGE_ME` is refused), `image.tag` (`latest` is refused), `existingSecret`,
`orcid.clientId`. `host` defaults to `plant-commons.ipk-gatersleben.de` and must be a bare host name.
`helm lint` and `helm template` fail with a message until these are set; `ci/values-ci.yaml` holds obviously fake values for CI.

## Design choices

- **Secrets.** One existing Secret, key names equal to the variable names. Each pod gets only the keys it needs, via
  `secretKeyRef` (never `envFrom` of the whole Secret). `PGRST_DB_URI` is assembled **in the pod spec** with
  Kubernetes `$(VAR)` expansion from `POSTGRES_AUTHENTICATOR_PASSWORD` instead of being stored as a fifth key: the password then lives in
  exactly one place and cannot drift from the database's. (Safe because the value is `[A-Za-z0-9]`.)
  `secrets.create=true` renders a Secret from values for **local kind tests only**: it puts the credentials into the Helm release secret.
- **Database.** Runs as uid/gid 999 from the start with `fsGroup: 999` (instead of root plus the capabilities the entrypoint needs for chown/gosu):
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
  The memory limits are starting estimates, **not measured**; tune them after the first real run (Phase 6). No CPU limits by default (throttling,
  and the JVM sizes GC/threads from the CPU limit).
- **Replicas.** frontend and backend are stateless (no local state in the code; auth is too), so 2 replicas are possible; the default is 1 for all, pending your answer.
  A PodDisruptionBudget is available per service but refuses to render with fewer than 2 replicas (it would block node drains).
  database, background-services and scrapers are always 1 (`Recreate` for the last two so that never two run at once).
- **Frontend** gets emptyDirs at `/tmp` and `/app/.next/cache`: measured, with a read-only root filesystem the Next.js image optimiser fails with
  `unhandledRejection ... mkdir '/app/.next/cache'` without it.
- **Scrapers** run as root with `SETUID`+`SETGID` added back and a writable root filesystem (cron; measured: no jobs run without those two capabilities).
  **Swagger** needs a writable root and `CHOWN`/`SETUID`/`SETGID` (its entrypoint rewrites files). Both are off by default.
  The scrapers image's shell-form CMD means SIGTERM may not reach `cron`; pod shutdown can take the full grace period (harmless).

## Routing and TLS (optional, off, BLOCKED)

`routing.enabled=false`. `templates/routing.yaml` is generated only from the Traefik-neutral spec in
[routing.md](../../../docs/plant-commons/routing.md) and needs the CRDs only when enabled. Entrypoints, issuer name and any
registry labels/annotations are values without defaults. The six inputs still missing are listed in `values.yaml` above the `routing:` block
(and in routing.md). Without routing the site is **not reachable**; the chart creates no Ingress of any kind.

## First admin

`ORCID:INVITE_ONLY` has a chicken-and-egg problem: creating invites needs an admin. After the first successful install, edit the ORCID iD and name in
`examples/first-admin.sql` and run it **once** as the database superuser (this needs your explicit go-ahead on the cluster; it is not part of the chart):

```bash
kubectl -n plant-commons exec -i plant-commons-database-0 -- \
  psql -U rsd -d rsd-db < deploy/helm/plant-commons/examples/first-admin.sql
```

(`rsd` / `rsd-db` are `database.user` / `database.name`.) Then log in through ORCID with that iD.

## Database upgrades

The `database` image only creates the schema on the first start with an **empty** data directory; there is no migration runner and the chart does not invent one.
`POSTGRES_PASSWORD` / `POSTGRES_AUTHENTICATOR_PASSWORD` are also applied only at first init (rotation = `ALTER ROLE ...` by hand, then restart the consumers).
For an RSD upgrade:

1. Read upstream's release notes and fetch the migration SQL for the release: upstream publishes it per release in
   `database-migration/` of <https://github.com/research-software-directory/RSD-production> (not part of this repo; check it for your version jump).
2. **Back up first** (`pg_dump`; Phase 6 discusses backups). A rollback of the images does not undo a migration.
3. Apply the SQL as the superuser, either by hand (`kubectl exec -i ...-database-0 -- psql -U rsd -d rsd-db --single-transaction -v ON_ERROR_STOP=1 < migration.sql`)
   or with the **opt-in stub Job**: create a ConfigMap `kubectl -n plant-commons create configmap rsd-migration --from-file=migration.sql=<file>`
   and set `dbMigration.enabled=true`, `dbMigration.configMapName=rsd-migration`, a fresh `dbMigration.name` per run.
   The Job is an **untested stub** (never run in a cluster; the `psql` arguments were only reviewed). It runs the file as one transaction with `ON_ERROR_STOP`.
4. Deploy the new image tag.

## Optional NetworkPolicies

`networkPolicy.enabled=true` renders default-deny ingress plus allow rules for the traffic that really exists
(database <- backend, background-services; backend <- frontend, auth, scrapers, ingress controller; auth <- frontend, ingress controller; frontend <- ingress controller).
You must supply `networkPolicy.ingressFrom` (the ingress controller's pods). With `networkPolicy.egress.enabled` it also restricts egress and requires
`networkPolicy.egress.orcid` (the auth pod must reach `orcid.org:443`; plain NetworkPolicy cannot match host names, so it needs CIDRs or a CNI-specific FQDN policy: **not guessed**, open question 15).

## Tests without a cluster

```bash
deploy/helm/plant-commons/ci/check.sh      # needs helm 3.16 and yq v4 on PATH (HELM=/YQ= to override)
```

Lints, renders every optional part, runs ~30 negative tests (render must fail), asserts security and wiring properties on the rendered YAML,
and diffs the env var names per service against `configuration.md`. `examples/values-kind.yaml` is for a local kind smoke test (see chart.md; not run).
