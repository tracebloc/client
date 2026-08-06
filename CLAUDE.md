# Repo-level guidance for Claude Code

## Helm chart migrations — always read `docs/MIGRATIONS.md` first

Before planning any migration from one Helm release/chart to another in this repo, **read `docs/MIGRATIONS.md` in full**. It documents a specific, non-obvious gotcha that cost the tracebloc team a production PVC set on 2026-04-22:

> `helm.sh/resource-policy: keep` is read from the **stored release manifest**, not the live resource. `kubectl annotate pvc X helm.sh/resource-policy=keep` does NOT protect the PVC from `helm uninstall` if the chart template didn't render the annotation.

The mandatory pre-flight check before any `helm uninstall` that is part of a migration:

```bash
helm get manifest <release> -n <ns> | grep -B2 -A1 'resource-policy'
```

If the annotation is missing from the stored manifest for any resource you need to preserve, do not proceed with `helm uninstall` until you've applied **Option A or Option C** from `docs/MIGRATIONS.md`. (Option B in the doc is a cautionary tale labelled "DOES NOT WORK" — stripping live Helm ownership labels does not prevent uninstall from deleting the resource. Both production migrations to date were bitten by variants of "modify the live resource, expect uninstall to respect it." Assume that pattern will keep failing.)

## Default branch

Integration branch for this repo (and all tracebloc repos) is `develop`, not `main`. Target PRs at `develop`.

## PR conventions

Every PR must be assigned to **whoever is doing the work** — the author sets it when opening the PR. Assignee and reviewer are different roles: the assignee owns getting it merged, the reviewer owns judging it. On handover the assignee changes; the author does not (RFC-BACKEND-0008 D31).

Do not default the assignee to one person. This file used to name `saadqbal` unconditionally, from when he was the de-facto code owner here; that is no longer true, and a fixed assignee re-creates exactly the bystander effect the author-picks model was adopted to remove. Reviewer assignment is also the author's call — there is no automation that picks one.

<!-- org-standards:begin -->
# tracebloc engineering standards (org-wide)

<!-- Canonical source: tracebloc/.github/org-standards.md.
     Synced into every repo's CLAUDE.md between org-standards markers — never
     edit it inside a consuming repo; open a PR against tracebloc/.github.
     Meta-rule: the moment a rule below becomes mechanically enforced (a lint
     rule, a house-rules grep, a required check), delete the sentence here and
     let the check carry it. Prose is only for what tooling can't judge. -->

## Branches & PRs

- Branch model: `develop → staging → main`. Branch off `develop`; every PR targets `develop`. Never open PRs to `staging` or `main` — promotions are the release train's job. (Sole exception: the `docs` repo may target `main`.)
- Before starting any task: `git fetch` and branch from the current tip of `develop` — never build on a stale checkout. A branch that lives more than a day gets `develop` merged back in before review. We move fast; stale starts mean silent divergence and duplicated work.
- One self-contained change per PR. A few hundred changed lines reviews well; at 1000+ split it. Refactors ship in separate PRs from behavior changes.
- Branches are short-lived (aim to merge within a day or two), single-author, and based on `develop` — no stacked PRs on top of other open PRs.
- Names and commits: `feat/ fix/ docs/ sec/ ci/ chore/` + issue number + short slug (`fix/1234-ingest-timeout`); commit subjects `type(scope): summary`, referencing the ticket (`backend#1234`).
- When you open a PR: assign yourself and request exactly one reviewer immediately — a PR without a reviewer stalls by construction. Each repo's CLAUDE.md names its default reviewer.
- When you are the reviewer: first response within one business day.

## Quality bar

- Before every push: run the linter and the tests that cover your change. Never push a branch you believe is red — CI is the backstop, not the first run.
- Read the full diff before opening the PR. You own every line you ship, whoever — or whatever — wrote it.
- AI sessions end with evidence, not assertion: run the relevant check (tests, build, lint) and show the output. A change that could not be verified does not ship.
- After opening or pushing to a PR, stay on it: poll CI and Bugbot on the current head and triage every finding the same day — fix it, or reply on the thread saying why not. No silent dismissals. Unresolved threads block the merge and stall the release train's settle stage; cheap now beats expensive later.
- A finding that recurs across PRs becomes a rule: add it to `.cursor/BUGBOT.md`, and if it is grep-expressible, to code-quality's house-rules — then stop re-arguing it in comments.
- Style and naming rules live in tooling (black/ruff, eslint/prettier, house-rules), never in prose. If a rule matters, encode it; do not restate linter rules in CLAUDE.md files.
- Never commit secrets, tokens, or customer data — not in code, config, tests, issues, or commit messages. gitleaks and the PII gate will catch it; don't make them.

## Engineer kanban

- Picking up work: the team coordinates. `Ready` is the refined queue and the first choice when it's stocked; pulling from `Backlog` is normal when refinement hasn't caught up — say what you're taking.
- Merging to `develop` moves the card to `On dev` automatically; there is no dev-side review.
- Functional review happens once, on staging: when it passes, comment `/fr-pass` on the PR or drag the card to `Ready for prod`. Self-signoff is allowed.
- `fr-gate` is a required check on promotions. If it blocks, the board or the work isn't ready — fix that. `skip-fr-gate` is audited, for emergencies only.

## Releases & publishing

- The release train is the only path to `staging`, `main`, and every package registry. Never hand-cut a `v*` tag, hand-bump a version file, or publish an artifact — every legal publish path is inventoried in release-train's `PUBLISH-PATHS.md`.
- Findings on a promotion PR are fixed on the source branch (`develop`/`staging`), then the train re-prepares. Never push fixes onto a promotion PR — every push re-rolls its review.

## Filing issues

- Internal work — planning, epics, security findings, infrastructure, anything mentioning a customer — is filed in `backend` (the private catch-all), never in a public repo. When in doubt: `backend`.
- Public repos (`cli`, `client`, `docs`, `data-ingestors`, `model-zoo`, `start-training`, `.github`) only get issues a stranger could act on: about the public artifact itself, with no customer names, internal URLs, or internal paths.

## AI-assisted sessions (Claude Code, etc.)

- An AI session may open PRs and push its own branches. It never: merges a PR, closes another person's PR, deletes another person's branch, or force-pushes — each of those needs an explicit instruction from the human running it.
- If your change makes a statement in any CLAUDE.md, BUGBOT.md, or runbook false, update that file in the same PR.
<!-- org-standards:end -->
