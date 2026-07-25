# Agent Deploy Guardrails

A working template for letting an AI coding agent deploy to production without
it becoming the scariest part of your week.

Everything published about AI coding agents is about getting them to *write*
code. This is about the question you ask second: how do you let it **ship**?

The honest answer isn't "review everything it writes." That doesn't survive
contact with three deploys a day. It's a graduated control system where the
amount of scrutiny applied to a change is computed from what the change
actually touches — cheap when it's a documentation edit, exhaustive when it
moves money.

---

## You don't have to read this

It's written to be handed to a coding agent, not studied. The rules are
written as rules — testable, specific, and free of the hedging that makes
most engineering documentation unusable by a machine.

Point your agent at this repository and ask it something like:

> Read this repo. Compare it against how you currently ship changes in my
> project. What would you adopt, what doesn't apply, and what would you
> need from me to put the rest in place?

Then read what it tells you. That conversation is more useful than anything
you'd get from reading these files yourself, because it's grounded in your
codebase rather than mine.

If you'd rather read it as a human, start with
[`PRINCIPLES.md`](PRINCIPLES.md) — seven rules, each with the incident that
produced it.

## Where this came from

I run a payments platform. An AI agent writes and maintains the software; in a
recent 90-day window it shipped to production just under 300 times, and every
one of those releases was gated by more than 2,700 automated tests.

Early on I tried to save money. Deploys looked mechanical to me — a checklist,
some automation, a green light at the end — so I proposed running them on a
cheaper, faster model and saving the expensive one for writing code.

The agent argued back. It said deployment was exactly where the capable model
belonged, because of everything that can go wrong in the gaps *between* the
automated checks.

I took the advice, and two incidents proved it right. Not because the code was
bad — in both cases the code was fine. **The verification lied.** A test suite
reported success having run zero tests. A feature shipped, passed every check,
and rendered as a dead button because a browser security policy silently
blocked one of its components. Nothing in either pipeline was equipped to
notice, because every gate reported exactly what it was designed to report.

What's in this repository is what got built in response. It is the reason I can
now say, plainly, that I trust the agent not to put anything into production
that hasn't been thoroughly and automatically tested first.

That trust isn't a feeling about the model. It's this system.

---

## The one-sentence version

**A green pipeline is a statement about the checks that ran. It is not a
statement about whether your business still works.** Every control here exists
to narrow the distance between those two things.

---

## What's in the box

| File | What it is |
|---|---|
| [`PRINCIPLES.md`](PRINCIPLES.md) | Seven rules, each with the incident that produced it. **Start here.** |
| [`AGENTS.md`](AGENTS.md) | The delegation contract — what the agent decides alone, what it must escalate |
| [`skills/promote-to-production.md`](skills/promote-to-production.md) | The promotion gate. The centerpiece |
| [`skills/deploy-staging.md`](skills/deploy-staging.md) | Shipping to staging, including multi-agent integration |
| [`skills/hotfix.md`](skills/hotfix.md) | The emergency path, and the limits that keep it honest |
| [`scripts/check-migration-safety.sh`](scripts/check-migration-safety.sh) | Scripted tripwires for schema changes |
| [`ci/pipeline.yml`](ci/pipeline.yml) | A CI pipeline annotated with what each job does *not* prove |
| [`hooks/pre-tool-use.sh`](hooks/pre-tool-use.sh) | Hard blocks enforced outside the agent's judgment |
| [`ADOPTING.md`](ADOPTING.md) | The three controls to implement first if you do nothing else |

## Stack assumptions (and how to escape them)

The examples are a TypeScript web app on a managed host with a Postgres
database and GitHub Actions, because that's what the original runs on. Every
control is described stack-independently first and shown concretely second. If
you're on Django and AWS, the tier logic, the tripwire patterns, the escalation
list, and the evidence rule all port directly — only the commands change.

Placeholder names used throughout: `$APP` for your project, `$HOST` for your
deployment CLI, `payments_v2_enabled` for a feature flag gating a risky
migration, `next_invoice_number` for a sequence that must never gap.

---

## What this is not

- **Not a way to remove humans from deploys.** It's a way to make the human's
  attention land where it's actually needed. The escalation list is the point.
- **Not a security product.** It reduces the odds of shipping a broken change.
  It does not replace code review, threat modelling, or an audit.
- **Not automatic.** Every control here exists because something went wrong
  first. Yours will be shaped by your own incidents. Copy the structure, then
  let your failures write the specifics.

## The uncomfortable part

Most of these controls were written *after* the thing they prevent had already
happened at least once. That's not a failure of planning — it's how operational
systems actually mature. The discipline that matters isn't predicting failures.
It's the rule that **every incident produces a written check before the
incident is considered closed**, so that the same class of mistake cannot
happen a second time.

That rule is the whole system. Everything else is an instance of it.

---

MIT licensed. Contributions welcome — especially incident reports that justify
a control this template is missing.
