# Plant Commons: database on the platform (external CloudNativePG)

The target platform (PDB, RKE2 at de.NBI Bielefeld) does not allow application-managed PostgreSQL. Every service gets a
CloudNativePG (CNPG) cluster from the platform: PostgreSQL 17.11 (`ghcr.io/cloudnative-pg/postgresql:17.11-system-trixie`),
2 instances, local disks, nightly `pg_dump` by the platform. The chart therefore has two modes:

| | `database.enabled: true` (default) | `database.enabled: false` (platform) |
|---|---|---|
| Database | the chart's StatefulSet + Service + PVC, upstream's image, schema from `docker-entrypoint-initdb.d` | CNPG cluster, nothing rendered for it |
| Connection | plain TCP inside the namespace | **TLS with certificate verification** (`verify-full`), the cluster rejects everything else |
| Passwords | `POSTGRES_PASSWORD`, `POSTGRES_AUTHENTICATOR_PASSWORD` in `existingSecret` | `externalDatabase.ownerSecret` (CNPG `-app` Secret), `externalDatabase.authenticatorSecret` (platform, from the vault) |
| Schema | first start of the empty data directory | `deploy/postgres/init.sql`, once, as superuser |
| Use | kind / local tests | the cluster |

Values: [chart.md](chart.md) section 2 ("External database") and `examples/values-plant-commons.yaml`.

## 1. Connections and TLS

Only three things connect to the database; each gets the CA from `externalDatabase.caSecret` (Secret in the release namespace,
key `ca.crt`), mounted **read-only** at `/etc/plant-commons/db-ca/ca.crt`:

| Client | Role | How TLS is configured |
|---|---|---|
| backend (PostgREST) | `rsd_authenticator` | `PGRST_DB_URI=postgres://rsd_authenticator:$(POSTGRES_AUTHENTICATOR_PASSWORD)@<host>:5432/<db>?sslmode=verify-full&sslrootcert=/etc/plant-commons/db-ca/ca.crt` (PostgREST uses libpq) |
| background-services | owner (`rsd`) | **`POSTGRES_DB_JDBC_PARAMS=sslmode=verify-full&sslrootcert=/etc/plant-commons/db-ca/ca.crt`**, see below |
| dbMigration Job (optional) | owner (`rsd`) | libpq environment `PGSSLMODE=verify-full`, `PGSSLROOTCERT=/etc/plant-commons/db-ca/ca.crt` |

frontend, auth and scrapers never talk to the database (they use PostgREST over HTTP).

`verify-full` also checks that the host name is in the server certificate. `plant-commons-pg-rw` is the short in-namespace name of the CNPG
read-write Service; CNPG's server certificate contains `<cluster>-rw`, `<cluster>-rw.<ns>` and `<cluster>-rw.<ns>.svc` (from CNPG's documentation,
**not verified against the real cluster**). If the connection fails with a host name mismatch, set `externalDatabase.host` to a name that is in the
certificate. `sslMode` accepts `verify-full` and `verify-ca` only; the password of `rsd_authenticator` must be `[A-Za-z0-9]` because it is part of a URI.

### background-services: how it builds the JDBC connection (checked, one change)

`background-services/src/main/java/nl/esciencecenter/rsd/PostgresRunnable.java` is the only place that connects. It builds
`jdbc:postgresql://$POSTGRES_DB_HOST:$POSTGRES_DB_HOST_PORT/$POSTGRES_DB` with `POSTGRES_USER`/`POSTGRES_PASSWORD` and has no way to add parameters.
pgjdbc 42.7.13 (the version in `pom.xml`) reads **no** `PGSSLMODE`/`PGSSLROOTCERT` from the environment (its `PGEnvironment` only knows
`PGPASSFILE`, `PGSERVICEFILE`, `PGSYSCONFDIR`; checked in the jar of the built image). So there is a **smallest possible `PLANT-COMMONS` change**
(5 lines): an optional environment variable `POSTGRES_DB_JDBC_PARAMS`, appended to the URL as `?<value>` when set and not blank. Unset means upstream's
behaviour. The chart sets it only with the external database. Mark: `grep -rn PLANT-COMMONS background-services`.

## 2. `deploy/postgres/init.sql` (build artefact)

The schema can no longer come from `docker-entrypoint-initdb.d`. `deploy/postgres/build-init-sql.sh` concatenates `database/*.sql` in the order the
image's entrypoint runs them (`001-setup-basic-roles.sql` ... `950-pre-request-hook.sql`; compared with the built image, identical; `*.sql.example`
and `000-fill-authenticator-password.sh` are not part of it) into `deploy/postgres/init.sql`. The result is committed and **must be regenerated on every
upstream update** (`UPSTREAM.md`): `deploy/postgres/build-init-sql.sh [database-name] [owner-role]` (defaults `rsd-db rsd`).

Run **once**, as superuser, in the database `rsd-db`, after initdb and after CNPG created the owner role `rsd` and the database
(`psql -v ON_ERROR_STOP=1 --single-transaction -U postgres -d rsd-db -f init.sql`). Plain SQL, no psql meta-commands.

What the script changes (everything else is upstream's SQL byte for byte; each pattern is asserted to match exactly as expected, the script fails
after an upstream change that breaks one):

1. `_database_name_` -> `rsd-db` (done by `000-fill-authenticator-password.sh` with `sed` in the image).
2. `CREATE ROLE rsd_authenticator NOINHERIT LOGIN;` **without** a password. The platform sets it as a CNPG managed role from its vault.
3. `ALTER DEFAULT PRIVILEGES ...` becomes `ALTER DEFAULT PRIVILEGES FOR ROLE rsd ...` and `SET ROLE rsd;` follows `001`, `RESET ROLE;` ends the file.
   Reason: running as `postgres` would make `postgres` the owner of all 300+ tables/functions/views and the holder of the default privileges, so the
   owner `rsd` (used by background-services and the migration Job) could not alter anything and tables created later by `rsd` would get no grants for
   `rsd_web_anon`/`rsd_user`/`rsd_admin`. With the two changes the result is what upstream's image produces (verified, section 4).
4. A file that ends without `;` gets one (upstream's `022-create-maintenance-tables.sql`, which only works there because every file is run separately).

### Roles and grants (document for the platform)

`001` creates `rsd_web_anon`, `rsd_user`, `rsd_admin` (all `NOLOGIN`) and `rsd_authenticator` (`NOINHERIT LOGIN`), and grants the three to the authenticator:

```sql
GRANT rsd_web_anon TO rsd_authenticator;
GRANT rsd_admin    TO rsd_authenticator;
GRANT rsd_user     TO rsd_authenticator;
```

The platform sets `inRoles` of the CNPG managed role `rsd_authenticator` to exactly these three, and its password from the vault. The grants stay in
`init.sql` anyway. Points the platform has to respect:

- **Order:** `init.sql` runs first and creates the four roles. The managed role `rsd_authenticator` then reconciles the existing role (password, `inRoles`);
  its `inRoles` can only name roles that already exist. If CNPG creates `rsd_authenticator` before `init.sql` runs, `CREATE ROLE rsd_authenticator` fails and the
  single-transaction run rolls back completely (nothing half-applied). Not tested against CNPG.
- `rsd_authenticator` must stay `NOINHERIT LOGIN` and have a password: PostgREST logs in as the authenticator and switches to `rsd_web_anon` (no JWT),
  `rsd_user` or `rsd_admin` per request (`SET ROLE`). Without the password PostgREST cannot connect.
- The password must be `[A-Za-z0-9]`: the chart puts it into the URI `PGRST_DB_URI`.

## 3. Rights of the owner `rsd` and what needs superuser

**Owner `rsd` (created by CNPG as owner of `rsd-db`, `NOSUPERUSER`, no `CREATEROLE`).** Besides owning the database it needs nothing:
tested, the whole of `002`..`950` ran under `SET ROLE rsd` with exactly these rights (section 4). In particular:

- `CREATE EXTENSION pgcrypto` / `citext` (`003`, `004`): both are *trusted* extensions since PostgreSQL 13, so the database owner (`CREATE` on the database) may
  create them. The extension files must be in the image: the CNPG `system` image is the Debian PostgreSQL package, which includes `contrib` (**not verified on
  the platform image**; `SELECT * FROM pg_available_extensions WHERE name IN ('pgcrypto','citext')` shows it).
- `ALTER DATABASE ... SET JIT = OFF` (`001`) is allowed for the owner; it runs as superuser here anyway.
- `GRANT USAGE ON SCHEMA public` works for the owner on PostgreSQL 15+ (`public` belongs to `pg_database_owner`).
- No file uses `CREATE ROLE` (other than `001`), event triggers, untrusted languages, `COPY ... FROM file`, `ALTER SYSTEM`, or superuser-only settings
  (grepped through `database/*.sql`).

**Needs superuser (or `CREATEROLE`) in `init.sql`:** only `001`: the four `CREATE ROLE` and the three `GRANT <role> TO rsd_authenticator` (the owner has no admin
option on the new roles). Everything else is owner-level. `pgcrypto`/`citext` do **not** need a superuser. A later upstream migration may: read each
release's migration SQL for `CREATE ROLE`, `CREATE EXTENSION` of an untrusted extension, `ALTER SYSTEM`; those would have to be run by the platform as superuser.

**Other files depending on environment substitution:** none. Only `001` contained placeholders (`_database_name_`, `POSTGRES_AUTHENTICATOR_PASSWORD`; both handled
by the script); the other SQL files have none (grepped for `_database_name_`, `POSTGRES_*`, `$POSTGRES`), and the script fails if one appears after an upstream update.
`000-fill-authenticator-password.sh` is not needed any more and not used.

## 4. What was tested (local Docker, no cluster)

PostgreSQL 17.11 (`postgres:17.11`, not CNPG's image) with a non-superuser owner `rsd` and database `rsd-db`; `init.sql` run as `postgres`:

- Applies without error: **747 top-level statements** (counted with `log_statement=all`, without psql's own `BEGIN`), file size 376,588 bytes, 10,293 lines, 41 source files.
- `pg_dump --schema-only` (including owners and ACLs) of that database equals, line for line, the dump of a database created by upstream's own image
  (`rsd/database` with `docker-entrypoint-initdb.d`): 15,072 lines, no difference. The data dump differs only in generated UUIDs/timestamps.
- Every object is owned by `rsd`; `ALTER DEFAULT PRIVILEGES` is recorded `FOR ROLE rsd`; a table created afterwards by `rsd` gets SELECT for `rsd_web_anon` and
  SELECT/INSERT/UPDATE/DELETE for `rsd_user`/`rsd_admin`; `rsd` can `ALTER` the upstream tables.
- `rsd_authenticator` (password set separately) logs in, `SET ROLE rsd_web_anon` and reads the views. `pgcrypto`, `citext` are owned by `rsd`.

**Not tested:** the CNPG image itself, CNPG managed roles / `inRoles` interplay, the platform's mechanism for running the file, TLS against the real cluster
(`verify-full` against its certificate), and an upgrade from one RSD release to the next (no migration SQL exists in this repo for it).
