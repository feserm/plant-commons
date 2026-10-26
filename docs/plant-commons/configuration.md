# Plant Commons: production configuration reference

Every environment variable, per service, for `https://plant-commons.ipk-gatersleben.de`
(RSD v6.7.4). Values were checked against the code in `authentication/`, `frontend/`,
`backend-postgrest/`, `background-services/`, `database/`, `scrapers/`, `codemeta/`, `publisher/` and
`mail/`, not only against the comments in `.env.example`. Where code and comment disagree, this file
says so.

Companion files: [`.env.production.example`](../../.env.production.example) (placeholder template, validated with
`docker compose config`), [services.md](services.md), [routing.md](routing.md). The chart README (Phase 5) will
link here.

Legend. **Source**: `Secret` = Kubernetes Secret key (key name = variable name); `ConfigMap` =
non-secret value; `chart` = derived or fixed by the chart, not user-configurable.
**Req.**: yes = the service does not work without it; opt = optional; no = must stay unset/empty.

## 1. Production decisions

| Topic | Value | Why |
|---|---|---|
| Public base URL | `https://plant-commons.ipk-gatersleben.de` (no trailing slash) | CLAUDE.md |
| `HOST_URL` | `https://plant-commons.ipk-gatersleben.de` | Used by auth to build OAuth redirect URIs (section 4) |
| `POSTGREST_URL_EXTERNAL` | `https://plant-commons.ipk-gatersleben.de/api/v1` | Only consumed by swagger (optional) |
| `RSD_AUTH_URL` | **`http://auth:7000/auth`** (in-cluster), not the public URL | See below |
| `POSTGREST_URL` | `http://backend:3500` (in-cluster Service) | Server-side calls from frontend, auth, scrapers, codemeta |
| `RSD_AUTH_PROVIDERS` | `ORCID:INVITE_ONLY` (recommended, section 3) | ORCID only |
| `ORCID_WELL_KNOWN_URL` | `https://orcid.org/.well-known/openid-configuration` | Production ORCID, not sandbox |
| `RSD_ENVIRONMENT` | `prod` | `dev` turns the first user into an admin |

**`RSD_AUTH_URL`: this deviates from the wording in CLAUDE.md** ("`POSTGREST_URL_EXTERNAL` and `RSD_AUTH_URL` must
match `https://plant-commons.ipk-gatersleben.de`"). In the code the variable is read in exactly two
places, both on the Next.js **server**: `frontend/auth/api/getLoginProviders.tsx` (server side
only; in the browser the same function uses the relative path `/auth`) and
`frontend/app/api/fe/token/refresh/route.ts`. `.env.example` itself says `.env` (the server value) is
`http://auth:7000/auth` and only `.env.local` (frontend dev on a laptop) is the public form. The browser never
sees `RSD_AUTH_URL`. Pointing it at the public URL would work, but it would send every login-page render
and token refresh out through Traefik and TLS and back. **Recommendation: internal URL.** If you want
the public form anyway, `https://plant-commons.ipk-gatersleben.de/auth` is the value (see open question 9;
CLAUDE.md should then be amended either way).

## 2. Variables per service

### database (`rsd/database`, PostgreSQL 17)

| Variable | Req. | Secret? | Production value | Source | What it does |
|---|---|---|---|---|---|
| `POSTGRES_DB` | yes | no | `rsd-db` | ConfigMap | Database name. Also sed-substituted into `001-setup-basic-roles.sql` by `000-fill-authenticator-password.sh`; keep it `[a-z0-9-]`. |
| `POSTGRES_USER` | yes | no | `rsd` | ConfigMap | Superuser role. Also used by background-services and by the `pg_isready` probe. |
| `POSTGRES_PASSWORD` | yes | **yes** | `CHANGE_ME` | Secret | Password of `POSTGRES_USER`. **First init only** (empty data dir); later changes of the Secret do not change the DB. |
| `POSTGRES_AUTHENTICATOR_PASSWORD` | yes | **yes** | `CHANGE_ME` | Secret | Password of role `rsd_authenticator`, which PostgREST uses to connect. sed-substituted into SQL at first init (so `/`, `&`, `\` break it) and embedded in `PGRST_DB_URI`. First init only. |
| `PGDATA` | yes (k8s) | no | `/var/lib/postgresql/data/pgdata` | chart | Not in compose. Avoids `lost+found` at a PVC root breaking `initdb` (see services.md). |

### backend (PostgREST)

| Variable | Req. | Secret? | Production value | Source | What it does |
|---|---|---|---|---|---|
| `PGRST_DB_URI` | yes | **yes** (contains password) | `postgres://rsd_authenticator:<POSTGRES_AUTHENTICATOR_PASSWORD>@database:5432/rsd-db` | chart (compose builds it from `POSTGRES_AUTHENTICATOR_PASSWORD`, `POSTGRES_DB_HOST`, `POSTGRES_DB_HOST_PORT`, `POSTGRES_DB`) | Connection string. Build it in the pod spec from the Secret value (Kubernetes `$(VAR)` expansion) or store the whole URI as a Secret key. The role name `rsd_authenticator` is fixed by `database/001-setup-basic-roles.sql`. |
| `PGRST_DB_PRE_REQUEST` | yes | no | `public.pre_request_hook` | chart (fixed) | Function in `database/950-pre-request-hook.sql`; rejects requests from locked accounts. Must be set or locks are not enforced. |
| `PGRST_DB_ANON_ROLE` | yes | no | `rsd_web_anon` | ConfigMap | Role for unauthenticated requests. |
| `PGRST_DB_SCHEMA` | yes | no | `public` | ConfigMap | Exposed schema. |
| `PGRST_SERVER_HOST` | yes | no | **`0.0.0.0`** | chart | Compose hardcodes `backend`, which cannot be bound in a pod (see services.md). |
| `PGRST_SERVER_PORT` | yes | no | `3500` | ConfigMap | API port. |
| `PGRST_ADMIN_SERVER_PORT` | yes | no | `3501` | ConfigMap | Admin port for `/ready` and `/live`; **never route it publicly**. |
| `PGRST_JWT_SECRET` | yes | **yes** | `CHANGE_ME` (>= 32 chars) | Secret | HS256 key that validates the JWTs signed by the auth service. |
| `PGRST_DB_POOL` | opt | no | `30` | chart | Connection pool size (compose hardcodes 30; PostgreSQL's default `max_connections` is 100). |
| `PGRST_DB_POOL_ACQUISITION_TIMEOUT` | opt | no | `30` | chart | Seconds to wait for a pooled connection. |

### auth (Java/Javalin, port 7000)

Read in `Config.java`, `RsdProviders.java`, `Main.java`. No debugger flags (see services.md).

| Variable | Req. | Secret? | Production value | Source | What it does |
|---|---|---|---|---|---|
| `RSD_AUTH_PROVIDERS` | yes | no | `ORCID:INVITE_ONLY` | ConfigMap | Provider list and access mode; format in section 3. If unset or all providers disabled, nobody can log in. |
| `ORCID_CLIENT_ID` | yes | no | `CHANGE_ME_APP-XXXXXXXXXXXXXXXX` | ConfigMap | OAuth client id of the **production** ORCID client. Public (appears in the authorize URL). |
| `ORCID_WELL_KNOWN_URL` | yes | no | `https://orcid.org/.well-known/openid-configuration` | ConfigMap | OpenID discovery. Authorize URL (at startup, once) and token endpoint (on each login) are read from it. |
| `AUTH_ORCID_CLIENT_SECRET` | yes | **yes** | `CHANGE_ME` | Secret | ORCID client secret, sent in the token request. |
| `HOST_URL` | yes | no | `https://plant-commons.ipk-gatersleben.de` | ConfigMap | Prefix of the redirect URIs. Must match what is registered at ORCID **exactly** (scheme, host, no trailing slash). |
| `PGRST_JWT_SECRET` | yes | **yes** | same Secret key as the backend | Secret | Signs the JWT (`rsd_token` cookie) and the admin/anon JWTs the auth service uses to call PostgREST. |
| `POSTGREST_URL` | yes | no | `http://backend:3500` | ConfigMap | Internal PostgREST base URL (accounts, logins, invites). |
| `RSD_API_ACCESS_TOKEN_ENABLED` | opt | no | `true` | ConfigMap | Registers `/auth/accesstoken` and the `/api/v2/*` proxy (only exactly `true` enables it). |
| `RSD_ENVIRONMENT` | yes | no | `prod` | ConfigMap | Only the literal `dev` matters: first login becomes admin if `admin_account` is empty, and SURFconext forces re-login. Anything else is prod behaviour. |
| `SURFCONEXT_*`, `HELMHOLTZID_*`, `AZURE_*`, `LINKEDIN_*`, `GITHUB_*`, `AUTH_<those>_CLIENT_SECRET` | no | | **leave unset** | n/a | Read only when the provider is active in `RSD_AUTH_PROVIDERS`. Do not copy the upstream example values (section 6). `AZURE_DISPLAY_NAME`/`AZURE_DESCRIPTION_HTML` are labelled "consumed by: frontend" in `.env.example` but are read by the **auth** service (`RsdProviders.java`). |

### background-services

| Variable | Req. | Secret? | Production value | Source | What it does |
|---|---|---|---|---|---|
| `POSTGRES_DB_HOST` | yes | no | `database` (Service name) | ConfigMap | Direct DB connection (no PostgREST). |
| `POSTGRES_DB_HOST_PORT` | yes | no | `5432` | ConfigMap | |
| `POSTGRES_DB` | yes | no | `rsd-db` | ConfigMap | |
| `POSTGRES_USER` | yes | no | `rsd` | ConfigMap | |
| `POSTGRES_PASSWORD` | yes | **yes** | `CHANGE_ME` | Secret | Superuser password. |

### frontend (Next.js 16, port 3000)

`PORT=3000`, `HOSTNAME=0.0.0.0` and `NODE_ENV=production` are set in the image (`frontend/Dockerfile`).

| Variable | Req. | Secret? | Production value | Source | What it does |
|---|---|---|---|---|---|
| `POSTGREST_URL` | yes | no | `http://backend:3500` | ConfigMap | Server-side data fetching (`utils/fetchHelpers.ts` `getBaseUrl()`, `apiOrganisations.ts`). If unset it falls back to the relative `/api/v1`, which does not work for server-side `fetch`. |
| `PGRST_JWT_SECRET` | yes | **yes** | same Secret key | Secret | Verifies the `rsd_token` cookie on the server (`auth/jwtUtils.ts`). Must be identical to auth's and PostgREST's. |
| `RSD_AUTH_URL` | yes | no | `http://auth:7000/auth` | ConfigMap | Server-side login-provider list and token refresh (section 1). |
| `RSD_REVERSE_PROXY_URL` | opt | no | `https://plant-commons.ipk-gatersleben.de` | ConfigMap | Only used to load plugin configs from `${url}/plugin/<name>` (`config/getPlugins.ts`); Plant Commons configures no plugins. Defaults to `http://nginx`, a hostname that will not exist in the cluster. Set it so it never points at a dead host. |
| `CROSSREF_CONTACT_EMAIL` | opt | no | mailbox IPK monitors | ConfigMap | Sent as `mailto` to Crossref's "polite pool" for DOI lookups (`utils/getCrossref.ts`). Not a secret. |
| `MATOMO_URL` | opt | no | empty (or IPK Matomo URL with trailing slash) | ConfigMap | Matomo tracking. Both `MATOMO_URL` and `MATOMO_ID` must be set to enable. |
| `MATOMO_ID` | opt | no | empty | ConfigMap | |
| `RSD_VERSION` | opt | no | build arg `APP_VERSION` | image | Shown by `/api/fe`. Upstream compose passes `6.7.2` even for 6.7.4. |
| `ORCID_CLIENT_ID`, `ORCID_WELL_KNOWN_URL`, `LINKEDIN_CLIENT_ID`, `LINKEDIN_WELL_KNOWN_URL` | no | | **omit** | n/a | Passed by compose but **not read by any frontend code** (`grep` over `frontend/` finds no use). The chart does not need to set them. |

The frontend settings file `public/data/settings.json` is runtime configuration too (Phase 3), but is
not an env var.

### Optional: scrapers

Read in `scrapers/.../Config.java` and the individual scrapers.

| Variable | Req. | Secret? | Production value | Source | What it does |
|---|---|---|---|---|---|
| `POSTGREST_URL` | yes | no | `http://backend:3500` | ConfigMap | |
| `PGRST_JWT_SECRET` | yes | **yes** | same Secret key | Secret | Scrapers mint an admin JWT. |
| `MAX_REQUESTS_GITHUB`, `_GITLAB`, `_4TU`, `_CODEBERG`, `_DOI`, `_OPENALEX`, `_ROR` | opt | no | `6` each | ConfigMap | Per-run request caps (runs ~10x/hour); default 6 if unset. |
| `API_CREDENTIALS_GITHUB` | opt | **yes** | `username:token` | Secret | GitHub API credentials; without it GitHub scraping is heavily rate-limited. |
| `ZENODO_ACCESS_TOKEN` | opt | **yes** | | Secret | |
| `OPENALEX_API_KEY` | opt | **yes** | | Secret | |
| `LIBRARIES_IO_ACCESS_TOKEN` | opt | **yes** | | Secret | Package-manager data. |
| `CROSSREF_CONTACT_EMAIL` | opt | no | same as frontend | ConfigMap | |
| `ENABLE_NASSA_SCRAPER`, `ENABLE_ESCAPE_OSSR_SCRAPER` | opt | no | `false` | ConfigMap | NLeSC-only; only the exact string `true` enables. |

### Optional: codemeta, swagger

| Service | Variable | Value | Source | Notes |
|---|---|---|---|---|
| codemeta | `POSTGREST_URL` | `http://backend:3500` | ConfigMap | |
| codemeta | `PGRST_JWT_SECRET` | same Secret key | Secret | |
| codemeta | `ENABLE_4TU_SCRAPER` | `false` | ConfigMap | NLeSC-only. |
| swagger | `API_URL` | `https://plant-commons.ipk-gatersleben.de/api/v1` (= `POSTGREST_URL_EXTERNAL`) | ConfigMap | Browser-side URL of the API. |
| swagger | `SUPPORTED_SUBMIT_METHODS` | `[]` | chart | Disables "Try it out". |

### Optional: mail stack (rabbitmq, mail, publisher): not planned

| Service | Variables |
|---|---|
| mail | `MAIL_SMTP_SERVER`, `MAIL_SMTP_PORT`, `MAIL_SMTP_SECURITY` (`SSL`/`STARTTLS`), `MAIL_SMTP_LOGIN`, `MAIL_SMTP_PASSWORD` (**secret**), `MAIL_FROM_ADDRESS`, `MAIL_REPLY_TO`, `MAIL_QUEUE` (`mailq`) |
| publisher | `MAIL_QUEUE`, `PUBLISHER_JWT_SECRET_KEY` (**secret**), `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` (**secret**), `POSTGRES_DB_HOST`, `POSTGRES_DB_HOST_PORT`, `POSTGREST_URL`, `HOST_URL`, `PGRST_JWT_SECRET` (**secret**) |

### Docker-compose-only variables (no meaning in Kubernetes)

`COMPOSE_PROJECT_NAME` (Docker project name). The chart builds `PGRST_DB_URI` itself.

## 3. `RSD_AUTH_PROVIDERS` with ORCID only

Format (from `RsdProviders.parseAuthProvidersEnvString`): entries separated by `;`, each
`KEY:VALUE` with exactly one colon. Keys (`SURFCONEXT`, `HELMHOLTZ`, `ORCID`, `AZURE`, `LINKEDIN`,
`GITHUB`, `LOCAL`) are matched case-insensitively; **values are case-sensitive**: `DISABLED`,
`INVITE_ONLY` or `EVERYONE`. A missing key means `DISABLED`; a malformed or duplicate entry means
`MISCONFIGURED` (login for that provider fails with "is misconfigured"). Note: the key for Helmholtz is
`HELMHOLTZ`, while its env vars start with `HELMHOLTZID_` (irrelevant here).

Valid for Plant Commons: `ORCID:INVITE_ONLY` or `ORCID:EVERYONE`. Omit every other provider; do **not**
write `LOCAL:DISABLED` either, to keep the string unambiguous.

| | `ORCID:INVITE_ONLY` | `ORCID:EVERYONE` |
|---|---|---|
| Who can create an account | Only holders of an invite link `https://.../invite/rsd/<id>` created by an admin (admin UI, `account_invite`; single- or multi-use, with expiry). Existing accounts log in normally. | Any person with an ORCID iD, immediately. |
| Who can then publish | Invited users | **Any such account can create software entries**: `database/020-row-level-security.sql` gives every `rsd_user` insert rights on `software` (`WITH CHECK (TRUE)`), and likewise for `project`. |
| Moderation burden | Low (admin controls entry) | High on a public site; spam and abuse are possible; accounts can be locked only after the fact. |
| Operational cost | Admin must issue invites; **first admin needs a bootstrap** (below) | None |

**Recommendation: `ORCID:INVITE_ONLY`.** Plant Commons is a curated IPK-run site, ORCID has no
organisation filter (anyone in the world has an iD), and open registration means open publishing. If
the community later wants self-service sign-up, switch to `EVERYONE`; it is a ConfigMap change plus
a pod restart, and existing accounts are unaffected. (The reverse, `EVERYONE` -> `INVITE_ONLY`, does not remove
accounts that already exist.)

### First admin with `INVITE_ONLY`

Chicken and egg: creating an invite needs admin rights (`account_invite` is `rsd_admin`-only), and an
admin needs an account, which needs an invite. In `INVITE_ONLY` mode `RSD_ENVIRONMENT=dev` does not help (the
dev shortcut only runs after an account exists or is created, and creating one still requires the invite).
Options:

1. **Recommended: create the first account and admin directly in SQL, using your ORCID iD.** The ORCID
   login looks accounts up by `(provider, sub)` where `sub` is the ORCID iD (`0000-0002-1825-0097` form;
   `OrcidLogin` takes `sub` from the ID token), so a pre-created login lets you in without an invite. This
   SQL was run against a throwaway instance of the `rsd/database` image with dummy credentials and produced one
   `login_for_account` row (`provider='orcid'`) plus one `admin_account` row:

   ```sql
   WITH new_account AS (
     INSERT INTO account DEFAULT VALUES RETURNING id
   ), new_login AS (
     INSERT INTO login_for_account (account, provider, sub, name)
     SELECT id, 'orcid', '0000-0000-0000-0000', 'Your Name'   -- your ORCID iD and name
     FROM new_account
     RETURNING account
   )
   INSERT INTO admin_account (account_id) SELECT account FROM new_login;
   ```

   Run it as the `rsd` superuser, e.g. `kubectl exec -i <db-pod> -- psql -U rsd -d rsd-db < first-admin.sql`
   (do this only with your explicit go-ahead on the cluster; Phase 6). The ORCID login then finds the
   account, updates the name from the ID token, and the JWT carries the admin role. The
   `account` insert trigger generates the id, which is why `RETURNING id` is used rather than inserting
   a UUID by hand. Afterwards: log in, open the profile menu -> Administration -> RSD invites.
2. Temporarily `ORCID:EVERYONE`, log in, then insert your account id into `admin_account` as upstream
   documents (`INSERT INTO admin_account VALUES ('<account id>');`, `documentation/docs/03-rsd-instance/01-getting-started.md`),
   then switch back. Simple, but anyone can register while the window is open and those accounts persist.
Further admins: Administration -> RSD users -> assign the administrator role (upstream docs,
`03-administration.md`).

## 4. ORCID

- **Production discovery URL**: `https://orcid.org/.well-known/openid-configuration` (sandbox is
  `https://sandbox.orcid.org/...`; the client id format `APP-...` is the same in both, so the URL is
  the only visible tell).
- **Redirect URIs the auth service sends** (derived from `RsdProviders.obtainRedirectUrl`,
  `obtainCouplingRedirectUrl`, `obtainLoginPath`, `obtainCouplingPath`):
  - Login: `${HOST_URL}/auth/login/orcid` = **`https://plant-commons.ipk-gatersleben.de/auth/login/orcid`**
  - Account coupling: `${HOST_URL}/auth/couple/orcid` = **`https://plant-commons.ipk-gatersleben.de/auth/couple/orcid`**
  (The `www.localhost` special case in the code applies only when `HOST_URL` is `http://localhost`.)
  Register **both** in the ORCID client. The login URI is the one actually needed with ORCID only;
  coupling matters only if a second provider is added later, but registering it costs nothing.
  The same `redirect_uri` value is sent in the authorize request and in the token request, so
  ORCID needs an exact match; a trailing slash on `HOST_URL` would produce `//auth/...` and fail.
- **Scope**: only `openid` is requested (authorize URL and token request). With that scope the service
  gets an ID token whose `sub` is the ORCID iD and whose `name` (or `given_name`/`family_name`)
  is present only if the user made it public. No e-mail is requested, so `login_for_account.email`
  stays empty. No record data is read or written.
- **Public vs member API**: the **public API** client is sufficient, because the service only
  authenticates ("Sign in with ORCID") and uses no member-only features. Trade-offs: a public
  client is registered under an individual's ORCID account (the owner is a person, not IPK; this
  is a continuity risk if they leave); a member API client is owned by an organisation with
  ORCID membership and comes with support. Whether IPK already has ORCID membership (for example through a
  consortium) is not known to me; ask your library/IT (open question 5). Either way the same
  `ORCID_CLIENT_ID` / secret / redirect URIs configuration applies. I did not check ORCID's current
  rules for production redirect URIs (they require HTTPS; confirm in the developer-tools form).
- Users who hide their name at ORCID arrive with no name in the ID token (stored as empty); the code has no fallback.
- Provider discovery happens once at pod start (see services.md): after a cluster egress change or an
  ORCID outage, restart the auth pod and check `GET /auth/providers` returns the ORCID entry.

## 5. Secrets

- **Upstream restriction**: `.env.example` warns that special characters "might corrupt some
  processes". Concretely: `000-fill-authenticator-password.sh` substitutes the authenticator password into
  SQL with `sed s/.../.../` (so `/`, `&`, `\` break it); `PGRST_DB_URI` embeds it unescaped in a URI (`@ : / ? # %`
  break it); and `.env` files and shells mangle `$`, quotes, `#`, spaces. Use **only `[A-Za-z0-9]`**.
- **Safe generation** (hex is alphanumeric; 64 characters satisfies PostgREST's 32-character JWT-secret minimum):

  ```bash
  openssl rand -hex 32
  ```

  Generate one value per secret; do not reuse. Do not paste results into git, chat, or shell history you
  do not control. For example, write them straight into a file readable only by you and create the
  Secret with `kubectl create secret generic ... --from-file=`.
- **Secrets**: `POSTGRES_PASSWORD`, `POSTGRES_AUTHENTICATOR_PASSWORD`, `PGRST_JWT_SECRET`,
  `AUTH_ORCID_CLIENT_SECRET` (from ORCID; any special characters there come from ORCID, so check it works).
  Optional: scraper tokens, `MAIL_SMTP_PASSWORD`, `PUBLISHER_JWT_SECRET_KEY`.
- **Rotation**: `POSTGRES_*` secrets are applied only at first database initialisation, so rotating
  later needs `ALTER ROLE rsd PASSWORD ...` / `ALTER ROLE rsd_authenticator PASSWORD ...` plus a restart of
  the consumers; losing the PVC and re-initialising applies the new values. Rotating `PGRST_JWT_SECRET` logs
  everyone out; it must change in auth, frontend, backend (and scrapers/codemeta) together.

## 6. What must NOT be set (or must be unset) in production

From `.env.example`; every item below is a trap if copied into the cluster.

| Variable | Upstream value | Production |
|---|---|---|
| `RSD_AUTH_PROVIDERS` | `SURFCONEXT:EVERYONE;ORCID:INVITE_ONLY;LOCAL:DISABLED` | `ORCID:INVITE_ONLY` only. Any `LOCAL:EVERYONE` / `LOCAL:INVITE_ONLY` enables passwordless local accounts (any username logs in) and is flagged "not safe for production" in the auth log. `SURFCONEXT:EVERYONE` would open sign-up to Dutch IdPs. |
| `ORCID_CLIENT_ID` | `APP-4D4D69ASWTYOI9QI` (shared sandbox client) | your production client id |
| `ORCID_WELL_KNOWN_URL` | `https://sandbox.orcid.org/...` | `https://orcid.org/...` |
| `SURFCONEXT_CLIENT_ID`, `SURFCONEXT_WELL_KNOWN_URL` | `www.research-software.nl`, `connect.test.surfconext.nl` (test env) | unset |
| `HELMHOLTZID_CLIENT_ID`, `HELMHOLTZID_WELL_KNOWN_URL`, `HELMHOLTZID_SCOPES` | `rsd-dev`, `login-dev.helmholtz.de`, ... | unset |
| `HELMHOLTZID_ALLOW_EXTERNAL_USERS` | commented out | never `true` |
| `AZURE_DISPLAY_NAME`, `AZURE_DESCRIPTION_HTML`, `AZURE_ORGANISATION` | "Imperial College Login", ... | unset |
| `AZURE_*`, `LINKEDIN_*`, `GITHUB_*`, `AUTH_*_CLIENT_SECRET` except ORCID | empty | unset |
| `RSD_ENVIRONMENT` | `prod` | `prod`; never `dev` |
| `HOST_URL`, `POSTGREST_URL_EXTERNAL` | `http://localhost...` | public URLs from section 1 (`http://` would also make the redirect URI mismatch ORCID) |
| `RSD_REVERSE_PROXY_URL` | `http://nginx` | public URL (no nginx in k8s) |
| `ENABLE_4TU_SCRAPER`, `ENABLE_NASSA_SCRAPER`, `ENABLE_ESCAPE_OSSR_SCRAPER` | `false` | `false` |
| `COMPOSE_PROJECT_NAME` | `rsd` | not applicable |

Other things from the repo that must not be carried over:

- `docker-compose.yml`: `auth` `entrypoint` with JDWP on 5005 and `ports: 5005:5005`; `database`
  `ports: 5432:5432`; `PGRST_SERVER_HOST=backend`; `frontend` bind mount of `./frontend/public`.
- `e2e/.env.e2e`: committed, public, throw-away test values, including `LOCAL:EVERYONE` and the sandbox ORCID client.
  Never reuse any value from it.
- `docker-compose.dev.yml`: development frontend image with debug ports 9229/9230.
- `.env.example` contains no dev passwords (the secrets are empty), so there is nothing to scrub there,
  but every secret must be generated, never left empty (PostgREST requires a JWT secret of at least 32 characters).

## 7. Validation done (Phase 2, no containers started)

`docker compose --env-file .env.production.example -f docker-compose.yml -f docker-compose.no-bind-mounts.yml config`
(also with `--profile scrapers --profile mail --profile data`) exits 0 with no "variable is not set" warnings.
Because compose silently drops *bare* `- VAR` environment entries whose variable is unset, I also
extracted every variable referenced in `docker-compose.yml` (68) and compared with the template. Result:
all are defined **except `HELMHOLTZID_ALLOW_EXTERNAL_USERS`**, which is commented out in the upstream
`.env.example` as well; the code treats unset as `false` (`Boolean.parseBoolean`), which is what we want.
The template defines one variable that `.env.example` lacks (`PGRST_SERVER_HOST`, documented above, ignored by compose). The
rendered config shows `HOST_URL`, `API_URL`, `ORCID_WELL_KNOWN_URL`, `RSD_AUTH_PROVIDERS`, `POSTGREST_URL`
and `RSD_AUTH_URL` as intended, and `PGRST_SERVER_HOST: backend` (hardcoded in compose, the
reason the chart must override it).
