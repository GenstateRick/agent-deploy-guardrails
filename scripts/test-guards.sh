#!/usr/bin/env bash
#
# test-guards.sh — trip every guard in this repository on purpose.
#
# Usage:  ./scripts/test-guards.sh
#
# Exit 0 = every fixture behaved. Exit 1 = a guard passed something it must
# catch, or caught something it must pass.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# A guard that was demonstrated once, by hand, on the day it was written, is
# not a control. It is decoration with an audit trail. A guard that has
# silently stopped catching (a pattern that drifted, a tool that changed, a
# refactor) looks exactly like a guard with nothing to catch.
#
# So every guard gets a standing pair of fixtures, run on the same cadence as
# the tests:
#
#   - one input it MUST PASS  (compliant work — the false-positive half)
#   - one input it MUST CATCH (the violation it was written for)
#
# The must-catch fixtures also name the message they expect. A fixture that
# trips for the wrong reason proves nothing about the check it was aimed at.
#
# Both guards here had a hole that their first fixture run exposed. Each is
# marked REGRESSION below with the date it was found. See PRINCIPLES.md #3.
#
# When you add a pattern to a guard, add its pair here in the same change.
# ---------------------------------------------------------------------------

set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
MIGRATION_GUARD="$HERE/scripts/check-migration-safety.sh"
HOOK="$HERE/hooks/pre-tool-use.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

checked=0
failed=0
bad() { echo "FAIL: $*"; failed=$((failed + 1)); }

# ---------------------------------------------------------------------------
# check-migration-safety.sh
#
# Runs inside a throwaway repository whose first commit already contains one
# function, so "replaces an object that exists upstream" has something real to
# find. UPSTREAM=HEAD stands in for the production branch.
# ---------------------------------------------------------------------------

REPO="$WORK/repo"
mkdir -p "$REPO/migrations"
git -C "$REPO" init -q
cat > "$REPO/migrations/0001_base.sql" <<'SQL'
CREATE TABLE widgets (id bigint PRIMARY KEY, name text);
CREATE FUNCTION public.widget_count() RETURNS bigint
  LANGUAGE sql AS $$ SELECT count(*) FROM widgets $$;

-- ROLLBACK
-- DROP FUNCTION public.widget_count();
-- DROP TABLE widgets;
SQL
git -C "$REPO" add migrations/0001_base.sql
git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -q -m "base"

# migration <clean|trip> <name> [text the output must contain] [text it must NOT contain]
# The migration body is read from stdin.
migration() {
  local want=$1 name=$2 must=${3:-} must_not=${4:-} out rc
  cat > "$REPO/migrations/$name.sql"
  out=$(cd "$REPO" && UPSTREAM=HEAD "$MIGRATION_GUARD" "migrations/$name.sql" 2>&1)
  rc=$?
  rm -f "$REPO/migrations/$name.sql"
  checked=$((checked + 1))

  if [ "$want" = clean ] && [ "$rc" -ne 0 ]; then
    bad "migration/$name must pass, but tripped:"; echo "$out" | sed 's/^/      /'
  elif [ "$want" = trip ] && [ "$rc" -eq 0 ]; then
    bad "migration/$name must trip, but passed"
  elif [ -n "$must" ] && ! grep -qF -- "$must" <<<"$out"; then
    bad "migration/$name: expected output to contain '$must'"; echo "$out" | sed 's/^/      /'
  elif [ -n "$must_not" ] && grep -qF -- "$must_not" <<<"$out"; then
    bad "migration/$name: output must not contain '$must_not'"; echo "$out" | sed 's/^/      /'
  fi
}

# --- must pass --------------------------------------------------------------

# The founding case: the required rollback block of an additive migration is,
# by definition, a DROP. PRINCIPLES.md #4, first instance.
migration clean additive_with_rollback <<'SQL'
CREATE TABLE gadgets (id bigint PRIMARY KEY, name text NOT NULL);

-- ROLLBACK
-- DROP TABLE gadgets;
SQL

# REGRESSION 2026-09-01. The destructive pattern matched TRUNCATE anywhere, so
# a column NAMED "truncated" in an additive CREATE TABLE read as a TRUNCATE
# statement. It is executable SQL, so comment-stripping could not save it.
# PRINCIPLES.md #4, third instance.
migration clean identifier_that_looks_destructive <<'SQL'
CREATE TABLE import_runs (
  id bigint PRIMARY KEY,
  truncated boolean NOT NULL DEFAULT false,
  dropped_at timestamptz,
  record_type text
);

-- ROLLBACK
-- DROP TABLE import_runs;
SQL

migration clean destructive_words_only_in_comments <<'SQL'
-- An earlier draft would DROP COLUMN name and TRUNCATE the table. This one
-- only adds an index.
CREATE INDEX widgets_name_idx ON widgets (name);

-- ROLLBACK
-- DROP INDEX widgets_name_idx;
SQL

# An INSERT of literal rows, with a SELECT in a LATER statement, is not a
# backfill. The statement-level match must not join the two.
migration clean seed_rows_then_unrelated_select <<'SQL'
CREATE TABLE widget_kinds (code text PRIMARY KEY);
INSERT INTO widget_kinds (code) VALUES ('standard');
CREATE VIEW widget_kind_codes AS SELECT code FROM widget_kinds;

-- ROLLBACK
-- DROP VIEW widget_kind_codes;
-- DROP TABLE widget_kinds;
SQL

# "create or replace" of a function that does NOT exist upstream is a new
# object. PRINCIPLES.md #4, second instance. It carries a self-test, so no
# advisory either.
migration clean new_function_with_self_test "" "ADVISORY" <<'SQL'
CREATE OR REPLACE FUNCTION public.gadget_count() RETURNS bigint
  LANGUAGE sql AS $$ SELECT count(*) FROM widgets $$;

-- self-test: execute it, so a broken body fails here and not in production
DO $$ BEGIN PERFORM public.gadget_count(); END $$;

-- ROLLBACK
-- DROP FUNCTION public.gadget_count();
SQL

# A function nothing executes is created successfully with a fatal bug inside.
# Advisory, not a tripwire: it must be reported and must NOT fail the run.
migration clean function_without_self_test "ADVISORY" <<'SQL'
CREATE FUNCTION public.gadget_total() RETURNS bigint
  LANGUAGE sql AS $$ SELECT count(*) FROM widgets $$;

-- ROLLBACK
-- DROP FUNCTION public.gadget_total();
SQL

# --- must catch -------------------------------------------------------------

migration trip no_rollback_section "has no -- ROLLBACK section" <<'SQL'
CREATE TABLE gizmos (id bigint PRIMARY KEY);
SQL

migration trip drop_column "contains destructive DDL" <<'SQL'
ALTER TABLE widgets DROP COLUMN name;

-- DATA IMPACT: every row loses its name. No NULLs introduced elsewhere.
-- ROLLBACK
-- ALTER TABLE widgets ADD COLUMN name text;
SQL

migration trip destructive_without_data_impact "carries no -- DATA IMPACT note" <<'SQL'
ALTER TABLE widgets DROP COLUMN name;

-- ROLLBACK
-- ALTER TABLE widgets ADD COLUMN name text;
SQL

# The word-boundary fix above must not cost the real statement.
migration trip truncate_statement "contains destructive DDL" <<'SQL'
TRUNCATE widgets;

-- DATA IMPACT: every row deleted.
-- ROLLBACK
-- (not reversible)
SQL

migration trip column_type_change "contains destructive DDL" <<'SQL'
ALTER TABLE widgets ALTER COLUMN name TYPE varchar(40);

-- DATA IMPACT: names longer than 40 characters fail the cast.
-- ROLLBACK
-- ALTER TABLE widgets ALTER COLUMN name TYPE text;
SQL

migration trip update_backfill "mutates existing rows" <<'SQL'
ALTER TABLE widgets ADD COLUMN label text;
UPDATE widgets SET label = name WHERE label IS NULL;

-- ROLLBACK
-- ALTER TABLE widgets DROP COLUMN label;
SQL

migration trip insert_select_backfill_one_line "mutates existing rows" <<'SQL'
CREATE TABLE widget_history (widget_id bigint, name text);
INSERT INTO widget_history (widget_id, name) SELECT id, name FROM widgets;

-- ROLLBACK
-- DROP TABLE widget_history;
SQL

# REGRESSION 2026-09-28. The backfill check read one line at a time, so an
# INSERT with its SELECT on the next line read as "no row mutation". A real
# four-step backfill went through the original of this check that way.
migration trip insert_select_backfill_across_lines "mutates existing rows" <<'SQL'
CREATE TABLE widget_history (widget_id bigint, name text);
INSERT INTO widget_history (widget_id, name)
SELECT id, name
FROM widgets;

-- ROLLBACK
-- DROP TABLE widget_history;
SQL

migration trip alter_existing_function "alters an existing function" <<'SQL'
ALTER FUNCTION public.widget_count() SECURITY DEFINER;

-- ROLLBACK
-- ALTER FUNCTION public.widget_count() SECURITY INVOKER;
SQL

migration trip replace_function_that_exists_upstream "REPLACES existing object" <<'SQL'
CREATE OR REPLACE FUNCTION public.widget_count() RETURNS bigint
  LANGUAGE sql AS $$ SELECT 0::bigint $$;

-- self-test
DO $$ BEGIN PERFORM public.widget_count(); END $$;

-- ROLLBACK
-- (restore the previous body)
SQL

migration trip staged_rollout_flag "references payments_v2_enabled" <<'SQL'
ALTER TABLE widgets ADD COLUMN payments_v2_enabled boolean NOT NULL DEFAULT true;

-- ROLLBACK
-- ALTER TABLE widgets DROP COLUMN payments_v2_enabled;
SQL

# ---------------------------------------------------------------------------
# hooks/pre-tool-use.sh
#
# Each fixture runs the hook against a project directory holding exactly the
# bypass marker named, so "allowed in promotion mode" and "refused without it"
# are both proven.
# ---------------------------------------------------------------------------

SHA=0123456789abcdef0123456789abcdef01234567      # any full 40-character hash

# hook <allow|deny> <none|promotion|hotfix> <command>
hook() {
  local want=$1 marker=$2 cmd=$3 dir="$WORK/project-$2" out rc
  mkdir -p "$dir"
  case "$marker" in
    promotion) : > "$dir/.promotion-active" ;;
    hotfix)    : > "$dir/.hotfix-active" ;;
  esac
  out=$(PROJECT_DIR="$dir" "$HOOK" "$cmd" 2>&1)
  rc=$?
  checked=$((checked + 1))

  if [ "$want" = allow ] && [ "$rc" -ne 0 ]; then
    bad "hook [$marker] must allow: $cmd"; echo "$out" | sed 's/^/      /'
  elif [ "$want" = deny ] && [ "$rc" -eq 0 ]; then
    bad "hook [$marker] must refuse: $cmd"
  elif [ "$want" = deny ] && ! grep -q 'BLOCKED' <<<"$out"; then
    bad "hook [$marker] refused without saying why: $cmd"
  fi
}

# --- must allow: routine work ------------------------------------------------
# A hook that blocks routine work gets bypassed. These are the false-positive
# half, and they matter as much as the refusals.

hook allow none 'git status'
hook allow none 'git push origin feature/invoice-export'
hook allow none 'git push origin HEAD:staging'
hook allow none 'git push -u origin fix/main-nav'
hook allow none 'git push origin feature/maintenance-page'
hook allow none 'git push --force-with-lease origin feature/invoice-export'
hook allow none 'git log main --oneline && git push origin feature/invoice-export'
hook allow none 'rm -rf node_modules'
hook allow none 'npm run deploy:preview'

# --- must refuse: no marker --------------------------------------------------

hook deny none 'git push origin main'
hook deny none 'git push origin master'
hook deny none 'git push -u origin main'
# REGRESSION 2026-10-12. The first version matched only "origin main", so
# every refspec form of the same push went straight through.
hook deny none 'git push origin HEAD:main'
hook deny none 'git push origin origin/staging:main'
hook deny none 'git push origin feature/invoice-export:refs/heads/main'
hook deny none "git push origin $SHA:main"
hook deny none 'npm test && git push origin HEAD:main'

hook deny none 'git push --force origin feature/invoice-export'
hook deny none 'git push -f origin staging'
# REGRESSION 2026-10-12. A leading "+" on a refspec is a force push with no flag.
hook deny none 'git push origin +HEAD:staging'
hook deny none 'git commit --no-verify -m wip'
hook deny none 'git reset --hard origin/staging'
hook deny none 'git branch -D staging'
hook deny none 'rm -rf /'
hook deny none 'rm -rf ~'
hook deny none 'host deploy --prod'
hook deny none 'psql "$PROD_DATABASE_URL" -c "select 1"'

# --- promotion mode: exactly the two promotion pushes, nothing wider ---------

hook allow promotion 'git push origin origin/staging:main'
hook allow promotion "git push origin $SHA:main"
hook allow promotion 'host deploy --prod'
hook deny  promotion 'git push origin HEAD:main'
hook deny  promotion 'git push origin main'
hook deny  promotion 'git push origin feature/invoice-export:main'
hook deny  promotion 'git push origin 0123abc:main'
hook deny  promotion 'git push --force origin origin/staging:main'
hook deny  promotion 'git push origin +origin/staging:main'
hook deny  promotion 'git push origin origin/staging:main && git push origin HEAD:main'
hook deny  promotion 'psql "$PROD_DATABASE_URL" -c "select 1"'

# --- hotfix mode: the push to production, and only that ----------------------

hook allow hotfix 'git push origin main'
hook deny  hotfix 'git push --force origin main'
hook deny  hotfix 'host deploy --prod'
hook deny  hotfix 'git commit --no-verify -m urgent'

# ---------------------------------------------------------------------------
# A green result states how many things it checked, and zero is a failure.
# (PRINCIPLES.md #3 — this script is a gate too.)
# ---------------------------------------------------------------------------

if [ "$checked" -lt 1 ]; then
  echo "FAIL: no fixtures ran."
  exit 1
fi

if [ "$failed" -gt 0 ]; then
  echo
  echo "$failed of $checked fixtures failed. A guard is passing something it must catch,"
  echo "or catching something it must pass. Fix the guard, not the fixture."
  exit 1
fi

echo "$checked fixtures, every guard tripped and passed as expected."
exit 0
