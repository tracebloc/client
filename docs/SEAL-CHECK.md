# Seal check — the chart's conformance suite

> RFC-0003 §8.2–8.4 (D12) · backend#1184 · CLI companion: tracebloc/cli#393

The **seal check** is the tracebloc chart's conformance suite: a set of
`helm test` hook Jobs that verify, from inside the cluster, that the
guarantees the secure environment claims are actually enforced on *this*
cluster — not just declared in values.

One command runs the whole suite:

```bash
helm test <release> -n <namespace> --logs
```

`helm test` exits non-zero if any check fails — that exit status is the
aggregated verdict today. Per-check detail is in each Job's log
(`OK` / `FAIL` / `SKIP` / `WARNING` lines, ending in a
`SEAL-CHECK RESULT:` line). Run a single check with
`--filter name=<release>-<check>-check`.

Because every check is a `helm.sh/hook: test` hook, **nothing here ever runs
during install or upgrade** — the suite can never block them or the hourly
auto-upgrade.

## The philosophy: unsealed, never silently sealed

Design stance the chart has always taken: **silent non-protection is worse
than explicit disabling.**

- An environment that cannot enforce a guarantee is explicitly marked
  **unsealed** — a check that cannot verify its guarantee **fails loudly**;
  it never silently claims sealed. (Example: the egress-enforcement probe
  fails on an inconclusive DNS outcome rather than assuming the lockdown
  works.)
- Turning a check off is an **explicit, values-visible declaration**
  (reviewable in `helm get values`), never a runtime fallback. An operator
  who disables a check has documented that the guarantee is not verified on
  that cluster — which is honest; a suite that quietly skips is not.
- Where a check can only *partially* verify (see `clusterScope=false` under
  storage-assertions), the output names exactly what was and was not
  verified.

## The enumeration contract (consumed by the tracebloc CLI)

Every **runnable** check is a `helm test` hook **Job** carrying two labels —
on the Job *and* on its pod template:

| Label | Value |
|---|---|
| `tracebloc.io/seal-check` | `"true"` — membership marker |
| `tracebloc.io/seal-check-name` | stable per-check identifier (below) |

Enumerate the suite without running anything (hooks are not part of the
release manifest, so use the hooks view):

```bash
helm get hooks <release> -n <namespace>
```

While a `helm test` run is live:

```bash
kubectl get jobs,pods -n <namespace> -l tracebloc.io/seal-check=true
```

**Contract rules** (tooling such as `tracebloc` CLI, cli#393, depends on
these):

- The two label keys and the existing check names are public API — never
  rename them. New checks are added under new names.
- Only runnable checks (Jobs) carry the labels. Auxiliary hook resources
  (the storage check's ServiceAccount/RBAC) deliberately do not — counting
  them would inflate the suite.
- A check that does not *render* (its gating values turned it off, or its
  preconditions are not declared — e.g. the egress-enforcement probe before
  the lockdown is flipped) is **not part of the suite on that cluster**, and
  the values that gated it away say why.
- Log lines are human-oriented and not part of the contract; the machine
  contract today is *labels + Job exit status*. (A structured verdict is the
  CLI's job — cli#393.)

## The suite today

| `seal-check-name` | Template | Verifies | Renders when | Explicit off-switch |
|---|---|---|---|---|
| `egress-enforcement` | `egress-enforcement-check.yaml` | The CNI actually blocks a training-labelled pod's direct egress to `enforcementProbeHost:443` — i.e. the §8.2 lockdown is *enforced*, not just declared | `networkPolicy.training.enabled` and `allowExternalHttps=false` and `enforcementProbeHost` non-empty | `networkPolicy.training.enforcementProbeHost: ""` |
| `backend-reachability` | `egress-reachability-check.yaml` | A normal (non-training) pod completes an HTTPS round trip to the tracebloc backend API — the required-egress complement (no backend egress ⇒ experiments sit Pending) | `egressReachabilityCheck.enabled` (default on) | `egressReachabilityCheck.enabled: false` |
| `storage-assertions` | `storage-assertions-check.yaml` | Release storage matches the declared storage model (below) | `sealCheck.storageAssertions.enabled` (default on) | `sealCheck.storageAssertions.enabled: false` |

### storage-assertions in detail

Three sub-checks, reported line-by-line in the Job log:

1. **pvc-bound** — every release PVC (`client-pvc`, `client-logs-pvc`,
   `mysql-pvc`) exists and is `Bound`. Waits up to
   `sealCheck.storageAssertions.timeoutSeconds` (default 120) first:
   `WaitForFirstConsumer` classes bind only when the consuming pod
   schedules, and fresh installs may still be pulling images.
2. **pvc-storageclass** — every release PVC is on the release's expected
   StorageClass (`<release>-storage-class` when the chart creates it,
   `storageClass.name` otherwise). A claim satisfied by some other class is
   storage the chart does not manage.
3. **pv-hostpath** — *dynamic-PVC mode only* (`hostPath.enabled=false`): no
   release PVC is backed by a hostPath PersistentVolume on an unmanaged host
   tree. This catches the RFC-0003 D3/D4 stranding scenario: a leftover
   chart hostPath PV from an older bare-metal install still carries a
   `claimRef` for our fixed PVC names and **captures the claim even in
   dynamic mode**. In hostPath mode this sub-check reports `SKIP` — hostPath
   PVs are that install's declared storage model, and the model is chosen in
   values, visible to review.

Two deliberate nuances, both grounded in RFC-0003:

- **Node-local provisioner paths are tolerated, with a note.** On k3s/k3d
  the bundled local-path provisioner creates PVs that are hostPath-*typed*
  but live inside the cluster node's filesystem and die with the cluster —
  exactly the RFC-0003 **Option C** ("node-local") model. Paths under
  `sealCheck.storageAssertions.nodeLocalPathPrefixes` (default:
  `/var/lib/rancher/`, `/opt/local-path-provisioner/`; entries match whole
  path segments — a prefix admits itself and paths under it, never sibling
  paths) therefore pass, with
  an `OK` line stating the caveat: whether such a path is *additionally*
  host-visible is a cluster-creation fact (a bind mount) that cannot be
  observed from inside the cluster — it is verified at install level, not
  here. Any *other* hostPath backing in dynamic mode fails the check.
- **`clusterScope: false` degrades the PV scan, and says so.**
  PersistentVolumes are cluster-scoped; without a ClusterRole the check
  cannot read PV specs. It still runs the leftover-PV name check (needs no
  PV read) and prints a `WARNING` naming exactly what was not verified.
  Full verification needs `clusterScope: true`. The degradation is declared
  in values, not discovered at runtime.

The assertion pod authenticates with its own least-privilege ServiceAccount
(get/list on PVCs in the release namespace; get/list on PVs only when
cluster scope allows it), created as negative-weight test hooks alongside
the Job and removed with it on success. It is deliberately **not** labelled
`tracebloc.io/workload: training` — it needs the Kubernetes API, which the
training lockdown denies.

## Guarantee coverage per substrate (chart-side view)

This table is the chart-side input to the RFC-0003 §8.3 guarantee matrix
(the RFC holds the authoritative, customer-quotable matrix; precise filling
is tracked in backend#1184). "Verified" below means *this suite verifies it
on the live cluster when the corresponding check runs.*

| Guarantee | k3d local (k3s) | EKS | AKS | OpenShift | bare metal |
|---|---|---|---|---|---|
| Training egress blocked (NetworkPolicy) | Conditional — k3s-embedded controller expected to enforce, **verification run pending** (runbook below; do not assume) | Conditional on CNI (VPC CNI netpol agent / Calico / Cilium) — **verified** by `egress-enforcement` once the lockdown is flipped | Conditional on CNI (Azure NPM / Calico) — **verified** by `egress-enforcement` once the lockdown is flipped | OVN-Kubernetes enforces by default — still **verified** by `egress-enforcement` | Conditional on CNI (Flannel alone does not enforce) — **verified** by `egress-enforcement` |
| Backend reachability (required egress) | **Verified** by `backend-reachability` | **Verified** | **Verified** | **Verified** | **Verified** |
| Storage on the declared class, bound | **Verified** by `storage-assertions` | **Verified** | **Verified** | **Verified** (PV scan degraded if `clusterScope=false`) | **Verified** |
| No unmanaged hostPath backing (dynamic mode) | **Verified** once the Option C flip lands (today's installer still declares hostPath mode → sub-check SKIPs, honestly) | **Verified** | **Verified** | **Verified** with `clusterScope=true`; partial (name check + explicit WARNING) otherwise | n/a — hostPath *is* the declared model (SKIP) |
| Nothing under `~/.tracebloc` on the host (post-Option-C) | Not observable in-cluster — CLI/installer-side check (see follow-ups) | n/a | n/a | n/a | n/a |

Two lockdown caveats the suite states rather than hides:

- `egress-enforcement` only *renders* after the per-fleet lockdown flip
  (`allowExternalHttps=false` — the RFC-0003 §8.1 rollout). Until that flip,
  training-pod outbound :443 is deliberately open and there is no
  enforcement to verify — the environment is **not sealed for egress** and
  nothing here claims it is.
- A rendered check that fails means the environment is **unsealed** for that
  guarantee until fixed — e.g. a CNI that does not enforce NetworkPolicy
  fails `egress-enforcement` with remediation hints, exactly so the lockdown
  cannot be a silent no-op.

## Runbook: verify NetworkPolicy egress enforcement on k3d/k3s locally

RFC-0003 §8.4: **do not assume** k3d enforces NetworkPolicy — k3s ships an
embedded (kube-router-based) NetworkPolicy controller that is *expected* to
enforce egress rules, but expected is not verified.

> **Status: this verification run has NOT yet been executed and recorded by
> the team.** Until a run below is recorded (backend#1184), treat k3d/k3s
> egress enforcement as unverified — i.e. unsealed for the egress guarantee.
> The steps use the existing `egress-enforcement` probe; nothing new needs
> to be built to execute them.

Run on a **local test install** (the lockdown flip below breaks direct
training-pod egress until reverted — do not run it on a fleet you care
about without following the §8.1 rollout order):

```bash
# 0. A local k3d install (docs/INSTALL.md / the installer one-liner).
#    Note the release + namespace; the installer uses the same value for both.
RELEASE=<release> NS=<namespace>

# 1. Flip the egress lockdown ON so the probe renders:
helm upgrade "$RELEASE" tracebloc/client -n "$NS" --reuse-values \
  --set networkPolicy.training.allowExternalHttps=false

# 2. Run the probe (a training-labelled pod tries a direct TCP connect to
#    1.1.1.1:443 and must be BLOCKED; it retries up to 60s to cover CNIs
#    that program per-pod policy after a brief reconcile):
helm test "$RELEASE" -n "$NS" --logs \
  --filter name="$RELEASE"-egress-enforcement-check

# 3. Interpret:
#    "OK  egress lockdown verified …"        → the k3s-embedded controller
#      enforces egress NetworkPolicy on this cluster. Sealed for this
#      guarantee (record the run: k3s version, k3d version, date).
#    "WARNING  EGRESS LOCKDOWN NOT ENFORCED" → k3d/k3s did NOT block the
#      connect. The environment is UNSEALED for the egress guarantee;
#      the lockdown must not be relied on locally until this is fixed.
#    "WARNING  … INCONCLUSIVE"               → probe host unresolvable;
#      fix DNS / probe host and re-run. Inconclusive fails the test —
#      unverified is never reported sealed.

# 4. Revert the flip:
helm upgrade "$RELEASE" tracebloc/client -n "$NS" --reuse-values \
  --set networkPolicy.training.allowExternalHttps=true
```

When the run has been executed, record the result (pass/fail, k3s/k3d
versions, date) here and fold it into the RFC-0003 §8.3 matrix.

## What the suite does not cover yet (follow-ups)

Tracked under backend#1184 unless noted:

- **The live k3d verification run** (§8.4) — the runbook above is
  documented but has not been executed; the k3d cell in the matrix stays
  "verification run pending" until it is.
- **A single aggregated sealed/unsealed verdict with per-guarantee detail**
  — surfaced by the tracebloc CLI on top of this label contract
  (tracebloc/cli#393). Today the aggregate is `helm test`'s exit status
  plus per-Job logs.
- **`~/.tracebloc` host-tree check** (post-Option-C: nothing of the
  environment left under the operator's home) — host-side by construction,
  not observable from in-cluster; belongs to the CLI/installer offboard
  verification lineage (cli#389), not to a helm-test Job.
- **Wiring the suite into the e2e harness dev runs.**
- **Filling the RFC-0003 §8.3 matrix precisely** in the RFC itself — the
  table above is the chart-side input.
- **The Option C storage flip on local installs** (client#368) — the
  storage-assertions check is forward-compatible either way: it gates on
  `hostPath.enabled` and verifies whichever model the install declares.
