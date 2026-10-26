#!/usr/bin/env bash
#
# Compares a schema snapshot with the database the migrations produce.
#
# Two scratch databases are created on a Postgres server (a container started
# from --postgres-image, or the server behind --database-url). The migrations
# are applied to one, with goose on --migrations-dir or with --migrate-command;
# the snapshot files are applied to the other with psql. Both are dumped with
# pg_dump --schema-only, normalised (see normalize.awk) and compared. The
# unified diff is the report: lines with - are only in the snapshot, lines with
# + only in the migrations.
#
# Every option can also be given through the environment (SD_SCHEMA_FILES with
# one path per line, SD_MIGRATIONS_DIR, SD_MIGRATE_COMMAND, SD_DATABASE_URL_ENV,
# SD_POSTGRES_IMAGE, SD_DATABASE_URL, SD_GOOSE_TABLE, SD_EXCLUDE_SCHEMAS,
# SD_EXCLUDE_TABLES, SD_FAIL_ON_DRIFT, SD_NAME, SD_REPORT_DIR, SD_KEEP), which
# is how action.yml calls it. Flags win over the environment.
#
# Usage:
#   check.sh --schema-file sql/schema/v0.sql --schema-file sql/schema/v1.sql \
#     --migrations-dir db/migrations [--postgres-image postgres:16]
#   check.sh --schema-file schema.sql --migrate-command 'go run ./cmd/migrate' \
#     --database-url-env DATABASE_URL --exclude-schema outbox
#
# Other flags: --database-url URL (reuse a server; needs psql and pg_dump),
# --goose-table NAME, --exclude-table PATTERN, --name LABEL, --report-dir DIR,
# --no-fail (exit 0 even when drifted), --keep (leave the container and the
# scratch databases in place).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCHEMA_FILES="${SD_SCHEMA_FILES:-}"
MIGRATIONS_DIR="${SD_MIGRATIONS_DIR:-}"
MIGRATE_COMMAND="${SD_MIGRATE_COMMAND:-}"
DATABASE_URL_ENV="${SD_DATABASE_URL_ENV:-DATABASE_URL}"
POSTGRES_IMAGE="${SD_POSTGRES_IMAGE:-postgres:16}"
ADMIN_URL="${SD_DATABASE_URL:-}"
GOOSE_TABLE="${SD_GOOSE_TABLE:-goose_db_version}"
EXCLUDE_SCHEMAS="${SD_EXCLUDE_SCHEMAS:-}"
EXCLUDE_TABLES="${SD_EXCLUDE_TABLES:-}"
FAIL_ON_DRIFT="${SD_FAIL_ON_DRIFT:-true}"
NAME="${SD_NAME:-schema}"
REPORT_DIR="${SD_REPORT_DIR:-}"
KEEP="${SD_KEEP:-false}"

die() {
  echo "schema-drift: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --schema-file) SCHEMA_FILES="${SCHEMA_FILES:+$SCHEMA_FILES$'\n'}$2"; shift 2 ;;
    --migrations-dir) MIGRATIONS_DIR="$2"; shift 2 ;;
    --migrate-command) MIGRATE_COMMAND="$2"; shift 2 ;;
    --database-url-env) DATABASE_URL_ENV="$2"; shift 2 ;;
    --postgres-image) POSTGRES_IMAGE="$2"; shift 2 ;;
    --database-url) ADMIN_URL="$2"; shift 2 ;;
    --goose-table) GOOSE_TABLE="$2"; shift 2 ;;
    --exclude-schema) EXCLUDE_SCHEMAS="${EXCLUDE_SCHEMAS:+$EXCLUDE_SCHEMAS,}$2"; shift 2 ;;
    --exclude-table) EXCLUDE_TABLES="${EXCLUDE_TABLES:+$EXCLUDE_TABLES,}$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    --no-fail) FAIL_ON_DRIFT=false; shift ;;
    --keep) KEEP=true; shift ;;
    -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# --- inputs ------------------------------------------------------------------

schema_files=()
while IFS= read -r f; do
  f="${f#"${f%%[![:space:]]*}"}"
  f="${f%"${f##*[![:space:]]}"}"
  [ -n "$f" ] && [ "${f#\#}" = "$f" ] && schema_files+=("$f")
done <<<"$SCHEMA_FILES"
[ "${#schema_files[@]}" -gt 0 ] || die "at least one schema file is required"
for f in "${schema_files[@]}"; do
  [ -f "$f" ] || die "schema file not found: $f"
done

if [ -n "$MIGRATIONS_DIR" ] && [ -n "$MIGRATE_COMMAND" ]; then
  die "give either a migrations directory or a migrate command, not both"
fi
if [ -z "$MIGRATIONS_DIR" ] && [ -z "$MIGRATE_COMMAND" ]; then
  die "a migrations directory or a migrate command is required"
fi
if [ -n "$MIGRATIONS_DIR" ]; then
  [ -d "$MIGRATIONS_DIR" ] || die "migrations directory not found: $MIGRATIONS_DIR"
  command -v goose >/dev/null 2>&1 || die "goose is required on PATH for --migrations-dir"
fi
if [ -n "$ADMIN_URL" ]; then
  for tool in psql pg_dump; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required on PATH for --database-url"
  done
else
  command -v docker >/dev/null 2>&1 || die "docker is required to start the Postgres container"
fi

case "$FAIL_ON_DRIFT" in
  true | false) ;;
  *) die "fail-on-drift must be true or false" ;;
esac

if [ -z "$REPORT_DIR" ]; then
  REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/schema-drift.XXXXXX")"
else
  mkdir -p "$REPORT_DIR"
fi

# Keep "database does not exist, skipping" and similar out of the output.
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"

migrations_db="schema_drift_migrations"
schema_db="schema_drift_schema"

# --- server ------------------------------------------------------------------

cid=""
pg_user="postgres"

# with_database URL NAME: swap the database in a postgres URL, keeping the query string.
with_database() {
  local url="$1" name="$2" base query=""
  base="${url%%\?*}"
  if [ "$base" != "$url" ]; then
    query="?${url#*\?}"
  fi
  printf '%s/%s%s' "${base%/*}" "$name" "$query"
}

# run_psql DB [psql args...]
run_psql() {
  local db="$1"
  shift
  if [ -n "$cid" ]; then
    docker exec -i -e PGOPTIONS="$PGOPTIONS" "$cid" psql -U "$pg_user" -d "$db" "$@"
  else
    psql "$(with_database "$ADMIN_URL" "$db")" "$@"
  fi
}

# run_pg_dump DB [pg_dump args...]
run_pg_dump() {
  local db="$1"
  shift
  if [ -n "$cid" ]; then
    docker exec "$cid" pg_dump -U "$pg_user" -d "$db" "$@"
  else
    pg_dump "$(with_database "$ADMIN_URL" "$db")" "$@"
  fi
}

cleanup() {
  if [ "$KEEP" = true ]; then
    if [ -n "$cid" ]; then
      echo "keeping container $cid"
    else
      echo "keeping scratch databases $migrations_db and $schema_db"
    fi
    return
  fi
  if [ -n "$cid" ]; then
    docker rm -f "$cid" >/dev/null 2>&1 || true
  elif [ -n "$ADMIN_URL" ]; then
    run_psql postgres -q -v ON_ERROR_STOP=1 \
      -c "DROP DATABASE IF EXISTS $migrations_db WITH (FORCE)" \
      -c "DROP DATABASE IF EXISTS $schema_db WITH (FORCE)" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ -z "$ADMIN_URL" ]; then
  echo "starting $POSTGRES_IMAGE"
  cid="$(docker run -d \
    -e POSTGRES_USER="$pg_user" -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=postgres \
    -p 127.0.0.1:0:5432 "$POSTGRES_IMAGE")"
  port="$(docker port "$cid" 5432/tcp | head -n 1)"
  port="${port##*:}"
  ADMIN_URL="postgresql://$pg_user:postgres@127.0.0.1:$port/postgres?sslmode=disable"
  # The image's entrypoint runs a socket-only server during initialisation, so
  # readiness is checked over TCP.
  ready=0
  for _ in $(seq 1 90); do
    if docker exec "$cid" pg_isready -h 127.0.0.1 -U "$pg_user" -q 2>/dev/null; then
      ready=1
      break
    fi
    sleep 1
  done
  if [ "$ready" = 0 ]; then
    docker logs "$cid" 2>&1 | tail -n 30
    die "$POSTGRES_IMAGE did not become ready"
  fi
else
  echo "using $(with_database "$ADMIN_URL" '<db>')"
  ready=0
  for _ in $(seq 1 60); do
    if run_psql postgres -q -c 'SELECT 1' >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" = 1 ] || die "could not connect to the database server"
fi

migrations_url="$(with_database "$ADMIN_URL" "$migrations_db")"

echo "creating scratch databases"
run_psql postgres -q -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS $migrations_db WITH (FORCE)" \
  -c "DROP DATABASE IF EXISTS $schema_db WITH (FORCE)" \
  -c "CREATE DATABASE $migrations_db" \
  -c "CREATE DATABASE $schema_db"

# --- report helpers ----------------------------------------------------------

report_md="$REPORT_DIR/report.md"
report_diff="$REPORT_DIR/report.diff"
: >"$report_diff"

set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >>"$GITHUB_OUTPUT"
  fi
}

publish_report() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$report_md" >>"$GITHUB_STEP_SUMMARY"
  fi
  set_output report "$report_md"
  set_output diff "$report_diff"
}

# fail_setup HEADLINE LOGFILE: report a step that could not run, then exit 1.
fail_setup() {
  {
    echo "## Schema drift: $NAME"
    echo
    echo ":x: $1"
    echo
    echo '```'
    tail -n 60 "$2"
    echo '```'
  } >"$report_md"
  set_output drifted "true"
  publish_report
  cat "$2"
  echo "schema-drift: $1" >&2
  exit 1
}

# --- apply -------------------------------------------------------------------

if [ -n "$MIGRATIONS_DIR" ]; then
  echo "applying goose migrations from $MIGRATIONS_DIR"
  goose -table "$GOOSE_TABLE" -dir "$MIGRATIONS_DIR" postgres "$migrations_url" up \
    >"$REPORT_DIR/migrate.log" 2>&1 ||
    fail_setup "goose up failed" "$REPORT_DIR/migrate.log"
else
  echo "applying migrations with: $MIGRATE_COMMAND"
  env "$DATABASE_URL_ENV=$migrations_url" bash -eo pipefail -c "$MIGRATE_COMMAND" \
    >"$REPORT_DIR/migrate.log" 2>&1 ||
    fail_setup "the migrate command failed" "$REPORT_DIR/migrate.log"
fi

for f in "${schema_files[@]}"; do
  echo "applying $f"
  run_psql "$schema_db" -q -v ON_ERROR_STOP=1 -f - <"$f" >"$REPORT_DIR/schema.log" 2>&1 ||
    fail_setup "applying $f failed; the snapshot is not valid SQL on its own" "$REPORT_DIR/schema.log"
done

# --- normalise and dump ------------------------------------------------------

# Both databases: no partitions (the snapshot only defines the parents) and
# every constraint validated (added online by a migration as NOT VALID, inline
# in the snapshot).
normalize_database() {
  run_psql "$1" -q -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT c.oid::regclass AS rel
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relispartition
          AND c.relkind IN ('r', 'p')
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND n.nspname NOT LIKE '\_timescaledb\_%'
    LOOP
        EXECUTE format('DROP TABLE IF EXISTS %s CASCADE', r.rel);
    END LOOP;

    FOR r IN
        SELECT c.conrelid::regclass AS rel, c.conname
        FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE NOT c.convalidated
          AND c.contype IN ('c', 'f')
          AND n.nspname NOT LIKE '\_timescaledb\_%'
    LOOP
        EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', r.rel, r.conname);
    END LOOP;
END
$$;
SQL
}

dump_args=(--schema-only --no-owner --no-privileges
  "--exclude-table=$GOOSE_TABLE"
  '--exclude-schema=_timescaledb_*' '--exclude-schema=timescaledb_*')
# add_excludes FLAG LIST: one pg_dump FLAG=pattern per comma-separated entry.
add_excludes() {
  local flag="$1" list="$2" item
  while [ -n "$list" ]; do
    item="${list%%,*}"
    if [ "$item" = "$list" ]; then list=""; else list="${list#*,}"; fi
    item="${item// /}"
    [ -n "$item" ] && dump_args+=("$flag=$item")
  done
}
add_excludes --exclude-schema "$EXCLUDE_SCHEMAS"
add_excludes --exclude-table "$EXCLUDE_TABLES"

# dump_normalized DB OUT: statements sorted, one per line in OUT.blocks and
# expanded in OUT.
dump_normalized() {
  run_pg_dump "$1" "${dump_args[@]}" >"$2.raw"
  awk -f "$script_dir/normalize.awk" <"$2.raw" | LC_ALL=C sort >"$2.blocks"
  tr '\001' '\n' <"$2.blocks" >"$2"
}

echo "dumping and comparing"
normalize_database "$migrations_db"
normalize_database "$schema_db"
dump_normalized "$migrations_db" "$REPORT_DIR/migrations.sql"
dump_normalized "$schema_db" "$REPORT_DIR/schema.sql"
statements="$(wc -l <"$REPORT_DIR/migrations.sql.blocks" | tr -d ' ')"

# --- compare -----------------------------------------------------------------

schema_label="$NAME: snapshot (applied)"
if [ "${#schema_files[@]}" -eq 1 ]; then
  schema_label="${schema_files[0]} (applied)"
fi
drifted=0
diff -u --label "$schema_label" --label "migrations (applied)" \
  "$REPORT_DIR/schema.sql" "$REPORT_DIR/migrations.sql" >"$report_diff" || drifted=$?
if [ "$drifted" -gt 1 ]; then
  die "diff failed"
fi

if [ "$drifted" = 0 ]; then
  {
    echo "## Schema drift: $NAME"
    echo
    echo ":white_check_mark: The snapshot matches the migrations ($statements statements compared)."
  } >"$report_md"
  set_output drifted "false"
  publish_report
  echo "schema-drift: $NAME matches the migrations ($statements statements compared)"
  exit 0
fi

removed="$(grep -c '^-[^-]' "$report_diff" || true)"
added="$(grep -c '^+[^+]' "$report_diff" || true)"
{
  echo "## Schema drift: $NAME"
  echo
  echo ":x: The snapshot and the migrations differ: $removed lines only in the snapshot (\`-\`), $added lines only in the migrations (\`+\`)."
  echo
  echo "Update the snapshot so it describes what the migrations build."
  echo
  echo '```diff'
  if [ "$(wc -l <"$report_diff")" -gt 400 ]; then
    head -n 400 "$report_diff"
    echo "... (truncated; the full diff is in the step log)"
  else
    cat "$report_diff"
  fi
  echo '```'
} >"$report_md"
set_output drifted "true"
publish_report

cat "$report_diff"
echo
echo "schema-drift: $NAME does not match the migrations ($removed lines only in the snapshot, $added only in the migrations)" >&2
if [ "$FAIL_ON_DRIFT" = true ]; then
  exit 1
fi
