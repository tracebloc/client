# RFC 0003 — One installer core: Linux-first, thin OS adapters

**Qualified ID:** `RFC-CLIENT-0003` — cite this document by its qualified ID, never as a bare "RFC 0003"; other repos have their own numbering. Org-wide index: `docs/rfcs/README.md` in `tracebloc/backend` (private).
**Status:** Draft — proposed 2026-07-27. Decision D2 (the Windows adapter) is gated on the rootless-in-WSL validation; D3/D5 are proposed for immediate adoption.
**Author:** Lukas (drafted with Claude)
**Reviewers:** @saadqbal
**Repos affected:** `client` (installer), `.github` (CI), later `cli`
**Related:** [`RFC-CLIENT-0001` — spike: rootless Docker as the k3d backend](./0001-rootless-spike.md) · [`RFC-CLIENT-0002` — least-privilege install](./0002-least-privilege-install.md) · epics tracebloc/backend#1285 (installer quality) and tracebloc/backend#1168 / tracebloc/backend#1179 (least-privilege, Windows/WSL2 child)

## 1. Problem — we implement every installer behavior three times

The installer exists as one **7,082-line bash core** (Linux multi-distro + a 279-line macOS branch) and one **2,678-line PowerShell monolith** (Windows). A July 2026 sweep of three real installs (one hospital deployment, two internal Windows test machines) plus a cross-OS code audit produced a 25-child epic (tracebloc/backend#1285) — and most children are the *same defect class appearing per-OS*:

- **Facts drift.** `K3D_VERSION`/`HELM_VERSION` pins landed in bash (#382) but never in PowerShell (#410) — a customer install then died on the exact rate-limited `api.github.com` lookup the pin was built to kill. On macOS the pins exist but are silently bypassed by bare `brew install` (#429).
- **Logic drift.** No execute-gate after tool install (all three OSes, #411/#429); missing deadlines around `k3d cluster create --wait` / `helm upgrade` (all OSes, #426); error-surface quality present in bash (`spin_cmd` log tails) but absent on Windows (#423); a Windows-only infinite spinner (#412).
- **The drift is structural, not carelessness.** Bash is exercised by a 9-distro prerequisite matrix and real-k3d e2e jobs on every push; the PowerShell installer gets **mocked Pester only**, because GitHub's `windows-latest` runners cannot nest virtualization. A behavior can regress or never be ported on Windows and CI stays green. Windows lags because nothing forces it not to.

Fixing one user-visible defect currently costs up to three implementations, three reviews, and three test suites — and in practice the second and third copies arrive late or never.

## 2. Proposed decisions

**D1 — The Linux bash core is *the* implementation of installer behavior.** Preflight, tool acquisition, cluster lifecycle, provisioning, diagnosis: one implementation, in the code path that already has the deepest hardening and the only real e2e coverage.

**D2 — OS adapters are thin and do only what is genuinely OS-specific** (gated, see §4):
- *macOS (exists today):* keep `setup-macos.sh` as the adapter, but consolidate its brew shortcuts into the shared verified-download path (tracebloc/client#429) so core behaviors aren't forked.
- *Windows (the big move):* replace the PowerShell monolith with a **WSL2 bootstrap adapter** — elevation, WSL provisioning (Store-blocked fallbacks), `.wslconfig` sizing, daily-user provisioning, autostart, reboot-resume — which then runs the **bash core inside WSL2**. This is the direction tracebloc/backend#1179 already states: *inside WSL2 the environment is Linux; prefer rootless Docker in WSL over Docker Desktop.* It also removes the Docker Desktop dependency and its commercial-licensing requirement for >250-employee organizations — i.e., effectively every hospital system we target.
- **Gate:** the `RFC-CLIENT-0001` validation experiments must pass *inside WSL2 on representative managed Windows hardware* (corporate AV, proxies, kernel restrictions). Until that spike is green, the PowerShell installer remains the supported Windows path.

**D3 — Single-source the facts now, regardless of D2.** One machine-readable spec (versions + checksums, external-host manifest, timeout budgets, memory floors/recommendations) consumed by both installers; the copy catalog already proves this pattern for user-facing strings. Extend the existing drift-check so a fact that changes in one consumer and not the other fails CI. Tracked as a new epic child.

**D4 — Parity becomes a CI gate, not a memory.** A behavior-parity matrix (feature × OS, with explicit waiver entries for deliberate differences) checked in CI. New behaviors land with either all implementations or a waiver + follow-up ticket. Tracked with D3.

**D5 — Windows gets a real e2e leg in every branch of this decision** (scheduled Windows VM or self-hosted runner running the actual installer end-to-end). Without it, whichever Windows path we keep will structurally lag again. Tracked as a new epic child.

**Interim rule (until the D2 gate resolves):** Wave-1/2 correctness fixes to the PowerShell installer proceed — hospital installs are happening now and the transition period needs a working Docker Desktop path regardless. But **no new large PS-only subsystems**: the test case is tracebloc/client#420 (resume/state engine) — build the Windows-native version only if D2 is rejected; otherwise resume logic belongs in the adapter + core.

## 3. Options considered

| # | Option | Verdict |
|---|--------|---------|
| 1 | Status quo + discipline (facts spec, parity gate) | **Adopt as D3/D4** — necessary in every branch, insufficient alone |
| 2 | Windows = WSL2 bootstrap + bash core inside WSL | **Adopt as D2, gated** on the rootless-in-WSL spike |
| 3 | Go CLI becomes the installer brain (`tracebloc env up`) | **Deferred end-state candidate** — revisit by RFC after D2 ships; the CLI already owns provisioning, doctor, prepare-host, and a styled UI, so D2 moves us toward it, not away |
| 4 | One scripting runtime everywhere (pwsh everywhere / bash on Windows without WSL) | Rejected — bootstrap chicken-and-egg on every OS |
| 5 | Big-bang unified rewrite now | Rejected — 25 open children and live hospital deployments; rewrite risk exceeds duplication cost today |

## 4. Consequences, risks, fallback

- **Epic mapping:** Wave-1/2 children proceed unchanged except tracebloc/client#420 (gated per the interim rule). tracebloc/client#429 becomes a D2 prerequisite (macOS consolidation proves the adapter model). D3/D4/D5 are new children on tracebloc/backend#1285.
- **Risk — the WSL spike fails** on managed hospital hardware: fallback is the hardened Docker Desktop path, which is exactly the Wave-1/2 work; nothing is wasted.
- **Risk — WSL2 itself is blocked by policy** on some enterprise fleets: the adapter keeps a Docker Desktop escape hatch until field data says it can go.
- **Risk — two paths during transition:** bounded by D3/D4 (shared facts + parity gate) and by the interim rule freezing PS-side growth.

## 5. Non-goals

- Choosing the end-state orchestrator (Go CLI vs bash core) — separate RFC after D2.
- Changing the R8 supply-chain model (signed manifest bootstrap) — both adapters keep it.
- Kubernetes-distribution or Helm-chart changes — this is install-path architecture only.
