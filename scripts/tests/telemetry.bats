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
    trap install_cleanup EXIT
    exit 130
  '
  [ "$status" -eq 130 ] || return 1
  grep -q '"event.name":"install.run.cancelled"' "$spool" || return 1
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
