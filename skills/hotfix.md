# Hotfix to production

The emergency path: a small, urgent, code-only fix straight to production,
skipping staging.

**Note that this procedure has *more* restrictions than the normal one, not
fewer.** That inversion is deliberate and it's the most important thing on this
page. The fast path is where discipline is most likely to be abandoned and
least affordable to lose — the reason you're rushing is precisely the reason
your judgment is degraded.

---

## Prerequisites

- A human explicitly asked for a hotfix, with a description of the fix. No
  description, no hotfix.
- Working tree clean.
- The fix is **code only**. If it needs a schema migration, stop — this path
  skips the migration dry run entirely. Use the normal promotion procedure.
- The fix does not touch payments, financial-document numbering, auth, or
  row-level security. These need the full gate.

---

## Step 0 — Set the flag

```bash
touch "$PROJECT_DIR/.hotfix-active"
```

This marker tells the pre-tool-use hook to permit committing and pushing
directly to the production branch — normally refused outright.

**It is a narrow bypass, not a master key.** It does *not* unlock production
database writes or manual production deploys; those stay blocked. Graduated
bypass is the point: an emergency justifies skipping the staging round trip. It
does not justify skipping everything.

**Remove it in step 7, on every exit path.** A flag left on disk is a silently
disabled safety system.

---

## Step 1 — Branch from production

```bash
git fetch origin main
git checkout -b hotfix/<short-slug> origin/main
```

Branch from production, not from staging. Staging contains unshipped work that
has no business riding along in an emergency.

---

## Step 2 — Make the fix. Stay narrow

One issue. If the fix grows past roughly 30 lines or touches multiple
subsystems, **stop** — the scope has outgrown the path. Remove the flag and use
the normal procedure.

If it turns out to need a migration, stop for the same reason.

---

## Step 3 — Scripted tripwire check · not a judgment call

The "no payments, documents, auth, or RLS" prerequisite is enforced by script,
**not by your classification of what the fix really is**:

```bash
git diff origin/main --name-only | grep -E \
  'migrations/|src/lib/payments/|src/app/api/webhooks/|invoice|receipt|src/middleware|src/lib/auth/|^\.env|hooks/' \
  && echo "ABORT: touches a tripwire path — no staging skip allowed here"

git diff origin/main | grep -E \
  '^\+.*(<payment SDK>\.|application_fee|transfer_data|next_invoice_number|CREATE POLICY|DROP POLICY|createAdminClient)' \
  && echo "ABORT: adds money-movement, document-numbering, or RLS code"
```

Any match aborts the hotfix. Route it through the full procedure instead.

**"It's just display copy that happens to live near the payment flow" does not
override a path match.** The path list is the authority, not the description of
the change. This sentence is in the file because that exact argument is
persuasive, always available, and wrong often enough to matter. Someone in a
hurry, asked to classify their own change, will classify it as low-risk —
that's not dishonesty, it's what urgency does to judgment.

---

## Step 4 — Local build gate

```bash
npm run build   # or your equivalent
```

Must pass. Never push a broken build to production. This is a cheap
pre-check — the full suite still runs in CI on the push.

---

## Step 5 — Commit and merge

Stage **named files**. Never `git add -A`. Review the staged diff before
committing — an emergency is exactly when a stray file rides along.

```bash
git checkout main
git pull origin main
git merge --no-ff hotfix/<short-slug>
git push origin main
```

Use `--no-ff` so the hotfix stays legible in history. If `git pull` shows
production moved since step 1, rebase onto it and re-run the build gate.

---

## Step 6 — Watch production CI

The push triggers the production pipeline. If the deploy job fails, retry it —
do **not** reach for a manual production deploy command. That is blocked from
the agent by design; a human runs it if the pipeline itself is broken.

If the smoke check fails, roll back immediately, then diagnose.

---

## Step 7 — Remove the flag · ALWAYS

```bash
rm -f "$PROJECT_DIR/.hotfix-active"
```

Every exit path: success, CI failure, scope growth, migration discovered, build
failure, abort at step 3. If it can't be removed, say so prominently — safety
is disabled until it is.

---

## Step 8 — Backport to staging · MANDATORY

```bash
git checkout staging
git pull origin staging
git merge main
git push origin staging
```

**Without this, the next routine promotion silently reverts the hotfix.**
Staging still holds the broken version of the file, and promoting staging
carries it straight over the fix. The urgent problem returns, days later, with
no obvious cause and everyone certain it was fixed.

The hotfix is not finished until this push lands. Not "should be done soon" —
not finished.

If the merge conflicts, stop and get a human. Staging has divergent edits to
the same file and guessing is how you ship the wrong resolution.

---

## Rules

- Code-only. Never migrations.
- The step 3 tripwire check is mandatory and scripted. A match aborts,
  regardless of how the change is described.
- Never skip the build gate.
- Never `git add -A`. Never force-push. Never bypass commit hooks.
- The flag is created in step 0 and removed in step 7 on every path.
- The backport in step 8 is not optional.
- Anything ambiguous: stop and ask.

## When not to use this

- **Any migration.** Full procedure.
- **Payments, document numbering, auth, RLS.** Full procedure.
- **"While I'm here" cleanup.** Stay narrow — that's the whole bargain.
- **The pipeline itself is broken.** A human runs the manual deploy. The agent
  is blocked from it, deliberately, precisely for this moment.
