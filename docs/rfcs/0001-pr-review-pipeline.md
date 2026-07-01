# RFC 0001 — A layered pre-merge review pipeline (stop the Bugbot trickle)

> **Status: DRAFT** — circulated for discussion; not yet approved. Everything here
> is open to change. Owner: @saadqbal. Last updated: 2026-07-01.
>
> **Home / scope.** This doc lives in `tracebloc/client` (our ops/deploy repo) but
> its scope is **every tracebloc repo**. If we'd rather it live org-wide, it can
> move to `tracebloc/.github`; the per-repo numbering here follows the `cli` repo's
> `docs/rfcs/` precedent.
>
> **Problem in one line:** every develop→staging/main PR gets picked apart by
> Cursor Bugbot **one issue at a time**, over many push/fix cycles — slow, and the
> issues land late (at the promotion gate) instead of early (per feature).

## 0. Decisions to settle in this review

These are the calls the team needs to make. The rest of the doc assumes the
recommended column; push back on any of them in the thread.

| # | Decision | Recommendation |
|---|---|---|
| D1 | **Is Bugbot our comprehensive review gate, or a precision backstop?** | **Backstop.** Bugbot averages ~0.7 findings/review by design (§3); comprehensiveness must come from deterministic tools + a recall-tuned pass, not from Bugbot. |
| D2 | **Where does review happen — at promotion, or per feature?** | **Per feature.** Gate + review the small `feature→develop` PRs so the `develop→main` promotion PR is clean by construction (§6.2, §6.3). |
| D3 | **Do we make deterministic linters *required* status checks?** | **Yes**, everywhere, with `fail-fast: false` so one CI run reports *all* findings at once (§6.4). This is the single biggest fix for "one-by-one". |
| D4 | **Do we adopt a recall-tuned AI pass (Claude Code) alongside Bugbot?** | **Yes, optional per repo** — it posts every finding in one comment, which is what "all at once" actually requires (§6.6). |
| D5 | **Do we gate merges on the `Cursor Bugbot` status check?** | **Only after** the deterministic layer lands — otherwise we've just moved the trickle into a blocking gate. |

## 1. Summary

Replace "open a big promotion PR and let Bugbot drip-feed findings across a dozen
push cycles" with a **layered pre-merge funnel** that catches each class of issue
at the earliest point where a tool can report *all* of it at once:

```
Layer 0  laptop (pre-push)        Layer 1  feature → develop PR       Layer 2  develop → staging/main
────────────────────────         ──────────────────────────         ────────────────────────────────
pre-commit (ruff, black,     →    Required CI gates, fail-fast:  →    Promotion PR is a formality:
 shellcheck, mypy, gitlint)       false → EVERY finding in one        small/no new diff, so Bugbot +
+ optional one-shot AI review     run: ruff · mypy · bandit ·         the recall pass find ~nothing.
 (/review-bugbot or               shellcheck · helm lint · tests      The `gate / gate` FR check is
 /code-review) before pushing     + Bugbot(High) on a SMALL diff       orthogonal (kanban, not code).
```

The reframe that makes this work: **Bugbot is tuned for precision, not recall** —
it is architecturally a ~1-finding-per-pass backstop (§3), so we stop asking it to
be the exhaustive gate and let deterministic tooling (which reports 100% of
findings, every run) plus one recall-oriented AI pass do the heavy lifting, early,
on small diffs.

## 2. Motivation

Today the review load lands at the **promotion PR** (`develop`→`staging`/`main`),
and it lands as a **trickle**:

- You open the promotion PR. Bugbot posts ~1 finding.
- You fix it, push. Bugbot re-reviews the *whole* diff and posts a *different* ~1
  finding.
- Repeat. Each cycle is a full re-review of a large accumulated diff.

Two things make this painful, and both are structural, not accidental:

1. **Almost nothing deterministic gates the PR** (§4), so mechanical issues
   (style, imports, types, unquoted shell vars, un-nil-guarded Helm values,
   security lint) are left for a *human or Bugbot* to notice one at a time —
   instead of a linter dumping the full list in one CI run.
2. **Review is concentrated at promotion time**, on the largest possible diff,
   where Bugbot's stochastic re-review is slowest to converge.

The cost is real: a promotion PR can burn a day of push→wait→fix→push cycles that
a single `ruff`/`mypy`/`shellcheck` run plus one recall-tuned AI pass would have
surfaced *in full, on the original feature PR*.

## 3. The core reframe — Bugbot is a precision backstop, not a comprehensive gate

This is the crux, and it's counter-intuitive, so it's stated up front.

Per Cursor's own docs and engineering posts, **Bugbot is deliberately tuned for
precision over recall**:

- It averages **~0.7 findings per review on Default effort, ~0.95 on High** —
  these are design outputs, not configurable floors. There is **no setting that
  makes it report "everything at once"** and no documented per-review cap to lift.
- It **re-reviews the full diff on every push** and is **stochastic** — the agent
  investigates suspicious patterns and surfaces a *different* ~1 finding per run.
  That *is* the "one-by-one" behaviour. It cannot be turned off; it is what Bugbot
  is.
- Cursor optimises for **resolution rate** (did the dev fix what it flagged),
  because a reviewer that fires 50 mostly-wrong comments gets muted in a week.

**Implication:** asking Bugbot to be our exhaustive gate is fighting its design.
The fix is to change *what we ask of each tool*:

| Layer | Tool | Tuned for | Reports |
|---|---|---|---|
| Deterministic | ruff, mypy, bandit, shellcheck, helm lint, golangci-lint, eslint | **completeness** | 100% of findings, every run, in one list |
| Recall AI (optional) | Claude Code review / `/code-review` | **coverage** | all findings in one comment/pass |
| Precision AI | **Bugbot** | **precision** | ~1 high-confidence finding/pass — a backstop |

Everything below follows from this: move each issue class to the *leftmost* tool
that can catch it completely.

The one thing we *can* do to make Bugbot's single pass land better — run it once,
early, on a small diff — is in §6.5.

## 4. What exists today (grounded audit, 2026-07-01)

A read-only sweep of the repos under `/Volumes/VPPD/projects/tracebloc`:

| Repo | `.cursor/BUGBOT.md` | Deterministic lint on PR | Required checks (branch protection) | Pre-commit |
|---|---|---|---|---|
| **client** | ✗ | shellcheck + `helm lint --strict` + kubeconform run, **not gated** | none visible via API¹ | ✗ |
| **client-runtime** | ✗ | **black only** (+ pytest, cov ≥50%) | `pytest` on develop; `gate / gate` + `pytest` on staging/master | ✓ (black, gitlint, json/xml, debug-stmts) |
| **tracebloc-engine** | ✗ | pytest only (cov) | `test (3.11)` on develop; `gate / gate` + `test (3.11)` on staging/master | ✗ |
| **backend** | ✗ | black (in `lint.yml`, **not required**) + Bandit-in-pytest (cov ≥60%) | `Django + Bandit plugin` on develop; `gate / gate` + that on staging/master | ✓ |
| **frontend-app** | ✗ | **no ESLint in CI**; typecheck + vitest + cypress run | `gate / gate` only on staging/main (unit/e2e **not** required) | ✗ |
| **cli** | ✗ | ad-hoc `gofmt`/`errcheck`/`ineffassign`/`misspell`; `.golangci.yml` present but **unused** | none visible via API¹ | ✗ |
| **data-ingestors** | ✗ | pytest e2e only | unknown | ✗ |

¹ `client` and `cli` return 404 for `.../branches/*/protection` — consistent with
our known pattern that **ruleset-based protection is invisible to the classic
protection API** (see the `.github` main-ruleset note). Configuring/reading them
needs a `project`/`repo`-scoped `gh` token — a verify step (§9).

**Gaps that directly cause the trickle:**

- **No `.cursor/BUGBOT.md` anywhere** → Bugbot reviews every repo with zero project
  context (doesn't know our shell-safety rules, Helm nil-guard rule, the
  `resource-policy: keep` trap, the anti-leak `values*.yaml` patterns, etc.).
- **No `ruff`/`mypy` anywhere; `bandit` only inside backend's pytest.** The entire
  Python style/type/security class is unguarded → left to humans/Bugbot.
- **`client` and `cli` gate nothing** — good checks exist and simply don't block.
- **`gate / gate` is the FR (feature-readiness) kanban gate, not code quality** —
  it verifies each contained PR's kanban status, so it does nothing for this
  problem. Don't confuse it with a review gate.

## 5. Goals / Non-goals

**Goals**
- **All findings of a given class arrive at once**, in one CI run, not drip-fed.
- **Issues caught early** — on the small `feature→develop` PR (and on the laptop),
  not at the `develop→main` promotion gate.
- A **consistent policy** across repos, templated from one pilot.
- **Cheaper, faster Bugbot** — it reviews small diffs with context, as a backstop.
- Keep the existing FR/`gate` kanban flow untouched (orthogonal).

**Non-goals**
- Replacing Bugbot (it stays, as the precision backstop).
- Making Bugbot "report everything" — impossible by design (§3); we stop trying.
- Reworking the branch model (`develop`→`staging`/`main`) — unchanged.
- 100% type coverage day one — `mypy` starts lenient and ratchets.

## 6. Proposed design — the layered funnel

### 6.1 Layer 0 — the laptop (earliest possible)

Roll `.pre-commit-config.yaml` out to **all** repos (only `client-runtime` +
`backend` have it). Standard hook set:

- Python: `ruff` (lint + import order), `ruff format` (or keep `black`), `mypy`
  (lenient), `bandit`.
- `client`: `shellcheck`, `helm lint`, `yamllint`.
- All: `gitlint`, trailing-whitespace, end-of-file, large-file guard, a
  **secret scanner** (`gitleaks` / `detect-secrets`).

Plus an *optional* one-shot AI pass before pushing — either Cursor's
`/review-bugbot` (§6.5) or Claude Code's `/code-review` on the diff. This is where
"catch everything before anyone sees it" actually happens.

### 6.2 Layer 1 — the `feature → develop` PR (the real fix)

**Require PRs into `develop`** (verify we don't push straight to it — §9), and make
`develop` PRs run the full deterministic gate set **as required checks**. On a
small feature diff:

- deterministic tools report their complete list in one run, and
- Bugbot (High effort, with `.cursor/BUGBOT.md` context) reviews a *small* diff, so
  its ~1 finding is meaningful and converges fast.

By the time these features are batched into a promotion PR, they've already been
gated and reviewed. **This is D2, and it's the biggest structural lever.**

### 6.3 Layer 2 — the `develop → staging/main` promotion PR

Should be **clean by construction**. Keep the same deterministic gates as a
backstop; keep Bugbot on. The `gate / gate` FR check continues to do its (separate)
kanban job. If Bugbot still finds things here regularly after Layers 0–1 are in
place, that's a signal Layer 1 isn't actually running on the feature PRs (§9).

### 6.4 Deterministic tooling per repo (the "all at once" engine)

Add these as **separate CI jobs with `fail-fast: false`** so a failing `ruff`
never hides `mypy`'s output — one PR, one CI run, every finding:

| Repo(s) | Add | Notes |
|---|---|---|
| **Python** (`client-runtime`, `tracebloc-engine`, `backend`, `data-ingestors`) | `ruff check`, `ruff format --check` (or keep black), `mypy` (lenient→ratchet), standalone `bandit` | `ruff` replaces flake8/isort/pylint; near-instant. Promote backend's in-pytest Bandit to a standalone gate everywhere. |
| **client** (Helm/shell) | make existing `helm-ci` + `installer-tests` **required**; add `yamllint`, `hadolint` (ingestor Dockerfile), `kube-linter`/`checkov` on rendered manifests | keep shellcheck/helm-unittest/kubeconform that already run |
| **cli** (Go) | switch to `golangci-lint run` (uses the existing `.golangci.yml`), add `gosec`; add branch protection | one bundled linter reports all at once vs today's ad-hoc tools |
| **frontend-app** | finish ESLint flat-config migration; gate `eslint` + `tsc --noEmit`; consider `knip` | make vitest/cypress required once stable |

Then **make them required status checks** on `develop` (and the promotion branches)
in each repo's ruleset.

### 6.5 Bugbot configuration (make its one pass land early, with context)

1. **Add `.cursor/BUGBOT.md` to every repo** — highest-value Bugbot change. It is
   hierarchical/monorepo-aware (root file always applies; per-subdir files apply
   when files under them change). Draft for `client` in Appendix A.
2. **Adopt the pre-PR pass:** run Cursor `/review-bugbot` against the base branch
   **before opening the PR**. Bugbot's patch-ID dedup then makes the GitHub PR skip
   the automatic re-review ("already reviewed this diff") — **one comprehensive
   pass total** instead of a staggered sequence.
3. **Effort = High** (or a Custom rule scoped to `main`/promotion PRs to control
   cost) — modestly higher recall.
4. **Keep incremental-review mode OFF for promotion PRs** — it reviews only the
   delta, which makes a big accumulated diff *worse*.
5. **Learned rules + backfill**, and `@cursor remember …` on false positives, so it
   self-calibrates to our codebase.
6. **(D5, later) Gate merges on the `Cursor Bugbot` status check** with
   `fail-on-unresolved` — *only after* the deterministic layer lands, or we've just
   turned the trickle into a blocking gate.

### 6.6 The recall-tuned AI pass (optional, recommended — this is "all at once")

Because Bugbot won't dump everything (§3), pair it with an AI reviewer tuned for
**coverage**, which posts all findings in **one** comment/pass:

- **Claude Code GitHub Action** (`anthropics/claude-code-action`) as a PR reviewer, or
- the local **`/code-review`** / **`/security-review`** skills run on the diff
  before pushing (Layer 0).

This is the piece that actually delivers "catch everything at once" for the
judgment-level issues; Bugbot then confirms/adds high-precision catches on top.

## 7. Security considerations

- **Shift security lint left:** standalone `bandit` (Python) and `gosec` (Go) as
  required gates; `kube-linter`/`checkov` on rendered Helm manifests catches
  insecure `securityContext`, missing resource limits, etc. before promotion.
- **Secret scanning in pre-commit + CI** (`gitleaks`/`detect-secrets`) — reinforces
  the `values*.yaml` anti-leak patterns and the "no secrets in PRs" checklist.
- **`.cursor/BUGBOT.md` encodes our security rules** so Bugbot flags them
  deterministically (curl|bash input validation, `resource-policy: keep` stored-
  manifest trap, unguarded new `values.yaml` keys — Appendix A).
- **Bugbot billing note:** reviews are usage-based since June 2026 (~$1–4/large
  review). Scoping High effort to promotion PRs and shrinking diffs via Layer 1
  keeps spend down.
- **CI supply chain:** pin third-party actions (`golangci-lint`, `kube-linter`,
  Claude action) to commit SHAs, matching the `client` installer's hardening ethos.

## 8. Rollout — pilot then template

- **Phase 0 (no repo changes):** turn on the Cursor dashboard settings — High
  effort, learned rules + backfill, incremental-off default. Start doing the pre-PR
  `/review-bugbot` habit.
- **Phase 1 — pilot one repo end-to-end.** Recommend **`client`** (we know its
  failure modes; least protection today) *or* **`client-runtime`** (representative
  Python service). Wire Layer 0 + Layer 1 + `.cursor/BUGBOT.md`, make checks
  required, prove the next promotion PR comes out clean.
- **Phase 2 — template across repos.** Python repos share one config; `client` /
  `cli` / `frontend-app` each get their variant. Add branch protection where it's
  missing (`client`, `cli`).
- **Phase 3 — (D5) gate on `Cursor Bugbot`** once deterministic gates are trusted;
  add the recall-tuned Claude pass where wanted.

## 9. Open questions / things to verify

- **Does Bugbot (and full CI) currently run on `feature→develop` PRs, or only on
  promotion PRs?** Determines how much Layer 1 buys us. If features land by pushing
  straight to `develop`, requiring feature PRs *is* the fix.
- **Branch-protection/ruleset visibility** — need a `project`/`repo`-scoped `gh`
  token to read/edit `client` + `cli` rulesets (they 404 on the classic API).
- **Bugbot billing tier** — is High effort available on our plan, and is the
  per-review cost acceptable scoped to promotion PRs?
- **`mypy` starting strictness** — lenient baseline + ratchet, or per-module opt-in?
- **Where does this RFC live long-term** — `client/docs/rfcs` or `tracebloc/.github`?

## 10. Work breakdown (cross-repo)

- **Tracking epic:** _TBD — to be created on the [engineering kanban](https://github.com/orgs/tracebloc/projects/2/views/1) before any implementation PR._
- **`client`**: `.cursor/BUGBOT.md` (Appendix A); make `helm-ci` + `installer-tests`
  required; add `yamllint`/`hadolint`/`kube-linter`; add `.pre-commit-config.yaml`;
  add branch protection.
- **Python repos** (`client-runtime`, `tracebloc-engine`, `backend`,
  `data-ingestors`): add `ruff` + `mypy` + standalone `bandit` jobs
  (`fail-fast: false`); make required; `.cursor/BUGBOT.md`; extend pre-commit to the
  repos missing it.
- **`cli`**: adopt `golangci-lint run` + `gosec`; add branch protection;
  `.cursor/BUGBOT.md`; PR template.
- **`frontend-app`**: ESLint flat-config migration; gate `eslint` + `tsc`;
  `.cursor/BUGBOT.md`; CODEOWNERS.
- **Org / Cursor dashboard**: High effort, learned rules + backfill, incremental-off
  default, (later) `Cursor Bugbot` required check + `fail-on-unresolved`.
- **Optional**: Claude Code review action wired into one pilot repo.

## 11. Risks & dependencies

- **R1 — Layer 1 only helps if feature PRs exist and are gated.** If the team pushes
  straight to `develop`, requiring PRs into `develop` is a workflow change with its
  own friction. *Mitigation:* verify current practice (§9); if direct-push is common,
  socialise the change and lean on Layer 0 (pre-commit) in the interim.
- **R2 — `mypy` on legacy code can produce a wall of errors.** *Mitigation:* start
  lenient (`--ignore-missing-imports`, per-module `disallow_untyped_defs=false`),
  ratchet like the existing coverage floors.
- **R3 — Turning on required checks can block in-flight PRs.** *Mitigation:* land the
  jobs as non-required first, fix the backlog, then flip to required.
- **R4 — Bugbot spend rises with High effort.** *Mitigation:* Custom rule scoping
  High to promotion PRs; Layer 1 shrinks diffs.
- **R5 — Branch-prefix/label skipping of Bugbot isn't supported yet** (Cursor
  internal ticket, not shipped) — so we can't cheaply exempt e.g. docs-only PRs.
  *Watch-item.*
- **Dependency:** editing `client`/`cli` rulesets needs a project-scoped token; the
  `.github` org ruleset needs a non-author approver (can't self-merge).

## Appendix A — draft `.cursor/BUGBOT.md` for `client`

```markdown
# Bugbot guide — tracebloc/client

## Context
Helm charts + a `curl | bash` installer for deploying the tracebloc edge client to
customer Kubernetes clusters. Bash + PowerShell provisioning scripts under
`scripts/`; Helm charts under `client/`. On-prem, often headless/SSH, sometimes
behind a TLS-inspecting corporate proxy. Operators are frequently junior.

## Always flag
- **Shell safety:** missing `set -euo pipefail`; unquoted `$var` / `$(...)`;
  unvalidated installer input piped from `curl | bash`; `eval`; parsing that breaks
  on spaces/newlines.
- **Helm nil-guards:** any read of a *new* top-level `values.yaml` key that isn't
  nil-guarded — `helm upgrade --reuse-values` keeps OLD stored values and will
  `nil pointer` before any resource lands. Require `default`/`with` guards.
- **`helm.sh/resource-policy: keep`:** it is read from the STORED release manifest,
  not the live resource. Flag any migration/uninstall step that assumes a live
  `kubectl annotate` protects a PVC. (See docs/MIGRATIONS.md.)
- **Secret leakage:** credentials in `values*.yaml`, logs, or committed files;
  world-readable secret/values files (want mode 0600).
- **Chart version/appVersion lockstep:** a `Chart.yaml` `version` bump without the
  matching `appVersion` bump (the `app.kubernetes.io/version` label depends on it).

## Leave alone
- `scripts/manifest.sha256` (generated), `docs/`, chart lockfiles, vendored schemas,
  `values.schema.json` generated sections.

## Tone
Direct. Name the file and line. Suggest a concrete fix, not "consider".
```

## Appendix B — issue-class → layer matrix

| Issue class | Caught by | Layer | Reports all at once? |
|---|---|---|---|
| Formatting / imports / style | ruff, black, gofmt, eslint | 0/1 | ✅ |
| Type errors | mypy, tsc | 0/1 | ✅ |
| Shell bugs | shellcheck | 0/1 | ✅ |
| Helm nil-guards / lint | helm lint, kube-linter, `.cursor/BUGBOT.md` | 1 | ✅ (det.) / backstop |
| Security lint | bandit, gosec, checkov, gitleaks | 0/1 | ✅ |
| Logic / judgment bugs | Claude recall pass, then Bugbot | 1 | ✅ (Claude) / backstop |
| Subtle high-confidence bugs | **Bugbot** | 1/2 | ❌ (~1/pass — backstop) |

---

_Discussion: please comment inline or in the tracking epic once created. The two
calls that most shape everything downstream are **D1** (Bugbot = backstop, not
gate) and **D2** (review per-feature, not at promotion)._
