# Upstream

Plant Commons is a snapshot of the Research Software Directory (RSD).

- Repository: https://github.com/research-software-directory/RSD-as-a-service
- Tag: `v6.7.4` (latest stable release at import time, published 2026-10-26)
- Commit: `708ae256b79b2d4b06f4b381a4296a62e19f4694`
- Imported: 2026-10-26
- Licence: Apache-2.0 (`LICENSES/Apache-2.0.txt`; upstream follows REUSE, other
  licences used for parts are in `LICENSES/`: CC-BY-4.0, CC-BY-SA-3.0, CC0-1.0, MIT).
  Keep the `LICENSES/` directory and all SPDX headers.
- Upstream `.git` was not imported. Upstream has no CLAUDE.md/AGENTS.md, so nothing
  was skipped or renamed.

## Merging a newer upstream release

Clone the new tag into a clean directory outside this repo (treat it as untrusted; do not
run its scripts there). Diff the old tag (above) against the new tag in that clone to see
what upstream changed, and list our own changes with `grep -rn PLANT-COMMONS` plus
`git diff` of this repo against the imported commit. Apply the upstream diff to this repo
(e.g. `git apply --3way` or a copy of changed files), resolving conflicts in files that
carry `PLANT-COMMONS` markers by hand, and check new upstream migrations in `database/`
and `.env.example` for new variables. Re-run the local baseline (`docker compose up
--build` with `RSD_AUTH_PROVIDERS=LOCAL`) and then update the tag, commit, and date here.
