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
# `bootstrap` is the phase before step a — and only the part of it that runs in
# THIS process: install-k8s.sh's preamble, validate_config, the leftover-data
# guard, the assess gate. Download and verify are NOT in it. They happen in
# install.sh, which never sources this file and whose EXIT trap is
# `rm -rf "$TMPDIR"`, not install_cleanup — so a fetch, manifest or cosign
# failure emits nothing at all, and `bootstrap` means "install-k8s.sh before
# step a", not "everything before step a". (saadqbal on client#747; verified —
# install.sh's only mention of telemetry.sh is the FILES list it downloads.)
# Extending coverage over the fetch is separate work, not this ticket.
#
# It has no letter because nothing in the a–f run-through covers it, and a run
# that dies there must not be filed under `preflight`.
TB_TELEMETRY_PHASES="a:preflight b:prerequisites c:cluster d:register e:helm f:connect"
TB_TELEMETRY_PHASE="bootstrap"

# ── event.name vocabulary (contract §6.1, §6.4) ──────────────────────────────
# Every name this installer can emit. Three segments; `install` is a registered
# domain (§6.3); the third segment of each is a registered outcome verb (§6.4:
# started succeeded failed skipped rejected retried timed_out expired cancelled
# completed). §6.2 requires the set to be finite and enumerable by grep — this
# is that enumeration, and telemetry_render_event checks its answer against it.
#
# telemetry-vocabulary-agreement.sh derives the emitted names from
# telemetry_render_event's own case statement and from exercising the function
# over the exit codes the installer produces, then compares. It does NOT read
# this list twice: a list checked against itself is self-consistent and blind.
#
# What it cannot check from this repo is the §6.4 half — the verb registry lives
# in rfcs/specs/backend-1872-telemetry-contract.md, which is not checked out
# here, and a hand-copied second list of verbs would be the defect rather than
# the fix. Adding a name here is therefore a review question: is its third
# segment in §6.4?
TB_TELEMETRY_EVENT_NAMES="install.run.succeeded install.run.failed install.run.cancelled install.run.skipped"

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
#
# `install.sh` is in the set for derivation symmetry and is UNREACHABLE today:
# TB_ERR_LOC has exactly one writer, common.sh's _record_err (common.sh:988), and
# common.sh is only ever sourced inside install-k8s.sh's process. Nothing in the
# bootstrap can name itself here. Kept rather than special-cased out, because the
# day the bootstrap does get an emitter the name must already be admissible —
# but do not read its presence as coverage. (saadqbal on client#747.)
TB_TELEMETRY_SOURCES="install.sh install-k8s.sh common.sh preflight.sh detect-gpu.sh gpu-nvidia.sh gpu-amd.sh setup-macos.sh setup-linux.sh cluster.sh gpu-plugins.sh install-client-helm.sh install-cli.sh provision.sh assess.sh probe.sh summary.sh diagnose.sh telemetry.sh"

# ── The value shapes ─────────────────────────────────────────────────────────
# This is the privacy boundary. Nothing else in this file is allowed to write to
# the record.
#
# MATCHED WITH `[[ =~ ]]`, NEVER `grep`. The anchors say whole string; grep says
# whole LINE, and the difference is a hole exactly one input shape wide. A value
# carrying an embedded newline gave grep a first line that matched and the record
# everything after it:
#
#   TB_VERSION=$'v1.9.3\n","tracebloc.install.injected":"yes'
#   → "service.version":"v1.9.3
#     ","tracebloc.install.injected":"yes",…
#
# — a forged attribute AND one record split across two lines of a `.jsonl` spool,
# so #1906's forwarder reads two malformed events. It is the one shape the
# "nowhere for a path to go" argument does not cover, because the value that
# lands is not a path. `[[ $v =~ $RE ]]` anchors at end of STRING (POSIX
# regexec, no REG_NEWLINE), so the same regex now refuses it. Reproduced on all
# four shape checks before fixing; found by saadqbal on client#747.
#
# The RHS must stay UNQUOTED — a quoted RHS is a literal string on bash 3.2+,
# which is the system bash on macOS.
TB_TELEMETRY_TOKEN_RE='^[A-Za-z0-9._-]{1,64}$'
TB_TELEMETRY_INT_RE='^-?[0-9]{1,15}$'
TB_TELEMETRY_KEY_RE='^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'

# service.version gets a TIGHTER shape than the generic token, and it is the
# bootstrap's own: install.sh refuses to fetch from anything that is not an
# immutable vX.Y.Z release tag, so a TB_VERSION that does not match that never
# came from a release. The generic token shape was not enough on its own —
# `v1.9.3-<64 arbitrary chars>` satisfies it, which makes the version column a
# 64-byte free-text channel. telemetry-vocabulary-agreement.sh checks this
# against install.sh's — byte-for-byte AND, since client#747, verdict-for-verdict
# over a corpus, each side evaluated by the operator its own file uses. The byte
# check alone was not enough and said it was: the two regexes were identical
# while install.sh's `[[ =~ ]]` refused an input this file's `grep -qE` admitted.
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
#
# READ THE COUNT NARROWLY. It is NOT "re-runs on a healthy machine": on the
# `curl | bash` path install.sh:132 reaches a healthy machine first and
# `exec tracebloc`s at :144 — before install-k8s.sh has even been fetched — so
# assess.sh's gate never runs and this event is never emitted. What it counts is
# re-runs of `./install-k8s.sh` directly, plus curl|bash runs that reached the
# gate because the bootstrap's own health check did not bail (--force,
# TRACEBLOC_FORCE_REINSTALL, a pinned REF/BRANCH, or no `tracebloc` on PATH).
# (saadqbal on client#747; verified against install.sh's line order.)
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
# Every shape test is a `[[ =~ ]]`, not a grep. Two reasons, and the second one
# is a bug this file already had:
#
#  * `[[ =~ ]]` matches the whole STRING; grep matches a LINE. See the shape
#    declarations above for the newline bypass that cost.
#  * grep is an external process invoked from an EXIT trap. The spelling that
#    was here read its subject through a HERE-STRING rather than a pipe,
#    because `grep -q` closes the pipe at its first hit and a
#    `printf ... | grep -q` under the installer's `set -o pipefail` returns 141
#    (SIGPIPE) on a MATCH — a successful validation turned into a fatal that
#    killed the whole run from inside the trap. Same defect, same fix as
#    summary.sh's _diagnose_not_ready (backend#1778). `[[ =~ ]]` is a shell
#    builtin with no pipe and no child, so that class cannot recur here at all.
#    The bats test that drives install_cleanup for real is what caught it; every
#    unit-level test of these functions passed throughout.
#
# Refuses and DROPS, in this order: a malformed key, an empty value, a value
# that is not the shape KIND promises. It never trims, escapes or truncates —
# a value that had to be repaired to be safe is a value we did not understand,
# and shipping our guess about it is how a redactor leaks.
_telemetry_attr() {
  local key="$1" value="$2" kind="${3:-str}"
  [[ $key =~ $TB_TELEMETRY_KEY_RE ]] || return 0
  [ -n "$value" ] || return 0
  case "$kind" in
    int)
      [[ $value =~ $TB_TELEMETRY_INT_RE ]] || return 0
      _TB_TELEMETRY_BUF="${_TB_TELEMETRY_BUF:+${_TB_TELEMETRY_BUF},}\"${key}\":${value}"
      ;;
    *)
      [[ $value =~ $TB_TELEMETRY_TOKEN_RE ]] || return 0
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
  local line="${1##*:}" re='^[0-9]{1,7}$'
  [[ $line =~ $re ]] || return 1
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
  #
  # EXIT 2 IS NOT A FAILURE. It is the installer's "complete this step and re-run"
  # handoff — install_cleanup has treated it as its own outcome ("Re-run
  # required") since client#681, and its one live producer is gpu-nvidia.sh:55,
  # which exits 2 after install_nvidia_drivers SUCCEEDED, to ask for a reboot.
  # That call sits under step b, so folding it into failed booked every
  # unattended GPU host's first install as `prerequisites_failed` — a fabricated
  # prerequisite failure in the exact rate this ticket exists to produce. Same
  # shape as the `--help` bug, opposite direction. (saadqbal on client#747;
  # reproduced.)
  #
  # It rides `cancelled` rather than a verb of its own because §6.4's outcome
  # verbs are a CLOSED list — started, succeeded, failed, skipped, rejected,
  # retried, timed_out, expired, cancelled, completed — and adding one is a PR
  # against the contract, not a decision an emitter takes unilaterally. Of those,
  # `cancelled` is the only terminal verb that is true here: the run stopped
  # before completing, deliberately, without an error. The two causes stay
  # separable because tracebloc.install.exit_code is already an attribute —
  # exit_code=2 is the re-run handoff, 130/143 the user's own Ctrl-C — which is
  # why the exit code is an attribute rather than something the name carries.
  case "$code" in
    0)       if [ -n "$_TB_TELEMETRY_SKIPPED" ]; then
               event="install.run.skipped"
             else
               event="install.run.succeeded"
             fi ;;
    2|130|143) event="install.run.cancelled" ;;
    *)       event="install.run.failed" ;;
  esac
  # The name is checked against the declared set before it is written, and an
  # unregistered one DROPS the record rather than filing it — same rule as §3.2's
  # unrecognised environment, for the same reason: a record under a name no alert
  # is written against is worse than no record, and it is how a closed namespace
  # fills with rows nobody queries. This cannot fire on today's literals-only
  # case; it is here for the edit that adds a branch, and
  # telemetry-vocabulary-agreement.sh proves declaration and case agree by
  # parsing this function rather than by reading the declaration twice.
  _telemetry_in_set "$event" "$TB_TELEMETRY_EVENT_NAMES" || return 1

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
  [[ $v =~ $TB_TELEMETRY_VERSION_RE ]] || v=""
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
# _telemetry_fallback_dir — a directory whose contents survive this install.
#
# `${TMPDIR:-/tmp}` on its own is NOT that directory on the primary macOS path,
# and getting this wrong silently undid the whole pre-log fix. install.sh:238
# does `TMPDIR="$(mktemp -d)"` and :239 traps `rm -rf "$TMPDIR"` on EXIT. A plain
# assignment to a name that is ALREADY EXPORTED keeps the export attribute — and
# TMPDIR is always exported on macOS (launchd sets a per-user one) and on plenty
# of Linux sessions — so `bash "$TMPDIR/install-k8s.sh"` at :571 inherits the
# bootstrap's scratch dir, this file writes the record into it, and the bootstrap
# deletes it the moment install-k8s.sh returns. The NFS refusal and every other
# pre-setup_log_file failure then produced no record anywhere, which is the exact
# hole the fallback was added to close. (saadqbal on client#747; reproduced
# end-to-end — the spooled file was gone after the bootstrap exited.)
#
# DERIVED, not agreed. The test is "is the running installer inside this
# directory?", which is true precisely when TMPDIR is the bootstrap's own scratch
# dir, because install.sh unpacks install-k8s.sh + lib/ into it and runs it from
# there. Asking install.sh to export its original TMPDIR under another name would
# work too and would be wrong here: install.sh is served from a URL the user may
# have curl'd months ago, so a fix that only works when the bootstrap is new is a
# fix that does not work on the machines this feature exists for.
#
# When TMPDIR is disqualified the record goes to $HOME — outside anything the
# bootstrap's trap owns, and NOT into $HOME/.tracebloc, which is HOST_DATA_DIR
# and which telemetry must never create (client#432, and the comment on
# _telemetry_deliver). /tmp is the last resort for a run with no usable HOME.
_TB_TELEMETRY_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd -P)" || _TB_TELEMETRY_SRC_DIR=""
_telemetry_fallback_dir() {
  local tmp="${TMPDIR:-/tmp}" real
  tmp="${tmp%/}"
  [ -n "$tmp" ] || tmp="/tmp"
  # BOTH SIDES PHYSICAL, or the comparison misses the only platform that has the
  # bug. macOS's /var is a symlink to /private/var, so `pwd -P` above resolves the
  # installer's own directory to /private/var/folders/… while $TMPDIR keeps the
  # /var/folders/… spelling it was exported with — compared as written, the
  # prefix test never fires on a Mac. (Caught by re-running the reproduction
  # against the fix rather than by reading it.)
  real="$(cd "$tmp" 2>/dev/null && pwd -P)" || real=""
  # A `case`, not a `[[ == ]]`: the pattern side must be the glob and the subject
  # side must not be re-globbed.
  if [ -n "$_TB_TELEMETRY_SRC_DIR" ] && [ -n "$real" ]; then
    case "${_TB_TELEMETRY_SRC_DIR}/" in
      "${real}"/*) tmp="" ;;
    esac
  fi
  if [ -n "$tmp" ] && [ -d "$tmp" ] && [ -w "$tmp" ]; then printf '%s' "$tmp"; return 0; fi
  if [ -n "${HOME:-}" ] && [ -d "$HOME" ] && [ -w "$HOME" ]; then printf '%s' "$HOME"; return 0; fi
  printf '/tmp'
  return 0
}

# _telemetry_fallback_spool — where an event goes when there is no data dir yet.
#
# mktemp, never a fixed name: /tmp is world-writable on Linux, so a predictable
# path is a symlink target for an append that may be running under sudo. mktemp
# creates with O_EXCL. Trailing X's with no suffix after them: BSD mktemp (macOS)
# requires the X's at the END of the template, exactly as _choose_log_file's own
# fallback does.
_telemetry_fallback_spool() {
  mktemp "$(_telemetry_fallback_dir)/tracebloc-telemetry-XXXXXX" 2>/dev/null || return 1
}

_telemetry_deliver() {
  local json="$1" spool dir
  # The install log gets it WHERE THERE IS ONE. `log` is a no-op until
  # setup_log_file sets LOG_FILE, and setup_log_file runs AFTER validate_config
  # and early_data_dir_guard — deliberately, because #432 refuses a network data
  # dir *before* logging starts.
  #
  # An earlier version of this function claimed the log "always" got the event.
  # It did not, and the consequence was the worst possible one: a run refused for
  # being on NFS is a real, actionable field failure, and it was the single case
  # that produced no record anywhere — invisible to the very failure rate this
  # feature exists to produce. (Found by Bugbot on client#747, which also spotted
  # that this file's own NFS test masked it by setting LOG_FILE=/dev/null.)
  log "telemetry: $json"

  # TELEMETRY MUST NOT CREATE HOST_DATA_DIR. An observer that changes the
  # install's own preconditions is not an observer.
  #
  # This ran from the EXIT trap and did `mkdir -p "$HOST_DATA_DIR/telemetry"`
  # unconditionally — including on the path where early_data_dir_guard had just
  # REFUSED that directory for being on a network filesystem and called `error`.
  # The guard skips an existing dir on purpose ("an EXISTING data dir has no
  # at-risk mkdir here", client#441), so the next run saw the directory this
  # trap had created, returned 0, and installed MySQL onto NFS — the exact
  # corruption client#432 exists to prevent, reintroduced by the telemetry that
  # was only supposed to watch. Found by Bugbot on client#747; reproduced.
  #
  # So: spool INTO the data dir only when it already exists — and when it does
  # not, into a temp file rather than nowhere. #1906's forwarder reads both.
  if [ -n "${HOST_DATA_DIR:-}" ] && [ -d "$HOST_DATA_DIR" ]; then
    spool="$(_telemetry_spool_path)"
    dir="${spool%/*}"
    mkdir -p "$dir" 2>/dev/null || return 0
    chmod 700 "$dir" 2>/dev/null || true
    printf '%s\n' "$json" >> "$spool" 2>/dev/null || return 0
    chmod 600 "$spool" 2>/dev/null || true
    # Bounded: nothing drains this until #1906, and an unbounded append on a
    # customer's disk is a defect we would be shipping on purpose.
    if [ -s "$spool" ]; then
      if tail -n "$TB_TELEMETRY_SPOOL_MAX" "$spool" > "${spool}.tmp" 2>/dev/null; then
        # The trim REPLACES the file, so the mode has to be put on the thing that
        # survives. `> "${spool}.tmp"` creates under the process umask and `mv`
        # keeps the tmp file's mode, so a chmod that ran only before this landed
        # a 0644 spool: common.sh's `umask 077` normally covers it, but
        # _install_userspace_tools (setup-linux.sh:893) and its macOS twin
        # (setup-macos.sh:418) set `umask 022` around install_{kubectl,k3d,helm}
        # and restore it only afterwards — so an install that dies in one of
        # those emits from the EXIT trap under 022. Nothing sensitive is in the
        # record by construction, so this is defence in depth; it is here because
        # a file this installer creates should not depend on which line it died
        # on for its mode. (saadqbal on client#747; reproduced — spool 644.)
        # BEFORE the mv, not after it: a chmod on the spool afterwards would
        # leave a window in which the file is world-readable, and — the thing
        # that matters more — a second chmod on the spool is unreachable belt and
        # braces that no test can redden, which is how a guard nobody has watched
        # fail gets shipped. One chmod, on the inode that survives.
        chmod 600 "${spool}.tmp" 2>/dev/null || true
        mv "${spool}.tmp" "$spool" 2>/dev/null || rm -f "${spool}.tmp" 2>/dev/null || true
      else
        rm -f "${spool}.tmp" 2>/dev/null || true
      fi
    fi
    return 0
  fi

  # No data dir: the pre-log failures — validate_config, early_data_dir_guard —
  # which are exactly the ones the run-started latch was built to preserve. One
  # file per run, which is the same footprint _choose_log_file already leaves on
  # this path; no trimming, because there is only ever one line in it.
  spool="$(_telemetry_fallback_spool)" || return 0
  printf '%s\n' "$json" >> "$spool" 2>/dev/null || return 0
  chmod 600 "$spool" 2>/dev/null || true
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
