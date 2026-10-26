# Normalises a `pg_dump --schema-only` dump for comparison.
#
# Statements are collected whole (a dollar-quoted function body counts as part
# of its statement) and printed one per line with \001 between the original
# lines, so the caller can `sort` them: pg_dump orders objects by dependency,
# which differs between two databases built by different routes. Columns
# inside a CREATE TABLE are sorted for the same reason (ALTER TABLE ADD COLUMN
# always appends). Comments, blank lines, whitespace and pg_dump's preamble are
# dropped; DEFAULT now() is spelled DEFAULT CURRENT_TIMESTAMP; TimescaleDB's
# internal materialized hypertable numbers are masked.

function flush_table(   i, j, v) {
  for (i = 2; i <= n; i++) {
    v = body[i]
    j = i - 1
    while (j >= 1 && body[j] > v) {
      body[j + 1] = body[j]
      j--
    }
    body[j + 1] = v
  }
  for (i = 1; i <= n; i++) emit("    " body[i])
  n = 0
}

function emit(l) {
  block = (block == "" ? l : block "\001" l)
  if (in_body) {
    if (l != tag ";") return
    in_body = 0
  } else if (l ~ /^AS \$[A-Za-z_]*\$$/) {
    tag = substr(l, 4)
    in_body = 1
    return
  }
  if (l ~ /;$/) {
    print block
    block = ""
  }
}

{
  line = $0
  sub(/^[ \t]+/, "", line)
  sub(/[ \t]+$/, "", line)
  gsub(/DEFAULT now\(\)/, "DEFAULT CURRENT_TIMESTAMP", line)
  gsub(/_materialized_hypertable_[0-9]+/, "_materialized_hypertable_N", line)
  gsub(/cagg_watermark\([0-9]+\)/, "cagg_watermark(N)", line)
  if (line == "") next
  if (line ~ /^--/) next
  if (line ~ /^\\(un)?restrict /) next
  if (line ~ /^SET (statement_timeout|lock_timeout|idle_in_transaction_session_timeout|transaction_timeout|client_encoding|standard_conforming_strings|check_function_bodies|xmloption|client_min_messages|row_security|default_tablespace|default_table_access_method|default_with_oids) /) next
  if (line ~ /^SELECT pg_catalog\.set_config/) next
  if (in_table) {
    if (line ~ /^\)/) {
      flush_table()
      in_table = 0
      emit(line)
      next
    }
    sub(/,$/, "", line)
    body[++n] = line
    next
  }
  if (line ~ /^CREATE (UNLOGGED )?TABLE .*\($/) {
    in_table = 1
    n = 0
  }
  emit(line)
}

END { if (block != "") print block }
