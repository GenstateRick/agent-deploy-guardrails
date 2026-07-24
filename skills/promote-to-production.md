# Promote staging → production

The centerpiece. This is the procedure an agent follows to put code in front of
customers, and the place where the capable model earns its cost.

Give this file to your agent as a skill, runbook, or slash command — whatever
your tooling calls a saved procedure.

---

## What CI green does not prove

Read this before the steps, because it's the reason the steps exist.

By the time this procedure runs, the change already has a green pipeline. That
proves: it compiles, the tests that exist pass, the schema migration applies
without erroring, and the homepage returns 200.

It does **not** prove the migration is *safe* (a `DROP TABLE` applies cleanly).
It does not prove any transaction works — the smoke check is a reachability
probe, not a business-process test. It does not prove the green run was even
for *this* commit.

Step 4 is what turns "the checks passed" into "this won't break operations."
**CI green is a precondition for running this procedure, not a substitute for
it.**

---

## Prerequisites

- On the staging branch, working tree clean.
- Staging's HEAD has a green pipeline run **at the exact commit being
  promoted** (asserted in step 2 — do not take this on faith).
- Deployment and repository CLIs authenticated.

---

## Step 0 — Set the promotion flag

```bash
touch "$PROJECT_DIR/.promotion-active"
```

A marker file saying "we are deliberately in production-promotion mode." The
pre-tool-use hook treats it as a narrow bypass for production-path blocks that
are otherwise refused outright.

**It must be removed in step 9 on every exit path** — success, failure, or
abort. A marker left on disk is a silently disabled safety system, which is
worse than never having had one, because you'll believe you're protected.

---

## Step 1 — Pre-flight

```bash
git fetch origin main staging
git log origin/main..staging --oneline
git diff --name-only origin/main..staging -- 'migrations/**'
```

Abort if not on staging. If staging isn't ahead of main, there's nothing to
promote — run step 9 and exit.

---

## Step 2 — Assert the green run is for *this* commit

The failure this prevents: your "is CI green?" query returns the most recent
successful run regardless of which commit it ran against. If anything landed
after that run, "CI is green" is true and meaningless.

```bash
GREEN_SHA=$(<query your CI for the latest successful run's commit hash>)
STAGING_SHA=$(git rev-parse origin/staging)

if [ "$GREEN_SHA" != "$STAGING_SHA" ]; then
  echo "ABORT: green run was for $GREEN_SHA, promoting $STAGING_SHA"
  echo "Something landed after CI passed. Re-run CI on the new head."
  exit 1
fi
```

Also assert that the migration dry-run job specifically passed, not just the
run overall.

---

## Step 3 — Verify schema parity

Compare the staging and production schemas semantically — a real diff tool,
not a text diff of dump files, so that column ordering and whitespace don't
generate noise that trains you to ignore the output (principle 4).

```bash
./scripts/verify-schema-sync.sh   # exit 0 = identical or matches allowlist
```

Deliberate, documented exceptions live in a version-controlled allowlist file
that must match the diff **byte for byte**. Every entry needs a written
clearing condition. An allowlist without expiry conditions becomes a permanent
record of drift you've agreed to stop noticing.

---

## Step 4 — Operational-risk analysis · THE GATE

```bash
CHANGED=$(git diff --name-only origin/main..staging)
MIGRATIONS=$(git diff --name-only origin/main..staging -- 'migrations/**')
```

### Tripwire set

Any match forces tier 2, and findings within it are hard stops.

**Paths:**
```
migrations/**                    always
src/lib/payments/**              payment logic
src/app/api/webhooks/**          inbound external events
src/lib/auth/**  src/middleware  auth and session
*invoice*  *receipt*             anything financial-document shaped
src/config/security.*            CSP, headers, cookie policy
.github/workflows/**             the pipeline defining these gates
hooks/**                         the agent's own guardrails
.env*                            configuration and secrets
```

**Content patterns — in any file, matched against added lines only:**
```
<payment SDK namespace>.         SDK calls anywhere
application_fee|transfer_data    money-movement fields
next_invoice_number              sequence generators that must not gap
createAdminClient|service_role   privileged clients that bypass RLS
CREATE POLICY|DROP POLICY        row-level security changes
payments_v2_enabled              staged-rollout flag
```

The content half exists because money moves through files nobody remembered to
list. The path list is a proxy; the content patterns are the backstop.

### Tier 0 — Trivial

Every changed path is docs, markdown, or comments; no migrations; nothing under
source, scripts, CI, or config. State the tier, state the file list, go to
step 5. No review. This is what keeps a documentation change from paying for
scrutiny it doesn't need.

### Tier 1 — Standard code

Source or config changed, no migrations, no tripwire match. Run the content
pattern scan over the diff to confirm. If clean, state the tier and proceed. If
a pattern matches unexpectedly, escalate to tier 2 — the scan outranks the
initial classification.

### Tier 2 — High-risk

**4a. Scripted migration checks.** Run `scripts/check-migration-safety.sh`
against each migration. Each failure is a tripwire. Note that it strips
comments before matching — see principle 4 for the incident that made that
mandatory.

**4b. Two independent reviewers, different briefs, in parallel.** Not one
reviewer twice. Diversity of lens catches what redundancy can't:

- *Reviewer A — invariants and compliance.* Sequence continuity unbroken. No
  gaps possible. Documents still render with the correct issuing entity.
  Migrations additive-only, each carrying a rollback section, and a data-impact
  note if destructive. The staged-rollout flag never written by code, seed, or
  migration. Legacy payment paths behaviourally unchanged.
- *Reviewer B — security.* No cardholder data added to schema, logs, or
  application state. No secrets or credential config touched. No row-level
  security policy weakened or dropped. Content security policy not broadened.
  Auth checks intact on every protected route.

Both return findings tagged `TRIPWIRE` or `ADVISORY`.

**4c. Behavioural gates.** Run these while the reviewers work:

- **The full end-to-end suite** — not the smoke subset.
- **A real transaction.** If a payment, invoice, or webhook tripwire matched:
  drive one actual test-mode transaction through staging and verify the record
  lands *and* the document generates. This is the check that would have caught
  "everything is green and the button does nothing." The agent performs it;
  it is not a reminder for a human to remember.
- **A correctness review** at high effort over the diff. The two reviewers
  above are scoped to invariants and security — neither is hunting for ordinary
  bugs. This is the backstop.

**4d. Adjudicate.**

- **Any `TRIPWIRE` → hard stop.** Print every finding verbatim with file and
  line. Do not open the PR. Require an explicit per-finding human decision. If
  not approved: run step 9, exit.
- **Pre-authorised exemptions are reported but don't auto-stop** — *provided
  they're evidenced.* Cite the file and line of the gate that runs before the
  risky call, and the test proving the path is inert when the flag is off.
  **Cannot cite both? The finding stays a hard stop.** (Principle 6.)
- **`ADVISORY` only → proceed**, but surface the list in the PR body and the
  final report so the record exists.

State the computed tier and the adjudication outcome out loud before moving on.

---

## Step 5 — Open the PR

Body must state: commit count; migration files or "no schema changes"; **the
computed tier and analysis outcome**; a link to the green run plus explicit
confirmation that the green commit equals the promoted commit; and any
advisories.

---

## Step 6 — Wait for genuinely mergeable, not just "checks passed"

A "watch the checks" command can exit 0 having watched only the checks it knew
about, while a separate run triggered by the PR itself is still in flight.
Branch protection then blocks the merge and a merge attempt fails.

Gate on the repository's own mergeable state, not on the watch command:

```bash
for i in $(seq 1 30); do
  STATE=$(<query PR merge state>)
  [ "$STATE" = "CLEAN" ] && break
  sleep 10
done
[ "$STATE" = "CLEAN" ] || { echo "ABORT: merge state $STATE"; exit 1; }
```

---

## Step 7 — Capture a rollback target, then merge

**Before merging**, record the currently-live deployment so a rollback has a
known-good target instead of a guess made under pressure:

```bash
<host CLI> list --production > "$JOB_DIR/previous-production.txt"
```

If capture fails, warn loudly and proceed — but say so in the final report, so
nobody discovers mid-incident that there's no target.

Then merge with a **merge commit, not a squash**, if any downstream step needs
to resolve the pre-merge commit (build-artifact reuse typically does).

---

## Step 8 — Watch production CI, then probe a read path

After the deployment smoke check goes green, run one probe that actually
exercises the application against its database:

```bash
code=$(curl -s -o "$JOB_DIR/probe.json" -w "%{http_code}" \
  https://$APP/api/public/health-with-data)
[ "$code" = "200" ] && jq -e '.items | length > 0' "$JOB_DIR/probe.json" \
  && echo "read path OK" \
  || echo "READ PATH FAILED — deployed and reachable, but the app is broken"
```

Use an endpoint that is unauthenticated, read-only, and returns no personal
data. This catches "homepage 200 but every page errors" — bad environment
variables, a broken database client, a runtime failure on first query.

### Failure matrix — decide this now, not during the incident

| Failed | Do this |
|---|---|
| Migration job | Code merged, schema half-applied. **Fix forward** with a new change. Do not roll back — the code would run against a future schema. |
| Deploy job | Migrations applied, code didn't ship. Retry the deploy. |
| Smoke check | Roll back to the step 7 target, then diagnose. |
| Read-path probe | Reachable but broken. Same rollback target. Diagnose before re-promoting. |

---

## Step 9 — Cleanup · ALWAYS

```bash
rm -f "$PROJECT_DIR/.promotion-active"
```

Every exit path. If removal fails, say so prominently and treat it as an
incident: production safety is disabled until it's gone.

---

## Step 10 — Retrospective · suggest-only

Only if the run was notable: a check failed, a tripwire fired, a fallback ran,
timing was well off expectation, or a human had to intervene. A clean run that
went as expected writes **nothing** and reports "retrospective: nominal."

If notable, append to a log: date, what happened, root cause, and the full
proposed amendment to this file. Then surface **at most two lines**:

```
SUGGESTION: <one line — what to change>
WHY:        <one line — what went wrong this run>
```

If it can't be said in two lines it isn't ready; log it and say so.

**This step never edits this file.** The process proposes; a human disposes.
See principle 7.

---

## Rules

- The step 4 gate is not optional. A tripwire stops the promotion until a human
  explicitly approves it. A green pipeline does not override a tripwire.
- Never merge if the green run's commit ≠ the promoted commit.
- Never merge if the migration dry-run failed.
- Fix forward for migration failures; roll back for code, deploy, and smoke
  failures.
- The promotion flag is created in step 0 and removed in step 9 on every path.
- Step 10 never edits this file.

## When not to use this

- **Emergencies:** see `hotfix.md` — and note it has *more* restrictions, not
  fewer.
- **Rolling back:** use the host's rollback command directly. Don't route an
  incident through a procedure designed for planned change.
