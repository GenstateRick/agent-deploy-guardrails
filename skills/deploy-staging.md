# Deploy to staging

Staging deploys are unsupervised. That's the point — if shipping to staging
needs approval, nothing else in this system is affordable.

This procedure also covers the harder case: **several agents working in
parallel**, each in its own isolated working directory, whose work has to be
integrated without anyone's changes being lost.

---

## The prime directive

**Loss prevention beats speed.** Never drop a branch silently. Never force an
integration past a conflict. Never deploy from a stale local branch.

Speed matters, but a fast deploy that quietly discards someone's afternoon is
not fast. It's a rollback plus a re-do plus an apology.

---

## The consent marker

An agent that finishes work drops a marker file in its working directory:

```
.ready-for-staging
  branch: feature/invoice-export
  head:   a1b2c3d
  scope:  invoice CSV export + tests
  ts:     2026-07-24T14:02:00Z
```

**The marker is the consent signal.** Its presence means "ship this whenever
the next deploy runs, by whichever agent gets there." Its absence means don't,
full stop.

This is worth stating explicitly because the tempting alternative — collecting
anything that looks finished, or prompting a human about every unmarked branch
— is worse in both directions. Auto-collecting unmarked work ships things
nobody cleared. Prompting about it produces a stream of questions with no
safety benefit, and questions asked too often stop being read.

Unmarked work isn't lost. It was never offered.

---

## Step 1 — Pre-flight

```bash
git fetch origin --prune
git rev-parse origin/staging      # record the integration base
```

Fetch first. Every decision below is made against the *remote* staging branch,
not a local copy that may have drifted.

---

## Step 2 — Collect markers

Enumerate the working directories. Every one holding `.ready-for-staging` joins
the integration set, oldest timestamp first so the order is deterministic.

Print the full inventory — collected *and* skipped, with the reason. The
skipped list matters: it's how the operator notices that an agent forgot to
mark work ready.

---

## Step 3 — Integrate in a disposable, per-run directory

Never integrate inside anyone's working directory, and never in a local
staging branch.

```bash
RUN_TAG=$(date -u +%Y%m%d%H%M%S)-$$          # unique per run
INT="worktrees/_integration-$RUN_TAG"
git worktree add --detach "$INT" origin/staging
```

**The `RUN_TAG` is load-bearing.** A fixed path was used originally. Two
deploys ran concurrently, the second reused the first's directory, a branch
creation failed, the merge landed on a detached HEAD, and one run's work
stacked silently on top of the other's. Pushing it would have shipped the wrong
code.

The fix wasn't better sequencing or a lock — it was a unique path per run, so
collision is structurally impossible rather than merely unlikely.

**Inherit environment configuration explicitly:**

```bash
cp "$MAIN_REPO/.deploy-config.json" "$INT/.deploy-config.json" \
  || { echo "ABORT: could not inherit deploy config"; exit 1; }
```

Without this, the deploy tool infers its target from the directory name and
**silently creates a brand-new hosting project**, then builds and deploys into
it. Every command succeeds. A URL is printed. Staging is never updated and
nothing reports a problem. See `PRINCIPLES.md` #3 — this is the purest example
of a verification that lies, because there's no verification at all, just a
chain of commands that each did exactly what they were asked.

---

## Step 4 — Merge each branch · halt on conflict

```bash
git merge --no-ff --no-edit "origin/$B" -m "integrate $B — <scope>"
```

- **Clean** → next branch.
- **Conflict** → `git merge --abort` and **stop**. Report which branches
  integrated, the conflicting one with both sides of the diff, and which
  weren't attempted. Ask a human.

**Never auto-resolve a conflict between two agents' work.** A conflict means
two workstreams made incompatible assumptions about the same code. That's a
design question, not a merge problem — and resolving it by picking a side ships
a decision nobody actually made.

---

## Step 5 — Assert the shipped set, then push

```bash
git diff --stat origin/staging..HEAD
```

This must contain **exactly** the files from the collected branches. Anything
unexpected aborts the push.

This check is the one that caught the concurrency incident in step 3 before it
reached anyone. A diff assertion right before the irreversible step is cheap
insurance, and it's the last place a surprise can be caught for free.

```bash
git push origin HEAD:staging      # fast-forward only
```

Rejected as non-fast-forward means someone pushed mid-deploy. Re-fetch and
re-run from step 3 — the whole procedure is idempotent, because the markers
still drive collection.

---

## Step 6 — Wait for CI, and gate on the *conclusion*

```bash
# Find the run for OUR commit. Never take "the most recent run" — it may be
# from an earlier push and will never match.
RUN_ID=$(<query runs, filtering on headSha == our commit>)

<watch the run> || true          # watch for progress only

CONCLUSION=$(<query that run's conclusion>)
[ "$CONCLUSION" = "success" ] || { echo "CI: $CONCLUSION — triage"; exit 1; }
```

**Never gate on the watch command's exit code.** Pipe it into anything — even
`tail` — and you get the *pipeline's* exit status, which is the last stage's.
A failing run reads as green and the deploy continues. That happened; the
subsequent steps ran against a red build.

Gate on the literal string `success` from an explicit query. Nothing else.

### When CI doesn't run at all

If your pipeline skips certain paths (documentation, for example), a
docs-only push produces **no run**, and waiting for one is waiting forever.

Classify rather than poll: if every changed file matches the skip patterns,
that's success by design. If any file doesn't, CI should have fired and didn't
— that's a genuine failure worth alerting on, not a timeout to shrug at.

> **Keep in sync:** the skip patterns are now written in two places — your
> pipeline config and this procedure. They must match. When they drift you get
> either a spurious abort or a false success. If your tooling lets you read the
> patterns from one source, do that instead.

---

## Step 7 — Clear consumed markers

Remove `.ready-for-staging` only from branches that **both** reached the remote
branch **and** passed CI. If CI failed, leave the markers — a re-run must
re-collect the work.

---

## Step 8 — Tear down and report

Remove the per-run integration directory by its exact path. **Never glob** a
shared prefix — that deletes a concurrent run's directory mid-flight.

Report: what shipped and its scope; what was skipped and why; any conflict and
how it resolved; migrations applied; the staging URL's status; the CI
conclusion; wall time.

---

## Step 9 — Retrospective · suggest-only

Only if notable: a conflict halted the run, the push was rejected, the build
failed, a rollback was needed, markers couldn't be cleared, or timing was well
off expectation. Otherwise write nothing.

If notable, log the proposed amendment and surface two lines. **This step never
edits this file.** (`PRINCIPLES.md` #7.)

---

## Rules

- Marked work is either shipped or explicitly halted. Never silently dropped.
- Halt on conflict. Never auto-resolve between two agents.
- The marker is the only collection signal. Branch names are not trusted.
- Integrate only in the disposable per-run directory, off a fresh remote
  staging.
- Never force-push. Never bypass commit hooks.
- Gate on the CI conclusion string, never a watch command's exit code.
