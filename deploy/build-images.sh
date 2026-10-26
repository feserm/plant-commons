#!/usr/bin/env bash
# PLANT-COMMONS: single entry point that builds (and optionally pushes) the Plant Commons
# container images from the unmodified upstream Dockerfiles. CI only calls this script.
# Documentation: docs/plant-commons/images.md
#
# Names:  ${IMAGE_REGISTRY}/${IMAGE_NAMESPACE}/plant-commons-<service>
# Tags:   <component version>-<git short sha>[-dirty]   e.g. 1.6.0-6786371
#         sha-<git short sha>[-dirty]                   one tag per commit, same for all services
#         <git tag>                                     only when building from a git tag
#
# No secrets are passed to the build: the only --build-arg is APP_VERSION (frontend).
# Registry login is the caller's job (CI runs `docker login` itself); this script never
# sees credentials.
set -euo pipefail

CORE_SERVICES=(database backend auth frontend background-services)
OPTIONAL_SERVICES=(documentation scrapers codemeta) # documentation: not run (open question 11)
PLACEHOLDER_REGISTRY="registry.invalid" # RFC 6761 reserved TLD: can never resolve, cannot be pushed to

usage() {
  cat <<USAGE
Usage: deploy/build-images.sh [options]

Builds the Plant Commons images from the upstream build contexts.

Options:
  --push             push the images after building (default: build only; refuses a dirty
                     work tree and the placeholder registry)
  --only a,b         build only these services (repeatable). Services:
                       core:     ${CORE_SERVICES[*]}
                       optional: ${OPTIONAL_SERVICES[*]}
  --all              build core and optional services (default: core only)
  --pull             always pull newer base images
  --dry-run          print the docker commands, do not run anything
  -h, --help         this text

Environment:
  IMAGE_REGISTRY       registry host[:port], e.g. registry.example.org  (required for --push)
  IMAGE_NAMESPACE      path below the registry, lower-cased automatically (required for --push)
  IMAGE_SOURCE         URL of this repository for the OCI source label (default: git remote
                       "origin" with credentials stripped; label omitted if unknown)
  GIT_TAG              release tag to add as an image tag (default: \$CI_COMMIT_TAG, then the
                       git tag pointing at HEAD, if any)
  FRONTEND_APP_VERSION overrides APP_VERSION / the frontend tag (default: frontend/package.json)
  BUILD_DRIVER         auto (default) | buildx | classic
  BUILD_PLATFORM       e.g. linux/amd64 (passed as --platform when set)
  BUILD_CACHE_FROM     buildx --cache-from value; "{service}" is replaced (buildx driver only)
  BUILD_CACHE_TO       buildx --cache-to value; same placeholder (buildx driver only)
  IMAGES_FILE          if set, "<service> <image:tag>" lines of the primary tags are written here

Without IMAGE_REGISTRY the placeholder ${PLACEHOLDER_REGISTRY} is used, which is fine for local builds.
USAGE
}

die() { echo "build-images: error: $*" >&2; exit 1; }
warn() { echo "build-images: warning: $*" >&2; }

# ---------------------------------------------------------------- arguments
PUSH=0 DRY=0 ALL=0 PULL=0
ONLY=()
while (($#)); do
  case "$1" in
    --push) PUSH=1 ;;
    --dry-run) DRY=1 ;;
    --all) ALL=1 ;;
    --pull) PULL=1 ;;
    --only)
      [[ $# -ge 2 ]] || die "--only needs a value"
      IFS=',' read -r -a _o <<<"$2"
      ONLY+=("${_o[@]}")
      shift
      ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ---------------------------------------------------------------- service table
context_for() {
  case "$1" in
    database) echo database ;;
    backend) echo backend-postgrest ;;
    auth) echo authentication ;;
    frontend) echo frontend ;;
    background-services) echo background-services ;;
    documentation) echo documentation ;;
    scrapers) echo scrapers ;;
    codemeta) echo codemeta ;;
    *) return 1 ;;
  esac
}

if ((${#ONLY[@]})); then
  SERVICES=("${ONLY[@]}")
elif ((ALL)); then
  SERVICES=("${CORE_SERVICES[@]}" "${OPTIONAL_SERVICES[@]}")
else
  SERVICES=("${CORE_SERVICES[@]}")
fi
for s in "${SERVICES[@]}"; do
  context_for "$s" >/dev/null || die "unknown service '$s' (known: ${CORE_SERVICES[*]} ${OPTIONAL_SERVICES[*]})"
done

# ---------------------------------------------------------------- upstream info
# UPSTREAM.md lines look like: - Tag: `v6.7.4`
upstream_field() { sed -n -E "s/^- $1: \`?([^\` ]+)\`?.*/\1/p" UPSTREAM.md | head -n1; }
UPSTREAM_REPO=$(upstream_field Repository)
UPSTREAM_TAG=$(upstream_field Tag)
UPSTREAM_COMMIT=$(upstream_field Commit)
[[ -n $UPSTREAM_TAG && -n $UPSTREAM_COMMIT ]] || die "cannot read tag/commit from UPSTREAM.md"
UPSTREAM_VERSION=${UPSTREAM_TAG#v}

# Component version = tag of the service's `image:` line in docker-compose.yml.
compose_image_tag() {
  awk -v svc="$1" '
    /^services:/ { in_s = 1; next }
    in_s && /^[^ #]/ { in_s = 0 }
    in_s && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { cur = $1; sub(":", "", cur); next }
    in_s && cur == svc && /^    image:/ { n = split($2, p, ":"); print p[n]; exit }
  ' docker-compose.yml
}

frontend_package_version() {
  sed -n -E 's/^[[:space:]]*"version":[[:space:]]*"([^"]+)".*/\1/p' frontend/package.json | head -n1
}

component_version() {
  local v
  case "$1" in
    frontend)
      # Not the compose value: upstream compose passes a hard-coded APP_VERSION
      v=${FRONTEND_APP_VERSION:-$(frontend_package_version)}
      local c
      c=$(compose_image_tag frontend)
      [[ -z $c || $c == "$v" ]] || warn "frontend: docker-compose.yml says $c, using $v"
      ;;
    *)
      v=$(compose_image_tag "$1")
      if [[ -z $v ]]; then
        # background-services has a build: but no image: line upstream
        warn "$1: no image: line in docker-compose.yml, using upstream release $UPSTREAM_VERSION as version"
        v=$UPSTREAM_VERSION
      fi
      ;;
  esac
  [[ $v =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "$1: '$v' is not a valid image tag"
  echo "$v"
}

# ---------------------------------------------------------------- git, registry
GIT_SHA=$(git rev-parse HEAD) || die "not a git repository"
SHORT_SHA=$(git rev-parse --short=7 HEAD)
DIRTY=0
git diff-index --quiet HEAD -- || DIRTY=1
((DIRTY)) && SHORT_SHA="${SHORT_SHA}-dirty"

RELEASE_TAG=${GIT_TAG:-${CI_COMMIT_TAG:-$(git describe --tags --exact-match HEAD 2>/dev/null || true)}}
if [[ -n $RELEASE_TAG ]]; then
  RELEASE_TAG=$(printf '%s' "$RELEASE_TAG" | tr -c 'A-Za-z0-9_.-' '-')
  [[ $RELEASE_TAG =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "git tag '$RELEASE_TAG' is not usable as an image tag"
fi

SOURCE_URL=${IMAGE_SOURCE:-}
if [[ -z $SOURCE_URL ]]; then
  remote=$(git remote get-url origin 2>/dev/null || true)
  # strip credentials, turn scp-style and ssh URLs into https, drop .git
  SOURCE_URL=$(printf '%s' "$remote" | sed -E 's#^[a-z+]+://[^@/]*@#https://#; s#^git@([^:]+):#https://\1/#; s#^ssh://#https://#; s#\.git$##')
fi
[[ -n $SOURCE_URL ]] || warn "no IMAGE_SOURCE and no git remote: omitting the org.opencontainers.image.source label"

REGISTRY=${IMAGE_REGISTRY:-$PLACEHOLDER_REGISTRY}
NAMESPACE=${IMAGE_NAMESPACE:-plant-commons}
NAMESPACE=${NAMESPACE,,}
NAMESPACE=${NAMESPACE#/}; NAMESPACE=${NAMESPACE%/}
[[ $REGISTRY =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "IMAGE_REGISTRY '$REGISTRY' must be host[:port] without scheme or path"
[[ $NAMESPACE =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || die "IMAGE_NAMESPACE '$NAMESPACE' is not a valid repository path"
if ((PUSH && ! DRY)); then
  [[ -n ${IMAGE_REGISTRY:-} && -n ${IMAGE_NAMESPACE:-} ]] || die "--push needs IMAGE_REGISTRY and IMAGE_NAMESPACE"
  ((!DIRTY)) || die "--push refused: work tree has uncommitted changes to tracked files"
fi
((! PUSH)) || [[ $REGISTRY != "$PLACEHOLDER_REGISTRY" ]] || warn "pushing to the placeholder registry (dry run)"

# ---------------------------------------------------------------- driver
DRIVER=${BUILD_DRIVER:-auto}
if [[ $DRIVER == auto ]]; then
  if command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then DRIVER=buildx; else DRIVER=classic; fi
fi
[[ $DRIVER == buildx || $DRIVER == classic ]] || die "BUILD_DRIVER must be auto, buildx or classic"
if [[ $DRIVER == classic && ( -n ${BUILD_CACHE_FROM:-} || -n ${BUILD_CACHE_TO:-} ) ]]; then
  warn "BUILD_CACHE_FROM/TO are ignored with the classic builder (needs docker buildx)"
fi
# Some upstream Dockerfiles need BuildKit (codemeta uses COPY --chmod); the legacy builder
# rejects them only after minutes of work, so check before building anything.
if [[ $DRIVER == classic ]]; then
  for s in "${SERVICES[@]}"; do
    if grep -qE '^(COPY|ADD) .*--chmod|^RUN .*--mount|^# *syntax=' "$(context_for "$s")/Dockerfile"; then
      die "$s needs BuildKit; install the docker buildx plugin, or leave $s out (e.g. omit --all)"
    fi
  done
fi
if ((! DRY)); then command -v docker >/dev/null 2>&1 || die "docker not found"; fi

# ---------------------------------------------------------------- run helpers
# Print a command one flag per line, so a dry run is readable and copy-pastable.
quote() { if [[ $1 =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then printf '%s' "$1"; else printf '%q' "$1"; fi; }
print_cmd() {
  local out="" prev="" a n=0
  for a in "$@"; do
    n=$((n + 1))
    case "$prev" in
      -t | -f | --label | --build-arg | --cache-from | --cache-to | --platform)
        out+=" $(quote "$a")" ;;
      *)
        ((n == 1)) || out+=$' \\\n  '
        out+="$(quote "$a")" ;;
    esac
    prev=$a
  done
  printf '%s\n' "$out"
}
run() {
  if ((DRY)); then print_cmd "$@"; echo; else "$@"; fi
}

[[ -z ${IMAGES_FILE:-} ]] || { ((DRY)) || : >"$IMAGES_FILE"; }

# ---------------------------------------------------------------- build
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SUMMARY=()
echo "build-images: ${#SERVICES[@]} image(s): ${SERVICES[*]}; sha ${SHORT_SHA}; driver ${DRIVER}; push ${PUSH}${RELEASE_TAG:+; release tag $RELEASE_TAG}"
((! DIRTY)) || warn "work tree has uncommitted changes to tracked files: tags carry '-dirty'"

for svc in "${SERVICES[@]}"; do
  ctx=$(context_for "$svc")
  ver=$(component_version "$svc")
  name="${REGISTRY}/${NAMESPACE}/plant-commons-${svc}"
  tags=("${name}:${ver}-${SHORT_SHA}" "${name}:sha-${SHORT_SHA}")
  [[ -z $RELEASE_TAG ]] || tags+=("${name}:${RELEASE_TAG}")
  base=$(awk '/^FROM /{ img = $2 } END { print img }' "$ctx/Dockerfile")

  if [[ $DRIVER == buildx ]]; then cmd=(docker buildx build); else cmd=(docker build); fi
  cmd+=(-f "$ctx/Dockerfile")
  for t in "${tags[@]}"; do cmd+=(-t "$t"); done
  cmd+=(
    --label "org.opencontainers.image.title=plant-commons-${svc}"
    --label "org.opencontainers.image.version=${ver}-${SHORT_SHA}"
    --label "org.opencontainers.image.revision=${GIT_SHA}"
    --label "org.opencontainers.image.created=${CREATED}"
    --label "org.opencontainers.image.licenses=Apache-2.0"
    --label "org.opencontainers.image.base.name=${base}"
    --label "de.ipk-gatersleben.plant-commons.upstream.repository=${UPSTREAM_REPO}"
    --label "de.ipk-gatersleben.plant-commons.upstream.tag=${UPSTREAM_TAG}"
    --label "de.ipk-gatersleben.plant-commons.upstream.commit=${UPSTREAM_COMMIT}"
  )
  [[ -z $SOURCE_URL ]] || cmd+=(--label "org.opencontainers.image.source=${SOURCE_URL}")
  # The only build arg. Never add secrets here: build args are readable with `docker history`.
  [[ $svc != frontend ]] || cmd+=(--build-arg "APP_VERSION=${ver}")
  ((! PULL)) || cmd+=(--pull)
  [[ -z ${BUILD_PLATFORM:-} ]] || cmd+=(--platform "$BUILD_PLATFORM")
  if [[ $DRIVER == buildx ]]; then
    [[ -z ${BUILD_CACHE_FROM:-} ]] || cmd+=(--cache-from "${BUILD_CACHE_FROM//\{service\}/$svc}")
    [[ -z ${BUILD_CACHE_TO:-} ]] || cmd+=(--cache-to "${BUILD_CACHE_TO//\{service\}/$svc}")
    if ((PUSH)); then cmd+=(--push); else cmd+=(--load); fi
  fi
  cmd+=("$ctx")

  # Env files in a build context can end up in an image (frontend/documentation use COPY . .).
  # Upstream .dockerignore files only cover *.local variants. Fail on --push, warn otherwise.
  leaks=$(find "$ctx" -name node_modules -prune -o -name '.env*' ! -name '*.example' -type f -print 2>/dev/null || true)
  if [[ -n $leaks ]]; then
    ((! PUSH)) || die "$svc: env file(s) in the build context: $leaks"
    warn "$svc: env file(s) in the build context (not pushed): $leaks"
  fi

  echo "build-images: === ${svc} (${ctx}, version ${ver})"
  start=$SECONDS
  run "${cmd[@]}"
  if [[ $DRIVER == classic ]] && ((PUSH)); then
    for t in "${tags[@]}"; do run docker push "$t"; done
  fi
  SUMMARY+=("$(printf '%-20s %5ss  %s' "$svc" "$((SECONDS - start))" "${tags[0]}")")
  [[ -z ${IMAGES_FILE:-} ]] || ((DRY)) || echo "$svc ${tags[0]}" >>"$IMAGES_FILE"
done

echo
echo "build-images: summary (service, seconds, primary tag)"
printf '  %s\n' "${SUMMARY[@]}"
