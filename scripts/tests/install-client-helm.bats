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
  # _bounded wraps probes in timeout(1) (the pending-* recovery `helm status`),
  # which can't exec a `helm` shell-function mock: on a runner that HAS timeout(1)
  # it would exec the real helm binary instead of the stub. Passthrough so the
  # mocked helm stays visible; _bounded's deadline behaviour is covered in
  # common.bats. Same pattern as cluster.bats / preflight.bats.
  _bounded() { shift; "$@"; }
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
  HTTP_PROXY="http://proxy.charite.de:8080"
  run _chart_proxy_env_yaml
  [[ "$output" == *'HTTP_PROXY_HOST: "proxy.charite.de"'* ]] || return 1
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
  HTTP_PROXY="http://proxy.charite.de:8080"; NO_PROXY=".charite.de"
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  # NB: the "Corporate proxy detected" notice goes through log(), which the test
  # harness routes to /dev/null — so assert on the generated file, not $output.
  grep -q 'HTTP_PROXY_HOST: "proxy.charite.de"' "$HOST_DATA_DIR/values.yaml"
  grep -q 'HTTP_PROXY_PORT: "8080"' "$HOST_DATA_DIR/values.yaml"
  grep -q 'NO_PROXY: ".charite.de"' "$HOST_DATA_DIR/values.yaml"
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

@test "training size: below-floor machine falls back to the static default" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  kubectl() { printf '2 4Gi\n'; }        # 4−3 GiB = 1 GiB < the 2 GiB floor
  run _training_resources
  [ "$output" = "cpu=2,memory=8Gi" ] || return 1
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

# ── pending-* wedge recovery (#554 / Bugbot #619) ──────────────────────────
@test "_last_deployed_revision: newest deployed/superseded revision, ignoring failed + pending (Bugbot #619)" {
  # An interrupted atomic rollback: r3 was the last good release, r4 the failed
  # upgrade, r5 the pending rollback. The recovery target is r3 — NOT r4 (which a
  # bare `helm rollback` would land on).
  helm() {
    printf -- '- chart: client-1.9.19\n  revision: 3\n  status: superseded\n'
    printf -- '- chart: client-1.9.20\n  revision: 4\n  status: failed\n'
    printf -- '- chart: client-1.9.20\n  revision: 5\n  status: pending-rollback\n'
  }
  run _last_deployed_revision munich munich
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "3" ] || return 1
}

@test "_last_deployed_revision: no good revision -> empty (never a bad target)" {
  helm() {
    printf -- '- revision: 1\n  status: failed\n- revision: 2\n  status: pending-install\n'
  }
  run _last_deployed_revision munich munich
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "_reconcile_pending_release: pending-upgrade rolls back to the last DEPLOYED revision, not a bare rollback (Bugbot #619)" {
  spin_cmd_bounded() { shift 2; "$@"; }   # exec the mutating cmd so the mock records it
  helm() {
    if [ "$1" = status ];  then printf 'info:\n  status: pending-upgrade\n'; return 0; fi
    if [ "$1" = history ]; then printf -- '- chart: client-1.9.18\n  revision: 6\n  status: superseded\n- chart: client-1.9.19\n  revision: 7\n  status: deployed\n- chart: client-1.9.20\n  revision: 8\n  status: pending-upgrade\n'; return 0; fi
    record "helm $*"; return 0
  }
  run _reconcile_pending_release munich munich
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q "helm rollback munich 7 -n munich"       # explicit last-good revision
  run mock_calls
  [[ "$output" != *"helm rollback munich -n munich"* ]] || return 1   # never a bare rollback
}

@test "_reconcile_pending_release: pending-* with no deployed revision leaves it wedged, no bad rollback (Bugbot #619)" {
  spin_cmd_bounded() { shift 2; "$@"; }
  helm() {
    if [ "$1" = status ];  then printf 'info:\n  status: pending-rollback\n'; return 0; fi
    if [ "$1" = history ]; then printf -- '- chart: client-1.9.20\n  revision: 1\n  status: failed\n- chart: client-1.9.20\n  revision: 2\n  status: pending-rollback\n'; return 0; fi
    record "helm $*"; return 0
  }
  run _reconcile_pending_release munich munich
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"no prior deployed revision"* ]] || return 1
  run mock_calls
  [[ "$output" != *"helm rollback"* ]] || return 1
}

@test "_reconcile_pending_release: pending-install WITH a preserve file stashes values + flags a reinstall (Bugbot #619)" {
  spin_cmd_bounded() { shift 2; "$@"; }
  local pf; pf="$(mktemp)"
  helm() {
    if [ "$1" = status ];        then printf 'info:\n  status: pending-install\n'; return 0; fi
    if [ "$1 $2" = "get values" ]; then printf 'clientId: "123"\nclientPassword: "s3cr3t"\n'; return 0; fi
    record "helm $*"; return 0
  }
  TB_PENDING_REINSTALL=0
  _reconcile_pending_release munich munich "$pf"
  [ "$TB_PENDING_REINSTALL" = "1" ] || return 1                 # caller must reinstall
  grep -q "clientPassword" "$pf" || return 1                    # the write-only password was preserved
  mock_calls | grep -q "helm uninstall munich -n munich"
}

@test "_reconcile_pending_release: pending-install WITHOUT a preserve file just uninstalls (normal install path)" {
  spin_cmd_bounded() { shift 2; "$@"; }
  helm() {
    if [ "$1" = status ]; then printf 'info:\n  status: pending-install\n'; return 0; fi
    record "helm $*"; return 0
  }
  TB_PENDING_REINSTALL=9
  _reconcile_pending_release munich munich
  [ "$TB_PENDING_REINSTALL" = "0" ] || return 1                 # no reinstall signalled
  mock_calls | grep -q "helm uninstall munich -n munich"
  run mock_calls
  [[ "$output" != *"helm get values"* ]] || return 1           # never reads values on the normal path
}

@test "install_client_helm: adopt + pending-install recovers by reinstalling from preserved values, not --reuse-values (Bugbot #619)" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  kubectl() { record "kubectl $*"; return 0; }
  # The adopted client's release is wedged in pending-install (a first install was
  # killed). Recovery must uninstall it, but the write-only password lives ONLY in
  # that release's stored values — so we preserve them and reinstall, rather than a
  # --reuse-values upgrade against a release that no longer exists.
  helm() {
    if [[ "$1" == list ]];            then echo "munich munich 1 now pending-install client-1.8.2 1.8.2"; return 0; fi
    if [[ "$1 $2" == "upgrade --help" ]]; then echo "  --reset-then-reuse-values"; return 0; fi
    if [[ "$1" == status ]];          then printf 'info:\n  status: pending-install\n'; return 0; fi
    if [[ "$1 $2" == "get values" ]]; then printf 'clientId: "123"\nclientPassword: "s3cr3t"\n'; return 0; fi
    record "helm $*"; return 0
  }
  verify_credentials() { echo "VERIFY_CALLED"; printf invalid; }
  export TRACEBLOC_CLIENT_ADOPTED=1 TRACEBLOC_CLIENT_ID=0e9db54e-c9c0-4bf3-9ff2-1646da307019
  run install_client_helm </dev/null
  [ "$status" -eq 0 ] || return 1
  mock_calls | grep -q "helm uninstall munich"                  # cleared the half-installed release
  mock_calls | grep -q "helm upgrade --install munich"          # reinstalled (not an in-place upgrade)
  run mock_calls
  [[ "$output" != *"--reuse-values"* ]] || return 1             # nothing to reuse — release was gone
  [[ "$output" == *"--set clientId=0e9db54e-c9c0-4bf3-9ff2-1646da307019"* ]] || return 1
}

@test "install_cleanup shreds a lingering preserved-values credential file (Bugbot #619)" {
  # A signal between capture and the normal rm must not leave the write-only
  # clientPassword on disk — install_cleanup is the EXIT/INT/TERM backstop.
  local f; f="$(mktemp)"; printf 'clientPassword: "s3cr3t"\n' > "$f"
  _TB_PENDING_VALUES_FILE="$f"
  install_cleanup >/dev/null 2>&1 || true
  [ ! -e "$f" ] || return 1
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
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ] || return 1
  ! grep -q 'mysqlClient:' "$HOST_DATA_DIR/values.yaml" || return 1
}
