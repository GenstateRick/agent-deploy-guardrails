#!/usr/bin/env bash
#
# verify-schema-sync.sh — is staging structurally identical to production?
#
# Exit 0 = identical, or the diff matches the documented allowlist exactly.
# Exit 1 = real drift.
# Exit 2 = configuration error (could not reach a database, etc.).
#
# ---------------------------------------------------------------------------
# USE A SEMANTIC DIFF, NOT A TEXT DIFF
# ---------------------------------------------------------------------------
# The obvious implementation — dump both schemas, run `diff` — produces
# constant noise: column ordering, whitespace inside function bodies, a
# constraint declared inline in one environment and as an ALTER in the other.
# All semantically identical. All shown as differences.
#
# A comparator that cries wolf trains you to skim its output, and the day it
# reports a genuinely missing column you will skim that too. PRINCIPLES.md #4.
#
# Use a tool that understands the schema (migra, apgdiff, Liquibase diff, or
# your ORM's equivalent) and compares MEANING.
#
# ---------------------------------------------------------------------------
# WHAT THIS COMPARISON CANNOT SEE
# ---------------------------------------------------------------------------
# migra compares the SHAPE of a schema. It does not compare privileges: GRANT,
# REVOKE and column-level grants do not appear in its output at all. A
# migration whose whole purpose is to change who may write to a table produces
# no drift, so this script exits 0 whether or not that migration ran in both
# environments.
#
# "Schemas identical" below means identical in everything this tool looks at.
# For a privilege change, read the privileges from both databases directly.
#
# Every comparator has a list like this one. Find yours and write it here.
# PRINCIPLES.md #3, "the comparison that could not see the change."
# ---------------------------------------------------------------------------

set -uo pipefail

ALLOWLIST="${ALLOWLIST:-.schema-allowlist.sql}"

command -v migra >/dev/null || { echo "migra not installed"; exit 2; }

DIFF=$(migra --unsafe "$STAGING_DB_URL" "$PRODUCTION_DB_URL" 2>/dev/null) || {
  echo "could not compare schemas — check connectivity and credentials"
  exit 2
}

if [ -z "$DIFF" ]; then
  echo "schemas identical (structure only — privileges are not compared)"
  exit 0
fi

# ---------------------------------------------------------------------------
# THE ALLOWLIST
#
# In-flight work legitimately produces a window where staging is ahead of
# production: the migration has landed on staging and hasn't been promoted yet.
# The allowlist holds a BYTE-EXACT copy of the expected diff for that window.
#
# Three rules, and they are what keep this from becoming a place drift goes to
# be forgotten:
#
#   1. Byte-exact match, not "contains". A near-match is a real difference.
#   2. Every entry traces to a named migration that exists on staging and not
#      on production — i.e. drift a pending promotion will clear. Drift with no
#      owning migration is NEVER allowlisted. Stop and ask a human.
#   3. Every entry has a written clearing condition, and the file is deleted
#      once the promotion lands.
#
# An allowlist entry with no expiry is a permanent agreement to stop noticing
# something. That is the failure mode this file exists to prevent.
# ---------------------------------------------------------------------------

if [ -f "$ALLOWLIST" ] && [ "$DIFF" = "$(cat "$ALLOWLIST")" ]; then
  echo "drift matches the documented allowlist exactly"
  echo "reminder: delete $ALLOWLIST once its migration reaches production"
  exit 0
fi

echo "SCHEMA DRIFT — staging and production differ:"
echo "$DIFF"
echo
echo "There are no trivial differences. A column is either there or it isn't."
echo "Fix it in the database. Do not silence it in this comparator."
exit 1
