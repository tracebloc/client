#!/usr/bin/env bats
# Tests for scripts/lib/summary.sh — readiness gate + state-branched summary (#716)
load test_helper

setup() {
  load_lib summary.sh
  TB_NAMESPACE=testns
  GPU_VENDOR=none
}

# ── _diagnose_not_ready ────────────────────────────────────────────────────
@test "_diagnose_not_ready: jobs-manager auth error -> bad_creds" {
  kubectl() { case "$*" in *logs*) echo "Exception: Authentication failed: Unable to log in with provided credentials";; *) echo "x 0/2 CrashLoopBackOff";; esac; }
  run _diagnose_not_ready testns
  [ "$output" = "bad_creds" ]
}

@test "_diagnose_not_ready: ImagePullBackOff -> image_pull" {
  kubectl() { case "$*" in *logs*) echo "booting";; *) echo "x 0/1 ImagePullBackOff";; esac; }
  run _diagnose_not_ready testns
  [ "$output" = "image_pull" ]
}

@test "_diagnose_not_ready: CrashLoopBackOff (no auth err) -> crash" {
  kubectl() { case "$*" in *logs*) echo "booting";; *) echo "x 0/1 CrashLoopBackOff";; esac; }
  run _diagnose_not_ready testns
  [ "$output" = "crash" ]
}

@test "_diagnose_not_ready: still creating -> starting" {
  kubectl() { case "$*" in *logs*) echo "booting";; *) echo "x 0/1 ContainerCreating";; esac; }
  run _diagnose_not_ready testns
  [ "$output" = "starting" ]
}

# ── wait_for_client_ready ──────────────────────────────────────────────────
@test "wait_for_client_ready: all rollouts succeed -> connected" {
  kubectl() { case "$*" in *"rollout status"*) return 0;; *) echo "";; esac; }
  READY_TIMEOUT=20
  CLIENT_STATE=""
  wait_for_client_ready
  [ "$CLIENT_STATE" = "connected" ]
}

@test "wait_for_client_ready: a rollout fails -> diagnosed (bad_creds)" {
  kubectl() {
    case "$*" in
      *"rollout status"*) return 1 ;;
      *logs*) echo "Authentication failed: Unable to log in" ;;
      *) echo "x 0/2 CrashLoopBackOff" ;;
    esac
  }
  READY_TIMEOUT=20
  CLIENT_STATE=""
  wait_for_client_ready
  [ "$CLIENT_STATE" = "bad_creds" ]
}

# ── print_summary: the trust claim must appear ONLY when connected ─────────
@test "print_summary connected: Connected + trust claim + rich summary blocks" {
  CLIENT_STATE=connected
  TB_CLI_USABLE_NOW=1   # pin CLI-usable so the CTA is the deterministic "Run …" variant (B2)
  run print_summary
  [[ "$output" == *"Connected to tracebloc"* ]]
  [[ "$output" == *"never leaves this machine"* ]]   # trust claim (was "data never leaves")
  # rich summary from the run-through
  [[ "$output" == *"Environment"* ]]
  [[ "$output" == *"Mode"* ]]
  [[ "$output" == *"Your secure environment is live"* ]]   # live-status heading (lime ● replaced the 🟢 emoji)
  [[ "$output" == *"What's next"* ]]
  [[ "$output" == *"tracebloc data ingest"* ]]
  [[ "$output" == *"my-use-cases"* ]]
  [[ "$output" == *"Run"* && "$output" == *"to get started"* ]]
}

@test "print_summary connected: shows the client version" {
  CLIENT_STATE=connected
  helm() { echo "tracebloc tracebloc 1 now deployed client-1.4.4 1.4.4"; }
  run print_summary
  [[ "$output" == *"Version"* ]]
  [[ "$output" == *"1.4.4"* ]]
}

@test "print_summary starting: 'still starting', no trust claim" {
  CLIENT_STATE=starting
  run print_summary
  [[ "$output" == *"still starting"* ]]
  [[ "$output" != *"never leaves this machine"* ]]
}

@test "print_summary bad_creds: 'rejected', no trust claim" {
  CLIENT_STATE=bad_creds
  run print_summary
  [[ "$output" == *"rejected"* ]]
  [[ "$output" != *"never leaves this machine"* ]]
}

@test "print_summary image_pull: image message, no trust claim" {
  CLIENT_STATE=image_pull
  run print_summary
  [[ "$output" == *"image couldn't be pulled"* ]]
  [[ "$output" != *"never leaves this machine"* ]]
}

@test "print_summary crash: crash-loop message" {
  CLIENT_STATE=crash
  run print_summary
  [[ "$output" == *"crash loop"* ]]
  [[ "$output" != *"never leaves this machine"* ]]
}

# ── _reboot_note (reboot persistence) ───────────────────────────────────────
@test "_reboot_note: Linux -> survives-reboot line" {
  OS=Linux
  run _reboot_note
  [[ "$output" == *"restarts automatically"* ]]
  [[ "$output" != *"Docker Desktop"* ]]
}

@test "_reboot_note: macOS -> Docker Desktop start-on-login instruction" {
  OS=Darwin
  run _reboot_note
  [[ "$output" == *"Docker Desktop"* ]]
  [[ "$output" == *"open Docker Desktop"* ]]
}

@test "print_summary connected: includes the reboot note" {
  CLIENT_STATE=connected; OS=Linux
  run print_summary
  [[ "$output" == *"restarts automatically"* ]]
}

# ── B2: PATH-aware CTA (grep-based so a false check fails loudly on bash 3.2) ──
@test "print_summary connected: CTA says 'Run' when the CLI is usable now (B2)" {
  CLIENT_STATE=connected; OS=Linux
  helm() { echo "tracebloc tracebloc 1 now deployed client-1.4.4 1.4.4"; }
  TB_CLI_USABLE_NOW=1
  run print_summary
  printf '%s\n' "$output" | grep -qE "Run[[:space:]]+tracebloc"   # the "Run …" branch specifically
  ! printf '%s\n' "$output" | grep -qF "Open a new terminal"
}

@test "print_summary connected: CTA says 'open a new terminal' when persisted but this shell can't see it yet (case A, B2)" {
  CLIENT_STATE=connected; OS=Linux
  helm() { echo "tracebloc tracebloc 1 now deployed client-1.4.4 1.4.4"; }
  TB_CLI_USABLE_NOW=0; TB_CLI_ON_FRESH_PATH=1   # a NEW terminal resolves it, this one doesn't
  has() { [ "$1" = tracebloc ] && return 1; command -v "$1" >/dev/null 2>&1; }
  run print_summary
  printf '%s\n' "$output" | grep -qF "Open a new terminal"
}

@test "print_summary connected: CTA points at the PATH fix (NOT 'open a new terminal') when a fresh shell won't find it either (case B, #371)" {
  CLIENT_STATE=connected; OS=Linux
  helm() { echo "tracebloc tracebloc 1 now deployed client-1.4.4 1.4.4"; }
  TB_CLI_USABLE_NOW=0; TB_CLI_ON_FRESH_PATH=0   # not on PATH anywhere yet
  has() { [ "$1" = tracebloc ] && return 1; command -v "$1" >/dev/null 2>&1; }
  run print_summary
  printf '%s\n' "$output" | grep -qF "Add tracebloc to your PATH"   # matches install-cli.sh's PATH-fix step
  ! printf '%s\n' "$output" | grep -qF "Open a new terminal"        # never the useless new-terminal advice
}
