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

## Must escalate — stop and ask

1. **Destructive schema changes.** Dropping a table, column, or constraint;
   changing a column's type; removing a not-null.
2. **Data-mutating migrations.** Backfills, `UPDATE` statements, replacing an
   existing function, view, trigger, or policy. These are *not* additive
   regardless of how the change is described.
3. **Writes to a production database** not explicitly authorised this session.
4. **Anything touching payment processing or financial-document generation**,
   outside a narrow pre-authorised scope (see the evidence rule below).
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

---

## The read/write asymmetry

Reading production is pre-authorised at all times. Writing to it is never
pre-authorised.

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

Some work is pre-authorised as a category — in the original system, changes
behind a specific feature flag, because the flag makes the code path inert in
production.

**Claiming that pre-authorisation requires citing evidence.** Specifically: the
file and line of the server-side check that runs *before* the risky operation,
and the test proving the path does nothing when the flag is off. Cannot cite
both? The exemption is refused and the change escalates.

The flag's name appearing somewhere in a large diff is not evidence that the
new code path is gated. Grep-level compliance is not compliance.

This is the highest-leverage rule in the document. It generalises to every
organisation where "don't worry, legal already looked at it" carries weight it
hasn't earned.

---

## Definition of done

"Done" is a claim someone can check. Not "it compiles," not "it looks right,"
not "the demo worked."

For this project, done means: the build passes, the relevant tests pass, new
user-facing behaviour has a test that would fail if the behaviour regressed,
and — for anything touching a browser surface — a test that drives the page
like a user and fails loudly if the page misbehaves.

That last clause exists because a feature once shipped past every check and
rendered as a dead button: a browser security policy blocked one of its
components, with no error, no log entry, and no alarm. Nothing in the machinery
asks "did anyone actually see this work?" unless you build that question in.

---

## Standing orders

- **Exploration before proposal.** Read the code before suggesting changes to
  it.
- **Smallest testable change.** Don't refactor, optimise, or improve outside
  the current goal.
- **Never suppress a check.** No skipping hooks, no disabling a failing test to
  get green, no adding an exception to silence a comparison tool. If a control
  is wrong, fix the control in the open.
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
