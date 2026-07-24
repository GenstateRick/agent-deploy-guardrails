# Seven Principles

Each of these has a scar behind it. The incidents are here because they're how
you decide whether a rule is yours to adopt: if the same failure is possible in
your system, take the rule. If it isn't, skip it. You can't make that call from
the rule alone.

---

## 1. A green pipeline is not an operational safety claim

Write down, next to each gate, **what that gate does not prove**. This is the
single highest-value paragraph in the entire system, and almost nobody writes
it.

Worked examples from a real pipeline:

- A migration **dry run** proves the migration *applies without erroring*. It
  does not prove the migration is safe. `DROP TABLE customers` applies
  perfectly cleanly.
- A **smoke test** that checks the homepage returns HTTP 200 proves the process
  is running and the router works. It proves nothing about whether payments,
  receipts, or webhooks function. A site can return 200 on every page while
  every transaction fails.
- A **build** proves the code compiles. It says nothing about behaviour.
- **Type checks and linting** prove internal consistency. A perfectly typed
  program can compute the wrong number.

None of this is an argument against those gates. They're all worth having. The
argument is that the *set* of green checks is not equivalent to "production
still works," and the moment your team starts treating it that way, you've
stopped having a safety system and started having a ritual.

> **Practice:** in your pipeline config, put a comment above each job stating
> what it does not prove. In `ci/pipeline.yml` here, every job has one.

---

## 2. Scrutiny is computed from the change, not applied uniformly

Uniform review is a trap. Set it high enough for a schema migration and nobody
can ship a typo fix; set it low enough for a typo fix and you're waving
migrations through. It cannot be correct at both ends.

So the pipeline classifies each change and picks a tier:

| Tier | When | What runs |
|---|---|---|
| **0 — Trivial** | Only docs, markdown, comments. No code, no config, no schema. | State the tier and ship. No review. |
| **1 — Standard** | Application code or config changed. No tripwire matched. | Full automated suite. Pattern scan over the diff. Ship if clean. |
| **2 — High-risk** | Any schema migration, **or** any tripwire path or content pattern matched. | Everything in tier 1, plus: scripted safety checks on each migration, two independent reviewers with *different* briefs, the full end-to-end suite, and a real transaction driven through staging. Any finding is a hard stop. |

**Tripwires are paths and patterns, not categories.** Naming a directory is not
enough — money moves through files nobody thought to list. So the tier-2 test
is a union of two things:

- **Paths:** payment libraries, webhook handlers, auth and session code,
  anything matching `*receipt*` or `*invoice*`, security config, the CI
  definition itself, and the agent's own hook scripts.
- **Content, in any file whatsoever:** added lines that call the payment SDK,
  reference a money-movement field, touch a sequence generator, or construct a
  privileged database client that bypasses row-level security.

The content half is what catches money moving in a file the path list never
anticipated. It will happen. Design for it.

**This generalises past software.** Every approval process in every company has
this problem: one review standard applied to a $200 expense and a $2M contract.
The fix is the same — compute the scrutiny from the properties of the thing.

---

## 3. Verification can lie. Audit the verifier

The most expensive failures in this system have all had the same shape: a check
reported success without having actually checked anything. Four real instances,
all of which shipped or nearly shipped:

**The suite that ran zero tests.** The test runner found no test files — an
environment quirk — and exited 0. "Ran nothing, encountered no failures" is
technically success, and every downstream gate believed it.
*Fix:* a green result must report **how many things it checked**, and zero is a
failure, not a pass.

**The green build for a different commit.** The command used to ask "is CI
green?" returns the most recent successful run — *regardless of which commit it
ran against*. Work landed after that run finished, so "CI is green" was true
and irrelevant: it was green for a commit that was no longer the one being
promoted.
*Fix:* assert the green run's commit hash equals the hash being deployed.
Mismatch is a stop.

**The exit code that came from the wrong process.** A "watch this CI run"
command was piped into another command. The pipeline's exit status is the
*last* stage's status, so a failing run reported as green and the deploy
continued.
*Fix:* never gate on a watch command's exit code. Query the run's conclusion
explicitly and require the literal string `success`.

**The deploy that went somewhere else.** A misconfigured working directory
caused the deploy tool to silently create a *new* hosting project named after
the directory, then build and deploy into it. Every command succeeded. A URL
was printed. Staging was never updated, and nothing anywhere reported a
problem.
*Fix:* deploys assert their target, and the environment link is inherited
explicitly rather than inferred.

The pattern is always the same: **the check answered a narrower question than
the one everybody thought it was answering.**

> **Practice:** for every gate you rely on, write the sentence "this could
> report success without having checked anything if ______." If you can't
> complete it, you haven't looked hard enough.

---

## 4. A control that fires on compliant work is worse than no control

This one cost the most to learn and generalises the furthest.

Policy required every schema migration to include a rollback section — the SQL
that reverses it. A separate safety check scanned migrations for destructive
statements (`DROP`, `TRUNCATE`, and friends) and flagged them for human review.

Both good rules. Together, a disaster: **the rollback section of an additive
migration is, by definition, a `DROP`.** Adding a table means the rollback
drops it. So the destructive-DDL scanner fired on *every correctly written
migration in the codebase.*

The check was punishing compliance. And because it fired constantly, it was
training everyone — human and agent — to wave through the exact alarm that
existed to catch a genuinely destructive change.

*Fix:* judge executable code only. Strip comments before scanning, so a
required rollback block cannot trip the wire.

It happened a second time, in a subtler form. A check flagged any migration
that replaced an existing database function, since replacing behaviour isn't
additive. But the codebase's convention used the same "create or replace"
syntax for brand-new functions too. The naive check hit roughly 43% of
migrations.
*Fix:* only flag a replacement when the object already exists upstream — an
actual replacement, not a stylistic coincidence.

**Anyone who has worked in a hospital knows this failure by its other name:
alarm fatigue.** Monitors that alarm constantly don't produce vigilance. They
produce staff who silence alarms reflexively, including the real one.

> **Practice:** measure your controls' false-positive rate before you trust
> them. A tripwire that fires on 43% of normal work is not a safety control —
> it's noise wearing a safety control's uniform. Tune it or delete it. Leaving
> it in place is the worst of the three options, because it looks like coverage.

---

## 5. Escalation is a written list, not a judgment call

"Use your judgment about when to ask me" is not a delegation policy. It's an
invitation to discover, after the fact, that your judgment and the agent's
differed.

The list is explicit, enumerable, and short enough to remember. A match halts
the pipeline and requires a human decision **per finding** — not a blanket
approval of the batch:

1. Destructive schema changes — dropping anything, changing a column's type,
   removing a constraint
2. Migrations that mutate existing rows (backfills), which are *not* additive
   no matter how they're described
3. Replacing an existing database function, view, trigger, or policy
4. Anything touching the flag that controls a staged rollout
5. Weakening a security control — auth checks, rate limits, row-level security,
   content security policy
6. Writes to a production database that weren't authorised this session
7. Changes to secrets, environment variables, or credential configuration
8. Deleting or renaming files
9. Adding an external service that will handle user data

Plus two catch-alls that matter more than the specifics:

- **Two rules give conflicting guidance.**
- **Confidence is below roughly 70%.**

Those two exist because no enumerated list is complete, and the agent
encountering the *edge* of the list is exactly the situation you want to hear
about.

**The emergency path is not exempt.** The fast route to production — the one
that skips staging for urgent fixes — runs the same tripwire scan, and a match
aborts it outright. The rule is written down explicitly because the temptation
is so predictable: *"it's just display copy that happens to live near the
payment flow"* does not override a path match. **The path list is the
authority, not the description of the change.** If you let the person in a
hurry classify their own change, the classification will always come back
"low-risk," because that's what they need it to be.

---

## 6. Claimed exemptions require evidence, not assertion

Some categories of change are pre-authorised — in the original system, work
behind a specific feature flag can proceed without stopping, because the flag
guarantees the code path is inert in production.

The pipeline does not take the agent's word for it.

To claim the exemption, it must cite **the file and line of the server-side
check that runs before the risky operation**, and **the test proving the path
does nothing when the flag is off**. If it cannot cite both, the exemption is
refused and the finding remains a hard stop.

The rule is written in the gate itself, because it closes an obvious hole: the
flag's name appearing *somewhere* in a large diff is not evidence that the new
code path is actually gated. Grep-level compliance is not compliance.

**This is the single highest-leverage control in the whole system**, and it's
the one I'd copy first if I could only copy one. Not because agents lie —
because "this is fine, it's covered by X" is a claim, and claims are checkable.
The cost of requiring a citation is seconds. The cost of accepting an assertion
is however long it takes you to find out.

It's also the control that transfers most cleanly to human organisations, where
"don't worry, legal already looked at it" is load-bearing far more often than
anyone is comfortable admitting.

---

## 7. The process may propose changes to itself. It may not make them

The last step of every deploy is a retrospective. If the run was notable — a
check failed, a tripwire fired, a fallback path was taken, timing was well off
expectation — the agent writes up what happened, the root cause, and **the
exact proposed amendment to the deploy process**.

It writes that into a log. It is explicitly forbidden from editing the deploy
process itself.

That's separation of duties, in a file. The system that runs the gates is not
allowed to change the gates. A human reviews the proposal and applies it
through the normal change process.

Two smaller rules keep it honest:

- If the suggestion can't be stated in two lines, it isn't ready to be
  suggested. Log it and say so.
- A run that went exactly as expected produces **nothing**. No write-up, no
  suggestion. Otherwise the log fills with routine entries and stops being
  read — principle 4 again: something that fires constantly stops carrying
  information.

---

## Appendix: guards that didn't become principles

Smaller lessons, each of which is now a check somewhere in the system.

**Never force-remove a working directory you haven't inspected.** A cleanup
routine removed directories whose branches were fully merged. A freshly created
one qualified — and held hours of uncommitted work. The guard now refuses to
remove any directory with uncommitted changes, and the date of the loss is in
the comment so nobody optimises it away.

**Concurrency needs isolation, not care.** Two deploys running at once shared a
fixed scratch directory. The second reused the first's path, a branch creation
failed, a merge landed on a detached HEAD, and one run's work stacked silently
on the other's. Pushing it would have shipped the wrong code. The fix wasn't
better sequencing — it was a unique per-run path, so collision becomes
structurally impossible.

**Assert the shipped set.** Before the final push, the pipeline diffs what's
about to ship against what was *supposed* to ship, and aborts on anything
unexpected. This is the check that caught the incident above before it reached
production.

**Fix forward, don't roll back, when schema and code disagree.** If migrations
applied but the deploy failed, rolling the code back leaves it running against
a schema from the future. Roll back for code and smoke failures; fix forward
for migration failures. Decide which is which *before* you're in the incident.

**An emergency fix that isn't backported gets silently reverted.** The urgent
patch goes straight to the production branch. The next routine promotion
carries the staging branch — which still contains the broken version — right
over the top of it. The backport is mandatory and the deploy isn't considered
finished without it.

**Capture output from the stream you meant.** A deployment URL was read from
merged stdout and stderr, so a diagnostic hint line got captured instead of the
URL and passed to the next command. Read from one stream deliberately.

**Duplicated config drifts.** Two places encoded which file patterns skip CI.
They disagreed, and the pipeline either waited for a run that would never come
or declared success while a run was still going. They now carry a "keep in
sync" comment naming each other — the cheapest available fix short of a single
source of truth, and worth writing down when a single source isn't available.
