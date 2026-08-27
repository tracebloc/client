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
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"WARN: Couldn't download"* ]] || return 1
}

@test "install_tracebloc_cli: installer-script failure is non-fatal (returns 0, warns)" {
  curl() { : > "${@: -1}"; return 0; }   # 'download' OK (creates the -o target)
  sh()   { return 1; }                   # the CLI installer itself fails
  run install_tracebloc_cli
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"WARN: Couldn't install"* ]] || return 1
  # This step is by-design non-fatal, so a failure must NOT show spin_cmd's hard
  # red "✖ …" + log dump (which would look like a hard failure). We drive `spin`
  # directly to keep the failure path soft (Bugbot: fatal-looking CLI install UX).
  [[ "$output" != *"Last 10 lines"* ]] || return 1
  [[ "$output" != *"✖ Installing the tracebloc CLI"* ]] || return 1
}

@test "install_tracebloc_cli: success path reports installed" {
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  has()              { return 0; }       # tracebloc now resolvable
  _cli_on_fresh_path() { return 0; }     # a fresh terminal finds it (don't spawn real shells)
  tracebloc()        { echo "tracebloc 0.2.0"; }
  run install_tracebloc_cli
  [ "$status" -eq 0 ] || return 1
  # tracebloc was already present at the same version → "up to date" (a re-run
  # that bumped the version would say "updated (vOLD → vNEW)").
  [[ "$output" == *"SUCCESS: tracebloc CLI up to date"* ]] || return 1
}

# ── Self-verification (#738) ────────────────────────────────────────────────
# After install, prove the CLI is usable from a FRESH terminal and print a
# verified next command; if a new shell wouldn't find it, print the EXACT
# shell-correct PATH fix instead of a generic "open a new terminal". Always
# non-fatal (return 0) — the client is already connected by Step 5.

@test "install_tracebloc_cli: fresh-shell AND current-shell success reports a VERIFIED verdict" {
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  _cli_on_fresh_path() { return 0; }     # a brand-new terminal resolves tracebloc
  has()              { return 0; }       # …and so does THIS shell (binary already on PATH)
  _cli_at_system_dir() { return 0; }     # installed to a system dir → usable in THIS shell too
  tracebloc()        { echo "tracebloc 0.2.0"; }
  run install_tracebloc_cli
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"to use it"* ]] || return 1                      # usable-now verdict ("… — run tb to use it")
  [[ "$output" == *'`tb`'* ]] || return 1                           # prefers the short alias when it's present
  [[ "$output" == *"0.2.0"* ]] || return 1                          # real proof via `tracebloc version`
  [[ "$output" != *"open a new terminal"* ]] || return 1            # not the new-terminal (edge) message
  # The canonical dataset-push next step lives in summary.sh — don't duplicate it
  # here on the fully-verified path (#738: "don't duplicate; keep consistent").
  [[ "$output" != *"tracebloc dataset push"* ]] || return 1
}

@test "install_tracebloc_cli: names 'tracebloc' when the 'tb' alias wasn't created" {
  # The CLI installer skips the `tb` symlink when that name is already taken, so
  # the success copy must fall back to `tracebloc` rather than point the user at a
  # command that isn't there (Bugbot: wrong CLI command in success copy).
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  _cli_on_fresh_path() { return 0; }
  has()              { [[ "$1" == "tracebloc" ]]; }     # tracebloc present, tb absent
  _cli_at_system_dir() { return 0; }                    # system dir → usable-now verdict path
  tracebloc()        { echo "tracebloc 0.2.0"; }
  run install_tracebloc_cli
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *'run `tracebloc` to use it'* ]] || return 1      # named the real binary
  [[ "$output" != *'`tb`'* ]] || return 1                           # never a bare `tb` when it doesn't resolve
}

@test "install_tracebloc_cli: on PATH via ~/.local/bin (not a system dir) → new-terminal verdict, never 'run it now' (#371)" {
  # The contradictory-verdict bug: has tracebloc is TRUE (install.sh prepends
  # ~/.local/bin to THIS process) and a fresh shell resolves it, but the binary is
  # NOT in a system dir, so the user's returning login shell won't see it yet. The
  # step must NOT print the usable-now verdict (the summary CTA correctly says
  # "open a new terminal"); the two must agree.
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  _cli_on_fresh_path() { return 0; }             # a new terminal resolves it
  has()              { return 0; }               # THIS process resolves it too (PATH prepend)
  _cli_at_system_dir() { return 1; }             # …but it's in ~/.local/bin, not a system dir
  SHELL="/bin/zsh"; OS="Linux"
  tracebloc()        { echo "tracebloc 0.2.0"; }
  run install_tracebloc_cli
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"open a new terminal"* ]] || return 1     # matches the summary CTA
  [[ "$output" != *"to use it"* ]] || return 1               # NEVER the usable-now verdict on this path
}

@test "install_tracebloc_cli: fresh shell finds it but the CURRENT shell can't → 'new terminals' verdict + load-it-now hint (#304)" {
  # The bug: binary lands in ~/.local/bin, a fresh shell sources the rc and finds
  # it, but the caller's live shell predates that PATH edit. Old code printed
  # "verified on your PATH" here — a lie for the shell the user is typing in.
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  _cli_on_fresh_path() { return 0; }     # a NEW terminal resolves tracebloc (rc edit persisted)…
  has()              { return 1; }       # …but THIS shell does not yet
  SHELL="/bin/zsh"; OS="Linux"          # zsh → ~/.zshrc
  tracebloc()        { echo "tracebloc 0.2.0"; }
  run install_tracebloc_cli
  [ "$status" -eq 0 ] || return 1                                   # still non-fatal
  [[ "$output" == *"open a new terminal"* ]] || return 1            # honest: persisted, but not usable in THIS shell
  [[ "$output" == *"source $HOME/.zshrc"* ]] || return 1            # how to use it in THIS shell now
  [[ "$output" != *"to use it"* ]] || return 1                      # never claim the usable-now verdict for this shell
  # It's already in the rc (fresh shell found it) — don't tell the user to re-append.
  [[ "$output" != *"echo '"* ]] || return 1
}

@test "install_tracebloc_cli: CLI-missing-from-fresh-shell prints an actionable, shell-correct PATH hint" {
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  _cli_on_fresh_path() { return 1; }     # installed, but a fresh terminal does NOT find it
  SHELL="/bin/zsh"; OS="Linux"          # zsh → ~/.zshrc (rc routing under test)
  run install_tracebloc_cli
  [ "$status" -eq 0 ] || return 1
  # Append the exact PATH line to the rc, THEN source it — fixes this terminal
  # and every new one (the old code printed a bare `export` + a `source` of an
  # rc that didn't contain the line, so nothing persisted).
  [[ "$output" == *"echo 'export PATH=\"$HOME/.local/bin:\$PATH\"' >> $HOME/.zshrc"* ]] || return 1
  [[ "$output" == *"source $HOME/.zshrc"* ]] || return 1                       # the right rc for zsh
  [[ "$output" != *"open a new terminal"* ]] || return 1                       # never the generic line
}

@test "install_tracebloc_cli: fish gets a fish-correct fix (fish_add_path, no source needed)" {
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  _cli_on_fresh_path() { return 1; }
  SHELL="/usr/bin/fish"; OS="Linux"
  run install_tracebloc_cli
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"fish_add_path \"$HOME/.local/bin\""* ]] || return 1        # fish's idiom, not POSIX export
  [[ "$output" != *"export PATH"* ]] || return 1                               # never a POSIX export for fish
  # fish_add_path persists (universal var) AND applies to the running shell, so
  # fish users must NOT be told to `source` anything (the old guidance did).
  [[ "$output" != *"source "* ]] || return 1
}

@test "install_tracebloc_cli: verification failure is still NON-FATAL (status 0)" {
  curl()             { : > "${@: -1}"; return 0; }
  sh()               { return 0; }
  # The whole verification step explodes — must NOT abort the install.
  _cli_on_fresh_path() { return 2; }
  _cli_rc_for_shell()  { return 7; }     # even if rc resolution itself errors
  run install_tracebloc_cli
  [ "$status" -eq 0 ] || return 1
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
  [ "$rc" -eq 0 ] || return 1
}

# ── _cli_at_system_dir: the summary-CTA usable-now gate (Bugbot #371) ─────────
@test "_cli_at_system_dir: system dir usable-now, \$HOME bin conservative (#371)" {
  HOME=/home/tester
  _cli_at_system_dir /usr/local/bin/tracebloc                 # system → usable now
  _cli_at_system_dir /usr/bin/tracebloc
  ! _cli_at_system_dir /home/tester/.local/bin/tracebloc || return 1      # $HOME → conservative
  ! _cli_at_system_dir /home/tester/bin/tracebloc || return 1
  ! _cli_at_system_dir "" || return 1                                     # unresolved → conservative
}

# ── TB_CLI_USABLE_NOW default seeded from pre-install state (Bugbot #371) ─────
@test "install_tracebloc_cli: pre-existing SYSTEM tracebloc + install step fails → TB_CLI_USABLE_NOW stays 1 (#371)" {
  # A prior install left tracebloc on a system PATH dir (resolvable in the user's
  # shell). This run can't even start (no temp dir) → early return, _verify never
  # runs — the summary must still say "Run", not "open a new terminal".
  has() { return 0; }                    # tracebloc resolvable
  _cli_at_system_dir() { return 0; }     # …at a system dir
  _cli_version_short() { echo "0.2.0"; }
  mktemp() { return 1; }                 # force the early "(no temp dir)" return
  TB_CLI_USABLE_NOW=
  install_tracebloc_cli >/dev/null 2>&1 || true
  [ "$TB_CLI_USABLE_NOW" = "1" ] || return 1
}

@test "install_tracebloc_cli: pre-existing ~/.local/bin tracebloc + install step fails → TB_CLI_USABLE_NOW=0 (#371)" {
  # Prior install is in ~/.local/bin (this process resolves it via install.sh's
  # PATH prepend, the returning shell may not) → NOT usable-now; the summary must
  # not over-claim "Run".
  has() { return 0; }
  _cli_at_system_dir() { return 1; }     # ~/.local/bin, not a system dir
  _cli_version_short() { echo "0.2.0"; }
  mktemp() { return 1; }
  TB_CLI_USABLE_NOW=
  install_tracebloc_cli >/dev/null 2>&1 || true
  [ "$TB_CLI_USABLE_NOW" = "0" ] || return 1
}

# ── upgrade_cli_only (backend#2253) ─────────────────────────────────────────
# The CLI-only path for an explicit `tracebloc upgrade` on an otherwise-healthy
# machine (INSTALL_STATE_REASON=cli-behind-latest): update JUST the CLI and exit
# 0, with no cluster/Helm work. This is what makes `tracebloc upgrade` finally
# able to clear the update nag — the healthy fast-path used to update nothing.
@test "upgrade_cli_only: runs the CLI install step and exits 0" {
  install_tracebloc_cli() { echo "INSTALL_RAN"; }
  _cli_version_short() { echo "0.10.8"; }   # deterministic post-install probe
  run upgrade_cli_only
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"INSTALL_RAN"* ]] || return 1
}

# The ticket's acceptance criterion at the installer seam: after `upgrade` on a
# healthy machine whose CLI is behind latest, the reported version is latest.
# Before backend#2253 the healthy fast-path updated nothing, so this could not
# hold; upgrade_cli_only is the step that makes it true — model the released
# installer by advancing the version the post-install probe reports to latest.
@test "upgrade_cli_only: after upgrade the reported CLI version equals latest (backend#2253)" {
  VERFILE="$BATS_TEST_TMPDIR/ver"; echo "0.10.5" > "$VERFILE"    # behind latest
  TB_CLI_LATEST="0.10.8"
  install_tracebloc_cli() { echo "$TB_CLI_LATEST" > "$VERFILE"; }  # installer drops latest
  _cli_version_short() { cat "$VERFILE"; }                          # reflects the install
  run upgrade_cli_only
  [ "$status" -eq 0 ] || return 1
  [ "$(cat "$VERFILE")" = "$TB_CLI_LATEST" ] || return 1
}

# Bugbot: a FAILED update on THIS path must not exit 0 — that would leave the nag
# in place while `tracebloc upgrade` looked like it worked. When the CLI is
# verifiably still behind a known latest, exit non-zero and say so.
@test "upgrade_cli_only: a failed update (still behind latest) exits non-zero, not a false success" {
  TB_CLI_LATEST="0.10.8"
  install_tracebloc_cli() { :; }              # download/install hiccup: nothing changes
  _cli_version_short() { echo "0.10.5"; }     # still behind latest afterward
  run upgrade_cli_only
  [ "$status" -ne 0 ] || return 1
  [[ "$output" == *"Couldn't update the tracebloc CLI"* ]] || return 1
}

# Fail SAFE toward success: when we can't PROVE a failure (latest unknown), the
# explicit upgrade must not be reported as failed on a false negative.
@test "upgrade_cli_only: latest unknown -> exits 0 (can't prove a failure)" {
  unset TB_CLI_LATEST
  install_tracebloc_cli() { :; }
  _cli_version_short() { echo "0.10.5"; }
  run upgrade_cli_only
  [ "$status" -eq 0 ] || return 1
}

# Non-fatal by inheritance: install_tracebloc_cli never aborts, and a stale
# bootstrap without it must not crash this path either (the declare -F guard).
# Driven under `set -e` for the same reason as the wire_ca_trust guard test below:
# main() runs this under errexit, and bats `run` disables it — so strip the
# declare -F guard and this must go 127, not stay green (Bugbot, backend#2679).
@test "upgrade_cli_only: install step absent (stale bootstrap) still exits 0 under set -e" {
  unset TB_CLI_LATEST
  unset -f install_tracebloc_cli 2>/dev/null || true
  _cli_version_short() { echo ""; }           # nothing to compare -> can't prove failure
  local status
  ( set -e; upgrade_cli_only ) >/dev/null 2>&1; status=$?
  [ "$status" -eq 0 ] || return 1
}

# backend#2679: this path downloads + cosign-verifies the CLI, then EXITS — before
# main()'s wire_ca_trust runs. Behind a TLS-inspecting proxy the download/signature
# check fails x509 on the very machine where a normal install (CA wired first, #583)
# succeeds. So upgrade_cli_only must wire the corporate CA ITSELF, and BEFORE the
# download — order is the whole point, so assert it, not merely that both ran.
@test "upgrade_cli_only: wires CA trust BEFORE the CLI download (backend#2679)" {
  unset TB_CLI_LATEST                          # can't prove a failure -> exit 0
  ORDER="$BATS_TEST_TMPDIR/order"; : > "$ORDER"
  wire_ca_trust()         { echo "wire" >> "$ORDER"; }
  install_tracebloc_cli() { echo "download" >> "$ORDER"; }
  _cli_version_short()    { echo "0.10.8"; }
  run upgrade_cli_only
  [ "$status" -eq 0 ] || return 1
  # CA trust wired, and wired ahead of the download.
  [ "$(cat "$ORDER")" = "$(printf 'wire\ndownload')" ] || return 1
}

# The declare -F guard degrades gracefully: a stale bootstrap without cluster.sh
# (wire_ca_trust undefined) must not crash the upgrade — it downloads as before.
#
# main() runs upgrade_cli_only under `set -e`, so drive it under errexit HERE too.
# bats `run` turns errexit OFF, which would let an UNGUARDED call to a missing
# wire_ca_trust be a mere command-not-found the function walks past — the guard
# could be deleted and this test would still pass while production crashed before
# the download (Bugbot). An explicit `set -e` subshell exercises the real seam:
# strip the declare -F guard and this goes 127, not green.
@test "upgrade_cli_only: no cluster.sh (wire_ca_trust absent) still exits 0 under set -e (backend#2679)" {
  unset TB_CLI_LATEST
  unset -f wire_ca_trust 2>/dev/null || true
  install_tracebloc_cli() { echo "INSTALL_RAN"; }
  _cli_version_short()    { echo "0.10.8"; }
  local status output
  output="$( set -e; upgrade_cli_only )"; status=$?
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"INSTALL_RAN"* ]] || return 1
}
