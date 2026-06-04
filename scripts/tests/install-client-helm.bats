#!/usr/bin/env bats
# Tests for scripts/lib/install-client-helm.sh — credential verification (#717)
# + the install_client_helm flow.
load test_helper

setup() {
  load_lib install-client-helm.sh
  MOCK_CALLS="$(mktemp)"
  GPU_VENDOR=none
  CLIENT_ENV=""
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
  [[ "$output" == *"Connected to tracebloc"* ]]
  grep -q 'clientId: "myid"' "$HOST_DATA_DIR/values.yaml"
  grep -q "clientPassword: 'mypw'" "$HOST_DATA_DIR/values.yaml"
  mock_calls | grep -q "helm upgrade --install tracebloc"
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
    if [ "$1" = list ]; then echo '[{"name":"oldrel","namespace":"default","chart":"client-1.4.3"}]'; return 0; fi
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

@test "install_client_helm: same client re-run is allowed (upgrade in place)" {
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"; mkdir -p "$HOST_DATA_DIR"
  _ensure_tracebloc_dirs() { :; }
  _ensure_release_dirs() { :; }
  _ensure_helm_runnable() { :; }
  helm() {
    if [ "$1" = list ]; then echo '[{"name":"tracebloc","namespace":"tracebloc","chart":"client-1.4.3"}]'; return 0; fi
    if [ "$1" = get ] && [ "$2" = values ]; then echo 'clientId: "sameid"'; return 0; fi
    record "helm $*"; return 0
  }
  verify_credentials() { printf valid; }
  run install_client_helm <<< $'sameid\nmypw'
  [ "$status" -eq 0 ]
  run mock_calls
  [[ "$output" == *"helm upgrade --install tracebloc"* ]]
}
