#!/usr/bin/env bats
# Tests for provision.sh (RFC-0001 #838): sign in + `client create` BEFORE Helm,
# handing the minted credential + namespace to install_client_helm via env.
#
# The load-bearing properties: dual-mode (pre-supplied creds/values) skips
# sign-in; the browser-auth path is FATAL on a missing CLI / failed login /
# missing credential file; a mint hands all three env vars to Helm; an adopt
# hands only the namespace (no password) and lets Helm reconcile.

load test_helper

setup() {
  load_lib install-cli.sh             # common.sh + install-cli.sh (URL, the real fn)
  # shellcheck source=/dev/null
  source "${LIB_DIR}/provision.sh"
  step() { :; }
  info() { echo "INFO: $*"; }
  warn() { echo "WARN: $*"; }
  hint() { echo "HINT: $*"; }
  # error() is the real common.sh one (prints + exit 1) — fatal tests assert status.
  has() { return 0; }                 # default: CLI present after install
  install_tracebloc_cli() { :; }      # stubbed — covered by install-cli.bats
  LOG_FILE="$(mktemp)"
  HOST_DATA_DIR="$(mktemp -d)"
  unset TRACEBLOC_VALUES_FILE TRACEBLOC_CLIENT_ID TRACEBLOC_CLIENT_PASSWORD \
        TB_NAMESPACE TRACEBLOC_CLIENT_ADOPTED TRACEBLOC_CLIENT_LOCATION
  # Tests are non-interactive — never touch a real /dev/tty — and carry a machine
  # name so the mint tests clear provision.sh's required-name gate (the no-name
  # test unsets it). CREATE_ARGS_FILE captures the `client create` argv to assert on.
  _prompt_tty() { return 1; }
  export TRACEBLOC_CLIENT_NAME="ci-machine"
  CREATE_ARGS_FILE="$(mktemp)"
}

# A `tracebloc` stub: `login` succeeds; `client create` writes the given
# --credential-file with the env lines in $CRED_LINES.
_stub_tracebloc() {
  CRED_LINES="$1"
  tracebloc() {
    [ "$1" = "login" ] && return 0
    local f="" prev=""
    for a in "$@"; do [ "$prev" = "--credential-file" ] && f="$a"; prev="$a"; done
    # Record the real mint argv (the call that writes the credential file) so tests
    # can assert --name / --location are passed through.
    [ -n "$f" ] && printf '%s\n' "$*" >>"${CREATE_ARGS_FILE:-/dev/null}"
    [ -n "$f" ] && printf '%b' "$CRED_LINES" > "$f"
    return 0
  }
}

@test "provision_client: dual-mode (credentials) skips browser sign-in" {
  export TRACEBLOC_CLIENT_ID=abc TRACEBLOC_CLIENT_PASSWORD=xyz
  tracebloc() { echo "TRACEBLOC $*"; }   # must NOT be called for login/create
  run provision_client
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping browser sign-in"* ]]
  [[ "$output" != *"TRACEBLOC login"* ]]
}

@test "provision_client: dual-mode (values file) skips browser sign-in" {
  export TRACEBLOC_VALUES_FILE=/tmp/values.yaml
  tracebloc() { echo "TRACEBLOC $*"; }
  run provision_client
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping browser sign-in"* ]]
}

@test "provision_client: a CLI too old to provision falls back to manual sign-in (not fatal)" {
  # Old CLI: `login` / `client create` are unknown commands, so the --help probe
  # exits non-zero. provision_client must fall back (return 0) and let
  # install_client_helm collect credentials, NOT hard-fail on `tracebloc login`.
  tracebloc() { case "$1" in login|client) return 1 ;; *) return 0 ;; esac; }
  run provision_client
  [ "$status" -eq 0 ]
  [[ "$output" == *"falling back to manual sign-in"* ]]
  [[ "$output" != *"approve this machine in your browser"* ]]   # never entered the login flow
}

@test "provision_client: mint hands id+password+namespace to Helm" {
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=5\nTRACEBLOC_CLIENT_PASSWORD=pw9\nTB_NAMESPACE=my-ns\n'
  provision_client                       # called directly so exports persist
  [ "$TRACEBLOC_CLIENT_ID" = "5" ]
  [ "$TRACEBLOC_CLIENT_PASSWORD" = "pw9" ]
  [ "$TB_NAMESPACE" = "my-ns" ]
  # the credential file is transient — removed after sourcing
  [ ! -f "${HOST_DATA_DIR}/client-credential.env" ]
}

@test "provision_client: a stale TRACEBLOC_CLIENT_ADOPTED in the env does not misroute a mint" {
  export TRACEBLOC_CLIENT_ADOPTED=1      # leftover in the environment, NOT from the mint file
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=7\nTRACEBLOC_CLIENT_PASSWORD=pw\nTB_NAMESPACE=mns\n'  # mint: no ADOPTED line
  provision_client
  # mint path must win: the credential is handed to Helm, not dropped as if adopted
  [ "$TRACEBLOC_CLIENT_ID" = "7" ]
  [ "$TRACEBLOC_CLIENT_PASSWORD" = "pw" ]
  [ "$TB_NAMESPACE" = "mns" ]
}

@test "provision_client: adopt hands only the namespace (no password)" {
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=8\nTB_NAMESPACE=ex-ns\nTRACEBLOC_CLIENT_ADOPTED=1\n'
  provision_client
  [ "$TB_NAMESPACE" = "ex-ns" ]
  [ -z "${TRACEBLOC_CLIENT_PASSWORD:-}" ]   # no fresh credential on adopt
  [ "$TRACEBLOC_CLIENT_ID" = "8" ]          # adopted id kept → Step 5 heals the release's clientId to it
  [ "$TRACEBLOC_CLIENT_ADOPTED" = "1" ]     # marker kept → Step 5 takes the reconcile branch
}

@test "provision_client: missing CLI after install is fatal" {
  has() { return 1; }                    # CLI not resolvable after install
  tracebloc() { return 0; }
  run provision_client
  [ "$status" -ne 0 ]
  [[ "$output" == *"tracebloc CLI is required"* ]]
}

@test "provision_client: failed sign-in is fatal" {
  # Provisioning-capable CLI (the --help capability probe passes), but the actual
  # sign-in fails — that must still be fatal, not a silent fall-through.
  tracebloc() { [[ "$*" == *--help ]] && return 0; [ "$1" = "login" ] && return 1; return 0; }
  run provision_client
  [ "$status" -ne 0 ]
  [[ "$output" == *"Sign-in didn't complete"* ]]
}

@test "provision_client: client create writing no credential file is fatal" {
  tracebloc() { return 0; }              # login OK, create "succeeds" but writes nothing
  run provision_client
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not write the credential file"* ]]
}

@test "provision_client: a failed client create leaves no credential file behind" {
  tracebloc() {
    [[ "$*" == *--help ]] && return 0      # capability probe: CLI supports provisioning
    [ "$1" = "login" ] && return 0
    # create writes a PARTIAL (secret-bearing) file, then fails — must be cleaned up.
    local f="" prev=""
    for a in "$@"; do [ "$prev" = "--credential-file" ] && f="$a"; prev="$a"; done
    [ -n "$f" ] && printf 'TRACEBLOC_CLIENT_ID=5\nTRACEBLOC_CLIENT_PASSWORD=leak\n' >"$f"
    return 1
  }
  run provision_client
  [ "$status" -ne 0 ]
  [ ! -f "${HOST_DATA_DIR}/client-credential.env" ]
}

@test "provision_client: mint passes --name (+ --location) through to client create" {
  # `client create`'s output is redirected to the log, so it can't prompt and
  # hard-requires --name; provision.sh must pass it. Multi-word name checks the
  # array-based invocation keeps values with spaces intact.
  export TRACEBLOC_CLIENT_NAME="lab box 3" TRACEBLOC_CLIENT_LOCATION="DE"
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=1\nTRACEBLOC_CLIENT_PASSWORD=p\nTB_NAMESPACE=ns\n'
  provision_client
  run cat "$CREATE_ARGS_FILE"
  [[ "$output" == *"--name lab box 3"* ]]
  [[ "$output" == *"--location DE"* ]]
}

@test "provision_client: no name and no TTY to prompt is fatal (can't provision blind)" {
  unset TRACEBLOC_CLIENT_NAME
  _prompt_tty() { return 1; }   # non-interactive: no terminal to prompt on
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=1\nTRACEBLOC_CLIENT_PASSWORD=p\nTB_NAMESPACE=ns\n'
  run provision_client
  [ "$status" -ne 0 ]
  [[ "$output" == *"name for this machine is required"* ]]
  # and it must not have called client create (no argv recorded)
  [ ! -s "$CREATE_ARGS_FILE" ]
}
