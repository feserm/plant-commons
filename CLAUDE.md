# CLAUDE.md

## Project

Plant Commons is a customized deployment of the Research Software Directory (RSD,
upstream: https://github.com/research-software-directory/RSD-as-a-service, docs:
https://research-software-directory.org/documentation/). It will run on Kubernetes at
`https://plant-commons.ipk-gatersleben.de` (IPK Gatersleben).

The customization is mainly the home page (`/`): custom hero/landing content, IPK / Plant
Commons branding and theme, and additional custom sections. Everything else should stay as
close to upstream as possible so upstream releases remain mergeable.

See [implementation.md](implementation.md) for the plan, status and open questions. Keep it
updated as work proceeds.

## Decisions (made with the user)

- **Repo strategy:** snapshot copy of upstream in this repo (no submodule). Record the
  upstream tag/commit in `UPSTREAM.md` and mark every customization (see below).
- **Home page:** custom hero + tagline, branding/theme, custom sections.
- **Auth:** ORCID only (`RSD_AUTH_PROVIDERS=ORCID`). `LOCAL` is for local dev only and must
  never be enabled in the cluster.
- **Deployment:** Helm chart in `deploy/helm/plant-commons/`. In-cluster PostgreSQL
  StatefulSet with PVC.
- **Ingress/TLS:** Traefik + cert-manager; routes and certificates are generated from the
  cluster's service registry (exact mechanism still to be confirmed, see implementation.md).
- **Images:** built by CI and pushed to a GitLab/GitHub registry; registry is a chart value
  (`image.registry`), never hard-coded.

## Conventions

- Minimize diffs against upstream. Prefer adding new files/components over editing upstream
  ones; when editing upstream files, add a `// PLANT-COMMONS:` comment (or `# PLANT-COMMONS:`
  in YAML/SQL) so customizations can be found with `grep -rn PLANT-COMMONS`.
- Home page work lives in the upstream Next.js app under `frontend/` (the `/` route and its
  components); branding assets go in `frontend/public/`. Hero text and section content
  should be kept in one place (e.g. `frontend/config/plantCommons.ts` or the RSD settings
  mechanism) rather than scattered through JSX.
- Never commit secrets. `.env` is git-ignored; only `.env.example` and Helm `values.yaml`
  with placeholders are committed. Secrets in the cluster come from Kubernetes Secrets
  (POSTGRES_PASSWORD, POSTGRES_AUTHENTICATOR_PASSWORD, PGRST_JWT_SECRET, ORCID client
  secret). Avoid special characters in those values (upstream restriction).
- Public URLs: `POSTGREST_URL_EXTERNAL` and `RSD_AUTH_URL` must match
  `https://plant-commons.ipk-gatersleben.de`.
- Do not run `git commit`/push unless asked. Do not apply anything to a cluster without
  explicit confirmation.

## Local development (once the upstream snapshot is imported)

Follow upstream's docs; typical flow:

```bash
cp .env.example .env        # fill SECRETS; use RSD_AUTH_PROVIDERS=LOCAL for dev
docker compose up --build   # http://localhost
# frontend only: cd frontend && pnpm install && pnpm dev
```

Verify the chart with `helm lint deploy/helm/plant-commons` and
`helm template deploy/helm/plant-commons -f deploy/helm/plant-commons/values.yaml`.

## Upstream updates

Merge upstream releases by diffing against the tag in `UPSTREAM.md`, re-applying/merging the
`PLANT-COMMONS` changes, then updating `UPSTREAM.md`.
