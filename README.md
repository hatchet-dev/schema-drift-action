# schema-drift-action

A GitHub Action that fails a pull request when a sqlc schema snapshot no longer
describes the database the migrations build.

It starts a Postgres container, creates two scratch databases, applies the
migrations to one and the snapshot files to the other, dumps both with
`pg_dump --schema-only`, normalises the dumps and diffs them. The diff is the
report: it goes to the step log, to the job summary and to the `report` and
`diff` outputs. Lines starting with `-` are only in the snapshot, lines starting
with `+` only in the migrations.

## Usage

Migrations that are plain goose SQL files:

```yaml
- uses: hatchet-dev/schema-drift-action@v1
  with:
    schema-files: sql/schema.sql
    migrations-dir: db/migrations
```

Migrations applied by a command (needed when the set includes Go migrations or
other steps goose alone cannot replay). The command runs in `working-directory`
with the scratch database URL in the variable named by `database-url-env`:

```yaml
- uses: actions/setup-go@v5
  with:
    go-version-file: go.mod
- uses: hatchet-dev/schema-drift-action@v1
  with:
    name: sql/schema
    schema-files: |
      sql/schema/v0.sql
      sql/schema/v1-core.sql
      sql/schema/v1-olap.sql
    migrate-command: go run ./cmd/hatchet-migrate
    exclude-schemas: outbox
```

Any Postgres-compatible image works, for example TimescaleDB:

```yaml
- uses: hatchet-dev/schema-drift-action@v1
  with:
    name: sql/timescalev1/schema
    schema-files: sql/timescalev1/schema/schema.sql
    migrate-command: go run ./cmd/hatchet-migrate --skip-control-plane
    database-url-env: CLOUD_TIMESCALE_V1_DATABASE_URL
    postgres-image: timescale/timescaledb-ha:pg15
  env:
    CLOUD_CLICKHOUSE_ENABLED: "false"
```

The job needs Docker (present on the GitHub-hosted Linux runners) and nothing
else: `psql` and `pg_dump` run inside the container, so they always match the
server version. To compare against a server you already run, pass
`database-url` instead; the role must be allowed to create databases and
`psql` and `pg_dump` must be on `PATH`.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `schema-files` | required | Snapshot files, one per line, applied in the order sqlc reads them. |
| `migrations-dir` | | Directory of goose SQL migrations; goose is installed and runs `up`. |
| `migrate-command` | | Shell command that applies the migrations. Exactly one of `migrations-dir` and `migrate-command` is required. |
| `database-url-env` | `DATABASE_URL` | Variable that carries the scratch database URL to `migrate-command`. |
| `postgres-image` | `postgres:16` | Image for the server the action starts. |
| `database-url` | | Reuse this server instead of starting a container. |
| `goose-version` | `v3.29.0` | goose release to install for `migrations-dir`. |
| `goose-table` | `goose_db_version` | goose's version table; excluded from the comparison. |
| `exclude-schemas` | | Comma-separated pg_dump schema patterns to leave out. |
| `exclude-tables` | | Comma-separated pg_dump table patterns to leave out. |
| `fail-on-drift` | `true` | Fail the step when the two differ. |
| `working-directory` | `.` | Base for the paths and for `migrate-command`. |
| `name` | `schema` | Label used in the report. |

Outputs: `drifted` (`true` or `false`), `report` (path of the Markdown
report) and `diff` (path of the unified diff).

## What counts as drift

Names and definitions are compared as pg_dump prints them, so a renamed index,
a changed default, a different type or a constraint that exists on one side
only is drift. The following is normalised away because it is not a difference
in the schema:

- partitions created by the migrations (the snapshot only declares the parents),
- `NOT VALID` on a constraint a migration added online,
- column order inside a table and the order of statements in the dump,
- comments, blank lines and whitespace, including inside function bodies,
- `DEFAULT now()` versus `DEFAULT CURRENT_TIMESTAMP`,
- goose's version table, TimescaleDB's own schemas and the numbering of its
  internal materialized hypertables.

Settings that live in TimescaleDB's catalog rather than in the Postgres schema
(chunk intervals, retention and aggregate policies) are not compared.

A snapshot that cannot be applied on its own (a type used before it is
declared, a constraint naming a column that does not exist) is reported as a
setup failure with the psql error, and the step fails regardless of
`fail-on-drift`.

## Running it locally

`scripts/check.sh` is the whole action; it takes the same options as flags:

```sh
scripts/check.sh --schema-file fixtures/schema.sql --migrations-dir fixtures/migrations
scripts/check.sh --schema-file sql/schema/v0.sql --schema-file sql/schema/v1-core.sql \
  --migrate-command 'go run ./cmd/hatchet-migrate' --exclude-schema outbox
```

`--keep` leaves the container and the dumps in place for inspection, `--no-fail`
exits 0 even when the two differ. `fixtures/` holds a small migration set with
matching, drifted and invalid snapshots; `.github/workflows/test.yml` runs the
action against them.
