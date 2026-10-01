#!/usr/bin/env bash
# =============================================================================
#  common.sh — Shared colours, logging helpers, configuration defaults,
#              retry logic, and log-file setup
# =============================================================================

# ── Security hardening ───────────────────────────────────────────────────────
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
umask 077

# Minimum TLS version, as a bare flag. Retained for backward compatibility only
# (an out-of-tree caller may still splice it in by hand); everything in this repo
# goes through curl_secure() below, which names the flag itself rather than
# reading this — so growing this constant can never silently reshape every fetch
# in the installer. It must stay a SINGLE flag regardless: two call sites
# historically quoted it ("$CURL_SECURE"), and a space-separated value collapses
# into one argv element that curl rejects.
readonly CURL_SECURE="--tlsv1.2"

# tb_client_env — TRACEBLOC_ENV/CLIENT_ENV reduced to the canonical dev|stg|prod.
#
# The chart, client-runtime and this installer all key on dev|stg|prod, while
# values.schema.json documents development|staging|production as accepted
# aliases. Every consumer must reduce through here rather than matching the raw
# value, for the reason backend#1723 and backend#1745 both record: a `case`
# that knows only dev|stg with a `*)` catch-all sends a documented alias to the
# PROD branch silently.
#
# That is not hypothetical here. `_backend_url` feeds verify_credentials(),
# so a `CLIENT_ENV=staging` install validated the customer's STAGING client
# credentials against the PRODUCTION backend and told them their correct
# credentials were wrong.
#
# RFC-0076 settings-naming (S3): TRACEBLOC_ENV is the canonical shell var,
# CLIENT_ENV the legacy one (remove_by 2026-12-31), same alias-first
# precedence as the chart's tracebloc.clientEnv -- a non-empty TRACEBLOC_ENV
# wins, else CLIENT_ENV, else absent. This is only the AMBIENT-ENV fallback:
# an explicit $1 (even "") still wins outright, so a caller that has already
# resolved its own value (e.g. from a values-file read) is unaffected.
#
# Unknown values pass through unchanged: this normalises spellings, it does not
# validate. Each caller keeps its own fallback for genuinely unrecognised input.
tb_client_env() {
  local raw
  if [ "$#" -ge 1 ]; then
    raw="$1"
  else
    raw="${TRACEBLOC_ENV:-${CLIENT_ENV:-}}"
  fi
  case "$raw" in
    development) printf 'dev'  ;;
    staging)     printf 'stg'  ;;
    production)  printf 'prod' ;;
    *)           printf '%s' "$raw" ;;
  esac
}

# The DASHBOARD for this environment — where a human goes to create a client,
# read their credentials, or see whether it came online (backend#2849).
#
# THE BASH TWIN OF Get-TraceblocDashboardUrl. The PowerShell side was fixed
# first; Bugbot caught that this half still hardcoded production at ten sites
# while `_backend_url` was correctly env-aware — so a `CLIENT_ENV=dev` install on
# Linux or macOS still sent the operator to ai.tracebloc.io for credentials
# `dev-api` then rejects. Same defect, other half of the contract.
#
# IT LIVES HERE, NOT IN install-client-helm.sh, and that placement is the whole
# point (@LukasWodka on client#946). It was defined in install-client-helm.sh and
# CALLED from summary.sh — sibling libraries where neither sources the other — so
# summary.sh silently depended on a load order nothing enforced. Standalone (which
# is exactly what summary.bats does) the four call sites rendered an EMPTY link:
# `See it on your dashboard:` followed by nothing. That is WORSE than the bug
# being fixed, because a wrong link a reader can recover from and a missing one
# they cannot. common.sh is sourced first by install-k8s.sh AND by the bats
# load_lib, and it already holds `tb_client_env` — which this calls — so both
# twins get it by construction rather than by accident.
#
# The hosts are the backend's OWN per-environment settings, not a guess:
# DEVICE_VERIFICATION_URI / RESET_PASSWORD_URL in
# xraybackend/settings/{dev,stg,prod}.py resolve to dev.tracebloc.io,
# stg.tracebloc.io and ai.tracebloc.io. Same `tb_client_env` alias reduction and
# the same unknown->prod fallback as `_backend_url`, so the two can never
# disagree about which environment an install belongs to.
#
#   $1 = path under the dashboard (default "clients"; pass "" for the bare host)
_dashboard_url() {
  local path="${1-clients}" base
  # Bare call, no explicit fallback: tb_client_env's own ambient-env path
  # already reads TRACEBLOC_ENV alias-first, and an unset/unrecognised result
  # lands in the *) branch below the same way an explicit "prod" would --
  # spelling out "${TRACEBLOC_ENV:-${CLIENT_ENV:-prod}}" here would just
  # re-derive what tb_client_env already does internally.
  case "$(tb_client_env)" in
    dev) base='https://dev.tracebloc.io' ;;
    stg) base='https://stg.tracebloc.io' ;;
    *)   base='https://ai.tracebloc.io' ;;
  esac
  if [[ -n "$path" ]]; then printf '%s/%s' "$base" "$path"; else printf '%s' "$base"; fi
}

# curl_secure — the one way this installer fetches anything.
#
# The TLS floor used to be opt-in: every call site had to remember to splice
# $CURL_SECURE in, and seven of them had silently lost it — including the POST
# that carries the client's password (backend#1252). A wrapper makes the floor
# structural instead of remembered: a new call site gets it whether or not its
# author knew it existed.
#
# It is not redundant with modern curl defaults. These installs run on
# customer-managed hosts, older distros, and behind TLS-inspecting corporate
# proxies, which negotiate down to whatever the client will accept — which is
# exactly why this repo adopted an explicit floor instead of trusting defaults.
#
# It also supplies default time bounds so an unbounded fetch cannot hang the
# install. Both defaults are injected BEFORE "$@", so a call site that passes its
# own --connect-timeout/--max-time still wins (curl honours the LAST occurrence).
# The one thing the wrapper must not do is impose a deadline where a call site
# deliberately has none: a large binary download bounds itself with stall
# detection (--speed-limit/--speed-time) because a hard --max-time would kill a
# slow-but-healthy link, so those calls keep exactly the behaviour they had.
#
# Plain `curl`, not `command curl`: the bats suite mocks transfers by defining a
# curl shell function, and `command` would bypass the mock and dial the network.
curl_secure() {
  local _arg _stall_bounded=0
  for _arg in "$@"; do
    case "$_arg" in --speed-limit|--speed-time) _stall_bounded=1; break ;; esac
  done
  local -a _bounds=(--connect-timeout "${TB_CURL_CONNECT_TIMEOUT:-30}")
  (( _stall_bounded )) || _bounds+=(--max-time "${TB_CURL_MAX_TIME:-300}")
  # checker false positive: _bounds ALWAYS carries --connect-timeout (plus
  # --max-time unless the call stall-bounds itself) — flags inside a bash
  # array expansion are invisible to the grep. house-rules: ignore=curl-timeout
  curl --tlsv1.2 "${_bounds[@]}" "$@"  # set-u-safe: always carries --connect-timeout
}

# Verify FILE against an EXPECTED sha256, portably and FAIL-CLOSED. Linux ships
# sha256sum (coreutils); macOS ships NO sha256sum but has shasum -a 256 — so the
# same pinned-download verification works on both (#429). We feed "<hash>  <file>"
# to `--check` (exit-code only) rather than recomputing and string-comparing, so
# the bats fetch mocks that stub `sha256sum` keep working unchanged. `command -v`
# (not has()) picks the tool: has() is mocked per-test on PRESENT_CMDS, but the
# checksum tool is a RUNTIME detail, and the tests provide it as a shell function
# that command -v resolves. An EMPTY expected hash fails closed here too.
_verify_sha256() {
  local expected="$1" file="$2"
  [[ -n "$expected" ]] || return 2
  # Tool choice: Linux ships GNU sha256sum (coreutils, on even minimal cloud images).
  # macOS ALSO ships a /sbin/sha256sum (Darwin 1.0). On macOS 26 it accepts --check
  # --status, but only with a file operand: fed on stdin with none, as below, it
  # prints its usage and exits 1 (measured on 26.6.2, client-dev#1356), so on real
  # macOS prefer `shasum -a 256`. The `type -t` guard keeps this from disturbing
  # the bats fetch tests, which run on macOS dev boxes and provide sha256sum as a
  # shell FUNCTION (a mock): a function means we're under test, so honor it rather
  # than the Darwin fallback. GNU sha256sum and shasum both read "<hash>  <file>"
  # on stdin and report via exit code with --check --status, which is exactly what
  # those mocks stub.
  local tool=""
  if [[ "$OS" == "Darwin" && "$(type -t sha256sum)" != function ]]; then
    command -v shasum >/dev/null 2>&1 && tool=shasum
  elif command -v sha256sum >/dev/null 2>&1; then
    tool=sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    tool=shasum
  fi
  case "$tool" in
    sha256sum) printf '%s  %s\n' "$expected" "$file" | sha256sum --check --status 2>/dev/null ;;
    shasum)    printf '%s  %s\n' "$expected" "$file" | shasum -a 256 --check --status 2>/dev/null ;;
    *)         return 2 ;;
  esac
}

# Fail-fast when a just-downloaded FILE is shorter than a real tool binary can be
# (#607). On a filtered network a proxy or antivirus can return a truncated stream
# or a small error page under HTTP 200 — `curl -f` can't see it (it's not an HTTP
# error), and the only downstream signal was _verify_sha256, which misreports a
# blocked TRANSFER as "checksum verification failed" (tampering). Catching the short
# payload here gives the user the real, actionable reason. `wc -c` is the portable
# size read (GNU `stat -c%s` vs BSD `stat -f%z` differ). FAIL-CLOSED: a missing or
# unreadable file reads as 0 bytes and fails.
_assert_download_size() {
  # TB_MIN_DOWNLOAD_BYTES overrides the floor (set to 0 by the bats fetch tests,
  # whose curl mocks write tiny fixture files); unset in production, so the real
  # per-tool floor passed as $2 applies. $4 (optional) is the caller's mktemp -d
  # tree to remove before erroring, so a truncated transfer cleans up its partial
  # payload exactly like the checksum-mismatch branches do (Bugbot).
  local file="$1" min="${TB_MIN_DOWNLOAD_BYTES:-$2}" label="$3" cleanup="${4:-}" size=0
  [ -f "$file" ] && size="$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$size" ] || size=0
  if [ "$size" -lt "$min" ]; then
    [ -n "$cleanup" ] && rm -rf "$cleanup"
    error "Download of ${label} was truncated or blocked — got ${size} bytes (expected at least ${min}). On a filtered network a proxy or antivirus may be cutting the transfer; allowlist the download host (github.com / objects.githubusercontent.com / dl.k8s.io / get.helm.sh) or exclude the tools directory from AV scanning, then re-run."
  fi
}

# ── Colours ──────────────────────────────────────────────────────────────────
# One brand-grounded palette (design-system tokens): cyan #01a5cc = structure,
# lime #91e947 = action — mirrors the Go CLI's internal/ui engine. Each tone
# renders as exact 24-bit hex on a truecolor terminal, the nearest ANSI-16
# elsewhere, its deep shade on a light background, and nothing at all when colour
# is off (NO_COLOR / not a TTY / TERM=dumb / TB_PLAIN=1). Meaning never rests on
# hue alone — headings/commands also carry bold and alerts a distinct glyph.
#
# Decided ONCE here, at source time: common.sh is sourced before setup_log_file
# redirects stdout through `tee`, so the `-t 1` test sees the real terminal.
if [[ -n "${NO_COLOR:-}" || "${TB_PLAIN:-}" == "1" || "${TERM:-}" == "dumb" || ! -t 1 ]]; then
  _tb_mode=none
elif [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
  _tb_mode=true
else
  _tb_mode=16
fi
_tb_bg=dark
if [[ -n "${COLORFGBG:-}" ]]; then
  _tb_last="${COLORFGBG##*;}"           # "fg;bg" → a trailing 7/15 is a light bg
  [[ "$_tb_last" == "7" || "$_tb_last" == "15" ]] && _tb_bg=light
fi

# _sgr DARK_RGB LIGHT_RGB ANSI16 BOLD UNDERLINE → the opening escape for a tone
# (empty when colour is off). RGB args are "R;G;B"; emits the literal \033[…m form
# so both `echo -e` and printf format strings interpret it, matching legacy usage.
_sgr() {
  [[ "$_tb_mode" == "none" ]] && return 0
  local codes
  if [[ "$_tb_mode" == "true" ]]; then
    if [[ "$_tb_bg" == "light" ]]; then codes="38;2;$2"; else codes="38;2;$1"; fi
  else
    codes="$3"
  fi
  [[ "$4" == "1" ]] && codes="${codes};1"
  [[ "$5" == "1" ]] && codes="${codes};4"
  printf '\\033[%sm' "$codes"
}

# Semantic tones (the same table as internal/ui/ui.go).
TB_HEADING="$(_sgr '1;165;204'  '1;99;122'   36 1 0)"  # cyan bold — structure/headings
TB_CMD="$(_sgr     '145;233;71' '87;140;43'  32 1 0)"  # lime bold — the thing to run
TB_DESC="$(_sgr    '167;237;108' '87;140;43' 32 0 0)"  # soft lime — supporting text
TB_LINK="$(_sgr    '1;165;204'  '1;99;122'   36 0 1)"  # cyan underline — destinations
TB_ACCENT="$(_sgr  '1;165;204'  '1;99;122'   36 0 0)"  # cyan — prompt guidance
TB_GO="$(_sgr      '145;233;71' '87;140;43'  32 0 0)"  # lime — ✔ / ● (good/go)
TB_WARN="$(_sgr    '255;198;43' '138;106;0'  33 0 0)"  # amber — ⚠
TB_ERR="$(_sgr     '246;76;76'  '192;39;31'  31 1 0)"  # red bold — ✖
TB_ERRSOFT="$(_sgr '246;76;76'  '192;39;31'  31 0 0)"  # red — ✗ offline
TB_LABEL="$(_sgr   '142;142;142' '107;107;107' 2 0 0)" # dim neutral — labels

# Structural (weight only) + reset — also honour the off switch.
if [[ "$_tb_mode" == "none" ]]; then
  BOLD=''; DIM=''; WHITE=''; RESET=''
else
  BOLD='\033[1m'; DIM='\033[2m'; WHITE='\033[1;37m'; RESET='\033[0m'
fi

# Legacy names, kept so untouched call sites still render on-brand AND honour the
# off switch: CYAN → cyan accent, GREEN → go/lime, YELLOW → warn, RED → error.
CYAN="$TB_ACCENT"; GREEN="$TB_GO"; YELLOW="$TB_WARN"; RED="$TB_ERRSOFT"

# ── Logging ──────────────────────────────────────────────────────────────────
#  info()          — supplementary detail shown to user (dim bullet)
#  success()       — completed item (green checkmark)
#  warn()          — non-blocking warning (yellow triangle)
#  error()         — fatal error (bold red cross, exits)
#  step()          — major step header: step <n> <total> "label"
#  log()           — debug only, writes to LOG_FILE, never shown to user
#  prompt_header() — bold label before user input prompts
#  hint()          — dim contextual help text
info()           { echo -e "  ${DIM}·${RESET} $*"; }
success()        { echo -e "  ${TB_GO}✔${RESET} $*"; }
warn()           { echo -e "  ${TB_WARN}⚠${RESET}  $*"; }
# error MESSAGE — print and exit 1.
#
# It records itself first, and that is not decoration. `exit` fires NO ERR trap,
# so a deliberate refusal left TB_ERR_* holding whatever benign probe failed
# last — and install_cleanup then reported that probe as the cause. A real log
# read "Stopped at common.sh:527 — sudo -n true" for an install that died of a
# missing administrator password: line 527 is the passwordless-sudo probe, which
# is SUPPOSED to fail on a normal Mac. The report named a healthy check and sent
# the reader to the wrong place, which is worse than naming nothing.
#
# BASH_SOURCE[1]/BASH_LINENO[0] are the CALLER's file and line — where the
# refusal was decided. BASH_SOURCE[0] would name common.sh every time.
error() {
  if declare -F _record_err >/dev/null 2>&1; then
    _record_err "${BASH_SOURCE[1]:-?}:${BASH_LINENO[0]:-?}" "error: $*" 1
  fi
  echo -e "  ${TB_ERR}✖ $*${RESET}" >&2
  exit 1
}
step()           { echo -e "\n${TB_HEADING}Step $1/$2${RESET}  ${BOLD}$3${RESET}"; }
log()            { [[ -n "${LOG_FILE:-}" ]] && echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE" 2>/dev/null; return 0; }
prompt_header()  { echo -e "\n  ${BOLD}${WHITE}$*${RESET}"; }
hint()           { echo -e "  ${DIM}$*${RESET}"; }

# The "remove the client that is already here" remedy, printed from ONE place
# (backend#2077) — peer of k3d.sh::_recreate_cluster_hint, for the sites that
# mean a FULL removal (switch account, switch Client ID), not a keep-your-data
# recreate.
#
# Why not just `k3d cluster delete`: the backend record is anchored to the
# cluster's identity (the kube-system namespace UID), which dies with the k3d
# cluster. `k3d cluster delete` never calls the API, so the record keeps a
# cluster_id that will never exist again and stays on the dashboard for good.
# `tracebloc delete` revokes it server-side first (an API call, so it works on a
# broken cluster too), then uninstalls, tears down the `tracebloc` cluster and —
# without --keep-data — wipes ~/.tracebloc, which is what these sites promise.
#
# It acts on this machine's active client with the SIGNED-IN account's token, so
# it has to run as the account that owns that client: the switch-account site has
# just signed in as the OTHER one, hence the `tracebloc login` in front. The k3d
# line stays for a custom CLUSTER_NAME (`tracebloc delete` only removes the one
# named `tracebloc`), and the last line covers a machine where `tracebloc delete`
# can't run — it refuses with "no active client" when the pointer is gone.
#
# $1 (optional): the indent to print the command lines at.
_release_client_hint() {
  local in="${1:-}"
  hint "${in}tracebloc login  &&  tracebloc delete   (as the account that owns it: releases it on"
  hint "${in}                                         its dashboard, then wipes it + its local data)"
  hint "${in}k3d cluster delete ${CLUSTER_NAME:-tracebloc}"
  hint "${in}(tracebloc delete refused, or you can't sign in as that account? revoke the client on"
  hint "${in} that account's dashboard first, then just the k3d line.)"
}

# step_header LETTER TITLE — bold running header for one of the six install steps
# (a–f) in the first-run run-through, e.g. `step_header a "Checking your machine"`
# → "  a) Checking your machine". Prints the header + a single trailing blank; the
# blank-line gap BETWEEN steps comes from each step body ending with a blank line
# (main() adds it), matching the run-through's spacing.
#
# It is also where the install's phase clock turns over (backend#1907). Hooking
# THIS rather than adding a telemetry_phase_begin call to each of the six steps
# is the difference between phase timings that are correct by construction and
# phase timings that are correct for the steps somebody remembered — and the
# letters it is keyed on are the ones actually being printed, so nothing can
# drift. Guarded because telemetry.sh may be absent under an older bootstrap
# whose FILES list did not fetch it, and the `|| true` because printing a step
# header must never be able to end an install.
step_header()    {
  if declare -F telemetry_phase_begin >/dev/null 2>&1; then
    telemetry_phase_begin "$1" || true
  fi
  echo -e "  ${TB_HEADING}$1) $2${RESET}"; echo "";
}

# ── Utility ──────────────────────────────────────────────────────────────────
has() { command -v "$1" &>/dev/null; }

# _rootless_active — the single source of truth for "this run is a rootless Tier-1
# install" (RFC 0001 #1177). Slice 1 (#1219) established the condition as
# INSTALL_TIER==1 AND the opt-in TB_TIER1_ROOTLESS flag; every later slice calls
# THIS predicate instead of re-testing the pair, so the two markers can never drift
# (#1221). Lives in common.sh because both setup-linux.sh (the install path) and
# k3d.sh (the cluster path, sourced standalone by the e2e harness) depend on it.
_rootless_active() {
  [ "${INSTALL_TIER:-}" = "1" ] && [ "${TB_TIER1_ROOTLESS:-0}" = "1" ]
}

# Execute-gate a freshly-installed tool (#411). The old post-install "check" was a
# log-only interpolation (`... 2>/dev/null || echo present`) that masked failure,
# so a corrupt or wrong-architecture binary — a partial pkg/brew install, or a
# download no checksum path guarded — sat on PATH and failed only later, at
# cluster-create, after a green "System tools". Actually RUN the tool's cheapest
# self-check; on failure error() with an arch-aware remedy so the tool step fails
# loudly instead. NOTE: kubectl is gated with `version --client` (NOT --short,
# removed in kubectl 1.28+); helm with bare `version` (—short may go the same way).
#
# Removal is OPT-IN via a leading `--rm <path>`: pass it with the path where the
# installer PLACES the binary (TB_TOOLS_DIR/<tool>). On failure we remove that path
# ONLY when the binary that actually ran is that exact file (same inode, `-ef`).
# So: a broken binary WE installed there (fresh OR left by a prior run) is cleared,
# letting a re-run self-heal (Bugbot: otherwise `has` stays true → stuck loop);
# but a brew/pkg-manager copy that lives elsewhere on PATH is never deleted — the
# resolved binary won't match our path (reviewer). Callers may pass --rm on every
# path; the `-ef` guard sorts out ownership. macOS/brew callers pass no --rm.
# Usage: assert_tool_runs [--rm <placed-path>] <name> <version-arg>...
assert_tool_runs() {
  local rm_path=""
  if [[ "${1:-}" == "--rm" ]]; then rm_path="$2"; shift 2; fi
  local name="$1"; shift
  local out
  if out="$("$name" "$@" 2>&1)"; then
    # First line via pure-bash slicing, not `printf … | head -1` (backend#1778).
    # This one sits in ARGUMENT position, where a 141 does NOT trip errexit, so it
    # was never an abort — but the pipeline bought nothing and the shape is the
    # one being retired fleet-wide.
    log "$name OK: ${out%%$'\n'*}"
    return 0
  fi
  # Remove only the file we placed AND only if it's the binary that just failed.
  if [[ -n "$rm_path" && -f "$rm_path" ]]; then
    local resolved; resolved="$(command -v "$name" 2>/dev/null || true)"
    [[ -n "$resolved" && "$resolved" -ef "$rm_path" ]] && rm -f "$rm_path" 2>/dev/null || true
  fi
  error "$name was installed but won't run — a corrupt or wrong-architecture binary (this machine is ${ARCH:-$(uname -m)}). Re-run the installer to re-download it; if it recurs, remove ${rm_path:-the $name on your PATH} (and any package-manager copy) first."
}

# _bounded SECONDS CMD… — run CMD with a deadline, so a wedged external call can't
# hang a headless install (installer rule: every docker/kubectl/helm probe must be
# bounded). Returns CMD's exit status, or 124 when the deadline fired. Output is
# NOT redirected — the caller decides — and stdin reaches CMD.
#
# timeout(1)/gtimeout(1) when either is present: they signal the whole process
# group. Neither ships on a stock Mac, and the bare call this used to fall back to
# was no bound at all there (#741, #832, backend#2521), so without them the deadline
# comes from _tb_bounded_bg, the background-PID mechanism _bounded_capture uses.
_bounded() {
  local t="$1"; shift
  if   has timeout;  then timeout  "$t" "$@"
  elif has gtimeout; then gtimeout "$t" "$@"
  else _tb_bounded_bg "$t" "$@"; fi
}

# _tb_bounded_bg SECONDS CMD… — the deadline with no coreutils: run CMD in the
# background, stdin preserved (`<&0`; a background job in a non-interactive shell
# otherwise reads /dev/null), and poll it. On the deadline: TERM, then KILL, and
# return 124; otherwise CMD's own status. Only CMD itself is signalled, not a
# process group (job control is off in the installer's shell). SECONDS reads as
# timeout(1) reads it: a number with an optional s/m/h/d suffix (a fraction rounds
# UP, so the bound is never shorter than asked), 0 disables the deadline, and
# anything else is timeout(1)'s 125, "the interval is invalid".
#
# The poll tick is 0.1s where `sleep` accepts fractions and 1s otherwise, detected
# once per shell — a 1-second floor would charge a full second for every call that
# answered instantly.
_tb_bounded_bg() {
  local asked="$1" raw="$1" mult=1 secs; shift
  case "$raw" in
    *s) raw="${raw%s}" ;;
    *m) raw="${raw%m}"; mult=60 ;;
    *h) raw="${raw%h}"; mult=3600 ;;
    *d) raw="${raw%d}"; mult=86400 ;;
  esac
  case "$raw" in
    ''|*[!0-9.]*|*.*.*|.*) echo "_bounded: invalid time interval '${asked}'" >&2; return 125 ;;
    *.*) raw=$(( 10#${raw%%.*} + 1 )) ;;
  esac
  secs=$(( 10#$raw * mult ))
  if [ "$secs" -eq 0 ]; then "$@"; return; fi
  # Poll granularity, detected ONCE per shell and cached: a fast call must not cost
  # a whole tick. GNU and BSD/macOS `sleep` both take fractions; a strictly POSIX
  # one does not, so fall back to 1s rather than spin or fail.
  if [ -z "${_TB_CAPTURE_TICK:-}" ]; then
    if sleep 0.1 2>/dev/null; then _TB_CAPTURE_TICK=0.1; _TB_CAPTURE_PER_SEC=10
    else                           _TB_CAPTURE_TICK=1;   _TB_CAPTURE_PER_SEC=1; fi
  fi
  "$@" <&0 &
  # The waiter's OWN stderr is silenced, never CMD's: a job killed on the deadline
  # is reaped asynchronously, and bash then prints "PID Terminated: 15 CMD" at its
  # next command -- inside the loop, outside `wait`'s redirection. Measured on
  # /bin/bash 3.2; it would land on the user's terminal, or in a --diagnose file.
  _tb_bounded_wait "$!" "$secs" 2>/dev/null
}

# _tb_bounded_wait PID SECONDS -- _tb_bounded_bg's deadline loop over a background
# job of this shell: its status, or 124 once SECONDS have passed.
#
# TWO CLOCKS, and the deadline is whichever runs out first. The tick count is never
# early (each tick sleeps at least one tick), but it is not a bound: every tick also
# pays a `kill -0` and a `sleep` fork, and on a loaded macOS runner "1s, then a 2s
# grace" measured 6.6s (client-dev#1514). The wall clock caps it. $SECONDS is whole
# seconds, so a difference of N means MORE than N-1 have passed: the deadline needs
# `> secs` to stay never-shorter-than-asked; the grace is best-effort and takes `>= 2`.
_tb_bounded_wait() {
  local pid="$1" rc=0 waited=0 t0=$SECONDS
  local limit=$(( $2 * _TB_CAPTURE_PER_SEC ))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ] || [ $(( SECONDS - t0 )) -gt "$2" ]; then
      # EVERY LINE FAILURE-PROOFED (`|| true`), exactly as spin's deadline path is
      # and for the reason recorded there (Bugbot #442 r3, and again on
      # client#984): `wait` on a TERM'd child reports 143 and `kill` fails outright
      # on an already-exited pid, so under `set -e` either aborted this arm BEFORE
      # `return 124` and the caller saw a fired deadline as "the command failed
      # with 143". That is the stall/failure conflation every caller keys on.
      # Measured: bash -c 'set -e; source common.sh; _bounded_capture 1 f sleep 30'
      # -> 143 (Not reproducible through `( set -e; … ) || rc=$?` — bash inherits
      # the AND-OR errexit suppression into subshells, which is why the first draft
      # of the guard passed against this bug.)
      kill -TERM "$pid" 2>/dev/null || true
      # ESCALATE IN-LINE, not from a detached subshell that races `wait`: a child
      # ignoring TERM otherwise decides how long the installer waits, and a KILL
      # arriving after `wait` has reaped the child can signal a REUSED pid. While
      # the child is still our own unreaped child its pid cannot be recycled, so
      # escalating here is both bounded and safe.
      local _kwait=0 _klimit=$(( 2 * _TB_CAPTURE_PER_SEC )) _kt0=$SECONDS
      while kill -0 "$pid" 2>/dev/null && [ "$_kwait" -lt "$_klimit" ] && [ $(( SECONDS - _kt0 )) -lt 2 ]; do
        sleep "$_TB_CAPTURE_TICK" || true
        _kwait=$(( _kwait + 1 ))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep "$_TB_CAPTURE_TICK"
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

# _bounded_capture SECONDS OUTFILE CMD… — run CMD with stdout+stderr captured to
# OUTFILE, bounded on EVERY platform. Returns CMD's status, or 124 when the
# deadline fired. THREE OUTCOMES, all distinguishable by the caller: 0 (answered),
# 124 (did not answer in time), anything else (CMD's own failure).
#
# WHY IT EXISTS ALONGSIDE _bounded (client#984). `_bounded` leaves the output where
# the caller put it; this one captures it to a FILE, and uses the background-PID
# deadline (_tb_bounded_bg) on every host, coreutils or not, so a capture behaves
# the same everywhere. `_docker_answers_bounded` bounds a yes/no probe by letting
# `spin` kill it on a deadline, but spin writes UI and discards the command's
# OUTPUT, so it cannot serve a read whose output is the point.
#
# The --diagnose bundle is exactly that case and the one where the cost is the
# whole artifact rather than a stall: every read in it goes into a `{ … } > file`
# group, so ONE call that never returns means no file at all, from the one run
# collected BECAUSE the machine is already broken. A `docker info` gate passing in
# 10s does not make a 15s `k3d cluster list` safe — more engine work, different
# budget (Bugbot High, client#984).
#
# The mechanism is _tb_bounded_bg's: the same background-PID + kill as spin (#426),
# no coreutils, TERM first and then KILL, so a well-behaved child can clean up.
_bounded_capture() {
  local secs="$1" out="$2"; shift 2
  : > "$out" 2>/dev/null || return 2      # cannot capture => "could not tell", not "empty"
  # stdin from /dev/null, as a plain background job had it: a --diagnose read never
  # takes input, and must not sit on the terminal's.
  _tb_bounded_bg "$secs" "$@" >"$out" 2>&1 </dev/null
}

# Deadline for `k3d cluster list` (seconds). Its OWN knob, deliberately LOOSER
# than TB_DOCKER_PROBE_TIMEOUT's 10s, because it is strictly more engine work:
# `docker info` asks the daemon about itself, while `k3d cluster list` enumerates
# AND inspects the cluster's containers. The first cut of client#974 gave it
# TB_PROBE_TIMEOUT's 5s — the tightest bound in the tree on the slowest call, and
# half the budget of the daemon probe that gates it (LukasWodka, client#984).
#
# 15s matches the PowerShell twin's identical read (install-k8s.ps1's
# Get-ClusterListJson job deadline), so the two installers agree on how long this
# question is allowed to take. It also narrows the window the tri-state has to
# resolve: a busy-but-healthy engine that answers in 6s is now PRESENT/ABSENT
# rather than UNKNOWN.
: "${TB_K3D_LIST_TIMEOUT:=15}"

# _bounded_root SECONDS CMD… — like _bounded, but for a command that would
# otherwise be prefixed with `sudo`. `_bounded` execs `timeout`, a BINARY, which
# resolves `sudo` from PATH and so bypasses the root-aware `sudo()` shadow below —
# and as root (the normal `--prepare-host` path, where RFC 0001 often has no sudo
# binary at all) `timeout sudo CMD` then fails to find sudo and the caller misreads
# a live daemon as dead (Bugbot, #744). Mirror the shadow's one rule: root needs no
# sudo; non-root uses the real sudo binary (preflight_sudo has guaranteed it by now).
_bounded_root() {
  local t="$1"; shift
  if [ "$(id -u)" -eq 0 ]; then _bounded "$t" "$@"
  else                          _bounded "$t" sudo "$@"; fi
}

# _docker_answers — `docker info`, bounded and silent. The single probe every
# "is the runtime up?" check should route through.
#
# A bare `docker info` does not return when the daemon is WEDGED, as opposed to
# stopped — and wedged is precisely the state that lands a machine in
# assess's runtime-down branch, since _assess_runtime_down classifies on
# _bounded's 124. So the unbounded probe hangs exactly on the input that
# reaches it: the operator is told Docker is being started and the installer
# freezes with no further output (Bugbot, #741).
#
# TB_DOCKER_PROBE_TIMEOUT defaults to the same 10s as TB_ASSESS_DOCKER_TIMEOUT;
# they answer the same question about the same daemon and should not disagree.
_docker_answers() {
  _bounded "${TB_DOCKER_PROBE_TIMEOUT:-10}" docker info >/dev/null 2>&1
}

# ── Subordinate ID helpers (rootless Docker, RFC 0001 #1220) ──────────────────
# Pure parsers shared by probe.sh (detection) and setup-linux.sh (remediation), so
# both read /etc/subuid + /etc/subgid the same way. Lines are `key:start:count`,
# key = user name OR numeric uid.

# _subid_has_entry FILE NAME UID — true if FILE has a range keyed by NAME or UID.
# First-field (anchored) match, so a name that is a substring of another user's
# entry can't false-positive. FILE is world-readable; the read is side-effect-free.
_subid_has_entry() {
  local file="$1" name="$2" uid="$3" key
  [[ -r "$file" ]] || return 1
  while IFS=: read -r key _ _; do
    [[ -n "$key" ]] || continue
    [[ "$key" == "$name" ]] && return 0
    [[ -n "$uid" && "$key" == "$uid" ]] && return 0
  done < "$file"
  return 1
}

# _next_subid_start FILE... — the next free start offset for a fresh 65536-wide
# block: max(start+count) across the given files, or 100000 (Docker's default base)
# when none carry a valid range. Guarantees the new block can't overlap an existing
# allocation, so remediation is safe to run on a host that already has some ranges.
_next_subid_start() {
  local f start count max=100000
  for f in "$@"; do
    [[ -r "$f" ]] || continue
    while IFS=: read -r _ start count; do
      [[ "$start" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ ]] || continue
      if (( start + count > max )); then max=$(( start + count )); fi
    done < "$f"
  done
  echo "$max"
}

# _idmap_helper_ok NAME — is a subid-mapping helper (newuidmap/newgidmap) both
# present AND privileged enough to write ID maps: the setuid bit, OR a cap_setuid
# file capability. Arch's `shadow` ships these with filecaps rather than setuid
# (Bugbot, client#458), so a setuid-only test wrongly rejects a working helper and
# false-hands-off. When getcap is unavailable we can't inspect caps, so fall back to
# the setuid check alone. Shared by probe.sh (detection) and setup-linux.sh (the
# post-install re-verify).
_idmap_helper_ok() {
  local name="$1" p cap
  p="$(command -v "$name" 2>/dev/null)" || return 1
  [[ -n "$p" ]] || return 1
  [[ -u "$p" ]] && return 0                     # setuid-root covers both helpers
  # Filecaps path (Arch etc.): newuidmap needs cap_setuid, newgidmap needs
  # cap_setgid — checking cap_setuid for both wrongly rejects newgidmap (Bugbot #458).
  case "$name" in
    newgidmap) cap=cap_setgid ;;
    *)         cap=cap_setuid ;;
  esac
  if has getcap; then
    local caps; caps="$(getcap "$p" 2>/dev/null)"
    [[ "$caps" == *"$cap"* ]] && return 0
  fi
  return 1
}

# Sanitize a minutes-valued env override to a base-10 integer, else <default>.
# The 10# base prefix matters: bash arithmetic reads a leading zero as octal,
# so 08/09 would ABORT $(( … )) under set -e (mid-create, leaving a partial
# cluster) and 010 would silently become 8 (Bugbot #442).
tb_minutes_or() {
  local v="$1" def="$2"
  case "$v" in ''|*[!0-9]*) echo "$def"; return 0 ;; esac
  echo $((10#$v))
}

# Strip ANSI escape sequences and C0 control characters from a value. A raw
# `read` captures whatever the terminal sends — this can include:
#   • bracketed-paste wrappers:  ESC[200~ ... ESC[201~
#   • arrow keys / cursor moves: ESC[A/B/C/D, ESC[1;5C, ESC[3~ (Delete), …
#   • function keys, modifier combos, mode-switch sequences
# Two shapes carry all of those:
#   CSI  ESC '[' <params ∈ [0-9;]> <final ∈ [A-Za-z~]>
#   SS3  ESC 'O' <final ∈ [A-Za-z~]>   — ESC OA/OB/OC/OD, ESC OH/OF, ESC OP…OS
# SS3 is what the SAME keys emit once the terminal is in DECCKM
# application-cursor mode, the state vim/less/tmux leave behind on an unclean
# exit (cli#516). It was the hole left by the CSI-only fix of 2026-07-21
# (client#362 / cli#364): ESC is dropped as a C0 byte but 'O' and the final byte
# are printable, so ESC OD ESC OA survived as the plausible name "ODOA" and
# minted a permanent namespace — where CSI residue cleans to empty and re-prompts.
# Strip iteratively to handle consecutive sequences (e.g. paste-wrappers).
#
# Also handles the post-corruption case where ESC was stripped by an earlier
# (buggy) sanitizer but the literal `[200~`/`[201~` markers survived. Only
# self-heals the two well-defined bracketed-paste markers — generic `[X]`
# shapes could plausibly be real password content.
#
# UTF-8 bytes (0x80+) preserved so international characters survive. Lives here
# (shared) so BOTH the credential path (install-client-helm.sh) and the client-
# name prompt (provision.sh) sanitize identically (customer-reported 2026-07-20).
# Mirrored by cli/internal/cli/sanitize.go and install-k8s.ps1's
# ConvertTo-SanitizedInput — change all three together.
_strip_paste_garbage() {
  local s="$1"
  local esc=$'\e'
  local esc_pattern="${esc}(\\[[0-9;]*|O)[A-Za-z~]"
  while [[ "$s" =~ $esc_pattern ]]; do
    s="${s/${BASH_REMATCH[0]}/}"
  done
  s="${s//\[200\~/}"
  s="${s//\[201\~/}"
  # The floor. The loop above knows CSI, SS3 and the paste markers; it cannot
  # know the escape family nobody has reported yet — and that is exactly how SS3
  # got here, one rule hand-copied into three languages with only CSI ever
  # tested. So if an ESC SURVIVED the loop, this value carries a shape we do not
  # recognise and its printable bytes are not trustworthy content. Require one
  # alphanumeric that did not come from an escape final byte, probing with ESC +
  # intermediates + AT MOST TWO final-class bytes. Two, not one and not
  # unbounded: one leaves the 'D' of an unrecognised SS3-shaped pair behind and
  # the floor stops firing on the very shape this is about, while unbounded
  # swallows a whole ASCII name (ESC N C h e l l o) yet spares a non-Latin one,
  # making keep-vs-reject depend on the script the name is written in (Bugbot,
  # #736). An escape final is one byte, an intro plus a final is two, and every
  # keyboard-input escape family fits in that. The probe's output is only a
  # yes/no — it is never returned. Nothing but residue ⇒ emit empty, which every
  # caller already treats as "no answer" (re-prompt, or auto-name in the CLI).
  if [[ "$s" == *"$esc"* ]]; then
    # `sed`, NOT the `while [[ =~ ]]; do s="${s/$BASH_REMATCH/}"` loop the strip
    # above uses. Pattern substitution treats BASH_REMATCH as a GLOB, and this
    # pattern — unlike the CSI one, whose match can never contain `]` — can match
    # a complete bracket expression: on ESC [ ; ] A the regex matches the whole
    # thing, the glob `<ESC>[;]A` then means ESC ';' 'A', which is NOT in the
    # string, the substitution removes nothing, and the loop never terminates.
    # That is a hang at the installer's name prompt. One sed pass has no glob
    # semantics and no loop.
    #
    # And "alphanumeric" via tr, not `=~ [[:alnum:]]`: bash's regex engine is
    # locale-dependent, and under the C locale the installer often runs in,
    # [[:alnum:]] does not match a UTF-8 letter — which would auto-name a
    # perfectly good "日本" the moment an unknown escape sat next to it. Keeping
    # every byte >= 0x80 makes "is there real content here" locale-independent
    # and matches what the strip itself already preserves.
    local probe
    probe="$(printf '%s' "$s" | LC_ALL=C sed -E "s/${esc}[^A-Za-z0-9~]*[A-Za-z~]{1,2}//g" | LC_ALL=C tr -dc '0-9A-Za-z\200-\377')"
    if [[ -z "$probe" ]]; then
      printf ''
      return 0
    fi
  fi
  printf '%s' "$s" | tr -d '\000-\037\177'
}

# _version_lt A B — true when dotted-numeric A < B. Pure and self-contained: no
# `sort -V` (BSD sort predates it, and this must behave the same on macOS) and no
# jq. Missing or non-numeric components read as 0, so "0.10" < "0.10.1" and a
# pre-release suffix ("0.10.0-rc.1") compares as its base version.
#
# Lives here rather than in assess.sh (backend#2422) because k3d.sh gates a
# kubelet flag on the k3s pin and assess.sh is sourced only conditionally.
#
# CALLER MUST STRIP A LEADING "v". A non-numeric leading component reads as 0, so
# `_version_lt v1.36.3 1.31.0` is TRUE — the comparison silently inverts and a
# version gate built on it never fires. Pass "${K8S_VERSION#v}", not
# "$K8S_VERSION". Pinned by a test in scripts/tests/assess.bats.
_version_lt() {
  local a="${1%%-*}" b="${2%%-*}" i av bv
  local -a _A _B
  IFS=. read -r -a _A <<<"$a"
  IFS=. read -r -a _B <<<"$b"
  for ((i = 0; i < 3; i++)); do
    av="${_A[i]:-0}"; bv="${_B[i]:-0}"
    [[ "$av" =~ ^[0-9]+$ ]] || av=0
    [[ "$bv" =~ ^[0-9]+$ ]] || bv=0
    (( av < bv )) && return 0
    (( av > bv )) && return 1
  done
  return 1
}

# Best-effort chart version of the installed client release in namespace $1
# (e.g. "1.4.4"); empty if not found / cluster unreachable. Greps helm's CHART
# column ("client-<ver>"), so it needs no jq.
_chart_version() {
  local ns="${1:-${TB_NAMESPACE:-tracebloc}}"
  has helm || return 0
  # Trailing `|| true`: when no client-* release exists, `grep` exits 1 and, under
  # `set -o pipefail`, the pipeline (this function's last command) returns 1 —
  # which would abort callers that assign it under `set -e` (e.g. diagnose.sh).
  # The version (or empty) has already been emitted to stdout regardless.
  helm list -n "$ns" 2>/dev/null | grep -oE 'client-[0-9][^[:space:]]*' | head -1 | sed 's/^client-//' || true
}

# THE CLIENT'S CORE WORKLOADS, READ FROM THE CLUSTER, NEVER BUILT FROM A NAME
# (backend#2888). These three Deployments are the set whose readiness DEFINES
# "the client is up": the post-install readiness gate (wait_for_client_ready,
# summary.sh), the stop-and-check gate (assess.sh) and --diagnose all read them
# through _client_workloads below.
#
# The installer used to REBUILD two of the names as `<namespace>-jobs-manager`
# and `<namespace>-requests-proxy`. The chart prefixes them with its resolved
# name, which equals the namespace only while `fullnameOverride` is unset, so on
# an overridden release every one of those sites looked for a Deployment that
# does not exist: the readiness gate read a healthy client as not Ready and
# --diagnose shipped empty jobs-manager logs. The names are now LISTED from the
# release instead:
#
#   * `app.kubernetes.io/instance=<release>` selects the release's Deployments.
#     It is the one label the chart keeps equal to the release name under an
#     override (scripts/tests/fullname-override-completeness.sh asserts it).
#   * each ROLE is then told apart by the Deployment's own
#     `spec.selector.matchLabels.app`, the right-hand side below. A Deployment's
#     selector is immutable, so the chart cannot rename these without replacing
#     the Deployment, and they never carry the release name.
#
# ONE TABLE PER LANGUAGE, HELD TOGETHER BY A GUARD: $script:ClientWorkloadRoles
# in scripts/install-k8s.ps1 is the PowerShell twin, and
# scripts/tests/client-workloads-read-not-built.sh holds the two identical AND
# holds each right-hand side to exactly one Deployment in the rendered chart,
# with and without an override. Keep this on ONE line of role=app words.
_TB_CLIENT_WORKLOAD_ROLES="mysql-client=mysql-client jobs-manager=manager requests-proxy=requests-proxy"

# _client_workloads_from_rows ROWS — the pure half: pick each role's Deployment
# out of `APP NAME` rows (what the kubectl read below prints) and print
# `ROLE NAME` lines in role order. Returns 1 and prints NOTHING unless every role
# matches exactly one row: a missing role is a client that is not all there, and
# two rows claiming one role is a namespace this cannot read unambiguously.
# Either way the caller must not guess, so every consumer reads rc 1 as "not
# Ready" / "not healthy" -- the fail-closed direction.
_client_workloads_from_rows() {
  local rows="$1" pair role app a name hit n out=""
  for pair in $_TB_CLIENT_WORKLOAD_ROLES; do
    role="${pair%%=*}"; app="${pair#*=}"; hit=""; n=0
    while read -r a name _; do
      [[ -n "$name" && "$a" == "$app" ]] || continue
      hit="$name"; n=$((n + 1))
    done <<<"$rows"
    (( n == 1 )) || return 1
    out+="${role} ${hit}"$'\n'
  done
  printf '%s' "$out"
}

# _client_workloads NS [TIMEOUT] [RELEASE] — the client's core workload
# Deployments in namespace NS, as `ROLE NAME` lines in role order (mysql-client,
# jobs-manager, requests-proxy). RELEASE defaults to NS: the installer names the
# release after the namespace (scripts/tests/release-name-equals-namespace.sh).
# ONE bounded read (TIMEOUT, default 10s); a failed or unanswered read returns 1,
# the same as a missing role. custom-columns rather than jsonpath so the same
# argument vector works from PowerShell, where an embedded `"` in a native
# argument is mangled on Windows PowerShell 5.1.
_client_workloads() {
  local ns="${1:-${TB_NAMESPACE:-default}}" timeout="${2:-10s}" rel="${3:-}" rows
  [[ -n "$rel" ]] || rel="$ns"
  rows="$(kubectl get deployment -n "$ns" -l "app.kubernetes.io/instance=${rel}" \
            -o 'custom-columns=APP:.spec.selector.matchLabels.app,NAME:.metadata.name' \
            --no-headers --request-timeout="$timeout" 2>/dev/null)" || return 1
  _client_workloads_from_rows "$rows"
}

# _client_workload_name NS ROLE [TIMEOUT] — one role's Deployment name, or rc 1.
_client_workload_name() {
  local rows role name
  rows="$(_client_workloads "$1" "${3:-10s}")" || return 1
  while read -r role name; do
    [[ "$role" == "$2" ]] && { printf '%s' "$name"; return 0; }
  done <<<"$rows"
  return 1
}

# THE RESOURCE-MONITOR DAEMONSET, READ FROM THE CLUSTER, NEVER BUILT FROM A NAME
# (client-dev#1306). --diagnose used to fetch
# `kubectl logs -n <client ns> daemonset/tracebloc-resource-monitor`, which is
# wrong on BOTH halves: the chart puts the DaemonSet in the node-agents namespace
# (`nodeAgents.namespace.name`, default `tracebloc-node-agents`), never the
# client's, and names it `<fullname>-resource-monitor`, which follows the release
# and `fullnameOverride`. So every bundle shipped a NotFound error as the
# resource-monitor log. It is now LISTED instead:
#
#   * `app.kubernetes.io/instance=<release>` across every namespace selects the
#     release's DaemonSets, wherever `nodeAgents.namespace` put them.
#   * the chart's `meta.helm.sh/release-namespace` annotation must name the
#     client namespace: the node-agents namespace is deliberately shareable, and
#     two releases of one name in two namespaces both match the label.
#   * the one whose pod template runs the container below is the resource-monitor.
#     The container name is fixed across releases by design (as
#     scripts/tests/collector-class-a-agreement.sh also records), so it is the
#     stable handle the object name is not.
#
# TWIN of $script:ResourceMonitorContainer in scripts/install-k8s.ps1;
# scripts/tests/client-workloads-read-not-built.sh holds the two identical and
# holds the helper below to the DaemonSet the chart renders, with and without an
# override.
_TB_RESOURCE_MONITOR_CONTAINER="tracebloc-resource-monitor"

# _resource_monitor_from_rows ROWS NS — the pure half: out of
# `RELEASE-NS NAMESPACE NAME CONTAINERS` rows (what the read below prints;
# CONTAINERS comma-separated), print `NAMESPACE NAME` of the one DaemonSet whose
# release namespace is NS and whose pod template runs the resource-monitor
# container. Returns 1 and prints NOTHING unless exactly one row matches -- none
# is a release without the resource-monitor (or a failed read), two cannot be
# told apart, and neither is a name to guess.
_resource_monitor_from_rows() {
  local rows="$1" want="$2" relns ns name ctrs c hit="" n=0
  local -a cs
  while read -r relns ns name ctrs _; do
    [[ -n "$ctrs" && "$relns" == "$want" ]] || continue
    IFS=',' read -r -a cs <<<"$ctrs"
    for c in "${cs[@]}"; do  # set-u-safe: ctrs is non-empty, and read -a of a non-empty line yields a field
      [[ "$c" == "$_TB_RESOURCE_MONITOR_CONTAINER" ]] || continue
      hit="$ns $name"; n=$((n + 1)); break
    done
  done <<<"$rows"
  (( n == 1 )) || return 1
  printf '%s\n' "$hit"
}

# _resource_monitor_daemonset NS [TIMEOUT] [RELEASE] — `NAMESPACE NAME` of the
# resource-monitor DaemonSet of the client in namespace NS, or rc 1. RELEASE
# defaults to NS, as in _client_workloads. ONE bounded read (TIMEOUT, default
# 10s); custom-columns for the same PowerShell-quoting reason.
_resource_monitor_daemonset() {
  local ns="${1:-${TB_NAMESPACE:-default}}" timeout="${2:-10s}" rel="${3:-}" rows
  [[ -n "$rel" ]] || rel="$ns"
  rows="$(kubectl get daemonset -A -l "app.kubernetes.io/instance=${rel}" \
            -o 'custom-columns=RELNS:.metadata.annotations.meta\.helm\.sh/release-namespace,NS:.metadata.namespace,NAME:.metadata.name,CONTAINERS:.spec.template.spec.containers[*].name' \
            --no-headers --request-timeout="$timeout" 2>/dev/null)" || return 1
  _resource_monitor_from_rows "$rows" "$ns"
}

# ── Spinner — hides noisy command output behind an animated status line ──────
#  Usage:  spin <pid> "Installing foo…" [deadline_seconds]
#  The background process's stdout/stderr should already be redirected to a file
#  before calling spin. spin waits for the PID to exit and returns its exit code.
#  With the optional third argument, a still-running PID is killed once the
#  deadline passes and spin returns 124 (GNU timeout's convention) — the
#  backstop for commands that can wedge indefinitely (#426).
spin() {
  local pid="$1" msg="$2" deadline_s="${3:-}"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  local ticks=0                           # one tick ≈ 0.12s
  local _spin_t0=$SECONDS                 # the deadline's wall clock: ticks alone stretch on a slow host (client-dev#1514)
  local _spin_kids="" _spin_k=""          # deadline path: captured child PIDs

  tput civis 2>/dev/null || true          # hide cursor
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -n "$deadline_s" ]] && (( ticks * 12 >= deadline_s * 100 || SECONDS - _spin_t0 > deadline_s )); then
      # Children FIRST: the pid is often a wrapper subshell (k3d.sh's
      # `( k3d … ) &`) — signalling only the wrapper orphans the real worker,
      # which keeps running (k3d keeps creating the cluster) after the install
      # has already failed, racing any retry (Bugbot #442). Capture the child
      # PIDs BEFORE any signal: once the wrapper dies they reparent to init
      # and pkill -P can't see them (Bugbot #442 r2), so the KILL sweep must
      # address them by captured PID. Harmless when bash exec-optimized the
      # wrapper away — then $pid IS the worker and there are no children.
      # Every line below is failure-proofed (`|| true`): pkill returns 1 when
      # there are no children, kill/wait fail on already-reaped PIDs, and wait
      # reports the kill signal — under `set -e` any of those would abort the
      # deadline path before `return 124`, so the caller would never see the
      # timeout (no warn/hint, no partial-cluster cleanup) (Bugbot #442 r3).
      _spin_kids="$(pgrep -P "$pid" 2>/dev/null || true)"
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      sleep 0.5
      for _spin_k in $_spin_kids; do
        kill -9 "$_spin_k" 2>/dev/null || true
      done
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      printf "\r\033[K"
      tput cnorm 2>/dev/null || true
      return 124
    fi
    printf "\r  ${CYAN}%s${RESET} %s" "${frames[i]}" "$msg"
    i=$(( (i + 1) % ${#frames[@]} ))
    ticks=$(( ticks + 1 ))
    sleep 0.12
  done

  wait "$pid"
  local rc=$?
  printf "\r\033[K"                       # clear the spinner line
  tput cnorm 2>/dev/null || true          # restore cursor
  return $rc
}

# ── Convenience wrapper: run a command quietly behind a spinner ───────────────
#  Usage:  spin_cmd "Installing foo…" brew install --cask docker
#  stdout/stderr are captured in the LOG_FILE (if set) or a private mktemp file
#  (_tb_spin_logfile; never a fixed /tmp name, backend#4279)
spin_cmd() {
  local msg="$1"; shift
  local logfile; _tb_spin_logfile; logfile="$_TB_SPIN_LOG"
  "$@" >> "$logfile" 2>&1 &
  local pid=$!
  if ! spin "$pid" "$msg"; then
    echo -e "  ${RED}${BOLD}✖ ${msg}${RESET}" >&2
    echo -e "  ${DIM}Last 10 lines of log:${RESET}" >&2
    tail -10 "$logfile" >&2
    return 1
  fi
}

# ── spin_cmd with a hard deadline (#426) ─────────────────────────────────────
#  Usage:  spin_cmd_bounded <seconds> "Doing the thing…" cmd args…
#  For commands that can wedge indefinitely against a stuck endpoint (helm
#  talking to a wedged kube-apiserver). Same quiet-log capture + failure tail
#  as spin_cmd; returns the command's real exit code, or 124 when the deadline
#  killed it (with a timeout note so the user knows it was us, not the tool).
spin_cmd_bounded() {
  local secs="$1" msg="$2"; shift 2
  local logfile; _tb_spin_logfile; logfile="$_TB_SPIN_LOG"
  "$@" >> "$logfile" 2>&1 &
  local pid=$!
  local rc=0
  spin "$pid" "$msg" "$secs" || rc=$?
  if (( rc == 124 )); then
    echo -e "  ${RED}${BOLD}✖ ${msg} — timed out after ${secs}s${RESET}" >&2
    echo -e "  ${DIM}Last 10 lines of log:${RESET}" >&2
    tail -10 "$logfile" >&2
    return 124
  elif (( rc != 0 )); then
    echo -e "  ${RED}${BOLD}✖ ${msg}${RESET}" >&2
    echo -e "  ${DIM}Last 10 lines of log:${RESET}" >&2
    tail -10 "$logfile" >&2
    return $rc
  fi
}

# _docker_answers_bounded MSG [SECONDS] — "is the daemon up?", bounded on EVERY
# platform and shown behind a spinner. The bound comes from spin's own
# background-pid + kill deadline (#426), NOT from _bounded.
#
# WHY A SECOND PROBE EXISTS ALONGSIDE _docker_answers (backend#2521). Both answer
# the same question, but _docker_answers bounds through _bounded, which runs the
# BARE command when neither timeout(1) nor gtimeout(1) is on PATH -- and NEITHER
# ships on stock macOS (both are GNU coreutils). So on a Mac with no coreutils,
# `_docker_answers` degrades to an unbounded `docker info`, and a bare `docker
# info` does not return against a WEDGED daemon (as opposed to a cleanly stopped
# one — the same distinction _docker_answers' own header draws). The colima-stop
# recovery path in setup-macos.sh is reached precisely when a timed-out `colima
# stop` may have left the VZ VM half-down — exactly the wedged state — so a
# headless macOS install froze there with no spinner and never reached its
# restore. spin backgrounds the probe and kills it on the deadline with no
# coreutils dependency, so the bound holds on a stock Mac too.
#
# SILENT on a non-answer (no ✖ / log tail, unlike spin_cmd_bounded): a daemon
# that does not answer is the expected result on a recovery path, not an error to
# shout about — the caller decides what to say. Returns 0 iff docker answered
# within SECONDS; non-zero otherwise (124 when the deadline fired).
_docker_answers_bounded() {
  local msg="$1" secs="${2:-${TB_DOCKER_PROBE_TIMEOUT:-10}}" _pid
  # This IS the coreutils-free bound: the probe runs in the background and `spin`
  # kills it on the deadline via its PID — so it is bounded without timeout(1). The
  # check-style rule-5 grep only recognises the lexical _bounded/timeout forms, so
  # exempt this line explicitly (it is the one legitimate background-PID probe).
  docker info >/dev/null 2>&1 &   # style-guard: allow
  _pid=$!
  spin "$_pid" "$msg" "$secs"
}

# ── Root-aware privileged execution (RFC 0001 A2) ────────────────────────────
#  The installer's privileged steps are written as `sudo <cmd>`. Two gaps that
#  needlessly excluded real users — a shared-cluster researcher, a root
#  container/VM:
#    (a) when we are ALREADY root, sudo is unnecessary — and often ABSENT on
#        minimal images — so `sudo <cmd>` died with "sudo: command not found"
#        even though <cmd> would have run fine directly; and
#    (b) "sudo isn't installed" was reported as "no sudo access", a different and
#        misleading fix.
#  We shadow `sudo` with a function so every existing `sudo <cmd>` call site is
#  fixed with NO edit: as root, run <cmd> directly (no sudo binary needed);
#  otherwise defer to the real sudo; and when neither is possible, fail the way
#  the real sudo would (non-zero) so best-effort `sudo … || fallback` sites still
#  take their fallback. Only `sudo <command>` forms route through here — the sole
#  option-only uses (`sudo -v` / `sudo -n`) live in preflight_sudo and go through
#  _real_sudo. Detection + the real binary are wrapped in tiny helpers so the
#  bats suite can exercise every branch without a real sudo.
_have_sudo_bin() { type -P sudo >/dev/null 2>&1; }   # real binary, ignoring this fn; no $(...) so a failing probe can't trip set -e on bash <4.4 (Bugbot #372)
_real_sudo()     { command sudo "$@"; }           # the real sudo, bypassing the shadow

sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif _have_sudo_bin; then
    _real_sudo "$@"
  else
    # Not root and no sudo binary. Mimic sudo's own not-found failure (non-zero)
    # rather than exit, so best-effort call sites keep working; preflight_sudo
    # aborts up front with an accurate message on the REQUIRED path.
    echo "sudo: not found (you are not root and sudo is not installed)" >&2
    return 127
  fi
}

# Export the shadow (+ its helpers) so `sudo <cmd>` inside `bash -c '…'` subshells
# also routes through it — e.g. the apt-lock wait and the RHEL-rebuild (Alma/Rocky/
# OL) Docker install in setup-linux.sh both run `bash -c '… sudo … …'`. Without
# export, those child shells resolve the REAL sudo binary, so a root box without
# sudo installed would still hit "sudo: command not found" there — the exact case
# A2 fixes everywhere else (review #372). Harmless to non-bash children, which
# ignore the BASH_FUNC_* environment entries.
export -f sudo _real_sudo _have_sudo_bin

# ── Sudo preflight — warm the credential cache before spinners hide prompts ──
#  Call once at the start of install_macos / install_linux. Establishes that the
#  privileged steps below can run, and (when a password is needed) primes the
#  sudo credential once so later steps behind spinners don't re-prompt.
preflight_sudo() {
  # Already root — nothing to prime; the sudo() shadow runs privileged steps
  # directly and needs no sudo binary. Fixes root containers/VMs and minimal
  # images without sudo (A2).
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  # Not root AND no sudo binary — the honest, actionable failure (previously
  # conflated with "no sudo access").
  if ! _have_sudo_bin; then
    error "This machine needs administrator rights to install Docker and system tools, but you are not root and sudo isn't installed. Re-run as root, or install sudo (e.g. apt-get install sudo) and try again."
  fi
  # Sudo present and already usable without a password (cached / NOPASSWD).
  if _real_sudo -n true 2>/dev/null; then
    return 0
  fi
  # Prompt once, then keep the credential warm. One line, then the system's own
  # "Password:" prompt. Kept generic so it reads correctly on macOS (Docker
  # Desktop) and Linux (Docker Engine + system packages).
  hint "tracebloc needs your password once to set up Docker and a few tools."
  echo ""
  _real_sudo -v || error "Could not obtain administrator privileges (sudo authentication failed). Re-run as a user allowed to sudo, or as root."
  ( while _real_sudo -n true 2>/dev/null; do sleep 50; done ) &
  SUDO_KEEPALIVE_PID=$!
}

# ── Download with live progress bar ───────────────────────────────────────────
#  Usage:  download_with_progress "https://…/file.dmg" "/tmp/file.dmg" "Downloading Docker Desktop"
#  Probes total size via HEAD, downloads in background, and monitors the growing
#  file to render a visual bar with percentage and MB counters.  Works on both
#  macOS and Linux without stdbuf or GNU coreutils.
download_with_progress() {
  local url="$1" dest="$2" label="$3"

  local total_bytes
  # -m 15 tightens curl_secure's default deadline for the HEAD probe so a stalled
  # server can't hang it (it's not retry-wrapped and its failure just means
  # "no total" -> indeterminate bar).
  total_bytes=$(curl_secure -fsSLI -m 15 "$url" 2>/dev/null \
    | awk 'tolower($0) ~ /content-length/ {gsub(/[^0-9]/,"",$2); print $2}' \
    | tail -1)

  local total_mb=""
  if [[ -n "$total_bytes" ]] && (( total_bytes > 0 )) 2>/dev/null; then
    total_mb=$(awk "BEGIN {printf \"%.0f\", $total_bytes / 1048576}")
    hint "${label} (${total_mb} MB)"
  else
    hint "$label"
    total_bytes=0
  fi

  local logfile; _tb_spin_logfile; logfile="$_TB_SPIN_LOG"
  rm -f "$dest"

  # --connect-timeout bounds the dial; --speed-limit/--speed-time abort a STALLED
  # transfer (<1 KB/s for 60s) without capping a legitimately slow-but-progressing
  # large download. Without these the backgrounded curl is monitored only by
  # `kill -0` (no deadline, no kill), so a slow-loris / mid-stream stall would
  # hang the progress loop forever. The stall flags are also how curl_secure knows
  # NOT to add its default --max-time here: this path carries the large (hundreds
  # of MB) Docker Desktop DMG, where a fixed deadline would fail a slow-but-healthy
  # link.
  curl_secure -fSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
    -o "$dest" "$url" >> "$logfile" 2>&1 &
  local curl_pid=$!

  local bar_width=30
  tput civis 2>/dev/null || true

  while kill -0 "$curl_pid" 2>/dev/null; do
    if [[ -f "$dest" ]] && (( total_bytes > 0 )); then
      local cur_bytes
      cur_bytes=$(wc -c < "$dest" 2>/dev/null || echo 0)
      cur_bytes=${cur_bytes// /}

      local pct=$(( cur_bytes * 100 / total_bytes ))
      (( pct > 100 )) && pct=100
      local filled=$(( pct * bar_width / 100 ))
      local empty=$(( bar_width - filled ))
      local cur_mb=$(awk "BEGIN {printf \"%.0f\", $cur_bytes / 1048576}")

      local bar=""
      for (( j=0; j<filled; j++ )); do bar+="█"; done
      for (( j=0; j<empty;  j++ )); do bar+="░"; done

      printf "\r  ${CYAN}%s${RESET} %3d%%  %s / %s MB" "$bar" "$pct" "$cur_mb" "$total_mb"
    fi
    sleep 0.4
  done

  wait "$curl_pid"
  local rc=$?

  if [[ $rc -eq 0 ]] && [[ -n "$total_mb" ]]; then
    local bar=""
    for (( j=0; j<bar_width; j++ )); do bar+="█"; done
    printf "\r  ${CYAN}%s${RESET} 100%%  %s / %s MB\n" "$bar" "$total_mb" "$total_mb"
  fi
  printf "\r\033[K"
  tput cnorm 2>/dev/null || true
  return $rc
}

# ── Count bar — honest N-of-M progress for things pulled in discrete units ────
#  Usage:  count_bar <current> <total> [noun]      (renders ONE frame)
#  Draws a bar plus an "N of M <noun>" counter and NO newline, so a caller loop
#  can overwrite it in place (with \r) and clear it at the end via printf "\r\033[K".
#  Use this — never a fabricated aggregate percentage — for multi-image pulls
#  (e.g. the client's container images), where the only honest signal is how many
#  of a known count have completed. The %-by-bytes bar (download_with_progress) is
#  reserved for a single-file curl download, where a true byte percentage exists.
count_bar() {
  local cur="$1" total="$2" noun="${3:-items}" w=24 filled j bar=""
  [[ "$cur"   =~ ^[0-9]+$ ]] || cur=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=1
  (( total < 1 ))     && total=1
  (( cur > total ))   && cur=$total
  (( cur < 0 ))       && cur=0
  filled=$(( cur * w / total ))
  for (( j=0; j<filled; j++ )); do bar+="█"; done
  for (( j=filled; j<w;   j++ )); do bar+="░"; done
  printf "\r  ${CYAN}%s${RESET}  %d of %d %s" "$bar" "$cur" "$total" "$noun"
}

# ── Retry wrapper for flaky network calls ────────────────────────────────────
#  Usage:  retry 3 5 curl -fsSL https://example.com -o /tmp/file
#          retry <max_attempts> <delay_seconds> <command...>
retry() {
  local max_attempts="$1" delay="$2"; shift 2
  local attempt=1
  while true; do
    if "$@"; then return 0; fi
    if [[ $attempt -ge $max_attempts ]]; then
      warn "Command failed after $max_attempts attempts: $*"
      return 1
    fi
    warn "Attempt $attempt/$max_attempts failed. Retrying in ${delay}s..."
    sleep "$delay"
    ((attempt++))
  done
}

# ── Log file — captures all stdout/stderr alongside the terminal ─────────────
# Choose the log-file path: under HOST_DATA_DIR when it's creatable AND writable,
# else a temp file — so setup_log_file never dies on a bare `mkdir -p`/`tee` (#432).
# This matters for prepare-host, which logs BEFORE the data-dir guard runs: on an NFS
# home under sudo + root_squash the data dir isn't creatable/writable yet, and a
# cryptic mkdir failure there predates any friendly message. (The full install's
# early_data_dir_guard still refuses a network DATA dir before this runs.) Pure-ish
# (prints the path; no exec redirect) so it's unit-testable.
_choose_log_file() {
  local candidate=""
  if mkdir -p "$HOST_DATA_DIR" 2>/dev/null; then
    candidate="${HOST_DATA_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
    : >"$candidate" 2>/dev/null || candidate=""   # confirm it's actually writable
  fi
  # Trailing X's (no suffix after): BSD mktemp (macOS) requires the X's at the END
  # of the template, GNU accepts it too — a `.log` suffix would break macOS.
  [[ -n "$candidate" ]] || candidate="$(mktemp "${TMPDIR:-/tmp}/tracebloc-install-XXXXXX" 2>/dev/null || echo /dev/null)"
  printf '%s' "$candidate"
}

setup_log_file() {
  LOG_FILE="$(_choose_log_file)"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "Install log: $LOG_FILE"
  # The substrate line printed before the log existed goes into it too, verbatim
  # (not through log(), whose timestamp would bend the grammar).
  if [[ -n "${TB_SUBSTRATE_TOKEN_PRINTED:-}" ]]; then
    tb_substrate_token >>"$LOG_FILE" 2>/dev/null || true
  fi
}

# ── Configuration (overridable via env) ──────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-tracebloc}"
# The secure-environment name (= the Helm release and the k8s namespace).
# Settings naming: TRACEBLOC_NAMESPACE is the canonical env var, TB_NAMESPACE
# the legacy alias (remove_by 2026-12-31). A non-empty TRACEBLOC_NAMESPACE wins,
# else TB_NAMESPACE, else it stays unset and each reader keeps its own default
# -- the same precedence and blank-means-unset rule as tb_client_env above.
# Resolved ONCE, here, into TB_NAMESPACE, the variable the rest of the installer
# reads and re-assigns (sanitising, adopting an existing release, provisioning);
# where the installer hands the name on it exports both spellings
# (tb_export_namespace), so a child that resolves alias-first sees the SAME
# value and not a stale canonical the user set before the name was decided.
if [[ -n "${TRACEBLOC_NAMESPACE:-}" ]]; then TB_NAMESPACE="$TRACEBLOC_NAMESPACE"; fi

# tb_export_namespace — export the decided secure-environment name under both
# spellings. An unset TB_NAMESPACE exports an empty canonical, which every
# alias-first reader treats as unset.
tb_export_namespace() {
  TRACEBLOC_NAMESPACE="${TB_NAMESPACE:-}"
  export TB_NAMESPACE TRACEBLOC_NAMESPACE
}
# SERVERS/AGENTS are k3d's node counts and nothing else: their defaults, the
# node-local single-node forcing and their validation live in the k3d create path
# (k3d.sh::_k3d_node_counts), so code that is not k3d never reads them.
# RFC-0003 — local dataset storage model. node-local is the DEFAULT as of the
# D15 flip (client#456, epic backend#1151), superseding the flag-gated prototype
# from #367. (D15 gates the flip on a green node-local dev training run on the dev
# environment; that sign-off is tracked on client#456, not asserted here.)
#   node-local (default, Option C): datasets live on k3s local-path INSIDE the
#                          k3d node — they die with `cluster delete`, are not a
#                          browsable host folder, and need no chmod 777. This is
#                          the RFC-0003 goal for the local install. The flip
#                          applies to the Linux/k3s (bash core) install path;
#                          install-k8s.ps1 stays hostpath-only (no Windows
#                          node-local path yet — see the D15 scope note on #456).
#   hostpath   (opt-out) : the older model — datasets live in ~/.tracebloc on the
#                          host, bind-mounted into the cluster; survive cluster
#                          delete; world-writable dirs. Select with
#                          TB_STORAGE_MODE=hostpath (still required for a
#                          HOST_DATASET_DIR network mount).
# C1: node-local forces a single k3d node (k3d.sh::_k3d_node_counts says why).
# Record whether the operator chose the mode or is getting the D15 default: the
# existing-cluster mismatch guard phrases its remedy differently for "you set
# node-local" vs "node-local is the default now" (client#456 review, Bugbot High).
if [[ -n "${TB_STORAGE_MODE:-}" ]]; then TB_STORAGE_MODE_SOURCE="explicit"; else TB_STORAGE_MODE_SOURCE="default"; fi
TB_STORAGE_MODE="${TB_STORAGE_MODE:-node-local}"
# Pinned default; an empty value falls back to this pin (`:-` treats empty and
# unset the same — there is no opt-out to "latest" for k3s).
K8S_VERSION="${K8S_VERSION:-v1.36.3-k3s1}"
# CUDA base tag for the GPU-capable k3d node image (client#616/#835). The custom
# docker/k3s-cuda image rebuilds the SAME pinned k3s (K8S_VERSION) on this CUDA
# base, and its published tag encodes both (…/k3s-cuda:<K8S_VERSION>-cuda-<this>),
# so k3d.sh::_gpu_node_image can derive the pull ref deterministically.
# TRACEBLOC_CUDA_BASE_TAG overrides it (mirrors the Windows twin's $CUDA_BASE_TAG).
# check-facts.sh keeps this in lockstep with facts.env's CUDA_TAG and the four
# other consumers, so a bump can't derive a GPU image tag that was never built.
# shellcheck disable=SC2034  # consumed cross-file by k3d.sh (_gpu_node_image)
TB_CUDA_BASE_TAG="${TRACEBLOC_CUDA_BASE_TAG:-12.4.1-base-ubuntu22.04}"
# Exact digest of the published k3s-cuda image for the tag those two derive (backend#1867).
# The tag is mutable; k3d.sh's pre-pull asserts the tag resolved to THIS digest and
# drops to CPU if it did not. It is deliberately NOT appended to the pull ref -- see the
# note in scripts/spec/facts.env for why a tag@digest ref is a lie waiting to happen. No
# TRACEBLOC_* override on purpose -- an operator who wants a different image already
# has TRACEBLOC_K3S_CUDA_IMAGE, and a second knob for the same thing could pin a
# digest onto a ref it does not belong to. check-facts.sh keeps it in lockstep with
# facts.env's K3S_CUDA_DIGEST, and --check-published proves it still equals the live
# digest of the derived tag.
# shellcheck disable=SC2034  # consumed cross-file by k3d.sh (_gpu_node_image)
TB_K3S_CUDA_DIGEST="sha256:fbb1a8cfebcdf32320b493fc614161cd1115603067135c27080ac380e4742e9d"
# The NVIDIA GPU floors (facts.env NVIDIA_DRIVER_FLOOR_LINUX / NVIDIA_COMPUTE_CAP_FLOOR,
# stamped by check-facts.sh --write). Below the compute-capability floor detect-gpu.sh
# leaves the GPU unwired and the install runs CPU-only; below the driver floor it
# warns and wires the GPU anyway. Policy, so no TRACEBLOC_* override.
# shellcheck disable=SC2034  # consumed cross-file by detect-gpu.sh and gpu-nvidia.sh
TB_NVIDIA_DRIVER_FLOOR="570.26"
# shellcheck disable=SC2034  # consumed cross-file by detect-gpu.sh
TB_NVIDIA_COMPUTE_CAP_FLOOR="7.5"
# Pinned default; ONLY the literal K3D_VERSION=latest resolves the newest k3d
# release at install time instead (an empty value falls back to this pin, like
# K8S_VERSION above). The binary is fetched directly from the release and
# verified against its checksums.txt either way (setup-linux.sh). The pin makes
# installs deterministic and immune to the releases/latest lookup, which breaks
# under GitHub rate limiting on shared egress IPs (CI runners, corporate NAT).
K3D_VERSION="${K3D_VERSION:-v5.9.0}"
# Pinned default; ONLY the literal HELM_VERSION=latest resolves the newest Helm
# release at install time (an empty value falls back to this pin, like the two
# above). The tarball is fetched directly from get.helm.sh and verified against
# its published .sha256sum either way (setup-linux.sh) — helm's get-helm-3
# script is NOT used: it floats on the mutable helm/helm@main and needs
# openssl, which minimal cloud images don't ship (#395).
HELM_VERSION="${HELM_VERSION:-v4.2.3}"
# Settings naming: TRACEBLOC_HOST_DATA_DIR is the canonical env var, HOST_DATA_DIR
# the legacy one (remove_by 2026-12-31) -- the same rule as TRACEBLOC_NAMESPACE
# above: a non-empty canonical wins, else the legacy, else the default. Resolved
# ONCE, here, into HOST_DATA_DIR, the variable the rest of the installer reads
# and re-assigns (--data-dir, validate_config's normalisation, the leftover
# guard's new-dir choice); validate_config then exports both spellings
# (tb_export_host_data_dir), so a child resolving alias-first sees the decided
# path and not a stale canonical.
if [[ -n "${TRACEBLOC_HOST_DATA_DIR:-}" ]]; then HOST_DATA_DIR="$TRACEBLOC_HOST_DATA_DIR"; fi
HOST_DATA_DIR="${HOST_DATA_DIR:-$HOME/.tracebloc}"

# tb_export_host_data_dir — export the decided data dir under both spellings.
tb_export_host_data_dir() {
  TRACEBLOC_HOST_DATA_DIR="${HOST_DATA_DIR:-}"
  export HOST_DATA_DIR TRACEBLOC_HOST_DATA_DIR
}
# Optional separate host dir for the big DATASET volume (backend#743). Empty
# (default) keeps datasets under HOST_DATA_DIR. When set — e.g. a network/NFS
# mount like /data01/tracebloc — the installer bind-mounts it into the cluster
# at /tracebloc-data and the chart's dataset PV points there, while mysql + logs
# stay on the local HOST_DATA_DIR (InnoDB over NFS is unsafe).
HOST_DATASET_DIR="${HOST_DATASET_DIR:-}"

# ── Input validation ────────────────────────────────────────────────────────
validate_config() {
  [[ -n "${HOME:-}" ]]  || error "\$HOME is not set — cannot determine user home directory"
  [[ -n "${USER:-}" ]]  || USER="$(whoami)" || error "Cannot determine current user"

  [[ "$CLUSTER_NAME" =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,62}$ ]] \
    || error "CLUSTER_NAME must start with a letter, contain only [a-zA-Z0-9._-], max 63 chars (got '$CLUSTER_NAME')"

  [[ "$TB_STORAGE_MODE" == "hostpath" || "$TB_STORAGE_MODE" == "node-local" ]] \
    || error "TB_STORAGE_MODE must be 'hostpath' or 'node-local' (got '$TB_STORAGE_MODE')"

  # node-local forces hostPath.enabled=false, so a HOST_DATASET_DIR network export
  # would be ignored and datasets would silently land on ephemeral local-path
  # storage (gone on 'cluster delete'). Combining the two is a documented follow-up
  # (backend#743 + RFC-0003); until then, refuse it rather than misroute datasets.
  [[ "$TB_STORAGE_MODE" == "node-local" && -n "${HOST_DATASET_DIR:-}" ]] \
    && error "HOST_DATASET_DIR is not supported with TB_STORAGE_MODE=node-local (datasets would land on ephemeral in-node storage, not the export). Use hostpath mode (TB_STORAGE_MODE=hostpath) for network-mount datasets."

  # HOST_DATA_DIR must be under $HOME and must not be a system path (security)
  local dir="$HOST_DATA_DIR"
  # Fail closed on an empty value (e.g. --data-dir= with no path) — otherwise the
  # $HOME-relative rewrite below resolves "" to a surprise dir like $HOME/$USER.
  [[ -n "$dir" ]] || error "HOST_DATA_DIR must not be empty (got '')."
  # Expand a leading ~ / ~/ : users type --data-dir=~/foo and the shell does not
  # expand ~ inside a quoted value, so it would otherwise be read as the literal
  # "$HOME/~/foo" and fail parent resolution. Only the leading ~ is expanded.
  case "$dir" in
    "~")   dir="$HOME" ;;
    "~/"*) dir="$HOME/${dir#\~/}" ;;
  esac
  [[ "$dir" != /* ]] && dir="$HOME/$dir"
  # Resolve via parent directory — the target itself may not exist yet on first run
  local parent
  parent="$(cd -P "$(dirname "$dir")" 2>/dev/null && pwd)" || true
  [[ -z "$parent" ]] && error "HOST_DATA_DIR parent directory could not be resolved: $(dirname "$dir")"
  dir="$parent/$(basename "$dir")"
  case "$dir" in
    /) error "HOST_DATA_DIR cannot be root (/)"
      ;;
    /etc|/etc/*|/usr|/usr/*|/var|/var/*|/bin|/sbin|/lib|/lib64)
      error "HOST_DATA_DIR cannot be a system path: $dir"
      ;;
  esac
  # Must be strictly UNDER $HOME — never $HOME itself. $HOME is reachable via a
  # bare '~', HOST_DATA_DIR=$HOME, or --data-dir=$HOME; adopting it would make the
  # installer chmod 777 home-level logs/mysql dirs, bind-mount all of $HOME into
  # the cluster, and treat any existing ~/data or ~/mysql as install data
  # (Bugbot #384).
  [[ "$dir" == "$HOME" ]] && \
    error "HOST_DATA_DIR must be a subdirectory of \$HOME, not \$HOME itself (got: $HOST_DATA_DIR)."
  [[ "${dir#$HOME/}" == "$dir" ]] && \
    error "HOST_DATA_DIR must be under \$HOME (got: $HOST_DATA_DIR)"
  HOST_DATA_DIR="$dir"
  tb_export_host_data_dir

  # Optional dataset dir (backend#743): unlike HOST_DATA_DIR it MAY live outside
  # $HOME (a mounted network volume like /data01). It must already EXIST and be
  # WRITABLE as the host user — we never mkdir a network-share root — and is
  # barred from system paths. The HOST_DATA_DIR rules above are unchanged.
  if [[ -n "${HOST_DATASET_DIR:-}" ]]; then
    local ddir="$HOST_DATASET_DIR" rddir
    [[ "$ddir" == /* ]] || error "HOST_DATASET_DIR must be an absolute path (got '$HOST_DATASET_DIR')"
    [[ -d "$ddir" ]]    || error "HOST_DATASET_DIR does not exist: $ddir (mount the dataset volume before installing)"
    [[ -w "$ddir" ]]    || error "HOST_DATASET_DIR is not writable (uid $(id -u)): $ddir — check its permissions."
    rddir="$(cd -P "$ddir" 2>/dev/null && pwd)" || error "HOST_DATASET_DIR could not be resolved: $ddir"
    case "$rddir" in
      /) error "HOST_DATASET_DIR cannot be root (/)" ;;
      /etc|/etc/*|/usr|/usr/*|/var|/var/*|/bin|/sbin|/lib|/lib64)
        error "HOST_DATASET_DIR cannot be a system path: $rddir" ;;
    esac
    HOST_DATASET_DIR="$rddir"
  fi
}

# ── Runtime globals ──────────────────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"
# On macOS, override ARCH with real hardware to avoid Rosetta misdetection
# Capture-then-match (#680): a SIGPIPE'd producer under pipefail reads as "no
# match" here, which would leave an Apple Silicon Mac detected as x86_64 and pick
# the wrong download for every pinned tool.
if [[ "$OS" == "Darwin" ]]; then
  _tb_arm64_flag="$(sysctl -n hw.optional.arm64 2>/dev/null || true)"
  [[ "$_tb_arm64_flag" == "1" ]] && ARCH="arm64"
  unset _tb_arm64_flag
fi
[[ "$ARCH" == "x86_64" ]] && ARCH_DL="amd64" || ARCH_DL="arm64"

# True if this host can run amd64 binaries via QEMU binfmt. Lives here (not in
# preflight.sh) because TWO gates now ask it — preflight's early arch check and
# install-client-helm.sh's engine gate (backend#2047) — and both must read the
# same probe: an arch verdict that disagreed with the engine verdict is the bug
# that ticket describes. Wrapped in a function so bats can override it.
amd64_emulation_available() { [[ -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ]]; }

GPU_VENDOR="none"          # nvidia | amd | apple_silicon | none
NVIDIA_DRIVER_OK=false
# detect-gpu.sh's floor verdict for a present NVIDIA driver: ok | below-driver |
# below-compute | unreadable. Empty = not judged (no NVIDIA driver on the host yet).
TB_GPU_FLOOR_VERDICT=""
# 1 once an NVIDIA GPU is wired into this cluster, else 0. Assigned, never
# defaulted from the environment: only the installer's own GPU steps may set it.
TB_GPU_WIRED=0
PM_INSTALL=""
PM_UPDATE=""

# True when an NVIDIA GPU has been WIRED INTO THIS CLUSTER — not merely detected.
# TB_GPU_WIRED becomes 1 only once the container runtime is ready to expose the
# GPU (gpu-nvidia.sh / setup-linux.sh::_tier0_gpu_flags), the k3d node is then
# created from the GPU-capable image with --gpus=all (k3d.sh, which derives
# that flag from this gate), and the reuse guard puts it back to 0 when an
# existing cluster turns out to be a CPU-only node. So this is the one honest
# gate for "should we request a GPU for jobs" — the same role the Windows twin's
# `$K3D_GPU_FLAG -ne ""` plays. Requesting nvidia.com/gpu on a node that
# advertises 0 GPUs strands every job Pending (client#835), so the GPU chart
# values (install-client-helm.sh) ride this, not bare GPU_VENDOR detection.
# Wired means exactly GPU_VENDOR=nvidia and TB_GPU_WIRED=1; any other value of
# either is "not wired". set -u safe: a unit test that sources only a single lib
# may not have TB_GPU_WIRED, so it defaults here.
_gpu_wired() {
  [[ "${GPU_VENDOR:-}" == "nvidia" && "${TB_GPU_WIRED:-0}" == "1" ]]
}

# True when detect_gpu's floor verdict skips the GPU: below-compute (the card is too
# old for the images) or unreadable (cannot tell). The GPU steps then install no
# toolkit and never set TB_GPU_WIRED, so the install runs CPU-only; detect_gpu has
# already printed why and the remedy. below-driver does NOT skip: detect_gpu warned,
# and the GPU is wired (Lukas, 2026-09-30, client-dev#1355: the floor is advice until
# spike S-G measures it). Not judged (no driver yet, the driver-install path) is not
# a skip either.
_gpu_floor_skips() {
  case "${TB_GPU_FLOOR_VERDICT:-}" in
    below-compute|unreadable) return 0 ;;
  esac
  return 1
}

# ── Failure diagnostics (client#681) ─────────────────────────────────────────
#  Under `set -euo pipefail` a command that fails outside an if/&&/|| context
#  kills the installer with NO output at all: the user got a generic "did not
#  complete", and the install log — which is the WHOLE session tee'd — recorded
#  nothing about why. A single ERR trap records where it died so both the log
#  and the closer can name it. This is the bash counterpart of install-k8s.ps1's
#  Show-FatalError (#577).
#
#  install-k8s.sh arms this with `set -E` (errtrace) so the trap is inherited by
#  functions and subshells — without it an ERR trap fires only at top level, and
#  every failure inside install_macos/install_linux (i.e. nearly all of them)
#  would still be invisible.
TB_ERR_LOC=""    # "file:line" of the LAST failing command — see _record_err
_TB_IN_RECORD_ERR=""   # re-entrancy guard; the recorder inherits its own trap
TB_ERR_CMD=""    # what failed. TWO producers, and they differ — read on before
                 # writing a message that ends up here.
                 #
                 #   ERR trap  → BASH_COMMAND, i.e. the command text UNEXPANDED:
                 #               `cmd "$VAR"`, never the value.
                 #   error()   → "error: $*", i.e. the message AS INTERPOLATED,
                 #               because a deliberate refusal fires no ERR trap
                 #               and would otherwise leave a benign probe here
                 #               (#741).
                 #
                 # So the old blanket "this cannot leak a credential into the
                 # log" no longer holds for the error() path, and TB_ERR_CMD
                 # reaches LOG_FILE twice — via _record_err and via
                 # install_cleanup's `FAILED at … command:` line.
                 #
                 # Every error() call today interpolates only paths, sizes,
                 # versions and arch names (audited on #741). Keep it that way:
                 # NEVER interpolate a credential, token or password into an
                 # error() message. If you need one in the text, say
                 # "the credential file at $path", not the value.
TB_ERR_CODE=""   # its exit status (137/141/… included: a signal death is a failure)

# _record_err LOCATION COMMAND — ERR-trap body. Everything it needs about the
# failure is passed IN, because none of it survives being read from in here:
#   • `$?` must still be the FAILING command's status, so the trap calls this as
#     its very first command (parameter expansions cannot disturb `$?`);
#   • BASH_SOURCE/LINENO inside this function describe common.sh, not the site
#     that failed;
#   • BASH_COMMAND tracks the CURRENTLY executing command, so by the time this
#     function runs its own first test it already reads as that test, not as the
#     command that failed.
# Always returns 0 — a recorder that failed would re-enter the trap.
_record_err() {
  local _code=$?
  # $3 overrides the implicit $?. The ERR trap has a meaningful $? and passes
  # nothing; error() does not (its $? is whatever preceded the call) and passes
  # the 1 it is about to exit with. Read before any other statement, or $? is
  # already clobbered.
  _code="${3:-$_code}"
  # Re-entrancy guard. `set -E` makes this function inherit the ERR trap, so any
  # command in here that fails would re-enter it — including `log` below, whose
  # `[[ -n "${LOG_FILE:-}" ]] && …` form returns non-zero when no log is open.
  # Every test also sits inside an `if` block for the same reason: a bare
  # `[[ … ]] && return 0` FAILS when the condition is false, which re-enters the
  # trap and records the guard itself as the failing command.
  if [[ -n "$_TB_IN_RECORD_ERR" ]]; then return 0; fi
  _TB_IN_RECORD_ERR=1

  # LAST failure wins — deliberately, and this is the whole point of the record.
  #
  # The ERR trap fires for EVERY failing command, including ones whose failure is
  # the expected answer: `_probe_privilege` runs `sudo -n true` and reads its
  # non-zero exit as "a password is needed", then prints that as a normal row in
  # the host check. First-wins latched onto exactly that probe and refused every
  # later record, so a run that died two steps afterwards reported the location of
  # a routine probe inside a step that SUCCEEDED — a wrong answer stated
  # confidently, which is worse than the blank screen it replaced.
  #
  # Last-wins is precise here because errexit stops the script AT the fatal
  # command and the trap fires once per failing command, with no per-frame
  # re-firing as the error unwinds — verified on bash 3.2 (macOS) and 5.x.
  TB_ERR_CODE="$_code"
  TB_ERR_LOC="${1:-?}"
  TB_ERR_CMD="${2:-}"

  # The full trail, log only. The benign entries are not noise: they are how you
  # tell a probe that always fails from the command that actually ended the run,
  # and reading them in order is what identified this bug.
  log "err: ${TB_ERR_LOC} exit=${TB_ERR_CODE} cmd=${TB_ERR_CMD}"

  _TB_IN_RECORD_ERR=""
  return 0
}

# ── Private scratch directories (backend#4279) ───────────────────────────────
#  A download that lands under a FIXED name in /tmp can be written through by
#  another local account: /tmp is sticky, so a symlink someone else planted at
#  that name survives our `rm -f` (it fails silently — we don't own the entry)
#  and `curl -o` then writes wherever it points, as us. So every download and
#  scratch file goes in a directory mktemp just made for this run: ours, 0700,
#  with a name nobody could predict. On macOS TMPDIR is already per-user.
#
#  tb_scratch_dir VAR PREFIX — make the directory, assign its path to VAR, and
#  register it so install_cleanup removes it on ANY exit (error()'s exit 1, a
#  Ctrl-C, set -e). Registered rather than trapped: one EXIT trap per process,
#  and it is install_cleanup's. Trailing X's only — BSD mktemp needs them last.
#  Fails (non-zero, VAR untouched) when no directory could be made; the caller
#  decides, because writing to a fixed /tmp name instead is the bug this fixes.
#  tb_scratch_rm DIR — remove one now (the success path) and unregister it.
_TB_SCRATCH_DIRS="${_TB_SCRATCH_DIRS:-}"   # newline-separated, registration order
tb_scratch_dir() {
  local __var="$1" __prefix="$2" __dir
  __dir="$(mktemp -d "${TMPDIR:-/tmp}/${__prefix}-XXXXXX" 2>/dev/null)" || return 1
  [[ -n "$__dir" && -d "$__dir" ]] || return 1
  _TB_SCRATCH_DIRS="${_TB_SCRATCH_DIRS}${__dir}"$'\n'
  printf -v "$__var" '%s' "$__dir"
}
tb_scratch_rm() {
  local __dir="$1" __d __keep=""
  [[ -n "$__dir" ]] || return 0
  rm -rf "$__dir" 2>/dev/null || true
  while IFS= read -r __d; do
    [[ -n "$__d" && "$__d" != "$__dir" ]] && __keep="${__keep}${__d}"$'\n'
  done <<<"$_TB_SCRATCH_DIRS"
  _TB_SCRATCH_DIRS="$__keep"
}
# Reap every registered directory. Called from the EXIT traps; never fails.
tb_scratch_reap() {
  local __d
  while IFS= read -r __d; do
    [[ -n "$__d" ]] && { rm -rf "$__d" 2>/dev/null || true; }
  done <<<"$_TB_SCRATCH_DIRS"
  _TB_SCRATCH_DIRS=""
  return 0
}

# _tb_spin_logfile — sets _TB_SPIN_LOG to where the spinner helpers append a
# command's output: LOG_FILE once setup_log_file has run (every real install
# path), else a private mktemp file made once per shell. The old fallback was a
# fixed /tmp/tracebloc-spin.log appended with `>>`, which follows a planted
# symlink the same way (backend#4279). /dev/null only if mktemp itself fails.
_tb_spin_logfile() {
  if [[ -n "${LOG_FILE:-}" ]]; then _TB_SPIN_LOG="$LOG_FILE"; return 0; fi
  [[ -n "${_TB_SPIN_LOG:-}" && -f "$_TB_SPIN_LOG" ]] && return 0
  _TB_SPIN_LOG="$(mktemp "${TMPDIR:-/tmp}/tracebloc-spin-XXXXXX" 2>/dev/null)" || _TB_SPIN_LOG=""
  [[ -n "$_TB_SPIN_LOG" ]] || _TB_SPIN_LOG=/dev/null
  return 0
}

# ── Cleanup on exit ──────────────────────────────────────────────────────────
install_cleanup() {
  local exit_code=$?
  # Stop recording before doing anything else. This handler's own lines can fail
  # (a `kill` on a dead pid, an `[[ … ]]` that is simply false), and with `set -E`
  # each of those fires the ERR trap — which under last-wins would overwrite the
  # fatal command with a cleanup detail before the report below ever reads it.
  trap - ERR
  [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  # Never leave the transient machine credential on disk (#838): provision.sh sets
  # _PROVISION_CRED_FILE before minting and removes it after sourcing — this is the
  # backstop for an error/signal between mint and that cleanup.
  [[ -n "${_PROVISION_CRED_FILE:-}" ]] && rm -f "$_PROVISION_CRED_FILE" 2>/dev/null || true
  # The private download/scratch directories (backend#4279): a fatal error mid
  # download must not leave a ~600 MB Docker.dmg behind in the user's TMPDIR.
  declare -F tb_scratch_reap >/dev/null 2>&1 && tb_scratch_reap
  # Record WHERE it died, always and first (client#681). The log is the artifact
  # users send to support, and until now a `set -e` death left it with no trace of
  # the failure at all. Logged even on the exit-2 / interrupted paths, so a
  # re-run-required stop that was actually caused by an error is still traceable.
  if [[ -n "${TB_ERR_CODE:-}" ]]; then
    log "FAILED at ${TB_ERR_LOC} — exit ${TB_ERR_CODE} — command: ${TB_ERR_CMD}"
  fi
  if [[ $exit_code -eq 2 ]]; then
    echo ""
    hint "Re-run required. Complete the step above, then run the script again."
    [[ -n "${LOG_FILE:-}" ]] && hint "Logs: $LOG_FILE"
  elif [[ $exit_code -eq 130 || $exit_code -eq 143 ]]; then
    # Interrupted, not broken (client#681). install-k8s.sh routes SIGINT/SIGTERM
    # through `exit 130`/`exit 143` so this trap still shreds the transient
    # credential — but funnelling those into "did not complete" told users their
    # own Ctrl-C was an installer failure, and made an interrupted run
    # indistinguishable from a real one in the log. Mirrors Show-Interrupted (#577).
    echo ""
    warn "Installation was interrupted before it finished."
    [[ -n "${LOG_FILE:-}" ]] && hint "Log: $LOG_FILE"
    hint "Nothing is broken — this installer is safe to re-run."
  elif [[ $exit_code -ne 0 ]]; then
    # If print_summary already reported a specific outcome (CLIENT_STATE set),
    # don't tack on a second, generic "did not complete" message.
    if [[ -z "${CLIENT_STATE:-}" ]]; then
      echo ""
      warn "Installation did not complete."
      # Name the failing site on screen too. The command text stays in the log
      # only: it is unexpanded, but it is still installer internals, and the
      # PowerShell side deliberately shows a reason without a stack trace (#577).
      if [[ -n "${TB_ERR_CODE:-}" ]]; then
        hint "Stopped at ${TB_ERR_LOC} (exit ${TB_ERR_CODE})."
      fi
      [[ -n "${LOG_FILE:-}" ]] && hint "Check the install log: $LOG_FILE"
      hint "This installer is safe to re-run — just try again."
      hint "If it keeps failing, re-run with --diagnose and send the bundle to tracebloc support."
    fi
  fi

  # One structured outcome event per install (backend#1907). Emitted LAST, from
  # the EXIT trap, so it runs on every path — success, the re-run-required stop,
  # Ctrl-C, and the fatal one — which is what §6.5 of the telemetry contract
  # requires and what makes a failure RATE computable rather than just a count.
  # Everything it reads (CLIENT_STATE, TB_ERR_*, the phase clock) is final by
  # this point. Guarded for an older bootstrap that did not fetch telemetry.sh.
  if declare -F telemetry_emit_outcome >/dev/null 2>&1; then
    telemetry_emit_outcome "$exit_code" || true
  fi
}

# Installer version shown in the banner's title (" · <version>"). The curl|bash
# bootstrap (install.sh) exports TRACEBLOC_INSTALL_REF — the immutable release tag
# it pinned to, e.g. v1.9.3 — so the title states exactly what is being installed.
# On the direct ./install-k8s.sh path it's unset and the title drops the suffix.
TB_VERSION="${TB_VERSION:-${TRACEBLOC_INSTALL_REF:-}}"

# ── The installer contract: substrate switch, substrate line, install record ─
#  scripts/spec/install-record.schema.json is the one declaration. The
#  values below are STAMPED from it (the bootstrap ships no spec file), and
#  install-contract.bats holds each one to the schema:
#    TB_SUBSTRATES                  properties.substrate.enum, space-separated
#    TB_SUBSTRATE_DEFAULT           x-tracebloc-substrate.default
#    TB_SUBSTRATE_TOKEN_PREFIX      x-tracebloc-substrate.token-prefix
#    TB_SUBSTRATE_TOKEN_UNSUPPORTED x-tracebloc-substrate.token-unsupported
#    TB_INSTALL_RECORD_VERSION      properties.schema_version.const
#    TB_ARTEFACT_KINDS              $defs.artefact.properties.kind.enum, space-separated
#    TB_RECORD_USER_PATH            x-tracebloc-record.user-path (a leading ~ is $HOME)
#    TB_RECORD_ROOT_PATH            x-tracebloc-record.root-path (<user> is the login name)
TB_SUBSTRATES="k3d"
TB_SUBSTRATE_DEFAULT="k3d"
TB_SUBSTRATE_TOKEN_PREFIX="tracebloc-installer substrate="
TB_SUBSTRATE_TOKEN_UNSUPPORTED="unsupported"
TB_INSTALL_RECORD_VERSION=1
TB_ARTEFACT_KINDS="k3d-cluster binary launch-agent launch-daemon helm-release"
# shellcheck disable=SC2088  # a template: tb_record_path substitutes the ~, never the shell
TB_RECORD_USER_PATH="~/.tracebloc/install-record.json"
TB_RECORD_ROOT_PATH="/var/lib/tracebloc/<user>/install-record.json"
# The substrate this run was asked for: TRACEBLOC_SUBSTRATE, else the default
# (blank means unset, as for every TRACEBLOC_* setting). There is no flag and no
# alias. main() refuses a value outside TB_SUBSTRATES, by name, AFTER the
# substrate line has printed.
TB_SUBSTRATE="${TRACEBLOC_SUBSTRATE:-$TB_SUBSTRATE_DEFAULT}"

tb_substrate_supported() {
  local s
  for s in $TB_SUBSTRATES; do
    [[ "$s" == "${TB_SUBSTRATE:-}" ]] && return 0
  done
  return 1
}

# The substrate line: one line, fixed grammar, no colour, so a harness can read it
# from the installer's own output. It names the substrate this run resolved, or
# the "unsupported" sentinel, never the raw request: a free-form value must not
# be able to bend the grammar.
tb_substrate_token() {
  if tb_substrate_supported; then
    printf '%s%s\n' "$TB_SUBSTRATE_TOKEN_PREFIX" "$TB_SUBSTRATE"
  else
    printf '%s%s\n' "$TB_SUBSTRATE_TOKEN_PREFIX" "$TB_SUBSTRATE_TOKEN_UNSUPPORTED"
  fi
}

# Printed by main() before anything that can refuse; setup_log_file copies it
# into the install log once that exists.
print_substrate_token() {
  tb_substrate_token
  TB_SUBSTRATE_TOKEN_PRINTED=1
}

refuse_unsupported_substrate() {
  tb_substrate_supported && return 0
  error "TRACEBLOC_SUBSTRATE='${TB_SUBSTRATE}' is not a runtime this installer can set up (it supports: ${TB_SUBSTRATES// /, }). Unset it to use ${TB_SUBSTRATE_DEFAULT}."
}

# ── Install record ──────────────────────────────────────────────────────────
#  What this install created, for an uninstall to remove exactly that. Written
#  as the install goes: tb_record_write KIND ID PATH records one artefact the
#  moment it exists, and tb_record_write alone refreshes the other fields. The
#  format is fixed (one artefact object per line) because the writer reads its
#  own previous output back: an artefact an earlier run recorded is kept, and so
#  is a field this run has not decided yet. No jq or python3 on this path.
#  Best-effort: a record that cannot be written is logged, never fatal.
#  Written only once main() has armed it, after the refusals, when the run is
#  committed to installing. Assigned here, never read from the environment: a
#  library function a unit test or a harness calls directly writes nothing.
TB_RECORD_ARMED=""
TB_RECORD_REFRESH_ONLY=""
# The user copy: x-tracebloc-record.user-path, its leading ~ as $HOME.
tb_record_path() { printf '%s%s' "${HOME:-}" "${TB_RECORD_USER_PATH#\~}"; }

# The root copy for login name $1: x-tracebloc-record.root-path with <user> filled
# in. TB_RECORD_ROOT_DIR, a test seam, replaces the directory above <user>.
_tb_record_root_path() {
  printf '%s/%s%s' "${TB_RECORD_ROOT_DIR:-${TB_RECORD_ROOT_PATH%%/<user>*}}" "$1" "${TB_RECORD_ROOT_PATH#*<user>}"
}

# $1 as a JSON string literal, or null when empty.
_tb_json() {
  if [[ -z "${1:-}" ]]; then printf 'null'; return 0; fi
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# The JSON literal a previous write left for top-level KEY ($1) in record text $2.
_tb_record_prior() {
  local v
  v="$(printf '%s\n' "$2" | sed -n "s/^  \"$1\": \(.*[^,]\),\{0,1\}\$/\1/p")"
  printf '%s' "${v%%$'\n'*}"
}

# Top-level field KEY ($1): this run's value ($2) wins, else the value the
# previous write left in record text $3, else null. A CLI-only refresh
# (TB_RECORD_REFRESH_ONLY=1) never saw the install's facts: what it has for
# them is a default (CLUSTER_NAME, HOST_DATA_DIR), so the prior value wins.
_tb_record_field() {
  local p; p="$(_tb_record_prior "$1" "${3:-}")"
  if [[ "${TB_RECORD_REFRESH_ONLY:-}" == "1" && -n "$p" ]]; then printf '%s' "$p"; return 0; fi
  if [[ -n "${2:-}" ]]; then _tb_json "$2"; return 0; fi
  printf '%s' "${p:-null}"
}

tb_record_write() {
  [[ "${TB_RECORD_ARMED:-}" == "1" && -n "${HOME:-}" ]] || return 0
  local rec dir now prior="" arts="" root_copy
  rec="$(tb_record_path)"; dir="${rec%/*}"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$dir" 2>/dev/null || { log "Install record: couldn't create ${dir}; not recorded."; return 0; }
  if [[ -f "$rec" ]]; then prior="$(cat "$rec" 2>/dev/null || true)"; fi
  arts="$(printf '%s\n' "$prior" | sed -n 's/^    \({"kind": .*}\),\{0,1\}$/\1/p')"
  if [[ -n "${1:-}" ]]; then
    # A kind the schema does not declare would make the whole record invalid, so
    # it is refused by name and the record keeps what it had.
    case " ${TB_ARTEFACT_KINDS} " in
      *" $1 "*) ;;
      *) log "Install record: '${1}' is not an artefact kind the schema declares; not recorded."; return 0 ;;
    esac
    # Keyed on kind + id + path: a re-run that finds it already recorded keeps
    # the first created_at.
    local key
    key="{\"kind\": $(_tb_json "$1"), \"id\": $(_tb_json "${2:-}"), \"path\": $(_tb_json "${3:-}"), "
    case "$arts" in
      *"$key"*) ;;
      *) arts="${arts:+${arts}$'\n'}${key}\"created_at\": \"${now}\"}" ;;
    esac
  fi
  # A CLI-only refresh keeps the recorded substrate too: TB_SUBSTRATE there is
  # the default this process resolved, not the runtime the install set up.
  local substrate p_sub
  substrate="$(_tb_json "$TB_SUBSTRATE")"
  if [[ "${TB_RECORD_REFRESH_ONLY:-}" == "1" ]]; then
    p_sub="$(_tb_record_prior substrate "$prior")"
    if [[ -n "$p_sub" ]]; then substrate="$p_sub"; fi
  fi
  # root_copy: the root copy's path once one exists. The previous write's value
  # stands until this run writes the copy; the first write that does re-renders
  # the user copy with it and copies again, so the two copies stay identical.
  root_copy="$(_tb_record_field root_copy "" "$prior")"
  _tb_record_put "$rec" "$(_tb_record_render "$substrate" "$prior" "$arts" "$now" "$root_copy")" || return 0
  _TB_RECORD_ROOT_WRITTEN=""
  _tb_record_root_copy "$rec"
  if [[ -n "$_TB_RECORD_ROOT_WRITTEN" && "$(_tb_json "$_TB_RECORD_ROOT_WRITTEN")" != "$root_copy" ]]; then
    root_copy="$(_tb_json "$_TB_RECORD_ROOT_WRITTEN")"
    _tb_record_put "$rec" "$(_tb_record_render "$substrate" "$prior" "$arts" "$now" "$root_copy")" || return 0
    _tb_record_root_copy "$rec"
  fi
  return 0
}

# The record's text: SUBSTRATE ($1) and ROOT_COPY ($5) as JSON literals, the
# previous write's text ($2), its artefact lines ($3) and the time ($4).
_tb_record_render() {
  local out line n i
  out="{
  \"schema_version\": ${TB_INSTALL_RECORD_VERSION},
  \"substrate\": $1,
  \"user\": $(_tb_record_field user "$(id -un 2>/dev/null || printf '%s' "${USER:-}")" "$2"),
  \"cluster_name\": $(_tb_record_field cluster_name "${CLUSTER_NAME:-}" "$2"),
  \"kube_context\": $(_tb_record_field kube_context "${TB_KUBE_CONTEXT:-}" "$2"),
  \"data_dir\": $(_tb_record_field data_dir "${HOST_DATA_DIR:-}" "$2"),
  \"namespace\": $(_tb_record_field namespace "${TB_NAMESPACE:-}" "$2"),
  \"installer_version\": $(_tb_record_field installer_version "${TB_VERSION:-}" "$2"),
  \"root_copy\": $5,
  \"updated_at\": \"$4\","
  if [[ -z "$3" ]]; then
    out+=$'\n  "artefacts": []\n}'
  else
    out+=$'\n  "artefacts": ['
    n="$(printf '%s\n' "$3" | wc -l | tr -d ' ')"; i=0
    while IFS= read -r line; do
      i=$((i + 1))
      out+=$'\n    '"$line"
      if [[ "$i" -lt "$n" ]]; then out+=","; fi
    done <<<"$3"
    out+=$'\n  ]\n}'
  fi
  printf '%s' "$out"
}

# Write record text $2 to the user copy $1 atomically. Non-zero (logged) when it
# could not; the caller stops there.
_tb_record_put() {
  local tmp
  tmp="$(mktemp "${1%/*}/.install-record.XXXXXX" 2>/dev/null)" || { log "Install record: couldn't write in ${1%/*}; not recorded."; return 1; }
  if printf '%s\n' "$2" >"$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null; then return 0; fi
  rm -f "$tmp" 2>/dev/null
  log "Install record: couldn't write ${1}; not recorded."
  return 1
}

# Linux keeps a root copy for sudo and headless uninstalls, at
# x-tracebloc-record.root-path (/var/lib/tracebloc/<user>/install-record.json).
# Written only as root, or with a sudo that needs no password; Tier 0 promised no
# administrator rights and gets none. Never prompts, never fails the install.
# Sets _TB_RECORD_ROOT_WRITTEN to the copy's path when this call wrote it.
_tb_record_root_copy() {
  [[ "${OS:-$(uname -s 2>/dev/null)}" == "Linux" ]] || return 0
  [[ "${INSTALL_TIER:-}" != "0" ]] || return 0
  local user dst
  user="$(id -un 2>/dev/null)" || return 0
  [[ -n "$user" ]] || return 0
  dst="$(_tb_record_root_path "$user")"
  # A CLI-only refresh runs before the tier is known, so the Tier 0 guard above
  # cannot see it: it refreshes a root copy a full install made and never creates one.
  if [[ "${TB_RECORD_REFRESH_ONLY:-}" == "1" ]] && ! _tb_record_root_copy_exists "$dst"; then return 0; fi
  if [[ "$(id -u 2>/dev/null)" == "0" ]]; then
    if { mkdir -p "${dst%/*}" && cp "$1" "$dst"; } 2>/dev/null; then _TB_RECORD_ROOT_WRITTEN="$dst"
    else log "Install record: couldn't write the root copy ${dst}."; fi
  elif _have_sudo_bin && _real_sudo -n true 2>/dev/null; then
    if { _real_sudo -n mkdir -p "${dst%/*}" && _real_sudo -n cp "$1" "$dst"; } 2>/dev/null; then _TB_RECORD_ROOT_WRITTEN="$dst"
    else log "Install record: couldn't write the root copy ${dst}."; fi
  fi
  return 0
}

# Whether the root copy $1 exists, looked up the way it is written: as root, or
# through a password-free sudo. As the user, its directory is unreadable (made
# through sudo under umask 077), so a plain -f would always answer "absent".
_tb_record_root_copy_exists() {
  if [[ "$(id -u 2>/dev/null)" == "0" ]]; then [[ -f "$1" ]]; return; fi
  _have_sudo_bin && _real_sudo -n test -f "$1" 2>/dev/null
}

# ── Banner ───────────────────────────────────────────────────────────────────
#  The first-run title: "Setting up tracebloc on your machine · <version>".
#  In the curl|bash path the bootstrap (install.sh) already drew this above its
#  "1. Downloading" section and exported TRACEBLOC_BANNER_SHOWN, so we don't draw
#  a second one; on the direct ./install-k8s.sh path we draw it here.
print_banner() {
  if [[ -n "${TRACEBLOC_BANNER_SHOWN:-}" ]]; then
    log "Banner already shown by the bootstrap — not redrawing."
    log "OS=$OS  Arch=$ARCH  Cluster='$CLUSTER_NAME'"
    return 0
  fi
  echo ""
  echo ""
  if [[ -n "${TB_VERSION:-}" ]]; then
    echo -e "  Setting up ${BOLD}${CYAN}tracebloc${RESET} on your machine${DIM} · ${TB_VERSION}${RESET}"
  else
    echo -e "  Setting up ${BOLD}${CYAN}tracebloc${RESET} on your machine"
  fi
  echo ""
  echo -e "  ${DIM}────────────────────────────────────────${RESET}"
  echo ""
  log "OS=$OS  Arch=$ARCH  Cluster='$CLUSTER_NAME'"
  log "Host data dir: $HOST_DATA_DIR → /tracebloc (inside k3s nodes)"
}

# ── Step roadmap — the "2. Installing" plan, printed once before install begins ─
#  Section 1 ("1. Downloading") is the bootstrap's download+verify; this is the
#  a–f plan for everything install-k8s.sh does. The running steps use the gerund
#  form ("Checking your machine", …) via step_header.
print_roadmap() {
  echo -e "  ${BOLD}2. Installing${RESET}"
  echo ""
  echo -e "  ${DIM}a) Check your machine${RESET}"
  echo -e "  ${DIM}b) Install what tracebloc needs${RESET}"
  echo -e "  ${DIM}c) Create your secure environment${RESET}"
  echo -e "  ${DIM}d) Register this machine${RESET}"
  echo -e "  ${DIM}e) Install tracebloc${RESET}"
  echo -e "  ${DIM}f) Connect to the tracebloc network${RESET}"
  echo ""
  echo ""
}

# ── Help ─────────────────────────────────────────────────────────────────────
print_help() {
  cat <<'HELP'
tracebloc — client setup

  Set up a secure compute environment on your machine
  and connect it to the tracebloc network.

Usage:
  curl -fsSL https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.sh | bash
  ./install-k8s.sh [--help] [--diagnose] [--force] [--reuse-data|--wipe-data|--data-dir=PATH]

Commands:
  --diagnose     Collect a redacted support bundle (logs + cluster/host status)
                 into ~/.tracebloc/tracebloc-diagnose-<timestamp>.tgz and exit.
                 Run this if something went wrong, then send the file to support
                 (passwords and proxy credentials are removed before it is written).
  --force        Skip the "already set up" check and re-run every step. Use this
  --reinstall    to force a full reinstall on a machine that is already set up.
                 (Same effect as TRACEBLOC_FORCE_REINSTALL=1 for curl | bash.)

Leftover data (a new install onto a machine that still holds old data):
  By default the installer STOPS and asks rather than silently adopting it.
  --reuse-data   Keep and adopt the existing data (non-interactive).
  --wipe-data    Delete the existing data and start fresh (non-interactive).
  --data-dir=P   Install into directory P instead (leaves old data untouched).
                 (Bypass the guard entirely with TRACEBLOC_SKIP_LEFTOVER_GUARD=1.)

Advanced configuration (environment variables):
  CLUSTER_NAME   Cluster name                   (default: tracebloc)
  TRACEBLOC_NAMESPACE  Secure-environment name  (default: tracebloc; legacy: TB_NAMESPACE)
  SERVERS        Control-plane nodes             (default: 1)
  AGENTS         Worker nodes                    (default: 1)
  K8S_VERSION    k3s image tag                   (default: v1.36.3-k3s1)
  K3D_VERSION    k3d release tag                 (default: v5.9.0; "latest" resolves at install time)
  HELM_VERSION   Helm release tag                (default: v4.2.3; "latest" resolves at install time)
  TRACEBLOC_HOST_DATA_DIR  Persistent data directory  (default: ~/.tracebloc; legacy: HOST_DATA_DIR)
                 Must be on a LOCAL disk — NFS/CIFS/SMB is rejected (the database
                 corrupts on network storage). TRACEBLOC_ALLOW_NETWORK_FS=1 overrides.

Usage reporting:
  This installer records ONE outcome event per run so we can see failures without
  waiting for someone to report them: which step it reached, how long each step
  took, the exit code, an error class, your OS and architecture, and the version.
  It cannot record your arguments, any path, any file name, your username, your
  hostname or your credentials — every field is a number or a value from a fixed
  list, so there is nowhere for those to go.
  TRACEBLOC_SKIP_TELEMETRY=1  Turn it off.
  TRACEBLOC_NO_TELEMETRY=1    Also turns it off (legacy name).
  DO_NOT_TRACK=1              Also turns it off.

Windows:
  irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex

Learn more: https://docs.tracebloc.io
HELP
  exit 0
}
