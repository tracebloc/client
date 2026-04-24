# Repo-level guidance for Claude Code

## Helm chart migrations — always read `docs/MIGRATIONS.md` first

Before planning any migration from one Helm release/chart to another in this repo, **read `docs/MIGRATIONS.md` in full**. It documents a specific, non-obvious gotcha that cost the tracebloc team a production PVC set on 2026-04-22:

> `helm.sh/resource-policy: keep` is read from the **stored release manifest**, not the live resource. `kubectl annotate pvc X helm.sh/resource-policy=keep` does NOT protect the PVC from `helm uninstall` if the chart template didn't render the annotation.

The mandatory pre-flight check before any `helm uninstall` that is part of a migration:

```bash
helm get manifest <release> -n <ns> | grep -B2 -A1 'resource-policy'
```

If the annotation is missing from the stored manifest for any resource you need to preserve, do not proceed with `helm uninstall` until you've applied Option A, B, or C from `docs/MIGRATIONS.md`. Do not assume live annotations will work.

## Default branch

Integration branch for this repo (and all tracebloc repos) is `develop`, not `main`. Target PRs at `develop`.
