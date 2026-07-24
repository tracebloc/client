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
}

# ── _backend_url ───────────────────────────────────────────────────────────
@test "_backend_url: default (unset) -> prod" {
  unset CLIENT_ENV
  run _backend_url
  [ "$output" = "https://api.tracebloc.io/" ]
}

@test "_backend_url: dev" {
  CLIENT_ENV=dev
  run _backend_url
  [ "$output" = "https://dev-api.tracebloc.io/" ]
}

@test "_backend_url: stg" {
  CLIENT_ENV=stg
  run _backend_url
  [ "$output" = "https://stg-api.tracebloc.io/" ]
}

@test "_backend_url: unknown -> prod" {
  CLIENT_ENV=whatever
  run _backend_url
  [ "$output" = "https://api.tracebloc.io/" ]
}

# ── verify_credentials (mock curl's http_code on stdout) ───────────────────
@test "verify_credentials: HTTP 200 -> valid" {
  curl() { echo 200; }
  run verify_credentials id pw
  [ "$output" = valid ]
}

@test "verify_credentials: HTTP 400 -> invalid" {
  curl() { echo 400; }
  run verify_credentials id pw
  [ "$output" = invalid ]
}

@test "verify_credentials: HTTP 401 -> inactive" {
  curl() { echo 401; }
  run verify_credentials id pw
  [ "$output" = inactive ]
}

@test "verify_credentials: HTTP 429 -> unverified" {
  curl() { echo 429; }
  run verify_credentials id pw
  [ "$output" = unverified ]
}

@test "verify_credentials: connection failure -> unverified" {
  curl() { return 7; }
  run verify_credentials id pw
  [ "$output" = unverified ]
}

# ── sanitizers ─────────────────────────────────────────────────────────────
@test "_strip_paste_garbage: unwraps bracketed-paste ESC markers" {
  run _strip_paste_garbage "$(printf '\e[200~secret\e[201~')"
  [ "$output" = "secret" ]
}

@test "_strip_paste_garbage: strips C0 control chars, keeps text" {
  run _strip_paste_garbage "$(printf 'ab\001cd')"
  [ "$output" = "abcd" ]
}

@test "_sanitize_workspace_name: lowercases + dashes" {
  run _sanitize_workspace_name "My Team_1"
  [ "$output" = "my-team-1" ]
}

@test "_sanitize_workspace_name: all-invalid -> default" {
  run _sanitize_workspace_name "@@@"
  [ "$output" = "default" ]
}

@test "_sanitize_workspace_name: collapses + trims dashes" {
  run _sanitize_workspace_name "a--b-"
  [ "$output" = "a-b" ]
}

# ── _extract_yaml_value ────────────────────────────────────────────────────
@test "_extract_yaml_value: double-quoted" {
  f="$BATS_TEST_TMPDIR/v"; printf 'clientId: "abc-123"\n' >"$f"
  run _extract_yaml_value "$f" clientId
  [ "$output" = "abc-123" ]
}

@test "_extract_yaml_value: single-quoted with '' escape" {
  f="$BATS_TEST_TMPDIR/v"; printf "clientPassword: 'a''b'\n" >"$f"
  run _extract_yaml_value "$f" clientPassword
  [ "$output" = "a'b" ]
}

@test "_extract_yaml_value: missing key -> empty" {
  f="$BATS_TEST_TMPDIR/v"; printf 'other: x\n' >"$f"
  run _extract_yaml_value "$f" clientId
  [ "$output" = "" ]
}

# ── _ensure_helm_runnable (happy path) ─────────────────────────────────────
@test "_ensure_helm_runnable: helm runs -> ok" {
  helm() { return 0; }
  run _ensure_helm_runnable
  [ "$status" -eq 0 ]
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
  [ "$status" -eq 0 ]
  [[ "$output" == *"Credentials verified"* ]]
  [[ "$output" == *"tracebloc installed"* ]]
  grep -q 'clientId: "myid"' "$HOST_DATA_DIR/values.yaml"
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
  [ "$status" -eq 0 ]
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
  [ "$status" -eq 0 ]
  ! grep -q 'datasetPath:' "$HOST_DATA_DIR/values.yaml"
  ! grep -q 'HOST_UID:' "$HOST_DATA_DIR/values.yaml"
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
  [ "$status" -eq 0 ]
  [[ "$output" == *"Credentials verified"* ]]
  [[ "$output" != *"Client ID:"* ]]
  grep -q 'clientId: "envid"' "$HOST_DATA_DIR/values.yaml"
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
  [ "$status" -eq 0 ]
  [[ "$output" != *"Client ID:"* ]]                # no credential prompt
  [[ "$output" != *"VERIFY_CALLED"* ]]             # no verify
  [[ "$output" == *"reconciling"* ]]
  [[ "$output" == *"tracebloc installed"* ]]
  # Reconciled the LIVE release in place (name 'munich') AND healed clientId to the
  # adopted UUID, reusing the stored password — NOT a fresh --install, no duplicate.
  mock_calls | grep -q "helm upgrade munich"
  mock_calls | grep -q -- "--reset-then-reuse-values"
  mock_calls | grep -q -- "--set clientId=0e9db54e-c9c0-4bf3-9ff2-1646da307019"
  run mock_calls
  [[ "$output" != *"helm upgrade --install"* ]]
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
  [ "$status" -eq 0 ]
  [[ "$output" != *"Client ID:"* ]]                # no prompt (no bail)
  [[ "$output" != *"VERIFY_CALLED"* ]]             # no verify
  [[ "$output" == *"tracebloc installed"* ]]
  mock_calls | grep -q "helm upgrade munich"
  mock_calls | grep -q -- "--reset-then-reuse-values"
  run mock_calls
  [[ "$output" != *"helm upgrade --install"* ]]
  [[ "$output" != *"--set clientId"* ]]            # nothing to heal with → no --set
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
  [ "$status" -eq 0 ]
  mock_calls | grep -q -- "--reuse-values"
  run mock_calls
  [[ "$output" != *"--reset-then-reuse-values"* ]]
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
  [ "$status" -eq 0 ]
  [[ "$output" == *"no live tracebloc release"* ]]     # explained the fallback
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
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected"* ]]
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]]
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
  [ "$status" -ne 0 ]
  [[ "$output" == *"TRACEBLOC_CLIENT_ID"* ]]
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]]
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
  [ "$status" -ne 0 ]
  [[ "$output" == *"TRACEBLOC_CLIENT_ID"* ]]
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]]
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
  [ "$status" -eq 0 ]
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
  [ "$status" -eq 0 ]
  [[ "$output" == *"rejected"* ]]
  [[ "$output" == *"Credentials verified"* ]]
  grep -q 'clientId: "goodid"' "$HOST_DATA_DIR/values.yaml"
}

@test "install_client_helm: inactive account -> errors, no helm install" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf inactive; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not active"* ]]
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]]
}

@test "install_client_helm: unverified backend -> proceeds with install" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() { record "helm $*"; return 0; }
  verify_credentials() { printf unverified; }
  run install_client_helm <<< $'myid\nmypw'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Couldn't reach tracebloc"* ]]
  run mock_calls
  [[ "$output" == *"helm upgrade --install"* ]]
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
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"helm upgrade --install devns"* ]]
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
  [ "$status" -eq 0 ]
  grep -q 'clientId: "previd"' "$HOST_DATA_DIR/values.yaml"
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
  [ "$status" -ne 0 ]
  [[ "$output" == *"Too many failed attempts"* ]]
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]]
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
  [ "$status" -ne 0 ]
  [[ "$output" == *"already runs the tracebloc client 'otherclient'"* ]]
  [[ "$output" == *"one client per machine"* ]]
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]]
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
  [ "$status" -ne 0 ]
  [[ "$output" == *"Couldn't determine which tracebloc client"* ]]
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]]
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
  [ "$status" -ne 0 ]
  [[ "$output" == *"Couldn't determine which tracebloc client"* ]]
  run mock_calls
  [[ "$output" != *"helm upgrade"* ]]
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
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"helm upgrade --install tracebloc"* ]]
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
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"helm upgrade --install tracebloc"* ]]   # reused existing namespace
  [[ "$output" != *"acme-corp"* ]]                          # no second release forked
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
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"helm upgrade --install tracebloc"* ]]   # reused existing namespace
  [[ "$output" != *"acme-corp"* ]]                          # no second release forked
}

# ── _chart_proxy_env_yaml (#242: host proxy -> split chart keys) ─────────────
@test "_chart_proxy_env_yaml: no proxy on host -> empty" {
  run _chart_proxy_env_yaml
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_chart_proxy_env_yaml: host:port -> HTTP_PROXY_HOST + HTTP_PROXY_PORT" {
  HTTP_PROXY="http://proxy.charite.de:8080"
  run _chart_proxy_env_yaml
  [[ "$output" == *'HTTP_PROXY_HOST: "proxy.charite.de"'* ]]
  [[ "$output" == *'HTTP_PROXY_PORT: "8080"'* ]]
  [[ "$output" != *"HTTP_PROXY_USERNAME"* ]]
}

@test "_chart_proxy_env_yaml: prefers HTTPS_PROXY when HTTP_PROXY unset" {
  HTTPS_PROXY="http://proxy.example.com:3128"
  run _chart_proxy_env_yaml
  [[ "$output" == *'HTTP_PROXY_HOST: "proxy.example.com"'* ]]
  [[ "$output" == *'HTTP_PROXY_PORT: "3128"'* ]]
}

@test "_chart_proxy_env_yaml: authenticated proxy -> username/password split" {
  HTTPS_PROXY="http://user:s3cr3t@proxy.example.com:3128"
  run _chart_proxy_env_yaml
  [[ "$output" == *'HTTP_PROXY_HOST: "proxy.example.com"'* ]]
  [[ "$output" == *'HTTP_PROXY_PORT: "3128"'* ]]
  [[ "$output" == *'HTTP_PROXY_USERNAME: "user"'* ]]
  [[ "$output" == *'HTTP_PROXY_PASSWORD: "s3cr3t"'* ]]
}

@test "_chart_proxy_env_yaml: '@' in password tolerated (split on last @)" {
  http_proxy="http://user:p@ss@proxy.example.com:8080"
  run _chart_proxy_env_yaml
  [[ "$output" == *'HTTP_PROXY_HOST: "proxy.example.com"'* ]]
  [[ "$output" == *'HTTP_PROXY_PASSWORD: "p@ss"'* ]]
}

@test "_chart_proxy_env_yaml: no port -> HTTP_PROXY_HOST only, no PORT line" {
  HTTP_PROXY="http://proxy.example.com"
  run _chart_proxy_env_yaml
  [[ "$output" == *'HTTP_PROXY_HOST: "proxy.example.com"'* ]]
  [[ "$output" != *"HTTP_PROXY_PORT"* ]]
}

@test "_chart_proxy_env_yaml: passes host NO_PROXY through (proxyEnv unions cluster ranges)" {
  HTTP_PROXY="http://proxy:8080"; NO_PROXY="myinternal.example,.corp"
  run _chart_proxy_env_yaml
  [[ "$output" == *'NO_PROXY: "myinternal.example,.corp"'* ]]
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
  [ "$status" -eq 0 ]
  # NB: the "Corporate proxy detected" notice goes through log(), which the test
  # harness routes to /dev/null — so assert on the generated file, not $output.
  grep -q 'HTTP_PROXY_HOST: "proxy.charite.de"' "$HOST_DATA_DIR/values.yaml"
  grep -q 'HTTP_PROXY_PORT: "8080"' "$HOST_DATA_DIR/values.yaml"
  grep -q 'NO_PROXY: ".charite.de"' "$HOST_DATA_DIR/values.yaml"
  # injection must not corrupt the rest of the env: block / file
  grep -q 'clientId: "myid"' "$HOST_DATA_DIR/values.yaml"
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
  [ "$status" -eq 0 ]
  ! grep -q 'HTTP_PROXY_HOST' "$HOST_DATA_DIR/values.yaml"
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
  [ "$status" -eq 0 ]
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
  [ "$status" -eq 0 ]
  grep -q 'RESOURCE_LIMITS: "cpu=2,memory=8Gi"' "$HOST_DATA_DIR/values.yaml"
  grep -q 'RESOURCE_REQUESTS: "cpu=2,memory=8Gi"' "$HOST_DATA_DIR/values.yaml"
}

# ── _training_resources (backend#1236, option A) ─────────────────────────────
@test "training size: TRACEBLOC_TRAINING_RESOURCES override wins, no probing" {
  TRACEBLOC_TRAINING_RESOURCES="cpu=4,memory=16Gi"
  helm() { record "helm $*"; return 1; }
  kubectl() { record "kubectl $*"; return 1; }
  run _training_resources
  [ "$output" = "cpu=4,memory=16Gi" ]
  run mock_calls
  [ -z "$output" ]
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
  [ "$output" = "cpu=4,memory=12Gi" ]
  run mock_calls
  [[ "$output" != *"get nodes"* ]]   # machine sizing never consulted
  # and the QUOTED form (our own values file style) parses identically
  helm() { printf 'env:\n  RESOURCE_LIMITS: "cpu=4,memory=12Gi"\n'; }
  run _training_resources
  [ "$output" = "cpu=4,memory=12Gi" ]
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
  [ "$output" = "cpu=11,memory=3Gi" ]
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
  [ "$output" = "cpu=11,memory=3Gi" ]   # 12−1 CPU; 6.76−3 GiB floored
}

@test "training size: below-floor machine falls back to the static default" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  has() { return 0; }
  kubectl() { printf '2 4Gi\n'; }        # 4−3 GiB = 1 GiB < the 2 GiB floor
  run _training_resources
  [ "$output" = "cpu=2,memory=8Gi" ]
}

@test "training size: kubectl absent falls back to the static default" {
  TB_NAMESPACE=tracebloc
  unset TRACEBLOC_TRAINING_RESOURCES
  helm() { return 1; }
  kubectl() { return 1; }   # the probe also fails -> carry skipped hermetically
  has() { case "$1" in kubectl) return 1 ;; *) return 0 ;; esac; }
  run _training_resources
  [ "$output" = "cpu=2,memory=8Gi" ]
}

# ── _download_services_progress (step-e count bar; must never hang/fail) ─────
@test "_download_services_progress: TB_NO_SERVICE_PROGRESS set -> immediate no-op" {
  export TB_NO_SERVICE_PROGRESS=1
  run _download_services_progress tracebloc
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_download_services_progress: kubectl absent -> silent skip (never fatal)" {
  unset TB_NO_SERVICE_PROGRESS
  has() { return 1; }                 # kubectl not present
  run _download_services_progress tracebloc
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_download_services_progress: empty namespace -> no-op" {
  unset TB_NO_SERVICE_PROGRESS
  has() { return 0; }
  run _download_services_progress ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
