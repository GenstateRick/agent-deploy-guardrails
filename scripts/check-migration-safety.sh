#!/usr/bin/env bash
#
# check-migration-safety.sh — scripted tripwires for schema migrations.
#
# Usage:  ./check-migration-safety.sh migrations/2026*_*.sql
#         git diff --name-only origin/main..HEAD -- 'migrations/**' \
#           | xargs ./check-migration-safety.sh
#
# Exit 0 = no tripwires. Exit 1 = at least one tripwire; a human decides.
#
# ---------------------------------------------------------------------------
# WHY THIS STRIPS COMMENTS FIRST — read before "simplifying" it
# ---------------------------------------------------------------------------
# Policy requires every migration to carry a -- ROLLBACK section containing the
# SQL that reverses it. The reverse of an additive migration is, by definition,
# a DROP.
#
# So a naive `grep -i 'DROP TABLE' migration.sql` fires on EVERY CORRECTLY
# WRITTEN ADDITIVE MIGRATION. The check punishes compliance, and because it
# fires constantly it trains everyone to wave through the exact alarm meant to
# catch a genuinely destructive change. That is alarm fatigue, manufactured by
# a safety control. See PRINCIPLES.md #4.
#
# Every DDL test below therefore matches against $SQL — executable statements
# with line comments stripped. The comment-PRESENCE checks are the deliberate
# exception: they read the raw file, because finding those comments is their
# entire job.
#
# ---------------------------------------------------------------------------
# EVERY PATTERN HERE HAS A FIXTURE — scripts/test-guards.sh
# ---------------------------------------------------------------------------
# One input it must pass, one it must catch. The first published version of
# this file had no fixtures, and two defects sat in it unnoticed: a false
# positive (a column NAMED "truncated" read as a TRUNCATE) and a false
# negative (a backfill whose SELECT sat on the line after its INSERT read as
# no row mutation at all). Change a pattern, change its pair in the same edit.
# ---------------------------------------------------------------------------

set -uo pipefail

# The staged-rollout flag whose value must never be set by code or migration —
# flipping it is an operational decision, not a deploy. Rename for your project.
ROLLOUT_FLAG="${ROLLOUT_FLAG:-payments_v2_enabled}"

# Branch representing production, used to decide whether a "create or replace"
# is genuinely replacing something that already exists.
UPSTREAM="${UPSTREAM:-origin/main}"

MIGRATION_GLOB="${MIGRATION_GLOB:-migrations/*.sql}"

tripwires=0
trip() { echo "TRIPWIRE: $*"; tripwires=$((tripwires + 1)); }

# Reported, never a stop. An advisory that failed the run would be a tripwire
# with a softer name.
advisories=0
advise() { echo "ADVISORY: $*"; advisories=$((advisories + 1)); }

[ "$#" -gt 0 ] || { echo "usage: $0 <migration.sql> [...]"; exit 2; }

for f in "$@"; do
  [ -f "$f" ] || { echo "skip (not a file): $f"; continue; }

  # Executable SQL only. Every pattern test below uses $SQL, never "$f".
  SQL=$(sed 's/--.*$//' "$f")

  # --- comment-presence checks: these read the RAW file by design ------------

  grep -q -- '-- ROLLBACK' "$f" \
    || trip "$f has no -- ROLLBACK section"

  # --- destructive DDL -------------------------------------------------------
  # Word-boundaried. The bare pattern matched TRUNCATE inside a column NAMED
  # "truncated" in an additive CREATE TABLE. That is executable SQL, so the
  # comment strip above could not save it. PRINCIPLES.md #4, third instance.

  if grep -Eqi '\bDROP (TABLE|COLUMN|CONSTRAINT)\b|\bALTER .* TYPE\b|\bDROP NOT NULL\b|\bSET NOT NULL\b|\bDELETE FROM\b|\bTRUNCATE\b' <<<"$SQL"; then
    grep -q -- '-- DATA IMPACT' "$f" \
      || trip "$f is destructive but carries no -- DATA IMPACT note (rows affected? NULLs introduced? defaults needed?)"
    trip "$f contains destructive DDL — destructive migrations require an explicit human decision"
  fi

  # --- "additive" hole-closers ----------------------------------------------
  # These pass a migration dry-run AND the destructive grep above, yet can
  # rewrite business logic or the transaction ledger. They are NOT additive,
  # whatever the PR description says.

  # INSERT...SELECT is judged per STATEMENT, not per line. A backfill is
  # normally written with INSERT INTO t (...) on one line and its SELECT on
  # the next, which a line-by-line match never sees. A real four-step backfill
  # went through the original of this check as "no row mutation" that way.
  # Newlines become spaces, then one statement per line.
  STATEMENTS=$(tr '\n' ' ' <<<"$SQL" | tr ';' '\n')

  if grep -Eqi '^[[:space:]]*UPDATE[[:space:]]' <<<"$SQL" \
     || grep -Eqi 'INSERT[[:space:]]+INTO[^;]*SELECT' <<<"$STATEMENTS"; then
    trip "$f mutates existing rows (UPDATE / INSERT...SELECT backfill) — not additive"
  fi

  grep -Eqi 'ALTER FUNCTION' <<<"$SQL" \
    && trip "$f alters an existing function — not additive"

  # --- staged-rollout flag ---------------------------------------------------

  grep -qi "$ROLLOUT_FLAG" <<<"$SQL" \
    && trip "$f references $ROLLOUT_FLAG — rollout is an operational flag flip, never a deploy"

  # --- replacement of an EXISTING object -------------------------------------
  # Only a tripwire when the object already exists upstream. The naive version
  # (flag every CREATE OR REPLACE) hit ~43% of migrations in the original repo,
  # because the house style uses that syntax for brand-new functions too.
  # PRINCIPLES.md #4, second instance.

  while read -r obj; do
    [ -n "$obj" ] || continue
    short=${obj##*.}
    if git grep -Eil "(FUNCTION|VIEW)[[:space:]]+(public\.)?${short}[[:space:](]" \
         "$UPSTREAM" -- "$MIGRATION_GLOB" 2>/dev/null \
         | grep -qv "$(basename "$f")"; then
      trip "$f REPLACES existing object ${obj} — behaviorally destructive, not additive"
    fi
  done < <(grep -Eio 'CREATE OR REPLACE (FUNCTION|VIEW)[[:space:]]+[a-zA-Z0-9_."]+' <<<"$SQL" \
             | awk '{print $NF}' | sed 's/(.*//' | sort -u)

  # --- functions and triggers: created is not the same as working ------------
  # Postgres compiles a procedural function body the first time it EXECUTES,
  # not when it is created. A function with a fatal bug inside is created
  # without complaint, so the dry run, the staging migration and the schema
  # comparison all go green. Only something that runs it can find out.
  # PRINCIPLES.md #1.
  #
  # The convention this looks for: a block in the same migration, marked
  # "self-test", that executes the new function and rolls its effects back.
  # Advisory rather than a tripwire because the marker is a convention, and a
  # reviewer still has to confirm the block exercises the function.

  if grep -Eqi 'CREATE (OR REPLACE )?(FUNCTION|TRIGGER)' <<<"$SQL" \
     && ! grep -Eqi 'self-?test' "$f"; then
    advise "$f defines a function or trigger with no self-test — nothing in this pipeline has executed it"
  fi
done

if [ "$tripwires" -gt 0 ]; then
  echo
  echo "$tripwires tripwire(s). A human decides per finding — a green pipeline does not override this."
  echo "If one fired after comment-stripping, it is real: the DDL is in executable SQL."
  echo "Do not re-litigate it as a comment artifact."
  exit 1
fi

if [ "$advisories" -gt 0 ]; then
  echo
  echo "$advisories advisory(ies) above — reported, not a stop. Carry them into the promotion report."
fi

echo "No migration tripwires."
exit 0
