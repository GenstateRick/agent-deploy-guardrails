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

[ "$#" -gt 0 ] || { echo "usage: $0 <migration.sql> [...]"; exit 2; }

for f in "$@"; do
  [ -f "$f" ] || { echo "skip (not a file): $f"; continue; }

  # Executable SQL only. Every pattern test below uses $SQL, never "$f".
  SQL=$(sed 's/--.*$//' "$f")

  # --- comment-presence checks: these read the RAW file by design ------------

  grep -q -- '-- ROLLBACK' "$f" \
    || trip "$f has no -- ROLLBACK section"

  # --- destructive DDL -------------------------------------------------------

  if grep -Eqi 'DROP (TABLE|COLUMN|CONSTRAINT)|ALTER .* TYPE |DROP NOT NULL|SET NOT NULL|DELETE FROM|TRUNCATE' <<<"$SQL"; then
    grep -q -- '-- DATA IMPACT' "$f" \
      || trip "$f is destructive but carries no -- DATA IMPACT note (rows affected? NULLs introduced? defaults needed?)"
    trip "$f contains destructive DDL — destructive migrations require an explicit human decision"
  fi

  # --- "additive" hole-closers ----------------------------------------------
  # These pass a migration dry-run AND the destructive grep above, yet can
  # rewrite business logic or the transaction ledger. They are NOT additive,
  # whatever the PR description says.

  if grep -Eqi '^[[:space:]]*UPDATE[[:space:]]|INSERT INTO.*SELECT' <<<"$SQL"; then
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
      trip "$f REPLACES existing object ${obj} — behaviourally destructive, not additive"
    fi
  done < <(grep -Eio 'CREATE OR REPLACE (FUNCTION|VIEW)[[:space:]]+[a-zA-Z0-9_."]+' <<<"$SQL" \
             | awk '{print $NF}' | sed 's/(.*//' | sort -u)
done

if [ "$tripwires" -gt 0 ]; then
  echo
  echo "$tripwires tripwire(s). A human decides per finding — a green pipeline does not override this."
  echo "If one fired after comment-stripping, it is real: the DDL is in executable SQL."
  echo "Do not re-litigate it as a comment artifact."
  exit 1
fi

echo "No migration tripwires."
exit 0
