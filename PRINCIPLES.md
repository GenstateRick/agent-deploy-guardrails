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
- A **build** proves the code compiles. It says nothing about behavior.
- **Type checks and linting** prove internal consistency. A perfectly typed
  program can compute the wrong number.
- A migration that **creates a database function** proves the function was
  stored. It does not prove the function runs. Postgres compiles a procedural
  function body the first time it executes, not when it is created, so a
  function with a fatal bug inside is created without complaint.
- An **end-to-end test that mocks the API** proves the screen renders. It
  proves nothing about the code behind the request it replaced.

None of this is an argument against those gates. They're all worth having. The
argument is that the *set* of green checks is not equivalent to "production
still works," and the moment your team starts treating it that way, you've
stopped having a safety system and started having a ritual.

The last two examples were added after they happened.

A migration added an audit trigger to five tables. It applied cleanly to
staging, applied cleanly in the production dry run, and passed the schema
comparison. Three reviewers cleared it; one of them confirmed that every column
the function referenced existed. The fault was a type error inside the function
body, which nothing had executed. The first real update to any of those tables
raised an error, and because the trigger ran in the same transaction, the error
canceled the update it was there to record. One behavioral test caught it.

A feature branch went green on everything — types, lint, more than five
thousand unit tests, the build, and thirteen of thirteen end-to-end tests for
the feature. It held a logic fault that left one path through the feature
permanently stuck. The end-to-end tests mocked the three requests where the
fault lived, and the unit test with the right name passed for an unrelated
reason. A reviewer handed the diff and asked to find what was wrong found it.

> **Practice:** in your pipeline config, put a comment above each job stating
> what it does not prove. In `ci/pipeline.yml` here, every job has one.
>
> **Practice:** a migration that defines a function or trigger carries a test
> that *executes* it — in the migration itself, rolled back afterward, so it
> runs everywhere the migration runs.

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
| **2 — High-risk** | Any schema migration, **or** any tripwire path or content pattern matched. | Everything in tier 1, plus: scripted safety checks on each migration, two independent reviewers with *different* briefs, the full end-to-end suite compared against the same run on the pre-change commit (principle 4), and a real transaction driven through staging. Any finding is a hard stop. |

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

**This generalizes past software.** Every approval process in every company has
this problem: one review standard applied to a $200 expense and a $2M contract.
The fix is the same — compute the scrutiny from the properties of the thing.

---

## 3. Verification can lie. Audit the verifier

The most expensive failures in this system have all had the same shape: a check
reported success without having actually checked anything. Eight real
instances, all of which shipped or nearly shipped. The first four were here
when this was first published. The second four have happened since.

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

**The fallback that answered with its own question.** A pipeline step worked
out which commit was being promoted by running a command and, if that failed,
using a default. The command prints its unresolved argument before it fails, so
the default never ran and the next step was handed a string that was not a
commit. It had worked on every promotion made through a merge. On the first
fast-forward promotion it failed, every downstream job was skipped, and the
production branch had moved while production itself still ran the old build
against an unmigrated database.
*Fix:* a fallback that has never executed is not a tested path. Run it on
purpose before depending on it.

**The red job inside the green run.** One build job was allowed to fail without
failing the run, because it was speculative: a head start on the production
build. The run reported success with that job red. The production deploy falls
back to the same build on the same machine, so a red speculative build was a
promotion that would fail, announced as a pass.
*Fix:* wherever any job is allowed to fail, read the per-job results. The
run's conclusion is a summary written by the jobs that were allowed a vote.

**The comparison that could not see the change.** The schema comparison diffs
structure: tables, columns, constraints, functions. It does not diff
permissions. A migration whose whole purpose was to revoke and re-grant access
produced no difference at all, so the parity check was green whether or not
the migration had done anything.
*Fix:* know what your comparator is blind to, write it next to the job, and
verify that class of change directly.

**The monitor that watched a third of the fleet.** An hourly job checked that
payment devices in the field were online, and logged success every hour. Two
devices went offline, one of them for two days, and no alert fired. The monitor
could match only two of six devices to a status feed. The other four it skipped
as not applicable, and a skipped device counted toward a clean run. The skip
was deliberate and the reasoning behind it was sound. The conclusion was wrong:
a device in that state could never raise an alert, so it was invisible for
good.
*Fix:* a target the monitor cannot evaluate is a finding with its own alert,
separate from the failure the monitor was built to catch. Ask of every branch
that does not alert: if this is permanent, who finds out?

The pattern is always the same: **the check answered a narrower question than
the one everybody thought it was answering.**

> **Practice:** for every gate you rely on, write the sentence "this could
> report success without having checked anything if ______." If you can't
> complete it, you haven't looked hard enough.

### A guard proven once is decoration

The migration check published here was demonstrated by hand on the day it was
written: fed one input it should pass and one it should catch. Then nothing
tripped it again, and nothing in the repository tripped the hook at all. A
guard that has silently stopped catching looks exactly like a guard with
nothing to catch, and "it worked when I wrote it" is the same sentence as "the
suite ran zero tests and passed."

Maziyar P. of OpenMed said it better than I had, replying in public to a
comment of mine: *a guard nobody has deliberately tripped is not a control, it
is decoration with an audit trail.* I had fallen into my own trap.

*Fix:* every guard ships with a standing pair of fixtures — one input it must
pass, one it must catch — run on the same cadence as the tests. Each fixture
that must be caught also names the message it expects, because a guard that
trips for the wrong reason has proven nothing about the check you aimed at.

`scripts/test-guards.sh` does this for the two guards published here. Run
against those guards as first published, it fails 14 of 59 fixtures. One of the
14 is a check that did not exist yet. The other 13 come down to four defects:

- The migration check read a column *named* `truncated` as a `TRUNCATE`
  statement.
- The same check judged backfills one line at a time, so an `INSERT` with its
  `SELECT` on the next line read as no row mutation. A real backfill had
  already gone through the original of that check this way. It had separate
  human approval, so nothing shipped unapproved — but the check had said
  nothing.
- The hook refused `git push origin main` and allowed `git push origin
  HEAD:main`.
- The hook refused `git push --force` and allowed `git push origin
  +HEAD:staging`, which is the same force push spelled without a flag.

All four had been public, and described as controls, since the first version.

> **Practice:** for every guard, ask when it was last shown to fail on purpose.
> If the answer is the day it was written, it has a fixture to write.

---

## 4. A control that fires on compliant work is worse than no control

This one cost the most to learn and generalizes the furthest.

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
that replaced an existing database function, since replacing behavior isn't
additive. But the codebase's convention used the same "create or replace"
syntax for brand-new functions too. The naive check hit roughly 43% of
migrations.
*Fix:* only flag a replacement when the object already exists upstream — an
actual replacement, not a stylistic coincidence.

And a third time, after comment-stripping had supposedly closed the question.
The destructive pattern matched `TRUNCATE` anywhere in executable SQL, so an
additive migration that created a table with a column *named* `truncated` was
flagged as destroying data.
*Fix:* match whole words. `TRUNCATE orders;` still trips; a column called
`truncated` does not.

**Anyone who has worked in a hospital knows this failure by its other name:
alarm fatigue.** Monitors that alarm constantly don't produce vigilance. They
produce staff who silence alarms reflexively, including the real one.

### The same failure from the other side: a gate that is always red

The high-risk tier runs the full end-to-end suite. Run for long enough against
a shared staging environment, that suite fails dozens of tests whatever you
changed: sessions expire partway through, rate limits bite. On a tree with no
changes at all it once failed 73 tests and passed 102. Running the tests one at
a time did not help.

A gate that fails every time cannot be passed and cannot be believed, so it
gets overridden every time — which is a gate that always passes, with extra
steps.

*Fix:* compare, don't assert. Run the identical suite against the commit
*before* the change, and judge only the failures the change introduced.

Two limits, both learned by getting them wrong:

- **The comparison can only clear a failure it can tell apart.** On a shared
  staging database, a schema-level fault fails on both sides — the change and
  the baseline are talking to the same database — so the comparison files it
  under existing decay. A fault like the audit trigger in principle 1 fails
  identically on both sides. When the failure is a database error, the
  baseline does not get a vote.
- **Check that the comparison compares.** The two failure lists have to be
  normalized before they are diffed. One normalizing step used a pattern its
  tool silently did not support, so it changed nothing, and the diff reported
  15 regressions that did not exist.

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
6. Writes to a production database that weren't authorized this session
7. Changes to secrets, environment variables, or credential configuration
8. Deleting or renaming files
9. Adding an external service that will handle user data
10. Anything touching payment processing or financial-document generation,
    outside a narrow pre-authorized scope (principle 6)
11. Deploying to production — always, including "just this one small fix"

`AGENTS.md` carries the same list in the form the agent reads. It folds items
2 and 3 into one.

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

**A refusal is an answer.** The list has a mirror image. When something outside
the agent refuses an action — a hook, a permission layer, branch protection —
the refusal is the decision. The agent does not go looking for an equivalent
command that gets through. In the original system the promotion procedure's own
push to production, a command the project's hook explicitly allows, was refused
by a permission layer sitting above the hook. The procedure's instruction for
that moment is written down: do not retry the push in other shapes, do not
rearrange anything to satisfy a pattern, take the documented fallback, and
where there is no fallback, hand the exact command to a human. A denied
production write is the human's to run, never the agent's to re-route.

---

## 6. Claimed exemptions require evidence, not assertion

Some categories of change are pre-authorized — in the original system, work
behind a specific feature flag could proceed without stopping, because the flag
guaranteed the code path was inert in production.

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
Asking for the citation is nearly free. Accepting the assertion is a bet on a
claim nobody checked.

It's also the control that transfers most cleanly to human organizations, where
"don't worry, legal already looked at it" is load-bearing far more often than
anyone is comfortable admitting.

### Exemptions expire

The paragraphs above are in the past tense because the exemption they describe
outlived its reason.

The flag existed to stage a rollout. Work behind it was safe to ship because,
with the flag off, the new path did nothing. Then the rollout finished. Every
customer had the flag on, and nothing behind it was inert any more.

The exemption was still written down. Worse, a claim against it would still
have been evidenced: the server-side check was still there, and the test
proving the path does nothing with the flag off still passed. The evidence
rule verifies that the gate exists. It does not verify that the reason for the
exemption is still true.

No check caught this. It was noticed in a review of the documentation.

*Rule:* an exemption is written with the condition that ends it, and that
condition is a fact someone can look up — here, "the flag is off for at least
one customer in production." When the condition stops holding, the exemption is
gone, whether or not anyone has edited the document.

---

## 7. The process may fix its own mechanics. It may not touch its own gates

The last step of every deploy is a retrospective. If the run was notable — a
check failed, a tripwire fired, a fallback path was taken, timing was well off
expectation — the agent writes up what happened, the root cause, and **the
exact amendment to the deploy process that would have prevented it**.

The first published version of this principle stopped there. Its title was "The
process may propose changes to itself. It may not make them." The agent wrote
its proposal into a log and was forbidden from editing the process at all.

That rule was too wide, and I changed it. Most of what a retrospective finds is
not a judgment call: a command in the procedure that no longer works, a failure
mode nobody had written down, a pattern that misses a case. Sending those
through a human added a delay and no review, because nobody deliberates over a
broken command.

So the rule now splits on one question: **does this change make any gate fire
less often?**

- **Mechanics — the agent applies them.** Fixing a broken command. Documenting
  a failure mode and how to triage it. Adding a check. Making an existing check
  stricter or more reliable. Each one lands as its own commit through the
  normal change process, is listed in the run's report, and is undone with an
  ordinary revert.
- **Gates — proposal only, exactly as before.** Anything that weakens, narrows,
  removes or bypasses a gate: tripwire paths and patterns, tier classification,
  adjudication rules, the escalation list, exemptions and allowlists, the hook,
  and the promotion mechanics themselves. The agent logs the full proposed edit
  and surfaces two lines. A human applies it or doesn't.

That's still separation of duties, in a file. The system that runs the gates is
not allowed to loosen the gates.

Three rules keep the split honest:

- **When unsure, it's a gate.**
- **Never mid-run.** The procedure that executed is the record of what the
  gates ran under. Changes to it land after cleanup, never during.
- **A good reason is not an exemption.** "This check fires on compliant work"
  is a correct diagnosis under principle 4, and the fix is still a gate change.
  It goes to a human *because* it is reasonable: carve-outs for false positives
  are how safety rails erode, each one sensible, the sum of them a gate that no
  longer fires. The whole-word fix in principle 4 went to a human for approval
  on exactly these grounds.

In the two months after the split, the deploy procedures took about sixty
self-applied changes.

One side effect to know about before you copy this. A self-applied fix is a
commit that touches only documentation, and a pipeline that skips
documentation-only commits will never produce a green run for it. That breaks
"assert the green run is for this commit" in a way that waiting cannot fix.
Step 2 of `skills/promote-to-production.md` has the answer.

Two smaller rules, unchanged:

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
the comment so nobody optimizes it away.

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

**Staging is contained only if its exits are.** Shipping to staging is
unsupervised on the theory that nothing there can reach anyone. In the original
system it could: staging held real email addresses and a mail credential that
delivered, and a test of a notification feature sent twelve real emails to
administrators at customer organizations before anyone noticed. The first guard
written afterward had a hole, because a second code path built its own mail
client and went around it. What closed it was a staging mail server that cannot
deliver at all, one client that every send must go through, and a test that
fails the build if a second one appears. Guard the door, not the callers.

**Deployed is not running.** Scheduled safety jobs ship switched off and are
switched on per environment as an operational step. In the codebase, a job that
is running and a job that was never switched on are the same file, so it is
easy to write "the nightly job catches this" about a job that has never run in
production. Nobody describes a job as protecting anything until its active flag
has been read from production.
The reverse also holds: a job that is off may be off on purpose, so find out
why before switching it on.

**No gate waits forever.** Reviewers that run as separate agents can stall.
Each one carries a deadline. When it expires, the review happens inline with
whatever has been reported. A stalled reviewer is a scheduling problem, never a
reason to skip the review.

**A fix is a new change.** When a gate finds something and the finding gets
fixed, the fix goes back through the gate. On two consecutive promotions the
fixes made in response to findings contained findings of their own.

**When your re-check disagrees with a delegate, suspect your own question
first.** The rule is to re-derive the riskiest claim in any all-clear that came
from a cheaper model. Once, one of the re-derived numbers came out four times
the delegate's, and the delegate was right: the re-check had used a wider
filter and swept in 2,588 rows that were out of scope by design. A disagreement is a
third hypothesis, not a verdict. Print the whole partition, not the filtered
count, before deciding who is wrong.

**The procedure is a file, so it can be out of date.** A deploy procedure kept
in the repository is versioned like everything else, which means a branch cut
before its last change executes the old one. Read the procedure from the shared
branch before step 0, not from wherever you happen to be standing.

**Don't change the mechanics and the gate in the same revision.** Promotion
moved from a pull request to a direct fast-forward only after the analysis gate
was in place, and as a separate revision from it. If a promotion goes wrong
after a change, you need to know which of the two did it.

---

## A second opinion on your own system

The rules are the easy part. The hard part is the two questions this document
can't answer for you: **which of your gates are lying to you**, and **which of
these controls are worth their false-positive rate in your system**. Both
depend on your codebase, your incidents, and what your team will actually
tolerate.

I can't answer either of those from here. Nobody can; that's kind of the
point. But they're good puzzles, and I like puzzles. Send me the gate you trust
least and we'll work out what it actually proves.

rick@genstate.com · [genstate.com](https://genstate.com/#ask)
