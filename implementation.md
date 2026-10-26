# Implementation plan: Plant Commons (customized RSD)

Target: `https://plant-commons.ipk-gatersleben.de` on Kubernetes.
Status legend: [ ] todo, [x] done.

## Decisions

| Topic | Decision |
|---|---|
| Base | Snapshot of upstream RSD-as-a-service copied into this repo |
| Customization | Home page `/`: hero/tagline, branding & theme, custom sections |
| Auth | ORCID |
| Packaging | Helm chart `deploy/helm/plant-commons` |
| Database | In-cluster PostgreSQL StatefulSet + PVC |
| Ingress / TLS | Traefik + cert-manager (routes/certs from service registry, TBC) |
| Registry | GitLab/GitHub registry, CI-built images, configurable |

## Open questions / inputs needed

1. **Hero text, tagline and custom section definitions**: the user has them ready but they
   have not been supplied yet. Needed before phase 3 can be finished (use clearly marked
   placeholders until then).
2. **Logo/brand assets and colors**: not confirmed as available; ask or use placeholders.
3. **"Routes and certificates generated from the service registry"**: clarify what this
   means concretely (e.g. a controller that creates Traefik `IngressRoute` + cert-manager
   `Certificate` from annotations/labels on the Service, or an IPK-internal registry).
   Need: annotation/label scheme, ClusterIssuer name, whether the chart should emit
   `Ingress`/`IngressRoute` itself.
4. **GitLab vs GitHub** (which one hosts the repo/CI) and registry hostname.
5. **ORCID** (client id `APP-T1MHJINJKL8PTMXA` supplied 2026-10-26; still to confirm: it is a
   production client, both redirect URIs from configuration.md are registered, who holds the
   client secret): register an ORCID API client (production redirect URI under
   `https://plant-commons.ipk-gatersleben.de`); decide who owns it. Public API vs member API.
6. **Initial admin**: the ORCID-linked account to insert into `admin_account`.
7. **Cluster details**: namespace, storage class for the postgres PVC, image pull secrets,
   any network policies, and whether the scrapers (periodic jobs) are wanted.
8. Imprint/privacy/legal links required by IPK for the footer.

Added in Phase 2 (details in docs/plant-commons/):

9. **`RSD_AUTH_URL`: internal or public?** Code shows it is server-side only (frontend pod ->
   auth), and upstream's own `.env` uses `http://auth:7000/auth`. I used the internal URL in
   `.env.production.example`, which contradicts the wording of CLAUDE.md ("must match
   `https://plant-commons.ipk-gatersleben.de`"). Confirm, then amend CLAUDE.md accordingly
   (configuration.md section 1).
10. **`ORCID:INVITE_ONLY` (recommended) vs `ORCID:EVERYONE`**, and your ORCID iD + name for the
    bootstrap SQL that creates the first admin without an invite (extends question 6;
    configuration.md section 3). Everyone-mode lets any ORCID holder publish software/projects.
11. **Documentation service**: run it (proposed) or drop it? The frontend hard-codes many
    `/documentation/...` links (menu in `settings.json`, home page config, edit-form help links);
    dropping it leaves 404s that need upstream-component edits (services.md). Decide before Phase 3.
12. **Scraper ownership of API tokens** (extends question 7): if scrapers are wanted, who provides
    `API_CREDENTIALS_GITHUB`, `ZENODO_ACCESS_TOKEN`, `OPENALEX_API_KEY`, `LIBRARIES_IO_ACCESS_TOKEN`,
    and which egress is allowed. Also whether to keep `/api/v2` (personal access tokens,
    `RSD_API_ACCESS_TOKEN_ENABLED=true`).
13. **Routing choices** (extends question 3; routing.md lists the six inputs needed): keep the 40M
    body cap on `/api/v1` and `/api/v2` via Traefik Buffering (proposed: yes), Traefik version
    (for Compress `includedContentTypes`), entrypoint names.
14. **ORCID API type** (extends question 5): public API client owned by a person (sufficient) or
    member API owned by IPK, if IPK is an ORCID member.
15. **Egress/NetworkPolicy for the auth pod**: it must reach `orcid.org:443`, and discovery runs
    once at startup with no retry (services.md).

Added in Phase 4 (details in docs/plant-commons/images.md):

16. ~~GitHub or GitLab, registry, pull secret~~ **Answered:** GitHub (`origin` =
    `https://github.com/feserm/plant-commons.git`), registry ghcr.io, images public, so no `imagePullSecrets`.
    Namespace defaults to `feserm/plant-commons` (repository path); confirm if IPK wants another owner.
    ghcr.io packages start private: make them public once after the first push.
17. ~~Run the documentation image?~~ **Answered: no** (resolves question 11 as "drop"). Consequence for Phase 3:
    the hard-coded `/documentation/...` links will 404 and need handling (settings.json menu, home page
    config, edit-form help links; see services.md). The image is now opt-in (`--only documentation`).
18. **Upstream GitHub workflows**: decision is to leave them for now. The import commit is on `origin/main`, so they
    may run on GitHub; list in images.md section 4. Revisit before the first real CI run.
19. ~~auth `args` / buildx~~ buildx installed (user-level). **Confirmed:** the Phase 5 chart sets exec-form `args`
    (not `command`) for auth (`java -cp auth.jar nl.esciencecenter.rsd.authentication.Main`) and background-services
    (`java -cp background-services.jar nl.esciencecenter.rsd.Main`); no Dockerfile change (images.md 6.1).

Added in Phase 5 (details in docs/plant-commons/chart.md):

20. **Replicas 2 for frontend and backend (and auth)?** Verified stateless (no local state in the code), so 2 is possible
    (`frontend.replicas`, `backend.replicas`, optional PodDisruptionBudget). Default is 1 everywhere until you decide; it also
    depends on question 7 (node count).
21. **NetworkPolicy: enable it, and what is the ORCID egress rule?** The chart can render default-deny ingress plus the allow rules
    that really exist (needs `networkPolicy.ingressFrom` = your ingress controller's pods) and, optionally, egress rules. Plain
    NetworkPolicy cannot match `orcid.org`, so `networkPolicy.egress.orcid` needs CIDRs or a CNI-specific FQDN policy (Cilium/Calico).
    Which CNI is it? (extends 15)
22. **Cluster storage details** (extends 7): namespace name, storage class and PVC size (default 10Gi is a placeholder), and whether the
    storage class honours `fsGroup` (the database runs as uid 999 and needs a group-writable volume; the alternative is root + capabilities).
23. **Resource numbers are estimates, not measurements** (`values.yaml`); no CPU limits by default. Revisit after the first real run (Phase 6).
24. **Schema validation of the rendered manifests in CI** needs network access (kubeconform downloads its schemas from
    raw.githubusercontent.com; it has none bundled). It is a commented step. Allow it, or vendor the schemas?
25. **Swagger and scrapers**: implemented but off. Do you want swagger at `/swagger/` (needs routing)? Scrapers are question 7/12.

## Phases

### 1. Import upstream
- [x] Choose the upstream release tag (latest stable release) and copy the source into this
      repo (frontend, backend-postgrest, authentication, database, nginx, scrapers,
      `docker-compose.yml`, `.env.example`). Exclude upstream `.git`.
- [x] Add `UPSTREAM.md` (repo URL, tag, commit, date, licence note: Apache-2.0 upstream;
      keep LICENSE/NOTICE files).
- [x] `git init`, `.gitignore` (`.env`, build output, `node_modules`), initial commit.
- [x] Run the stack locally with `RSD_AUTH_PROVIDERS=LOCAL` to confirm the baseline works.
      Needs `docker-compose.no-bind-mounts.yml` here (home is on NFS; see Upstream findings).

### 2. Configuration for production
- [x] Decide which services to run in k8s: database, backend (PostgREST), auth, frontend,
      background-services, scrapers (optional), swagger (optional). The upstream nginx is
      replaced by Traefik routing; replicate its path routing (`/` -> frontend, `/api/v1` ->
      PostgREST, `/auth` -> auth service, `/image`, `/swagger` as needed). Check upstream
      `nginx.conf` for the exact rules, including header/cache settings.
      Done: [docs/plant-commons/services.md](docs/plant-commons/services.md) (decision table) and
      [docs/plant-commons/routing.md](docs/plant-commons/routing.md) (Traefik-neutral spec; manifests
      wait for open question 3).
- [x] Set `POSTGREST_URL_EXTERNAL`, `RSD_AUTH_URL` and `RSD_AUTH_PROVIDERS=ORCID` plus ORCID
      client id/secret/redirect URI per upstream `.env.example`.
      Done in [`.env.production.example`](.env.production.example) (placeholders only;
      `docker compose config` validated, no gaps) and explained in
      [docs/plant-commons/configuration.md](docs/plant-commons/configuration.md). Decisions
      pending your confirmation: `RSD_AUTH_URL` internal, `ORCID:INVITE_ONLY` (open questions 9, 10).
- [x] Document all env vars used per service. Lives in
      [docs/plant-commons/configuration.md](docs/plant-commons/configuration.md); the chart README
      (Phase 5) will link to it rather than duplicate it.

### 3. Home page customization (`frontend/`)
**Skipped for now (frontend is stock upstream).** The image build is parameterised, so Phase 3 only needs a
rebuild (docs/plant-commons/images.md section 8).

- [ ] Locate the `/` page and its components in the upstream Next.js app.
- [ ] Centralize Plant Commons content/config (hero title, tagline, CTAs, section data) in
      one config module.
- [ ] Hero / landing section.
- [ ] Custom sections (as defined by the user, TBD).
- [ ] Branding: logos, favicon, theme colors/fonts (MUI theme + Tailwind/DaisyUI config as
      used upstream), footer and legal links, page title/metadata.
- [ ] Keep or hide default RSD home elements as decided; mark edits with `PLANT-COMMONS`.
- [ ] Verify responsive layout, light/dark behaviour (if upstream supports it), and
      accessibility basics. Run upstream lint/tests (`pnpm lint`, `pnpm test`) in `frontend/`.

### 4. Images and CI
- [x] Dockerfiles: reuse upstream ones for auth, backend, database, scrapers; build the
      customized frontend image. Tag images with git SHA / release.
      Done: [`deploy/build-images.sh`](deploy/build-images.sh) (upstream Dockerfiles unchanged; frontend is
      stock until Phase 3). Built and inspected 7 of 8 images; see docs/plant-commons/images.md.
- [x] CI pipeline (GitLab CI or GitHub Actions, TBC): build, push. Skeletons for both:
      `.github/workflows/plant-commons-images.yml` and `.gitlab-ci.yml` (keep one). Neither executed yet.
- [x] CI: `helm lint`, `helm template`: enabled in Phase 5 as the `chart` job of `.github/workflows/plant-commons-images.yml`
      (runs `deploy/helm/plant-commons/ci/check.sh`). The GitLab stub stays commented; that file is to be deleted.
- [x] Registry/platform decisions: GitHub + ghcr.io, public images (questions 16-19).

### 5. Helm chart (`deploy/helm/plant-commons/`)
- [x] `Chart.yaml`, `values.yaml` (placeholders only), `values.schema.json`, `templates/` for:
  - [x] PostgreSQL StatefulSet + PVC + ClusterIP Service. No init Job: the schema is created at first start from the
        image; upgrades are manual (README, opt-in untested stub Job).
  - [x] PostgREST, auth, frontend, background-services with probes (where they apply) and resource requests; scrapers
        (Deployment running cron) and swagger as optional flags; codemeta and the mail stack skipped.
  - [x] Secrets: references an existing Secret (`existingSecret`); `secrets.create` only for local kind tests.
  - [ ] Traefik routing + cert-manager certificate: `templates/routing.yaml` is written from routing.md but **disabled and
        BLOCKED on open questions 3 and 13**; rendered and linted with placeholder inputs only.
- [x] Values: `image.registry`, `image.namespace`, one `image.tag`, host, storage class, resources, auth provider config.
- [x] `helm lint` and `helm template` clean (`ci/check.sh`: 160+ checks); kubeconform could not run offline (question 24).
      The `kind` smoke test was **not run** (no cluster access in this phase); `examples/values-kind.yaml` and the commands are ready.
- [x] Docs: README next to the chart and [docs/plant-commons/chart.md](docs/plant-commons/chart.md).

### 6. Rollout
- [ ] Create namespace, secrets, ORCID client; `helm upgrade --install` (only with user's
      explicit go-ahead).
- [ ] Insert first admin into `admin_account`; log in via ORCID and verify admin rights.
- [ ] Verify TLS, `/`, login, `/api/v1`, and persistence across postgres pod restarts.
- [ ] Backup/restore strategy for the postgres PVC (e.g. CronJob `pg_dump`) - discuss.

## Risks / notes
- Upstream is actively developed; snapshot drift is the main maintenance cost, hence the
  `PLANT-COMMONS` markers and `UPSTREAM.md`.
- Upstream documents docker-compose + nginx only; Kubernetes deployment is not covered, so
  routing and migration handling must be derived from upstream's compose/nginx files.
- ORCID is the only production login; without a configured provider the instance should not
  be exposed publicly.

## Upstream findings (RSD v6.7.4, commit 708ae25, imported 2026-10-26)

### Baseline check (Phase 1, step 6): passed with an override
`docker compose up --build -d` built all images and started database (healthy), backend
(healthy), auth, background-services, codemeta, swagger, documentation. `frontend` and
`nginx` were never started: `error while creating mount source path
'/home/mfeser/plant-commons/frontend/public': mkdir /home/mfeser/plant-commons: permission
denied`. Cause: `/home/mfeser` is on NFS and mode 750; dockerd runs as root and cannot
create/traverse the bind-mount source. Compose bind-mounts `./frontend/public` and
`./nginx/nginx.conf`. Needs either the repo in a local (non-NFS) path, or a compose override
that avoids bind mounts. Added `docker-compose.no-bind-mounts.yml` (resets frontend volumes,
keeps only the `lets-encrypt` volume on nginx; images already contain `public/` and nginx.conf).
Run: `docker compose -f docker-compose.yml -f docker-compose.no-bind-mounts.yml up --build -d`.
Result: all 9 services up; `/` 200 (title "Home | Research Software Directory"), `/api/v1/` 200
(OpenAPI), `/auth/` 200, `/api/v1/rpc/homepage_counts` 200. Stack removed with `down -v` (test data only).

### Services and images (docker-compose.yml)
| Service | Image / build | Port | Notes |
|---|---|---|---|
| database | build `./database` (postgres:17.11) | 5432 | init SQL baked in; volume `pgdb` |
| backend | build `./backend-postgrest` (PostgREST) | 3500 (admin 3501) | healthcheck `postgrest --ready` |
| auth | build `./authentication` (Java/Javalin) | 7000 | compose entrypoint enables JDWP debug on 5005, **do not copy** to prod |
| background-services | build `./background-services` | - | connects to DB directly |
| frontend | build `./frontend` (Next.js 16, node 26) | 3000 | `./frontend/public` bind-mounted over `/app/public` |
| scrapers | build `./scrapers`, profile `scrapers` | - | optional |
| codemeta | build `./codemeta` | 8000 | |
| swagger | swaggerapi/swagger-ui | 8080 | optional |
| documentation | build `./documentation` | 80 | optional |
| nginx | build `./nginx` (nginx + certbot) | 80/443 | to be replaced by Traefik |
| rabbitmq, mail, publisher | profile `mail` | 5672 / - / 5000 | optional (email) |
| data-generation | profile `data` | - | dev only |

### nginx routing (nginx/nginx.conf)
- `/auth/` -> `auth:7000/auth/`
- `/api/v1/` -> `backend:3500/` (prefix stripped; `client_max_body_size 40M`, sets
  `Content-Location` to `/api/<upstream value>`, `default_type application/json`,
  HTTP/1.1, empty `Connection`)
- `/api/v2/` -> `auth:7000/api/v2/` (40M)
- `/image/<id>` -> `backend:3500/<id>` with `Accept: application/octet-stream`
- `/metadata/codemeta/` -> `codemeta:8000/`
- `/swagger/` -> `swagger:8080/`, `/documentation/` -> `documentation:80/`
- `/` -> `frontend:3000` with websocket upgrade headers; gzip on for css/js/svg
- Note `/api/v1` has no TLS/HSTS logic here; certbot is in the nginx image (not needed with
  cert-manager). Traefik needs StripPrefix for `/api/v1`, `/image` (rewrite to id),
  `/metadata/codemeta`, `/swagger`, `/documentation`; keep `/auth` and `/api/v2` prefixes.

### DB migrations
There is no migration runner. `database/Dockerfile` copies `*.sql`/`*.sh` into
`/docker-entrypoint-initdb.d`, so the schema is created only on first start with an empty
data directory. `000-fill-authenticator-password.sh` seds `POSTGRES_AUTHENTICATOR_PASSWORD`
and `POSTGRES_DB` into `001-setup-basic-roles.sql`. Upgrades are manual: upstream publishes
a migration SQL per release (https://github.com/research-software-directory/RSD-production,
`database-migration/`). For k8s: use the built `rsd/database` image for the StatefulSet
(initdb works with a fresh PVC), and plan a manual/Job step per upgrade.

### Env vars per service (from compose; defaults in `.env.example`)
- **database**: POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_AUTHENTICATOR_PASSWORD
- **backend**: PGRST_DB_URI (built from POSTGRES_AUTHENTICATOR_PASSWORD, POSTGRES_DB_HOST,
  POSTGRES_DB_HOST_PORT, POSTGRES_DB), PGRST_DB_PRE_REQUEST=public.pre_request_hook,
  PGRST_DB_ANON_ROLE, PGRST_DB_SCHEMA, PGRST_SERVER_HOST=backend, PGRST_SERVER_PORT,
  PGRST_ADMIN_SERVER_PORT, PGRST_JWT_SECRET, PGRST_DB_POOL=30, PGRST_DB_POOL_ACQUISITION_TIMEOUT=30
- **auth**: RSD_ENVIRONMENT, POSTGREST_URL, RSD_AUTH_PROVIDERS, ORCID_CLIENT_ID,
  ORCID_WELL_KNOWN_URL, AUTH_ORCID_CLIENT_SECRET, PGRST_JWT_SECRET,
  RSD_API_ACCESS_TOKEN_ENABLED, HOST_URL (+ unused providers: SURFCONEXT, HELMHOLTZID,
  AZURE, LINKEDIN, GITHUB client id/well-known/secret)
- **background-services**: POSTGRES_DB_HOST, POSTGRES_DB_HOST_PORT, POSTGRES_DB, POSTGRES_USER,
  POSTGRES_PASSWORD
- **frontend**: POSTGREST_URL, PGRST_JWT_SECRET, RSD_REVERSE_PROXY_URL (nginx base, used
  server-side), RSD_AUTH_URL, CROSSREF_CONTACT_EMAIL, MATOMO_URL, MATOMO_ID, ORCID_CLIENT_ID,
  ORCID_WELL_KNOWN_URL, LINKEDIN_CLIENT_ID, LINKEDIN_WELL_KNOWN_URL
- **scrapers**: POSTGREST_URL, PGRST_JWT_SECRET, MAX_REQUESTS_*, ENABLE_NASSA_SCRAPER,
  ENABLE_ESCAPE_OSSR_SCRAPER, API_CREDENTIALS_GITHUB, ZENODO_ACCESS_TOKEN,
  CROSSREF_CONTACT_EMAIL, OPENALEX_API_KEY, LIBRARIES_IO_ACCESS_TOKEN
- **codemeta**: ENABLE_4TU_SCRAPER, POSTGREST_URL, PGRST_JWT_SECRET
- **swagger**: API_URL (= POSTGREST_URL_EXTERNAL), SUPPORTED_SUBMIT_METHODS=[]
- **mail/publisher** (optional): MAIL_*, PUBLISHER_JWT_SECRET_KEY, HOST_URL, DB vars
- Secrets: POSTGRES_PASSWORD, POSTGRES_AUTHENTICATOR_PASSWORD, PGRST_JWT_SECRET,
  AUTH_ORCID_CLIENT_SECRET (and PUBLISHER_JWT_SECRET_KEY / MAIL_SMTP_PASSWORD if mail is used).
  `.env.example` defaults point at the ORCID **sandbox** and `RSD_AUTH_PROVIDERS` defaults to
  `SURFCONEXT:EVERYONE;ORCID:INVITE_ONLY;LOCAL:DISABLED`; prod needs ORCID prod
  well-known URL (`https://orcid.org/.well-known/openid-configuration`) and own client id.

### Home page (`frontend/`)
- Route: `frontend/app/page.tsx` (`force-dynamic`, server component). It loads counts, top
  news and RSD settings, then switches on `settings.host.name`: `helmholtz`, `imperial`, else
  default `RsdHome`. Components: `frontend/components/home/{rsd,helmholtz,imperial}/`
  (`rsd/index.tsx`, `JumboBanner.tsx`, `AboutUsSection.tsx`, etc., config in `rsd/home_config.ts`).
  A new `plantcommons` host branch + `components/home/plantcommons/` fits the minimal-diff rule.
- Theme/settings: `frontend/public/data/settings.json` is fetched at runtime from
  `http://localhost:3000/data/settings.json` (falls back to `config/defaultSettings.json`);
  holds host name, modules, theme, logo, links. In compose, `./frontend/public` is
  bind-mounted, so in k8s bake it into the image or mount a ConfigMap at `/app/public/data/settings.json`.
- Static assets (favicons, `images/`, `manifest.json`) live in `frontend/public/`.
- Stack: Next.js 16, React 19, MUI 9, Tailwind 4 (`tailwind.config.js`).
  **Frontend uses npm** (`package-lock.json`, `npm ci`), not pnpm as CLAUDE.md says.
- Footer/header: `components/AppFooter`, `components/AppHeader`; pages (imprint etc.) are
  editable Markdown pages in the admin UI (`meta pages`), useful for legal links.

### Phase 2 findings that affect later phases
- **Phase 5, PostgREST**: compose sets `PGRST_SERVER_HOST=backend`, which cannot be bound in a pod;
  the chart must set `0.0.0.0`. Probe the admin port 3501 (`/ready`, `/live`; to be confirmed in
  the `kind` test).
- **Phase 5, database**: set `PGDATA` to a subdirectory of the PVC mount (`lost+found`).
  `POSTGRES_*` passwords are applied only at first init (rotation needs `ALTER ROLE`).
- **Phase 4/5, auth**: use the image CMD (no JDWP entrypoint, no port 5005). Its CMD is shell
  form, so SIGTERM probably does not reach the JVM (slow shutdown). Provider discovery
  (ORCID well-known) runs once at startup without retry; check `/auth/providers` after rollout.
- **Phase 3**: `/documentation/...` links are hard-coded in several frontend components (see
  question 11). The frontend reads no `ORCID_*` / `LINKEDIN_*` env vars although compose passes them.
  `RSD_REVERSE_PROXY_URL` is used only for plugins (none).
- **Phase 5, routing**: `/image` needs only a prefix strip plus a forced
  `Accept: application/octet-stream`; the nginx `Content-Location` rewrite is malformed
  (`/api//...`) and read by nothing in the repo, so it is dropped (routing.md). The site needs
  HTTPS (cookies are `Secure`).
- **Phase 6**: first admin via SQL (tested against a throwaway `rsd/database` container; see
  configuration.md section 3).
- `.gitignore` now un-ignores `.env.production.example` (it was caught by `.env.*`).

### Phase 4 findings (images and CI)
- Build script: `deploy/build-images.sh`; names `<registry>/<ns>/plant-commons-<service>`, tags
  `<component version>-<sha>`, `sha-<sha>`, optional release tag; OCI + upstream labels; `--push` off by default.
  Default registry is the placeholder `registry.invalid`. Cold build of all images about 16 min, warm about 1 min.
- Docker 29 had **no buildx plugin**, so only the legacy builder worked, and **`codemeta/Dockerfile` needs
  BuildKit** (`COPY --chmod`); the script stops early for it with the classic driver. buildx v0.38.1 was then
  installed user-level (checksum verified); codemeta and backend built through it. `--push` and the registry cache
  (used by CI) were only dry-run.
- Component versions come from compose `image:` lines: database 4.0.0, backend 1.13.0, auth 1.6.0, frontend
  6.7.2, scrapers 2.0.1, codemeta 2.0.0, documentation 5.3.2. `background-services` has no `image:` line
  (falls back to the release, 6.7.4). `frontend/package.json` is also 6.7.2, so compose's `APP_VERSION`
  is not stale; correction to the note under "Other notes". `documentation/package.json` says 5.3.1 vs
  compose 5.3.2 (compose wins).
- **Auth SIGTERM measured:** shell-form CMD leaves `sh` as PID 1; `docker stop` took 10.25 s and ended in exit 137,
  vs 0.54 s / exit 143 with exec-form `args`. Recommendation: chart `args`, no new Dockerfile (images.md 6.1).
  No JDWP/5005 in the image.
- **Non-root:** frontend (uid 1001) and backend (uid 1000) run non-root out of the box. database and the Java
  images start as root; auth and java run fine as uid 10001 with a read-only root filesystem and all capabilities
  dropped (tested). The database entrypoint drops to uid 999; non-root start needs `fsGroup: 999`.
  The documentation image (nginx, port 80) needs root or `NET_BIND_SERVICE` + friends.
- `.dockerignore`: nothing leaks today (root `.env` and `e2e/.env.e2e` are outside every build context; built
  frontend/documentation/database images checked for `.env*`, `*.pem`, tests). Upstream's frontend and
  documentation ignores do not cover `.env`, `.env.production`, `.env.test`. Added `.dockerignore` for
  authentication, background-services, scrapers, codemeta; the script refuses `--push` if an env file is in a
  context.
- No base image is digest-pinned (all tag-pinned); no scanner was run.
- Upstream workflows that would fire on push/PR are listed in images.md section 4. `release.yml` is manual but
  publishes upstream images to ghcr.io.
- `git remote add origin` and `git push -u origin main` were done on request during this phase; only the
  import commit was pushed, the Phase 1-4 work is still staged.

### Phase 5 findings (Helm chart)
- Layout: `templates/_helpers.tpl` (names, labels, image refs, env wiring, pod template, Deployment/Service), `_config.tpl`
  (the ConfigMap data per service, one source for ConfigMap and pod checksum), `_validate.tpl` (render-time guards), one
  file per service, optional `scrapers`, `swagger`, `networkpolicy`, `routing`, `db-migration-job`, `pdb`, `secret`.
  Services are named `database`, `backend`, `auth`, `frontend` (optional `serviceNamePrefix`), so the documented in-cluster URLs hold.
- Guards (schema and template): ORCID only, no `LOCAL`, no `dev`, bare `host`, non-empty non-`latest` tag, non-placeholder namespace, no JDWP/5005,
  secrets `[A-Za-z0-9]`. `helm lint` without the four required values fails on purpose.
- **Measured with docker (see chart.md section 8):** the database runs as uid 999 with all capabilities dropped and its init `sed` works; the default
  `pg_isready` (unix socket) reports ready **during first-start init**, so the probe uses `-h 127.0.0.1`; PostgREST retries the database itself
  (`/live` 200, `/ready` 503, recovers), so no init container; background-services starts without a database; the frontend needs an emptyDir at
  `/app/.next/cache` (else `unhandledRejection mkdir`); cron in the scrapers needs `SETUID`+`SETGID`; swagger needs root + `CHOWN`/`SETUID`/`SETGID` and a writable root.
- `PGRST_DB_URI` is assembled in the pod spec with `$(VAR)` from `POSTGRES_AUTHENTICATOR_PASSWORD` (one source of truth, no fifth Secret key).
- Surprises for Phase 6: (1) with routing disabled nothing exposes the site, and the cluster's mechanism is unknown (3, 13); (2) the auth readiness probe
  (`/auth/`) does not detect a failed ORCID discovery, so check `/auth/providers` after every rollout and expect rolling updates to look healthy
  even then; (3) the Secret is not checked at install time, a missing key shows as `CreateContainerConfigError`; (4) `helm uninstall` leaves the PVC and
  the Secret; (5) a ConfigMap change restarts the database pod too (checksum annotation; harmless but visible); (6) the database needs a storage class
  that honours `fsGroup`; (7) the frontend image reports `rsd_version 6.7.2` at `/api/fe`; (8) the ghcr.io packages must be made public before the first pull.
- Side effect of this phase: `docker run alpine` pulled `alpine:latest` from Docker Hub (a helper to chown a test volume); it was removed again together with
  the test containers, volume and network. No other image was pulled and no schema was fetched.
- Files: `.github/workflows/plant-commons-images.yml` (the `chart` job enabled; `.gitlab-ci.yml` untouched), no upstream file was edited.

### Other notes
- Upstream has no CLAUDE.md/AGENTS.md. `.github/workflows/` (upstream CI) was imported;
  remove/disable before pushing to GitHub. `e2e/.env.e2e` is committed upstream with
  public throw-away test secrets (not real).
- `docker-compose.yml` sets frontend `APP_VERSION: "6.7.2"` even in tag v6.7.4 (upstream quirk).

### Answers received after Phase 5 (2026-10-26)
- Q3/13: routing and TLS come from one entry in the cluster-local service registry, outside the chart; `routing.enabled` stays false.
- Q5/14: ORCID client `APP-T1MHJINJKL8PTMXA` is registered with both redirect URIs. Still open: owner, secret holder, Q6/10 first-admin iD.
- Q16/22: namespace `plant-commons`, images `ghcr.io/feserm/plant-commons`, database PVC 10Gi, storage class `local-ephemeral` (confirmed;
  `nfs-rwx` rejected). Node-local by name: backup plan needed (Phase 6).
- Q20: 1 replica each. Q21: NetworkPolicy ingress+egress with any-destination TCP 443 egress; ingress controller labels still needed.
- Values: `deploy/helm/plant-commons/examples/values-plant-commons.yaml`; `image.namespace` default is now `feserm/plant-commons`.
