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
  [ "$output" = "bad_creds" ] || return 1
}

@test "_diagnose_not_ready: ImagePullBackOff -> image_pull" {
  kubectl() { case "$*" in *logs*) echo "booting";; *) echo "x 0/1 ImagePullBackOff";; esac; }
  run _diagnose_not_ready testns
  [ "$output" = "image_pull" ] || return 1
}

@test "_diagnose_not_ready: CrashLoopBackOff (no auth err) -> crash" {
  kubectl() { case "$*" in *logs*) echo "booting";; *) echo "x 0/1 CrashLoopBackOff";; esac; }
  run _diagnose_not_ready testns
  [ "$output" = "crash" ] || return 1
}

@test "_diagnose_not_ready: large (>64KB) pod list under pipefail still classifies (backend#1778)" {
  # The matcher used to be `printf '%s' "$pods" | grep -qiE ...`. Past the ~64KB
  # pipe buffer, grep -q closes the pipe, printf takes SIGPIPE and pipefail makes
  # the pipeline 141 — which the `if` reads as "no match", silently downgrading a
  # real crash diagnosis to "starting" and handing the user the wrong remedy.
  set -o pipefail
  # The match must come FIRST: grep -q exits on its first hit, so the SIGPIPE
  # only happens while the producer still has output left to write. A match at
  # the END forces grep to read everything, and the test passes vacuously.
  local big; big=$'testns-jobs-manager-abc 0/1 CrashLoopBackOff 7 3m\n'
  big+="$(printf 'testns-noise-%s 1/1 Running 0 5m\n' $(seq 1 8000))"   # >64KB after the match
  kubectl() { case "$*" in *logs*) echo "booting";; *) printf '%s\n' "$big";; esac; }
  run _diagnose_not_ready testns
  [ "$output" = "crash" ] || return 1
}

@test "_diagnose_not_ready: large (>64KB) jobs-manager log under pipefail still finds auth error (backend#1778)" {
  set -o pipefail
  local big; big=$'Exception: Authentication failed: Unable to log in with provided credentials\n'
  big+="$(printf 'noise line %s\n' $(seq 1 8000))"   # >64KB after the match
  kubectl() { case "$*" in *logs*) printf '%s\n' "$big";; *) echo "x 1/1 Running";; esac; }
  run _diagnose_not_ready testns
  [ "$output" = "bad_creds" ] || return 1
}

@test "_diagnose_not_ready: still creating -> starting" {
  kubectl() { case "$*" in *logs*) echo "booting";; *) echo "x 0/1 ContainerCreating";; esac; }
  run _diagnose_not_ready testns
  [ "$output" = "starting" ] || return 1
}

# ── wait_for_client_ready ──────────────────────────────────────────────────
@test "wait_for_client_ready: all rollouts succeed -> connected" {
  kubectl() { case "$*" in *"rollout status"*) return 0;; *) echo "";; esac; }
  READY_TIMEOUT=20
  CLIENT_STATE=""
  wait_for_client_ready
  [ "$CLIENT_STATE" = "connected" ] || return 1
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
  [ "$CLIENT_STATE" = "bad_creds" ] || return 1
}

# ── print_summary: the trust claim must appear ONLY when connected ─────────
@test "print_summary connected: Connected + trust claim + rich summary blocks" {
  CLIENT_STATE=connected
  TB_CLI_USABLE_NOW=1   # pin CLI-usable so the CTA is the deterministic "Run …" variant (B2)
  run print_summary
  [[ "$output" == *"Connected to tracebloc"* ]] || return 1
  [[ "$output" == *"never leaves this machine"* ]] || return 1   # trust claim (was "data never leaves")
  # rich summary from the run-through
  [[ "$output" == *"Environment"* ]] || return 1
  [[ "$output" == *"Mode"* ]] || return 1
  [[ "$output" == *"Your secure environment is live"* ]] || return 1   # live-status heading (lime ● replaced the 🟢 emoji)
  [[ "$output" == *"What's next"* ]] || return 1
  [[ "$output" == *"tracebloc data ingest"* ]] || return 1
  [[ "$output" == *"my-use-cases"* ]] || return 1
  [[ "$output" == *"Run"* && "$output" == *"to get started"* ]] || return 1
}

@test "print_summary connected: shows the client version" {
  CLIENT_STATE=connected
  helm() { echo "tracebloc tracebloc 1 now deployed client-1.4.4 1.4.4"; }
  run print_summary
  [[ "$output" == *"Version"* ]] || return 1
  [[ "$output" == *"1.4.4"* ]] || return 1
}

# ── GPU mode is HONEST: wired, not merely detected (client#835) ─────────────
# A detected-but-not-wired NVIDIA GPU runs CPU-only, so the summary must say CPU —
# printing "NVIDIA GPU" there is exactly the false claim #835 removes.
@test "print_summary: NVIDIA detected but NOT wired -> Mode: CPU (no false GPU claim)" {
  CLIENT_STATE=connected
  GPU_VENDOR=nvidia; K3D_GPU_FLAGS=()          # detected, cluster is CPU-only
  helm() { echo "tracebloc tracebloc 1 now deployed client-1.4.4 1.4.4"; }
  run print_summary
  [[ "$output" == *"CPU"* ]] || return 1
  [[ "$output" != *"NVIDIA GPU"* ]] || return 1
}

@test "print_summary: NVIDIA wired -> Mode: NVIDIA GPU" {
  CLIENT_STATE=connected
  GPU_VENDOR=nvidia; K3D_GPU_FLAGS=("--gpus=all")
  helm() { echo "tracebloc tracebloc 1 now deployed client-1.4.4 1.4.4"; }
  run print_summary
  [[ "$output" == *"NVIDIA GPU"* ]] || return 1
}

@test "print_summary starting: 'still starting', no trust claim" {
  CLIENT_STATE=starting
  run print_summary
  [[ "$output" == *"still starting"* ]] || return 1
  [[ "$output" != *"never leaves this machine"* ]] || return 1
}

@test "print_summary bad_creds: 'rejected', no trust claim" {
  CLIENT_STATE=bad_creds
  run print_summary
  [[ "$output" == *"rejected"* ]] || return 1
  [[ "$output" != *"never leaves this machine"* ]] || return 1
}

@test "print_summary image_pull: image message, no trust claim" {
  CLIENT_STATE=image_pull
  run print_summary
  [[ "$output" == *"image couldn't be pulled"* ]] || return 1
  [[ "$output" != *"never leaves this machine"* ]] || return 1
}

@test "print_summary crash: crash-loop message" {
  CLIENT_STATE=crash
  run print_summary
  [[ "$output" == *"crash loop"* ]] || return 1
  [[ "$output" != *"never leaves this machine"* ]] || return 1
}

# ── _reboot_note (reboot persistence) ───────────────────────────────────────
@test "_reboot_note: Linux with docker autostart -> survives-reboot line" {
  OS=Linux; TB_DOCKER_AUTOSTART=1
  run _reboot_note
  [[ "$output" == *"restarts automatically"* ]] || return 1
  [[ "$output" != *"Docker Desktop"* ]] || return 1
}

@test "_reboot_note: Linux without docker autostart -> honest 'start Docker' line" {
  # Tier 0 (zero-privilege) never enables docker.service, so the note must NOT
  # promise an automatic restart (Bugbot r3645585369).
  OS=Linux; TB_DOCKER_AUTOSTART=0
  run _reboot_note
  [[ "$output" == *"start Docker"* ]] || return 1
  [[ "$output" != *"restarts automatically"* ]] || return 1
}

@test "_reboot_note: macOS -> Docker Desktop start-on-login instruction" {
  OS=Darwin
  run _reboot_note
  [[ "$output" == *"Docker Desktop"* ]] || return 1
  [[ "$output" == *"open Docker Desktop"* ]] || return 1
}

@test "print_summary connected: includes the reboot note" {
  CLIENT_STATE=connected; OS=Linux; TB_DOCKER_AUTOSTART=1
  run print_summary
  [[ "$output" == *"restarts automatically"* ]] || return 1
}

@test "print_summary connected: node-local storage -> in-node data path, no host /tracebloc" {
  # Under TB_STORAGE_MODE=node-local there is no host /tracebloc bind-mount
  # (RFC-0003 Option C) — the summary must not point at one (Bugbot r3645585376).
  CLIENT_STATE=connected; OS=Linux; TB_DOCKER_AUTOSTART=1; TB_STORAGE_MODE=node-local
  run print_summary
  [[ "$output" == *"in-node (k3s local-path)"* ]] || return 1
  [[ "$output" != *"Data /tracebloc/"* ]] || return 1
}

@test "print_summary connected: hostpath storage -> host /tracebloc data path" {
  CLIENT_STATE=connected; OS=Linux; TB_DOCKER_AUTOSTART=1; TB_STORAGE_MODE=hostpath
  run print_summary
  [[ "$output" == *"Data /tracebloc/testns"* ]] || return 1
}

# ── B2: PATH-aware CTA (grep-based so a false check fails loudly on bash 3.2) ──
@test "print_summary connected: CTA says 'Run' when the CLI is usable now (B2)" {
  CLIENT_STATE=connected; OS=Linux
  helm() { echo "tracebloc tracebloc 1 now deployed client-1.4.4 1.4.4"; }
  TB_CLI_USABLE_NOW=1
  run print_summary
  printf '%s\n' "$output" | grep -qE "Run[[:space:]]+tracebloc"   # the "Run …" branch specifically
  ! printf '%s\n' "$output" | grep -qF "Open a new terminal" || return 1
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
  ! printf '%s\n' "$output" | grep -qF "Open a new terminal" || return 1        # never the useless new-terminal advice
}

@test "print_summary connected: UNSET fresh-path flag falls back to 'open a new terminal', not the 'see above' PATH fix (#371)" {
  # CLI step skipped/failed → TB_CLI_ON_FRESH_PATH never set, and NO PATH-fix was
  # printed. "Add tracebloc to your PATH (see above)" would point at nothing; the
  # safe default is "open a new terminal".
  CLIENT_STATE=connected; OS=Linux
  helm() { echo "tracebloc tracebloc 1 now deployed client-1.4.4 1.4.4"; }
  unset TB_CLI_USABLE_NOW TB_CLI_ON_FRESH_PATH
  has() { [ "$1" = tracebloc ] && return 1; command -v "$1" >/dev/null 2>&1; }
  run print_summary
  printf '%s\n' "$output" | grep -qF "Open a new terminal"
  ! printf '%s\n' "$output" | grep -qF "Add tracebloc to your PATH" || return 1
}

# ── CA-trust diagnosis (#424) ────────────────────────────────────────────────
@test "_diagnose_not_ready: ImagePullBackOff + x509 event -> image_pull_ca (#424)" {
  kubectl() {
    case "$*" in
      *logs*)   echo "booting" ;;
      *events*) echo "Failed to pull image \"ghcr.io/x\": x509: certificate signed by unknown authority" ;;
      *)        echo "x 0/1 ImagePullBackOff" ;;
    esac
  }
  run _diagnose_not_ready testns
  [ "$output" = "image_pull_ca" ] || return 1
}

@test "_diagnose_not_ready: ImagePullBackOff without x509 stays image_pull (#424)" {
  kubectl() {
    case "$*" in
      *logs*)   echo "booting" ;;
      *events*) echo "Back-off pulling image (rate limited)" ;;
      *)        echo "x 0/1 ImagePullBackOff" ;;
    esac
  }
  run _diagnose_not_ready testns
  [ "$output" = "image_pull" ] || return 1
}

@test "_diagnose_not_ready: x509 on an unrelated event (not the pull) stays image_pull (Bugbot #424)" {
  # The pull failure has no x509; a separate, unrelated event carries x509.
  # Must NOT be classified image_pull_ca — that would send the user into a
  # needless delete+recreate for the wrong reason.
  kubectl() {
    case "$*" in
      *logs*)   echo "booting" ;;
      *events*) printf '%s\n' \
                  'Warning  Failed       pod/x   Back-off pulling image "ghcr.io/x"' \
                  'Warning  FailedMount  pod/y   MountVolume failed: x509: certificate signed by unknown authority' ;;
      *)        echo "x 0/1 ImagePullBackOff" ;;
    esac
  }
  run _diagnose_not_ready testns
  [ "$output" = "image_pull" ] || return 1
}

@test "print_summary image_pull_ca: names the CA problem + env var, not a generic pull error (#424)" {
  CLIENT_STATE=image_pull_ca
  TB_NAMESPACE=testns
  run print_summary
  [[ "$output" == *"TLS-inspection CA"* ]] || return 1
  [[ "$output" == *"TRACEBLOC_CA_BUNDLE"* ]] || return 1
  [[ "$output" == *"x509"* ]] || return 1
  [[ "$output" != *"an image couldn't be pulled"* ]] || return 1   # not the generic message
}
