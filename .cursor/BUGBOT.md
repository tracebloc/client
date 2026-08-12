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
  ran `chown … && chmod …` for two releases: on any mount that refused the chown (bind
  mount, NFS root_squash, pre-provisioned volume) the chmod never ran, the dir kept
  root:root 0755, and the log said "leaving as-is" (#672, fixed in
  `client/templates/jobs-manager-deployment.yaml`). Flag independent best-effort repairs
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
  (`scripts/gen-manifest.sh`). The "Installer manifest is current (supply-chain, R8)" step
  in `installer-tests.yaml` fails, and a stale manifest breaks `install.sh`'s verified fetch.

- **A `Chart.yaml` `version` bump without the matching `appVersion`** — the
  `app.kubernetes.io/version` label depends on it.

## Known non-issues — do not flag

- **`scripts/lib/*.sh` have no `set -euo pipefail` by design.** They are only ever
  `source`d by `scripts/install-k8s.sh`, which sets it at line 44 *before* sourcing.
- `scripts/check-style.sh`, `scripts/tests/check-drift.sh`, `scripts/tests/distro-prereqs.sh`
  and `scripts/tests/path-persist.sh` deliberately use `set -uo pipefail` **without `-e`**
  so they can inspect a failing check's exit code instead of aborting.
- **SC2034 "unused variable" in `scripts/lib/*.sh` is a known false positive** — those vars
  are consumed cross-file once the libs are sourced together. CI blocks at
  `--severity=error` and runs `--severity=warning` advisory-only (`installer-tests.yaml:63-67`).
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
Unresolved cursor threads HOLD release-train promotions (soft gate) — an
unaddressed finding blocks the fleet, not just this PR.
