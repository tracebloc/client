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
  # The #303 pre-flight probes local Helm via detect_installed_client (defined in
  # install-client-helm.sh, which this suite doesn't source). Default it to
  # "nothing installed here" so the pre-flight is skipped; the #303 tests override.
  detect_installed_client() { INSTALLED_CLIENT_ID=""; INSTALLED_CLIENT_NS=""; }
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
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"skipping browser sign-in"* ]] || return 1
  [[ "$output" != *"TRACEBLOC login"* ]] || return 1
}

@test "provision_client: dual-mode (values file) skips browser sign-in" {
  export TRACEBLOC_VALUES_FILE=/tmp/values.yaml
  tracebloc() { echo "TRACEBLOC $*"; }
  run provision_client
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"skipping browser sign-in"* ]] || return 1
}

@test "provision_client: a CLI too old to provision falls back to manual sign-in (not fatal)" {
  # Old CLI: `login` / `client create` are unknown commands, so the --help probe
  # exits non-zero. provision_client must fall back (return 0) and let
  # install_client_helm collect credentials, NOT hard-fail on `tracebloc login`.
  tracebloc() { case "$1" in login|client) return 1 ;; *) return 0 ;; esac; }
  run provision_client
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"falling back to manual sign-in"* ]] || return 1
  [[ "$output" != *"approve this machine in your browser"* ]] || return 1   # never entered the login flow
}

@test "provision_client: mint hands id+password+namespace to Helm" {
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=5\nTRACEBLOC_CLIENT_PASSWORD=pw9\nTB_NAMESPACE=my-ns\n'
  provision_client                       # called directly so exports persist
  [ "$TRACEBLOC_CLIENT_ID" = "5" ] || return 1
  [ "$TRACEBLOC_CLIENT_PASSWORD" = "pw9" ] || return 1
  [ "$TB_NAMESPACE" = "my-ns" ] || return 1
  # the credential file is transient — removed after sourcing
  [ ! -f "${HOST_DATA_DIR}/client-credential.env" ] || return 1
}

@test "provision_client: a stale TRACEBLOC_CLIENT_ADOPTED in the env does not misroute a mint" {
  export TRACEBLOC_CLIENT_ADOPTED=1      # leftover in the environment, NOT from the mint file
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=7\nTRACEBLOC_CLIENT_PASSWORD=pw\nTB_NAMESPACE=mns\n'  # mint: no ADOPTED line
  provision_client
  # mint path must win: the credential is handed to Helm, not dropped as if adopted
  [ "$TRACEBLOC_CLIENT_ID" = "7" ] || return 1
  [ "$TRACEBLOC_CLIENT_PASSWORD" = "pw" ] || return 1
  [ "$TB_NAMESPACE" = "mns" ] || return 1
}

@test "provision_client: adopt hands only the namespace (no password)" {
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=8\nTB_NAMESPACE=ex-ns\nTRACEBLOC_CLIENT_ADOPTED=1\n'
  provision_client
  [ "$TB_NAMESPACE" = "ex-ns" ] || return 1
  [ -z "${TRACEBLOC_CLIENT_PASSWORD:-}" ] || return 1   # no fresh credential on adopt
  [ "$TRACEBLOC_CLIENT_ID" = "8" ] || return 1          # adopted id kept → Step 5 heals the release's clientId to it
  [ "$TRACEBLOC_CLIENT_ADOPTED" = "1" ] || return 1     # marker kept → Step 5 takes the reconcile branch
}

@test "provision_client: missing CLI after install is fatal" {
  has() { return 1; }                    # CLI not resolvable after install
  tracebloc() { return 0; }
  run provision_client
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"tracebloc CLI is required"* ]] || return 1
}

@test "provision_client: failed sign-in is fatal" {
  # Provisioning-capable CLI (the --help capability probe passes), but the actual
  # sign-in fails — that must still be fatal, not a silent fall-through.
  tracebloc() { [[ "$*" == *--help ]] && return 0; [ "$1" = "login" ] && return 1; return 0; }
  run provision_client
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"Sign-in didn't complete"* ]] || return 1
}

# ── cli#517: a missed code costs one prompt, not a whole installer run ────────
#
# The retry loop is driven through _run_device_login (the seam that owns the
# /dev/tty redirection): stubbing it lets these tests decide success or failure
# per attempt without needing a real controlling terminal, which CI has not got.
# The seam's OWN behaviour — which env it hands the CLI — is pinned separately
# below, on the non-tty branch, so it behaves the same in CI and on a laptop.

# _stub_sign_in_failing: a _run_device_login stub that records every attempt in
# ATTEMPTS_FILE and fails the first $1 of them (0 = succeed immediately). The
# count lives in a GLOBAL, not a local of this function: the stub runs long after
# this returns, so a local would be out of scope by then and read as empty.
_stub_sign_in_failing() {
  SIGN_IN_FAIL_FIRST="$1"
  ATTEMPTS_FILE="$(mktemp)"
  _run_device_login() {
    printf 'x\n' >>"$ATTEMPTS_FILE"
    [[ "$(grep -c . "$ATTEMPTS_FILE")" -le "$SIGN_IN_FAIL_FIRST" ]] && return 1
    return 0
  }
}

_attempts() { grep -c . "$ATTEMPTS_FILE" 2>/dev/null || echo 0; }

@test "_device_sign_in: a lapsed code is retried in place, not fatal" {
  # THE cli#517 fix: before it, one missed ten-minute code threw away every step
  # the installer had already completed. It must cost a single Enter instead.
  _prompt_tty() { return 0; }              # a live terminal is available
  TB_TTY="$(mktemp)"; printf '\n' >"$TB_TTY"   # the human presses Enter
  _stub_sign_in_failing 1
  run _device_sign_in
  [ "$status" -eq 0 ] || return 1
  [ "$(_attempts)" -eq 2 ] || return 1
  # The "Press Enter" line goes to /dev/tty (like every prompt here), so it is
  # not in $output; the warn/hint that explain the pause do go through the log.
  [[ "$output" == *"the code lapsed or wasn't approved"* ]] || return 1
  [[ "$output" == *"Nothing is lost"* ]] || return 1
}

@test "_device_sign_in: a second failure is fatal, and names the installer" {
  # The retry is ONE retry. A second failure is evidence of something other than
  # a missed code, and the advice must be the installer — not `tracebloc login`,
  # which would leave the client mint and the Helm install undone.
  _prompt_tty() { return 0; }
  TB_TTY="$(mktemp)"; printf '\n\n\n' >"$TB_TTY"
  _stub_sign_in_failing 99
  run _device_sign_in
  [ "$status" -ne 0 ] || return 1
  [ "$(_attempts)" -eq 2 ] || return 1
  [[ "$output" == *"re-run the installer"* ]] || return 1
  [[ "$output" != *"tracebloc login"* ]] || return 1
  # Offered ONCE. The attempt count alone can't see a guard that lets the loop
  # prompt after its final try — the user would be asked to press Enter for a
  # code that is never fetched — so count the offer, not just the attempts.
  [ "$(printf '%s\n' "$output" | grep -c 'Nothing is lost')" -eq 1 ] || return 1
}

@test "_device_sign_in: with no terminal there is no retry to offer" {
  # Nobody to hand a fresh code to — re-prompting would just hang or spin.
  # TB_TTY is deliberately READABLE here: with a dead one, dropping the
  # _prompt_tty gate would stop on the failed read instead and the assertion
  # below could not tell the gate from the EOF (the mutation ran green that way).
  _prompt_tty() { return 1; }
  TB_TTY="$(mktemp)"; printf '\n\n\n' >"$TB_TTY"
  _stub_sign_in_failing 99
  run _device_sign_in
  [ "$status" -ne 0 ] || return 1
  [ "$(_attempts)" -eq 1 ] || return 1
  [[ "$output" != *"Nothing is lost"* ]] || return 1
}

@test "_device_sign_in: an EOF on the retry prompt stops, it does not spin" {
  # A failed read (rc != 0 — EOF, a non-PTY ssh session, a closed pipe) can't be
  # fixed by asking again; the loop must fall straight through to the error.
  _prompt_tty() { return 0; }
  TB_TTY=/dev/null                          # read returns EOF immediately
  _stub_sign_in_failing 99
  run _device_sign_in
  [ "$status" -ne 0 ] || return 1
  [ "$(_attempts)" -eq 1 ] || return 1
  [[ "$output" == *"re-run the installer"* ]] || return 1
}

@test "_run_device_login: the CLI is told the installer is driving it" {
  # TRACEBLOC_INSTALLER is what stops the CLI printing "run \`tracebloc login\`"
  # — advice that is right for a hand-typed login and wrong under the installer.
  # Pinned on the no-tty branch so it reads the same in CI and on a laptop.
  _login_tty_ok() { return 1; }
  local seen="$BATS_TEST_TMPDIR/env"
  tracebloc() { printf '%s|%s\n' "${TRACEBLOC_INSTALLER:-unset}" "$*" >"$seen"; return 0; }
  _run_device_login
  [[ "$(cat "$seen")" == "1|login" ]] || return 1
}

@test "_run_device_login: TRACEBLOC_INSTALLER does not leak past the sign-in" {
  # Set as a command prefix, not exported for the rest of the install: `client
  # create` and every later CLI call must see the environment they always did.
  _login_tty_ok() { return 1; }
  tracebloc() { return 0; }
  _run_device_login
  [ -z "${TRACEBLOC_INSTALLER:-}" ] || return 1
}

@test "provision_client: client create writing no credential file is fatal" {
  tracebloc() { return 0; }              # login OK, create "succeeds" but writes nothing
  run provision_client
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"did not write the credential file"* ]] || return 1
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
  [ "$status" -ne 0 ] || return 1
  [ ! -f "${HOST_DATA_DIR}/client-credential.env" ] || return 1
}

@test "provision_client: mint passes --name (+ --location) through to client create" {
  # `client create`'s output is redirected to the log, so it can't prompt and
  # hard-requires --name; provision.sh must pass it. Multi-word name checks the
  # array-based invocation keeps values with spaces intact.
  export TRACEBLOC_CLIENT_NAME="lab box 3" TRACEBLOC_CLIENT_LOCATION="DE"
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=1\nTRACEBLOC_CLIENT_PASSWORD=p\nTB_NAMESPACE=ns\n'
  provision_client
  run cat "$CREATE_ARGS_FILE"
  [[ "$output" == *"--name lab box 3"* ]] || return 1
  [[ "$output" == *"--location DE"* ]] || return 1
}

@test "provision_client: refuses BEFORE minting when a foreign client already runs here (#303)" {
  # A client is installed locally under a namespace the signed-in account does NOT
  # own — the orphan scenario. provision_client must refuse before `client create`.
  detect_installed_client() { INSTALLED_CLIENT_ID="uuid-x"; INSTALLED_CLIENT_NS="tracebloc-amazon"; }
  tracebloc() {
    [[ "$*" == *--help ]] && return 0                    # capability probe
    [ "$1" = "login" ] && return 0
    if [ "$1" = "client" ] && [ "$2" = "list" ]; then
      echo "box   state=online   namespace=some-other-ns   location=DE"   # NOT tracebloc-amazon
      return 0
    fi
    # any `client create` records its argv so we can assert it never ran
    local f="" prev=""; for a in "$@"; do [ "$prev" = "--credential-file" ] && f="$a"; prev="$a"; done
    [ -n "$f" ] && printf '%s\n' "$*" >>"${CREATE_ARGS_FILE}"
    return 0
  }
  run provision_client
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"isn't in the account you just signed in as"* ]] || return 1
  [[ "$output" == *"Refusing to provision a second client"* ]] || return 1
  [ ! -s "$CREATE_ARGS_FILE" ] || return 1          # create was never called — no orphan minted
}

@test "provision_client: unknown helm state (list failed) refuses BEFORE minting — no orphan (#303)" {
  # detect_installed_client couldn't enumerate (helm/API failure): both globals
  # empty but INSTALLED_CLIENT_UNKNOWN=1. Minting now could strand a second client,
  # so provision_client must refuse before `client create` ever runs.
  detect_installed_client() { INSTALLED_CLIENT_ID=""; INSTALLED_CLIENT_NS=""; INSTALLED_CLIENT_UNKNOWN=1; }
  tracebloc() {
    [[ "$*" == *--help ]] && return 0
    [ "$1" = "login" ] && return 0
    local f="" prev=""; for a in "$@"; do [ "$prev" = "--credential-file" ] && f="$a"; prev="$a"; done
    [ -n "$f" ] && printf '%s\n' "$*" >>"${CREATE_ARGS_FILE}"
    return 0
  }
  run provision_client
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"Couldn't determine whether a tracebloc client is already installed"* ]] || return 1
  [ ! -s "$CREATE_ARGS_FILE" ] || return 1          # create never ran — no orphan minted
}

@test "provision_client: same-account re-run with a local client still provisions (adopt path intact) (#303)" {
  # The account owns the local client's namespace → create proceeds and adopts.
  detect_installed_client() { INSTALLED_CLIENT_ID="uuid-x"; INSTALLED_CLIENT_NS="my-ns"; }
  tracebloc() {
    [[ "$*" == *--help ]] && return 0
    [ "$1" = "login" ] && return 0
    if [ "$1" = "client" ] && [ "$2" = "list" ]; then
      echo "box   state=online   namespace=my-ns   location=DE"      # owned
      return 0
    fi
    local f="" prev=""; for a in "$@"; do [ "$prev" = "--credential-file" ] && f="$a"; prev="$a"; done
    [ -n "$f" ] && printf '%b' 'TRACEBLOC_CLIENT_ID=8\nTB_NAMESPACE=my-ns\nTRACEBLOC_CLIENT_ADOPTED=1\n' > "$f"
    return 0
  }
  provision_client
  [ "$TB_NAMESPACE" = "my-ns" ] || return 1
  [ "$TRACEBLOC_CLIENT_ADOPTED" = "1" ] || return 1     # adopt path reached, not refused
}

@test "provision_client: an unreadable client list falls through to create, not a refusal (#303)" {
  # Ownership inconclusive (list read fails) must NOT block — degrade to create's
  # own idempotent adopt/conflict handling, no worse than before the pre-flight.
  detect_installed_client() { INSTALLED_CLIENT_ID="uuid-x"; INSTALLED_CLIENT_NS="tracebloc-amazon"; }
  tracebloc() {
    [[ "$*" == *--help ]] && return 0
    [ "$1" = "login" ] && return 0
    if [ "$1" = "client" ] && [ "$2" = "list" ]; then return 5; fi     # list read fails
    local f="" prev=""; for a in "$@"; do [ "$prev" = "--credential-file" ] && f="$a"; prev="$a"; done
    [ -n "$f" ] && printf '%b' 'TRACEBLOC_CLIENT_ID=9\nTRACEBLOC_CLIENT_PASSWORD=pw\nTB_NAMESPACE=fresh-ns\n' > "$f"
    return 0
  }
  provision_client
  [ "$TRACEBLOC_CLIENT_ID" = "9" ] || return 1          # create ran despite the inconclusive list
  [ "$TB_NAMESPACE" = "fresh-ns" ] || return 1
}

@test "provision_client: legacy 'tracebloc' namespace absent from the account is NOT refused — defers to create + guard (#306 Bugbot)" {
  # A same-account client installed under the legacy fixed `tracebloc` namespace is
  # listed on the dashboard by its minted slug, so `client list` won't show
  # `tracebloc`. The old namespace-only check wrongly refused this (blocking a valid
  # re-run install_client_helm reconciles by clientId). Must defer to create, not refuse.
  detect_installed_client() { INSTALLED_CLIENT_ID="uuid-x"; INSTALLED_CLIENT_NS="tracebloc"; }
  tracebloc() {
    [[ "$*" == *--help ]] && return 0
    [ "$1" = "login" ] && return 0
    if [ "$1" = "client" ] && [ "$2" = "list" ]; then
      echo "box   state=online   namespace=slug-ns   location=DE"   # listed by slug, not 'tracebloc'
      return 0
    fi
    local f="" prev=""; for a in "$@"; do [ "$prev" = "--credential-file" ] && f="$a"; prev="$a"; done
    [ -n "$f" ] && printf '%b' 'TRACEBLOC_CLIENT_ID=9\nTRACEBLOC_CLIENT_PASSWORD=pw\nTB_NAMESPACE=slug-ns\n' > "$f"
    return 0
  }
  provision_client                          # must NOT refuse (a direct call fails the test if error exits)
  [ "$TRACEBLOC_CLIENT_ID" = "9" ] || return 1           # deferred to create, which ran
}

@test "provision_client: no name and no TTY to prompt is fatal (can't provision blind)" {
  unset TRACEBLOC_CLIENT_NAME
  _prompt_tty() { return 1; }   # non-interactive: no terminal to prompt on
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=1\nTRACEBLOC_CLIENT_PASSWORD=p\nTB_NAMESPACE=ns\n'
  run provision_client
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"name for this client is required"* ]] || return 1
  # and it must not have called client create (no argv recorded)
  [ ! -s "$CREATE_ARGS_FILE" ] || return 1
}

@test "provision_client: type-ahead blank lines are re-prompted, not accepted as the name (2026-07-09)" {
  # Regression: a stray newline queued in the tty during the browser-approval
  # wait was read as an empty name and aborted the install. The name read must
  # RETRY past empty lines and still capture the real name. TB_TTY=/dev/stdin
  # lets us feed the queued blanks + the name on stdin.
  unset TRACEBLOC_CLIENT_NAME
  export TRACEBLOC_CLIENT_LOCATION="DE"   # pin the zone (skip the timezone auto-derive); isolate the name read
  _prompt_tty() { return 0; }             # a terminal IS available
  TB_TTY=/dev/stdin
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=1\nTRACEBLOC_CLIENT_PASSWORD=p\nTB_NAMESPACE=ns\n'
  run provision_client <<< $'\n\nMyBox\n'  # two type-ahead blanks, then the real name
  [ "$status" -eq 0 ] || return 1
  run cat "$CREATE_ARGS_FILE"
  [[ "$output" == *"--name MyBox"* ]] || return 1      # the real name survived the stray blanks
}

@test "provision_client: a dead input tty (EOF, no keystrokes) fails fast with the actionable error" {
  # _prompt_tty passes (a controlling terminal exists) but the read side yields
  # no interactive input (EOF) — e.g. a non-PTY ssh / IDE terminal. Must NOT loop
  # or hang, and must surface the set-TRACEBLOC_CLIENT_NAME guidance.
  unset TRACEBLOC_CLIENT_NAME
  export TRACEBLOC_CLIENT_LOCATION="DE"    # pin the zone; the read under test is the name
  _prompt_tty() { return 0; }
  TB_TTY=/dev/stdin
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=1\nTRACEBLOC_CLIENT_PASSWORD=p\nTB_NAMESPACE=ns\n'
  run provision_client </dev/null          # read returns EOF immediately
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"name for this client is required"* ]] || return 1
  [ ! -s "$CREATE_ARGS_FILE" ] || return 1
}

@test "provision_client: interactive install auto-derives location from the timezone — never prompts (#354)" {
  # Only the name is prompted. With no TRACEBLOC_CLIENT_LOCATION the zone is derived
  # silently from the system timezone and passed as --location; the user is never
  # asked. Feed ONLY a name on stdin — a lingering location prompt would block on the
  # absent second line and the test would hang/fail.
  unset TRACEBLOC_CLIENT_NAME TRACEBLOC_CLIENT_LOCATION
  _prompt_tty() { return 0; }
  TB_TTY=/dev/stdin
  _detect_location_zone() { printf 'FR Europe/Paris\n'; }   # detection succeeds
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=1\nTRACEBLOC_CLIENT_PASSWORD=p\nTB_NAMESPACE=ns\n'
  run provision_client <<< $'MyBox\n'
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"carbon reporting"* ]] || return 1   # the location prompt is gone
  run cat "$CREATE_ARGS_FILE"
  [[ "$output" == *"--name MyBox"* ]] || return 1
  [[ "$output" == *"--location FR"* ]] || return 1       # zone came from the timezone, silently
}

@test "provision_client: interactive install with no detectable zone provisions with NO location — never prompts (#354)" {
  # Timezone detection yields nothing. The installer must NOT ask for a zone (the old
  # required-entry loop is gone) — it provisions with no --location, which the CLI
  # now accepts (cli#137), and the backend records the client with no location.
  unset TRACEBLOC_CLIENT_NAME TRACEBLOC_CLIENT_LOCATION
  _prompt_tty() { return 0; }
  TB_TTY=/dev/stdin
  _detect_location_zone() { return 0; }      # nothing detected
  _stub_tracebloc 'TRACEBLOC_CLIENT_ID=1\nTRACEBLOC_CLIENT_PASSWORD=p\nTB_NAMESPACE=ns\n'
  run provision_client <<< $'MyBox\n'
  [ "$status" -eq 0 ] || return 1                        # no location is not fatal anymore
  [[ "$output" != *"carbon reporting"* ]] || return 1    # never prompted
  [[ "$output" != *"location zone is required"* ]] || return 1
  run cat "$CREATE_ARGS_FILE"
  [[ "$output" == *"--name MyBox"* ]] || return 1
  [[ "$output" != *"--location"* ]] || return 1          # provisioned with no location
}

# ── cli#141: the #303 pre-flight's grep contract with `tracebloc client list` ──
# _account_owns_namespace shells out to `tracebloc client list --plain` and greps
# the output for `namespace=<ns>([[:space:]]|$)` to decide ownership. `client list`
# is a HIDDEN cobra command in the cli repo (RFC-0001 §7.10), kept callable purely
# for this pre-flight. The PRODUCER half of the contract — that the hidden command
# still runs and still prints that exact `namespace=<ns>` field under --plain — is
# pinned in the cli repo (internal/cli/client_list_contract_test.go, cli#141). The
# tests below pin the CONSUMER half here: that the grep classifies the CLI's EXACT
# --plain line format correctly (owned / absent / unreadable / prefix-boundary) and
# that the pre-flight really passes --plain. The fixture mirrors, field-for-field,
# what cli's runClientList prints (cli internal/cli/client.go):
#     "<name>   state=<state>   namespace=<ns>   location=<loc>"
# If that format ever changes, the cli-side guard fails first; keep this fixture +
# provision.sh's grep in lockstep with it.

# _stub_client_list_plain LINES — stub `tracebloc` so `client list` prints $LINES
# (one client per line, in the CLI's real --plain value format; \n-separated) and
# records its argv to $LIST_ARGV_FILE so a test can assert --plain was passed.
_stub_client_list_plain() {
  CLIENT_LIST_OUTPUT="$1"
  tracebloc() {
    if [ "$1" = "client" ] && [ "$2" = "list" ]; then
      printf '%s\n' "$*" >>"${LIST_ARGV_FILE:-/dev/null}"
      printf '%b' "$CLIENT_LIST_OUTPUT"
      return 0
    fi
    return 0
  }
}

@test "cli#141: _account_owns_namespace matches the CLI's exact --plain namespace= line (owned / absent / prefix-boundary) + passes --plain" {
  LIST_ARGV_FILE="$(mktemp)"
  # Two clients in the account, printed exactly as `client list --plain` renders
  # them; the second's namespace has the first's as a strict prefix on purpose.
  _stub_client_list_plain 'acme-box   state=online   namespace=acme-prod-01   location=DE\nother-box   state=offline   namespace=acme-prod-01-staging   location=US\n'

  # Owned → 0 (provision proceeds to create, which adopts).
  run _account_owns_namespace "acme-prod-01"
  [ "$status" -eq 0 ] || return 1

  # List read OK but the namespace is absent → 1 (the FOREIGN-client refuse signal).
  run _account_owns_namespace "acme-prod-99"
  [ "$status" -eq 1 ] || return 1

  # Strict prefix must NOT match: after "acme-prod-0" comes "1", not whitespace/EOL,
  # so the account does not "own" acme-prod-0 just because it owns acme-prod-01.
  # This pins the ([[:space:]]|$) anchor the installer's grep depends on — without
  # it a prefix collision would silently mis-classify ownership.
  run _account_owns_namespace "acme-prod-0"
  [ "$status" -eq 1 ] || return 1

  # The pre-flight MUST invoke the hidden list with --plain (the #141 output
  # contract). grep gives a real exit code, so this holds on bash 3.2 too.
  run grep -qF -- '--plain' "$LIST_ARGV_FILE"
  [ "$status" -eq 0 ] || return 1
}

@test "cli#141: _account_owns_namespace reports 'couldn't read the list' as rc 2, distinct from 'absent' rc 1" {
  # A failed list read must be rc 2 (not 1) so provision_client falls through to
  # create's own idempotent adopt/conflict handling instead of REFUSING on a
  # transient blip — the distinction the #303 pre-flight branches on.
  tracebloc() { if [ "$1" = "client" ] && [ "$2" = "list" ]; then return 7; fi; return 0; }
  run _account_owns_namespace "any-ns"
  [ "$status" -eq 2 ] || return 1
}

# ── _report_create_failure: rejected-zone hint names the real source (Bugbot #356) ──
# The invalid-location branch must attribute the rejected zone to where it actually
# came from. Blaming the timezone auto-derivation when the operator pinned
# TRACEBLOC_CLIENT_LOCATION reads as "the env override was ignored".

@test "bugbot#356: rejected zone from TRACEBLOC_CLIENT_LOCATION points at the env var, not the timezone" {
  local out; out="$(mktemp)"
  printf '%s\n' "Error: location: 'ZZ' is not a valid choice." > "$out"
  run _report_create_failure "$out" "ZZ" "env"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"came from TRACEBLOC_CLIENT_LOCATION"* ]] || return 1
  [[ "$output" != *"auto-derived from this machine's timezone"* ]] || return 1
}

@test "bugbot#356: rejected auto-derived zone still blames the timezone and offers the override" {
  local out; out="$(mktemp)"
  printf '%s\n' "Error: location: 'XX' is not a valid choice." > "$out"
  run _report_create_failure "$out" "XX" "auto"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"auto-derived from this machine's timezone"* ]] || return 1
  [[ "$output" == *"TRACEBLOC_CLIENT_LOCATION"* ]] || return 1
}

@test "bugbot#356: source defaults to auto when the caller omits it" {
  local out; out="$(mktemp)"
  printf '%s\n' "Error: location: 'XX' is not a valid choice." > "$out"
  run _report_create_failure "$out" "XX"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"auto-derived from this machine's timezone"* ]] || return 1
}
