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
5. **ORCID**: register an ORCID API client (production redirect URI under
   `https://plant-commons.ipk-gatersleben.de`); decide who owns it. Public API vs member API.
6. **Initial admin**: the ORCID-linked account to insert into `admin_account`.
7. **Cluster details**: namespace, storage class for the postgres PVC, image pull secrets,
   any network policies, and whether the scrapers (periodic jobs) are wanted.
8. Imprint/privacy/legal links required by IPK for the footer.

## Phases

### 1. Import upstream
- [ ] Choose the upstream release tag (latest stable release) and copy the source into this
      repo (frontend, backend-postgrest, authentication, database, nginx, scrapers,
      `docker-compose.yml`, `.env.example`). Exclude upstream `.git`.
- [ ] Add `UPSTREAM.md` (repo URL, tag, commit, date, licence note: Apache-2.0 upstream;
      keep LICENSE/NOTICE files).
- [ ] `git init`, `.gitignore` (`.env`, build output, `node_modules`), initial commit.
- [ ] Run the stack locally with `RSD_AUTH_PROVIDERS=LOCAL` to confirm the baseline works.

### 2. Configuration for production
- [ ] Decide which services to run in k8s: database, backend (PostgREST), auth, frontend,
      scrapers (optional), swagger (optional). The upstream nginx is replaced by Traefik
      routing; replicate its path routing (`/` -> frontend, `/api/v1` -> PostgREST,
      `/auth` -> auth service, `/image`, `/swagger` as needed). Check upstream
      `nginx.conf` for the exact rules, including header/cache settings.
- [ ] Set `POSTGREST_URL_EXTERNAL`, `RSD_AUTH_URL` and `RSD_AUTH_PROVIDERS=ORCID` plus ORCID
      client id/secret/redirect URI per upstream `.env.example`.
- [ ] Document all env vars used per service in the chart README.

### 3. Home page customization (`frontend/`)
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
- [ ] Dockerfiles: reuse upstream ones for auth, backend, database, scrapers; build the
      customized frontend image. Tag images with git SHA / release.
- [ ] CI pipeline (GitLab CI or GitHub Actions, TBC): build, push, `helm lint`,
      `helm template`.

### 5. Helm chart (`deploy/helm/plant-commons/`)
- [ ] `Chart.yaml`, `values.yaml` (placeholders only), `templates/` for:
  - PostgreSQL StatefulSet + PVC + Service; init with upstream `database/` SQL migrations
    (check upstream approach: image with baked-in migrations vs init job).
  - PostgREST, auth, frontend (and optional scrapers as CronJob/Deployment) with
    readiness/liveness probes and resource requests.
  - Secrets (reference existing Secret or create from values; never commit real values).
  - Traefik routing + cert-manager certificate for `plant-commons.ipk-gatersleben.de`
    (per open question 3).
- [ ] Values: `image.registry`, tags, host, storage class, resources, auth provider config.
- [ ] `helm lint` and `helm template` clean; optionally a `kind` smoke test.

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
