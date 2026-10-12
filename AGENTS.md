# The Delegation Contract

What the agent decides alone, and what it must never decide alone.

This is the document I'd hand an executive first, because it isn't really about
software. It's an employee handbook for a worker who is fast, capable,
tireless, and completely without instinct for which mistakes are expensive.

Put this in your repository where the agent reads it automatically at the start
of every session.

---

## Decides alone

- Writing, refactoring, and testing application code
- Choosing an implementation approach within an agreed design
- Adding tests, fixing failing tests, updating fixtures
- Documentation, comments, commit messages
- Shipping to **staging**, at any hour, without asking
- Running the full promotion procedure up to the point of its gate
- Reading production data (see the read/write asymmetry below)
- Ordinary dependency updates within existing major versions

Note what's on this list: **shipping to staging is unsupervised.** Everything
here is either reversible or contained. The point of a delegation contract
isn't to make the agent ask more often — it's to make the asks *rare and
meaningful*, so nobody learns to approve reflexively.

"Contained" is a property of staging you have to build, not one it has by
being called staging. In the original system, staging held real email addresses
and a mail credential that delivered, and a test of a notification feature sent
twelve real emails to administrators at customer organizations. Unsupervised
staging is safe when its outbound doors — email, text messages, payments, calls
to third parties — are *unable* to deliver. It is not safe because everyone
remembers not to use them.

## Must escalate — stop and ask

1. **Destructive schema changes.** Dropping a table, column, or constraint;
   changing a column's type; removing a not-null.
2. **Data-mutating migrations.** Backfills, `UPDATE` statements, replacing an
   existing function, view, trigger, or policy. These are *not* additive
   regardless of how the change is described.
3. **Writes to a production database** not explicitly authorized this session.
4. **Anything touching payment processing or financial-document generation**,
   outside a narrow pre-authorized scope (see the evidence rule below).
5. **The staged-rollout flag.** Flipping it in code, migration, or seed data;
   removing a gate that reads it. Rollout is an operational decision.
6. **Secrets, environment variables, credential configuration.**
7. **Deleting or renaming files.**
8. **Weakening any security control** — auth checks, rate limits, row-level
   security, content security policy.
9. **Adding an external service** that will handle user data.
10. **Deploying to production** — always, including "just this one small fix."

Plus the two that matter more than the enumerated list:

- **Two rules give conflicting guidance.**
- **Confidence is below roughly 70%.**

Those exist because no list is complete. The agent hitting the *edge* of the
list is precisely the moment you want to hear from it.

**A refusal is an answer.** When a hook, a permission layer, or branch
protection refuses an action, that is the decision. Do not retry it in another
shape, and do not look for an equivalent command that gets through. Take the
documented fallback. Where there is none, hand the exact command to a human. A
denied production write is the human's to run, never the agent's to re-route.

---

## The read/write asymmetry

Reading production is pre-authorized at all times. Writing to it is never
pre-authorized.

This turns out to matter more than it sounds. Diagnosis is most of the work,
and forcing an approval round-trip on every read makes the agent guess instead
of look — which is exactly the failure mode you were trying to prevent. Let it
look. Gate the changing.

Two conditions on the reads:

- **Personal data is converted at the query.** `SELECT email` becomes
  `SELECT email IS NOT NULL AS has_email`. Answer the question without pulling
  the data into a transcript that will outlive the question.
- **A function call is a write.** A `SELECT` that invokes a stored procedure
  can mutate the database regardless of the verb. Read-only means reading
  tables and views, not "starts with SELECT."

---

## Evidence, not assertion

Some work is pre-authorized as a category — in the original system, changes
behind a specific feature flag, because the flag made the code path inert in
production.

**Claiming that pre-authorization requires citing evidence.** Specifically: the
file and line of the server-side check that runs *before* the risky operation,
and the test proving the path does nothing when the flag is off. Cannot cite
both? The exemption is refused and the change escalates.

The flag's name appearing somewhere in a large diff is not evidence that the
new code path is gated. Grep-level compliance is not compliance.

**Every pre-authorization states the condition that ends it.** The flag
exemption above was safe while the flag was off somewhere in production. When
the rollout finished and every customer had it on, nothing behind the flag was
inert, and the exemption was still on the page. Write the ending condition as a
fact someone can look up. When it stops holding, the exemption is gone whether
or not anyone has edited this document.

This is the highest-leverage rule in the document. It generalizes to every
organization where "don't worry, legal already looked at it" carries weight it
hasn't earned.

---

## Definition of done

"Done" is a claim someone can check. Not "it compiles," not "it looks right,"
not "the demo worked."

For this project, done means: the build passes, the relevant tests pass, new
user-facing behavior has a test that would fail if the behavior regressed,
and — for anything touching a browser surface — a test that drives the page
like a user and fails loudly if the page misbehaves.

That last clause exists because a feature once shipped past every check and
rendered as a dead button: a browser security policy blocked one of its
components, with no error, no log entry, and no alarm. Nothing in the machinery
asks "did anyone actually see this work?" unless you build that question in.

Two more clauses, each added after the gap it closes was found:

- **A new database function or trigger has a test that executes it.** Creating
  one proves it was stored. The body is compiled the first time it runs.
- **A test that mocks the request counts as a test of the screen.** It is not
  evidence about the code behind the request. A feature is done when something
  has driven the real path end to end.

---

## Standing orders

- **Exploration before proposal.** Read the code before suggesting changes to
  it.
- **Smallest testable change.** Don't refactor, optimize, or improve outside
  the current goal.
- **Never suppress a check.** No skipping hooks, no disabling a failing test to
  get green, no adding an exception to silence a comparison tool. If a control
  is wrong, fix the control in the open.
- **Every guard ships with a case it must catch.** A new check, hook rule, or
  lint rule comes with two standing fixtures in the same change: one input it
  must pass and one it must catch. A guard nobody has tripped on purpose since
  the day it was written is not known to work.
- **An all-clear is a claim.** When a reviewer on a cheaper model reports
  nothing found on a money or security path, re-derive its single riskiest
  claim before accepting it. If your number disagrees with theirs, check your
  own filter first.
- **Every failure produces a rule.** An incident isn't closed when it's fixed.
  It's closed when there's an automated check that makes that class of failure
  impossible, and the rule is written where the next session will read it.

That last one is the entire system. Everything above is an instance of it.

---

## A note on tone

Write this document in the imperative, not the aspirational. "Escalate
destructive migrations" is a rule. "Be careful with destructive migrations" is
a mood.

The test for every line: **could a competent worker follow this without
guessing what you meant?** If not, it's a preference, and preferences don't
survive the moment they'd matter.
