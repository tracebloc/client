#!/usr/bin/env bats
# =============================================================================
#  telemetry.bats — the installer's one outcome event per install (backend#1907)
#
#  The vocabularies are checked elsewhere, by derivation:
#  scripts/tests/telemetry-vocabulary-agreement.sh parses install-k8s.sh,
#  summary.sh and gen-manifest.sh and compares them to telemetry.sh's closed
#  sets. This file checks the BEHAVIOUR — the event name, the required attribute
#  set, and the privacy boundary, which is asserted against what the code
#  actually renders rather than against a list of keys we hope nobody adds.
# =============================================================================
bats_require_minimum_version 1.7.0
load test_helper

# A value that could only have arrived from the machine this ran on. Written
# down here, independently of anything the matcher inspects — a needle iterated
# out of the haystack finds itself and nothing else.
CANARY="CANARY-PATIENT-7"

setup() {
  load_lib telemetry.sh
  CLIENT_ENV=prod
  OS=Linux
  ARCH=x86_64
  TB_VERSION=v1.9.3
  CLIENT_STATE=""
  TB_ERR_LOC=""
  HOST_DATA_DIR="$BATS_TEST_TMPDIR/data"
  # The data dir must already exist for the spool to be written: telemetry never
  # creates it (see the NFS-guard test below). A real install reaches
  # _telemetry_deliver only after setup_log_file has made it.
  mkdir -p "$HOST_DATA_DIR"
  # main() sets this once the terminal commands (--help, --diagnose,
  # prepare-host) have had their chance to dispatch. The tests that exercise
  # delivery are standing in for a committed install run, so they set it too;
  # the tests BELOW that assert on the latch clear it deliberately.
  telemetry_run_started
  unset TRACEBLOC_NO_TELEMETRY DO_NOT_TRACK 2>/dev/null || true
}

# attr KEY — read one attribute out of a rendered event, without a JSON parser
# (the repo's installer scripts do not get to depend on jq).
attr() {
  printf '%s' "$1" | sed -nE "s/.*\"$2\":\"?([^\",}]*)\"?.*/\1/p"
}

# ── the event name ───────────────────────────────────────────────────────────

@test "the event name follows the exit code, from a literal (contract §6.1)" {
  run telemetry_render_event 0
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *'"event.name":"install.run.succeeded"'* ]] || return 1

  run telemetry_render_event 1
  [[ "$output" == *'"event.name":"install.run.failed"'* ]] || return 1

  # 130/143 are the SIGINT/SIGTERM routes install-k8s.sh installs. A user's
  # Ctrl-C is not an installer failure, and counting it as one moves the rate
  # D9's alerts are written against every time somebody changes their mind.
  run telemetry_render_event 130
  [[ "$output" == *'"event.name":"install.run.cancelled"'* ]] || return 1
  run telemetry_render_event 143
  [[ "$output" == *'"event.name":"install.run.cancelled"'* ]] || return 1
}

@test "the DECLARED exit-2 re-run handoff is not a failure (saadqbal, client#747)" {
  # gpu-nvidia.sh exits 2 after install_nvidia_drivers SUCCEEDED, to ask for a
  # reboot. That call sits under step_header b, so folding 2 into `failed` booked
  # a fabricated `prerequisites_failed` on every unattended GPU host's first
  # install — in the very rate this ticket exists to produce. install_cleanup has
  # treated 2 as its own outcome ("Re-run required") since client#681.
  TB_TELEMETRY_PHASE=prerequisites
  telemetry_rerun_handoff          # what the `exit 2` site does before exiting
  run telemetry_render_event 2
  [ "$status" -eq 0 ] || return 1
  [ "$(attr "$output" 'event.name')" = "install.run.cancelled" ] || return 1
  [[ "$output" != *'"error.type"'* ]] || return 1
  # The exit code is what separates the handoff from the user's own Ctrl-C, so it
  # has to be on the record — the name deliberately does not carry it.
  [ "$(attr "$output" 'tracebloc.install.exit_code')" = "2" ] || return 1

  # The anchor: an ordinary failure in the same phase must STILL be a failure, or
  # every assertion above is satisfied by a function that never says `failed`.
  run telemetry_render_event 1
  [ "$(attr "$output" 'event.name')" = "install.run.failed" ] || return 1
  [ "$(attr "$output" 'error.type')" = "prerequisites_failed" ] || return 1
}

@test "an UNDECLARED exit 2 is a failure with its own error.type (saadqbal, client#747)" {
  # 2 is a sentinel the installer chose AND a status ordinary tools produce: grep
  # exits 2 on a file error, curl on a failed init, tar on a fatal, and
  # cluster.sh:1129 re-raises whatever k3d returned. Keyed on the NUMBER, every one
  # of those rendered `cancelled` with no error.type — a hard failure removed from
  # the NUMERATOR of the rate this ticket exists to produce rather than misfiled
  # inside it, which is the direction nobody notices.
  #
  # So: no marker, no handoff. Fail closed toward counting it.
  TB_TELEMETRY_PHASE=prerequisites
  [ -z "$_TB_TELEMETRY_RERUN_HANDOFF" ] || return 1   # nothing has declared one
  run telemetry_render_event 2
  [ "$status" -eq 0 ] || return 1
  [ "$(attr "$output" 'event.name')" = "install.run.failed" ] || return 1
  # And it is DISTINGUISHABLE — not folded into the phase's own bucket, where a
  # stray 2 would be indistinguishable from a real prerequisite failure, and not
  # `unclassified`, which already means "we cannot name the phase".
  [ "$(attr "$output" 'error.type')" = "unexpected_exit_2" ] || return 1
  [ "$(attr "$output" 'tracebloc.install.exit_code')" = "2" ] || return 1
  # The phase is not lost by flattening the class: it is its own attribute.
  [ "$(attr "$output" 'tracebloc.install.phase')" = "prerequisites" ] || return 1

  # It wins over a readiness diagnosis too: an exit status that was not ours to
  # read is a less trustworthy input than saying so, and client_state stays on the
  # record either way.
  TB_TELEMETRY_PHASE=connect
  CLIENT_STATE=image_pull_ca
  run telemetry_render_event 2
  [ "$(attr "$output" 'error.type')" = "unexpected_exit_2" ] || return 1
  [ "$(attr "$output" 'tracebloc.install.client_state')" = "image_pull_ca" ] || return 1
  # The anchor: the same state on an ordinary failure still yields the diagnosis,
  # or this test would pass against a classifier that only ever says one thing.
  run telemetry_render_event 1
  [ "$(attr "$output" 'error.type')" = "image_pull_untrusted_ca" ] || return 1
}

@test "the marker cannot be inherited from the environment (fail closed)" {
  # The marker is a process-internal handshake, not an input. Read off the
  # environment, `_TB_TELEMETRY_RERUN_HANDOFF=1` in a user's shell would turn every
  # real failure into a cancel — the same fail-open hole one level down. telemetry.sh
  # clears it at source time, before main() runs.
  run env _TB_TELEMETRY_RERUN_HANDOFF=1 CLIENT_ENV=prod OS=Linux ARCH=x86_64 \
    bash -c 'source "'"$LIB_DIR"'/common.sh"; source "'"$LIB_DIR"'/telemetry.sh"
             LOG_FILE=/dev/null; telemetry_render_event 2'
  [ "$status" -eq 0 ] || return 1
  [ "$(attr "$output" 'event.name')" = "install.run.failed" ] || return 1
  [ "$(attr "$output" 'error.type')" = "unexpected_exit_2" ] || return 1

  # The anchor: the same harness DOES honour a handoff declared in-process, so the
  # assertion above is about where the value came from and not about the harness
  # being unable to produce a cancel at all.
  run env CLIENT_ENV=prod OS=Linux ARCH=x86_64 \
    bash -c 'source "'"$LIB_DIR"'/common.sh"; source "'"$LIB_DIR"'/telemetry.sh"
             LOG_FILE=/dev/null; telemetry_rerun_handoff; telemetry_render_event 2'
  [ "$(attr "$output" 'event.name')" = "install.run.cancelled" ] || return 1
}

@test "every event name the renderer produces is one it declares" {
  # §6.2: the set of names a service can emit must be finite and enumerable. The
  # renderer's answer is checked against TB_TELEMETRY_EVENT_NAMES before it is
  # written, and an unregistered one DROPS the record rather than opening a
  # namespace of its own — the same rule §3.2 applies to the environment.
  local code ev
  for code in 0 1 2 42 130 143; do
    ev="$(attr "$(telemetry_render_event "$code")" 'event.name')"
    [ -n "$ev" ] || { printf 'exit %s rendered no event.name\n' "$code" >&2; return 1; }
    _telemetry_in_set "$ev" "$TB_TELEMETRY_EVENT_NAMES" || {
      printf 'exit %s rendered undeclared name %s\n' "$code" "$ev" >&2; return 1
    }
  done
  # And the guard is not vacuous: an undeclared name must be refused, not filed.
  TB_TELEMETRY_EVENT_NAMES="install.run.succeeded"
  run telemetry_render_event 1
  [ "$status" -ne 0 ] || { printf 'an undeclared event name was rendered anyway\n' >&2; return 1; }
  [ -z "$output" ] || return 1
}

@test "a cancel carries no error.type; a failure must (contract §8.4)" {
  run telemetry_render_event 130
  [[ "$output" != *'"error.type"'* ]] || return 1

  run telemetry_render_event 1
  [[ "$output" == *'"error.type"'* ]] || return 1
}

@test "a failure's error.type comes from the phase and the client state" {
  TB_TELEMETRY_PHASE=prerequisites
  run telemetry_render_event 1
  [ "$(attr "$output" 'error.type')" = "prerequisites_failed" ] || return 1

  # A readiness diagnosis wins over the phase: it names the actual fault, where
  # the phase only names where the run stopped.
  TB_TELEMETRY_PHASE=connect
  CLIENT_STATE=image_pull_ca
  run telemetry_render_event 1
  [ "$(attr "$output" 'error.type')" = "image_pull_untrusted_ca" ] || return 1
}

@test "an unregistered CLIENT_STATE or phase is dropped, not passed through" {
  # CLIENT_STATE and TB_TELEMETRY_PHASE are shell variables in a script that
  # sources sixteen files, and a shell variable is not a closed set until
  # something closes it.
  #
  # Both subjects are SHAPE-SAFE on purpose. A value with a '/' in it is refused
  # by _telemetry_attr's token shape whatever the vocabulary does, so testing
  # with a path proves only the shape guard — under the mutation that deletes
  # the set-membership check entirely, that version of this test stayed green.
  # `degraded` and `verifying` are exactly what a future edit to summary.sh or
  # install-k8s.sh would produce, and they are what must not appear.
  CLIENT_STATE="degraded"
  TB_TELEMETRY_PHASE="verifying"
  run telemetry_render_event 1
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"degraded"* ]] || return 1
  [[ "$output" != *"verifying"* ]] || return 1
  [[ "$output" != *'"tracebloc.install.client_state"'* ]] || return 1
  # The phase is REPORTED as unknown rather than omitted: "we saw a phase we
  # cannot name" has to stay countable, or the drift is invisible.
  [ "$(attr "$output" 'tracebloc.install.phase')" = "unknown" ] || return 1
  # …and the record still classifies rather than losing error.type entirely.
  [ "$(attr "$output" 'error.type')" = "unclassified" ] || return 1

  # The other half: registered values must still survive, or every assertion
  # above is satisfied by a function that drops everything.
  CLIENT_STATE="crash"
  TB_TELEMETRY_PHASE="helm"
  run telemetry_render_event 1
  [ "$(attr "$output" 'tracebloc.install.client_state')" = "crash" ] || return 1
  [ "$(attr "$output" 'tracebloc.install.phase')" = "helm" ] || return 1
}

# ── the privacy boundary ─────────────────────────────────────────────────────

@test "no path, credential or hostname can reach the record on ANY input" {
  # Every string the installer holds that a record could plausibly pick up, set
  # to something that would be a disclosure. This is the ticket's hard boundary,
  # asserted over what the code renders rather than over a list of forbidden keys.
  HOST_DATA_DIR="/Users/$CANARY/.tracebloc"
  CLUSTER_NAME="$CANARY-cluster"
  TB_NAMESPACE="$CANARY"
  HTTPS_PROXY="http://$CANARY:hunter2@proxy.hospital.internal:3128"
  HTTP_PROXY="$HTTPS_PROXY"
  NO_PROXY="$CANARY.internal"
  TB_VERSION="v1.9.3-$CANARY"
  TB_ERR_LOC="/var/folders/qx/$CANARY/T/tmp.9k/scripts/lib/setup-linux.sh:412"
  # TB_ERR_CMD is what common.sh's ERR trap records: the failing command,
  # UNEXPANDED. It is still free text and still carries a path, which is why it
  # is never emitted. (Deliberately not written as `curl -u user:pass` here —
  # that spelling is a real credential pattern and gitleaks is right to flag it
  # in a source file, canary or not. The credential half of this test is carried
  # by HTTPS_PROXY above.)
  TB_ERR_CMD="install_client_helm --values /Users/$CANARY/values.yaml"
  CLIENT_STATE="$CANARY"
  TB_TELEMETRY_PHASE="$CANARY"
  USER="$CANARY"
  HOSTNAME="$CANARY-macbook"

  run telemetry_render_event 1
  [ "$status" -eq 0 ] || return 1
  # The anchor: an empty render would pass "the canary is absent" trivially.
  [[ "$output" == *'"event.name":"install.run.failed"'* ]] || return 1
  [[ "$output" != *"$CANARY"* ]] || return 1
  [[ "$output" != *"hunter2"* ]] || return 1
  [[ "$output" != *"hospital.internal"* ]] || return 1
  [[ "$output" != *"/var/folders"* ]] || return 1
}

@test "a value with an embedded newline is refused, not split across two records" {
  # The one input shape the "nowhere for a path to go" argument does not cover:
  # what lands is not a path, it is a SECOND LINE. `grep -qE` matched line by
  # line, so the shape checks read the first line, said yes, and wrote the whole
  # thing — forging an attribute and splitting one record across two lines of a
  # `.jsonl` spool, which #1906's forwarder would read as two malformed events.
  # (saadqbal on client#747; reproduced on all four checks before fixing.)
  local nl=$'\n'

  # 1. the resource layer, through TB_VERSION and _telemetry_version.
  TB_VERSION="v1.9.3${nl}\",\"tracebloc.install.injected\":\"yes"
  run telemetry_render_event 0
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"injected"* ]] || return 1
  [ "$(printf '%s' "$output" | grep -c .)" = "1" ] || {
    printf 'the record was split across %s lines\n' "$(printf '%s' "$output" | grep -c .)" >&2
    return 1
  }
  [ "$(attr "$output" 'service.version')" = "0.0.0-unknown" ] || return 1
  TB_VERSION=v1.9.3

  # 2. the attribute writer — the str, int and key shapes, each on its own.
  _telemetry_reset
  _telemetry_attr "tracebloc.install.phase" "helm${nl}/etc/passwd"
  [ -z "$_TB_TELEMETRY_BUF" ] || { printf 'str: %s\n' "$_TB_TELEMETRY_BUF" >&2; return 1; }
  _telemetry_reset
  _telemetry_attr "tracebloc.install.duration_ms" "12${nl},\"x\":\"y" int
  [ -z "$_TB_TELEMETRY_BUF" ] || { printf 'int: %s\n' "$_TB_TELEMETRY_BUF" >&2; return 1; }
  _telemetry_reset
  _telemetry_attr "event.name${nl}bad key" "ok"
  [ -z "$_TB_TELEMETRY_BUF" ] || { printf 'key: %s\n' "$_TB_TELEMETRY_BUF" >&2; return 1; }

  # 3. the source line number.
  run _telemetry_source_line "cluster.sh:88${nl}/etc/shadow"
  [ "$status" -ne 0 ] || { printf 'source_line admitted: %s\n' "$output" >&2; return 1; }

  # The anchor for all four: the legal spellings must still be ADMITTED, or a
  # function that refuses everything passes this test.
  _telemetry_reset
  _telemetry_attr "tracebloc.install.phase" "helm"
  [[ "$_TB_TELEMETRY_BUF" == *'"tracebloc.install.phase":"helm"'* ]] || return 1
  _telemetry_attr "tracebloc.install.duration_ms" "12" int
  [[ "$_TB_TELEMETRY_BUF" == *'"tracebloc.install.duration_ms":12'* ]] || return 1
  [ "$(_telemetry_source_line "cluster.sh:88")" = "88" ] || return 1
  run telemetry_render_event 0
  [ "$(attr "$output" 'service.version')" = "v1.9.3" ] || return 1
}

@test "every rendered value is an int or a safe token — the derived guard" {
  # Not a list of forbidden keys; that agrees with itself and says nothing about
  # the twentieth attribute somebody adds. This walks what the code ACTUALLY
  # renders and requires every value to be one of the two shapes telemetry.sh
  # declares. A free-text channel of any kind fails it, whether or not anyone
  # thought to forbid the thing travelling down it.
  HOST_DATA_DIR="/Users/$CANARY/.tracebloc"
  TB_ERR_LOC="/tmp/$CANARY/scripts/lib/cluster.sh:88"
  CLIENT_STATE=crash
  TB_TELEMETRY_PHASE=helm
  TB_CLI_ON_FRESH_PATH=0

  run telemetry_render_event 9
  [ "$status" -eq 0 ] || return 1

  local pairs count=0
  # Flatten "key":value / "key":"value" pairs out of the rendered object.
  pairs="$(printf '%s' "$output" | tr ',{}' '\n\n\n' | sed '/^$/d')"
  while IFS= read -r pair; do
    # `"resource":` and `"attributes":` flatten to a key with an empty value —
    # they are the object wrappers, not attributes.
    [ -n "$pair" ] || continue
    case "$pair" in *:) continue ;; esac
    local key="${pair%%:*}" value="${pair#*:}"
    key="${key%\"}"; key="${key#\"}"
    case "$value" in
      \"*\") # a string: must be a safe token
        value="${value%\"}"; value="${value#\"}"
        printf '%s' "$value" | grep -qE "$TB_TELEMETRY_TOKEN_RE" || {
          printf 'value for %s is not a safe token: %s\n' "$key" "$value" >&2
          return 1
        }
        ;;
      *)     # a bare literal: must be an integer
        printf '%s' "$value" | grep -qE "$TB_TELEMETRY_INT_RE" || {
          printf 'value for %s is neither a quoted token nor an integer: %s\n' "$key" "$value" >&2
          return 1
        }
        ;;
    esac
    printf '%s' "$key" | grep -qE "$TB_TELEMETRY_KEY_RE" || {
      printf 'key is not a contract-shaped attribute key: %s\n' "$key" >&2
      return 1
    }
    count=$(( count + 1 ))
  done <<<"$pairs"

  # An inert loop over an empty payload reads exactly like a clean sweep.
  [ "$count" -ge 12 ] || { printf 'only %s pairs inspected\n' "$count" >&2; return 1; }
}

@test "_telemetry_attr drops an unsafe value rather than trimming it" {
  # Dropping, not repairing, is the design: a value that had to be cleaned up to
  # be safe is a value we did not understand, and shipping our guess about it is
  # how a redactor leaks.
  _telemetry_reset
  _telemetry_attr "tracebloc.install.phase" "/etc/$CANARY/rows.csv"
  [ -z "$_TB_TELEMETRY_BUF" ] || return 1

  _telemetry_reset
  _telemetry_attr "tracebloc.install.exit_code" "not-a-number" int
  [ -z "$_TB_TELEMETRY_BUF" ] || return 1

  # A key that is not contract-shaped is refused too (§1.1).
  _telemetry_reset
  _telemetry_attr "podName" "ok"
  [ -z "$_TB_TELEMETRY_BUF" ] || return 1

  # …and a legitimate pair still lands, or every assertion above is vacuous.
  _telemetry_reset
  _telemetry_attr "tracebloc.install.phase" "helm"
  [ "$_TB_TELEMETRY_BUF" = '"tracebloc.install.phase":"helm"' ] || return 1
}

@test "the source is a basename from the installer's own scripts, never the path" {
  TB_ERR_LOC="/var/folders/qx/$CANARY/T/scripts/lib/setup-linux.sh:412"
  run telemetry_render_event 1
  [ "$(attr "$output" 'tracebloc.install.source')" = "setup-linux.sh" ] || return 1
  [ "$(attr "$output" 'tracebloc.install.source_line')" = "412" ] || return 1
  [[ "$output" != *"$CANARY"* ]] || return 1

  # A file that is not one of ours is dropped, not reported.
  TB_ERR_LOC="/home/$CANARY/evil.sh:9"
  run telemetry_render_event 1
  [[ "$output" != *'"tracebloc.install.source"'* ]] || return 1
  [[ "$output" != *"evil.sh"* ]] || return 1
  # …and the LINE goes with it. This assertion was the gap: the two halves were
  # gated independently, so this same input emitted `"…source_line":9` on its own.
  [[ "$output" != *'"tracebloc.install.source_line"'* ]] || return 1
}

@test "a line number is never emitted without the file it belongs to (Bugbot, client#747)" {
  # `tracebloc.install.source` and `tracebloc.install.source_line` were two
  # independent gates over ONE fact. A location whose basename is not one of ours
  # dropped the file and kept the number, and a line number with no file is worse
  # than no field at all: it looks like information, groups like information, and
  # points at line 118 of nothing.
  #
  # The inputs are written down HERE, independently of the matcher, and the
  # expectation for each is derived by asking TB_TELEMETRY_SOURCES — the closed
  # vocabulary that is the declaration — rather than by restating which of these
  # is ours. Get the pairing wrong in either direction and this reddens.
  local loc base expect_source
  for loc in \
    "/var/folders/qx/T/scripts/lib/cluster.sh:88" \
    "/opt/tracebloc/lib/install-cli.sh:7" \
    "/home/someone/evil.sh:9" \
    "/usr/lib/node_modules/npm/bin/npm-cli.js:60" \
    "?:118" \
    "install-k8s.sh:1"
  do
    TB_ERR_LOC="$loc"
    base="${loc%%:*}"; base="${base##*/}"
    if _telemetry_in_set "$base" "$TB_TELEMETRY_SOURCES"; then
      expect_source="$base"
    else
      expect_source=""
    fi

    run telemetry_render_event 1
    [ "$status" -eq 0 ] || { printf 'render died on %s: %s\n' "$loc" "$output" >&2; return 1; }

    # The anchor: whatever we conclude about the pair, this is still a failure
    # event carrying an error.type. "No source keys" must not be reachable by
    # having quietly lost the whole event.
    [[ "$output" == *'"event.name":"install.run.failed"'* ]] || {
      printf 'not a failure event for %s: %s\n' "$loc" "$output" >&2; return 1
    }
    [[ "$output" == *'"error.type"'* ]] || {
      printf 'no error.type for %s\n' "$loc" >&2; return 1
    }

    if [ -n "$expect_source" ]; then
      [ "$(attr "$output" 'tracebloc.install.source')" = "$expect_source" ] || {
        printf 'declared source %s not reported for %s: %s\n' "$expect_source" "$loc" "$output" >&2
        return 1
      }
      [ "$(attr "$output" 'tracebloc.install.source_line')" = "${loc##*:}" ] || {
        printf 'source without its line for %s: %s\n' "$loc" "$output" >&2; return 1
      }
    else
      [[ "$output" != *'"tracebloc.install.source"'* ]] || {
        printf 'undeclared source %s reached the record: %s\n' "$base" "$output" >&2; return 1
      }
      [[ "$output" != *'"tracebloc.install.source_line"'* ]] || {
        printf 'ORPHAN LINE: %s has no source but its line was emitted: %s\n' "$loc" "$output" >&2
        return 1
      }
    fi
  done

  # The loop above is only worth anything if at least one input took each branch —
  # six undeclared paths and no declared one would pass every assertion while
  # proving only half the rule.
  TB_ERR_LOC="/x/cluster.sh:88"
  run telemetry_render_event 1
  [[ "$output" == *'"tracebloc.install.source_line":88'* ]] || {
    printf 'ANCHOR: the positive case does not emit a line at all, so the negative cases prove nothing\n' >&2
    return 1
  }
}

# ── the three field failures this ticket names ───────────────────────────────

@test "the #736 PATH case is a number: cli_on_path rides every event" {
  # install-cli.sh already computes this — whether a FRESH login shell resolves
  # `tracebloc` — and until now only ever printed advice about it.
  TB_CLI_ON_FRESH_PATH=0
  run telemetry_render_event 0
  [ "$(attr "$output" 'tracebloc.install.cli_on_path')" = "0" ] || return 1

  TB_CLI_ON_FRESH_PATH=1
  run telemetry_render_event 0
  [ "$(attr "$output" 'tracebloc.install.cli_on_path')" = "1" ] || return 1

  # Unset (the CLI step was skipped) omits the key rather than guessing a 0,
  # which would be indistinguishable from "installed, and unreachable".
  unset TB_CLI_ON_FRESH_PATH
  run telemetry_render_event 0
  [[ "$output" != *'"tracebloc.install.cli_on_path"'* ]] || return 1
}

@test "a slow phase is visible on a run that SUCCEEDED (the dpkg-lock shape)" {
  # apt-get blocked on unattended-upgrades produces no non-zero exit at all — it
  # just takes twenty minutes. Per-phase durations are the only thing that makes
  # it visible, so they must ride the success event too.
  step_header a "Checking your machine" >/dev/null
  _TB_TELEMETRY_PHASE_STARTED_MS=$(( $(_telemetry_now_ms) - 1320000 ))
  step_header b "Installing what tracebloc needs" >/dev/null

  run telemetry_render_event 0
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *'"event.name":"install.run.succeeded"'* ]] || return 1
  local ms
  ms="$(attr "$output" 'tracebloc.install.phase_preflight_ms')"
  [ -n "$ms" ] || { printf 'no preflight duration on a success event\n' >&2; return 1; }
  [ "$ms" -ge 1320000 ] || { printf 'preflight recorded %s ms, expected >= 1320000\n' "$ms" >&2; return 1; }
}

@test "the STILL-RUNNING phase has a duration (Bugbot, client#747)" {
  # The test above only ever measured a phase that a LATER step_header had
  # closed. telemetry_phase_begin is the only writer, so the phase still running
  # when the event fires had nothing recorded against it — and that is the one
  # that matters:
  #   * the dpkg-lock case in its likeliest real form is stuck twenty minutes in
  #     `prerequisites` and then killed or given up on, never reaching step c;
  #   * every SUCCESSFUL install ends in `connect`, the readiness wait, up to
  #     READY_TIMEOUT (600s) — the single longest phase, and it had no key at all.
  step_header a "x" >/dev/null
  step_header b "x" >/dev/null
  _TB_TELEMETRY_PHASE_STARTED_MS=$(( $(_telemetry_now_ms) - 1320000 ))

  # Cancelled while stuck in prerequisites.
  run telemetry_render_event 130
  [ "$status" -eq 0 ] || return 1
  [ "$(attr "$output" 'tracebloc.install.phase')" = "prerequisites" ] || return 1
  local ms
  ms="$(attr "$output" 'tracebloc.install.phase_prerequisites_ms')"
  [ -n "$ms" ] || { printf 'the active phase had no duration\n' >&2; return 1; }
  [ "$ms" -ge 1320000 ] || { printf 'active phase recorded %s ms\n' "$ms" >&2; return 1; }

  # And the success case: connect is always the active phase at emit time.
  step_header f "x" >/dev/null
  _TB_TELEMETRY_PHASE_STARTED_MS=$(( $(_telemetry_now_ms) - 400000 ))
  run telemetry_render_event 0
  ms="$(attr "$output" 'tracebloc.install.phase_connect_ms')"
  [ -n "$ms" ] || { printf 'a successful install had no connect duration\n' >&2; return 1; }
  [ "$ms" -ge 400000 ] || return 1
}

@test "bootstrap time is attributed, not left as an unnamed remainder" {
  # `bootstrap` has no step letter, so iterating the letter map skipped it and the
  # download + verify + leftover-guard + assess time became a remainder nobody
  # could name — which is also why subtracting the other keys from duration_ms
  # could not recover the missing active phase.
  TB_TELEMETRY_STARTED_MS=$(( $(_telemetry_now_ms) - 60000 ))
  _TB_TELEMETRY_PHASE_STARTED_MS="$TB_TELEMETRY_STARTED_MS"
  run telemetry_render_event 1
  local ms
  ms="$(attr "$output" 'tracebloc.install.phase_bootstrap_ms')"
  [ -n "$ms" ] || { printf 'bootstrap time is unattributed\n' >&2; return 1; }
  [ "$ms" -ge 60000 ] || { printf 'bootstrap recorded %s ms\n' "$ms" >&2; return 1; }
}

@test "the phase durations sum EXACTLY to duration_ms" {
  # The invariant that makes the numbers trustworthy rather than merely present:
  # every millisecond of the run is attributed to exactly one phase. A phase whose
  # time vanishes — the Bugbot bug above — breaks it, and so does double-counting.
  #
  # Driven by a FAKE CLOCK, because the obvious fixture is wrong: winding
  # _TB_TELEMETRY_PHASE_STARTED_MS backwards after the step_headers have already
  # attributed that time invents milliseconds that never elapsed, and the first
  # version of this test failed for exactly that reason (sum 1200000 vs total
  # 900000). Overriding the clock is the only way to build a fixture the
  # accounting can actually be true of.
  local T=1000000
  _telemetry_now_ms() { echo "$T"; }
  TB_TELEMETRY_STARTED_MS="$T"
  _TB_TELEMETRY_PHASE_STARTED_MS="$T"

  T=$(( T + 5000 ));    step_header a "x" >/dev/null   # bootstrap      5 s
  T=$(( T + 20000 ));   step_header b "x" >/dev/null   # preflight     20 s
  T=$(( T + 1320000 )); step_header e "x" >/dev/null   # prerequisites 22 min
  T=$(( T + 300000 ))                                  # helm still running, 5 min
  # c and d were never entered, so they must carry no key at all.

  run telemetry_render_event 1
  [ "$status" -eq 0 ] || return 1

  local total sum=0 name ms counted=0
  total="$(attr "$output" 'tracebloc.install.duration_ms')"
  [ "$total" = "1645000" ] || { printf 'duration_ms=%s, want 1645000\n' "$total" >&2; return 1; }
  # DERIVED: iterate the production phase-name list, not a list written here.
  for name in $(_telemetry_phase_names); do
    ms="$(attr "$output" "tracebloc.install.phase_${name}_ms")"
    [ -n "$ms" ] || continue
    sum=$(( sum + ms ))
    counted=$(( counted + 1 ))
  done
  # Anchor: an inert loop finding no keys would sum to 0 and could still agree
  # with a 0-length run's total.
  [ "$counted" = "4" ] || { printf 'found %s phase keys, want 4\n' "$counted" >&2; return 1; }
  [ "$sum" = "$total" ] || {
    printf 'phases sum to %s but duration_ms is %s\n' "$sum" "$total" >&2; return 1
  }
  # The individual attributions, so a compensating pair of errors cannot pass.
  [ "$(attr "$output" 'tracebloc.install.phase_bootstrap_ms')" = "5000" ] || return 1
  [ "$(attr "$output" 'tracebloc.install.phase_preflight_ms')" = "20000" ] || return 1
  [ "$(attr "$output" 'tracebloc.install.phase_prerequisites_ms')" = "1320000" ] || return 1
  [ "$(attr "$output" 'tracebloc.install.phase_helm_ms')" = "300000" ] || return 1
  # A phase never entered carries no key (§1.2 omits an absent value).
  [[ "$output" != *'"tracebloc.install.phase_cluster_ms"'* ]] || return 1
  [[ "$output" != *'"tracebloc.install.phase_register_ms"'* ]] || return 1
}

@test "step_header is what drives the phase clock, so no step can be forgotten" {
  [ "$TB_TELEMETRY_PHASE" = "bootstrap" ] || return 1
  step_header c "Creating your secure environment" >/dev/null
  [ "$TB_TELEMETRY_PHASE" = "cluster" ] || return 1
  step_header f "Connecting to the tracebloc network" >/dev/null
  [ "$TB_TELEMETRY_PHASE" = "connect" ] || return 1

  # A letter the map has never seen becomes `unknown` — a countable finding,
  # not a guessed phase name.
  step_header z "Something new" >/dev/null
  [ "$TB_TELEMETRY_PHASE" = "unknown" ] || return 1
}

# ── environment ──────────────────────────────────────────────────────────────

@test "an unrecognised CLIENT_ENV renders nothing at all (contract §3.2)" {
  # `staging` is the classic near miss: it is the git branch name, and `stg` is
  # the environment value. tb_client_env reduces the documented alias…
  CLIENT_ENV=staging
  run telemetry_render_event 0
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *'"deployment.environment":"stg"'* ]] || return 1

  # …but a value nothing reduces is refused outright rather than filed under a
  # guess. A record no query filters on is worse than no record.
  CLIENT_ENV=qa
  run telemetry_render_event 0
  [ "$status" -ne 0 ] || return 1
  [ -z "$output" ] || return 1
}

@test "unset CLIENT_ENV is prod, matching _backend_url's own default" {
  unset CLIENT_ENV
  run telemetry_render_event 0
  [[ "$output" == *'"deployment.environment":"prod"'* ]] || return 1
}

@test "the resource layer carries the registered identity and OTel's own names" {
  run telemetry_render_event 0
  [[ "$output" == *'"service.name":"installer"'* ]] || return 1
  [[ "$output" == *'"tracebloc.component":"install"'* ]] || return 1
  [[ "$output" == *'"os.type":"linux"'* ]] || return 1
  [[ "$output" == *'"host.arch":"amd64"'* ]] || return 1
  [[ "$output" == *'"service.version":"v1.9.3"'* ]] || return 1

  # §4 — unknown is a VALUE, not an omission: queryable and alertable, where an
  # absent key is neither.
  unset TB_VERSION
  run telemetry_render_event 0
  [[ "$output" == *'"service.version":"0.0.0-unknown"'* ]] || return 1
}

@test "service.instance.id is per-process and is not the hostname" {
  # §7.3 forbids a person's name outright, and field hostnames here are
  # overwhelmingly "<firstname>-macbook".
  HOSTNAME="$CANARY-macbook"
  local a b
  a="$(_telemetry_instance_id)"
  b="$(_telemetry_instance_id)"
  [ "$a" = "$b" ] || return 1                      # stable within the process
  [ "${#a}" -eq 16 ] || return 1
  [[ "$a" != *"$CANARY"* ]] || return 1
  printf '%s' "$a" | grep -qE '^[a-f0-9]{16}$' || return 1
}

# ── opt-out and delivery ─────────────────────────────────────────────────────

@test "opt-out stops emission entirely, and only the opt-out spellings do" {
  local spool="$HOST_DATA_DIR/telemetry/pending.jsonl"
  for var in $TB_TELEMETRY_OPT_OUT_VARS; do
    for value in 1 true yes please; do
      _TB_TELEMETRY_EMITTED=""
      rm -f "$spool"
      eval "export $var=$value"
      telemetry_emit_outcome 0
      eval "unset $var"
      [ ! -s "$spool" ] || { printf '%s=%s still emitted\n' "$var" "$value" >&2; return 1; }
    done
  done

  # The anchor for the loop above: if telemetry_enabled returned false
  # unconditionally the whole feature would be dead and every case would pass.
  for value in "" 0 false FALSE; do
    _TB_TELEMETRY_EMITTED=""
    rm -f "$spool"
    export TRACEBLOC_NO_TELEMETRY="$value"
    telemetry_emit_outcome 0
    unset TRACEBLOC_NO_TELEMETRY
    [ -s "$spool" ] || { printf '%q disabled telemetry; only an opt-out should\n' "$value" >&2; return 1; }
  done
}

@test "exactly one event per install, however many times the trap fires" {
  local spool="$HOST_DATA_DIR/telemetry/pending.jsonl"
  telemetry_emit_outcome 0
  telemetry_emit_outcome 1
  telemetry_emit_outcome 130
  [ "$(grep -c . "$spool")" = "1" ] || return 1
  grep -q '"event.name":"install.run.succeeded"' "$spool" || return 1
}

@test "the spool is bounded, 0600, and in a 0700 directory" {
  local spool="$HOST_DATA_DIR/telemetry/pending.jsonl"
  TB_TELEMETRY_SPOOL_MAX=3
  local i
  for i in 1 2 3 4 5 6; do
    _TB_TELEMETRY_EMITTED=""
    telemetry_emit_outcome "$i"
  done
  [ "$(grep -c . "$spool")" = "3" ] || return 1
  [ "$(_perm_of "$spool")" = "600" ] || return 1
  [ "$(_perm_of "$(dirname "$spool")")" = "700" ] || return 1
}

@test "the spool is 0600 under the umask the installer can actually be holding" {
  # The test above could not see the defect it was written to pin, and the reason
  # is in this file: load_lib sources common.sh, which sets `umask 077`, so every
  # test ran under a umask that made the mode right by accident. The trim
  # (`tail > "${spool}.tmp"` then `mv`) creates under the PROCESS umask and mv
  # keeps the tmp file's mode, so a chmod that ran only before it left a 0644
  # spool the moment the umask was anything else — and _install_userspace_tools
  # (setup-linux.sh:893) and its macOS twin (setup-macos.sh:418) set `umask 022`
  # around install_{kubectl,k3d,helm} and restore it only afterwards, so an
  # install that dies in one of those emits from the EXIT trap under 022.
  # (saadqbal on client#747; reproduced — spool 644.)
  local spool="$HOST_DATA_DIR/telemetry/pending.jsonl" saved
  saved="$(umask)"
  umask 022
  # Assert the mutation anchor applied: if common.sh has been re-sourced or the
  # umask did not take, this test is measuring 077 again and proves nothing.
  [ "$(umask)" = "0022" ] || { umask "$saved"; printf 'umask did not take\n' >&2; return 1; }
  TB_TELEMETRY_SPOOL_MAX=2
  local i
  for i in 1 2 3; do
    _TB_TELEMETRY_EMITTED=""
    telemetry_emit_outcome "$i"
  done
  local mode dir_mode lines
  mode="$(_perm_of "$spool")"
  dir_mode="$(_perm_of "$(dirname "$spool")")"
  lines="$(grep -c . "$spool")"
  umask "$saved"
  [ "$mode" = "600" ] || { printf 'spool is %s under umask 022, not 600\n' "$mode" >&2; return 1; }
  [ "$dir_mode" = "700" ] || return 1
  # The trim must still have run — a spool that was never rewritten would keep
  # its 600 for the wrong reason and this test would pass vacuously.
  [ "$lines" = "2" ] || { printf 'the trim did not run (%s lines)\n' "$lines" >&2; return 1; }
}

@test "install_cleanup emits the outcome on every path, including a cancel" {
  # The EXIT trap is where "a terminal event on every path" (§6.5) is actually
  # honoured — a failure that exits under errexit never reaches any other line.
  local spool="$HOST_DATA_DIR/telemetry/pending.jsonl"
  CLIENT_STATE=""
  run bash -c '
    set -euo pipefail
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    LOG_FILE=/dev/null
    HOST_DATA_DIR="'"$HOST_DATA_DIR"'"
    CLIENT_ENV=prod
    telemetry_run_started    # main() does this once the run is committed
    trap install_cleanup EXIT
    exit 130
  '
  [ "$status" -eq 130 ] || return 1
  grep -q '"event.name":"install.run.cancelled"' "$spool" || return 1
}

@test "an ordinary tool's status 2 lands in the numerator, under the real trap" {
  # THE REPRODUCTION, as a test. A bare `grep` on an unreadable file exits 2 — its
  # own file-error status, nothing to do with the installer's sentinel — and under
  # `set -e` that becomes install-k8s.sh's exit status. Keyed on the number, this
  # spooled install.run.cancelled with no error.type: a hard failure REMOVED from
  # the rate rather than misfiled in it. (saadqbal on client#747.)
  #
  # Driven through install_cleanup with install-k8s.sh's own trap wiring, not
  # through telemetry_render_event, because the whole point is what an unmodified
  # command failing somewhere in the middle of a real run produces.
  local spool="$HOST_DATA_DIR/telemetry/pending.jsonl"
  run bash -c '
    set -euo pipefail
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    LOG_FILE=/dev/null
    HOST_DATA_DIR="'"$HOST_DATA_DIR"'"
    CLIENT_ENV=prod
    telemetry_run_started
    trap install_cleanup EXIT
    set -E
    trap '"'"'_record_err "${BASH_SOURCE[0]:-?}:${LINENO}" "$BASH_COMMAND"'"'"' ERR
    telemetry_phase_begin b
    grep -q anything /nonexistent/definitely/not/here
  ' 3>&-
  # The anchor: grep really did supply the 2, so the assertions below are about a
  # tool's own status and not about a number this test picked.
  [ "$status" -eq 2 ] || { printf 'expected exit 2 from grep, got %s\n' "$status" >&2; return 1; }
  grep -q '"event.name":"install.run.failed"' "$spool" || {
    printf 'the record was: %s\n' "$(cat "$spool")" >&2; return 1
  }
  grep -q '"error.type":"unexpected_exit_2"' "$spool" || return 1
  # …and NOT the phase's ordinary bucket, which would hide it among real ones.
  ! grep -q '"error.type":"prerequisites_failed"' "$spool" || return 1
}

@test "gpu-nvidia's reboot handoff still renders a cancel, through its real exit" {
  # The other direction, and the one that must not regress: the marker has to be
  # SET at the site, so this drives install_nvidia_drivers itself rather than
  # re-implementing its exit. A mutation that drops the setter call from
  # gpu-nvidia.sh has to redden here (workspace CLAUDE.md rule 9); asserting on a
  # hand-written `telemetry_rerun_handoff; exit 2` could not see it.
  local spool="$HOST_DATA_DIR/telemetry/pending.jsonl"
  run bash -c '
    set -euo pipefail
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    source "'"$LIB_DIR"'/gpu-nvidia.sh"
    LOG_FILE=/dev/null
    HOST_DATA_DIR="'"$HOST_DATA_DIR"'"
    CLIENT_ENV=prod
    telemetry_run_started
    trap install_cleanup EXIT
    telemetry_phase_begin b
    NVIDIA_DRIVER_OK=false
    PM_UPDATE=true
    PM_INSTALL=true
    has() { return 0; }
    sudo() { return 0; }
    ubuntu-drivers() { return 0; }
    TRACEBLOC_SKIP_REBOOT_PROMPT=1
    install_nvidia_drivers
  ' 3>&-
  [ "$status" -eq 2 ] || { printf 'expected the exit-2 handoff, got %s\n' "$status" >&2; return 1; }
  grep -q '"event.name":"install.run.cancelled"' "$spool" || {
    printf 'the record was: %s\n' "$(cat "$spool")" >&2; return 1
  }
  ! grep -q '"error.type"' "$spool" || return 1
}

@test "a --help run installs nothing and must emit nothing (Bugbot, client#747)" {
  # install_cleanup is the EXIT trap, so it fires for every exit of
  # install-k8s.sh — including the terminal commands that touch no machine.
  # `--help` was emitting a full install.run.succeeded: a free success in the
  # denominator of the exact failure RATE this feature exists to produce, and
  # the command people run most while a real install is broken.
  #
  # Driven through the REAL entrypoint, not the helper, because the bug was in
  # which exits reach the trap — a unit test of telemetry_emit_outcome cannot
  # see it, and none of the twenty tests above did.
  local spool
  for flag in --help -h; do
    local dir="$BATS_TEST_TMPDIR/help-${flag#--}"
    spool="$dir/telemetry/pending.jsonl"
    run env HOST_DATA_DIR="$dir" CLIENT_ENV=prod \
      bash "$SCRIPTS_DIR/install-k8s.sh" "$flag"
    [ "$status" -eq 0 ] || return 1
    # The anchor: prove --help actually ran, so an empty spool means "emitted
    # nothing" and not "the command never started".
    [[ "$output" == *"tracebloc"* ]] || return 1
    [ ! -s "$spool" ] || {
      printf '%s emitted an event: %s\n' "$flag" "$(cat "$spool")" >&2
      return 1
    }
  done
}

@test "the already-set-up handoff is skipped, not succeeded" {
  # The stop-and-check gate exits 0 having run no step. Counting that as a
  # successful install makes the success count grow with re-runs on machines
  # nothing happened to, and the failure rate fall for an unrelated reason.
  # `skipped` is a registered outcome verb (§6.4), so this needs no new vocabulary.
  telemetry_run_skipped
  run telemetry_render_event 0
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *'"event.name":"install.run.skipped"'* ]] || return 1

  # …and a run that did NOT skip still reports success, or the branch above is
  # simply relabelling every success.
  _TB_TELEMETRY_SKIPPED=""
  run telemetry_render_event 0
  [[ "$output" == *'"event.name":"install.run.succeeded"'* ]] || return 1
}

@test "a committed run still emits once the latch is set" {
  # The anchor for the --help test: if the latch were never set, the whole
  # feature would be dead and "--help emits nothing" would pass trivially.
  local spool="$HOST_DATA_DIR/telemetry/pending.jsonl"
  _TB_TELEMETRY_EMITTED=""; _TB_TELEMETRY_RUN_STARTED=""
  telemetry_emit_outcome 0
  [ ! -s "$spool" ] || { printf 'emitted with no latch\n' >&2; return 1; }

  _TB_TELEMETRY_EMITTED=""
  telemetry_run_started
  telemetry_emit_outcome 0
  [ -s "$spool" ] || { printf 'the latch did not enable emission\n' >&2; return 1; }
}

@test "a real run past the terminal commands DOES emit (the latch is wired)" {
  # The anchor for the --help test, and it must go through the REAL entrypoint:
  # deleting main()'s telemetry_run_started call kills the whole feature, and a
  # unit test that sets the latch itself cannot notice. Nothing did, until this.
  #
  # HOST_DATA_DIR == $HOME is rejected by validate_config, which is AFTER the
  # latch and BEFORE step a — so this also pins the case the latch had to
  # preserve: a genuine failure in the bootstrap phase is still an install
  # attempt and must still be reported.
  local dir="$BATS_TEST_TMPDIR/real"
  mkdir -p "$dir"
  local spool="$dir/telemetry/pending.jsonl"
  run env HOME="$dir" HOST_DATA_DIR="$dir" CLIENT_ENV=prod \
    TRACEBLOC_SKIP_LEFTOVER_GUARD=1 \
    bash "$SCRIPTS_DIR/install-k8s.sh"
  [ "$status" -ne 0 ] || return 1
  [ -s "$spool" ] || { printf 'a committed run emitted nothing\n' >&2; return 1; }
  [ "$(grep -c . "$spool")" = "1" ] || return 1
  grep -q '"event.name":"install.run.failed"' "$spool" || {
    printf 'wrong event: %s\n' "$(cat "$spool")" >&2; return 1
  }
  grep -q '"tracebloc.install.phase":"bootstrap"' "$spool" || return 1
  grep -q '"error.type":"bootstrap_failed"' "$spool" || return 1
}

@test "_assess_handoff itself marks the run skipped (the wiring, not the flag)" {
  # Setting _TB_TELEMETRY_SKIPPED by hand proves the render branch and says
  # nothing about whether anything calls it — deleting assess.sh's call reddened
  # no test. Drive the real handoff, with `tracebloc` mocked so it exits instead
  # of rendering a home screen.
  local dir="$BATS_TEST_TMPDIR/handoff"
  mkdir -p "$dir/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/tracebloc"
  chmod +x "$dir/bin/tracebloc"
  local spool="$dir/telemetry/pending.jsonl"

  run bash -c '
    set -uo pipefail
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    source "'"$LIB_DIR"'/assess.sh"
    LOG_FILE=/dev/null
    HOME="'"$dir"'"; HOST_DATA_DIR="'"$dir"'"; CLIENT_ENV=prod
    PATH="'"$dir"'/bin:$PATH"; TB_TTY=/dev/null
    telemetry_run_started          # main() has committed to the run
    trap install_cleanup EXIT
    _assess_handoff
  '
  [ "$status" -eq 0 ] || { printf 'handoff exited %s: %s\n' "$status" "$output" >&2; return 1; }
  [ -s "$spool" ] || { printf 'the handoff emitted nothing\n' >&2; return 1; }
  grep -q '"event.name":"install.run.skipped"' "$spool" || {
    printf 'wrong event: %s\n' "$(cat "$spool")" >&2; return 1
  }
}

@test "an unrecognised source location drops the field, never the event" {
  # Bugbot (client#747) predicted the opposite: that the unprotected command
  # substitutions feeding tracebloc.install.source would abort telemetry_render_event
  # under `set -e` and take the whole outcome with them. That mechanism does not
  # exist — a command substitution in an ARGUMENT position does not propagate its
  # status to the enclosing command, verified on bash 3.2 (the system bash on
  # macOS) and 5.x. The INVARIANT is worth pinning anyway: nothing about a
  # location we cannot classify should cost us the event.
  run bash -c '
    set -euo pipefail
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    LOG_FILE=/dev/null
    HOST_DATA_DIR="'"$BATS_TEST_TMPDIR"'/src"
    CLIENT_ENV=prod
    TB_ERR_LOC="/home/someone/not-ours.sh:9"
    telemetry_render_event 1
  '
  [ "$status" -eq 0 ] || { printf 'render died: %s\n' "$output" >&2; return 1; }
  [[ "$output" == *'"event.name":"install.run.failed"'* ]] || return 1
  [[ "$output" == *'"error.type"'* ]] || return 1
  [[ "$output" != *'"tracebloc.install.source"'* ]] || return 1
  [[ "$output" != *"not-ours.sh"* ]] || return 1
}

@test "telemetry never creates HOST_DATA_DIR on a volume the installer refused" {
  # early_data_dir_guard refuses a network filesystem BEFORE logging starts,
  # because MySQL/InnoDB corrupts on NFS (client#432). It deliberately skips an
  # existing directory ("an EXISTING data dir has no at-risk mkdir here",
  # client#441) — so anything that creates that directory behind its back
  # disarms it for every subsequent run.
  #
  # _telemetry_deliver did exactly that: it ran from the EXIT trap and mkdir -p'd
  # $HOST_DATA_DIR/telemetry unconditionally, including on the path where the
  # guard had just called `error`. Run 1 refused and created the dir; run 2 saw
  # the dir, returned 0, and installed onto NFS. Found by Bugbot (client#747).
  local vol="$BATS_TEST_TMPDIR/nfs-volume"
  local target="$vol/.tracebloc"
  local tmp="$BATS_TEST_TMPDIR/nfs-tmp"
  mkdir -p "$tmp"
  # LOG_FILE is deliberately NOT set. early_data_dir_guard runs BEFORE
  # setup_log_file (#432 refuses a network data dir before logging starts), so on
  # the real path there is no log yet — and an earlier version of this test set
  # LOG_FILE=/dev/null, which masked the follow-on bug that the event went
  # nowhere at all (Bugbot, client#747, round 4).
  run env TMPDIR="$tmp" bash -c '
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    source "'"$LIB_DIR"'/preflight.sh"
    CLIENT_ENV=prod
    HOST_DATA_DIR="'"$target"'"
    _pf_fstype() { echo nfs; }     # the target reads as a network filesystem
    telemetry_run_started
    trap install_cleanup EXIT
    early_data_dir_guard
  '
  # The anchor: prove the guard actually refused, so "no directory" cannot mean
  # "the guard never ran".
  [ "$status" -ne 0 ] || { printf 'the guard did not refuse; fixture is inert\n' >&2; return 1; }
  [[ "$output" == *"network filesystem"* ]] || return 1

  [ ! -d "$target" ] || {
    printf 'telemetry created %s on the rejected volume — the guard is disarmed for the next run\n' "$target" >&2
    return 1
  }

  # …and the refusal is still REPORTED. It is a real, actionable field failure,
  # and it was the one case that produced no record anywhere — invisible to the
  # failure rate this feature exists to produce.
  local fallback
  fallback="$(ls "$tmp"/tracebloc-telemetry-* 2>/dev/null | head -1)"
  [ -n "$fallback" ] || { printf 'the NFS refusal produced no record at all\n' >&2; return 1; }
  grep -q '"event.name":"install.run.failed"' "$fallback" || return 1
  grep -q '"error.type":"bootstrap_failed"' "$fallback" || return 1
  [ "$(_perm_of "$fallback")" = "600" ] || return 1

  # …and the other half: where the data dir legitimately exists, the spool is
  # still written, or the fix has simply disabled the feature.
  mkdir -p "$target"
  run bash -c '
    set -uo pipefail
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    LOG_FILE=/dev/null
    CLIENT_ENV=prod
    HOST_DATA_DIR="'"$target"'"
    telemetry_run_started
    telemetry_emit_outcome 1
  '
  [ "$status" -eq 0 ] || return 1
  [ -s "$target/telemetry/pending.jsonl" ] || {
    printf 'the spool is no longer written even into an existing data dir\n' >&2
    return 1
  }
}

@test "the pre-log record survives the BOOTSTRAP, not just the process" {
  # The test below hands the fallback a TMPDIR of its own, and that is exactly
  # the shape that hid this: on the real `curl | bash` path TMPDIR is the
  # bootstrap's own scratch dir, and the bootstrap deletes it. install.sh:238
  # does `TMPDIR="$(mktemp -d)"` — a plain assignment to a name that is ALREADY
  # EXPORTED (always on macOS) keeps the export attribute — :239 traps
  # `rm -rf "$TMPDIR"`, and :571 runs the installer out of it. So every pre-log
  # record landed inside the doomed directory and was gone before anyone could
  # read it, on the primary macOS path. (saadqbal on client#747; reproduced.)
  #
  # This test reproduces the bootstrap rather than describing it: it unpacks the
  # libs into the scratch dir and sources them from THERE, because "where is the
  # installer running from" is what the fix derives its answer from.
  local boot="$BATS_TEST_TMPDIR/boot" home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$boot" "$home"
  run env HOME="$home" TB_BOOT="$boot" bash -c '
    TMPDIR="$(mktemp -d "$TB_BOOT/tb-XXXXXX")"
    export TMPDIR
    trap '\''rm -rf "$TMPDIR"'\'' EXIT
    mkdir -p "$TMPDIR/lib"
    cp "'"$LIB_DIR"'"/*.sh "$TMPDIR/lib/"
    bash -c '\''
      set -uo pipefail
      source "$TMPDIR/lib/common.sh"
      source "$TMPDIR/lib/telemetry.sh"
      CLIENT_ENV=prod
      HOST_DATA_DIR="$TB_BOOT/never-created"
      unset LOG_FILE
      telemetry_run_started
      telemetry_emit_outcome 1
    '\''
  '
  [ "$status" -eq 0 ] || { printf 'the bootstrap stand-in died: %s\n' "$output" >&2; return 1; }
  # The scratch dir is gone, as it is on a real run.
  [ -z "$(ls "$boot" 2>/dev/null)" ] || {
    printf 'the bootstrap stand-in did not clean up, so this proves nothing: %s\n' "$(ls "$boot")" >&2
    return 1
  }
  local record
  record="$(ls "$home"/tracebloc-telemetry-* 2>/dev/null | head -1)"
  [ -n "$record" ] || { printf 'the record did not survive the bootstrap\n' >&2; return 1; }
  grep -q '"event.name":"install.run.failed"' "$record" || return 1
  # Still never the data dir the installer refused.
  [ ! -d "$boot/never-created" ] || return 1
}

@test "a pre-log failure is still reported (no log, no data dir)" {
  # validate_config and early_data_dir_guard both run BEFORE setup_log_file, so
  # on those paths `log` is a no-op AND (correctly) no data dir exists. Together
  # those two facts silently discarded the event. This is the general case; the
  # NFS test above is the specific one that made it matter.
  #
  # NOTE this test gives the fallback a TMPDIR that nothing deletes, so it says
  # nothing about the curl|bash path — the test above is the one that does.
  local tmp="$BATS_TEST_TMPDIR/prelog"
  mkdir -p "$tmp"
  run env TMPDIR="$tmp" bash -c '
    set -uo pipefail
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    CLIENT_ENV=prod
    HOST_DATA_DIR="'"$BATS_TEST_TMPDIR"'/never-created"
    unset LOG_FILE
    telemetry_run_started
    telemetry_emit_outcome 1
  '
  [ "$status" -eq 0 ] || return 1
  [ ! -d "$BATS_TEST_TMPDIR/never-created" ] || return 1
  local fallback
  fallback="$(ls "$tmp"/tracebloc-telemetry-* 2>/dev/null | head -1)"
  [ -n "$fallback" ] || { printf 'a pre-log failure produced no record\n' >&2; return 1; }
  grep -q '"event.name":"install.run.failed"' "$fallback" || return 1

  # The fallback must be a FRESH file per run, not a predictable shared path:
  # /tmp is world-writable on Linux and the installer runs privileged steps, so a
  # fixed name is a symlink target. mktemp creates with O_EXCL.
  run env TMPDIR="$tmp" bash -c '
    source "'"$LIB_DIR"'/common.sh"; source "'"$LIB_DIR"'/telemetry.sh"
    CLIENT_ENV=prod; HOST_DATA_DIR="'"$BATS_TEST_TMPDIR"'/never-created"; unset LOG_FILE
    telemetry_run_started; telemetry_emit_outcome 1
  '
  [ "$(ls "$tmp"/tracebloc-telemetry-* | wc -l | tr -d " ")" = "2" ] || {
    printf 'the fallback reuses a predictable path\n' >&2; return 1
  }
}

@test "a data dir that will not take the write falls through to the fallback (Bugbot, client#747)" {
  # The data-dir spool's mkdir and append were both `|| return 0`, so a data dir
  # that EXISTS but refuses the write ended the function with the record nowhere.
  # That is not an exotic path: HOST_DATA_DIR present but unwritable is precisely
  # when _choose_log_file has already fallen back to a mktemp log — and on
  # curl|bash that log is inside the bootstrap's own doomed TMPDIR — so the `log`
  # line kept nothing either. The fallback existed and was unreachable in exactly
  # the case it was built for.
  [[ "$(id -u)" -eq 0 ]] && skip "root bypasses filesystem permission bits"
  local dd="$BATS_TEST_TMPDIR/ro/.tracebloc" tmp="$BATS_TEST_TMPDIR/ro/tmp"
  mkdir -p "$dd" "$tmp"
  chmod 500 "$dd"                       # exists; telemetry/ cannot be created in it

  # ANCHOR 1 — this fixture IS the _choose_log_file fallback case, checked by
  # calling _choose_log_file rather than by asserting that it is.
  local logf
  logf="$(env TMPDIR="$tmp" bash -c '
    source "'"$LIB_DIR"'/common.sh"; HOST_DATA_DIR="'"$dd"'"; _choose_log_file
  ' 2>/dev/null)"
  case "$logf" in
    "$dd"/*) printf 'ANCHOR: the log went into the data dir, so this is not the fallback case\n' >&2
             chmod 700 "$dd"; return 1 ;;
  esac

  run env TMPDIR="$tmp" bash -c '
    set -uo pipefail
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    CLIENT_ENV=prod
    HOST_DATA_DIR="'"$dd"'"
    LOG_FILE="'"$logf"'"
    telemetry_run_started
    telemetry_emit_outcome 1
  '
  [ "$status" -eq 0 ] || { chmod 700 "$dd"; printf 'emit died: %s\n' "$output" >&2; return 1; }

  # ANCHOR 2 — the mkdir really did fail. Without this, a fix that quietly made
  # the directory writable would read identically to a fix that fell through.
  [ ! -d "$dd/telemetry" ] || {
    chmod 700 "$dd"
    printf 'ANCHOR: telemetry/ was created after all, so nothing was diverted\n' >&2
    return 1
  }

  local fb
  fb="$(ls "$tmp"/tracebloc-telemetry-* 2>/dev/null | head -1)"
  [ -n "$fb" ] || { chmod 700 "$dd"; printf 'the record went nowhere\n' >&2; return 1; }
  grep -q '"event.name":"install.run.failed"' "$fb" || { chmod 700 "$dd"; return 1; }
  [ "$(_perm_of "$fb")" = "600" ] || { chmod 700 "$dd"; return 1; }
  chmod 700 "$dd"

  # The other half of the same hole, and this one is not about permissions at all —
  # it holds for root too: telemetry/ exists, but the spool path cannot be appended
  # to. The old code returned 0 here as well.
  local dd2="$BATS_TEST_TMPDIR/blocked/.tracebloc" tmp2="$BATS_TEST_TMPDIR/blocked/tmp"
  mkdir -p "$dd2/telemetry/pending.jsonl" "$tmp2"   # a DIRECTORY where the file goes
  run env TMPDIR="$tmp2" bash -c '
    set -uo pipefail
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    CLIENT_ENV=prod
    HOST_DATA_DIR="'"$dd2"'"
    LOG_FILE=/dev/null
    telemetry_run_started
    telemetry_emit_outcome 1
  '
  [ "$status" -eq 0 ] || { printf 'emit died on the blocked spool: %s\n' "$output" >&2; return 1; }
  # ANCHOR — the append could not have succeeded, and the shell's own diagnostic
  # about it must not have been printed at the user out of the EXIT trap.
  [ -d "$dd2/telemetry/pending.jsonl" ] || {
    printf 'ANCHOR: the spool path is no longer a directory, so the append was not blocked\n' >&2
    return 1
  }
  [[ "$output" != *"Is a directory"* ]] || {
    printf 'the shell leaked the spool path to the user from the trap: %s\n' "$output" >&2; return 1
  }
  local fb2
  fb2="$(ls "$tmp2"/tracebloc-telemetry-* 2>/dev/null | head -1)"
  [ -n "$fb2" ] || { printf 'a blocked append produced no record\n' >&2; return 1; }
  grep -q '"event.name":"install.run.failed"' "$fb2" || return 1
}

@test "a spool that DID take the write is not filed twice (Bugbot, client#747)" {
  # The other direction of the same fix, and the one that would be invisible: if
  # the data-dir branch stopped returning on success, every ordinary install would
  # write its outcome to the spool AND to a fallback file, doubling the denominator
  # of the failure rate this feature exists to produce and littering TMPDIR on
  # every run.
  local dd="$BATS_TEST_TMPDIR/ok/.tracebloc" tmp="$BATS_TEST_TMPDIR/ok/tmp"
  mkdir -p "$dd" "$tmp"
  run env TMPDIR="$tmp" bash -c '
    set -uo pipefail
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    CLIENT_ENV=prod
    HOST_DATA_DIR="'"$dd"'"
    LOG_FILE=/dev/null
    telemetry_run_started
    telemetry_emit_outcome 0
  '
  [ "$status" -eq 0 ] || { printf 'emit died: %s\n' "$output" >&2; return 1; }
  # ANCHOR — the spool really was written, so "no fallback" cannot mean "nothing
  # happened at all".
  [ "$(wc -l < "$dd/telemetry/pending.jsonl" | tr -d ' ')" = "1" ] || {
    printf 'the data-dir spool does not hold exactly one line: %s\n' \
      "$(cat "$dd/telemetry/pending.jsonl" 2>/dev/null)" >&2
    return 1
  }
  [ "$(ls "$tmp"/tracebloc-telemetry-* 2>/dev/null | wc -l | tr -d ' ')" = "0" ] || {
    printf 'the event was filed twice — once in the spool and once in the fallback\n' >&2
    return 1
  }

  # A failure AFTER the append must not divert either: the line is already on disk,
  # so a broken trim is a bounding problem, never a second row.
  #
  # `tail` is broken with a shell FUNCTION, not with a PATH shim. The first version
  # of this used a shim directory and proved nothing: common.sh:8 does
  # `export PATH="/usr/local/sbin:…:/bin:${PATH}"`, which PREPENDS the system
  # directories, so a shim prepended by the caller ends up behind /usr/bin and the
  # real `tail` ran. Both assertions below passed against a trim that had worked
  # perfectly. A function wins over PATH lookup outright and cannot be reordered.
  # (Caught by mutating the trim's own cleanup and watching this test stay green.)
  local spool="$dd/telemetry/pending.jsonl"
  local i
  for i in 3 4 5 6 7; do printf 'filler-%s\n' "$i" >> "$spool"; done
  run env TMPDIR="$tmp" bash -c '
    set -uo pipefail
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    tail() { return 1; }                 # beats PATH, whatever common.sh did to it
    command -v tail >/dev/null && [ "$(type -t tail)" = "function" ] || {
      echo "ANCHOR-TAIL-NOT-OVERRIDDEN"; exit 3; }
    CLIENT_ENV=prod
    TB_TELEMETRY_SPOOL_MAX=3
    HOST_DATA_DIR="'"$dd"'"
    LOG_FILE=/dev/null
    telemetry_run_started
    telemetry_emit_outcome 1
  '
  [ "$status" -eq 0 ] || { printf 'a failing trim killed the emit: %s\n' "$output" >&2; return 1; }
  [[ "$output" != *"ANCHOR-TAIL-NOT-OVERRIDDEN"* ]] || {
    printf 'the trim was never actually broken, so this proves nothing\n' >&2; return 1
  }
  # ANCHOR — the trim really did fail: with SPOOL_MAX=3 and 7 lines in the spool, a
  # working trim leaves 3. Anything else and the fixture is inert.
  [ "$(grep -c . "$spool")" = "7" ] || {
    printf 'ANCHOR: the spool holds %s lines, so the trim ran after all\n' "$(grep -c . "$spool")" >&2
    return 1
  }
  [ "$(ls "$tmp"/tracebloc-telemetry-* 2>/dev/null | wc -l | tr -d ' ')" = "0" ] || {
    printf 'a failing trim diverted an already-written record into the fallback\n' >&2; return 1
  }
  [ ! -e "${spool}.tmp" ] || {
    printf 'the failed trim left its scratch file behind\n' >&2; return 1
  }

  # The trim's OTHER failure exit: tail succeeds, the mv does not. Its `|| rm -f`
  # was the one line in this function no mutation could redden, because a fixture
  # that breaks the directory cannot let tail write the .tmp in the first place.
  # Overriding `mv` is the only way to construct it, so it is constructed rather
  # than assumed harmless.
  run env TMPDIR="$tmp" bash -c '
    set -uo pipefail
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    mv() { return 1; }
    [ "$(type -t mv)" = "function" ] || { echo "ANCHOR-MV-NOT-OVERRIDDEN"; exit 3; }
    CLIENT_ENV=prod
    TB_TELEMETRY_SPOOL_MAX=3
    HOST_DATA_DIR="'"$dd"'"
    LOG_FILE=/dev/null
    telemetry_run_started
    telemetry_emit_outcome 1
  '
  [ "$status" -eq 0 ] || { printf 'a failing mv killed the emit: %s\n' "$output" >&2; return 1; }
  [[ "$output" != *"ANCHOR-MV-NOT-OVERRIDDEN"* ]] || {
    printf 'mv was never overridden, so this proves nothing\n' >&2; return 1
  }
  # ANCHOR — the mv really did fail: a working one would have left SPOOL_MAX=3
  # lines. 8 means the trimmed copy never replaced the spool.
  [ "$(grep -c . "$spool")" = "8" ] || {
    printf 'ANCHOR: the spool holds %s lines, so the mv landed after all\n' "$(grep -c . "$spool")" >&2
    return 1
  }
  [ ! -e "${spool}.tmp" ] || {
    printf 'a failed mv left the trimmed copy behind\n' >&2; return 1
  }
  [ "$(ls "$tmp"/tracebloc-telemetry-* 2>/dev/null | wc -l | tr -d ' ')" = "0" ] || {
    printf 'a failing mv diverted an already-written record into the fallback\n' >&2; return 1
  }
}

@test "nothing here can kill the installer under set -euo pipefail" {
  # This class bit twice while writing the file, and both times every unit-level
  # test stayed green:
  #   * `printf ... | grep -q` returns 141 on a MATCH, because grep -q closes the
  #     pipe (the backend#1778 shape, in summary.sh's own comment);
  #   * `tr -dc … < /dev/urandom | head -c 16` returns 141 for the same reason —
  #     at SOURCE time, so the installer died before printing a line.
  # The installer runs under `set -euo pipefail` and calls this from an EXIT
  # trap, so a non-zero anywhere in here is a fatal that a user would experience
  # as the installer vanishing. Exercise the whole surface under those options.
  run bash -c '
    set -euo pipefail
    source "'"$LIB_DIR"'/common.sh"
    source "'"$LIB_DIR"'/telemetry.sh"
    LOG_FILE=/dev/null
    HOST_DATA_DIR="'"$BATS_TEST_TMPDIR"'/euo"
    CLIENT_ENV=prod; OS=Darwin; ARCH=arm64; TB_VERSION=v1.9.3
    telemetry_run_started
    step_header a "x" >/dev/null
    step_header f "x" >/dev/null
    TB_CLI_ON_FRESH_PATH=0
    CLIENT_STATE=crash
    TB_ERR_LOC="/tmp/scripts/lib/cluster.sh:88"
    telemetry_render_event 0  >/dev/null
    telemetry_render_event 1  >/dev/null
    telemetry_render_event 130 >/dev/null
    telemetry_emit_outcome 1
    echo SURVIVED
  '
  [ "$status" -eq 0 ] || { printf "died with %s: %s\n" "$status" "$output" >&2; return 1; }
  [[ "$output" == *"SURVIVED"* ]] || return 1
}

# _perm_of PATH — octal mode, portable across GNU and BSD stat.
_perm_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}
