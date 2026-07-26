# Adopting this

You don't need all of it. If you implement three things and nothing else,
implement these — in this order.

---

## 1. Write down what each gate does not prove

**The highest-value item here, and it changes nothing about your code.**

Go through your existing pipeline. For every job, write one sentence stating
what it does *not* prove, as a comment above the job.

You will not get through this exercise without finding at least one gate that
everybody believes is stronger than it is. That discovery is the deliverable.
Common findings:

- The smoke test only checks that the homepage loads.
- The migration check only proves the SQL parses or applies — not that it's
  safe.
- Nothing anywhere exercises the flow that actually makes you money.
- The staging environment differs from production in a way that makes an entire
  class of bug undetectable before release.

You don't have to fix them today. Writing them down changes how the team reads
a green pipeline, which is most of the benefit and available immediately.

---

## 2. Require evidence for claimed exemptions

**One paragraph in your review policy. Disproportionate return.**

Whenever a change claims it's safe because of an existing control — a feature
flag, a permission check, an upstream validation — the claim must cite the file
and line where that control runs, plus a test proving the guarded path is inert
when the control is off.

Can't cite both? The claim is refused and the change gets full review.

It closes the largest hole in any review process, human or machine: the
plausible assurance nobody checks. It's also the rule that ports furthest
outside engineering.

---

## 3. Tier your scrutiny

**This is what makes everything else sustainable.**

Pick your tripwires — the paths and content patterns that mean "this could
cost real money." Everything else gets standard review; tripwire matches get
the full battery.

Do it in this order:

1. **List the paths** where money, credentials, authentication, or customer
   records live.
2. **Add content patterns**, because money moves through files nobody thought
   to list. Match against added lines only.
3. **Make trivial changes actually trivial.** If a documentation edit runs the
   same gauntlet as a schema migration, people will batch changes to avoid the
   overhead — and batching is how a risky change rides along unnoticed inside
   a large diff.

The last point is the one teams get wrong. Making the cheap path genuinely
cheap is a *safety* measure, not a convenience.

---

## Then, in rough order of value

4. **`scripts/check-migration-safety.sh`** — if you have a database, this is
   the single most valuable script here. Run it before every promotion.
   Measure its false-positive rate in the first month; tune until it's near
   zero, because a tripwire that fires on normal work trains people to ignore
   it (`PRINCIPLES.md` #4).

5. **The escalation list** (`AGENTS.md`) — enumerate what requires a human.
   Include the two catch-alls: rules in conflict, and confidence below
   threshold.

6. **Assert the green run matches the commit you're shipping.** A three-line
   check that closes a genuinely dangerous hole.

7. **Capture a rollback target before you merge**, not while you're on fire.

8. **The retrospective that can propose but not edit.** Cheap, and it's what
   makes the system improve without letting it improve itself unsupervised.

---

## How to know it's working

- Approvals become **rare and considered** rather than frequent and reflexive.
  If your team is approving several tripwires a week, the tripwires are
  mistuned — not the team.
- Deploying gets **boring**. That's the goal, and it's measurable: ask people
  whether they'd rather ship on a Friday afternoon than not.
- Incidents produce **checks**, not documents. A retrospective whose only
  output is a page nobody reads has not closed the incident.

## How to know it's failing

- Someone adds an exception to make a comparison tool quiet.
- A tripwire is disabled "temporarily."
- The allowlist of documented exceptions has entries with no clearing
  condition, and nobody remembers who added them.
- A green pipeline is quoted as evidence in a conversation about whether
  something is safe.

That last one is the canary. The whole system exists to keep those two
sentences separate.

---

## If you get stuck partway

The controls above are ordered by value in the system they came from. Yours
will order differently, and the ordering matters more than the list — adopting
these in the wrong sequence is how people end up with a tripwire that fires on
half their migrations and a team that has learned to ignore it.

If you're partway in and stuck, ask. The ordering is much easier to work out
against a real codebase than in the abstract, and it's the kind of problem I
enjoy.

rick@genstate.com · [genstate.com](https://genstate.com/#ask)
