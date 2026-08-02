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
