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
  # hint() carries the actionable PATH-fix lines (#738), so echo it (like
  # success/warn) instead of silencing — the verification tests assert on it.
  hint()    { echo "HINT: $*"; }
  has()     { return 1; }   # default: tracebloc not present
  # CURL_SECURE is set readonly by common.sh (loaded via load_lib); don't
  # reassign it. curl is mocked in every test below, so its value is moot.
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
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  has()              { return 0; }       # tracebloc now resolvable
  _cli_on_fresh_path() { return 0; }     # a fresh terminal finds it (don't spawn real shells)
  tracebloc()        { echo "tracebloc 0.2.0"; }
  run install_tracebloc_cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUCCESS: tracebloc CLI installed"* ]]
}

# ── Self-verification (#738) ────────────────────────────────────────────────
# After install, prove the CLI is usable from a FRESH terminal and print a
# verified next command; if a new shell wouldn't find it, print the EXACT
# shell-correct PATH fix instead of a generic "open a new terminal". Always
# non-fatal (return 0) — the client is already connected by Step 5.

@test "install_tracebloc_cli: fresh-shell success reports a VERIFIED verdict (not 'open a new terminal')" {
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  _cli_on_fresh_path() { return 0; }     # a brand-new terminal resolves tracebloc
  tracebloc()        { echo "tracebloc 0.2.0"; }
  run install_tracebloc_cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified on your PATH"* ]]          # explicit proof, not hope
  [[ "$output" == *"0.2.0"* ]]                          # real proof via `tracebloc version`
  [[ "$output" != *"open a new terminal"* ]]            # the old, useless message is gone
  # The canonical dataset-push next step lives in summary.sh — don't duplicate it
  # here on the verified path (#738: "don't duplicate; keep consistent").
  [[ "$output" != *"tracebloc dataset push"* ]]
}

@test "install_tracebloc_cli: CLI-missing-from-fresh-shell prints an actionable, shell-correct PATH hint" {
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  _cli_on_fresh_path() { return 1; }     # installed, but a fresh terminal does NOT find it
  SHELL="/bin/zsh"; OS="Linux"          # zsh → ~/.zshrc (rc routing under test)
  run install_tracebloc_cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"export PATH=\"$HOME/.local/bin:\$PATH\""* ]]  # exact PATH line
  [[ "$output" == *"source $HOME/.zshrc"* ]]                       # the right rc for zsh
  [[ "$output" != *"open a new terminal"* ]]                       # never the generic line
}

@test "install_tracebloc_cli: fish gets a fish-correct fix (fish_add_path + config.fish)" {
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  _cli_on_fresh_path() { return 1; }
  SHELL="/usr/bin/fish"; OS="Linux"
  run install_tracebloc_cli
  [ "$status" -eq 0 ]
  [[ "$output" == *"fish_add_path \"$HOME/.local/bin\""* ]]        # not a POSIX `export`
  [[ "$output" == *"source $HOME/.config/fish/config.fish"* ]]
}

@test "install_tracebloc_cli: verification failure is still NON-FATAL (status 0)" {
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  # The whole verification step explodes — must NOT abort the install.
  _cli_on_fresh_path() { return 2; }
  _cli_rc_for_shell()  { return 7; }     # even if rc resolution itself errors
  run install_tracebloc_cli
  [ "$status" -eq 0 ]
}

@test "install_tracebloc_cli: NON-FATAL even under the orchestrator's set -e" {
  # The real installer sources this under `set -e`; a verification hiccup must
  # never abort an otherwise-good install. Reproduce that exact condition.
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  _cli_on_fresh_path() { return 1; }     # CLI not on a fresh PATH (failure branch)
  _cli_rc_for_shell()  { return 7; }     # and rc resolution itself errors
  set -e
  install_tracebloc_cli
  local rc=$?
  set +e
  [ "$rc" -eq 0 ]
}
