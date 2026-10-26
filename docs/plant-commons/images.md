# Plant Commons: container images and CI

Phase 4. Everything below was verified by building and running the images locally (Docker 29.1.3,
legacy builder, no `buildx` plugin installed) on 2026-10-26, from commit `6786371` (RSD v6.7.4).
Companion docs: [services.md](services.md) (which services run), [configuration.md](configuration.md).

All logic lives in [`deploy/build-images.sh`](../../deploy/build-images.sh). CI only calls it.
Upstream Dockerfiles are used unchanged.

## 1. Image list

Name: `${IMAGE_REGISTRY}/${IMAGE_NAMESPACE}/plant-commons-<service>`.

| Service | Build context | Built by default | Component version (source) | Size (local) |
|---|---|---|---|---|
| `database` | `database/` | yes | 4.0.0 (compose `image:`) | 640 MB |
| `backend` (PostgREST) | `backend-postgrest/` | yes | 1.13.0 (compose) | 28 MB |
| `auth` | `authentication/` | yes | 1.6.0 (compose) | 467 MB |
| `frontend` | `frontend/` | yes | 6.7.2 (`frontend/package.json`) | 522 MB |
| `background-services` | `background-services/` | yes | 6.7.4 (no `image:` line upstream: falls back to the upstream release from `UPSTREAM.md`) | 434 MB |
| `documentation` | `documentation/` | no, `--all`/`--only` (decided: not run) | 5.3.2 (compose) | 256 MB |
| `scrapers` | `scrapers/` | only with `--all` / `--only` | 2.0.1 (compose) | 710 MB |
| `codemeta` | `codemeta/` | only with `--all` / `--only`; **needs BuildKit (buildx)** | 2.0.0 (compose) | 411 MB |

Never built or published: `nginx` (replaced by Traefik), `data-generation`, `mail`, `publisher`,
`rabbitmq`; `swagger` uses the upstream image `swaggerapi/swagger-ui:v5.32.6` as is.

Sizes are the uncompressed sizes `docker images` reports (containerd store); registry transfer is smaller.

## 2. Naming and tags

Per image, three kinds of tags:

| Tag | Example | Meaning |
|---|---|---|
| `<component version>-<short sha>` | `auth:1.6.0-6786371` | readable: which upstream component version, which commit |
| `sha-<short sha>` | `auth:sha-6786371` | the **same tag for all services** of one commit. Not really "moving": there is one per commit and it is never reused. Recommended for the chart: one `image.tag` value deploys a consistent set |
| `<git tag>` | `auth:v0.1.0` | only when built from a git tag (`GIT_TAG`, `CI_COMMIT_TAG`, or a tag on `HEAD`) |

**Digests (platform).** For a release the chart can pin each component to its content digest in addition to the tag
(`image.digests.<component>`, rendered `repo:tag@sha256:...`; keys `auth`, `backend`, `frontend`, `background-services`, `scrapers`, `database`). The digest of a pushed image is printed
by the push (`docker buildx imagetools inspect <ref>` or `docker inspect --format '{{index .RepoDigests 0}}'`); the CI does not collect them yet. With the platform database the
`plant-commons-database` image is **not run** (no StatefulSet): only the optional migration Job borrows its `psql` (PostgreSQL 17, like the server). Its `*.sql`/`*.sh` payload is superseded by
`deploy/postgres/init.sql` ([database.md](database.md)); the image keeps building because the chart's own database (kind/local tests) and the Job use it.

No `latest` tag is ever produced. A work tree with uncommitted changes to tracked files gets `-dirty`
appended to the short sha, and `--push` refuses such a tree.

**Frontend version.** `APP_VERSION` (shown as `RSD_VERSION` by `/api/fe`) is taken from
`frontend/package.json`, overridable with `FRONTEND_APP_VERSION`. Note that this is `6.7.2` too:
upstream's compose value `6.7.2` is not stale relative to `package.json`. Upstream versions each component
separately and `6.7.2` is simply the last release that touched the frontend. The upstream *release*
(`v6.7.4`) is in the labels, not in the version.

Labels on every image: `org.opencontainers.image.{title,version,revision,created,source,licenses,base.name}`
and `de.ipk-gatersleben.plant-commons.upstream.{repository,tag,commit}` (from `UPSTREAM.md`).
`source` comes from `IMAGE_SOURCE`, else from `git remote origin` with credentials stripped. The only
build argument is `APP_VERSION`; no secrets are passed to any build.

## 3. Building locally

```bash
./deploy/build-images.sh                      # core images (database backend auth frontend background-services), build only, tags registry.invalid/plant-commons/...
./deploy/build-images.sh --only frontend      # one image (comma separated or repeated)
./deploy/build-images.sh --all                # plus documentation, scrapers, codemeta
./deploy/build-images.sh --dry-run --push     # print the docker commands, run nothing
IMAGE_REGISTRY=registry.example.org IMAGE_NAMESPACE=ipk/plant-commons ./deploy/build-images.sh --push   # after `docker login`
```

Without `IMAGE_REGISTRY` the placeholder `registry.invalid` (a reserved TLD that cannot resolve) is
used, so a local build can never be pushed by accident. Cold build of the whole set: about 16 minutes
(Maven and npm downloads dominate); rebuild with warm layers: about 1 minute.

Two pitfalls found while building:

- **`codemeta/Dockerfile` uses `COPY --chmod`, which the legacy builder rejects** (it fails after minutes
  of work). Docker 29 without the `buildx` plugin cannot use BuildKit, not even with `DOCKER_BUILDKIT=1`.
  The script checks this up front and stops with a message when the classic driver is in use. Phase 1's
  compose build worked because compose has its own BuildKit client. buildx v0.38.1 is now installed for the
  user (`~/.docker/cli-plugins/docker-buildx`, SHA-256 checked against the release's `checksums.txt`), the
  script picks it automatically, and `--only codemeta,backend` built through it (`docker buildx build --load`).
  The registry cache flags and `--push` still need the CI `docker-container` builder and were not run.
- Home is on NFS; plain `docker build` is fine (only bind mounts break, see implementation.md).

Dry run with placeholder values (buildx driver, release tag, cache), as CI would call it:

```
$ IMAGE_REGISTRY=registry.example.org IMAGE_NAMESPACE=ipk/plant-commons GIT_TAG=v0.1.0 BUILD_DRIVER=buildx \
  BUILD_CACHE_FROM='type=registry,ref=registry.example.org/ipk/plant-commons/plant-commons-{service}:buildcache' \
  ./deploy/build-images.sh --dry-run --push --only frontend
docker \
  buildx \
  build \
  -f frontend/Dockerfile \
  -t registry.example.org/ipk/plant-commons/plant-commons-frontend:6.7.2-6786371 \
  -t registry.example.org/ipk/plant-commons/plant-commons-frontend:sha-6786371 \
  -t registry.example.org/ipk/plant-commons/plant-commons-frontend:v0.1.0 \
  --label org.opencontainers.image.title=plant-commons-frontend \
  ... (labels) ...
  --build-arg APP_VERSION=6.7.2 \
  --cache-from type=registry,ref=registry.example.org/ipk/plant-commons/plant-commons-frontend:buildcache \
  --push \
  frontend
```

(With the classic builder the script runs `docker build` and then `docker push` per tag. The buildx
path was executed locally for build-only (`--load`); `--push` and the registry cache were only dry-run.)

## 4. CI

Two skeletons, both thin. The repo's `origin` is `https://github.com/feserm/plant-commons.git` and the
registry is ghcr.io (confirmed), so **`.github/workflows/plant-commons-images.yml` is the one to keep**;
delete `.gitlab-ci.yml`. For ghcr.io set `IMAGE_REGISTRY=ghcr.io` (repository variable); `IMAGE_NAMESPACE`
defaults to `github.repository`, i.e. `feserm/plant-commons`, giving `ghcr.io/feserm/plant-commons/plant-commons-<service>`.
Images are public, so the chart needs no `imagePullSecrets`. A ghcr.io package is private on first push:
make each package public once (package settings), or pulls will fail. Neither was executed (no push to a CI system was possible here); the YAML parses, and
`actionlint` was not run.

| Event | GitHub Actions / GitLab CI | What happens |
|---|---|---|
| pull request / merge request | `images` (PR path) / `images:build` | `build-images.sh`, build only, registry cache read-only, no login |
| push to `main` | `images` / `images:publish` | login, `build-images.sh --push`, registry cache written |
| push of tag `v*` | same | same, plus the release tag |
| manual | `workflow_dispatch` (GitHub only) | same as push |

Cache: registry cache (`type=registry,...:buildcache`, one cache tag per image) via buildx with a
`docker-container` builder. It needs a registry that supports OCI image manifests (ghcr.io and GitLab's do).
Cache refs reuse `IMAGE_REGISTRY` / `IMAGE_NAMESPACE`, so nothing is hard-coded.

Variables CI needs (names only):

| Name | Kind | Purpose |
|---|---|---|
| `IMAGE_REGISTRY` | variable | registry host[:port] (**open question 4**) |
| `IMAGE_NAMESPACE` | variable | path below the registry; defaults to the repository path |
| `REGISTRY_USER`, `REGISTRY_PASSWORD` | secret | push credentials (for ghcr.io: GitHub user and a token with `write:packages`; never commit) |
| `IMAGE_BUILD_ARGS` | variable, optional | extra script flags, e.g. `--all` |

Predefined and set by the pipelines themselves: `IMAGE_SOURCE`, `GIT_TAG` / `CI_COMMIT_TAG`, `IMAGES_FILE`,
`BUILD_CACHE_FROM`, `BUILD_CACHE_TO`.

Optional and **not enabled** in either file (commented): a Trivy scan job and the Phase 5 `helm lint` /
`helm template` job. Third-party actions are referenced by major version; pin them to commit SHAs before
the first real run (cannot be verified offline).

### Upstream workflows that fire on our pushes (`.github/workflows/`, not touched: decision is to leave them for now)

Evaluated from the `on:` blocks. They add noise and cost; the import commit
has already been pushed to `origin/main`, so some of these may already have run.

| Workflow | Fires on | Problem for us |
|---|---|---|
| `authentication_tests`, `background_services_tests`, `codemeta_tests`, `database_tests`, `scrapers_tests`, `frontend_tests` | push to `main` / PRs touching their directory (a first push of a new branch counts every file as changed) | slow, pointless for a deployment repo |
| `backend_tests` | push / PR touching `authentication`, `backend-postgrest`, `codemeta`, `database`, `backend-tests` | starts the compose stack |
| `e2e_tests_chrome` | push / PR touching `authentication`, `backend-postgrest`, `database`, `e2e`, `frontend`, `nginx` | full stack + browser; **uses `e2e/.env.e2e`** (public throw-away values) |
| `*_sonar` (5) | `workflow_run` after the matching tests | need SonarCloud secrets, fail without them |
| `cff_validate` | push to `main` touching `CITATION.cff` | harmless |
| `editorconfig-check`, `prettier-check`, `fair_software` | pull requests | lint noise on upstream files |
| `_*.yml` | `workflow_call` only | fire only through the others |
| `all_tests`, `e2e_tests_firefox`, `codemeta_scan_build`, `release`, `reuse_compliance` | `workflow_dispatch` only | manual; `release.yml` builds and publishes **upstream's** images to ghcr.io if someone runs it |

## 5. `.dockerignore` audit

Only the build **context directory** is relevant (the repo root is never a context), so the root `.env`
(git-ignored, exists locally) and `e2e/.env.e2e` are not sent to the daemon. Checked every context and the
built images:

| Context | Upstream `.dockerignore` | How the Dockerfile uses the context | Finding |
|---|---|---|---|
| `database` | none | `COPY *.sh *.sql` | safe; nothing else reaches the image |
| `backend-postgrest` | none | no `COPY` | safe |
| `authentication`, `background-services`, `scrapers` | none | `COPY pom.xml`, `COPY ./src` | safe today; a local `target/` would be sent to the daemon (build speed only) |
| `codemeta` | none | `COPY src`, two named files | same |
| `frontend` | yes: ignores `node_modules`, `.next`, `.env.local`, `.env.*.local`, `.vercel`, coverage | `COPY . .` in the builder stage; final image gets only `public/` and `.next/` | upstream list does **not** cover `.env`, `.env.production`, `.env.development`, `.env.test` (Next.js reads them at build time). None exist today. Final image checked: no `.env*`, no `*.pem`, no `e2e/`, no tests |
| `documentation` | yes (same list) | `COPY . .` in builder; final image gets only the static build | same gap, nothing leaks |

Added (new files, `PLANT-COMMONS` comment): `.dockerignore` in `authentication/`, `background-services/`,
`scrapers/`, `codemeta/` (ignores `target`, `.env*` except `*.example`, `.idea`, `*.iml`). Not added:
`database/`, `backend-postgrest/` (nothing to ignore), and nothing for `frontend/` / `documentation/`, whose
upstream files must not be edited. Compensating control in the script: it **fails `--push`** (warns
otherwise) if any `.env*` file (other than `*.example`) exists inside a build context. A merge risk:
if upstream later adds its own `.dockerignore` to one of the four directories, that is an add/add conflict
to resolve by taking upstream's file.

Not a leak but worth knowing: the frontend image ships 96 browser source maps in `.next/static` and 56
server source maps (open-source code, no secrets), and `public/` (38 MB, includes video).

## 6. Image review

Base image of every build stage (all from the upstream Dockerfiles). **None is pinned by digest**; all use a
version tag. The digests below are what the tag resolved to in the local image store at review time
(offline fact, taken from `RepoDigests`), useful for a later pin:

| Reference | Used by | Local digest |
|---|---|---|
| `postgres:17.11` | database | `sha256:b8faeff7...2408fe` |
| `postgrest/postgrest:v14.17` | backend | `sha256:c9dc201e...030f2c` |
| `eclipse-temurin:25.0.4.1_1-jre-noble` | auth, background-services, scrapers | `sha256:3f2223fe...bc13a5` |
| `maven:3.10.0-eclipse-temurin-25-noble` | auth, background-services, scrapers (builder) | `sha256:8e20356c...7f6a82` |
| `node:26.12.1-trixie-slim` | frontend, documentation (deps/builder/runner) | `sha256:36793bcb...f22761ec` |
| `nginx:1.30.2-alpine-slim` | documentation | `sha256:2c605dbe...b3d13b` |
| `golang:1.26.1-trixie`, `ubuntu:24.04` | codemeta | `sha256:1d414b03...f7234a`, `sha256:68ee2200...aff33ac` |
| `nginx:1.30.2` | nginx (not built) | n/a |

Version tags are fairly specific (they include patch levels), so drift is limited to rebuilds of the same tag.
Digest pinning would need an edit of every upstream Dockerfile, which conflicts with the merge strategy;
a Renovate/Dependabot-style bot is not worth it on a snapshot. Not done, as requested.

Review results (`docker image inspect`, `docker run --entrypoint ...` with no production env):

| Image | User | Exposed | ENTRYPOINT / CMD | Notes for Phase 5 |
|---|---|---|---|---|
| database | **root** at start; `docker-entrypoint.sh` drops to `postgres` (uid 999) via gosu | 5432 | `docker-entrypoint.sh` / `postgres`; stop signal SIGINT | Image `PGDATA=/var/lib/postgresql/data`; set it to a subdirectory (services.md). Works as non-root too: `/docker-entrypoint-initdb.d` is mode 777 and the scripts are owned by `postgres`, so the init `sed` works. Then the PVC must be writable for uid 999: use `runAsUser: 999`, `fsGroup: 999` (or run as root and let the entrypoint chown, which needs `CHOWN`/`SETUID`/`SETGID`). The dir is declared `VOLUME`; mount the PVC there |
| backend | **uid 1000** (not root). No shell, no `id` in the image | 3000 (stale: we use 3500/3501) | none / `/bin/postgrest` | Fine with `runAsNonRoot`, `readOnlyRootFilesystem`. Use HTTP probes on the admin port; there is no `exec` probe tooling except `postgrest --ready` |
| auth | **root** by default; **runs fine as uid 10001 with `--read-only`, `--cap-drop ALL`, tmpfs `/tmp`** (tested; started Javalin) | none declared (7000 in practice) | `/__cacert_entrypoint.sh` / shell-form `java -cp auth.jar ...Main` | see 6.1 |
| background-services | root by default; same non-root test passed for `java` | none | same entrypoint / shell-form `java ...Main` | same shell-form issue as auth |
| frontend | **non-root: `nextjs`, uid 1001, gid 65534 (nogroup)** | 3000 | `docker-entrypoint.sh` / `node server.js` (exec form) | started with `--read-only`, `--cap-drop ALL`, tmpfs `/tmp` and was `Ready`. `/app` itself is root-owned and read-only for the process; `/app/.next` is writable. Next may write `.next/cache` (image optimisation); mount an `emptyDir` there if that is seen |
| documentation | **root** (nginx master; workers run as `nginx`) | 80 | `/docker-entrypoint.sh` / `nginx -g 'daemon off;'`; stop signal SIGQUIT | Cannot use `runAsNonRoot`: it binds port 80 and writes `/var/cache/nginx`, `/run`. Keep root with `capabilities.drop: [ALL]` and add back `CHOWN SETGID SETUID NET_BIND_SERVICE`, or swap to an unprivileged nginx variant (a non-upstream Dockerfile; not recommended for a docs site) |
| scrapers (optional) | root | none | cacert entrypoint / `printenv > /etc/environment && cron -f` | needs a shell and root (cron); leave as is |
| codemeta (optional) | root | 8000 | `/usr/local/bin/codemeta.sh` (shell-form `CMD`) | cron + root; not built here |

Java 25 (Temurin 25.0.4.1) in all Java images. No `HEALTHCHECK` in any image (probes belong in the chart).

### 6.1 Auth: JDWP and SIGTERM

- **No JDWP and no port 5005 in the image.** Neither `ExposedPorts` nor `CMD` contains them; the debug agent
  comes only from compose's `entrypoint:` override, which the chart must not copy (services.md).
- **SIGTERM does not reach the JVM** (measured, not assumed). Shell-form `CMD`: PID 1 is
  `/bin/sh -c java ...` (dash) and `java` is its child. `docker stop` waited the full 10 s grace period
  and then killed the container (**10.25 s, exit 137**). With the same image and an exec-form command
  (`java -cp auth.jar nl.esciencecenter.rsd.authentication.Main` as the container arguments, which keeps
  the image's cacert `ENTRYPOINT`), the JVM is PID 1, and the container stopped in **0.54 s, exit 143**
  (clean SIGTERM). In Kubernetes the default grace period is 30 s, so each rollout would wait that long
  per auth pod and end with SIGKILL.

Options:

| | Leave it | Thin `deploy/docker/auth.Dockerfile` (`FROM <upstream-built auth> CMD [exec form]`) | **Chart `args`** (recommended) |
|---|---|---|---|
| Image changes | none | one more image layer, a two-step build (build upstream image, then wrap) in the script | none |
| Upstream merges | none | none for upstream files, but a second image build to keep working | none |
| Fix | no: 30 s + SIGKILL on every restart; harmless otherwise (no state to flush) | yes | yes |
| Cost | none | build complexity and a new artifact to version | the main class name `nl.esciencecenter.rsd.authentication.Main` is duplicated in the chart; if upstream renames it the pod fails at start, which the Phase 5 `kind` smoke test shows immediately |

**Recommendation: no image change; set the container `args` in the chart** to
`["java", "-cp", "auth.jar", "nl.esciencecenter.rsd.authentication.Main"]` (not `command`: `args` replaces
the image `CMD` and keeps the cacert `ENTRYPOINT`), and the same for background-services
(`nl.esciencecenter.rsd.Main`, `background-services.jar`). This amends the advice in services.md ("set
neither `command` nor `args`"): the point there was to never use compose's JDWP entrypoint, and an explicit
non-debug exec-form `args` list satisfies that. If you prefer zero duplication, leaving the shell form is
acceptable (slow restarts only).

Not tried: `tini`/`--init` equivalents (`shareProcessNamespace`), unnecessary once the JVM is PID 1.

## 7. Supply chain

Offline, cheap checks only (no scanner was run, nothing was sent to external services):

- Base images: see the table in section 6; none digest-pinned, all tag-pinned. Maven and npm dependencies
  are resolved from lock files (`package-lock.json`; `pom.xml` versions) at build time from the public
  registries; `mvn dependency:go-offline` emitted one warning (`POM for org.jetbrains:annotations:jar:13.0 is
  missing`, harmless).
- `useradd` warning from the frontend base: `nextjs's uid 1001 is greater than SYS_UID_MAX 999` (cosmetic).
- Proposed, not added: a Trivy scan job (`HIGH,CRITICAL`, `--ignore-unfixed`) after the push; present as a
  commented stub in both CI files. It needs network access to Trivy's DB and to the registry. Expect findings
  in Debian/Ubuntu base layers that only a base image bump fixes.
- Proposed, not added: image signing (cosign) and SBOM attestations (`buildx --sbom=true --provenance=mode=max`).

## 8. How Phase 3 plugs in

Phase 3 (home page) is skipped for now, so `plant-commons-frontend` is currently the stock upstream
frontend. Nothing in the build changes when it lands:

- Home page code goes in `frontend/` (the build context) and `frontend/public/` assets and
  `public/data/settings.json` are baked into the image by upstream's `COPY --from=builder /app/public ./public`
  (the decision recorded in services.md). Replace compose's `./frontend/public` bind mount with nothing.
- Rebuild and push the frontend only: `./deploy/build-images.sh --only frontend --push` (CI does this on every
  push to `main` anyway). A new commit gives a new `sha-<short sha>` tag; the other images are rebuilt too in
  CI but are cache hits (identical content, new tag).
- `APP_VERSION` stays the component version from `frontend/package.json`. If Plant Commons wants its own
  version number shown in `/api/fe`, bump `frontend/package.json` (a `PLANT-COMMONS` change) or set
  `FRONTEND_APP_VERSION`.
- `npm ci` is used (not pnpm); the lock file must be committed with every dependency change.
- Runtime settings (`POSTGREST_URL`, `RSD_AUTH_URL`, ...) are not build args, so no rebuild is needed to
  change them; they come from the chart (configuration.md).
