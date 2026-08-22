# Bugbot guide — tracebloc/client

## Context

Helm charts (`client/`, `ingestor/`) plus a `curl | bash` installer: `scripts/install.sh`
is the signed trust root that fetches and verifies `scripts/install-k8s.sh` +
`scripts/lib/*.sh`, with PowerShell peers (`install.ps1`, `install-k8s.ps1`).

This runs on **customer-operated Kubernetes**: on-prem, frequently headless over SSH,
often behind a TLS-inspecting corporate proxy, sometimes against a mirrored registry.
Operators are usually not Kubernetes people, and there is no telemetry — if the
installer prints "ready" when it isn't, nobody finds out for days. Optimise findings
for *what the operator sees and can act on*, not code elegance.

## Always flag

- **Missing `set -euo pipefail` in an entry-point script**, unquoted `$var` / `$(...)`,
  `eval`, or parsing that breaks on spaces/newlines. Note the house idiom: a top-level
  `[[ -f x ]] && source x` **trips `set -e`** when the test is false — require an `if`
  block instead (`scripts/install-k8s.sh:70-80`).

- **A bare `curl` that bypasses `curl_secure()`.** Every fetch goes through the
  `curl_secure()` wrapper (`scripts/lib/common.sh`), which bakes in the TLS floor
  (`--tlsv1.2`) and the connect/stall timeouts so a call site can't silently drop them
  and a TLS-inspecting proxy can't negotiate down. `check-style.sh` (rule 3, "no bare
  `curl`") enforces this in CI, so flag any new bare `curl` that isn't `curl_secure`.
  Legitimately exempt (the style rule already allows these): `scripts/install.sh` and the
  WSL here-string in `install-k8s.ps1` name `--tlsv1.2` directly because they can't source
  `common.sh`; comments; `has curl` / `command -v curl` presence tests; and the
  `curl … | sh` one-liner printed for the user to copy.

- **An unbounded external call.** `kubectl` takes `--request-timeout=5s`. `helm` has no
  `--request-timeout`, so the convention is to gate a helm call behind a bounded
  `kubectl cluster-info --request-timeout=5s` probe (`scripts/lib/diagnose.sh:149-152`).
  `curl` takes `--connect-timeout` plus `-m`/`--max-time`, or the
  `--speed-limit`/`--speed-time` stall pair. Against a wedged API server an unbounded
  call hangs a headless install forever, with no output to interpret.

- **A version/tag/ref interpolated into a URL without validation.** There is no shared
  validator — each path adds its own gate: `scripts/install.sh:184,193,214-219` (ref
  charset + immutable-tag regex + a literal `*/*` / `*..*` check, defending
  `v1.2.3-../../heads/main`), `scripts/lib/setup-linux.sh:406,413` for `K3D_VERSION`.
  A new download path needs its own.

- **A guard that fails open.** A failed or unparsable `kubectl`/`helm`/`docker` result
  must never read as a benign "nothing there". Canonical:
  `detect_installed_client()` sets `INSTALLED_CLIENT_UNKNOWN=1` rather than "no client
  here" when `helm list` exits non-zero (`scripts/lib/install-client-helm.sh:166-205`) —
  failing open lets a re-install silently overwrite a live client. Also
  `client/templates/egress-reachability-check.yaml:79-97` keys its verdict on curl's
  **exit code**, not the HTTP status, because curl without `--fail` exits 0 on a 500.

- **Success reported without verifying it.** `docs/SEAL-CHECK.md:34` — "unsealed, never
  silently sealed": a check that cannot verify its guarantee fails loudly. Flag any step
  that prints ✓ / "healthy" / "ready" on a path where the underlying assertion was
  skipped, degraded, or errored, and any summary that counts a skipped check as passed.

- **`A && B` where B is the operation that actually matters.** Chaining makes B conditional
  on A, so the *more likely to fail* call silently cancels the load-bearing one — and the
  `|| echo` tail then reports a graceful degrade that never happened. `init-writable-data`
  shipped `chown … && chmod …` in chart 1.9.20 (#611/#612) and kept it through 1.9.33: on
  any mount that refused the chown (bind mount, NFS root_squash, pre-provisioned volume)
  the chmod never ran, the dir kept root:root 0755, and the log said "leaving as-is" (#672,
  fixed in `client/templates/jobs-manager-deployment.yaml`). #667 rewrote the modes on that
  exact line and left the chain in place — a reviewer reading the line for its modes did not
  re-read its control flow, which is why this one is worth flagging mechanically. Flag independent best-effort repairs
  joined by `&&`; each should be its own statement, and the verdict should come from the
  end state (`ls -ldn`) rather than an exit status — a bind mount can accept a chmod and
  ignore it. Related: the same PR family also produced an owner check that passed
  unusable dirs, because ownership was treated as evidence of writability (#654).

- **A read of a *new* `values.yaml` key with no nil-guard.** `helm upgrade --reuse-values`
  keeps the OLD stored values, so a template reading a key that didn't exist at install
  time nil-pointers before any resource lands. Require `default` / `with` / `hasKey`;
  worked example at `client/templates/metadata-backfill-hook.yaml:1-18`. Both upgrade
  paths must survive: `scripts/lib/install-client-helm.sh:390-391` feature-detects
  `--reset-then-reuse-values` and falls back to `--reuse-values` on Helm < 3.14, while
  `client/templates/auto-upgrade-cronjob.yaml:84` hardcodes the reset form — a new chart
  *default* only reaches an existing release on the reset path.

- **Anything assuming a live `helm.sh/resource-policy: keep` annotation protects data.**
  Helm reads that annotation from the **stored release manifest**, not the live object, so
  `kubectl annotate pvc … resource-policy=keep` does not survive `helm uninstall`. This
  cost a production PVC set on 2026-04-22 (`docs/MIGRATIONS.md`, "The resource-policy:
  keep gotcha"). Templates that legitimately render it: `logs-pvc.yaml`,
  `shared-images-pvc.yaml`, `mysql-storage-pvc.yaml`, `namespace.yaml`,
  `node-agents-namespace.yaml`, `priority-class.yaml`.

- **Image pinning drift.** Images are pinned by digest with the tag kept for readability
  only — the digest is authoritative (`client/values.yaml`, `images.ingestor`). Pinned
  digests must be multi-arch *index* digests; `scripts/resolve-ingestor-digest.sh` refuses
  a single-arch one. The fleet-wide prod pin is the chart default
  `images.ingestor.prodDigest` (in `client/values.yaml`), **not** an install-time overlay —
  the old `client/values-prod.yaml` was deleted and the pin moved into chart defaults
  (backend#1245). CI's `ingestor-multiarch` guard (`.github/workflows/helm-ci.yaml`) reads
  `client/values.yaml` and hard-fails if `prodDigest` is empty (that silently un-pins prod)
  or not multi-arch; it also checks the floating `images.ingestor.tag` and the per-edge
  `images.ingestor.digest` when set. Flag a `prodDigest`/`digest` change that isn't a
  verified multi-arch index digest (resolve with `scripts/resolve-ingestor-digest.sh`).

- **Credentials in `values*.yaml`, logs, argv, or a `--diagnose` bundle**; secret/values
  files should be mode 0600.

- **A changed bootstrap-fetched script without a regenerated `scripts/manifest.sha256`**
  (`scripts/gen-manifest.sh`). `make drift` fails in the required `Source-of-truth drift`
  check, and a stale manifest breaks `install.sh`'s verified fetch.

- **A test whose fixture cannot reach the code it names.** Ask which line of production
  code changes the assertion's outcome; if none does, the test is decoration however well
  it reads. Three PRs on 2026-08-20 (#762, #763, `tracebloc/release-train#94`) shipped
  **eleven** of these, every one reviewed and green, so treat it as the default suspicion
  on a new guard test. Three shapes, ascending in subtlety:
  - **Unreachable fixture** — the input never takes the path. A one-liner test that
    *indents* the function when the opener rule is anchored at column 0; an attribution
    test whose dispatch-only fixture returns before attribution runs.
  - **Redundant mechanisms** — two code paths give the same observable for that input, so
    removing either changes nothing. A fixture with ONE Dockerfile cannot distinguish "the
    fallback demanded everything" from "the comment attributed that one file": both count 1.
    Add the second element.
  - **Inert mutation** — the *mutation* fails to express the defect. For a root Dockerfile
    `rel` and the basename are the same string, so mutating one of two redundant match arms
    leaves the other matching. An anchor-resolution check **cannot** catch this — the
    anchor resolves perfectly and the log is indistinguishable from real coverage. Only a
    surviving mutation reveals it.

- **A surviving mutation treated as a nuisance.** It is a defect in the test, or in the
  mutation — never something to annotate and move past. The converse matters too: a green
  mutation log is evidence only if the run also asserts the mutation *applied*
  (backend#1729 rule 5), because an unresolvable anchor and real coverage look the same.

- **A derived vocabulary that cannot fail closed.** Deriving beats restating (backend#1729
  rule 1), but a derivation that silently falls through returns the *wrong* vocabulary and
  then agrees with itself. `_brand_rgbs` in `scripts/tests/check-style.bats` fell back to
  the hex list when rule 1's RGB arm was deleted, so the test asserting "every RGB triple
  is caught" passed with the RGB half **gone**. Require both halves: fail closed on a
  missing marker, and assert the token shape.

- **A pipe into an early-closing reader under errexit + pipefail.** `producer | head -n N`,
  `| grep -q`, `| grep -m N`: the reader closes, the producer takes SIGPIPE, pipefail makes
  the pipeline 141 and errexit kills the script. Size-dependent, which is why it survives
  review — measured, 50 lines exit 0 and 20k exit 141 (client#656, client#678). The house
  idiom is a here-string or capture-then-slice.
  Enforced in CI by the **shared** gate — the `early-close` job in
  `tracebloc/.github`'s `code-quality.yml`, on by default for every repo — **including
  inside `scripts/lib/*.sh`** (see the corollary below). This repo carried the only copy
  for a month; it was retired once the shared one reached `.github`'s `main`, because two
  copies of a scanner is the drift this rule exists to prevent (backend#2264). Report a
  false positive there, not here. Converting an instance is not always the
  fix: `scripts/lib/diagnose.sh:95-101` keeps its `df -h | head -20` on purpose, because
  `run_diagnose` opens with `set +e` so the 141 cannot fire, *and* `head` streams — capturing
  df in full would block the whole bundle on an unresponsive NFS mount. The guard reads
  `set +e` and does not flag it, so no marker is needed there; `# pipefail-guard: allow`
  exists for a case the guard cannot reason about, and is currently unused in the tree.
  Flag a new marker that does not state why.

- **Half of a paired construct changed.** Openers and closers, arms of one `if`, a
  neutralisation and the boundary it destroys, a writer and its reader — when a rule lives
  in two places that must move together, changing one is not a partial fix, it is a *new*
  bug, and often in the opposite direction from the one being fixed. Three in one day on
  2026-08-20/21, all on constructs whose halves sat within twenty lines of each other:
    - client#777: `||` neutralised to `\001` for the `grep` arms via `grep[^|\001]*`, but
      `\001` was not added to the `head` terminator class — so `producer | head||die`, which
      `develop` flagged, was silently dropped. Fail-open.
    - client#764: the Helm comment stripper taught the chomping opener `{{- /*` but not the
      matching closer `*/ -}}`, so a block that used both never terminated and the stripper
      ate 23 lines of the file. Fail-**closed**, in a required drift gate.
    - client#777 again: the fix for the first one shipped a second change (a one-character
      stand-in) whose mutation survived — inert, and reverted.
  Two habits close it, and both are cheap. **Grep for the sibling** before committing: if
  you edited a terminator class, an opener, or one arm of a matcher, find the other. And for
  a scanner or matcher, **diff the whole-tree output against the base** — if the base flags
  something you no longer do, that is a regression the unit tests will not show you, because
  they only cover the case you were already thinking about.

- **A fixture set that only exercises the form the author had in mind.** The corollary to
  the above, and the reason it kept getting through: the `k3s-components-agreement` suite
  added in client#764 had nine cases and none used the `*/ -}}` closer, so the suite shipped
  in the *same commit* as the bug it could not see. When the thing under test accepts
  several spellings of one construct, enumerate the spellings from the real input — here,
  from the template the guard actually reads — not from the example in your head.

- **A `Chart.yaml` `version` bump without the matching `appVersion`** — the
  `app.kubernetes.io/version` label depends on it.

## Known non-issues — do not flag

- **`scripts/lib/*.sh` have no `set -euo pipefail` by design.** They are only ever
  `source`d by `scripts/install-k8s.sh`, which sets it at line 44 *before* sourcing.
  Corollary, and the reason this is a non-issue rather than a free pass: those libs still
  **run** under both options, so every errexit/pipefail rule — including the early-close
  gate above — applies to them in full. A guard that only asks "does this file set the
  options" reads the entire lib tree as safe; that was the bug #763 fixed.
- `scripts/check-style.sh`, `scripts/tests/check-drift.sh`, `scripts/tests/distro-prereqs.sh`
  and `scripts/tests/path-persist.sh` deliberately use `set -uo pipefail` **without `-e`**
  so they can inspect a failing check's exit code instead of aborting.
- **SC2034 "unused variable" in `scripts/lib/*.sh` is a known false positive** — those vars
  are consumed cross-file once the libs are sourced together. CI blocks at
  `--severity=error` via `make lint` in the required `Lint` check, and prints the
  `--severity=warning` sweep advisory-only via `make lint-warnings`.
- `scripts/manifest.sha256` and `scripts/testdata/golden/*.golden` are **generated**. The
  golden copy catalog is regenerated with
  `TB_UPDATE_GOLDEN=1 bats scripts/tests/copy-catalog.bats`, never hand-edited — review the
  copy itself, not the diff mechanics.
- **`clientId` is intentionally not redacted** from `--diagnose` bundles: it is the
  identifier support needs, not a secret (`scripts/lib/diagnose.sh:13`).
- Existing `# shellcheck disable=…` lines each carry a stated reason — don't re-litigate them.
- `docs/`, chart lockfiles, and generated sections of `client/values.schema.json`.
- A `code-quality-caller.yml` that passes **no `secrets:` line** is correct, not an omission.
  The shared `code-quality.yml` reusable references no secrets by contract
  (RFC-BACKEND-1405 Q5, backend#1526): secretless callees get no secrets line, and if the
  reusable ever gains one, callers switch to explicit per-secret passing — never
  `secrets: inherit`. Flag the *addition* of `secrets: inherit` on this caller instead.

## Tone

Direct. Name the file and line. Give a concrete fix, not "consider". Lead with the
operator-visible consequence (what they see, what breaks, at which step).

This repo is **public** — never put a customer name, internal hostname, or internal-only
ticket detail in a finding. A bare `tracebloc/backend#NNNN` reference is fine.

## Working with Bugbot findings (team norm)

Every Bugbot review thread gets a reply, then gets resolved:
- **Fixed**: say what changed and in which commit.
- **False positive**: say why, with evidence (file/line, measured behavior).
- **Never resolve on "the reported case now passes."** Re-test the surrounding shape space
  first — a fix for one spelling routinely leaves its sibling broken (flow vs block form
  recurred four times in `tracebloc/release-train#94` alone). A resolved thread reads as
  "handled" to the next person, so closing one over a still-broken shape is worse than
  leaving it open.
Unresolved cursor threads HOLD release-train promotions (soft gate) — an
unaddressed finding blocks the fleet, not just this PR.
