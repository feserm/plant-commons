# Plant Commons: which upstream services run in Kubernetes

Source of truth: `docker-compose.yml` (RSD v6.7.4). Every claim below was checked in the code
named in the "Evidence" column, not inferred from names. Companion docs:
[routing.md](routing.md), [configuration.md](configuration.md).

Decision legend: **yes** = deployed by the chart, **optional** = chart flag, off by default,
**no** = never deployed.

## Decision table

| Service | Run in k8s? | One-line reason | Evidence |
|---|---|---|---|
| database | **yes** | Single source of truth; StatefulSet + PVC, built `rsd/database` image (schema is baked in for first init). | `database/Dockerfile`, `database/000-fill-authenticator-password.sh` |
| backend (PostgREST) | **yes** | All frontend/auth/scraper data access goes through it; also exposed at `/api/v1`. | `docker-compose.yml`, `nginx/nginx.conf` |
| auth | **yes** | The only login path (ORCID); also serves `/api/v2` access-token API. | `authentication/.../Main.java` |
| frontend | **yes** | The site itself; carries the Plant Commons home page (Phase 3). | `frontend/Dockerfile` |
| background-services | **yes** | Refreshes materialized view `count_software_mentions_cached` every 5 min; talks to PostgreSQL directly. | `background-services/README.md` |
| nginx | **no** (Traefik) | Replaced by Traefik; its routing is specified in [routing.md](routing.md). certbot/Let's Encrypt in the image is replaced by cert-manager. | `nginx/nginx.conf`, `nginx/Dockerfile` |
| scrapers | **optional** | See below. Decide in open question 7. | `scrapers/jobs.cron` |
| codemeta | **optional** | Only an API/doc feature; nothing in the frontend calls it. | see below |
| swagger | **optional** | Interactive API docs at `/swagger/`; nothing links to it. | see below |
| documentation | **optional, but see warning** | The frontend has many hard-coded links to `/documentation/...`. | see below |
| rabbitmq, mail, publisher (profile `mail`) | **optional (off)** | Only sends e-mail for community join requests and access-token notifications; no e-mail is part of the plan. | see below |
| data-generation (profile `data`) | **no, never** | Fills the database with fake software/projects for development. | `docker-compose.yml` profile `data` |

## Core services: details that affect Phases 4-5

### database
- Built from `./database` (`postgres:17.11`). The Dockerfile copies `*.sql`/`*.sh` into
  `/docker-entrypoint-initdb.d`, so the schema is created **only on the first start with an empty
  data directory**. There is no migration runner (see "DB migrations" in implementation.md).
- `POSTGRES_PASSWORD` and `POSTGRES_AUTHENTICATOR_PASSWORD` are applied only at that first init.
  Changing the Kubernetes Secret later does **not** change the database password; it must be
  changed with `ALTER ROLE` as well, and the services restarted.
- Phase 5: mount the PVC at `/var/lib/postgresql/data` and set
  `PGDATA=/var/lib/postgresql/data/pgdata`. Many CSI volumes contain `lost+found` at the root,
  which makes `initdb` refuse to run in a non-empty directory. (Compose does not hit this because
  it uses a Docker volume.)
- Liveness/readiness: `pg_isready --username=$POSTGRES_USER --dbname=$POSTGRES_DB` (as in compose).
- No Service/Ingress exposure outside the cluster. Compose publishes 5432 for development only;
  do not copy that.

### backend (PostgREST)
- Image from `./backend-postgrest` (`postgrest/postgrest:v14.17`, no custom config files; all
  configuration is `PGRST_*` env).
- Compose healthcheck is `postgrest --ready`, which queries the admin port (3501). In k8s use
  HTTP probes on port 3501: `/ready` (readiness) and `/live` (liveness).
- **Do not copy `PGRST_SERVER_HOST=backend`** from compose. It is a Docker-network alias; in a pod
  `backend` resolves to the Service ClusterIP, which is not a local address, so PostgREST fails to
  bind. Set `PGRST_SERVER_HOST=0.0.0.0` (the admin server should use the same host and kubelet probes hit the pod IP; this and the
  `/live` / `/ready` paths come from PostgREST's documentation, not this repo, so confirm them in
  the Phase 5 `kind` smoke test). `.env.production.example` carries this variable for that reason.
- Needs the database reachable at startup (compose uses `depends_on: service_healthy`). In k8s use
  a wait-for-database init container or rely on pod restarts plus readiness.

### auth
- Image `rsd/auth` from `./authentication/Dockerfile`. Its last line is
  `CMD java -cp auth.jar nl.esciencecenter.rsd.authentication.Main` (shell form, listens on 7000).
- **The JDWP debug entrypoint must not be used.** `docker-compose.yml` overrides the image CMD with
  `entrypoint: java -agentlib:jdwp=transport=dt_socket,address=*:5005,server=y,suspend=n ...`, which
  opens an unauthenticated remote debugger (remote code execution) on 5005, and compose also
  publishes `5005:5005`. In the chart, set **neither `command` nor `args`** on the auth container so
  the image CMD is used, and expose only 7000. Do not publish 5005 in any Service.
- Heads-up for Phase 4: the shell-form CMD means `sh` is PID 1 and `java` is a child, so SIGTERM from
  Kubernetes may not reach the JVM and pod shutdown waits out the grace period. Harmless but slow;
  an exec-form CMD would fix it. Phase 4 measured it (10.25 s and SIGKILL vs 0.54 s) and recommends
  setting the container `args` to `java -cp auth.jar nl.esciencecenter.rsd.authentication.Main` in the chart
  (not `command`, which would drop the image's cacert ENTRYPOINT), instead of changing the image; see
  [images.md](images.md) section 6.1. This is fine with the "no JDWP" rule: the point is to never use
  compose's debug entrypoint.
- **Provider discovery happens once at startup.** `RsdProviders` fetches the ORCID well-known document
  in a background thread when the process starts. On failure (DNS, egress policy, ORCID outage) it logs a
  warning and **never retries**: `/auth/providers` then returns `[]` and nobody can log in until
  the pod restarts. Implications: the cluster must allow egress to `orcid.org:443` from the auth pod;
  check `GET /auth/providers` after every rollout (a readiness probe on `/auth/` would not catch this,
  because that endpoint is up regardless).
- It talks to the backend via `POSTGREST_URL` and signs JWTs with `PGRST_JWT_SECRET`.
- `RSD_API_ACCESS_TOKEN_ENABLED=true` (upstream default) registers `/auth/accesstoken` and the `/api/v2/*`
  proxy. Keep it on unless IPK does not want personal API tokens; if turned off, the `/api/v2` route in
  [routing.md](routing.md) can be dropped.

### frontend
- Next.js standalone server, `CMD ["node", "server.js"]`, port 3000, runs as UID 1001 (`nextjs`).
- Compose bind-mounts `./frontend/public` over `/app/public`; the image already contains it. In k8s
  either bake Plant Commons assets and `data/settings.json` into the image (simplest, Phase 4) or mount
  a ConfigMap at `/app/public/data/settings.json`.
- Image args: `APP_VERSION` (becomes `RSD_VERSION`, shown by `/api/fe`).
- `ORCID_CLIENT_ID`, `ORCID_WELL_KNOWN_URL`, `LINKEDIN_CLIENT_ID` and `LINKEDIN_WELL_KNOWN_URL` are passed
  to the frontend in compose but are **not read by any frontend code** (see configuration.md). The chart does not
  need to provide them.

### background-services
- No ports, no probes needed beyond process liveness. Run exactly 1 replica.
- Reads only `POSTGRES_DB_HOST`, `POSTGRES_DB_HOST_PORT`, `POSTGRES_DB`, `POSTGRES_USER`,
  `POSTGRES_PASSWORD`. It connects as the superuser role `rsd`, so it needs the database but not PostgREST.

## Optional services: what breaks if omitted

### scrapers (profile `scrapers`)
- The image is **one container running `cron -f`** with `jobs.cron` inside, not a set of Kubernetes
  CronJobs: git basic data/commits/contributors/programming languages, package managers, DOI
  releases/mentions/citations, ROR organisation data, and the "aggregator" (every minute) for
  federated RSD instances; plus the NASSA and ESCAPE OSSR scrapers (nightly, for NLeSC only).
  Deploy it as a 1-replica Deployment, not a CronJob. `printenv > /etc/environment` copies the env into
  cron, so env-from-Secret works.
- If omitted: the site works fully. Nothing is scraped, so repository stats (commits, contributors,
  languages), package-manager data, DOI-derived mention/release/citation metadata and ROR organisation data are
  never refreshed after a user adds them; remote RSD aggregation does not run.
- Egress to GitHub/GitLab/Codeberg/Zenodo/Crossref/OpenAlex/ROR is required if enabled; rate-limit
  settings are the `MAX_REQUESTS_*` vars. Without `API_CREDENTIALS_GITHUB` the GitHub scraper is heavily
  rate-limited.
- Keep `ENABLE_NASSA_SCRAPER` and `ENABLE_ESCAPE_OSSR_SCRAPER` `false` (NLeSC-only per `.env.example`).

### codemeta
- A Go service (`/metadata/codemeta/`), plus an optional nightly 4TU scraper (`ENABLE_4TU_SCRAPER`, NLeSC only).
- **Does the frontend call it? No.** `grep -rn "metadata/codemeta"` finds it only in `nginx.conf`,
  `documentation/docs/02-API/03-codemeta.md`, `codemeta/README.md`, and `backend-tests`. The "CodeMeta"
  download button in the frontend (`citationFormats.ts`) uses a content type
  (`application/vnd.codemeta.ld+json`), not this service.
- If omitted: only the public CodeMeta machine-readable endpoint (`/metadata/codemeta/...`) disappears. The
  documentation page for it would describe a non-existent endpoint (moot if the documentation service
  is also omitted).

### swagger
- Swagger UI pointed at `POSTGREST_URL_EXTERNAL` with `SUPPORTED_SUBMIT_METHODS=[]` (read-only browser).
- Nothing in the frontend, e2e tests, or docs links to `/swagger/`. If omitted: no interactive API explorer;
  the raw OpenAPI document is still at `/api/v1/`.
- Only consumer of `POSTGREST_URL_EXTERNAL`; omit it from the chart if swagger is omitted (compose still needs
  the variable defined, which is why `.env.production.example` sets it).

### documentation (Docusaurus)
- Static site at `/documentation/`. **The frontend links to it extensively**:
  `frontend/config/defaultSettings.json` and `frontend/public/data/settings.json` (menu entries
  `/documentation/users/`, `/documentation/rsd-instance/`), `frontend/components/home/rsd/home_config.ts`
  (home-page links), and "help" links in the software edit forms (`editSoftwareConfig.tsx`,
  `links/config.tsx`).
- If omitted without further changes: those links 404 (they fall through to the Next.js 404 page).
- It is upstream's generic RSD documentation (including how to run an RSD), not Plant Commons
  documentation. Options, to be decided in Phase 3 together with the home page and footer:
  (a) run it as-is (cheapest, upstream-faithful), (b) omit it and repoint/remove the links through
  `settings.json` and the Plant Commons home page, which leaves some hard-coded links in the edit forms,
  or (c) run it with customised content. **Proposed default: (a) run it**, because (b) cannot be done
  without editing several upstream components.

### mail stack: rabbitmq, mail, publisher
- Pipeline: PostgreSQL `pg_notify` -> `publisher` (listens via `LISTEN`) -> RabbitMQ -> `mail` -> SMTP.
  Notifications exist for community join requests (`database/008-create-community-table.sql`) and for access
  tokens (`database/090-access-token.sql`).
- If omitted: those events are silently dropped (`pg_notify` with no listener is a no-op). No
  frontend or auth feature depends on it; login is ORCID, with no e-mail verification.
- Needs an IPK SMTP relay and a RabbitMQ volume if enabled. Not planned.

## Summary of proposed defaults

- Deploy: database, backend, auth, frontend, background-services, plus documentation (see warning).
- Optional, off: scrapers (open question 7), codemeta, swagger, mail stack.
- Never: nginx, data-generation, JDWP, any published database/debug port.
