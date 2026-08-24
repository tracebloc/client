#!/usr/bin/env bats
# Tests for scripts/lib/install-client-helm.sh — credential verification (#717)
# + the install_client_helm flow.
load test_helper

setup() {
  load_lib install-client-helm.sh
  MOCK_CALLS="$(mktemp)"
  GPU_VENDOR=none
  CLIENT_ENV=""
  # Interactive credential reads come from TB_TTY (the controlling terminal in
  # production, so prompts survive `curl … | bash`). Point it at stdin so the
  # tests below can feed canned input via a heredoc.
  export TB_TTY=/dev/stdin
  # A proxy inherited from the CI runner would otherwise leak proxy keys into
  # the generated values.yaml and make the proxy assertions non-deterministic.
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
  # Skip the live image-pull count bar: kubectl is mocked here and its poll loop
  # would otherwise spin against fake output. The bar is cosmetic + covered by
  # its own reasoning; the readiness gate (summary.bats) is the real contract.
  export TB_NO_SERVICE_PROGRESS=1
  # THE HOST IS AN INPUT, SO DECLARE IT (backend#2208). install_client_helm calls
  # _assert_engine_runs_on_this_arch, which since client#756 probes the real
  # machine: `uname -m`, and on Darwin a live Rosetta/Docker smoke. Nothing here
  # set OS or ARCH, so any flow test whose helm mock reports an EXISTING release
  # — the one path that resolves the engine to 5.7 and therefore engages the gate
  # — inherited the developer's CPU and refused on an Apple Silicon Mac, while CI
  # (Linux/amd64) returned early at the arch check and stayed green. Three
  # reconcile tests failed that way for every Mac developer and CI could not see
  # it, because the platform the gate exists for is the one CI never runs.
  #
  # Pin to what CI is, so a local run reproduces CI. This does NOT disarm the
  # gate — TRACEBLOC_ALLOW_ARM64 would, which is exactly why it is not used here:
  # it would switch off the behaviour client#756 added. Every arch-sensitive test
  # in this file sets OS/ARCH for itself (see _arch_gate_ctx and the engine
  # tests), so they override this and keep testing the real rule.
  OS=Linux
  ARCH=x86_64
}

# ── _backend_url ───────────────────────────────────────────────────────────
@test "_backend_url: default (unset) -> prod" {
  unset CLIENT_ENV
  run _backend_url
  [ "$output" = "https://api.tracebloc.io/" ] || return 1
}

@test "_backend_url: dev" {
  CLIENT_ENV=dev
  run _backend_url
  [ "$output" = "https://dev-api.tracebloc.io/" ] || return 1
}

@test "_backend_url: stg" {
  CLIENT_ENV=stg
  run _backend_url
  [ "$output" = "https://stg-api.tracebloc.io/" ] || return 1
}

# THE ALIASES. values.schema.json documents development|staging|production as
# accepted, and the old case knew only dev|stg — so `staging` fell to the `*)`
# branch and verify_credentials() checked STAGING credentials against the
# PRODUCTION backend, telling the customer their correct credentials were wrong
# (backend#1745). The suite covered dev, stg, unset and "whatever"; it never
# covered the spellings the docs tell people to use.
@test "_backend_url: staging alias -> stg backend, NOT prod" {
  CLIENT_ENV=staging
  run _backend_url
  [ "$output" = "https://stg-api.tracebloc.io/" ] || return 1
}

@test "_backend_url: development alias -> dev backend" {
  CLIENT_ENV=development
  run _backend_url
  [ "$output" = "https://dev-api.tracebloc.io/" ] || return 1
}

@test "_backend_url: production alias -> prod backend" {
  CLIENT_ENV=production
  run _backend_url
  [ "$output" = "https://api.tracebloc.io/" ] || return 1
}

@test "tb_client_env: reduces aliases and passes anything else through" {
  # Pass-through matters: this normalises spellings, it does not validate, and
  # each caller keeps its own fallback for genuinely unrecognised input.
  [ "$(tb_client_env staging)" = "stg" ] || return 1
  [ "$(tb_client_env development)" = "dev" ] || return 1
  [ "$(tb_client_env production)" = "prod" ] || return 1
  [ "$(tb_client_env stg)" = "stg" ] || return 1
  [ "$(tb_client_env whatever)" = "whatever" ] || return 1
}

@test "_backend_url: unknown -> prod" {
  CLIENT_ENV=whatever
  run _backend_url
  [ "$output" = "https://api.tracebloc.io/" ] || return 1
}

# ── verify_credentials (mock curl's http_code on stdout) ───────────────────
@test "verify_credentials: HTTP 200 -> valid" {
  curl() { echo 200; }
  run verify_credentials id pw
  [ "$output" = valid ] || return 1
}

@test "verify_credentials: HTTP 400 -> invalid" {
  curl() { echo 400; }
  run verify_credentials id pw
  [ "$output" = invalid ] || return 1
}

@test "verify_credentials: HTTP 401 -> inactive" {
  curl() { echo 401; }
  run verify_credentials id pw
  [ "$output" = inactive ] || return 1
}

@test "verify_credentials: HTTP 429 -> unverified" {
  curl() { echo 429; }
  run verify_credentials id pw
  [ "$output" = unverified ] || return 1
}

@test "verify_credentials: connection failure -> unverified" {
  curl() { return 7; }
  run verify_credentials id pw
  [ "$output" = unverified ] || return 1
}

# ── sanitizers ─────────────────────────────────────────────────────────────
@test "_strip_paste_garbage: unwraps bracketed-paste ESC markers" {
  run _strip_paste_garbage "$(printf '\e[200~secret\e[201~')"
  [ "$output" = "secret" ] || return 1
}

@test "_strip_paste_garbage: strips C0 control chars, keeps text" {
  run _strip_paste_garbage "$(printf 'ab\001cd')"
  [ "$output" = "abcd" ] || return 1
}

# ── SS3 (cli#516) ──────────────────────────────────────────────────────────
# The CSI-only strip landed 2026-07-21 (client#362 / cli#364) and is not in
# question here. SS3 — ESC 'O' <final> — is what the SAME keys emit once the
# terminal is in DECCKM application-cursor mode, the state vim/less/tmux leave
# behind on an unclean exit. It was worse than the CSI case it was missed
# alongside: CSI residue cleans to empty and re-prompts, while ESC OD ESC OA
# left the non-empty, plausible "ODOA" and minted a permanent namespace.
@test "_strip_paste_garbage: strips SS3 escapes around real content" {
  run _strip_paste_garbage "$(printf 'na\eODme')"
  [ "$output" = "name" ] || return 1
}

@test "_strip_paste_garbage: SS3 arrows only -> empty (caller re-prompts)" {
  run _strip_paste_garbage "$(printf '\eOD\eOD\eOD\eOA\eOA\eOA')"
  [ "$output" = "" ] || return 1
}

@test "_strip_paste_garbage: SS3 Home/End and F1/F2 -> empty" {
  run _strip_paste_garbage "$(printf '\eOH\eOF')"
  [ "$output" = "" ] || return 1
  run _strip_paste_garbage "$(printf '\eOP\eOQ')"
  [ "$output" = "" ] || return 1
}

@test "_strip_paste_garbage: SS3 and CSI mixed in one value" {
  run _strip_paste_garbage "$(printf 'a\eODb\e[Dc')"
  [ "$output" = "abc" ] || return 1
}

@test "_strip_paste_garbage: a bare O is not an escape" {
  run _strip_paste_garbage "OPTIMUS-01"
  [ "$output" = "OPTIMUS-01" ] || return 1
}

# ── the post-sanitise floor ────────────────────────────────────────────────
# An ESC that SURVIVES the strip means an escape family this helper does not
# know — which is exactly how SS3 got here. SS2 (ESC 'N' <final>) stands in for
# "the next family": it is not stripped above, so these exercise the floor and
# nothing else.
@test "_strip_paste_garbage: unknown escape family, residue only -> empty" {
  run _strip_paste_garbage "$(printf '\eNB\eNC')"
  [ "$output" = "" ] || return 1
}

@test "_strip_paste_garbage: unknown escape family beside real content is kept" {
  run _strip_paste_garbage "$(printf 'box\eNC')"
  [ "$output" = "boxNC" ] || return 1
}

@test "_strip_paste_garbage: the floor counts non-Latin letters as real content" {
  run _strip_paste_garbage "$(printf '\eNC日本')"
  [ "$output" = "NC日本" ] || return 1
}

# The probe's final-byte run is bounded at two, so an ASCII name after an unknown
# escape is kept just like a non-Latin one. Keep-vs-reject must not depend on the
# script the name is written in — with an unbounded `+` the whole word was
# swallowed and this input was refused while the 日本 case above was not (Bugbot).
@test "_strip_paste_garbage: the floor keeps an ASCII name after an unknown escape" {
  run _strip_paste_garbage "$(printf '\eNChello')"
  [ "$output" = "NChello" ] || return 1
}

@test "_strip_paste_garbage: truncated SS3 (ESC O, no final) -> empty" {
  run _strip_paste_garbage "$(printf '\eO')"
  [ "$output" = "" ] || return 1
}

# ESC [ ; ] A is the shape that made the floor's first draft HANG, and it is why
# the floor uses one sed pass rather than the `while [[ =~ ]]; do
# s="${s/${BASH_REMATCH[0]}/}"; done` loop the strip above uses. Pattern
# substitution treats BASH_REMATCH as a GLOB: the residue regex matches
# ESC [ ; ] A whole, but the glob `<ESC>[;]A` means ESC ';' 'A' — not in the
# string — so the substitution removed nothing and the loop spun forever, at the
# installer's name prompt. (The CSI loop is safe by construction: its match can
# never contain a `]`, so it can never form a complete bracket expression.)
# Bounded like common.bats bounds its recursion guard — macOS ships no
# timeout(1), so Linux CI is the authority on the hang half.
@test "_strip_paste_garbage: ESC [ ; ] A terminates and is refused (glob-substitution hang)" {
  local _to=""
  command -v timeout  >/dev/null 2>&1 && _to=timeout
  command -v gtimeout >/dev/null 2>&1 && _to=gtimeout
  if [ -n "$_to" ]; then
    run "$_to" 10 bash -c 'source "$1/common.sh"; _strip_paste_garbage "$(printf "\e[;]A")"' _ "$LIB_DIR"
  else
    run bash -c 'source "$1/common.sh"; _strip_paste_garbage "$(printf "\e[;]A")"' _ "$LIB_DIR"
  fi
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "" ] || return 1
}

@test "_sanitize_workspace_name: lowercases + dashes" {
  run _sanitize_workspace_name "My Team_1"
  [ "$output" = "my-team-1" ] || return 1
}

@test "_sanitize_workspace_name: all-invalid -> default" {
  run _sanitize_workspace_name "@@@"
  [ "$output" = "default" ] || return 1
}

@test "_sanitize_workspace_name: collapses + trims dashes" {
  run _sanitize_workspace_name "a--b-"
  [ "$output" = "a-b" ] || return 1
}

# ── _extract_yaml_value ────────────────────────────────────────────────────
@test "_extract_yaml_value: double-quoted" {
  f="$BATS_TEST_TMPDIR/v"; printf 'clientId: "abc-123"\n' >"$f"
  run _extract_yaml_value "$f" clientId
  [ "$output" = "abc-123" ] || return 1
}

@test "_extract_yaml_value: single-quoted with '' escape" {
  f="$BATS_TEST_TMPDIR/v"; printf "clientPassword: 'a''b'\n" >"$f"
  run _extract_yaml_value "$f" clientPassword
  [ "$output" = "a'b" ] || return 1
}

@test "_extract_yaml_value: missing key -> empty" {
  f="$BATS_TEST_TMPDIR/v"; printf 'other: x\n' >"$f"
  run _extract_yaml_value "$f" clientId
  [ "$output" = "" ] || return 1
}

# The BARE-statement shape is the one that used to die (#523): on an absent key
# grep exits 1, `pipefail` carries that out of the assignment, and `set -e` kills
# the installer before the empty-check on the next line — the line that exists
# precisely to handle "key not found" — can run. Every call site wraps the
# function in `$( )` today, which suspends errexit for the body, so asserting
# those still work proves nothing about this. Exercise the bare call directly:
# under `set -e` a non-zero rc from it would abort, so reaching the sentinel IS
# the proof the not-found path is reachable.
@test "_extract_yaml_value: absent key under set -euo pipefail, bare call, does not abort (#523)" {
  f="$BATS_TEST_TMPDIR/v"; printf 'other: x\n' >"$f"
  run bash -c '
    set -euo pipefail
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/install-client-helm.sh"
    LOG_FILE=/dev/null
    _extract_yaml_value "'"$f"'" clientId
    echo "REACHED_NOT_FOUND_PATH"
  '
  [ "$status" -eq 0 ] || return 1
  # Sole output => the absent key emitted nothing, and execution continued.
  [ "$output" = "REACHED_NOT_FOUND_PATH" ] || return 1
}

# The first fix used `grep | head -1 || line=""`. On a DUPLICATE key, head
# exits after line one and SIGPIPEs grep (141); under pipefail the fallback
# then wiped the successfully captured value, so detect_installed_client could
# miss a clientId and fail open toward overwrite (Bugbot). The pipeline is gone
# — grep captures every match, the shell takes the first — so a duplicate key
# must yield the FIRST value, under the same bare-call errexit shape as above.
@test "_extract_yaml_value: duplicate key under set -euo pipefail keeps the first value (Bugbot #525)" {
  f="$BATS_TEST_TMPDIR/v"; printf 'clientId: "first"\nclientId: "second"\n' >"$f"
  run bash -c '
    set -euo pipefail
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/install-client-helm.sh"
    LOG_FILE=/dev/null
    _extract_yaml_value "'"$f"'" clientId
  '
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "first" ] || return 1
}

# ── _yaml_sq_escape / _yaml_sq_unescape (Saqlain review, #443) ──────────────
# The bash-3.2 portability rule lives in exactly these two helpers now, so both
# directions and their round-trip are pinned here.
@test "_yaml_sq_escape: doubles a quote (no stray backslash on bash 3.2)" {
  run _yaml_sq_escape "a'b"
  [ "$output" = "a''b" ] || return 1
}

@test "_yaml_sq_escape: leaves a quote-free value untouched" {
  run _yaml_sq_escape 'plain-uuid-123'
  [ "$output" = 'plain-uuid-123' ] || return 1
}

@test "_yaml_sq_unescape: collapses a doubled quote" {
  run _yaml_sq_unescape "a''b"
  [ "$output" = "a'b" ] || return 1
}

@test "_yaml_sq_escape then _yaml_sq_unescape round-trips quote-heavy values" {
  for v in "a'b" "'" "''" "it's a 'test'" "no-quotes"; do
    esc="$(_yaml_sq_escape "$v")"
    [ "$(_yaml_sq_unescape "$esc")" = "$v" ] || return 1
  done
}

# clientId used to be written raw into a DOUBLE-quoted scalar, so a `"` or `\`
# in it corrupted the values file. Both credentials now go through the escaper
# into single-quoted scalars, and must survive the write -> read round-trip.
@test "clientId survives a round-trip through a single-quoted scalar (quote in the value)" {
  f="$BATS_TEST_TMPDIR/v"
  raw="ab'cd"
  printf "clientId: '%s'\n" "$(_yaml_sq_escape "$raw")" >"$f"
  run _extract_yaml_value "$f" clientId
  [ "$output" = "$raw" ] || return 1
}

@test "a double-quote in clientId no longer breaks the scalar" {
  f="$BATS_TEST_TMPDIR/v"
  raw='ab"cd'
  printf "clientId: '%s'\n" "$(_yaml_sq_escape "$raw")" >"$f"
  # In a single-quoted YAML scalar a double quote is literal — no escaping needed,
  # and crucially it can no longer terminate the scalar early.
  run _extract_yaml_value "$f" clientId
  [ "$output" = "$raw" ] || return 1
}

@test "the generated values file quotes clientId with the escaper, not raw interpolation" {
  f="$BATS_TEST_DIRNAME/../lib/install-client-helm.sh"
  grep -qE "^clientId: '\\\$TB_CLIENT_ID_ESCAPED'" "$f"
  ! grep -qE '^clientId: "\$TB_CLIENT_ID"' "$f" || return 1
}

# ── _ensure_helm_runnable (happy path) ─────────────────────────────────────
@test "_ensure_helm_runnable: helm runs -> ok" {
  helm() { return 0; }
  run _ensure_helm_runnable
  [ "$status" -eq 0 ] || return 1
}

# ── install_client_helm: full flow with mocks ──────────────────────────────
@test "install_client_helm: valid creds -> writes values.yaml + runs helm" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Credentials verified"* ]] || return 1
  [[ "$output" == *"tracebloc installed"* ]] || return 1
  grep -q "clientId: 'myid'" "$HOST_DATA_DIR/values.yaml"
  grep -q "clientPassword: 'mypw'" "$HOST_DATA_DIR/values.yaml"
  # client-runtime#92: installer-provisioned k3d is a fixed single-host cluster,
  # so it declares SINGLE_NODE=true -> jobs-manager applies the hard CPU/GPU rule.
  grep -q 'SINGLE_NODE: "true"' "$HOST_DATA_DIR/values.yaml"
  mock_calls | grep -q "helm upgrade --install tracebloc"
}

# backend#743: when a dataset mount is provided, the generated values must point
# the dataset PV at /tracebloc-data and pass the host uid/gid so jobs-manager
# runs spawned ingestion pods as the owning user (NFS writes).
@test "install_client_helm: HOST_DATASET_DIR set -> values carry datasetPath + host uid/gid" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  HOST_DATASET_DIR="$BATS_TEST_TMPDIR/ds"; mkdir -p "$HOST_DATASET_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  grep -q 'datasetPath: /tracebloc-data' "$HOST_DATA_DIR/values.yaml"
  grep -qE 'HOST_UID: "[0-9]+"' "$HOST_DATA_DIR/values.yaml"
  grep -qE 'HOST_GID: "[0-9]+"' "$HOST_DATA_DIR/values.yaml"
}

@test "install_client_helm: HOST_DATASET_DIR unset -> no datasetPath / host uid (unchanged)" {
  unset HOST_DATASET_DIR
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  ! grep -q 'datasetPath:' "$HOST_DATA_DIR/values.yaml" || return 1
  ! grep -q 'HOST_UID:' "$HOST_DATA_DIR/values.yaml" || return 1
}

@test "install_client_helm: TRACEBLOC_CLIENT_* env -> non-interactive (no prompt), writes values.yaml + helm" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  export TRACEBLOC_CLIENT_ID=envid TRACEBLOC_CLIENT_PASSWORD=envpw
  run install_client_helm </dev/null    # no stdin: must not prompt
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Credentials verified"* ]] || return 1
  [[ "$output" != *"Client ID:"* ]] || return 1
  grep -q "clientId: 'envid'" "$HOST_DATA_DIR/values.yaml"
  grep -q "clientPassword: 'envpw'" "$HOST_DATA_DIR/values.yaml"
  mock_calls | grep -q "helm upgrade --install tracebloc"
}

@test "install_client_helm: adopted client with the UUID heals clientId + reconciles in place — no prompt, no verify" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  kubectl() { record "kubectl $*"; return 0; }
  # A live client release already occupies namespace 'munich'; helm advertises the
  # modern reuse flag.
  helm() {
    if [[ "$1" == list ]]; then echo "munich munich 1 now deployed client-1.8.2 1.8.2"; return 0; fi
    if [[ "$1 $2" == "upgrade --help" ]]; then echo "  --reset-then-reuse-values"; return 0; fi
    record "helm $*"; return 0
  }
  # verify_credentials must NOT be called on adopt (the existing credential stands).
  verify_credentials() { echo "VERIFY_CALLED"; printf invalid; }
  # Real CLI adopt: provision_client keeps the adopted client id (UUID) so Step 5 can
  # heal a cli#125-era numeric clientId on the existing release.
  export TRACEBLOC_CLIENT_ADOPTED=1 TRACEBLOC_CLIENT_ID=0e9db54e-c9c0-4bf3-9ff2-1646da307019
  run install_client_helm </dev/null              # no stdin: must not prompt
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"Client ID:"* ]] || return 1                # no credential prompt
  [[ "$output" != *"VERIFY_CALLED"* ]] || return 1             # no verify
  [[ "$output" == *"reconciling"* ]] || return 1
  [[ "$output" == *"tracebloc installed"* ]] || return 1
  # Reconciled the LIVE release in place (name 'munich') AND healed clientId to the
  # adopted UUID, reusing the stored password — NOT a fresh --install, no duplicate.
  mock_calls | grep -q "helm upgrade munich"
  mock_calls | grep -q -- "--reset-then-reuse-values"
  mock_calls | grep -q -- "--set clientId=0e9db54e-c9c0-4bf3-9ff2-1646da307019"
  run mock_calls
  [[ "$output" != *"helm upgrade --install"* ]] || return 1
}

@test "install_client_helm: adopt with NO client id (rebuilt host / R7) reconciles WITHOUT a heal — no prompt, no bail" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  kubectl() { record "kubectl $*"; return 0; }
  helm() {
    if [[ "$1" == list ]]; then echo "munich munich 1 now deployed client-1.8.2 1.8.2"; return 0; fi
    if [[ "$1 $2" == "upgrade --help" ]]; then echo "  --reset-then-reuse-values"; return 0; fi
    record "helm $*"; return 0
  }
  verify_credentials() { echo "VERIFY_CALLED"; printf invalid; }
  # Edge case: the marker is set but no adopted id was handed over (rebuilt host /
  # R7 orphan). Reconcile the LIVE release WITHOUT a heal — must not bail to a prompt.
  export TRACEBLOC_CLIENT_ADOPTED=1
  run install_client_helm </dev/null
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"Client ID:"* ]] || return 1                # no prompt (no bail)
  [[ "$output" != *"VERIFY_CALLED"* ]] || return 1             # no verify
  [[ "$output" == *"tracebloc installed"* ]] || return 1
  mock_calls | grep -q "helm upgrade munich"
  mock_calls | grep -q -- "--reset-then-reuse-values"
  run mock_calls
  [[ "$output" != *"helm upgrade --install"* ]] || return 1
  [[ "$output" != *"--set clientId"* ]] || return 1            # nothing to heal with → no --set
}

@test "install_client_helm: adopt on older Helm (no --reset-then-reuse-values) falls back to --reuse-values" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  kubectl() { record "kubectl $*"; return 0; }
  helm() {
    if [[ "$1" == list ]]; then echo "munich munich 1 now deployed client-1.8.2 1.8.2"; return 0; fi
    if [[ "$1 $2" == "upgrade --help" ]]; then echo "--install --values --set --reuse-values"; return 0; fi
    record "helm $*"; return 0
  }
  verify_credentials() { echo "VERIFY_CALLED"; printf invalid; }
  export TRACEBLOC_CLIENT_ADOPTED=1
  run install_client_helm </dev/null
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q -- "--reuse-values"
  run mock_calls
  [[ "$output" != *"--reset-then-reuse-values"* ]] || return 1
}

@test "install_client_helm: adopted but no live release -> falls back to the normal connect (fresh install)" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  kubectl() { record "kubectl $*"; return 0; }
  helm() {
    if [[ "$1" == list ]]; then return 0; fi      # no releases on the cluster
    record "helm $*"; return 0
  }
  verify_credentials() { printf valid; }
  export TRACEBLOC_CLIENT_ADOPTED=1
  run install_client_helm <<< $'typed-id\ntyped-pw'   # must fall through to the prompt
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"no live tracebloc release"* ]] || return 1     # explained the fallback
  mock_calls | grep -q "helm upgrade --install tracebloc"
}

@test "install_client_helm: TRACEBLOC_CLIENT_* with rejected creds -> errors, no helm" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf invalid; }
  export TRACEBLOC_CLIENT_ID=envid TRACEBLOC_CLIENT_PASSWORD=envpw
  run install_client_helm </dev/null
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"rejected"* ]] || return 1
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]] || return 1
}

@test "install_client_helm: no credentials + no terminal -> actionable error, no helm (curl|bash)" {
  # Reproduces `curl … | bash` with no env creds: TB_TTY points at a path that
  # can't be read, so we must fail with a clear "set TRACEBLOC_CLIENT_*" message
  # instead of aborting on an EOF read under set -e.
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  unset TRACEBLOC_CLIENT_ID TRACEBLOC_CLIENT_PASSWORD
  export TB_TTY="$BATS_TEST_TMPDIR/no-such-tty"
  run install_client_helm </dev/null
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"TRACEBLOC_CLIENT_ID"* ]] || return 1
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]] || return 1
}

@test "install_client_helm: readable-but-dead-input tty (EOF) fails fast, doesn't abort mid-read (#326 review)" {
  # _tty_available passes ([[ -r "$TB_TTY" ]] is true for /dev/stdin backed by
  # /dev/null), but the first credential read hits EOF — the non-PTY-ssh / IDE /
  # drained-tty class. The per-read `|| _no_interactive_creds_die` guard must
  # surface the actionable env-var error instead of a bare `read` aborting the
  # installer opaquely under set -e (Bugbot + Asad on #326).
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  unset TRACEBLOC_CLIENT_ID TRACEBLOC_CLIENT_PASSWORD
  TB_TTY=/dev/stdin
  run install_client_helm </dev/null   # tty is readable, but yields EOF immediately
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"TRACEBLOC_CLIENT_ID"* ]] || return 1
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]] || return 1
}

@test "install_client_helm: points kubeconfig at the client namespace (so the CLI needs no -n)" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { return 0; }
  kubectl() { record "kubectl $*"; return 0; }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q "kubectl config set-context --current --namespace tracebloc"
}

@test "install_client_helm: re-prompts on invalid, then accepts valid" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() {
    local n; n=$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" >"$BATS_TEST_TMPDIR/n"
    if [ "$n" -ge 2 ]; then printf valid; else printf invalid; fi
  }
  run install_client_helm <<< $'badid\nbadpw\ngoodid\ngoodpw'
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"rejected"* ]] || return 1
  [[ "$output" == *"Credentials verified"* ]] || return 1
  grep -q "clientId: 'goodid'" "$HOST_DATA_DIR/values.yaml"
}

@test "install_client_helm: inactive account -> errors, no helm install" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf inactive; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"not active"* ]] || return 1
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]] || return 1
}

@test "install_client_helm: unverified backend -> proceeds with install" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf unverified; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Couldn't reach tracebloc"* ]] || return 1
  run mock_calls
  [[ "$output" == *"helm upgrade --install"* ]] || return 1
}

@test "install_client_helm: dev-mode uses caller values file, skips prompts" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  vf="$BATS_TEST_TMPDIR/v.yaml"; printf 'clientId: "x"\n' >"$vf"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  TRACEBLOC_VALUES_FILE="$vf"; TB_NAMESPACE=devns
  run install_client_helm
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"helm upgrade --install devns"* ]] || return 1
}

@test "install_client_helm: reuses previous clientId/password defaults" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  printf 'clientId: "previd"\nclientPassword: '"'"'prevpw'"'"'\n' >"$HOST_DATA_DIR/values.yaml"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  # use-previous=y, ClientID=Enter(keep previd), password=Enter(keep prevpw)
  run install_client_helm <<< $'y\n\n\n'
  [ "$status" -eq 0 ] || return 1
  grep -q "clientId: 'previd'" "$HOST_DATA_DIR/values.yaml"
  grep -q "clientPassword: 'prevpw'" "$HOST_DATA_DIR/values.yaml"
}

@test "install_client_helm: gives up after max failed attempts" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf invalid; }
  run install_client_helm <<< $'i1\np1\ni2\np2\ni3\np3\ni4\np4\ni5\np5'
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"Too many failed attempts"* ]] || return 1
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]] || return 1
}

# ── One-client-per-machine guard ────────────────────────────────────────────
@test "install_client_helm: blocks a DIFFERENT client already installed" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  # an existing release reports a different clientId -> must block before upgrade
  helm() {
    if [ "$1" = list ]; then
      printf '%s\n' 'NAME NAMESPACE REVISION UPDATED STATUS CHART APP VERSION' \
                    'oldrel default 1 2026-01-01 deployed client-1.4.3 1.4.3'
      return 0
    fi
    if [ "$1" = get ] && [ "$2" = values ]; then echo 'clientId: "otherclient"'; return 0; fi
    record "helm $*"; return 0
  }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'newclient\nmypw'
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"already runs the tracebloc client 'otherclient'"* ]] || return 1
  [[ "$output" == *"one client per machine"* ]] || return 1
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]] || return 1
}

@test "install_client_helm: helm list failure -> fails CLOSED (refuses, no upgrade)" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  # `helm list` errors (wedged/unreachable API): detect_installed_client can't
  # enumerate, so the guard must REFUSE rather than read empty as "no client here"
  # and silently overwrite whatever is installed.
  helm() {
    if [ "$1" = list ]; then return 1; fi          # enumeration fails
    record "helm $*"; return 0
  }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'newclient\nmypw'
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"Couldn't determine which tracebloc client"* ]] || return 1
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]] || return 1
}

@test "install_client_helm: unreadable client values -> fails CLOSED (refuses, no upgrade)" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  # A client-* release is present, but `helm get values` for it fails — we can't
  # read its clientId, so it's an unidentifiable client. The guard must refuse
  # rather than read it as "no client here" and overwrite it.
  helm() {
    if [ "$1" = list ]; then
      printf '%s\n' 'NAME NAMESPACE REVISION UPDATED STATUS CHART APP VERSION' \
                    'oldrel default 1 2026-01-01 deployed client-1.4.3 1.4.3'
      return 0
    fi
    if [ "$1" = get ] && [ "$2" = values ]; then return 1; fi     # values unreadable
    record "helm $*"; return 0
  }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'newclient\nmypw'
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"Couldn't determine which tracebloc client"* ]] || return 1
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]] || return 1
}

@test "install_client_helm: same client re-run is allowed (upgrade in place)" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() {
    if [ "$1" = list ]; then
      printf '%s\n' 'NAME NAMESPACE REVISION UPDATED STATUS CHART APP VERSION' \
                    'tracebloc tracebloc 1 2026-01-01 deployed client-1.4.3 1.4.3'
      return 0
    fi
    if [ "$1" = get ] && [ "$2" = values ]; then echo 'clientId: "sameid"'; return 0; fi
    record "helm $*"; return 0
  }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'sameid\nmypw'
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"helm upgrade --install tracebloc"* ]] || return 1
}

@test "install_client_helm: same client in a different namespace -> upgrades in place, no duplicate" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  # The minted/adopted namespace (client slug) differs from where this same client
  # is already installed (the old fixed `tracebloc` namespace). Must upgrade the
  # existing release in place, NOT fork a second one under 'acme-corp'.
  export TB_NAMESPACE=acme-corp
  helm() {
    if [ "$1" = list ]; then
      printf '%s\n' 'NAME NAMESPACE REVISION UPDATED STATUS CHART APP VERSION' \
                    'tracebloc tracebloc 1 2026-01-01 deployed client-1.4.3 1.4.3'
      return 0
    fi
    if [ "$1" = get ] && [ "$2" = values ]; then echo 'clientId: "sameid"'; return 0; fi
    record "helm $*"; return 0
  }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'sameid\nmypw'
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"helm upgrade --install tracebloc"* ]] || return 1   # reused existing namespace
  [[ "$output" != *"acme-corp"* ]] || return 1                          # no second release forked
}

@test "install_client_helm: different-namespace reconcile works WITHOUT jq (Bugbot #284)" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  # Regression for the 2nd Bugbot finding on #284: the guard must enumerate ALL
  # namespaces without jq. On a jq-less host the old fallback only checked the
  # minted slug namespace, missed the existing `tracebloc` release, and forked a
  # second release under the slug. Report jq absent + feed only tabular `helm
  # list` output — the guard must still find `tracebloc` and upgrade it in place.
  has() { [ "$1" = jq ] && return 1; command -v "$1" >/dev/null 2>&1; }
  export TB_NAMESPACE=acme-corp
  helm() {
    if [ "$1" = list ]; then
      printf '%s\n' 'NAME NAMESPACE REVISION UPDATED STATUS CHART APP VERSION' \
                    'tracebloc tracebloc 1 2026-01-01 deployed client-1.4.3 1.4.3'
      return 0
    fi
    if [ "$1" = get ] && [ "$2" = values ]; then echo 'clientId: "sameid"'; return 0; fi
    record "helm $*"; return 0
  }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'sameid\nmypw'
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" == *"helm upgrade --install tracebloc"* ]] || return 1   # reused existing namespace
  [[ "$output" != *"acme-corp"* ]] || return 1                          # no second release forked
}

# ── _chart_proxy_env_yaml (#242: host proxy -> split chart keys) ─────────────
@test "_chart_proxy_env_yaml: no proxy on host -> empty" {
  run _chart_proxy_env_yaml
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_chart_proxy_env_yaml: host:port -> HTTP_PROXY_HOST + HTTP_PROXY_PORT" {
  HTTP_PROXY="http://proxy.tenant-a.example:8080"
  run _chart_proxy_env_yaml
  [[ "$output" == *'HTTP_PROXY_HOST: "proxy.tenant-a.example"'* ]] || return 1
  [[ "$output" == *'HTTP_PROXY_PORT: "8080"'* ]] || return 1
  [[ "$output" != *"HTTP_PROXY_USERNAME"* ]] || return 1
}

@test "_chart_proxy_env_yaml: prefers HTTPS_PROXY when HTTP_PROXY unset" {
  HTTPS_PROXY="http://proxy.example.com:3128"
  run _chart_proxy_env_yaml
  [[ "$output" == *'HTTP_PROXY_HOST: "proxy.example.com"'* ]] || return 1
  [[ "$output" == *'HTTP_PROXY_PORT: "3128"'* ]] || return 1
}

@test "_chart_proxy_env_yaml: authenticated proxy -> username/password split" {
  HTTPS_PROXY="http://user:s3cr3t@proxy.example.com:3128"
  run _chart_proxy_env_yaml
  [[ "$output" == *'HTTP_PROXY_HOST: "proxy.example.com"'* ]] || return 1
  [[ "$output" == *'HTTP_PROXY_PORT: "3128"'* ]] || return 1
  [[ "$output" == *'HTTP_PROXY_USERNAME: "user"'* ]] || return 1
  [[ "$output" == *'HTTP_PROXY_PASSWORD: "s3cr3t"'* ]] || return 1
}

@test "_chart_proxy_env_yaml: '@' in password tolerated (split on last @)" {
  http_proxy="http://user:p@ss@proxy.example.com:8080"
  run _chart_proxy_env_yaml
  [[ "$output" == *'HTTP_PROXY_HOST: "proxy.example.com"'* ]] || return 1
  [[ "$output" == *'HTTP_PROXY_PASSWORD: "p@ss"'* ]] || return 1
}

@test "_chart_proxy_env_yaml: no port -> HTTP_PROXY_HOST only, no PORT line" {
  HTTP_PROXY="http://proxy.example.com"
  run _chart_proxy_env_yaml
  [[ "$output" == *'HTTP_PROXY_HOST: "proxy.example.com"'* ]] || return 1
  [[ "$output" != *"HTTP_PROXY_PORT"* ]] || return 1
}

@test "_chart_proxy_env_yaml: passes host NO_PROXY through (proxyEnv unions cluster ranges)" {
  HTTP_PROXY="http://proxy:8080"; NO_PROXY="myinternal.example,.corp"
  run _chart_proxy_env_yaml
  [[ "$output" == *'NO_PROXY: "myinternal.example,.corp"'* ]] || return 1
}

# ── install_client_helm: host proxy propagated into the generated values ────
@test "install_client_helm: host proxy -> values.yaml carries split proxy keys" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  HTTP_PROXY="http://proxy.tenant-a.example:8080"; NO_PROXY=".tenant-a.example"
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  # NB: the "Corporate proxy detected" notice goes through log(), which the test
  # harness routes to /dev/null — so assert on the generated file, not $output.
  grep -q 'HTTP_PROXY_HOST: "proxy.tenant-a.example"' "$HOST_DATA_DIR/values.yaml"
  grep -q 'HTTP_PROXY_PORT: "8080"' "$HOST_DATA_DIR/values.yaml"
  grep -q 'NO_PROXY: ".tenant-a.example"' "$HOST_DATA_DIR/values.yaml"
  # injection must not corrupt the rest of the env: block / file
  grep -q "clientId: 'myid'" "$HOST_DATA_DIR/values.yaml"
  grep -q 'SINGLE_NODE: "true"' "$HOST_DATA_DIR/values.yaml"
}

@test "install_client_helm: no host proxy -> no proxy keys in values.yaml" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  ! grep -q 'HTTP_PROXY_HOST' "$HOST_DATA_DIR/values.yaml" || return 1
}

@test "install_client_helm: TRACEBLOC_TRAINING_RESOURCES overrides the training size in generated values" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  export TRACEBLOC_TRAINING_RESOURCES="cpu=4,memory=16Gi"
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  grep -q 'RESOURCE_LIMITS: "cpu=4,memory=16Gi"' "$HOST_DATA_DIR/values.yaml"
  grep -q 'RESOURCE_REQUESTS: "cpu=4,memory=16Gi"' "$HOST_DATA_DIR/values.yaml"
}

@test "install_client_helm: undeterminable machine falls back to cpu=2,memory=8Gi" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  kubectl() { return 1; }   # cluster unreadable -> machine sizing unavailable
  verify_credentials() { printf valid; }
  unset TRACEBLOC_TRAINING_RESOURCES
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  grep -q 'RESOURCE_LIMITS: "cpu=2,memory=8Gi"' "$HOST_DATA_DIR/values.yaml"
  grep -q 'RESOURCE_REQUESTS: "cpu=2,memory=8Gi"' "$HOST_DATA_DIR/values.yaml"
}

# ── _training_resources (backend#1236, option A) ─────────────────────────────
@test "training size: TRACEBLOC_TRAINING_RESOURCES override wins, no probing" {
  TRACEBLOC_TRAINING_RESOURCES="cpu=4,memory=16Gi"
  helm() { record "helm $*"; return 1; }
  kubectl() { record "kubectl $*"; return 1; }
  run _training_resources
  [ "$output" = "cpu=4,memory=16Gi" ] || return 1
  run mock_calls
  [ -z "$output" ] || return 1
  unset TRACEBLOC_TRAINING_RESOURCES
}

@test "training size: existing release choice carried — resources set survives re-install" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  # helm re-serializes stored values UNQUOTED (the #200 lesson). The kubectl
  # stub only answers the BOUNDED namespace probe that gates the helm call.
  helm() { printf 'env:\n  RESOURCE_LIMITS: cpu=4,memory=12Gi\n'; }
  kubectl() {
    record "kubectl $*"
    case "$*" in *"get namespace"*--request-timeout=*) return 0 ;; *) return 1 ;; esac
  }
  run _training_resources
  [ "$output" = "cpu=4,memory=12Gi" ] || return 1
  run mock_calls
  [[ "$output" != *"get nodes"* ]] || return 1   # machine sizing never consulted
  # and the QUOTED form (our own values file style) parses identically
  helm() { printf 'env:\n  RESOURCE_LIMITS: "cpu=4,memory=12Gi"\n'; }
  run _training_resources
  [ "$output" = "cpu=4,memory=12Gi" ] || return 1
}

@test "training size: the historic static default is NOT carried — re-install gets sized" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  # An older install stored the chart default; that was the absence of a
  # choice, so machine sizing must run (Bugbot on tracebloc/client#393).
  helm() { printf 'env:\n  RESOURCE_LIMITS: cpu=2,memory=8Gi\n'; }
  has() { return 0; }
  kubectl() {
    case "$*" in
      *"get namespace"*--request-timeout=*) return 0 ;;
      *"get nodes"*--request-timeout=*) printf '12 6924Mi\n' ;;
      *) return 1 ;;
    esac
  }
  run _training_resources
  [ "$output" = "cpu=11,memory=3Gi" ] || return 1
}

@test "training size: fresh install sized to the largest node minus overhead" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  # two k3d nodes = the same physical machine; must NOT be summed (cli#399).
  # The stub only answers BOUNDED calls — a wedged API must never hang
  # values generation, so dropping --request-timeout fails this test.
  kubectl() {
    case "$*" in
      *"get namespace"*--request-timeout=*) return 0 ;;
      *"get nodes"*--request-timeout=*) printf '12 6924Mi\n12 6924Mi\n' ;;
      *) return 1 ;;
    esac
  }
  run _training_resources
  [ "$output" = "cpu=11,memory=3Gi" ] || return 1   # 12−1 CPU; 6.76−3 GiB floored
}

# CHANGED BEHAVIOR (backend#2220). This test used to assert that a 2c/4Gi machine
# gets "cpu=2,memory=8Gi" — i.e. an envelope LARGER than the machine, on which no
# training pod can ever schedule. That was the bug, pinned as if it were the
# contract. It now gets the honest remainder, which fits.
#
# The old expectation is not lost, it moved: "unreadable cluster keeps the static
# default" below covers the case where the literal IS still right, because we
# genuinely cannot see the machine. That distinction — cannot-see vs too-small —
# is the whole change; the two used to collapse into the same empty answer.
@test "training size: below-floor machine gets the honest remainder, not an unschedulable literal" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  kubectl() { printf '2 4Gi\n'; }        # 4−3 GiB = 1 GiB < the 2 GiB floor
  run _training_resources
  [ "$output" = "cpu=1,memory=1Gi" ] || return 1
}

@test "training size: a below-floor machine is flagged undersized for the caller to warn" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  kubectl() { printf '2 4Gi\n'; }
  _resolve_training_size
  [ "$_TB_TRAINING_UNDERSIZED" = "1" ] || return 1
  [ "$_TB_TRAINING_UNSCHEDULABLE" = "0" ] || return 1
}

@test "training size: the resolver itself never emits a warning (it would corrupt the value)" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  kubectl() { printf '2 4Gi\n'; }
  # $(...) capture is exactly how the values generation reads this, so any warn
  # text emitted by the resolver would land inside RESOURCE_LIMITS.
  local captured
  captured="$(_training_resources)"
  [ "$captured" = "cpu=1,memory=1Gi" ] || return 1
}

# Bugbot on #768: the unschedulable warning used to be INFERRED by re-probing
# `kubectl get nodes -o name`, so any listable node -- including one whose
# allocatable would not parse, or one not Ready yet -- tripped a hard "this
# machine is too small" warning we had never actually measured. The PowerShell
# twin only flagged it after a parsed node, so the twins disagreed on the same
# cluster. It is now a verdict the ceiling helper RETURNS.
@test "training size: readable-but-unparseable nodes must NOT be called too small" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  # Nodes list fine, but no allocatable parses. We never measured the machine,
  # so claiming it is too small would be a fabrication.
  kubectl() {
    case "$*" in
      *--request-timeout=10s*) printf 'sixteen 64GB\neight lots\n' ;;
      *) printf 'node/one\n' ;;
    esac
  }
  _resolve_training_size
  [ "$_TB_TRAINING_SIZE" = "cpu=2,memory=8Gi" ] || return 1
  [ "$_TB_TRAINING_UNSCHEDULABLE" = "0" ] || return 1
  [ "$_TB_TRAINING_UNDERSIZED" = "0" ] || return 1
}

@test "training size: the ceiling helper reports '|unschedulable' only after measuring" {
  TB_NAMESPACE=tracebloc
  has() { return 0; }
  # A parsed node whose remainder is not a requestable shape.
  kubectl() { printf '500m 512Mi\n'; }
  run _machine_training_ceiling
  [ "$output" = "|unschedulable" ] || return 1
}

@test "training size: the ceiling helper stays SILENT when nothing parses" {
  TB_NAMESPACE=tracebloc
  has() { return 0; }
  kubectl() { printf 'sixteen 64GB\n'; }
  run _machine_training_ceiling
  # Silence means "I could not measure", which the caller must not turn into a
  # claim about machine size.
  [ -z "$output" ] || return 1
}

@test "training size: an unreadable cluster still keeps the static default" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  kubectl() { return 1; }   # nodes unreadable — we cannot do better than history
  run _training_resources
  [ "$output" = "cpu=2,memory=8Gi" ] || return 1
}

@test "training size: a machine too small for even a 1c/1Gi run keeps the literal and flags it" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  # 512Mi allocatable: the remainder is not a requestable shape (cpu=0), so
  # there is no honest number to write. Reachable only where the memory
  # preflight warns instead of failing (macOS/Windows).
  kubectl() { printf '500m 512Mi\n'; }
  _resolve_training_size
  [ "$_TB_TRAINING_SIZE" = "cpu=2,memory=8Gi" ] || return 1
  [ "$_TB_TRAINING_UNSCHEDULABLE" = "1" ] || return 1
  [ "$_TB_TRAINING_UNDERSIZED" = "0" ] || return 1
}

# ── envelope contract: the golden-vector replay (backend#2220) ────────────────
#
# This is the client side of the ticket's definition of done. The arithmetic has
# ONE definition — client-runtime's node_sizing.envelope_from_allocatable — and
# bash cannot call it, so instead bash proves it still AGREES with it by
# replaying the contract's golden vectors through the real function.
#
# Mutate the arithmetic upstream, regenerate, bump scripts/.client-runtime-ref,
# and these rows change. Mutate the embedded constants here and nowhere else,
# and these rows redden. Either way the disagreement surfaces in CI rather than
# on a customer's machine.
#
# The rows come from scripts/tests/fixtures/envelope_vectors.bash, generated by
# scripts/gen-envelope-embed.sh, whose --check mode is a CI gate. Deliberately
# NOT hand-maintained: a golden anyone can quietly edit is not a golden.

@test "envelope contract: every single-node golden vector replays" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  # shellcheck source=/dev/null
  source "${BATS_TEST_DIRNAME}/fixtures/envelope_vectors.bash"
  [ "${#TB_ENVELOPE_VECTORS[@]}" -gt 0 ] || return 1

  has() { return 0; }
  # NB: vcpu/vmem, not cpu/mem — _anchor_largest_schedulable (which
  # _machine_training_resources calls, and which declared these before
  # backend#2237 extracted it) declares `local cpu mem unsched`, shadowing the
  # caller's and feeding the stub empty strings. A stub that silently receives
  # nothing is the "guards nothing" failure mode. `unsched` joined that list
  # when the cordon field did, so avoid it as a caller-side name too.
  local row label vcpu vmem want got failures=""
  for row in "${TB_ENVELOPE_VECTORS[@]}"; do
    IFS='|' read -r label vcpu vmem want <<< "$row"
    kubectl() { printf '%s %s\n' "$vcpu" "$vmem"; }
    got="$(_machine_training_resources)"
    if [ "$got" != "$want" ]; then
      failures+="  ${label} (${vcpu} / ${vmem}): want '${want}' got '${got}'"$'\n'
    fi
  done
  if [ -n "$failures" ]; then
    printf 'envelope contract drift:\n%s' "$failures" >&2
    printf 'The embedded constants disagree with the contract. Run\n' >&2
    printf '  scripts/gen-envelope-embed.sh\n' >&2
    return 1
  fi
}

@test "envelope contract: ANCHOR_LARGEST picks the same node the contract says" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  # shellcheck source=/dev/null
  source "${BATS_TEST_DIRNAME}/fixtures/envelope_vectors.bash"
  [ "${#TB_ENVELOPE_ANCHOR_VECTORS[@]}" -gt 0 ] || return 1

  has() { return 0; }
  local row label nodes want got failures=""
  for row in "${TB_ENVELOPE_ANCHOR_VECTORS[@]}"; do
    IFS='|' read -r label nodes want <<< "$row"
    kubectl() { printf '%b\n' "$nodes"; }
    got="$(_machine_training_resources)"
    if [ "$got" != "$want" ]; then
      failures+="  ${label}: want '${want}' got '${got}'"$'\n'
    fi
  done
  if [ -n "$failures" ]; then
    printf 'anchor-rule drift:\n%s' "$failures" >&2
    return 1
  fi
}

# Parity with the Pester suite for Bugbot #766: the ps1 twin coerced an
# unparseable quantity to 0 and ranked the node anyway. bash has always skipped
# it via `|| continue`; this pins that so the twins cannot drift apart again.
@test "envelope contract: an unparseable node never beats a valid one" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  # 16 cores but a memory unit neither installer speaks, next to a good 8c/32Gi.
  kubectl() {
    case "$*" in
      *--request-timeout=10s*) printf '16 64GB\n8 32Gi\n' ;;
      *) return 1 ;;
    esac
  }
  run _machine_training_resources
  [ "$output" = "cpu=7,memory=29Gi" ] || return 1
}

# ── cordoned nodes (backend#2237) ────────────────────────────────────────────
#
# The contract's skipped_nodes has always listed `spec.unschedulable (cordoned)`
# and NEITHER installer honoured it: the jsonpath did not even request the field.
# The contract's own one-cordoned-out vector did not catch that, because
# gen-envelope-embed.sh PRE-FILTERED cordoned nodes out of the golden -- so the
# row replayed as a lone 4c/16Gi node and the code under test was never handed a
# cordoned one. The generator now emits the whole cluster and applies no rule of
# its own; these are the named regressions beside that replay.
#
# Why it matters in the field: on a heterogeneous cluster a cordoned LARGE node
# wins the anchor outright, the installer writes an envelope no live node can
# satisfy, and every training pod sits Pending with no obvious cause.

@test "envelope contract: a cordoned node never takes the anchor" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  # The 16c/64Gi box is cordoned; the live 4c/16Gi one must size the run.
  kubectl() {
    case "$*" in
      *--request-timeout=10s*) printf '16 64Gi true\n4 16Gi \n' ;;
      *) return 1 ;;
    esac
  }
  run _machine_training_resources
  [ "$output" = "cpu=3,memory=13Gi" ] || return 1
}

@test "envelope contract: cordoning the SMALL node changes nothing" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  # The mirror case. A filter that just dropped the largest node would pass the
  # test above while being completely wrong; this is what makes that one mean
  # "cordoned nodes are skipped" rather than "big nodes are skipped".
  kubectl() {
    case "$*" in
      *--request-timeout=10s*) printf '16 64Gi \n4 16Gi true\n' ;;
      *) return 1 ;;
    esac
  }
  run _machine_training_resources
  [ "$output" = "cpu=15,memory=61Gi" ] || return 1
}

@test "envelope contract: every node cordoned is UNMEASURED, not too small" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  kubectl() {
    case "$*" in
      *--request-timeout=10s*) printf '16 64Gi true\n8 32Gi true\n' ;;
      *) return 1 ;;
    esac
  }
  # Emits nothing, exactly like an unreadable cluster -- the caller keeps the
  # literal. Warning "too small" here would blame the hardware for a cordon the
  # operator can undo in one command.
  run _machine_training_resources
  [ -z "$output" ] || return 1
  # And the ceiling helper must stay silent too, so no undersized/unschedulable
  # warning is printed for a machine that was never measured.
  run _machine_training_ceiling
  [ -z "$output" ] || return 1
}

@test "envelope contract: an explicit 'false' is schedulable, not cordoned" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  # Unschedulable is omitempty, so in practice the field is absent or 'true'.
  # Keying on non-emptiness rather than on 'true' would drop every node from
  # sizing the day an API server serialises `false` -- silent and total, so it
  # is pinned rather than assumed (backend#1729 rule 6).
  kubectl() {
    case "$*" in
      *--request-timeout=10s*) printf '8 32Gi false\n' ;;
      *) return 1 ;;
    esac
  }
  run _machine_training_resources
  [ "$output" = "cpu=7,memory=29Gi" ] || return 1
}

# ── the VM beneath the node containers (backend#2221) ────────────────────────
#
# _honest_topology is pure arithmetic over two numbers -- no kubectl, no helm,
# no branching on cluster state -- so the contract's vectors are the right
# parity mechanism for it, the same way they are for the envelope. (What
# installer_parity.json exists for is CONTROL FLOW: every backend#2220
# divergence lived in a state that was not a clean measurement. That is the
# fixture the eventual CALLER of this function belongs in, because the caller
# shells out to docker and branches; the arithmetic itself does neither.)
#
# The rows come from scripts/tests/fixtures/envelope_vectors.bash, generated by
# scripts/gen-envelope-embed.sh from client-runtime/envelope_contract.json.
# install-k8s.Tests.ps1 replays the SAME rows through Get-HonestTopology, so a
# row added upstream forces both languages to answer it.
@test "topology contract: every VM shape yields the declared topology" {
  source "${BATS_TEST_DIRNAME}/fixtures/envelope_vectors.bash"
  [ "${#TB_TOPOLOGY_VECTORS[@]}" -gt 0 ] || return 1

  local row label vcpu vmem req want got failures=""
  for row in "${TB_TOPOLOGY_VECTORS[@]}"; do
    IFS='|' read -r label vcpu vmem req want <<< "$row"
    got="$(_honest_topology "$vcpu" "$vmem" "$req")"
    if [ "$got" != "$want" ]; then
      failures+="  ${label} (${vcpu} / ${vmem} / want ${req} nodes): want '${want}' got '${got}'"$'\n'
    fi
  done
  if [ -n "$failures" ]; then
    printf 'topology contract drift:\n%s' "$failures" >&2
    printf 'The embedded constants disagree with the contract. Run\n' >&2
    printf '  scripts/gen-envelope-embed.sh\n' >&2
    printf 'The ps1 twin replays the SAME rows -- if only one side fails, the\n' >&2
    printf 'twins have diverged.\n' >&2
    return 1
  fi
}

# The table must not be silently empty -- the disconnected-guard shape
# gen-manifest.sh warns about in its own surface check.
@test "topology contract: the vector table covers the boundaries" {
  source "${BATS_TEST_DIRNAME}/fixtures/envelope_vectors.bash"
  [ "${#TB_TOPOLOGY_VECTORS[@]}" -ge 8 ] || return 1
  # The case that motivated the ticket must be in the table by name: a stock
  # macOS VM cannot host the topology the installer asks for by default.
  printf '%s\n' "${TB_TOPOLOGY_VECTORS[@]}" | grep -q '^stock-macos-vm' || return 1
  # And the unreadable case, whose expected output is EMPTY -- if that row ever
  # grows a value, "I cannot answer" has been turned into an answer.
  printf '%s\n' "${TB_TOPOLOGY_VECTORS[@]}" | grep -q 'vm-unparseable-memory|.*|$' || return 1
}

# An unreadable VM must not be readable as "one node". A caller that collapses a
# cluster on a failed probe is worse than one that leaves the topology alone,
# so the two outcomes must stay distinguishable at the boundary.
@test "topology contract: an unreadable VM emits nothing, not a default" {
  run _honest_topology "eight" "lots" 2
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

# A caller bug, not a machine state. Reported as a non-zero exit with no output
# so it can never be mistaken for the unreadable-VM case above; the ps1 twin
# returns $null for the same input.
@test "topology contract: fewer than one requested node is refused" {
  run _honest_topology 8 17179869184 0
  [ "$status" -ne 0 ] || return 1
  [ -z "$output" ] || return 1
  run _honest_topology 8 17179869184 "two"
  [ "$status" -ne 0 ] || return 1
  [ -z "$output" ] || return 1
}

# The invariant the whole ticket exists to establish, asserted as a property
# across VM sizes rather than on the hand-picked rows above: uncapped k3d
# violates sum(node capacity) <= VM by exactly the node count, and nothing this
# function recommends may.
@test "topology contract: nodes x cap never exceeds the usable VM" {
  local gib bytes usable out nodes cap
  for gib in 4 5 6 7 8 11 12 16 24 32 48 64; do
    bytes=$(( gib * 1024 * 1024 * 1024 ))
    usable=$(( bytes - _TB_ENVELOPE_VM_RESERVE_MEM_BYTES ))
    (( usable < 0 )) && usable=0
    for req in 1 2 3 4 8; do
      out="$(_honest_topology 16 "$bytes" "$req")"
      [ -n "$out" ] || return 1
      nodes="${out#nodes=}"; nodes="${nodes%%,*}"
      cap="${out#*cap=}";    cap="${cap%%,*}"
      if (( nodes * cap > usable )); then
        printf 'VM %dGiB want %d: %d nodes x %d B > %d B usable\n' \
          "$gib" "$req" "$nodes" "$cap" "$usable" >&2
        return 1
      fi
      (( nodes >= 1 && nodes <= req )) || return 1
    done
  done
}

@test "envelope contract: every node unparseable emits nothing (caller falls back)" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  kubectl() {
    case "$*" in
      *--request-timeout=10s*) printf 'sixteen 64GB\neight lots\n' ;;
      *) return 1 ;;
    esac
  }
  run _machine_training_resources
  [ -z "$output" ] || return 1
}

@test "envelope contract: the tie-break is (cpu, memory), not (memory, cpu)" {
  # The regression this consolidation fixes. Before backend#2220 this function
  # ranked nodes (memory, cpu) and would have anchored on the 4c/32Gi node here,
  # answering cpu=3,memory=29Gi — while `tracebloc resources set`, ranking
  # (cpu, memory), anchored on 8c/16Gi and answered cpu=7,memory=13Gi. Two
  # producers, same cluster, different answers, and nobody had chosen either.
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  has() { return 0; }
  kubectl() { printf '8 16Gi\n4 32Gi\n'; }
  run _machine_training_resources
  [ "$output" = "cpu=7,memory=13Gi" ] || return 1
  # ...and the answer must not depend on the order the API listed the nodes in.
  kubectl() { printf '4 32Gi\n8 16Gi\n'; }
  run _machine_training_resources
  [ "$output" = "cpu=7,memory=13Gi" ] || return 1
}

@test "envelope contract: the embedded constants match the vendored contract" {
  # Cheap in-repo mirror of the CI gate, so a reviewer with no python3 handy
  # still sees the failure locally. The generator is the authority.
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available"
  fi
  run "${BATS_TEST_DIRNAME}/../gen-envelope-embed.sh" --check
  [ "$status" -eq 0 ] || return 1
}

# The mutating path — the one --check cannot reach.
#
# Bugbot#766 found a regen that rewrote the bash installer and then died on the
# first PowerShell constant, leaving the two embeds disagreeing. Every test
# above passed throughout, because they only ever ran `--check` (a read) or a
# regen against an ALREADY-CORRECT contract, where every constant short-circuits
# before the rewrite. So: adopt a genuinely changed contract in a scratch copy
# of the tree and assert BOTH installers moved.
@test "envelope contract: adopting a changed contract rewrites BOTH installers" {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available"
  fi
  local root="${BATS_TEST_DIRNAME}/../.."
  local work="${BATS_TEST_TMPDIR}/adopt"
  mkdir -p "$work"
  # Copy only what the generator touches, so the test cannot mutate the repo.
  mkdir -p "$work/scripts/lib" "$work/scripts/tests/fixtures"
  cp "$root/scripts/gen-envelope-embed.sh"                  "$work/scripts/"
  cp "$root/scripts/install-k8s.ps1"                        "$work/scripts/"
  cp "$root/scripts/lib/install-client-helm.sh"             "$work/scripts/lib/"
  cp "$root/scripts/tests/fixtures/envelope_contract.json"  "$work/scripts/tests/fixtures/"
  cp "$root/scripts/tests/fixtures/envelope_vectors.bash"   "$work/scripts/tests/fixtures/"

  # A different overhead, so every derived value moves.
  #
  # topology.per_node_minimum moves WITH it (backend#2221): it is overhead +
  # floor, and upstream's generator recomputes it, so a vendored contract always
  # arrives internally consistent. Recompute it here for the same reason -- this
  # test simulates adopting a properly regenerated upstream contract, not a
  # half-edited one. The half-edited case is its own test below, and the
  # generator is SUPPOSED to refuse it.
  python3 - "$work/scripts/tests/fixtures/envelope_contract.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    contract = json.load(handle)
contract["overhead"]["memory_bytes"] = 4 * 1024 ** 3
minimum = contract["topology"]["per_node_minimum"]
for key in ["cpu_millicores", "memory_bytes"]:
    minimum[key] = contract["overhead"][key] + contract["floor"][key]
with open(path, "w") as handle:
    json.dump(contract, handle, indent=2)
    handle.write("\n")
PY

  # --check must notice.
  run "$work/scripts/gen-envelope-embed.sh" --check
  [ "$status" -ne 0 ] || return 1

  # ...and the real regen must succeed and update BOTH files.
  run "$work/scripts/gen-envelope-embed.sh"
  [ "$status" -eq 0 ] || return 1

  grep -qE '^_TB_ENVELOPE_OVERHEAD_MEM_BYTES[[:space:]]*=[[:space:]]*4294967296$' \
    "$work/scripts/lib/install-client-helm.sh" || return 1
  grep -qE '^\$script:TbEnvelopeOverheadMemBytes[[:space:]]*=[[:space:]]*4294967296$' \
    "$work/scripts/install-k8s.ps1" || return 1

  # And the regenerated tree must now be self-consistent.
  run "$work/scripts/gen-envelope-embed.sh" --check
  [ "$status" -eq 0 ] || return 1
}

@test "envelope contract: a missing assignment is reported, not silently skipped" {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available"
  fi
  local root="${BATS_TEST_DIRNAME}/../.."
  local work="${BATS_TEST_TMPDIR}/missing"
  mkdir -p "$work/scripts/lib" "$work/scripts/tests/fixtures"
  cp "$root/scripts/gen-envelope-embed.sh"                  "$work/scripts/"
  cp "$root/scripts/install-k8s.ps1"                        "$work/scripts/"
  cp "$root/scripts/lib/install-client-helm.sh"             "$work/scripts/lib/"
  cp "$root/scripts/tests/fixtures/envelope_contract.json"  "$work/scripts/tests/fixtures/"
  cp "$root/scripts/tests/fixtures/envelope_vectors.bash"   "$work/scripts/tests/fixtures/"

  # Delete the PowerShell constant entirely: the generator must fail loudly
  # rather than fall through and report a healthy embed (the fail-open shape
  # gen-manifest.sh warns about in its own empty-surface guard).
  grep -v '^\$script:TbEnvelopeFloorMemBytes' "$work/scripts/install-k8s.ps1" \
    > "$work/scripts/install-k8s.ps1.tmp"
  mv "$work/scripts/install-k8s.ps1.tmp" "$work/scripts/install-k8s.ps1"

  run "$work/scripts/gen-envelope-embed.sh" --check
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"no \$script:TbEnvelopeFloorMemBytes assignment"* ]] || return 1
}

# The other half of the derivation guard (backend#2221). per_node_minimum is
# DERIVED from overhead + floor but RECORDED in the contract, because bash and
# PowerShell embed it and cannot do arithmetic on a JSON file. A recorded
# derivation nobody checks is just a fourth constant waiting to rot -- the exact
# duplication backend#2220 spent seven PRs deleting -- so the generator refuses
# a contract where the two disagree instead of embedding the stale number into
# BOTH installers at once.
#
# This is the half-vendored case: someone bumps overhead in the vendored fixture
# by hand, or vendors a contract from a ref where the upstream generator was
# never re-run.
@test "envelope contract: a stale per_node_minimum is refused, not embedded" {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available"
  fi
  local root="${BATS_TEST_DIRNAME}/../.."
  local work="${BATS_TEST_TMPDIR}/stale"
  mkdir -p "$work/scripts/lib" "$work/scripts/tests/fixtures"
  cp "$root/scripts/gen-envelope-embed.sh"                  "$work/scripts/"
  cp "$root/scripts/install-k8s.ps1"                        "$work/scripts/"
  cp "$root/scripts/lib/install-client-helm.sh"             "$work/scripts/lib/"
  cp "$root/scripts/tests/fixtures/envelope_contract.json"  "$work/scripts/tests/fixtures/"
  cp "$root/scripts/tests/fixtures/envelope_vectors.bash"   "$work/scripts/tests/fixtures/"

  # Move overhead and leave per_node_minimum behind.
  python3 - "$work/scripts/tests/fixtures/envelope_contract.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    contract = json.load(handle)
contract["overhead"]["memory_bytes"] = 4 * 1024 ** 3
with open(path, "w") as handle:
    json.dump(contract, handle, indent=2)
    handle.write("\n")
PY

  # A REGEN (not --check) must refuse, and say what to do.
  run "$work/scripts/gen-envelope-embed.sh"
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *per_node_minimum* ]] || return 1

  # And it must refuse BEFORE writing anything: a generator that rewrites one
  # installer and then dies is the Bugbot#766 failure this file exists to catch.
  grep -qE '^_TB_ENVELOPE_OVERHEAD_MEM_BYTES[[:space:]]*=[[:space:]]*3221225472$' \
    "$work/scripts/lib/install-client-helm.sh" || return 1
  grep -qE '^\$script:TbEnvelopeOverheadMemBytes[[:space:]]*=[[:space:]]*3221225472$' \
    "$work/scripts/install-k8s.ps1" || return 1
}

# ── provenance (backend#2220) ────────────────────────────────────────────────
#
# The marker exists because RESOURCE_* has no unset state once helm's
# --reset-then-reuse-values has seen it, so an installer-written value and a
# deliberate `tracebloc resources set` are indistinguishable once the value
# differs from the historic literal. These pin each branch's verdict, because
# getting one wrong means a future ladder either strands an edge forever or
# silently overrules a human.

@test "provenance: a fresh machine-sized install is attributed to the installer" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  kubectl() {
    case "$*" in
      *--request-timeout=10s*) printf '8 32Gi\n' ;;
      *) return 1 ;;
    esac
  }
  run _training_provenance
  [ "$output" = "installer" ] || return 1
}

@test "provenance: the static-default fallback is still the installer's choice" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  kubectl() { return 1; }
  has() { case "$1" in kubectl) return 1 ;; *) return 0 ;; esac; }
  run _training_provenance
  [ "$output" = "installer" ] || return 1
}

@test "provenance: TRACEBLOC_TRAINING_RESOURCES is a human choice, not ours" {
  TB_NAMESPACE=tracebloc
  export TRACEBLOC_TRAINING_RESOURCES="cpu=4,memory=16Gi"
  run _training_provenance
  [ "$output" = "user" ] || return 1
  unset TRACEBLOC_TRAINING_RESOURCES
}

@test "provenance: a value carried forward with no marker is 'unknown', not a guess" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  # A pre-#2220 release: an envelope, no provenance key.
  helm() { printf 'env:\n  RESOURCE_LIMITS: cpu=4,memory=12Gi\n'; }
  kubectl() { return 0; }
  has() { return 0; }
  run _training_provenance
  [ "$output" = "unknown" ] || return 1
}

@test "provenance: an existing 'user' marker SURVIVES re-install (never downgraded)" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() {
    printf 'env:\n  RESOURCE_LIMITS: cpu=4,memory=12Gi\n  RESOURCE_PROVENANCE: user\n'
  }
  kubectl() { return 0; }
  has() { return 0; }
  run _training_provenance
  # The whole point of scope bullet 4: a deliberate choice must not decay to
  # "unknown" (or worse, to "installer") just because the installer ran again.
  [ "$output" = "user" ] || return 1
}

@test "provenance: an existing 'installer' marker survives re-install too" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() {
    printf 'env:\n  RESOURCE_LIMITS: cpu=4,memory=12Gi\n  RESOURCE_PROVENANCE: installer\n'
  }
  kubectl() { return 0; }
  has() { return 0; }
  run _training_provenance
  [ "$output" = "installer" ] || return 1
}

@test "provenance: a junk marker degrades to 'unknown', never to a guess" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() {
    printf 'env:\n  RESOURCE_LIMITS: cpu=4,memory=12Gi\n  RESOURCE_PROVENANCE: banana\n'
  }
  kubectl() { return 0; }
  has() { return 0; }
  run _training_provenance
  [ "$output" = "unknown" ] || return 1
}

# The fail-unsafe path Bugbot found on #768. Provenance used to be read by a
# SECOND `helm get values`; a failed or empty second read looked like "no marker"
# and was written as `unknown` — which consumers treat as a human pin, so an
# installer-sized edge was PERMANENTLY STRANDED as a deliberate choice. That is
# the exact outcome scope bullet 4 exists to prevent, and it is the bash mirror
# of the `installer`-on-failure bug the PowerShell twin had.
@test "provenance: a failed values read carries NOTHING (never a stranding 'unknown')" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  has() { return 0; }
  kubectl() { return 0; }     # namespace probe fine
  helm() { return 1; }        # the values read FAILS
  run _existing_training_values
  [ -z "$output" ] || return 1
}

@test "provenance: an empty values read carries NOTHING" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  has() { return 0; }
  kubectl() { return 0; }
  helm() { printf ''; }       # succeeds, says nothing
  run _existing_training_values
  [ -z "$output" ] || return 1
}

@test "provenance: a failed read leaves the verdict at 'installer', not 'unknown'" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  has() { return 0; }
  helm() { return 1; }        # read fails -> nothing carried
  kubectl() {
    case "$*" in
      *--request-timeout=10s*) printf '8 32Gi\n' ;;
      *) return 0 ;;
    esac
  }
  # Nothing carried means WE sized this machine, so `installer` is correct and
  # the edge stays eligible for a future ladder.
  run _training_provenance
  [ "$output" = "installer" ] || return 1
}

@test "provenance: one lookup returns size and marker together" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  has() { return 0; }
  kubectl() { return 0; }
  helm() {
    printf 'env:\n  RESOURCE_LIMITS: cpu=4,memory=12Gi\n  RESOURCE_PROVENANCE: user\n'
  }
  run _existing_training_values
  [ "$output" = "cpu=4,memory=12Gi|user" ] || return 1
}

@test "provenance: a carried size with no marker pairs with 'unknown' from the SAME read" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  has() { return 0; }
  kubectl() { return 0; }
  helm() { printf 'env:\n  RESOURCE_LIMITS: cpu=4,memory=12Gi\n'; }
  run _existing_training_values
  # `unknown` is correct HERE: the read succeeded and there genuinely is no
  # marker. The bug was reporting it when the read FAILED.
  [ "$output" = "cpu=4,memory=12Gi|unknown" ] || return 1
}

@test "provenance: size and marker come from ONE pass and always agree" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  kubectl() {
    case "$*" in
      *--request-timeout=10s*) printf '8 32Gi\n' ;;
      *) return 1 ;;
    esac
  }
  _resolve_training_size
  [ "$_TB_TRAINING_SIZE" = "cpu=7,memory=29Gi" ] || return 1
  [ "$_TB_TRAINING_PROVENANCE" = "installer" ] || return 1
}

@test "training size: kubectl absent falls back to the static default" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  kubectl() { return 1; }   # the probe also fails -> carry skipped hermetically
  has() { case "$1" in kubectl) return 1 ;; *) return 0 ;; esac; }
  run _training_resources
  [ "$output" = "cpu=2,memory=8Gi" ] || return 1
}

# ── _download_services_progress (step-e count bar; must never hang/fail) ─────
@test "_download_services_progress: TB_NO_SERVICE_PROGRESS set -> immediate no-op" {
  export TB_NO_SERVICE_PROGRESS=1
  run _download_services_progress tracebloc
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_download_services_progress: kubectl absent -> silent skip (never fatal)" {
  unset TB_NO_SERVICE_PROGRESS
  has() { return 1; }                 # kubectl not present
  run _download_services_progress tracebloc
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_download_services_progress: empty namespace -> no-op" {
  unset TB_NO_SERVICE_PROGRESS
  has() { return 0; }
  run _download_services_progress ""
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

# ── bounded helm calls (#426) ────────────────────────────────────────────────
@test "both helm invocations run under a deadline, none unbounded (#426)" {
  local f="$BATS_TEST_DIRNAME/../lib/install-client-helm.sh"
  ! grep -qE 'spin_cmd "(Reconciling the existing client|Installing the tracebloc client)' "$f" || return 1
  # rc is captured (|| _helm_rc=$?) rather than tested via `if !` so the 124
  # timeout case can print its unwedge guidance before error (Bugbot #442).
  # Match the invocation lines only (comments also mention the helper).
  [ "$(grep -c 'spin_cmd_bounded "\$(( _helm_timeout_min \* 60 ))"' "$f")" -eq 2 ] || return 1
  [ "$(grep -c '|| _helm_rc=\$?' "$f")" -eq 2 ] || return 1
}

@test "helm timeout (124) names the pending-release unwedge commands (Bugbot #442)" {
  # SIGKILLed helm can leave pending-install/pending-upgrade; the next run
  # fails with "another operation is in progress" — both call sites must
  # point at the unwedge command. Match the hint lines, not the comments.
  local f="$BATS_TEST_DIRNAME/../lib/install-client-helm.sh"
  [ "$(grep -c "reports 'another operation is in progress'" "$f")" -eq 2 ] || return 1
  grep -q 'helm -n \$TB_NAMESPACE uninstall \$TB_NAMESPACE' "$f"
  # The adopt path tracks release and namespace separately — the rollback hint
  # must name the RELEASE (\$_rel), not the namespace (Bugbot #442 r5).
  grep -q 'helm -n \$_ns rollback \$_rel' "$f"
}

# ── #425: honest pull status (never sell a permanent failure as "downloading") ──
@test "_progress_end_message: complete -> done" {
  run _progress_end_message 3 3 3 ""
  [ "$output" = "done" ] || return 1
}
@test "_progress_end_message: a pull failure -> failed, even with partial progress" {
  run _progress_end_message 1 3 1 "pod/foo ImagePullBackOff"
  [ "$output" = "failed" ] || return 1
}
@test "_progress_end_message: progress, no failure -> downloading" {
  run _progress_end_message 2 3 2 ""
  [ "$output" = "downloading" ] || return 1
}
@test "_progress_end_message: no progress, no failure -> stalled (not 'downloading')" {
  run _progress_end_message 0 3 0 ""
  [ "$output" = "stalled" ] || return 1
}
@test "_pull_failure_detail: ImagePullBackOff -> prints pod + event, returns 0" {
  has() { [ "$1" = kubectl ]; }
  kubectl() {
    case "$*" in
      *"get pods"*)   printf '%s\n' "foo-abc  0/1  ImagePullBackOff  0  30s" ;;
      *"get events"*) printf '%s\n' '10s Warning Failed pod/foo Failed to pull image "ghcr.io/x": x509: certificate signed by unknown authority' ;;
    esac
  }
  run _pull_failure_detail tracebloc
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"ImagePullBackOff"* ]] || return 1
  [[ "$output" == *"x509"* ]] || return 1
}
@test "_pull_failure_detail: healthy pods -> returns 1, prints nothing" {
  has() { [ "$1" = kubectl ]; }
  kubectl() { case "$*" in *"get pods"*) printf '%s\n' "foo-abc 1/1 Running 0 1m" ;; esac; }
  run _pull_failure_detail tracebloc
  [ "$status" -ne 0 ] || return 1
  [ -z "$output" ] || return 1
}
@test "_pull_failure_detail: unrelated x509 events don't displace the real pull reason (#425 Bugbot)" {
  has() { [ "$1" = kubectl ]; }
  kubectl() {
    case "$*" in
      *"get pods"*)   printf '%s\n' "foo-abc  0/1  ImagePullBackOff  0  30s" ;;
      *"get events"*) printf '%s\n' \
        'Warning Failed pod/foo Failed to pull image "ghcr.io/x": 403 Forbidden' \
        'Warning Unrelated pod/bar x509: certificate signed by unknown authority' \
        'Warning Unrelated pod/baz x509: certificate signed by unknown authority' \
        'Warning Unrelated pod/qux x509: certificate signed by unknown authority' ;;
    esac
  }
  run _pull_failure_detail tracebloc
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"403 Forbidden"* ]] || return 1   # the real pull reason survives the tail
  [[ "$output" != *"x509"* ]] || return 1            # unrelated x509 events are scoped out
}
@test "_download_services_progress routes the end copy through the honest selector (#425)" {
  # The end-of-progress copy is chosen by the pure _progress_end_message selector,
  # a 'failed' branch warns loudly, and the background over-promise appears exactly
  # once — so a permanent failure can never be printed as background progress.
  local f="$BATS_TEST_DIRNAME/../lib/install-client-helm.sh"
  grep -q 'outcome="\$(_progress_end_message' "$f"
  grep -qE '^\s*failed\)' "$f"
  grep -q 'look stuck pulling' "$f"
  [ "$(grep -c 'Services are still downloading' "$f")" -eq 1 ] || return 1
}

# ── _image_mirror_yaml (private registry mirror / air-gap, #585) ────────────
# Emits the top-level chart values that re-home every image onto a private
# mirror. Empty unless TRACEBLOC_IMAGE_REGISTRY / TRACEBLOC_REGISTRY_* are set.
@test "_image_mirror_yaml: no knobs -> empty (default install unchanged)" {
  unset TRACEBLOC_IMAGE_REGISTRY TRACEBLOC_REGISTRY_USERNAME TRACEBLOC_REGISTRY_PASSWORD TRACEBLOC_REGISTRY_SERVER TRACEBLOC_REGISTRY_EMAIL
  run _image_mirror_yaml
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_image_mirror_yaml: mirror only -> global.imageRegistry, no dockerRegistry" {
  unset TRACEBLOC_REGISTRY_USERNAME TRACEBLOC_REGISTRY_PASSWORD TRACEBLOC_REGISTRY_SERVER TRACEBLOC_REGISTRY_EMAIL
  export TRACEBLOC_IMAGE_REGISTRY=mirror.corp.example
  run _image_mirror_yaml
  [ "$status" -eq 0 ] || return 1
  echo "$output" | grep -q "imageRegistry: 'mirror.corp.example'" || return 1
  echo "$output" | grep -q "^global:" || return 1
  ! echo "$output" | grep -q "dockerRegistry:" || return 1
}

@test "_image_mirror_yaml: strips a pasted scheme from the mirror host" {
  unset TRACEBLOC_REGISTRY_USERNAME TRACEBLOC_REGISTRY_PASSWORD TRACEBLOC_REGISTRY_SERVER TRACEBLOC_REGISTRY_EMAIL
  export TRACEBLOC_IMAGE_REGISTRY=https://mirror.corp.example
  run _image_mirror_yaml
  echo "$output" | grep -q "imageRegistry: 'mirror.corp.example'" || return 1
  ! echo "$output" | grep -q "https://mirror.corp.example'" || return 1
}

@test "_image_mirror_yaml: mirror + creds -> dockerRegistry with derived https server" {
  export TRACEBLOC_IMAGE_REGISTRY=mirror.corp.example
  export TRACEBLOC_REGISTRY_USERNAME=svc
  export TRACEBLOC_REGISTRY_PASSWORD=secret
  unset TRACEBLOC_REGISTRY_SERVER TRACEBLOC_REGISTRY_EMAIL
  run _image_mirror_yaml
  [ "$status" -eq 0 ] || return 1
  echo "$output" | grep -q "^dockerRegistry:" || return 1
  echo "$output" | grep -q "create: true" || return 1
  echo "$output" | grep -q "server: 'https://mirror.corp.example'" || return 1
  echo "$output" | grep -q "username: 'svc'" || return 1
  echo "$output" | grep -q "password: 'secret'" || return 1
}

@test "_image_mirror_yaml: an explicit TRACEBLOC_REGISTRY_SERVER wins over the derived URI" {
  export TRACEBLOC_IMAGE_REGISTRY=mirror.corp.example
  export TRACEBLOC_REGISTRY_USERNAME=svc
  export TRACEBLOC_REGISTRY_PASSWORD=secret
  export TRACEBLOC_REGISTRY_SERVER=https://auth.corp.example/v2/
  unset TRACEBLOC_REGISTRY_EMAIL
  run _image_mirror_yaml
  echo "$output" | grep -q "server: 'https://auth.corp.example/v2/'" || return 1
}

@test "_image_mirror_yaml: doubles single quotes in the password (YAML-safe)" {
  export TRACEBLOC_IMAGE_REGISTRY=mirror.corp.example
  export TRACEBLOC_REGISTRY_USERNAME=svc
  export TRACEBLOC_REGISTRY_PASSWORD="s3cr3t'q"
  unset TRACEBLOC_REGISTRY_SERVER TRACEBLOC_REGISTRY_EMAIL
  run _image_mirror_yaml
  echo "$output" | grep -q "password: 's3cr3t''q'" || return 1
}

@test "_image_mirror_yaml: creds without a mirror -> dockerRegistry only, no global" {
  unset TRACEBLOC_IMAGE_REGISTRY TRACEBLOC_REGISTRY_SERVER TRACEBLOC_REGISTRY_EMAIL
  export TRACEBLOC_REGISTRY_USERNAME=svc
  export TRACEBLOC_REGISTRY_PASSWORD=secret
  run _image_mirror_yaml
  [ "$status" -eq 0 ] || return 1
  ! echo "$output" | grep -q "^global:" || return 1
  echo "$output" | grep -q "^dockerRegistry:" || return 1
}

@test "_image_mirror_yaml: creds without a mirror still emit server (Docker Hub) - schema requires it (Bugbot)" {
  # The chart schema requires dockerRegistry.server whenever create is true, so a
  # creds-only config must NOT omit it (else helm install fails with a schema error).
  unset TRACEBLOC_IMAGE_REGISTRY TRACEBLOC_REGISTRY_SERVER TRACEBLOC_REGISTRY_EMAIL
  export TRACEBLOC_REGISTRY_USERNAME=svc
  export TRACEBLOC_REGISTRY_PASSWORD=secret
  run _image_mirror_yaml
  echo "$output" | grep -q "server: 'https://index.docker.io/v1/'" || return 1
}

# ── _resolve_mysql_engine (backend#723, decision A2) ────────────────────────
# Unit tests: the function reads values_file/existing_id/HOST_DATA_DIR/
# TB_NAMESPACE/ARCH from the caller's scope and sets TB_MYSQL_ENGINE_RESOLVED.

_engine_fixture() {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR/mysql"
  values_file="$HOST_DATA_DIR/values.yaml"
  existing_id=""
  TB_NAMESPACE="tracebloc"
  unset TB_MYSQL_ENGINE TB_MYSQL_ENGINE_RESOLVED
}

@test "_resolve_mysql_engine: explicit TB_MYSQL_ENGINE=8.4 wins on any arch" {
  _engine_fixture; ARCH=x86_64; TB_MYSQL_ENGINE=8.4
  _resolve_mysql_engine
  [ "$TB_MYSQL_ENGINE_RESOLVED" = "8.4" ] || return 1
}

@test "_resolve_mysql_engine: explicit TB_MYSQL_ENGINE=5.7 wins on arm64" {
  _engine_fixture; ARCH=arm64; TB_MYSQL_ENGINE=5.7
  _resolve_mysql_engine
  [ "$TB_MYSQL_ENGINE_RESOLVED" = "5.7" ] || return 1
}

@test "_resolve_mysql_engine: invalid value fails closed with the allowed set" {
  _engine_fixture; ARCH=arm64; TB_MYSQL_ENGINE=9.0
  run _resolve_mysql_engine
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"'auto', '5.7' or '8.4'"* ]] || return 1
}

@test "_resolve_mysql_engine: auto on a fresh arm64 install picks 8.4" {
  _engine_fixture; ARCH=arm64
  _resolve_mysql_engine
  [ "$TB_MYSQL_ENGINE_RESOLVED" = "8.4" ] || return 1
}

@test "_resolve_mysql_engine: auto on a fresh amd64 install stays 5.7" {
  _engine_fixture; ARCH=x86_64
  _resolve_mysql_engine
  [ "$TB_MYSQL_ENGINE_RESOLVED" = "5.7" ] || return 1
}

@test "_resolve_mysql_engine: an existing release pins 5.7 even on arm64" {
  _engine_fixture; ARCH=arm64; existing_id="someclient"
  _resolve_mysql_engine
  [ "$TB_MYSQL_ENGINE_RESOLVED" = "5.7" ] || return 1
}

@test "_resolve_mysql_engine: legacy datadir content pins 5.7 even on arm64" {
  _engine_fixture; ARCH=arm64
  touch "$HOST_DATA_DIR/mysql/ibdata1"
  _resolve_mysql_engine
  [ "$TB_MYSQL_ENGINE_RESOLVED" = "5.7" ] || return 1
}

@test "_resolve_mysql_engine: per-release datadir content pins 5.7 even on arm64" {
  _engine_fixture; ARCH=arm64
  mkdir -p "$HOST_DATA_DIR/$TB_NAMESPACE/mysql"; touch "$HOST_DATA_DIR/$TB_NAMESPACE/mysql/ibdata1"
  _resolve_mysql_engine
  [ "$TB_MYSQL_ENGINE_RESOLVED" = "5.7" ] || return 1
}

@test "_resolve_mysql_engine: an UNLISTABLE mysql dir pins 5.7 even on arm64 (fail closed)" {
  # The uid-999 ownership case (Bugbot): --reuse-data leaves a mysql dir the
  # host user cannot list; that must read as "content", never "empty" — an
  # 8.4 opt-in here would wedge the reuse behind the format guard.
  _engine_fixture; ARCH=arm64
  chmod 000 "$HOST_DATA_DIR/mysql"
  _resolve_mysql_engine
  status_engine="$TB_MYSQL_ENGINE_RESOLVED"
  chmod 700 "$HOST_DATA_DIR/mysql"
  [ "$status_engine" = "5.7" ] || return 1
}

@test "_resolve_mysql_engine: a previous 8.4 opt-in is sticky across re-runs (amd64)" {
  _engine_fixture; ARCH=x86_64
  printf 'images:\n  mysqlClient:\n    tag: "8.4"\n    digest: ""\n' > "$values_file"
  _resolve_mysql_engine
  [ "$TB_MYSQL_ENGINE_RESOLVED" = "8.4" ] || return 1
}

# ── _mysql_engine_decision: the rule, asked without side effects (backend#2047)
# preflight's arch gate consults this instead of restating the fresh-vs-existing
# test, so each verdict needs a REASON that is distinguishable — "5.7 because
# your data is 5.7-format" and "5.7 because you asked for it" print different
# remedies, and only "8.4" means this host needs no amd64 emulation.

@test "_mysql_engine_decision: reasons are distinguishable per input" {
  _engine_fixture; ARCH=arm64
  [ "$(_mysql_engine_decision)" = "8.4 fresh" ] || return 1
  ARCH=x86_64
  [ "$(_mysql_engine_decision)" = "5.7 amd64" ] || return 1
  ARCH=arm64; touch "$HOST_DATA_DIR/mysql/ibdata1"
  [ "$(_mysql_engine_decision)" = "5.7 existing-datadir" ] || return 1
  rm -f "$HOST_DATA_DIR/mysql/ibdata1"
  # A live Helm release is a DISTINCT reason from real datadir content: same 5.7
  # engine, different remedy (helm list, not the data dir).
  existing_id="someclient"
  [ "$(_mysql_engine_decision)" = "5.7 existing-release" ] || return 1
  # When BOTH a release and real datadir files exist, datadir wins: the host
  # DOES hold 5.7 data, and a release-only "uninstall" remedy would leave those
  # files to re-pin 5.7 next run (Bugbot, client#752). existing_id still set here.
  touch "$HOST_DATA_DIR/mysql/ibdata1"
  [ "$(_mysql_engine_decision)" = "5.7 existing-datadir" ] || return 1
  rm -f "$HOST_DATA_DIR/mysql/ibdata1"
  existing_id=""
  TB_MYSQL_ENGINE=5.7
  [ "$(_mysql_engine_decision)" = "5.7 explicit" ] || return 1
  TB_MYSQL_ENGINE=8.4
  [ "$(_mysql_engine_decision)" = "8.4 explicit" ] || return 1
  TB_MYSQL_ENGINE=9.0
  [ "$(_mysql_engine_decision)" = "invalid 9.0" ] || return 1
  unset TB_MYSQL_ENGINE
  printf 'images:\n  mysqlClient:\n    tag: "8.4"\n    digest: ""\n' > "$values_file"
  [ "$(_mysql_engine_decision)" = "8.4 sticky" ] || return 1
}

@test "_mysql_engine_decision: pure on EVERY branch — never logs, never sets the resolved global" {
  # preflight consults it minutes before the engine is chosen; a log line or a
  # half-set global there would be an install-time side effect at check time.
  # Every branch is exercised, not just the one the happy path takes: a purity
  # test covering a single branch passes while any other branch leaks (found by
  # mutating the sticky branch — it stayed green until this loop existed).
  log() { echo "LOGGED: $*"; }
  local case_name
  for case_name in fresh amd64 existing-release existing-datadir explicit invalid sticky; do
    _engine_fixture; ARCH=arm64
    case "$case_name" in
      amd64)            ARCH=x86_64 ;;
      existing-release) existing_id="someclient" ;;
      existing-datadir) touch "$HOST_DATA_DIR/mysql/ibdata1" ;;
      explicit)         TB_MYSQL_ENGINE=5.7 ;;
      invalid)          TB_MYSQL_ENGINE=9.0 ;;
      sticky)           printf 'images:\n  mysqlClient:\n    tag: "8.4"\n' > "$values_file" ;;
    esac
    # `run` would swallow the global anyway (subshell), so assert on both: the
    # captured output must carry no log line, and the global must stay unset in
    # THIS shell after a direct call.
    run _mysql_engine_decision
    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *LOGGED:* ]] || return 1
    unset TB_MYSQL_ENGINE_RESOLVED
    _mysql_engine_decision >/dev/null
    if [[ -n "${TB_MYSQL_ENGINE_RESOLVED:-}" ]]; then
      echo "branch '$case_name' set TB_MYSQL_ENGINE_RESOLVED=$TB_MYSQL_ENGINE_RESOLVED"
      return 1
    fi
  done
}

@test "_resolve_mysql_engine: records the reason alongside the engine" {
  _engine_fixture; ARCH=arm64; touch "$HOST_DATA_DIR/mysql/ibdata1"
  _resolve_mysql_engine
  [ "$TB_MYSQL_ENGINE_RESOLVED" = "5.7" ] || return 1
  [ "$TB_MYSQL_ENGINE_REASON" = "existing-datadir" ] || return 1
}

# ── _client_values_file / _client_default_namespace ──────────────────────────
# Both exist so preflight can reach the rule's inputs without restating them.

@test "_client_values_file: HOST_DATA_DIR default, TRACEBLOC_VALUES_FILE override" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"
  unset TRACEBLOC_VALUES_FILE
  [ "$(_client_values_file)" = "$HOST_DATA_DIR/values.yaml" ] || return 1
  TRACEBLOC_VALUES_FILE=/tmp/custom.yaml
  [ "$(_client_values_file)" = "/tmp/custom.yaml" ] || return 1
  unset TRACEBLOC_VALUES_FILE
}

@test "_client_default_namespace: default + sanitised override" {
  unset TB_NAMESPACE
  [ "$(_client_default_namespace)" = "tracebloc" ] || return 1
  TB_NAMESPACE="My Edge"
  [ "$(_client_default_namespace)" = "$(_sanitize_workspace_name "My Edge")" ] || return 1
  unset TB_NAMESPACE
}

# ── _assert_engine_runs_on_this_arch (backend#2047) ──────────────────────────
# The same arch question, re-asked once the engine is resolved for real. It has
# to exist because preflight cannot see an existing Helm release: that edge can
# read as fresh there and only pin 5.7 here.

_arch_gate_ctx() {
  OS=Linux; ARCH=aarch64
  unset TRACEBLOC_ALLOW_ARM64
  amd64_emulation_available() { return 1; }
  TB_MYSQL_ENGINE_RESOLVED=5.7
  TB_MYSQL_ENGINE_REASON=existing-datadir
}

@test "_assert_engine_runs_on_this_arch: 8.4 on arm64 without emulation -> proceeds" {
  _arch_gate_ctx; TB_MYSQL_ENGINE_RESOLVED=8.4; TB_MYSQL_ENGINE_REASON=fresh
  run _assert_engine_runs_on_this_arch
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_assert_engine_runs_on_this_arch: 5.7 on arm64 without emulation -> refuses, datadir reason" {
  _arch_gate_ctx
  run _assert_engine_runs_on_this_arch
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"existing MySQL 5.7 data"* ]] || return 1
  [[ "$output" == *"data-format constraint, not an architecture one"* ]] || return 1
  [[ "$output" != *"provision an amd64"* ]] || return 1
}

# The existing-release reason (a live Helm release, not host files) must NOT
# claim this host holds 5.7 data, and must NOT offer --data-dir — that remedy
# cannot clear a release `helm list` reports, so the next run would refuse
# identically (Asad, client#748).
@test "_assert_engine_runs_on_this_arch: existing-release refuses without a false data claim or a --data-dir remedy" {
  _arch_gate_ctx; TB_MYSQL_ENGINE_REASON=existing-release
  run _assert_engine_runs_on_this_arch
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"existing tracebloc release is installed"* ]] || return 1
  # never asserts the host data is 5.7-format as fact...
  [[ "$output" != *"This host holds existing MySQL 5.7 data"* ]] || return 1
  # ...and never offers the remedy that cannot clear a helm-list trigger.
  [[ "$output" != *"--data-dir"* ]] || return 1
  # the fresh-start remedy is COMPLETE: 'helm uninstall' leaves the kept MySQL
  # PVC, so it must say to remove the retained data too (Bugbot, client#752).
  [[ "$output" == *"retained MySQL PVC"* ]] || return 1
  [[ "$output" == *"resource-policy: keep"* ]] || return 1
}

@test "_assert_engine_runs_on_this_arch: explicit 5.7 request gets the request-shaped remedy" {
  _arch_gate_ctx; TB_MYSQL_ENGINE_REASON=explicit
  run _assert_engine_runs_on_this_arch
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"TB_MYSQL_ENGINE=5.7 was requested"* ]] || return 1
  [[ "$output" != *"existing MySQL 5.7 data"* ]] || return 1
}

@test "_assert_engine_runs_on_this_arch: emulation / amd64 / macOS-ok / escape hatch all proceed" {
  _arch_gate_ctx; amd64_emulation_available() { return 0; }
  run _assert_engine_runs_on_this_arch; [ "$status" -eq 0 ] || return 1
  _arch_gate_ctx; ARCH=x86_64
  run _assert_engine_runs_on_this_arch; [ "$status" -eq 0 ] || return 1
  # macOS is a real gate now (client#756), not an auto-proceed: it verifies the
  # Rosetta/Docker smoke. Emulation working -> proceed.
  _arch_gate_ctx; OS=Darwin; _macos_amd64_emulation_ok() { return 0; }
  run _assert_engine_runs_on_this_arch; [ "$status" -eq 0 ] || return 1
  _arch_gate_ctx; export TRACEBLOC_ALLOW_ARM64=1
  run _assert_engine_runs_on_this_arch; [ "$status" -eq 0 ] || return 1
  unset TRACEBLOC_ALLOW_ARM64
}

# THE FAIL-CLOSED BACKSTOP (Arturo, client#756). The early assert_amd64_emulation
# guesses 8.4 and skips when it can't see a live release (existing_id needs helm).
# On macOS this late gate is the only thing that catches the resolved-5.7 case.
@test "_assert_engine_runs_on_this_arch: macOS + 5.7 + emulation MISSING -> refuses (backstop)" {
  _arch_gate_ctx; OS=Darwin
  _macos_amd64_emulation_ok() { return 1; }   # Rosetta off
  run _assert_engine_runs_on_this_arch
  [ "$status" -ne 0 ] || return 1                            # not waved through
  [[ "$output" == *"Rosetta"* ]] || return 1                 # macOS remedy, not the Linux binfmt one
  [[ "$output" != *"tonistiigi/binfmt"* ]] || return 1
}

@test "_assert_engine_runs_on_this_arch: macOS + 5.7 + emulation helper ABSENT -> refuses (fail closed)" {
  _arch_gate_ctx; OS=Darwin
  # helper not defined at all: declare -F is false, so the gate must still refuse.
  run _assert_engine_runs_on_this_arch
  [ "$status" -ne 0 ] || return 1
}

# ── install_client_helm flow: the generated values carry the engine choice ──

@test "install_client_helm: TB_MYSQL_ENGINE=8.4 -> values carry the 8.4 mysqlClient block" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  ARCH=x86_64; TB_MYSQL_ENGINE=8.4
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  grep -q 'tag: "8.4"' "$HOST_DATA_DIR/values.yaml"
  grep -A3 'mysqlClient:' "$HOST_DATA_DIR/values.yaml" | grep -q 'digest: ""'
}

@test "install_client_helm: amd64 auto -> values carry no mysqlClient block (byte-identical default)" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  ARCH=x86_64; unset TB_MYSQL_ENGINE
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  ! grep -q 'mysqlClient:' "$HOST_DATA_DIR/values.yaml" || return 1
}

@test "install_client_helm: fresh arm64 auto -> values carry the 8.4 mysqlClient block" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  ARCH=arm64; unset TB_MYSQL_ENGINE
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  grep -q 'tag: "8.4"' "$HOST_DATA_DIR/values.yaml"
}

@test "install_client_helm: arm64 auto with existing mysql data -> stays 5.7 (no engine flip)" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR/mysql"
  touch "$HOST_DATA_DIR/mysql/ibdata1"
  ARCH=arm64; unset TB_MYSQL_ENGINE
  # Emulation present, stated rather than inherited from the runner: since
  # backend#2047 a 5.7 verdict on arm64 with NO emulation is refused outright
  # (next test), and OS/binfmt would otherwise decide this test's outcome.
  OS=Linux; amd64_emulation_available() { return 0; }
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  ! grep -q 'mysqlClient:' "$HOST_DATA_DIR/values.yaml" || return 1
}

@test "install_client_helm: arm64 + existing mysql data + no emulation -> refuses before helm (backend#2047)" {
  # The ordering, end to end: the engine resolves to 5.7 because of the datadir,
  # and only then does the arch question get asked — so the run stops with the
  # data-format reason and never reaches helm.
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR/mysql"
  touch "$HOST_DATA_DIR/mysql/ibdata1"
  ARCH=arm64; unset TB_MYSQL_ENGINE TRACEBLOC_ALLOW_ARM64
  OS=Linux; amd64_emulation_available() { return 1; }
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"existing MySQL 5.7 data"* ]] || return 1
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]] || return 1
}

@test "install_client_helm: FRESH arm64 + no emulation -> installs on the native 8.4 engine (backend#2047)" {
  # The bug this ticket is about, at the flow level: nothing on this host needs
  # emulation, so the run must complete and pick 8.4.
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  ARCH=arm64; unset TB_MYSQL_ENGINE TRACEBLOC_ALLOW_ARM64
  OS=Linux; amd64_emulation_available() { return 1; }
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  grep -q 'tag: "8.4"' "$HOST_DATA_DIR/values.yaml"
}

# ── _recover_pending_helm_release (#554) ─────────────────────────────────────
# A helm process killed mid-operation leaves the release in a pending-* state;
# the next `helm upgrade --install` then fails forever with "another operation
# is in progress". These cover the auto-recovery that clears the wedge.

@test "_recover_pending_helm_release: fresh/absent release -> no-op, rc 0" {
  _bounded() { shift; "$@"; }               # bypass timeout(1) so the helm mock is used
  helm() { record "helm $*"; return 1; }   # `helm status` errors when absent
  run _recover_pending_helm_release rel ns
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" != *"helm rollback"* ]] || return 1
  [[ "$output" != *"helm uninstall"* ]] || return 1
}

@test "_recover_pending_helm_release: deployed release -> no-op, rc 0" {
  _bounded() { shift; "$@"; }
  helm() {
    if [[ "$1" == status ]]; then printf 'NAME: rel\nSTATUS: deployed\nREVISION: 4\n'; return 0; fi
    record "helm $*"; return 0
  }
  run _recover_pending_helm_release rel ns
  [ "$status" -eq 0 ] || return 1
  run mock_calls
  [[ "$output" != *"helm rollback"* ]] || return 1
  [[ "$output" != *"helm uninstall"* ]] || return 1
}

@test "_recover_pending_helm_release: pending-upgrade -> rolls back, rc 0" {
  _bounded() { shift; "$@"; }
  helm() {
    if [[ "$1" == status ]]; then printf 'NAME: rel\nSTATUS: pending-upgrade\nREVISION: 5\n'; return 0; fi
    record "helm $*"; return 0
  }
  run _recover_pending_helm_release rel ns
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q "helm rollback rel -n ns"
  run mock_calls
  [[ "$output" != *"helm uninstall"* ]] || return 1
}

@test "_recover_pending_helm_release: pending-install -> uninstalls the half-install, rc 0" {
  _bounded() { shift; "$@"; }
  helm() {
    if [[ "$1" == status ]]; then printf 'NAME: rel\nSTATUS: pending-install\nREVISION: 1\n'; return 0; fi
    record "helm $*"; return 0
  }
  run _recover_pending_helm_release rel ns
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q "helm uninstall rel -n ns"
  run mock_calls
  [[ "$output" != *"helm rollback"* ]] || return 1
}

@test "_recover_pending_helm_release: uninstalling -> finishes the uninstall, rc 0" {
  _bounded() { shift; "$@"; }
  helm() {
    if [[ "$1" == status ]]; then printf 'NAME: rel\nSTATUS: uninstalling\nREVISION: 3\n'; return 0; fi
    record "helm $*"; return 0
  }
  run _recover_pending_helm_release rel ns
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q "helm uninstall rel -n ns"
}

@test "_recover_pending_helm_release: failed rollback -> rc 1 (caller fails closed)" {
  _bounded() { shift; "$@"; }
  helm() {
    if [[ "$1" == status ]]; then printf 'NAME: rel\nSTATUS: pending-upgrade\nREVISION: 5\n'; return 0; fi
    if [[ "$1" == rollback ]]; then return 1; fi
    record "helm $*"; return 0
  }
  run _recover_pending_helm_release rel ns
  [ "$status" -eq 1 ] || return 1
}

@test "_recover_pending_helm_release: failed uninstall -> rc 1 (caller fails closed)" {
  _bounded() { shift; "$@"; }
  helm() {
    if [[ "$1" == status ]]; then printf 'NAME: rel\nSTATUS: pending-install\nREVISION: 1\n'; return 0; fi
    if [[ "$1" == uninstall ]]; then return 1; fi
    record "helm $*"; return 0
  }
  run _recover_pending_helm_release rel ns
  [ "$status" -eq 1 ] || return 1
}

# ── install_client_helm: normal path clears a pending-* wedge first (#554) ───
# `helm list` hides pending releases by default, so the one-client guard never
# sees the wedge — but the next `helm upgrade --install` fails with "another
# operation is in progress". install_client_helm must recover before upgrading.

@test "install_client_helm: pending-upgrade wedge is rolled back BEFORE the install upgrade" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  _bounded() { shift; "$@"; }
  # list: empty (pending releases are hidden from the guard). status: wedged.
  helm() {
    if [[ "$1" == list ]]; then return 0; fi
    if [[ "$1" == status ]]; then printf 'NAME: n\nSTATUS: pending-upgrade\nREVISION: 5\n'; return 0; fi
    record "helm $*"; return 0
  }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  # rollback recorded, and it comes before the install upgrade in call order.
  mock_calls | grep -q "helm rollback"
  mock_calls | grep -q "helm upgrade --install"
  local rb up
  rb="$(mock_calls | grep -n 'helm rollback' | head -1 | cut -d: -f1)"
  up="$(mock_calls | grep -n 'helm upgrade --install' | head -1 | cut -d: -f1)"
  [ "$rb" -lt "$up" ] || return 1
}

@test "install_client_helm: fails closed when the wedge cannot be auto-cleared" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  _bounded() { shift; "$@"; }
  helm() {
    if [[ "$1" == list ]]; then return 0; fi
    if [[ "$1" == status ]]; then printf 'NAME: n\nSTATUS: pending-upgrade\nREVISION: 5\n'; return 0; fi
    if [[ "$1" == rollback ]]; then return 1; fi   # recovery itself fails
    record "helm $*"; return 0
  }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"interrupted previous helm operation"* ]] || return 1
  # MUST NOT march into the wedged upgrade after recovery failed.
  run mock_calls
  [[ "$output" != *"helm upgrade --install"* ]] || return 1
}

@test "install_client_helm: a generic (exit 1) upgrade failure still names the unwedge remedy (#554)" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  # Clean status (no wedge to recover), but the install upgrade itself fails 1 —
  # NOT the 124 timeout. The remedy must still be surfaced (issue #554).
  _bounded() { shift; "$@"; }
  helm() {
    if [[ "$1" == list ]]; then return 0; fi
    if [[ "$1" == status ]]; then return 0; fi
    if [[ "$1" == upgrade ]]; then return 1; fi
    record "helm $*"; return 0
  }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"another operation is in progress"* ]] || return 1
}

@test "install_client_helm: a DIFFERENT client WEDGED in pending-* is still seen and blocked (#554)" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  _bounded() { shift; "$@"; }
  # Helm 3 hides pending-* from a bare `helm list`, so the one-client guard must
  # enumerate those states explicitly — otherwise a foreign client wedged by a
  # killed helm op is invisible and a re-run with a different id would overwrite
  # it once recovery clears the wedge. The mock returns a pending-upgrade row.
  helm() {
    if [ "$1" = list ]; then
      record "helm $*"
      printf '%s\n' 'NAME NAMESPACE REVISION UPDATED STATUS CHART APP VERSION' \
                    'oldrel default 3 2026-01-01 pending-upgrade client-1.4.3 1.4.3'
      return 0
    fi
    if [ "$1" = get ] && [ "$2" = values ]; then echo 'clientId: "otherclient"'; return 0; fi
    record "helm $*"; return 0
  }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'newclient\nmypw'
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"already runs the tracebloc client 'otherclient'"* ]] || return 1
  # the enumeration must name pending explicitly, or the wedge would be invisible
  mock_calls | grep -q -- '--pending'
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]] || return 1
}

# ── _recover_pending_helm_release no-destroy mode (adopt path, #554 Bugbot) ──
# The reconcile/adopt path reuses the release's STORED credential, so recovery
# there must never uninstall a pending-install (that would drop the sole copy of
# the write-only credential). Rollback (non-destructive) is still allowed.

@test "_recover_pending_helm_release no-destroy: pending-install is REFUSED, never uninstalled" {
  _bounded() { shift; "$@"; }
  helm() {
    if [[ "$1" == status ]]; then printf 'NAME: rel\nSTATUS: pending-install\nREVISION: 1\n'; return 0; fi
    record "helm $*"; return 0
  }
  run _recover_pending_helm_release rel ns no-destroy
  [ "$status" -eq 1 ] || return 1                 # caller fails closed
  # remedy must be actionable + credential-preserving, NOT a useless rollback
  [[ "$output" == *"get values rel"* ]] || return 1
  [[ "$output" == *"clientPassword"* ]] || return 1
  [[ "$output" != *"rollback"* ]] || return 1
  run mock_calls
  [[ "$output" != *"helm uninstall"* ]] || return 1   # credential preserved
}

@test "_recover_pending_helm_release no-destroy: uninstalling is REFUSED, never uninstalled" {
  _bounded() { shift; "$@"; }
  helm() {
    if [[ "$1" == status ]]; then printf 'NAME: rel\nSTATUS: uninstalling\nREVISION: 3\n'; return 0; fi
    record "helm $*"; return 0
  }
  run _recover_pending_helm_release rel ns no-destroy
  [ "$status" -eq 1 ] || return 1
  run mock_calls
  [[ "$output" != *"helm uninstall"* ]] || return 1
}

@test "_recover_pending_helm_release no-destroy: pending-upgrade STILL rolls back (non-destructive)" {
  _bounded() { shift; "$@"; }
  helm() {
    if [[ "$1" == status ]]; then printf 'NAME: rel\nSTATUS: pending-upgrade\nREVISION: 5\n'; return 0; fi
    record "helm $*"; return 0
  }
  run _recover_pending_helm_release rel ns no-destroy
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q "helm rollback rel -n ns"
}

# #554 Bugbot/audit: the status READ is a plain command-substitution assignment.
# Under `set -euo pipefail`, `helm status` on an ABSENT release (fresh install)
# exits non-zero -> the pipeline is non-zero -> a bare `var=$(...)` assignment
# would abort. Both call sites use `if !` (which suppresses errexit), but a bare
# call must not abort either — the `|| _status=""` guard proves it.
@test "_recover_pending_helm_release: bare call under set -e with a failing helm status does NOT abort" {
  run bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/install-client-helm.sh"
    LOG_FILE=/dev/null
    _bounded() { shift; "$@"; }
    helm() { return 1; }              # status (and everything) fails: absent release
    warn() { :; }; info() { :; }; log() { :; }
    set -euo pipefail                 # enable AFTER sourcing, like the real installer
    _recover_pending_helm_release rel ns    # BARE call, not in an if-condition
    echo "REACHED_END"
  '
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "REACHED_END" ] || return 1
}

# #554 Bugbot: a WEDGED status with a long body must not be wiped under pipefail.
# awk's early `exit` SIGPIPEs helm (141); the old `... | awk exit || _status=""`
# then wiped the parsed "pending-upgrade" and recovery silently no-op'd. The
# here-string parse must keep the value so rollback actually runs.
@test "_recover_pending_helm_release: long wedged status is NOT wiped under set -o pipefail" {
  local log="$BATS_TEST_TMPDIR/reclog"; : > "$log"
  run bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/install-client-helm.sh"
    LOG_FILE="'"$log"'"
    _bounded() { shift; "$@"; }
    helm() {
      if [ "$1" = status ]; then
        printf "NAME: rel\nSTATUS: pending-upgrade\nREVISION: 5\n"
        i=0; while [ "$i" -lt 4000 ]; do printf "NOTES body line %d\n" "$i"; i=$((i+1)); done
        return 0
      fi
      if [ "$1" = rollback ]; then echo "ROLLED_BACK_MARKER"; return 0; fi
      return 0
    }
    warn() { :; }; info() { :; }; log() { :; }
    set -euo pipefail
    _recover_pending_helm_release rel ns    # bare call, under pipefail
  '
  [ "$status" -eq 0 ] || return 1
  grep -q ROLLED_BACK_MARKER "$log" || return 1   # status parsed -> rollback ran (not wiped)
}

# ── backend#1778 / client#686: early-exit pipe consumers ────────────────────
# Two probes in this lib let a consumer close the pipe on its first match, which
# SIGPIPEs the producer; pipefail turns that into 141 and the `if` reads it as
# "no match". In every fixture below the MATCH LEADS and the filler comes from an
# EXTERNAL command (seq) — with the match appended last, grep has to read the
# whole stream and never closes early, so the test would pass unfixed.

@test "_resolve_chart_ref: an existing repo in a large repo list is NOT re-added (backend#1778)" {
  # Misbranch consequence: the `if !` reads 141 as "repo absent" and re-runs
  # `helm repo add` on the next line — which is unguarded, and fails when the
  # name already exists with a different URL, aborting the install under set -e.
  TRACEBLOC_CHART_PATH=""
  TRACEBLOC_HELM_REPO_NAME="tracebloc"
  TRACEBLOC_HELM_REPO_URL="https://tracebloc.github.io/client"
  TRACEBLOC_CHART_NAME="client"
  # NOTE: no trailing `return 0` in this mock. The producer's exit status IS the
  # signal under test — an explicit `return 0` would mask seq's SIGPIPE death and
  # make the test vacuous.
  helm() {
    record "helm $*"
    if [ "${1:-}" = repo ] && [ "${2:-}" = list ]; then
      printf 'tracebloc\thttps://tracebloc.github.io/client\n'   # match LEADS
      seq 1 200000                                               # then past the buffer
    fi
  }
  set -o pipefail
  chart_ref=""
  run _resolve_chart_ref
  [ "$status" -eq 0 ] || return 1
  calls="$(mock_calls)"
  [[ "$calls" != *"repo add"* ]] || return 1     # the whole point
  [[ "$calls" == *"repo update"* ]] || return 1  # normal flow still ran
}

@test "_resolve_chart_ref: a genuinely absent repo IS still added (the fix did not invert it)" {
  TRACEBLOC_CHART_PATH=""
  TRACEBLOC_HELM_REPO_NAME="tracebloc"
  TRACEBLOC_HELM_REPO_URL="https://tracebloc.github.io/client"
  TRACEBLOC_CHART_NAME="client"
  helm() {
    record "helm $*"
    if [ "${1:-}" = repo ] && [ "${2:-}" = list ]; then printf 'someone-else\thttps://example.invalid/\n'; fi
    return 0
  }
  set -o pipefail
  chart_ref=""
  run _resolve_chart_ref
  [ "$status" -eq 0 ] || return 1
  [[ "$(mock_calls)" == *"repo add"* ]] || return 1
}

@test "_resolve_mysql_engine: a sticky 8.4 in a large values.yaml is honoured (backend#1778)" {
  # Misbranch consequence: the second grep closes the pipe on its first hit and
  # SIGPIPEs the first, so a machine that opted into 8.4 resolves to 5.7 — and
  # MySQL 5.7 will not open an 8.4 datadir.
  values_file="$BATS_TEST_TMPDIR/values.yaml"
  {
    printf 'mysqlClient:\n  image:\n    repo: mysql\n    tag: "8.4"\n'   # match LEADS
    # More mysqlClient: blocks so `grep -A 3` keeps producing long after the
    # second grep has already matched and closed the pipe.
    seq 1 60000 | sed 's/^/mysqlClient:\
  filler: /'
  } > "$values_file"
  TB_MYSQL_ENGINE=auto
  existing_id=""
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/nonexistent-data"
  set -o pipefail
  run bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/install-client-helm.sh"
    LOG_FILE=/dev/null
    set -o pipefail
    values_file="'"$values_file"'"; TB_MYSQL_ENGINE=auto; existing_id=""
    HOST_DATA_DIR="'"$BATS_TEST_TMPDIR"'/nonexistent-data"
    # ARCH must be amd64: on arm64 a FRESH auto-resolve also lands on 8.4, so the
    # misbranch would be invisible and the test vacuous. On amd64 the fallthrough
    # is 5.7, so "8.4" can only come from the sticky check actually matching.
    ARCH=x86_64
    _resolve_mysql_engine >/dev/null 2>&1
    printf "%s\n" "${TB_MYSQL_ENGINE_RESOLVED:-unset}"
  '
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "8.4" ] || return 1
}

@test "_resolve_mysql_engine: a large values.yaml with NO 8.4 pin does not become sticky" {
  values_file="$BATS_TEST_TMPDIR/values-no84.yaml"
  {
    printf 'mysqlClient:\n  image:\n    repo: mysql\n    tag: "5.7"\n'
    seq 1 60000 | sed 's/^/mysqlClient:\
  filler: /'
  } > "$values_file"
  run bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/install-client-helm.sh"
    LOG_FILE=/dev/null
    set -o pipefail
    values_file="'"$values_file"'"; TB_MYSQL_ENGINE=auto; existing_id=""
    HOST_DATA_DIR="'"$BATS_TEST_TMPDIR"'/nonexistent-data"
    ARCH=x86_64
    _resolve_mysql_engine >/dev/null 2>&1
    printf "%s\n" "${TB_MYSQL_ENGINE_RESOLVED:-unset}"
  '
  [ "$status" -eq 0 ] || return 1
  [ "$output" != "8.4" ] || return 1
}

# ── _adopt_orphaned_gpu_device_plugin (client#564) ───────────────────────────
# On the GPU path, adopt a Helm-unowned device-plugin DaemonSet left by the old
# imperative apply so `helm upgrade --install` takes it over instead of colliding.
@test "_adopt_orphaned_gpu_device_plugin: CPU-only host is a no-op (kubectl untouched)" {
  GPU_VENDOR=none
  kubectl() { echo "kubectl $*" >>"$MOCK_CALLS"; }
  run _adopt_orphaned_gpu_device_plugin
  [ "$status" -eq 0 ] || return 1
  [ ! -s "$MOCK_CALLS" ] || { cat "$MOCK_CALLS"; return 1; }
}

@test "_adopt_orphaned_gpu_device_plugin: an existing nvidia orphan is labelled+annotated for Helm adoption" {
  GPU_VENDOR=nvidia; TB_NAMESPACE=tb; LOG_FILE=/dev/null
  kubectl() {
    echo "kubectl $*" >>"$MOCK_CALLS"
    case "$1" in get) return 0 ;; esac   # DS present
  }
  run _adopt_orphaned_gpu_device_plugin
  [ "$status" -eq 0 ] || { cat "$MOCK_CALLS"; return 1; }
  grep -q 'label daemonset nvidia-device-plugin-daemonset .*app.kubernetes.io/managed-by=Helm' "$MOCK_CALLS" || { cat "$MOCK_CALLS"; return 1; }
  grep -q 'annotate daemonset nvidia-device-plugin-daemonset .*meta.helm.sh/release-name=tb' "$MOCK_CALLS" || { cat "$MOCK_CALLS"; return 1; }
}

@test "_adopt_orphaned_gpu_device_plugin: no orphan present -> no label/annotate (fresh host)" {
  GPU_VENDOR=nvidia; TB_NAMESPACE=tb; LOG_FILE=/dev/null
  kubectl() {
    echo "kubectl $*" >>"$MOCK_CALLS"
    case "$1" in get) return 1 ;; esac   # DS absent
  }
  run _adopt_orphaned_gpu_device_plugin
  [ "$status" -eq 0 ] || return 1
  ! grep -q 'label daemonset' "$MOCK_CALLS" || { cat "$MOCK_CALLS"; return 1; }
  ! grep -q 'annotate daemonset' "$MOCK_CALLS" || { cat "$MOCK_CALLS"; return 1; }
}

@test "_adopt_orphaned_gpu_device_plugin: a live API error does not fake-adopt (no label/annotate), still returns 0 (client#564 Bugbot)" {
  # A wedged/slow API must not be read as 'absent' and silently skipped as if
  # adopted; but it must also not abort (GPU is optional) — warn and return 0.
  GPU_VENDOR=nvidia; TB_NAMESPACE=tb; LOG_FILE=/dev/null
  kubectl() {
    echo "kubectl $*" >>"$MOCK_CALLS"
    case "$1" in get) echo "Unable to connect to the server: dial tcp timeout" >&2; return 1 ;; esac
  }
  run _adopt_orphaned_gpu_device_plugin
  [ "$status" -eq 0 ] || { cat "$MOCK_CALLS"; return 1; }
  ! grep -q 'label daemonset' "$MOCK_CALLS" || { cat "$MOCK_CALLS"; return 1; }
}

@test "_adopt_orphaned_gpu_device_plugin: a failed adoption removes the orphan so the install isn't bricked (client#564 Bugbot)" {
  # If label/annotate fail, the orphan stays unowned and helm would die
  # 'exists and cannot be imported'; delete it so the chart recreates a clean copy.
  GPU_VENDOR=nvidia; TB_NAMESPACE=tb; LOG_FILE=/dev/null
  kubectl() {
    echo "kubectl $*" >>"$MOCK_CALLS"
    case "$1" in
      get)    return 0 ;;    # orphan present
      label)  return 1 ;;    # adoption fails
      delete) return 0 ;;
    esac
  }
  run _adopt_orphaned_gpu_device_plugin
  [ "$status" -eq 0 ] || { cat "$MOCK_CALLS"; return 1; }
  grep -q 'delete daemonset nvidia-device-plugin-daemonset' "$MOCK_CALLS" || { cat "$MOCK_CALLS"; return 1; }
}

@test "_adopt_orphaned_gpu_device_plugin: a fresh-host NotFound under set -e does not abort the caller (client#564 Bugbot)" {
  # `run` disables errexit, so exercise the real set -e path in a subshell: a
  # bare `probe=$(...); rc=$?` would abort here on the non-zero NotFound lookup
  # (killing installer step e on a fresh GPU host) before the absent branch runs.
  GPU_VENDOR=nvidia; TB_NAMESPACE=tb; LOG_FILE=/dev/null
  kubectl() { echo "Error from server (NotFound): daemonsets.apps not found" >&2; return 1; }
  local out st
  out=$( set -e; _adopt_orphaned_gpu_device_plugin && echo REACHED ) 2>/dev/null; st=$?
  [ "$st" -eq 0 ] || { echo "aborted under set -e (st=$st)"; return 1; }
  [[ "$out" == *REACHED* ]] || { echo "did not reach end: '$out'"; return 1; }
}

@test "install-client-helm declares singleNode: true in the node-local storage branch (client#560)" {
  local lib="$BATS_TEST_DIRNAME/../lib/install-client-helm.sh"
  # node-local (RFC-0003 Option C, local-path StorageClass) is a single
  # schedulable node (AGENTS=0/SERVERS=1), so the values it emits must declare
  # singleNode: true — otherwise hostPath.enabled=false misclassifies it as
  # multi-node and the chart renders an undrainable minAvailable:1 PDB (#560).
  grep -q 'singleNode: true' "$lib" || return 1
  # ...and it must live in the node-local (local-path) values block.
  awk '/name: local-path/{f=1} f && /singleNode: true/{found=1} END{exit !found}' "$lib" || return 1
}
