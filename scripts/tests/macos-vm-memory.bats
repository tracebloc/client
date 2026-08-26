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
  # The docker "is it up?" probes, stubbed separately from `docker` so a test can
  # say "the daemon is wedged/down" (DOCKER_UP_RC) without also breaking `docker
  # context show`, which the runtime guard needs — and without spawning spin or a
  # real docker. The stop-failure handler moved from _docker_answers to
  # _docker_answers_bounded (backend#2521): the real bounded probe uses spin's
  # kill-deadline because _bounded (what _docker_answers uses) is a no-op on stock
  # macOS. Both are stubbed so the branch logic here stays fast and deterministic;
  # _docker_answers_bounded's actual boundedness is proven in common.bats.
  _docker_answers()         { record "_docker_answers";         return "${DOCKER_UP_RC:-0}"; }
  _docker_answers_bounded() { record "_docker_answers_bounded"; return "${DOCKER_UP_RC:-0}"; }
  # error() EXITS in production; this records and returns so a hard-fail is
  # assertable. The divergence matters: after a stubbed error the function keeps
  # running, so tests must assert on the message they expect rather than on how
  # many errors were raised.
  error() { record "error $*"; return 1; }
  _read_sanitized() { printf -v "$2" '%s' "${REPLY_IN:-}"; }
  PF_MIN_MEM_GB=5
  PF_VM_MEM_GRACE_MIB=512
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

# RELABELLED, not deleted (Bugbot Medium on #832). This used to name the
# `target_gb > current_gb` guard, which my sub-floor reorder made unreachable — so
# the test kept passing while the line it was named for could no longer run.
# The scenario is still worth covering; the mechanism that now handles it is the
# sub-floor branch, and the name says so.
@test "a sub-floor target is rejected by the sub-floor branch, not by a restart-worth check" {
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


# ── the guest-MemTotal grace (Bugbot High) ────────────────────────────────

@test "REGRESSION: a VM set to exactly the floor is NOT prompted about" {
  # preflight.sh says it in its own words: "a VM configured to exactly the
  # documented floor reports a few hundred MiB less as guest MemTotal, and rounding
  # that to whole GB first would misgrade it as sub-floor". I rounded first — so a
  # 5 GB VM reporting ~4.8 GiB truncated to 4, and this path offered to "fix" a
  # healthy runtime. Under TRACEBLOC_ASSUME_YES=1 it would have restarted one
  # unasked, which is the part that makes this High rather than cosmetic.
  REPLY_IN="y" MEM_KB=$(( (5 * 1024 - 300) * 1024 )) TARGET_GB=8 \
    run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  run bash -c "grep -c '^colima ' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "a VM genuinely below the floor is still prompted about" {
  # The grace must not have swallowed the case the feature exists for: 3 GiB is
  # short by far more than the grace can explain.
  REPLY_IN="y" MEM_KB=$(( 3 * 1024 * 1024 )) TARGET_GB=8 \
    MEM_KB_AFTER=$(( 8 * 1024 * 1024 )) run _offer_colima_memory_raise
  run bash -c "grep -c '^colima start --memory 8$' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
}

@test "a VM just OUTSIDE the grace is prompted about" {
  # The boundary: 5 GB minus 700 MiB is more than the 512 MiB grace explains.
  REPLY_IN="y" MEM_KB=$(( (5 * 1024 - 700) * 1024 )) TARGET_GB=8 \
    MEM_KB_AFTER=$(( 8 * 1024 * 1024 )) run _offer_colima_memory_raise
  run bash -c "grep -c '^colima stop$' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
}

@test "the recovery restores the CONFIGURED size, not the guest's short report" {
  # @LukasWodka's round-down wrinkle, closed rather than accepted: a VM configured
  # to 8 GB reports ~7.8 GiB, and restoring at 7 would quietly shrink it. Grading
  # through _pf_display_gb_from_mib recovers the 8.
  colima() {
    record "colima $*"
    if [[ "$1" == "start" && "$3" == "16" ]]; then return 1; fi
    [[ "$1" == "start" ]] && RESTARTED=1
    return 0
  }
  # A VM configured to 4 GB reporting ~3.7 GiB: below the floor (so the offer
  # fires) and short of its own configured size (so the round-down would show).
  # My first version used an 8 GB VM, which is ABOVE the floor — the function
  # returned early and the test proved nothing about recovery at all.
  REPLY_IN="y" MEM_KB=$(( (4 * 1024 - 300) * 1024 )) TARGET_GB=16 \
    run _offer_colima_memory_raise
  run bash -c "grep -c '^colima start --memory 4$' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
  run bash -c "grep -c '^colima start --memory 3$' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "the named-profile hint is not mangled by quote escaping" {
  # The '"'"'\'"'"''"'"' idiom is for a SINGLE-quoted string; in double quotes it emits a
  # literal backslash, muddying the one message that tells an operator what to run.
  DOCKER_CTX="colima-profile2" REPLY_IN="y" MEM_KB=$(( 2 * 1024 * 1024 )) TARGET_GB=8 \
    run _offer_colima_memory_raise
  [[ "$output" == *"profile 'profile2'"* ]] || return 1
  [[ "$output" != *"\\'"* ]] || return 1
}

# ── the sub-floor explanation: right culprit, and it actually prints ────────

@test "REGRESSION: the sub-floor hint prints even when the VM is ALREADY at that target" {
  # It used to sit after the `target_gb > current_gb` guard, so a VM already at the
  # inadequate target returned silently — and the one-shot explanation never
  # printed for the case that needs it most (Bugbot on #832).
  REPLY_IN="y" MEM_KB=$(( 4 * 1024 * 1024 )) TARGET_GB=4 run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"cannot spare 5 GB"* ]] || return 1
  run bash -c "grep -c '^colima ' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "REGRESSION: a sub-floor COLIMA_MEMORY blames the override, not the Mac" {
  # Blaming the machine for an operator's own choice sends them to buy hardware
  # they do not need. Two different problems, two messages.
  COLIMA_MEMORY=4 REPLY_IN="y" MEM_KB=$(( 3 * 1024 * 1024 )) run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"COLIMA_MEMORY is set to 4 GB"* ]] || return 1
  [[ "$output" != *"larger machine"* ]] || return 1
}

@test "a sub-floor DERIVED target still blames the machine" {
  # The other side of the same split: with no override, the machine really is the
  # constraint and saying so is the honest answer.
  REPLY_IN="y" MEM_KB=$(( 3 * 1024 * 1024 )) TARGET_GB=4 run _offer_colima_memory_raise
  [[ "$output" == *"larger machine"* ]] || return 1
  [[ "$output" != *"COLIMA_MEMORY"* ]] || return 1
}

@test "a healthy VM gets no sub-floor lecture at all" {
  # The reorder must not have moved the explanation ahead of the "is it short"
  # check — a VM above the floor has nothing to be told.
  REPLY_IN="y" MEM_KB=$(( 8 * 1024 * 1024 )) TARGET_GB=4 run _offer_colima_memory_raise
  [[ "$output" != *"cannot spare"* ]] || return 1
  [[ "$output" != *"COLIMA_MEMORY"* ]] || return 1
}


# ── a failed STOP is owned too, not just a failed start (Bugbot High) ───────

@test "REGRESSION: a failed stop that left Docker up is reported and left alone" {
  # A genuine "could not stop" with the VM still running is the benign case: say so
  # and change nothing.
  colima() { record "colima $*"; [[ "$1" == "stop" ]] && return 1; return 0; }
  REPLY_IN="y" MEM_KB=$(( 2 * 1024 * 1024 )) TARGET_GB=8 run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"still running"* ]] || return 1
  run bash -c "grep -c '^colima start' '$MOCK_CALLS' || true"
  [ "$output" = "0" ] || return 1
}

@test "REGRESSION: a failed stop that took Docker DOWN triggers recovery" {
  # The dangerous case, and the one the old handler mishandled: a TIMED-OUT stop
  # can leave the VM half-down, and the bounded wrapper reports that identically
  # to a clean refusal. "Left as it was" has to be checked, not assumed.
  colima() { record "colima $*"; [[ "$1" == "stop" ]] && return 1; [[ "$1" == "start" ]] && RESTARTED=1; return 0; }
  DOCKER_UP_RC=1
  REPLY_IN="y" MEM_KB=$(( 2 * 1024 * 1024 )) TARGET_GB=8 run _offer_colima_memory_raise
  [ "$status" -eq 0 ] || return 1
  run bash -c "grep -c '^colima start --memory 2$' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
}

@test "REGRESSION: a failed stop AND a failed recovery is a hard failure" {
  colima() { record "colima $*"; return 1; }
  DOCKER_UP_RC=1
  REPLY_IN="y" MEM_KB=$(( 2 * 1024 * 1024 )) TARGET_GB=8 run _offer_colima_memory_raise
  # ASSERTED ON THE MESSAGE, NOT A COUNT. `error` EXITS in production, so the real
  # run stops here — but the harness stub returns, so execution carries on into the
  # start path and errors a second time. Counting would pin a harness artifact
  # rather than the behaviour; the stop-failure text is the behaviour.
  run bash -c "grep -c 'did not stop cleanly and would not restart' '$MOCK_CALLS' || true"
  [ "$output" = "1" ] || return 1
}
