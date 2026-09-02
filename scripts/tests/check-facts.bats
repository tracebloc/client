#!/usr/bin/env bats
# check-facts.sh (#435): scripts/spec/facts.env is the single source of truth for
# cross-OS installer facts (tool version pins), stamped into every consumer (bash
# common.sh, PowerShell install-k8s.ps1). --check is the CI gate that makes the #410
# incident — a pin bumped in one OS path but not the other — a red check. These tests
# run the REAL script against a throwaway repo copy so a bad pattern can't pass silently.
load test_helper

setup() {
  CF="${SCRIPTS_DIR}/check-facts.sh"
  # A minimal throwaway repo the script operates on via DRIFT-free cwd. check-facts.sh
  # resolves paths relative to its own location, so run the copied tree's script.
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/scripts/spec" "$REPO/scripts/lib"
  cp "$CF" "$REPO/scripts/check-facts.sh"
  cp "${SCRIPTS_DIR}/spec/facts.env" "$REPO/scripts/spec/facts.env"
  # Consumers seeded FROM THE COPIED SPEC, not from literals. The literals were a
  # second copy of every pin: when backend#2448 moved K8S_VERSION 1.29.4 -> 1.36.3
  # this whole suite went red, because the fixture disagreed with the spec it had
  # just copied. Deriving them means a pin bump can never break these tests again —
  # which is the same property check-facts.sh itself exists to enforce.
  #
  # Heredocs stay QUOTED (the bodies contain ${K8S_VERSION:-…}, which must survive
  # verbatim), so the values go in as @@TOKENS@@ and are substituted afterwards.
  local _k8s _k3d _helm _cuda _ready _metrics
  _k8s="$(sed -n 's/^K8S_VERSION=\(.*\)$/\1/p'          "$REPO/scripts/spec/facts.env")"
  _k3d="$(sed -n 's/^K3D_VERSION=\(.*\)$/\1/p'          "$REPO/scripts/spec/facts.env")"
  _helm="$(sed -n 's/^HELM_VERSION=\(.*\)$/\1/p'        "$REPO/scripts/spec/facts.env")"
  _cuda="$(sed -n 's/^CUDA_TAG=\(.*\)$/\1/p'            "$REPO/scripts/spec/facts.env")"
  _ready="$(sed -n 's/^READY_TIMEOUT=\(.*\)$/\1/p'      "$REPO/scripts/spec/facts.env")"
  _metrics="$(sed -n 's/^METRICS_WAIT_TIMEOUT=\(.*\)$/\1/p' "$REPO/scripts/spec/facts.env")"
  # Fail closed: a spec we cannot read must not seed empty consumers that then
  # "agree" with an empty expectation.
  [[ -n "$_k8s" && -n "$_k3d" && -n "$_helm" && -n "$_cuda" && -n "$_ready" && -n "$_metrics" ]] \
    || { echo "could not derive facts from the copied spec"; return 1; }
  cat > "$REPO/scripts/lib/common.sh" <<'SH'
K8S_VERSION="${K8S_VERSION:-@@K8S@@}"
TB_CUDA_BASE_TAG="${TRACEBLOC_CUDA_BASE_TAG:-@@CUDA@@}"
K3D_VERSION="${K3D_VERSION:-@@K3D@@}"
HELM_VERSION="${HELM_VERSION:-@@HELM@@}"
  K8S_VERSION    k3s image tag                   (default: @@K8S@@)
SH
  cat > "$REPO/scripts/install-k8s.ps1" <<'PS'
$script:K3dVersion  = if ($env:K3D_VERSION)  { $env:K3D_VERSION }  else { "@@K3D@@" }
$script:HelmVersion = if ($env:HELM_VERSION) { $env:HELM_VERSION } else { "@@HELM@@" }
$K8S_VERSION   = if ($env:K8S_VERSION)   { $env:K8S_VERSION }   else { "@@K8S@@" }
$CUDA_BASE_TAG  = if ($env:TRACEBLOC_CUDA_BASE_TAG) { $env:TRACEBLOC_CUDA_BASE_TAG } else { "@@CUDA@@" }
$ReadyTimeout     = if ($env:READY_TIMEOUT) { $env:READY_TIMEOUT } else { "@@READY@@" }
$script:MetricsWaitTimeout = @@METRICS@@
$k3dArgs += @("--image", "rancher/k3s:$K8S_VERSION")
$cudaRepo = "tracebloc/k3s-cuda:$K8S_VERSION-cuda-$CUDA_BASE_TAG"
  K8S_VERSION    k3s image tag                   (default: @@K8S@@)
PS
  cat > "$REPO/scripts/lib/summary.sh" <<'SH'
READY_TIMEOUT="${READY_TIMEOUT:-@@READY@@}"
SH
  # #553: the metrics-server APIService wait budget is a cross-OS fact — bash reads it
  # here, PowerShell from $script:MetricsWaitTimeout, both behind TB_METRICS_WAIT_S.
  cat > "$REPO/scripts/lib/install-client-helm.sh" <<'SH'
METRICS_WAIT_TIMEOUT=@@METRICS@@
SH
  # backend#2448 added the HELP-TEXT default as its own consumer row in both
  # installers: it is the line the operator actually reads, and it used to be a
  # restate check-facts could not see (the pin moved in code while `--help` went on
  # advertising the old version). Seeded here so those rows have something to read.
  #
  # cluster.sh carries the create-time k3s --image pin the #547 wiring guard checks,
  # and (client#835) the GPU node-image derivation the #835 wiring guard checks.
  cat > "$REPO/scripts/lib/cluster.sh" <<'SH'
K3D_ARGS+=(--image "rancher/k3s:${K8S_VERSION}")
local repo="tracebloc/k3s-cuda:${K8S_VERSION}-cuda-${TB_CUDA_BASE_TAG}"
SH
  # #616: the GPU node image's k3s pin lives in the Dockerfile ARG, build.sh, and the
  # workflow input default — all check-facts consumers of K8S_VERSION. Seed them to
  # match the spec so a bump can't leave a GPU image tag that was never published.
  mkdir -p "$REPO/docker/k3s-cuda" "$REPO/.github/workflows"
  cat > "$REPO/docker/k3s-cuda/Dockerfile" <<'DF'
ARG K3S_TAG="@@K8S@@"
ARG CUDA_TAG="@@CUDA@@"
DF
  cat > "$REPO/docker/k3s-cuda/build.sh" <<'SH'
K3S_TAG="${K3S_TAG:-@@K8S@@}"
CUDA_TAG="${CUDA_TAG:-@@CUDA@@}"
SH
  # Two defaults on purpose: the extractor must pick the k3s_tag one (v… tag) and
  # leave the cuda_tag default (12.4.1…) alone.
  cat > "$REPO/.github/workflows/build-k3s-cuda.yaml" <<'YML'
      k3s_tag:
        default: "@@K8S@@"
      cuda_tag:
        default: "@@CUDA@@"
YML

  # One substitution pass over every seeded consumer.
  SEEDED=( "$REPO/scripts/lib/common.sh" "$REPO/scripts/install-k8s.ps1"
           "$REPO/scripts/lib/summary.sh" "$REPO/scripts/lib/install-client-helm.sh"
           "$REPO/scripts/lib/cluster.sh" "$REPO/docker/k3s-cuda/Dockerfile"
           "$REPO/docker/k3s-cuda/build.sh" "$REPO/.github/workflows/build-k3s-cuda.yaml" )
  local f
  for f in "${SEEDED[@]}"; do
    local tmp; tmp="$(mktemp)"
    sed -e "s|@@K8S@@|${_k8s}|g"   -e "s|@@K3D@@|${_k3d}|g" \
        -e "s|@@HELM@@|${_helm}|g" -e "s|@@CUDA@@|${_cuda}|g" \
        -e "s|@@READY@@|${_ready}|g" -e "s|@@METRICS@@|${_metrics}|g" "$f" > "$tmp" && mv "$tmp" "$f"
  done
  # Nothing may be left unsubstituted, or a consumer would "match" a token instead
  # of a value. Scoped to the SEEDED files: a repo-wide grep also matches the
  # copied check-facts.sh, whose own --write sed programs legitimately contain
  # @@VAL@@ — which is a false positive that fails every test in setup.
  ! grep -l '@@' "${SEEDED[@]}" >/dev/null 2>&1 \
    || { echo "unsubstituted token left in: $(grep -l '@@' "${SEEDED[@]}" | tr '\n' ' ')"; return 1; }

  # Exported for the drift tests below, so they mutate the value the spec actually
  # declares rather than a literal of their own.
  SEED_K8S="$_k8s"; SEED_K3D="$_k3d"
}

_facts() { bash "$REPO/scripts/check-facts.sh" "$@"; }
_set_spec() { local tmp; tmp="$(mktemp)"; sed "s|^$1=.*|$1=$2|" "$REPO/scripts/spec/facts.env" > "$tmp" && mv "$tmp" "$REPO/scripts/spec/facts.env"; }

@test "check-facts --check: all consumers match the spec -> passes (#435)" {
  run _facts --check
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"all installer facts match"* ]] || return 1
}

@test "check-facts --check: K8S_VERSION drift in PowerShell (not just bash) -> RED (#435 Bugbot)" {
  # install-k8s.ps1 pins K8S_VERSION too (--image rancher/k3s:$K8S_VERSION), so the spec
  # must enforce it in BOTH consumers — bumping bash alone can't leave Windows stale.
  local tmp; tmp="$(mktemp)"
  sed "s|\"${SEED_K8S}\"|\"v0.0.1-k3s1\"|" "$REPO/scripts/install-k8s.ps1" > "$tmp" && mv "$tmp" "$REPO/scripts/install-k8s.ps1"
  run _facts --check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"install-k8s.ps1:K8S_VERSION"* ]] || return 1
}

@test "check-facts --write: a K8S_VERSION bump stamps BOTH bash and PowerShell (#435 Bugbot)" {
  _set_spec K8S_VERSION v1.31.0-k3s1
  _facts --write
  grep -q 'K8S_VERSION="${K8S_VERSION:-v1.31.0-k3s1}"' "$REPO/scripts/lib/common.sh"   # bash
  grep -q 'else { "v1.31.0-k3s1" }' "$REPO/scripts/install-k8s.ps1"                     # PowerShell
  run _facts --check; [ "$status" -eq 0 ] || return 1
}

@test "check-facts --check: #410 incident — bash pin bumped, PowerShell NOT -> RED (#435)" {
  # Simulate the real #410: someone bumps K3D in common.sh but forgets install-k8s.ps1.
  # The spec is authoritative, so BOTH the bumped bash and the stale ps1 must be caught.
  local tmp; tmp="$(mktemp)"
  sed "s|${SEED_K3D}|v0.0.1|" "$REPO/scripts/lib/common.sh" > "$tmp" && mv "$tmp" "$REPO/scripts/lib/common.sh"
  run _facts --check
  [ "$status" -ne 0 ] || return 1   # red CI check
  [[ "$output" == *"common.sh:K3D_VERSION"* ]] || return 1
  [[ "$output" == *"drifted"* ]] || return 1
}

@test "check-facts --check: PowerShell pin drifts from bash+spec -> RED (#435)" {
  local tmp; tmp="$(mktemp)"
  sed "s|\"${SEED_K3D}\"|\"v0.0.1\"|" "$REPO/scripts/install-k8s.ps1" > "$tmp" && mv "$tmp" "$REPO/scripts/install-k8s.ps1"
  run _facts --check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"install-k8s.ps1:K3dVersion"* ]] || return 1
}

@test "check-facts --write: bumping the spec stamps EVERY consumer, then --check passes (#435)" {
  _set_spec K3D_VERSION v9.9.9
  run _facts --write
  [ "$status" -eq 0 ] || return 1
  grep -q 'K3D_VERSION="${K3D_VERSION:-v9.9.9}"' "$REPO/scripts/lib/common.sh"          # bash stamped
  grep -q 'else { "v9.9.9" }' "$REPO/scripts/install-k8s.ps1"                            # PowerShell stamped
  run _facts --check                                                                     # now consistent
  [ "$status" -eq 0 ] || return 1
}

@test "check-facts --write: HELM + K8S bumps stamp their consumers (#435)" {
  _set_spec HELM_VERSION v5.0.0
  _set_spec K8S_VERSION v1.30.0-k3s1
  _facts --write
  grep -q 'HELM_VERSION="${HELM_VERSION:-v5.0.0}"' "$REPO/scripts/lib/common.sh"
  grep -q 'else { "v5.0.0" }' "$REPO/scripts/install-k8s.ps1"
  grep -q 'K8S_VERSION="${K8S_VERSION:-v1.30.0-k3s1}"' "$REPO/scripts/lib/common.sh"
  run _facts --check; [ "$status" -eq 0 ] || return 1
}

@test "check-facts --check: READY_TIMEOUT (a real timeout budget) drift in ps1 -> RED (#435)" {
  # Consumers seed READY_TIMEOUT at the spec default (600, #562). Push ps1 to a WRONG
  # value so the gate must report ReadyTimeout drift — bumping bash alone (or the spec)
  # can't leave the Windows timeout budget stale.
  local tmp; tmp="$(mktemp)"
  sed 's|"600"|"900"|' "$REPO/scripts/install-k8s.ps1" > "$tmp" && mv "$tmp" "$REPO/scripts/install-k8s.ps1"
  run _facts --check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"install-k8s.ps1:ReadyTimeout"* ]] || return 1
}

@test "check-facts --write: bumping the READY_TIMEOUT budget stamps bash + PowerShell (#435)" {
  # Consumers seed at the current default (600, #562); bump the spec to a fresh value so
  # --write must actually restamp both the bash (summary.sh) and PowerShell budgets.
  _set_spec READY_TIMEOUT 900
  _facts --write
  grep -q 'READY_TIMEOUT="${READY_TIMEOUT:-900}"' "$REPO/scripts/lib/summary.sh"   # bash consumer
  grep -q 'else { "900" }' "$REPO/scripts/install-k8s.ps1"                          # PowerShell consumer
  run _facts --check; [ "$status" -eq 0 ] || return 1
}

@test "check-facts: a missing pattern (consumer refactored away) fails closed, not silently green (#435)" {
  echo "# no k3d pin here anymore" > "$REPO/scripts/lib/common.sh"
  run _facts --check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"no pinned value found"* ]] || return 1
}

@test "check-facts: an unknown mode is rejected (#435)" {
  run _facts --bogus
  [ "$status" -eq 2 ] || return 1
}

# --- pipefail + `sed | head -1` SIGPIPE regressions (#542 Bugbot) -----------
# Both helpers used to pipe `sed … | head -1` under `set -o pipefail`: on a second
# match large enough to fill the ~64KB pipe buffer, head closes after line 1, sed takes
# SIGPIPE, and the pipeline exits 141. In `_extract` the pipeline is the function's
# terminal command, so that 141 propagates out of `got="$(_extract …)"` and aborts the
# facts gate BEFORE any drift message prints (a crash / fail-open on duplicate input) —
# the test below reproduced exactly that on the pre-fix code. In `_spec_get` a trailing
# `printf` masked the pipeline status on some shells, so it did not always abort there,
# but the same fragile pipe was present. The fix removes both pipes: capture the whole
# output, take the first line with `${all%%$'\n'*}`. Each test feeds enough duplicate
# matches to trip the old pipe; the first value still equals the spec, so --check passes.

@test "check-facts --check: a duplicated spec key returns the first value, no SIGPIPE (#542 Bugbot)" {
  # A second (identical) K3D_VERSION= line in facts.env, repeated past the pipe buffer.
  # Locks the contract that _spec_get yields the FIRST value and never aborts the gate —
  # even if a future edit drops the trailing printf that masked the old pipe's exit code.
  { i=0; while [ "$i" -lt 20000 ]; do echo "K3D_VERSION=v5.9.0"; i=$((i + 1)); done; } >> "$REPO/scripts/spec/facts.env"
  run _facts --check
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"all installer facts match"* ]] || return 1
}

@test "check-facts --check: a duplicated consumer pin does not SIGPIPE _extract (#542 Bugbot)" {
  # Many identical K3D_VERSION default lines in common.sh — each matches the extractor,
  # so the old `sed | head -1` in _extract exited 141 (verified against the pre-fix code)
  # and aborted the gate. The first line still equals the spec, so drift is zero.
  { i=0; while [ "$i" -lt 20000 ]; do echo 'K3D_VERSION="${K3D_VERSION:-v5.9.0}"'; i=$((i + 1)); done; } >> "$REPO/scripts/lib/common.sh"
  run _facts --check
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"all installer facts match"* ]] || return 1
}

@test "check-facts --check: a missing create-time --image pin fails with a WIRING message, not the --write hint (#547 / Bugbot)" {
  # versions all still correct, but strip the k3s --image wiring from cluster.sh
  printf '%s\n' '# stub without the k3s --image pin' > "$REPO/scripts/lib/cluster.sh"
  run _facts --check
  [ "$status" -ne 0 ] || return 1
  # must NOT point the dev at --write (it cannot restore create-time wiring)
  if printf '%s\n' "$output" | grep -qF "Run 'scripts/check-facts.sh --write'"; then
    echo "unexpected --write hint for a wiring failure:" >&2; printf '%s\n' "$output" >&2; return 1
  fi
  # must name it as a wiring gap with the hand-fix
  printf '%s\n' "$output" | grep -qF "WIRING gap"
  printf '%s\n' "$output" | grep -qF "cannot fix it"
  # the hand-fix hint must name BOTH shell forms — PS uses no braces (#565 Bugbot).
  # The message covers the k3s pin AND the GPU node image (#835), so it names the
  # shared ${K8S_VERSION} token rather than the rancher/k3s: literal specifically.
  printf '%s\n' "$output" | grep -qF '${K8S_VERSION}'
  printf '%s\n' "$output" | grep -qF '$K8S_VERSION'
}

# --- --check-published: the registry half of the GPU-image guard (backend#3007) ---
# The fact table proves the four GPU-image DECLARATIONS agree; --check-published
# asks ghcr.io whether the tag they all derive was actually PUBLISHED. #3007: on
# 2026-08-24 the k3s pin moved 17 days after the image was last built, so every GPU
# install derived a 404 tag and SILENTLY fell back to CPU while this check stayed
# green. TB_REGISTRY_PROBE_STUB replaces the network (mirrors check-digest-drift's
# DRIFT_RESOLVE_STUB) so classification is asserted offline. Because the stub only
# answers for the EXACT derived ref, these also prove the derivation matches the
# installers — and, like setup(), they recompute that ref FROM the copied spec so a
# pin bump can never break them.

# The GPU image ref check-facts must derive, recomputed from the COPIED spec.
_expected_gpu_ref() {
  local k8s cuda
  k8s="$(sed -n 's/^K8S_VERSION=\(.*\)$/\1/p' "$REPO/scripts/spec/facts.env")"
  cuda="$(sed -n 's/^CUDA_TAG=\(.*\)$/\1/p'   "$REPO/scripts/spec/facts.env")"
  [[ -n "$k8s" && -n "$cuda" ]] || { echo "could not derive the GPU ref from the copied spec"; return 1; }
  printf 'ghcr.io/tracebloc/k3s-cuda:%s-cuda-%s' "$k8s" "$cuda"
}
# Write a  <ref><0x1f><status>  stub file and echo its path.
_probe_stub() {
  local ref="$1" status="$2" f="$BATS_TEST_TMPDIR/probe-stub"
  printf '%s\037%s\n' "$ref" "$status" > "$f"
  printf '%s' "$f"
}

@test "check-facts --check-published: a published tag (HTTP 200) -> pass, names the ref (backend#3007)" {
  local ref; ref="$(_expected_gpu_ref)"
  TB_REGISTRY_PROBE_STUB="$(_probe_stub "$ref" 200)" run _facts --check-published
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"is published"* ]] || return 1
  [[ "$output" == *"$ref"* ]] || return 1
}

@test "check-facts --check-published: a 404 is a HARD finding -> exit 1, names the silent-CPU consequence (backend#3007)" {
  local ref; ref="$(_expected_gpu_ref)"
  TB_REGISTRY_PROBE_STUB="$(_probe_stub "$ref" 404)" run _facts --check-published
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"NOT PUBLISHED"* ]] || return 1
  [[ "$output" == *"CPU"* ]] || return 1
}

@test "check-facts --check-published: an unreachable registry is CANNOT TELL -> exit 3, NOT collapsed into 404 (backend#3007)" {
  local ref; ref="$(_expected_gpu_ref)"
  TB_REGISTRY_PROBE_STUB="$(_probe_stub "$ref" 000)" run _facts --check-published
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  [[ "$output" == *"CANNOT TELL"* ]] || return 1
  [[ "$output" != *"NOT PUBLISHED"* ]] || return 1
}

@test "check-facts --check-published: 429 / 5xx / 401 are CANNOT TELL, never a false 404 (backend#3007)" {
  local ref; ref="$(_expected_gpu_ref)"
  local code
  for code in 429 503 401; do
    TB_REGISTRY_PROBE_STUB="$(_probe_stub "$ref" "$code")" run _facts --check-published
    [ "$status" -eq 3 ] || { echo "HTTP $code -> exit $status"; echo "$output"; return 1; }
    [[ "$output" == *"CANNOT TELL"* ]] || return 1
    [[ "$output" != *"NOT PUBLISHED"* ]] || return 1
  done
}

@test "check-facts --check-published: probes the EXACTLY derived ref — a wrong derivation misses the stub (backend#3007)" {
  # Stub answers 200 only for a DIFFERENT ref; the real derived ref is absent, so
  # the probe returns 000 -> CANNOT TELL. Proves the check asks about the ref the
  # installers actually pull, not some other string.
  TB_REGISTRY_PROBE_STUB="$(_probe_stub "ghcr.io/tracebloc/k3s-cuda:v0.0.0-cuda-wrong" 200)" run _facts --check-published
  [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  [[ "$output" == *"CANNOT TELL"* ]] || return 1
}

@test "check-facts --check-published: the derived ref tracks a K8S_VERSION bump (backend#3007)" {
  # Bump the spec; the ref the check probes must move with it — no second copy of
  # the pin. Stub the bumped ref as 200 and the OLD ref would no longer match.
  _set_spec K8S_VERSION v1.99.0-k3s1
  local ref; ref="$(_expected_gpu_ref)"
  [[ "$ref" == *"v1.99.0-k3s1-cuda-"* ]] || { echo "ref did not track the bump: $ref"; return 1; }
  TB_REGISTRY_PROBE_STUB="$(_probe_stub "$ref" 200)" run _facts --check-published
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"v1.99.0-k3s1-cuda-"* ]] || return 1
}

@test "check-facts --check-published: a missing spec key fails CLOSED (exit 2), never a misleading 404 (backend#3007)" {
  # Blank CUDA_TAG. _gpu_image_ref must abort with the spec error, not print a
  # malformed ref (…:-cuda-…) that then 404s — reporting a spec bug as a missing
  # image is the "blame the wrong cause" sin this mode exists to avoid. Stub is set
  # so a regression cannot reach the network; it must never be consulted.
  _set_spec CUDA_TAG ""
  TB_REGISTRY_PROBE_STUB="$(_probe_stub "ghcr.io/whatever:x" 200)" run _facts --check-published
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  [[ "$output" == *"missing from"* ]] || return 1
  [[ "$output" != *"NOT PUBLISHED"* ]] || return 1
  [[ "$output" != *"CANNOT TELL"* ]] || return 1
}
