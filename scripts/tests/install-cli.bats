#!/usr/bin/env bats
# Tests for scripts/lib/install-cli.sh — the tracebloc CLI install step (#201).
#
# The load-bearing property is that it is NON-FATAL: the client is already
# connected by the time install_tracebloc_cli runs, so a download or install
# failure must leave it returning 0 (the orchestrator runs under `set -e`; a
# non-zero return there would abort an otherwise-successful install).
load test_helper

setup() {
  load_lib install-cli.sh
  # Stub the UI helpers (defined in common.sh in the real run) so we can assert
  # on what the function reports.
  step()    { :; }
  info()    { :; }
  success() { echo "SUCCESS: $*"; }
  warn()    { echo "WARN: $*"; }
  hint()    { :; }
  has()     { return 1; }   # default: tracebloc not present
  CURL_SECURE="--tlsv1.2"
  LOG_FILE="$(mktemp)"
}

@test "install_tracebloc_cli: download failure is non-fatal (returns 0, warns)" {
  curl() { return 22; }                  # curl HTTP failure (exit 22)
  run install_tracebloc_cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN: Couldn't download"* ]]
}

@test "install_tracebloc_cli: installer-script failure is non-fatal (returns 0, warns)" {
  curl() { : > "${@: -1}"; return 0; }   # 'download' OK (creates the -o target)
  sh()   { return 1; }                   # the CLI installer itself fails
  run install_tracebloc_cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN: Couldn't install"* ]]
}

@test "install_tracebloc_cli: success path reports installed" {
  curl()      { : > "${@: -1}"; return 0; }
  sh()        { return 0; }
  has()       { return 0; }              # tracebloc now resolvable
  tracebloc() { echo "tracebloc 0.2.0"; }
  run install_tracebloc_cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUCCESS: tracebloc CLI installed"* ]]
}
