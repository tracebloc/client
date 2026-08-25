#!/usr/bin/env bats
# The macOS "offer to raise the VM" path (backend#2221).
#
# #428 sizes a FRESH Colima VM from physical RAM, so a first install is already
# fine. An EXISTING VM is not: the installer starts it as-is and preflight only
# WARNS. backend#2221 asks for the macOS equivalent of the Windows .wslconfig
# write — "and offers to fix it ... with consent before changing a user's Docker
# settings".
#
# Every test here is about a boundary rather than the happy path, because the
# risks are all on the boundaries: this STOPS the user's container runtime, so it
# must never run unasked, never run non-interactively, and never claim success it
# has not measured.
load test_helper

setup() {
  # shellcheck source=/dev/null
  source "${LIB_DIR}/common.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/preflight.sh"
  # shellcheck source=/dev/null
  source "${LIB_DIR}/setup-macos.sh"
  LOG_FILE=/dev/null
  OS="Darwin"
  MOCK_CALLS="$(mktemp)"
  PRESENT_CMDS="colima docker"
  has() { case " $PRESENT_CMDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
  record() { printf '%s\n' "$*" >> "$MOCK_CALLS"; }
  # Records its own wrapper line AND then runs the command, which records again.
  # Count assertions below therefore anchor with ^...$ — an unanchored `grep -c`
  # counts every colima call twice and reads as "it ran twice".
  spin_cmd_bounded() { record "bounded $*"; local _t="$1" _m="$2"; shift 2; "$@"; }
  # The mock FLIPS the restarted flag, so the "after" size is only visible once a
  # start has actually happened. Setting it up front (my first version) made the
  # very first read return the post-restart figure, so the function correctly saw
  # nothing to fix and every "yes" test failed — a fixture bug that looked like a
  # code bug.
  colima() {
    record "colima $*"
    [[ "$1" == "start" ]] && RESTARTED=1
    return "${COLIMA_RC:-0}"
  }
  # An existing instance unless a test says otherwise.
  _colima_instance_exists() { [[ "${NO_INSTANCE:-}" != "1" ]]; }
  # The VM's memory, in KB — first value, then the value after a restart.
  _pf_runtime_mem_kb() {
    if [[ -n "${RESTARTED:-}" && -n "${MEM_KB_AFTER:-}" ]]; then
      printf '%s' "$MEM_KB_AFTER"
    else
      printf '%s' "${MEM_KB:-}"
    fi
  }
  _macos_vm_mem_gb() { printf '%s' "${TARGET_GB:-8}"; }
  _tty_usable() { [[ "${TTY_OK:-1}" == "1" ]]; }
  # The active runtime. Defaults to colima so the existing tests keep their
  # meaning; DOCKER_CTX="desktop" exercises the wrong-runtime guard.
  docker() {
    record "docker $*"
    if [[ "$1" == "context" && "$2" == "show" ]]; then
      printf '%s' "${DOCKER_CTX:-colima}"
      return "${DOCKER_CTX_RC:-0}"
    fi
    return 0
  }
  # error() exits in production; record it so a hard-fail is assertable.
  error() { record "error $*"; return 1; }
  _read_sanitized() { printf -v "$2" '%s' "${REPLY_IN:-}"; }
  PF_MIN_MEM_GB=5
  unset COLIMA_MEMORY TRACEBLOC_ASSUME_YES
}

calls() { cat "$MOCK_CALLS"; }

# ── it must not fire when there is nothing to fix ───────────────────────────

@test "a VM at or above the floor is left alone" {
  # REPLY_IN=y on purpose. Left empty, the prompt's default decline would stop
  # the restart no matter what, so the test would pass with the floor check
  # DELETED — which a mutation run duly showed. Answering yes makes the floor
  # check the only thing that can prevent it.
  REPLY_IN="y" MEM_KB=$((8 * 1024 * 1024)) TARGET_GB=12 run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  run bash -c "grep -c '^colima stop$' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "no colima instance means no offer" {
  REPLY_IN="y" NO_INSTANCE=1 MEM_KB=$((2 * 1024 * 1024)) run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  [ ! -s "$MOCK_CALLS" ] || return 1
}

@test "a machine with no colima at all is skipped" {
  REPLY_IN="y" PRESENT_CMDS="docker" MEM_KB=$((2 * 1024 * 1024)) run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  [ ! -s "$MOCK_CALLS" ] || return 1
}

@test "an unreadable VM size is not guessed at" {
  # Asserts no colima ACTION rather than no calls at all: the read-only
  # `docker context show` probe legitimately runs before this point, so an
  # empty-log assertion would fail for a reason that is not the behaviour.
  REPLY_IN="y" MEM_KB="" run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  run bash -c "grep -c '^colima ' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "a target no bigger than the current size is not worth a restart" {
  REPLY_IN="y" MEM_KB=$((4 * 1024 * 1024)) TARGET_GB=4 run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  run bash -c "grep -c '^colima ' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "it only runs on Darwin" {
  REPLY_IN="y" OS="Linux" MEM_KB=$((2 * 1024 * 1024)) run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  [ ! -s "$MOCK_CALLS" ] || return 1
}

# ── consent ────────────────────────────────────────────────────────────────

@test "REGRESSION: a non-interactive run prints the command and touches nothing" {
  # The property that matters most. CI and 'curl | bash' have no usable TTY, and
  # an installer that restarts a container runtime nobody authorised is the worst
  # outcome this function can have.
  # REPLY_IN=y for the same reason as the floor test above: with an empty reply
  # the decline would mask a deleted TTY guard entirely, and a mutation run
  # confirmed it did. Answering yes means only the guard can stop the restart.
  TTY_OK=0 REPLY_IN="y" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 \
    run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"colima stop && colima start --memory 8"* ]] || return 1
  run bash -c "grep -c '^colima stop$' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "a bare Enter declines" {
  REPLY_IN="" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Left alone"* ]] || return 1
  run bash -c "grep -c '^colima stop$' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "an explicit no declines" {
  REPLY_IN="n" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 run _offer_colima_memory_raise
  run bash -c "grep -c '^colima stop$' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "yes restarts the VM with the target size" {
  REPLY_IN="y" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 \
    MEM_KB_AFTER=$((8 * 1024 * 1024)) run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  run bash -c "grep -c '^colima stop$' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
  run bash -c "grep -c '^colima start --memory 8$' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
}

@test "TRACEBLOC_ASSUME_YES skips the prompt for an unattended install" {
  TRACEBLOC_ASSUME_YES=1 TTY_OK=0 MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 \
    MEM_KB_AFTER=$((8 * 1024 * 1024)) run _offer_colima_memory_raise
  run bash -c "grep -c '^colima start --memory 8$' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
}

# ── it re-probes rather than assuming ──────────────────────────────────────

@test "a restart that did not actually grow the VM is NOT reported as success" {
  # "I ran the command" and "the VM is bigger" are different claims. Reporting
  # the first as the second is how an installer teaches people to distrust it.
  REPLY_IN="y" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 \
    MEM_KB_AFTER=$((2 * 1024 * 1024)) run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"still reports"* ]] || return 1
  [[ "$output" != *"raised to"* ]] || return 1
}

@test "a growing VM IS reported, with the measured figure" {
  REPLY_IN="y" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 \
    MEM_KB_AFTER=$((8 * 1024 * 1024)) run _offer_colima_memory_raise
  [[ "$output" == *"raised to 8 GB"* ]] || return 1
}

@test "a failed stop leaves the VM alone and says so" {
  REPLY_IN="y" COLIMA_RC=1 MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 \
    run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"Could not stop Colima"* ]] || return 1
  run bash -c "grep -c '^colima start' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "COLIMA_MEMORY overrides the derived target" {
  COLIMA_MEMORY=16 REPLY_IN="y" MEM_KB=$((2 * 1024 * 1024)) \
    MEM_KB_AFTER=$((16 * 1024 * 1024)) run _offer_colima_memory_raise
  run bash -c "grep -c '^colima start --memory 16$' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
}


# ── it must not act on the wrong runtime (Bugbot Medium) ───────────────────

@test "REGRESSION: Docker Desktop's budget does not trigger a Colima restart" {
  # A headless Mac can have Desktop up via VNC AND a stale Colima instance. The
  # memory figure then belongs to DESKTOP, while a yes would stop/start Colima and
  # switch the docker context to it — fixing a problem the user does not have, on
  # a runtime they were not using.
  DOCKER_CTX="desktop" REPLY_IN="y" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 \
    run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  run bash -c "grep -c '^colima stop$' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "an unreadable docker context declines to act" {
  # The safe direction for a function whose action stops a container runtime.
  DOCKER_CTX_RC=1 REPLY_IN="y" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 \
    run _offer_colima_memory_raise
  run bash -c "grep -c '^colima stop$' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "REGRESSION: a NAMED colima profile declines rather than restarting default" {
  # THIS TEST USED TO PIN THE WRONG REQUIREMENT (@LukasWodka on #832). It asserted
  # that a `colima-profile2` context ran the profile-LESS `colima stop` — which is
  # exactly the bug: `colima stop` / `colima start` with no `--profile` act on
  # **default**, so the budget was measured on profile2 and the restart landed on a
  # VM the user was not using. It was a mutation-proof test of the wrong behaviour,
  # which is why it read as coverage.
  DOCKER_CTX="colima-profile2" REPLY_IN="y" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 \
    run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  run bash -c "grep -c '^colima ' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "the named-profile decline names the command that WOULD work" {
  # Declining in silence would leave an operator with a real, fixable problem and
  # no way to see it. The hint carries --profile, which is the part this function
  # cannot safely run itself.
  DOCKER_CTX="colima-profile2" REPLY_IN="y" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 \
    run _offer_colima_memory_raise
  [[ "$output" == *"--profile profile2"* ]] || return 1
}

@test "the default colima context still acts" {
  # The narrowing must not have closed the case the feature exists for.
  DOCKER_CTX="colima" REPLY_IN="y" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 \
    MEM_KB_AFTER=$((8 * 1024 * 1024)) run _offer_colima_memory_raise
  run bash -c "grep -c '^colima stop$' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
}

# ── a failed raise must not leave Docker dead (Bugbot High) ───────────────

@test "REGRESSION: a failed start restores the previous VM" {
  # WE stopped it, so we own getting it back. The first version warned and
  # returned 0, so the install carried on with Docker DOWN — and on the
  # already-running headless path control then fell through to Docker Desktop
  # startup, giving a Desktop error on a Colima machine.
  colima() {
    record "colima $*"
    # The sized start fails; a plain start (recovery) succeeds.
    # The SIZED start fails; the recovery start (at the smaller, measured size)
    # succeeds. Keyed on the value so the two are distinguishable.
    if [[ "$1" == "start" && "$3" == "8" ]]; then return 1; fi
    [[ "$1" == "start" ]] && RESTARTED=1
    return 0
  }
  REPLY_IN="y" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  # EXPLICITLY at the measured size, not a bare `colima start` (Bugbot High): a
  # bare retry relies on the previous config still being on disk, and Colima may
  # already have persisted the rejected --memory.
  run bash -c "grep -c '^colima start --memory 2$' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
  run bash -c "grep -c '^colima start$' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "REGRESSION: a failed start AND a failed recovery is a hard failure" {
  # Continuing here would fail later with a message about something else entirely.
  colima() { record "colima $*"; [[ "$1" == "start" ]] && return 1; return 0; }
  REPLY_IN="y" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 run _offer_colima_memory_raise
  run bash -c "grep -c '^error ' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
}

@test "the hard failure names how to recover" {
  colima() { record "colima $*"; [[ "$1" == "start" ]] && return 1; return 0; }
  REPLY_IN="y" MEM_KB=$((2 * 1024 * 1024)) TARGET_GB=8 run _offer_colima_memory_raise
  run bash -c "grep '^error ' '$MOCK_CALLS'"
  # The GUIDANCE has to carry the size too, or it repeats the config that failed.
  [[ "$output" == *"colima start --memory 2"* ]] || return 1
  [[ "$output" == *"Docker is down"* ]] || return 1
}

# ── a host too small to reach the floor (@LukasWodka on #832) ──────────────

@test "REGRESSION: no offer when the best achievable target is still under the floor" {
  # `_macos_vm_mem_gb` applies the host cap AFTER the safe floor
  # (preflight.sh:189-192), so a 6 GB Mac yields a target of 4 against a floor of
  # 5. Offering that would prompt for a restart that cannot fix the problem — and
  # re-prompt every run, because the machine is the constraint, not the setting.
  REPLY_IN="y" MEM_KB=$((3 * 1024 * 1024)) TARGET_GB=4 run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  run bash -c "grep -c '^colima ' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "the too-small machine is named as the cause, not the setting" {
  REPLY_IN="y" MEM_KB=$((3 * 1024 * 1024)) TARGET_GB=4 run _offer_colima_memory_raise
  [[ "$output" == *"cannot spare 5 GB"* ]] || return 1
  [[ "$output" == *"larger machine"* ]] || return 1
}

@test "a target that DOES clear the floor still offers" {
  # The guard must not have closed the case the feature exists for.
  REPLY_IN="y" MEM_KB=$((3 * 1024 * 1024)) TARGET_GB=8 \
    MEM_KB_AFTER=$((8 * 1024 * 1024)) run _offer_colima_memory_raise
  run bash -c "grep -c '^colima start --memory 8$' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
}

@test "a target exactly AT the floor offers" {
  # >= not >: a VM at the floor is what the floor means.
  REPLY_IN="y" MEM_KB=$((3 * 1024 * 1024)) TARGET_GB=5 \
    MEM_KB_AFTER=$((5 * 1024 * 1024)) run _offer_colima_memory_raise
  run bash -c "grep -c '^colima start --memory 5$' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
}
