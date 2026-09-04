# Design proposal — fresh clusters are born retired (backend#947 / backend#1528)

**Status:** mechanism **signed off by @LukasWodka (2026-09-02)** and now IMPLEMENTED
in this PR (`_helpers.tpl` + the stg/prod bake of rotate/reparent). Still a draft:
the `lookup`-driven behavior is **inert in `helm unittest` and every cluster-less
render**, so the fresh / already-rotated / fall-back branches are proven only by
`helm unittest`'s *structure* (via the `mysqlRootPassword` pin and the empty-pin
fall-back case) — the live datadir behavior needs a **staging rehearsal** (§6)
before it reaches prod. Getting the cluster-less / already-rotated branch wrong
regresses a live fleet (§4), which is why the rehearsal gates the merge.
**Author:** Saqlain (with Claude Code).

Lukas's sign-off, in three cases, maps onto §3.1: **new clusters → generated
Secret** (fresh row); **our own accessible existing clusters → manually rotate**
(the explicit-override path, unchanged); **blind clusters we cannot reach → fall
back to the existing password** (existing-un-rotated row).

> **IMPLEMENTATION NOTE (final — supersedes the "already rotated" row in §3.1/§3.2/§4
> below).** The shipped `tracebloc.bakedRootRotationOn` does **not** probe the live
> Secret for `MYSQL_ROOT_PASSWORD`: `scripts/tests/fullname-override-completeness.sh`
> (backend#2626) refuses a rename-unsafe `lookup` on the override-following
> `secretName`. So the helper resolves on for a **pin** or a **fresh datadir on a
> live cluster** only. Already-rotated edges (dev, edge 713) keep rotation on via
> their explicit `rotateMysqlRoot=true` **override**, which bypasses the helper — so
> the preservation the §4 subtlety describes is delivered by the override path, not a
> Secret probe. The remaining sections are kept as the design record.

---

## 1. Goal

A **fresh** install on **any** environment (dev/stg/prod) should come up in the
retired posture — root rotated off the baked `Edg9@Tr@ce` literal, mint re-parented
onto root, data plane on `tb_meta`/`tb_ingest`, training on per-experiment creds —
**without** an operator flipping five gates by hand. Existing edges must be left
exactly as they are.

This is the prerequisite for removing the baked literal from `client-runtime`'s
`Dockerfile.mysql_client` (the anonymously-pullable public image Lukas measured):
only once *fresh* installs never need the literal can it leave the image.

The two **additive** gates (`serviceDbAccounts`, `perExperimentDbCreds`) are already
being baked for stg/prod safely — that is the sibling PR (client#964), and it needs
none of this machinery because those gates fire no guard. This proposal is only
about the two **root-password** gates: `rotateMysqlRoot` and `bootstrapDbReparent`
(and `narrowEdgeuser`, which the resolver already gates on all three predecessors).

## 2. Why baking rotate/reparent per-env (the obvious fix) can't be done

Flipping `rotateMysqlRootByEnv.{stg,prod}: true` (the client#957 strawman) born-
retires fresh installs **and wedges every existing edge**: the `#2879` guard in
`secrets.yaml` fails the render when rotate is on and a datadir already exists but
root has not been ALTERed. On an edge's next hourly auto-upgrade that render fails,
`helm upgrade` returns non-zero, and the edge freezes on its current version.

The prod fleet inventory (2026-09-02, `backstage/metaApi/edgedevice/`) makes "migrate
every existing edge first, then flip" impossible: ~15 non-decommissioned prod edges
under one account alone, most currently **offline**, only edge 713 migrated. You
cannot run the one-time `ALTER USER 'root'` on an offline edge, so you can never
guarantee every existing edge is ALTERed before a default flip reaches it.

## 3. Proposed mechanism

Make the **baked-default** resolution of `rotateMysqlRoot` and `bootstrapDbReparent`
datadir-aware, while leaving an **explicit operator override** exactly as it is
today (fail-closed on an existing datadir — the deliberate "you asked to rotate,
here's the manual `ALTER`" path).

### 3.1 The four-way resolution table (this is the whole design)

For a **baked default** (`…ByEnv[env]: true`, no explicit `.Values.rotateMysqlRoot`):

| Edge state (on a **live** render) | rotate resolves | why |
|---|---|---|
| **Fresh datadir** — no `mysql-pvc`, cluster visible | **on** | born rotated; tier-3 mint generates root |
| **Existing + already rotated** — Secret holds `MYSQL_ROOT_PASSWORD` | **on** | preserve; flipping off breaks reparent's derive (§4) |
| **Existing + not rotated** — `mysql-pvc` present, no rotated Secret | **off** | no wedge; edge keeps its literal root until it's ALTERed |
| **Explicit `--set rotateMysqlRoot=true`** | unchanged | still fail-closed via the `#2879` guard |

`bootstrapDbReparent` (baked) follows `rotateMysqlRoot` (baked) exactly — reparent
needs root's password and derives it from the rotation (`bootstrapDbPassword =
$mysqlRootPassword`, backend#2738), so it is on iff rotate is on.
`narrowEdgeuser` already resolves on only when all three predecessors are on, so it
follows for free.

### 3.2 Code sketch (`client/templates/_helpers.tpl`)

A new helper answers "is a baked rotation safe to turn on for this render?", reusing
the exact signals `secrets.yaml` already computes:

```gotemplate
{{/*
  Whether a BAKED-DEFAULT rotateMysqlRoot may resolve on for this render, without
  wedging an existing un-rotated edge (backend#947 fresh-born-retired). Only ever
  consulted on the baked-default path; an explicit .Values.rotateMysqlRoot override
  bypasses this and keeps the #2879 fail-closed guard.

    - fresh datadir on a live cluster (no mysql-pvc, kube-system visible) -> true
    - existing datadir whose Secret already holds MYSQL_ROOT_PASSWORD        -> true  (already rotated; preserve)
    - existing datadir, not yet rotated                                      -> false (no wedge)
    - cluster-less render (lookup inert): see OPEN QUESTION 1                 -> ???
*/}}
{{- define "tracebloc.bakedRotationSafe" -}}
{{- $pvc      := (lookup "v1" "PersistentVolumeClaim" .Release.Namespace (include "tracebloc.mysqlPvc" .)) -}}
{{- $clusterVisible := (lookup "v1" "Namespace" "" "kube-system") -}}
{{- $secret   := (lookup "v1" "Secret" .Release.Namespace (include "tracebloc.secretName" .)) -}}
{{- $alreadyRotated := and $secret $secret.data (hasKey $secret.data "MYSQL_ROOT_PASSWORD") -}}
{{- if not $clusterVisible -}}
{{-   /* OPEN QUESTION 1 — cluster-less is undecidable. */ -}}
{{- else if not $pvc -}}
true
{{- else if $alreadyRotated -}}
true
{{- end -}}
{{- end }}
```

The `rotateMysqlRoot` resolver's baked-default branch changes from
`{{- if get $byEnv $env }}true{{ end -}}` to
`{{- if and (get $byEnv $env) (include "tracebloc.bakedRotationSafe" .) }}true{{ end -}}`,
and `bootstrapDbReparent`'s baked branch gates on the same helper. The explicit-
override branch of both is untouched.

Then, and only then, `values.yaml` bakes `rotateMysqlRootByEnv` and
`bootstrapDbReparentByEnv` to `true` for stg and prod (this PR). The additive gates
(`serviceDbAccountsByEnv`, `perExperimentDbCredsByEnv`) come from client#964, and
`narrowEdgeuserByEnv` follows once those predecessors are baked — narrowing resolves
on only with all three predecessors on, so baking it here would be inert.

## 4. The subtlety that makes this dangerous (must not regress)

An **already-rotated existing edge must keep rotate ON.** dev's live edge has an
existing datadir *and* a Secret that already holds `MYSQL_ROOT_PASSWORD`. If the
resolver flipped rotate off just because a datadir exists:

- `secrets.yaml` stops emitting `MYSQL_ROOT_PASSWORD` and `DB_BOOTSTRAP_PASSWORD`;
- `bootstrapDbReparent`'s tier-2 derive (`= $mysqlRootPassword`) has nothing to
  read, so reparent falls to its "fail — no password" tier or to a stale live-Secret
  value;
- jobs-manager, which authenticates as root with `DB_BOOTSTRAP_PASSWORD`, loses its
  credential → **1045 → CrashLoop** on a fleet that was healthy.

That is why the table's second row exists and why the helper checks the Secret, not
just the PVC. The `#2879` guard never had to make this distinction because it only
ever fires on the tier-3 *mint*; moving the decision into the resolver makes the
already-rotated case newly reachable, and it must be handled.

## 5. Open questions for the owner

1. **Cluster-less renders are undecidable.** `lookup` is empty under `helm
   template`, `--dry-run=client`, ArgoCD's default renderer and Flux post-render, so
   none of them can tell fresh from existing-unrotated. Options:
   - **(a)** baked rotate resolves **off** cluster-less (safe: never wedge, but a
     cluster-less-rendered fresh install is *not* born rotated — it comes up on the
     baked literal until a later live render). Acceptable if fresh installs always
     hit a live `helm install`/auto-upgrade (edges do — the auto-upgrade CronJob runs
     `helm upgrade` against the local cluster).
   - **(b)** require `mysqlDatadirExists` / a `mysqlFreshInstall` values hint for
     cluster-less fleets, mirroring the existing `#2892` escape hatch.
   This is the crux decision and it's yours — it depends on whether any real fleet
   installs via a cluster-less GitOps renderer rather than a live `helm upgrade`.

2. **dev's baked value under a cluster-less render** (e.g. CI, ArgoCD validation)
   flips from today's unconditional `true` to `bakedRotationSafe`'s answer. Under
   option 1(a) that is `false`, which changes what a cluster-less dev render emits.
   Is any dev tooling depending on the cluster-less render showing rotate on?

3. **helm-unittest cannot exercise any of this** (lookup inert). The existing suites
   already pin `mysqlRootPassword` tier-1 to get *past* the mint guard; with this
   change the tests would also need to pin the datadir signal (a `mysqlDatadirExists`
   / fresh hint) to assert either branch. So CI verifies the *structure* and the
   override path, never the live datadir behavior — that is a **staging rehearsal**,
   not a unit test.

## 6. Verification plan (once the mechanism is agreed)

1. Implement §3, update the rotate/reparent/narrow chart tests to pin the datadir
   hint, get `helm unittest` + the gate guards green (structure only).
2. **Staging rehearsal** (needs the cluster access Lukas offered — SSM bastion + EKS
   View + staging exec/secrets per `docs/platform/access/CLUSTER-ACCESS.md`):
   - a **fresh** staging install renders rotate/reparent **on** and comes up born
     retired (root ≠ literal, mint as root, `edgeuser` never authenticated);
   - an **existing un-rotated** staging edge's auto-upgrade renders rotate **off** and
     does **not** wedge (no `#2879` failure, no `1045`);
   - the **already-rotated** staging edge keeps rotate **on** across the upgrade.
3. Only after all three hold on a live cluster does this reach prod, via the train.

## 7. What ships in what order

1. **client#964** — bake the two additive gates (no guard change). Safe now.
2. **This mechanism** — the datadir-aware baked rotate/reparent + the stg/prod bake.
   Gated on §5 decisions + §6 rehearsal.
3. **Image scrub** (`client-runtime` `Dockerfile.mysql_client`, root half first) —
   safe once fresh installs get root from the chart rather than the baked literal,
   i.e. once (2) is live. The `edgeuser`-account half follows the fleet rotation.
