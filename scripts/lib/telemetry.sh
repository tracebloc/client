#!/usr/bin/env bash
# =============================================================================
#  telemetry.sh — one structured outcome event per install (backend#1907)
#
#  RFC-BACKEND-1872 D12's host-process path; the record shape is
#  rfcs/specs/backend-1872-telemetry-contract.md, where this component is
#  registered as service.name=installer / tracebloc.component=install (§10.1).
#
#  WHY. The installer is the highest-variance, least-observed step in the
#  product: it runs on machines we have never seen, under package managers,
#  proxies and shells we do not control, and it reports to nobody. The
#  backend#736 failures — the CLI landing in ~/.local/bin with PATH advice only
#  printed, apt-get appearing hung because unattended-upgrades held the dpkg
#  lock — were each invisible until a customer happened to mention one.
#
#  "NO ARGUMENTS, NO PATHS, NO DATA" IS A SHAPE HERE, NOT A RULE. Every value
#  that reaches the record goes through _telemetry_attr, which admits a string
#  only if it matches ^[A-Za-z0-9._-]{1,64}$ and an integer only if it is one.
#  A filesystem path contains '/', a proxy credential contains ':' and '@', a
#  token is longer than 64 characters, a person's name contains a space — none
#  of them can pass, on ANY input, whether or not anyone anticipated it. Values
#  that fail are DROPPED, never trimmed or escaped: a redactor has to imagine
#  what it is stripping; a shape only admits what it was told to.
#
#  WHAT IS NOT HERE. The transport. The 17 Aug decision (rfcs#28) replaced the
#  Collector gateway with an ingest endpoint on the backend — tracebloc/backend#1905,
#  which does not exist yet. _telemetry_deliver therefore writes the event to
#  the install log and to a bounded local spool, and posts nothing. See the
#  comment on that function for the one thing #1905 changes.
#
#  Opt-out (on by default): TRACEBLOC_NO_TELEMETRY=1 or DO_NOT_TRACK=1.
# =============================================================================

# ── Identity (contract §10.1) ────────────────────────────────────────────────
# Constants, never derived from $0 or a hostname — deriving service identity
# from the process is the defect the contract exists to close (§2).
TB_TELEMETRY_SERVICE="installer"
TB_TELEMETRY_COMPONENT="install"

# ── Phase vocabulary ─────────────────────────────────────────────────────────
# The letters are install-k8s.sh's own `step_header a..f` labels; the names are
# what a dashboard shows. step_header calls telemetry_phase_begin, so this map
# is keyed on the thing that actually runs the steps rather than on a parallel
# list somebody has to remember to extend — and
# scripts/tests/telemetry-vocabulary-agreement.sh parses install-k8s.sh to prove
# the two sets are identical.
#
# `bootstrap` is the phase before step a: download + verify + the leftover-data
# guard. It has no letter because nothing in the a–f run-through covers it, and
# a run that dies there must not be filed under `preflight`.
TB_TELEMETRY_PHASES="a:preflight b:prerequisites c:cluster d:register e:helm f:connect"
TB_TELEMETRY_PHASE="bootstrap"

# ── Client-state vocabulary ──────────────────────────────────────────────────
# summary.sh's wait_for_client_ready + _diagnose_not_ready are the only writers
# of CLIENT_STATE. The agreement test derives THAT set from summary.sh and
# compares; anything not in this list is reported as `unknown` rather than
# passed through, because CLIENT_STATE is a shell variable and a shell variable
# is not a closed set until something closes it.
TB_TELEMETRY_CLIENT_STATES="connected starting bad_creds image_pull image_pull_ca crash"

# ── error.type vocabulary for the `install` domain (§8.4) ────────────────────
# The spec's open question 1 says each emitter ticket proposes its own. This one
# is a function of (phase reached, client state) — both closed sets — so it is
# incapable of carrying anything else. Ordered most-specific first: a readiness
# diagnosis names the actual fault, where a phase only names where it stopped.
TB_TELEMETRY_ERROR_CLASSES="bad_credentials image_pull_failed image_pull_untrusted_ca crash_loop not_ready bootstrap_failed preflight_failed prerequisites_failed cluster_create_failed registration_failed helm_install_failed unclassified"

# ── Source-file vocabulary ───────────────────────────────────────────────────
# The installer already records WHERE it died (common.sh's _record_err), and
# "died in setup-linux.sh at line 412" is the difference between an actionable
# failure and an unclassified one. The full TB_ERR_LOC is a PATH, though —
# under curl|bash it is a temp directory, which on macOS sits under
# /var/folders/<hash> — so only the basename is emitted, and only if it is one
# of the installer's own scripts. That set is gen-manifest.sh's FILES array plus
# the bootstrap; the agreement test derives it from there.
TB_TELEMETRY_SOURCES="install.sh install-k8s.sh common.sh preflight.sh detect-gpu.sh gpu-nvidia.sh gpu-amd.sh setup-macos.sh setup-linux.sh cluster.sh gpu-plugins.sh install-client-helm.sh install-cli.sh provision.sh assess.sh probe.sh summary.sh diagnose.sh telemetry.sh"

# ── The value shapes ─────────────────────────────────────────────────────────
# This is the privacy boundary. Nothing else in this file is allowed to write to
# the record.
TB_TELEMETRY_TOKEN_RE='^[A-Za-z0-9._-]{1,64}$'
TB_TELEMETRY_INT_RE='^-?[0-9]{1,15}$'
TB_TELEMETRY_KEY_RE='^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'

# service.version gets a TIGHTER shape than the generic token, and it is the
# bootstrap's own: install.sh refuses to fetch from anything that is not an
# immutable vX.Y.Z release tag, so a TB_VERSION that does not match that never
# came from a release. The generic token shape was not enough on its own —
# `v1.9.3-<64 arbitrary chars>` satisfies it, which makes the version column a
# 64-byte free-text channel. telemetry-vocabulary-agreement.sh compares this
# regex to install.sh's, so the two cannot drift apart.
TB_TELEMETRY_VERSION_RE='^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$'

# How many events the local spool keeps. Bounded because it is a file on a
# customer's machine that nothing drains until #1905's forwarder exists.
TB_TELEMETRY_SPOOL_MAX="${TB_TELEMETRY_SPOOL_MAX:-50}"

# ── Clock ────────────────────────────────────────────────────────────────────
# Second resolution, multiplied up. BSD date (macOS, which is half the install
# base) has no %N, and adding a dependency to read a millisecond would be a poor
# trade for a signal whose interesting values are minutes: the dpkg-lock case
# this exists to surface is a phase taking twenty of them.
_telemetry_now_ms() { echo $(( $(date +%s) * 1000 )); }

TB_TELEMETRY_STARTED_MS="$(_telemetry_now_ms)"
_TB_TELEMETRY_PHASE_STARTED_MS="$TB_TELEMETRY_STARTED_MS"
_TB_TELEMETRY_EMITTED=""

# ── "an install actually ran" latch ──────────────────────────────────────────
# install_cleanup is the EXIT trap, so it fires for EVERY exit of install-k8s.sh
# — including the terminal, non-install commands. `--help` exits 0 without
# touching the machine, and it was emitting a full install.run.succeeded: a free
# success in the denominator of the exact failure RATE this whole ticket exists
# to produce, and the one people run most while a real install is broken.
# (Bugbot on client#747; reproduced — `install-k8s.sh --help` spooled an
# install.run.succeeded with phase `bootstrap`.)
#
# A latch rather than a phase test, because a genuine failure in the bootstrap
# phase — the leftover-data guard, validate_config — IS an install attempt and
# must still be reported. main() sets this once the terminal commands have had
# their chance to dispatch and the run is committed to installing.
_TB_TELEMETRY_RUN_STARTED=""
telemetry_run_started() { _TB_TELEMETRY_RUN_STARTED=1; return 0; }

# ── "ran, but did nothing" ───────────────────────────────────────────────────
# The stop-and-check gate hands a verifiably healthy machine to the home screen
# and exits 0 without running a single step. That is a real invocation and worth
# counting, but it is not a successful INSTALL: folding it into succeeded would
# make the success count grow with re-runs on machines nothing happened to.
# `skipped` is a registered outcome verb (contract §6.4), so it needs no new
# vocabulary — and "how often do people re-run an installer that was already
# done" is a question worth being able to ask.
_TB_TELEMETRY_SKIPPED=""
telemetry_run_skipped() { _TB_TELEMETRY_SKIPPED=1; return 0; }

# ── Opt-out ──────────────────────────────────────────────────────────────────
# Opt-OUT by design: telemetry only the already-convinced enable measures the
# wrong population, and the population this exists for is people whose install
# just failed. Anything other than the explicit "off" spellings counts as opting
# out — a user who typed TRACEBLOC_NO_TELEMETRY=please meant it, and guessing
# wrong in the other direction sends a record they declined.
TB_TELEMETRY_OPT_OUT_VARS="TRACEBLOC_NO_TELEMETRY DO_NOT_TRACK"
telemetry_enabled() {
  local name value
  for name in $TB_TELEMETRY_OPT_OUT_VARS; do
    eval "value=\${$name:-}"
    case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
      ''|0|false) continue ;;
      *)          return 1 ;;
    esac
  done
  return 0
}

# ── Phases ───────────────────────────────────────────────────────────────────

# telemetry_phase_name LETTER — the registered name, or empty for an unknown
# letter. Fail closed: a step_header letter this map has never seen must not
# invent a phase name.
telemetry_phase_name() {
  local pair
  for pair in $TB_TELEMETRY_PHASES; do
    [ "${pair%%:*}" = "$1" ] && { printf '%s' "${pair#*:}"; return 0; }
  done
  return 1
}

# _telemetry_phase_names — every legal value of TB_TELEMETRY_PHASE: the six
# registered names plus the two that have no step letter. Derived from
# TB_TELEMETRY_PHASES so a phase added there needs no second edit.
_telemetry_phase_names() {
  local pair out="bootstrap unknown"
  for pair in $TB_TELEMETRY_PHASES; do out="$out ${pair#*:}"; done
  printf '%s' "$out"
}

# telemetry_phase_begin LETTER — close the running phase's timer, open the next.
# Called from step_header (common.sh), so the timings come from the code that
# actually prints the steps. Always returns 0: a timing bookkeeping error must
# never be able to end an install.
telemetry_phase_begin() {
  local name now elapsed
  now="$(_telemetry_now_ms)"
  elapsed=$(( now - _TB_TELEMETRY_PHASE_STARTED_MS ))
  # An `if` block, not `[ … ] && elapsed=0`. common.sh's _record_err records why:
  # a bare AND-list whose test is FALSE returns 1, and as the last statement of a
  # function that becomes the function's status — which under the installer's
  # `set -e` is fatal at the call site. Clock-step clamps are exactly the lines
  # where the test is normally false.
  if [ "$elapsed" -lt 0 ]; then elapsed=0; fi
  # Accumulate against the phase that is ENDING. Dynamic variable names are safe
  # here precisely because the name came out of the closed map above.
  printf -v "_TB_TELEMETRY_MS_${TB_TELEMETRY_PHASE}" '%s' "$elapsed" 2>/dev/null || true

  if name="$(telemetry_phase_name "$1")"; then
    TB_TELEMETRY_PHASE="$name"
  else
    TB_TELEMETRY_PHASE="unknown"
  fi
  _TB_TELEMETRY_PHASE_STARTED_MS="$now"
  return 0
}

# _telemetry_phase_ms NAME ACTIVE NOW — milliseconds against a phase.
#
# telemetry_phase_begin only closes a phase when the NEXT one starts, so the
# phase that is still running when the event is emitted has nothing recorded
# against it. That lost the most important number in the file:
#
#   * on every SUCCESSFUL install, phase_connect_ms — the readiness wait, up to
#     READY_TIMEOUT (600s), the single longest phase;
#   * on every failure and every cancel, the duration of the phase named by
#     tracebloc.install.phase — i.e. exactly the dpkg-lock shape this feature
#     exists to surface, in its most likely real form: stuck twenty minutes in
#     `prerequisites` and then killed or given up on.
#
# The remainder trick cannot recover it either, because bootstrap had no key at
# all. Found by Bugbot on client#747; reproduced before fixing.
#
# The live delta is ADDED here rather than written by a "close the phase" call in
# the emit path, so render stays idempotent — the tests call it repeatedly, and a
# render that mutated the accumulators would report different numbers each time.
_telemetry_phase_ms() {
  local name="$1" active="${2:-}" now="${3:-0}" v live
  eval "v=\${_TB_TELEMETRY_MS_${name}:-}"
  if [ "$name" = "$active" ]; then
    live=$(( now - _TB_TELEMETRY_PHASE_STARTED_MS ))
    if [ "$live" -lt 0 ]; then live=0; fi
    v=$(( ${v:-0} + live ))
  fi
  printf '%s' "$v"
}

# ── Classification ───────────────────────────────────────────────────────────

# telemetry_error_class EXIT_CODE PHASE CLIENT_STATE — the closed error.type.
#
# Both inputs are closed sets, so this cannot see — and therefore cannot
# forward — an error message, a path or an argument. A readiness diagnosis wins
# over the phase because it names the actual fault rather than the place the run
# stopped.
# The exit code is accepted but deliberately unread: the installer's status is
# already its own attribute, and folding it in here would give two attributes
# one meaning. It stays in the signature so a future classification that DOES
# need it is a body change, not a call-site change.
# shellcheck disable=SC2034
telemetry_error_class() {
  local code="$1" phase="$2" state="$3"
  case "$state" in
    bad_creds)     printf 'bad_credentials';        return 0 ;;
    image_pull)    printf 'image_pull_failed';      return 0 ;;
    image_pull_ca) printf 'image_pull_untrusted_ca'; return 0 ;;
    crash)         printf 'crash_loop';             return 0 ;;
    starting)      printf 'not_ready';              return 0 ;;
  esac
  case "$phase" in
    bootstrap)     printf 'bootstrap_failed' ;;
    preflight)     printf 'preflight_failed' ;;
    prerequisites) printf 'prerequisites_failed' ;;
    cluster)       printf 'cluster_create_failed' ;;
    register)      printf 'registration_failed' ;;
    helm)          printf 'helm_install_failed' ;;
    connect)       printf 'not_ready' ;;
    # Fail closed. A phase this function has not been taught is a countable
    # "we cannot name it", never the phase string rendered into a new value
    # that appears in the data on its own.
    *)             printf 'unclassified' ;;
  esac
  return 0
}

# telemetry_environment — deployment.environment, or empty for "do not export".
#
# tb_client_env is the installer's own alias reduction (backend#1745); calling it
# rather than re-deciding what `staging` means is what keeps this from becoming
# a fifth declaration of that vocabulary. An unrecognised value is NOT repaired
# and NOT guessed: §3.2 says a record filed under a value no query filters on is
# worse than no record, so the run reports nothing at all.
telemetry_environment() {
  local env
  if declare -F tb_client_env >/dev/null 2>&1; then
    env="$(tb_client_env "${CLIENT_ENV:-prod}")"
  else
    env="${CLIENT_ENV:-prod}"
  fi
  case "$env" in
    dev|stg|prod) printf '%s' "$env" ;;
    *)            return 1 ;;
  esac
}

# ── The record ───────────────────────────────────────────────────────────────

_TB_TELEMETRY_BUF=""

_telemetry_reset() { _TB_TELEMETRY_BUF=""; }

# _telemetry_attr KEY VALUE KIND — the single writer, and the whole privacy
# boundary. KIND is `str` or `int`.
#
# Every shape test reads its subject through a HERE-STRING, never a pipe.
# `grep -q` closes the pipe at its first hit, so a `printf ... | grep -q` under
# the installer's `set -o pipefail` returns 141 (SIGPIPE) on a MATCH — turning a
# successful validation into a fatal error that killed the whole run from inside
# the EXIT trap. Same defect, same fix as summary.sh's _diagnose_not_ready
# (backend#1778). The bats test that drives install_cleanup for real is what
# caught it; every unit-level test of these functions passed throughout.
#
# Refuses and DROPS, in this order: a malformed key, an empty value, a value
# that is not the shape KIND promises. It never trims, escapes or truncates —
# a value that had to be repaired to be safe is a value we did not understand,
# and shipping our guess about it is how a redactor leaks.
_telemetry_attr() {
  local key="$1" value="$2" kind="${3:-str}"
  grep -qE "$TB_TELEMETRY_KEY_RE" <<<"$key" || return 0
  [ -n "$value" ] || return 0
  case "$kind" in
    int)
      grep -qE "$TB_TELEMETRY_INT_RE" <<<"$value" || return 0
      _TB_TELEMETRY_BUF="${_TB_TELEMETRY_BUF:+${_TB_TELEMETRY_BUF},}\"${key}\":${value}"
      ;;
    *)
      grep -qE "$TB_TELEMETRY_TOKEN_RE" <<<"$value" || return 0
      _TB_TELEMETRY_BUF="${_TB_TELEMETRY_BUF:+${_TB_TELEMETRY_BUF},}\"${key}\":\"${value}\""
      ;;
  esac
  return 0
}

# _telemetry_in_set VALUE SET — membership, the only way a shell variable
# becomes a closed vocabulary.
_telemetry_in_set() {
  local needle="$1" set="$2" item
  # Word-splitting $set is the point: these vocabularies are space-separated
  # lists, and bash 3.2 (the system bash on macOS) has no associative arrays.
  # shellcheck disable=SC2086
  for item in $set; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# _telemetry_source_basename LOC — the script name out of a "file:line"
# location, if it is one of the installer's own. Everything else, including the
# directory the path came from, is discarded.
_telemetry_source_basename() {
  local base="${1%%:*}"
  base="${base##*/}"
  _telemetry_in_set "$base" "$TB_TELEMETRY_SOURCES" || return 1
  printf '%s' "$base"
}

# _telemetry_source_line LOC — the line number, if the location has one.
_telemetry_source_line() {
  local line="${1##*:}"
  grep -qE '^[0-9]{1,7}$' <<<"$line" || return 1
  printf '%s' "$line"
}

# telemetry_render_event EXIT_CODE — echo one contract-shaped JSON object.
#
# Pure: reads the installer's state, writes nothing, touches no file. That is
# what lets the tests assert on the real payload instead of on a re-implementation
# of it. Returns 1 without printing when the environment is unrecognised (§3.2).
telemetry_render_event() {
  local code="${1:-0}" env event state phase phase_ms name now total class
  env="$(telemetry_environment)" || return 1

  # §6.1 — three segments, a registered domain, a registered outcome verb. The
  # name is assembled from literals only; no runtime value appears in it.
  case "$code" in
    0)       if [ -n "$_TB_TELEMETRY_SKIPPED" ]; then
               event="install.run.skipped"
             else
               event="install.run.succeeded"
             fi ;;
    130|143) event="install.run.cancelled" ;;
    *)       event="install.run.failed" ;;
  esac

  state="${CLIENT_STATE:-}"
  _telemetry_in_set "$state" "$TB_TELEMETRY_CLIENT_STATES" || state=""

  # The phase is checked here as well as at the point it is set. telemetry_phase_begin
  # is its only writer today and already closes the set — but TB_TELEMETRY_PHASE is
  # a shell variable in a script that sources sixteen other files, and "the only
  # writer is careful" is a property that stops being true silently. Checked at the
  # boundary it cannot: a canary assigned straight to TB_TELEMETRY_PHASE reached the
  # record while this line was missing, and it is shaped exactly like a legal value,
  # so the token regex waved it through.
  phase="$TB_TELEMETRY_PHASE"
  _telemetry_in_set "$phase" "$(_telemetry_phase_names)" || phase="unknown"

  _telemetry_reset
  _telemetry_attr "event.name" "$event"
  _telemetry_attr "tracebloc.install.phase" "$phase"
  _telemetry_attr "tracebloc.install.exit_code" "$code" int
  # ONE clock read for the whole event: the per-phase numbers and the total are
  # then exactly consistent, which is an invariant a test can assert (and does).
  now="$(_telemetry_now_ms)"
  total=$(( now - TB_TELEMETRY_STARTED_MS ))
  if [ "$total" -lt 0 ]; then total=0; fi
  _telemetry_attr "tracebloc.install.duration_ms" "$total" int
  _telemetry_attr "tracebloc.install.client_state" "$state"

  # The #736 PATH case, as a number. install-cli.sh already computes this — it
  # asks whether a FRESH login shell resolves `tracebloc` — and until now only
  # ever printed advice about it. 1/0 rather than true/false so it sums.
  case "${TB_CLI_ON_FRESH_PATH:-}" in
    0|1) _telemetry_attr "tracebloc.install.cli_on_path" "${TB_CLI_ON_FRESH_PATH}" int ;;
  esac

  # Per-phase durations: a fixed, finite set of keys, one per phase name.
  # This is what makes a step that took twenty minutes visible on a run that
  # otherwise succeeded — the shape of the dpkg-lock failure, which never
  # produces a non-zero exit at all.
  #
  # Iterating _telemetry_phase_names, NOT the letter map: `bootstrap` has no step
  # letter, so the letter map skipped it and the download + verify + leftover
  # guard + assess time was unattributable — it silently became the remainder
  # nobody could name. A phase never entered still has no key (§1.2 omits an
  # absent value); a phase that ran always has one, including 0.
  for name in $(_telemetry_phase_names); do
    phase_ms="$(_telemetry_phase_ms "$name" "$phase" "$now")"
    _telemetry_attr "tracebloc.install.phase_${name}_ms" "$phase_ms" int
  done

  if [ "$event" = "install.run.failed" ]; then
    # §8.4 — a failure MUST carry error.type, or it cannot be grouped. The
    # classifier's answer is checked against the declared vocabulary before it
    # is written, so a future branch that returns something unregistered lands
    # as a countable `unclassified` rather than opening a namespace of its own.
    # (The declaration is not proved correct by this check — the agreement test
    # calls telemetry_error_class over every phase x state pair and compares.)
    class="$(telemetry_error_class "$code" "$phase" "$state")"
    _telemetry_in_set "$class" "$TB_TELEMETRY_ERROR_CLASSES" || class="unclassified"
    _telemetry_attr "error.type" "$class"
    # Where the shell died, to the file and line — never the path that reached
    # them. There is deliberately no exception.* set: bash has no stack trace,
    # and TB_ERR_CMD is unexpanded command text, which is free text.
    if [ -n "${TB_ERR_LOC:-}" ]; then
      _telemetry_attr "tracebloc.install.source" "$(_telemetry_source_basename "$TB_ERR_LOC")"
      _telemetry_attr "tracebloc.install.source_line" "$(_telemetry_source_line "$TB_ERR_LOC")" int
    fi
  fi

  printf '{"resource":{'
  printf '"service.name":"%s",' "$TB_TELEMETRY_SERVICE"
  printf '"tracebloc.component":"%s",' "$TB_TELEMETRY_COMPONENT"
  printf '"service.version":"%s",' "$(_telemetry_version)"
  printf '"deployment.environment":"%s",' "$env"
  printf '"os.type":"%s",' "$(_telemetry_os)"
  printf '"host.arch":"%s",' "$(_telemetry_arch)"
  printf '"service.instance.id":"%s"' "$(_telemetry_instance_id)"
  printf '},"attributes":{%s}}' "$_TB_TELEMETRY_BUF"
}

# _telemetry_version — the release tag the bootstrap pinned. §4: unknown is a
# VALUE, not an omission, because 0.0.0-unknown is queryable and alertable while
# an absent key is neither. The tag is shape-checked like everything else: a
# TB_VERSION somebody set to a sentence must not become the version column.
_telemetry_version() {
  local v="${TB_VERSION:-}"
  grep -qE "$TB_TELEMETRY_VERSION_RE" <<<"$v" || v=""
  printf '%s' "${v:-0.0.0-unknown}"
}

# _telemetry_os / _telemetry_arch — OpenTelemetry's own names for these (§1.1
# forbids re-inventing them as tracebloc.os). Reduced to the closed sets OTel
# and Go use, so an exotic `uname` cannot open a new namespace.
_telemetry_os() {
  case "${OS:-$(uname -s 2>/dev/null)}" in
    Darwin) printf 'darwin' ;;
    Linux)  printf 'linux' ;;
    *)      printf 'unknown' ;;
  esac
}
_telemetry_arch() {
  case "${ARCH:-$(uname -m 2>/dev/null)}" in
    arm64|aarch64) printf 'arm64' ;;
    x86_64|amd64)  printf 'amd64' ;;
    *)             printf 'unknown' ;;
  esac
}

# _telemetry_instance_id — §2 asks for a stable per-PROCESS uuid off-cluster.
#
# Not the hostname: field hostnames here are overwhelmingly "<firstname>-macbook",
# and §7.3 forbids a person's name outright. Not persisted either — a durable
# machine id would be an identifier we then have to answer erasure requests
# about. Fresh per run, which is all this field is for off-cluster.
# Computed at SOURCE time, not memoised on first call: every reader here runs
# inside a command substitution, and a variable set in a subshell does not
# survive it — so a lazily-memoised id would silently be a fresh value on every
# read, which is not what "stable per process" means.
#
# Built from bash's own $RANDOM rather than /dev/urandom, and with no pipeline
# at all. `tr -dc … < /dev/urandom | head -c 16` is the obvious spelling and it
# is fatal here: head exits after 16 bytes, tr takes SIGPIPE, and under the
# installer's `set -o pipefail` the command substitution returns 141 — at SOURCE
# time, under `set -e`, which killed the entire installer before it printed a
# line. Four $RANDOM draws need no external process and cannot fail. This is an
# id for telling two concurrent runs apart, not a secret, so 60 bits is ample.
TB_TELEMETRY_INSTANCE_ID="$(printf '%04x%04x%04x%04x' \
  "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM")"
# Never a constant stand-in: that would silently fuse every affected run into
# one.
[ -n "$TB_TELEMETRY_INSTANCE_ID" ] || TB_TELEMETRY_INSTANCE_ID="unknown"

_telemetry_instance_id() { printf '%s' "$TB_TELEMETRY_INSTANCE_ID"; }

# ── Delivery ─────────────────────────────────────────────────────────────────

_telemetry_spool_path() {
  printf '%s/telemetry/pending.jsonl' "${HOST_DATA_DIR:-${HOME}/.tracebloc}"
}

# _telemetry_deliver JSON — THE TRANSPORT SEAM (tracebloc/backend#1905).
#
# Today: the install log, plus a bounded local spool the forwarder (#1906) can
# drain once the ingest endpoint exists. Nothing is posted anywhere, because the
# endpoint the 17 Aug decision (rfcs#28) put this on does not exist yet — and
# building a client against an endpoint whose contract is still being written is
# how you ship two of them.
#
# Everything before this function is finished. This function is the change.
_telemetry_deliver() {
  local json="$1" spool dir
  log "telemetry: $json"

  spool="$(_telemetry_spool_path)"
  dir="${spool%/*}"
  mkdir -p "$dir" 2>/dev/null || return 0
  chmod 700 "$dir" 2>/dev/null || true
  printf '%s\n' "$json" >> "$spool" 2>/dev/null || return 0
  chmod 600 "$spool" 2>/dev/null || true

  # Bounded: nothing drains this until #1906, and an unbounded append on a
  # customer's disk is a defect we would be shipping on purpose.
  if [ -s "$spool" ]; then
    tail -n "$TB_TELEMETRY_SPOOL_MAX" "$spool" > "${spool}.tmp" 2>/dev/null &&
      mv "${spool}.tmp" "$spool" 2>/dev/null || rm -f "${spool}.tmp" 2>/dev/null
  fi
  return 0
}

# telemetry_emit_outcome EXIT_CODE — the one event this install produces.
#
# Called from install_cleanup, the EXIT trap, so it runs on every path including
# the interrupted and the fatal one (§6.5). Emits at most once per process:
# "one structured outcome event per install" is the ticket's wording, and a
# second trap invocation must not be able to make it two.
#
# Always returns 0. An installer that failed because telemetry was unhappy would
# be a strictly worse installer.
telemetry_emit_outcome() {
  local json
  [ -z "$_TB_TELEMETRY_EMITTED" ] || return 0
  _TB_TELEMETRY_EMITTED=1
  # No latch, no event: this trap also fires for `--help`, which installs
  # nothing. See _TB_TELEMETRY_RUN_STARTED above for why a false success is
  # worse here than a missing one.
  [ -n "$_TB_TELEMETRY_RUN_STARTED" ] || return 0
  telemetry_enabled || return 0
  json="$(telemetry_render_event "${1:-0}")" || return 0
  [ -n "$json" ] || return 0
  _telemetry_deliver "$json"
  return 0
}
