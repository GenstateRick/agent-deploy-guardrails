#!/usr/bin/env bash
#
# pre-tool-use.sh — hard blocks enforced OUTSIDE the agent's judgment.
#
# Wire this into your agent tooling as a pre-execution hook: it receives the
# command about to run, and a non-zero exit refuses it.
#
# ---------------------------------------------------------------------------
# WHY A HOOK AND NOT AN INSTRUCTION
# ---------------------------------------------------------------------------
# Everything in AGENTS.md is an instruction. Instructions are followed by a
# capable, well-intentioned worker approximately always — which is not the same
# as always, and the gap is where the expensive mistakes live.
#
# These are the rules where "approximately always" isn't good enough. They are
# enforced mechanically, so compliance doesn't depend on the agent having read,
# remembered, and correctly applied a policy while three steps deep in an
# unrelated task at 2am.
#
# Keep this list SHORT. A hook that blocks routine work gets bypassed, and a
# bypassed hook is worse than no hook because it looks like protection.
# (PRINCIPLES.md #4.)
# ---------------------------------------------------------------------------

set -uo pipefail

CMD="${1:-}"
PROJECT_DIR="${PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Narrow, explicit bypass markers. Each is created by a specific procedure and
# removed by it on every exit path. A marker left on disk is a silently
# disabled safety system — audit for these if anything feels wrong.
HOTFIX_ACTIVE=0;    [ -f "$PROJECT_DIR/.hotfix-active" ]    && HOTFIX_ACTIVE=1
PROMOTION_ACTIVE=0; [ -f "$PROJECT_DIR/.promotion-active" ] && PROMOTION_ACTIVE=1

deny() {
  echo "BLOCKED: $1" >&2
  [ -n "${2:-}" ] && echo "         $2" >&2
  exit 1
}

# --- 1. Production database credentials may never appear locally -------------
# The strongest single control here. It makes an entire category of accident
# structurally impossible rather than merely discouraged.

if grep -qE '(PROD|PRODUCTION)_(DATABASE_URL|DB_PASSWORD|SERVICE_ROLE_KEY)' <<<"$CMD"; then
  deny "production database credentials referenced in a command" \
       "Production secrets live in the deployment platform, never on a developer machine."
fi

# --- 2. No manual production deploys from the agent --------------------------
# Production ships through CI, so every release has the same gates and the same
# audit trail. The promotion procedure sets its marker for the narrow window
# where it legitimately drives the production path.

if grep -qE '(deploy|publish|push).*(--prod|--production)' <<<"$CMD"; then
  [ "$PROMOTION_ACTIVE" -eq 1 ] \
    || deny "manual production deploy" \
            "Production deploys go through CI. A human runs this by hand if CI is broken."
fi

# --- 3. Staging-first git discipline -----------------------------------------
# Hotfix mode lifts exactly this restriction and nothing else.

if grep -qE 'git +push +.*origin +(main|master)\b' <<<"$CMD"; then
  [ "$HOTFIX_ACTIVE" -eq 1 ] \
    || deny "direct push to the production branch" \
            "Normal flow is feature -> staging -> production. For emergencies use the hotfix procedure."
fi

# --- 4. Never rewrite shared history -----------------------------------------
# No bypass. There is no legitimate agent-initiated reason for this.

if grep -qE 'git +push +.*(--force|-f)\b' <<<"$CMD" \
   && ! grep -q -- '--force-with-lease' <<<"$CMD"; then
  deny "force push" "Rewriting shared history is a human decision, made deliberately."
fi

# --- 5. Never bypass the checks ----------------------------------------------
# If a hook is wrong, fix the hook in the open. Skipping it hides the problem
# from exactly the people who need to see it.

grep -q -- '--no-verify' <<<"$CMD" \
  && deny "commit/push hooks bypassed" "If a hook is wrong, fix the hook."

# --- 6. Destructive git operations on shared branches ------------------------

if grep -qE 'git +(reset +--hard +origin/(main|master|staging)|branch +-D +(main|master|staging))' <<<"$CMD"; then
  deny "destructive operation on a shared branch"
fi

# --- 7. Unscoped recursive deletes -------------------------------------------

if grep -qE 'rm +(-[a-zA-Z]* )*-[a-zA-Z]*r[a-zA-Z]* +(/|~|\$HOME|\*)( |$)' <<<"$CMD"; then
  deny "unscoped recursive delete"
fi

exit 0

# ---------------------------------------------------------------------------
# DELIBERATELY NOT BLOCKED
#
# Reading production. Diagnosis is most of the work, and an agent that can't
# look will guess instead — which is the failure mode you were preventing.
# Reads are pre-authorised; writes never are. See AGENTS.md, "read/write
# asymmetry", including the two conditions: convert personal data to booleans
# at the query, and treat any function call as a write regardless of the verb.
# ---------------------------------------------------------------------------
