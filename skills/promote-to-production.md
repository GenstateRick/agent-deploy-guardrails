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
It does not prove that a function the migration created actually runs — the
body is compiled the first time it executes, and nothing in the pipeline
executes it. It does not prove any transaction works — the smoke check is a
reachability probe, not a business-process test. It does not prove the green
run was even for *this* commit.

Step 4 is what turns "the checks passed" into "this won't break operations."
**CI green is a precondition for running this procedure, not a substitute for
it.**

---

## Prerequisites

- On the staging branch, working tree clean.
- A green pipeline run exists **for the exact commit being promoted**
  (asserted in step 2 — do not take this on faith).
- Deployment and repository CLIs authenticated.
- **This file is current.** A procedure kept in the repository is versioned
  like everything else, so a branch cut before its last change executes the
  old one. Read it from the shared staging branch before step 0, not from
  wherever you happen to be standing.

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
STAGING_SHA=$(git rev-parse --verify -q origin/staging) || exit 1
PROMOTE_SHA=$STAGING_SHA

if [ "$GREEN_SHA" != "$STAGING_SHA" ]; then
  echo "green run was for $GREEN_SHA, staging is at $STAGING_SHA"
  # Do not stop yet. Work out WHICH kind of mismatch this is (below).
fi
```

**Two different things produce a mismatch, and they have different answers.**

- **Something real landed after CI passed.** A run exists, or is in flight,
  for the new head. Wait for it, then restart this procedure from step 1.
- **The pipeline will never run for the new head.** If your pipeline skips
  documentation-only commits (`paths-ignore` in `ci/pipeline.yml`), a head
  commit that touches only those paths produces no run. Not a pending one.
  None. Waiting cannot make the two hashes match.

Tell them apart before reporting a stop:

```bash
git diff --name-only "$GREEN_SHA".."$STAGING_SHA"   # every path skipped by CI?
<query CI for runs on $STAGING_SHA>                 # empty = none exists
```

In the second case, **promote the green commit, not the head**:

```bash
PROMOTE_SHA=$GREEN_SHA
```

This holds only if *every* file in that diff matches the pipeline's skip
patterns. One file that doesn't, and it is the first case. List the files left
behind in the final report. They ship with the next promotion.

Do not promote the head on your own as a one-time exception — shipping a
commit that no run was ever for is a human's decision — and do not manufacture
a code-touching commit to force a run. Both turn "the green run is for this
commit" from an assertion into a habit of making exceptions.

This is not a rare case if you adopt step 10. Every fix this procedure applies
to itself is a documentation-only commit on the head of staging, so the next
promotion starts here.

Everything from here on is about `$PROMOTE_SHA`.

Also assert that the migration dry-run job specifically passed, not just the
run overall. Where any job in the run is allowed to fail without failing the
run, read the per-job results: a run can conclude `success` with a red build
inside it (`PRINCIPLES.md` #3).

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

**Know what the comparison cannot see.** Most schema diff tools compare
structure and ignore permissions. A migration that only revokes and grants
access produces no difference, so this step is green whether or not that
migration did anything. For a change of that kind, read the permissions
directly from both databases.

---

## Step 4 — Operational-risk analysis · THE GATE

```bash
CHANGED=$(git diff --name-only origin/main.."$PROMOTE_SHA")
MIGRATIONS=$(git diff --name-only origin/main.."$PROMOTE_SHA" -- 'migrations/**')
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
mandatory. It also prints an `ADVISORY` for any migration that defines a
function or trigger with no self-test; carry those to reviewer A.

**4b. Two independent reviewers, different briefs, in parallel.** Not one
reviewer twice. Diversity of lens catches what redundancy can't:

- *Reviewer A — invariants and compliance.* Sequence continuity unbroken. No
  gaps possible. Documents still render with the correct issuing entity.
  Migrations additive-only, each carrying a rollback section, and a data-impact
  note if destructive. Every function or trigger a migration defines is
  *executed* by a test in that migration — a function that was only created
  has not been checked by anything. The staged-rollout flag never written by
  code, seed, or migration. Legacy payment paths behaviorally unchanged.
- *Reviewer B — security.* No cardholder data added to schema, logs, or
  application state. No secrets or credential config touched. No row-level
  security policy weakened or dropped. Content security policy not broadened.
  Auth checks intact on every protected route.

Both return findings tagged `TRIPWIRE` or `ADVISORY`.

Three rules for running reviewers as separate agents:

- **Hand them the diff, not your summary of it.** A reviewer given your
  conclusion tends to return it confirmed.
- **No gate waits forever.** Each reviewer carries a deadline. When it expires,
  take whatever has been reported and do the review inline. A stalled reviewer
  is a scheduling problem, never a reason to skip the review.
- **An all-clear is a claim.** If a reviewer ran on a cheaper model and found
  nothing on a money or security path, re-derive its single riskiest claim
  yourself before accepting it. If your number disagrees with theirs, check
  your own filter first — print the whole partition, not the filtered count.

**4c. Behavioral gates.** Run these while the reviewers work:

- **The full end-to-end suite, compared against a baseline** — not the smoke
  subset, and not judged on whether it passes. A long suite against a shared
  staging environment fails some tests whatever you changed. So run the
  identical suite against the commit *before* the change, and judge only the
  failures the change introduced:
  - Before either run, stop every development server already on the machine.
    A test runner that reuses whatever is listening on its port will test
    someone else's code and look perfectly normal doing it.
  - Normalize both failure lists the same way before diffing them, and confirm
    the normalization changed something. A pattern your tool silently does not
    support is a no-op, and the diff then reports regressions that do not
    exist.
  - A cached baseline may only ever *pass* this gate. If the comparison against
    a cached baseline shows any new failure, run the baseline live before
    deciding anything.
  - **A database error never counts as existing decay.** Both runs talk to the
    same staging database, so a schema-level fault fails on both sides and the
    comparison clears it. Read the error text of every failure that is not new.
  - A test that mocks the request it is named after is a test of the screen.
    Do not count it as evidence about the code behind that request.
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
  line. Do not promote. Require an explicit per-finding human decision. If not
  approved: run step 9, exit.
- **Pre-authorized exemptions are reported but don't auto-stop** — *provided
  they're evidenced.* Cite the file and line of the gate that runs before the
  risky call, and the test proving the path is inert when the flag is off.
  **Cannot cite both? The finding stays a hard stop.** (Principle 6.)
- **`ADVISORY` only → proceed**, but surface the list in the final report (and
  the pull request body, on the fallback path) so the record exists.
- **A fix is a new change.** If a finding is fixed during this run, the fix
  goes back through the gate before the promotion continues: the scripted
  checks, a reviewer pass with the original findings as its checklist, and the
  tests that exercise what the fix touched. Fixes made in response to findings
  have contained findings of their own.

State the computed tier and the adjudication outcome out loud before moving on.

---

## Step 5 — Capture a rollback target

**Before anything moves**, record the currently-live deployment so a rollback
has a known-good target instead of a guess made under pressure:

```bash
<host CLI> list --production > "$JOB_DIR/previous-production.txt"
```

If capture fails, warn loudly and proceed — but say so in the final report, so
nobody discovers mid-incident that there's no target.

---

## Step 6 — Promote: fast-forward production to the gated commit

```bash
git fetch origin main staging
git push origin origin/staging:main                 # the normal case
git push origin <full 40-character hash>:main       # when step 2 chose the green commit
```

One of those two, typed exactly. The hook allows these two commands and no
other push to production, and it reads the command's text: a variable or an
abbreviated hash is a push it cannot verify, so it refuses it. Never `--force`.

**This step used to be a pull request**: open it, wait for it to be mergeable,
merge it. That stopped being the default once two things were true. The step 4
gate reviewed every change more rigorously than anyone skimming a pull request
had. And no check ran on the pull request that had not already run on the
staging commit. At that point the pull request was a wait with a ceremony
attached.

If either of those is not true in your system, keep the pull request as the
default. If your branch protection requires a human review before production,
that requirement is a gate. Keep it.

Switching was a separate revision from introducing the gate, on purpose. Do not
change how code reaches production and what guards that path in the same
change: if a promotion then goes wrong, you need to know which of the two did
it.

**The push can be refused three ways. Each has its own answer.**

- **Not a fast-forward.** Production has commits staging lacks. Look at them:
  `git log origin/staging..origin/main --no-merges --oneline`. Empty means they
  are only merge commits left behind by earlier pull-request promotions, and
  the trees are identical — take the fallback in step 7. Not empty means
  someone committed to production directly. Stop and reconcile by hand.
- **Refused by branch protection.** Take the fallback. Never force.
- **Refused by a permission layer above this procedure.** Take the fallback. Do
  not retry the push in other shapes, and do not rearrange refs to satisfy a
  pattern. A refusal is an answer (`PRINCIPLES.md` #5). Expect the same layer
  to refuse other production writes in the same session; those go to a human
  as exact commands.

**Without a pull request, the final report is the record.** It must state
everything the pull request body used to: commit count; migration files or "no
schema changes"; **the computed tier and analysis outcome**; a link to the
green run plus explicit confirmation that the green commit equals the promoted
commit; any advisories; and any files step 2 left behind.

**Your pipeline has to know about this path.** A pipeline step that finds the
staging commit by looking at a merge commit's second parent fails on the first
fast-forward promotion, where there is no merge commit. This happened
(`PRINCIPLES.md` #3, "the fallback that answered with its own question"). Make
the first fast-forward a promotion you can afford to have stall, and note that
when the pipeline stops before the migration job, production is untouched:
that is a safe state to fix forward from, not a reason to roll back.

---

## Step 7 — Fallback: the pull request path

Only when step 6 was refused, or a human asks for it.

Open a pull request from staging to production. Its body carries the record
listed in step 6.

Then wait for genuinely mergeable, not just "checks passed". A "watch the
checks" command can exit 0 having watched only the checks it knew about, while
a separate run triggered by the pull request itself is still in flight. Branch
protection then blocks the merge and a merge attempt fails.

Gate on the repository's own mergeable state, not on the watch command:

```bash
for i in $(seq 1 30); do
  STATE=$(<query PR merge state>)
  [ "$STATE" = "CLEAN" ] && break
  sleep 10
done
[ "$STATE" = "CLEAN" ] || { echo "ABORT: merge state $STATE"; exit 1; }
```

Then merge with a **merge commit, not a squash**, if any downstream step needs
to resolve the pre-merge commit (build-artifact reuse typically does). A squash
creates a new commit that no green run was ever for.

A promotion made this way leaves a merge commit on production that staging does
not have, which is why the next fast-forward is refused. Carry it back: base
the next change to staging on production's head.

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
| A job before the migration | Production branch moved, production itself untouched: nothing migrated, nothing deployed. A safe state. **Fix forward**; there is nothing to roll back. |
| Migration job | Code merged, schema half-applied. **Fix forward** with a new change. Do not roll back — the code would run against a future schema. |
| Deploy job | Migrations applied, code didn't ship. Retry the deploy. |
| Smoke check | Roll back to the step 5 target, then diagnose. |
| Read-path probe | Reachable but broken. Same rollback target. Diagnose before re-promoting. |

---

## Step 9 — Cleanup · ALWAYS

```bash
rm -f "$PROJECT_DIR/.promotion-active"
```

Every exit path. If removal fails, say so prominently and treat it as an
incident: production safety is disabled until it's gone.

---

## Step 10 — Retrospective · fix the mechanics, propose the gates

Only if the run was notable: a check failed, a tripwire fired, a fallback ran,
timing was well off expectation, or a human had to intervene. A clean run that
went as expected writes **nothing** and reports "retrospective: nominal."

If notable, sort each change you would make to this file by one question:
**does it make any gate fire less often?**

**No — mechanics. Apply it.** Fixing a broken command or pattern in this file.
Documenting a failure mode you hit and how to triage it. Adding a check.
Making an existing check stricter or more reliable. Correcting a stale
reference.

1. Make the edit *after* step 9, never mid-run. The version that executed is
   the record of what the gates ran under.
2. One commit per improvement, through the normal change process to staging.
3. List each applied change in the final report, with the full detail in the
   log: what happened, root cause, the edit.

Undoing one is an ordinary revert.

**Yes — a gate. Propose it.** Anything that weakens, narrows, removes or
bypasses a gate: the tripwire paths and patterns, the tier rules, adjudication,
the escalation list, exemptions and allowlists, the hook, the baseline
discipline in 4c, or the promotion mechanics in steps 5–7. Append to the log:
date, what happened, root cause, and the full proposed amendment. Then surface
**at most two lines**:

```
SUGGESTION: <one line — what to change>
WHY:        <one line — what went wrong this run>
```

If it can't be said in two lines it isn't ready; log it and say so.

**When unsure, it's a gate.** A change that makes a check stricter is
mechanics. A change that means "this check now fires less often, or can be
skipped" is a gate change however reasonable the argument — including "it
fires on compliant work," which is how most safety rails are taken apart.

**This step never loosens a gate.** The process fixes what it can prove is
broken; a human decides what it guards. See principle 7.

Applying a fix here leaves a documentation-only commit on the head of staging.
The next promotion will meet it in step 2.

---

## Rules

- The step 4 gate is not optional. A tripwire stops the promotion until a human
  explicitly approves it. A green pipeline does not override a tripwire.
- The gates in steps 0–4 are the same on both promotion paths, and are never
  skipped on either.
- Never promote a commit that is not the green run's commit. When the head of
  staging has no run and never will, promote the green commit, not the head.
- Never promote if the migration dry-run failed.
- The only pushes to production are the two in step 6, typed exactly. Never
  `--force`. A refused push is not retried in another shape.
- No gate waits forever. A reviewer past its deadline is reviewed inline, not
  skipped.
- The end-to-end baseline may only ever pass the gate. It never clears a
  database error.
- Fix forward for migration failures; retry a failed deploy job; roll back for
  smoke and read-path failures.
- The promotion flag is created in step 0 and removed in step 9 on every path.
- Step 10 applies mechanics and proposes gates. It never loosens a gate. When
  unsure, it's a gate.

## When not to use this

- **Emergencies:** see `hotfix.md` — and note it has *more* restrictions, not
  fewer.
- **Rolling back:** use the host's rollback command directly. Don't route an
  incident through a procedure designed for planned change.
