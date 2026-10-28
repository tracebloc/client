#!/usr/bin/env bash
# =============================================================================
#  common.sh — Shared colours, logging helpers, configuration defaults,
#              retry logic, and log-file setup
# =============================================================================

# ── Security hardening ───────────────────────────────────────────────────────
# The launching shell's PATH, read before the prepend below (install.sh sets it
# first on the curl|bash path; this covers install-k8s.sh run directly). See
# install-cli.sh _cli_on_launch_path.
# A bootstrap older than this file never set it, and has already put ~/.local/bin in
# front of PATH: that entry is the installer's, not the user's, so it is dropped from
# the capture. The cost is one conservative "open a new terminal" for a user whose
# own PATH starts with ~/.local/bin and who pairs a stale bootstrap with these libs.
# A bootstrap from before backend#3846 hands the capture over as TB_LAUNCH_PATH
# alone: read it as the fallback (remove_by 2026-12-31). Exported under the
# canonical name only: every reader is this core, which reads it first.
TRACEBLOC_LAUNCH_PATH="${TRACEBLOC_LAUNCH_PATH:-${TB_LAUNCH_PATH:-}}"
if [[ -z "$TRACEBLOC_LAUNCH_PATH" ]]; then
  TRACEBLOC_LAUNCH_PATH="${PATH:-}"
  TRACEBLOC_LAUNCH_PATH="${TRACEBLOC_LAUNCH_PATH#"${HOME}/.local/bin:"}"
fi
export TRACEBLOC_LAUNCH_PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
# In a bats run only, the suite's sudo fence goes back in front of the directories
# just prepended. Behind them, a case that dropped its own sudo stub would run the
# host's sudo (scripts/tests/setup_suite.bash). An install never sets either.
if [[ -n "${TRACEBLOC_HERMETIC_SUDO_BIN:-}" && -n "${BATS_SUITE_TMPDIR:-}" ]]; then
  export PATH="${TRACEBLOC_HERMETIC_SUDO_BIN}:${PATH}"
fi
umask 077

# ── Settings naming: the TRACEBLOC_ spellings of the tuning knobs ────────────
# backend#3846. Every timeout, wait and bound below can be set as
# TRACEBLOC_<name> -- the TB_ prefix REPLACED (TB_PULL_TIMEOUT ->
# TRACEBLOC_PULL_TIMEOUT), an unprefixed name prefixed (SIGN_IN_ATTEMPTS ->
# TRACEBLOC_SIGN_IN_ATTEMPTS). The old spelling still works (remove_by 2026-12-31).
# A non-empty canonical is copied, ONCE and here at the top of the core, into
# the legacy-named variable every reader across scripts/lib reads inline
# (`${TB_PULL_TIMEOUT:-600}`), so those dozens of reads, their defaults and
# their blank-means-default behaviour are unchanged; a blank canonical is unset.
# Nothing here is exported, so no child sees a value its parent did not.
tb_tuning_aliases=(
  TB_API_WAIT_S
  TB_ASSESS_KUBECTL_TIMEOUT TB_CLI_MIN_VERSION TB_CLI_PROBE_TIMEOUT
  TB_CURL_CONNECT_TIMEOUT TB_CURL_MAX_TIME
  TB_GPU_CDI_TIMEOUT TB_GPU_PROFILER_TIMEOUT
  TB_HELM_LIST_TIMEOUT TB_HELM_TIMEOUT_MIN TB_HELM_VALUES_TIMEOUT TB_INSTALL_CMD
  TB_K3S_CRI_TIMEOUT TB_K3S_INSTALL_SH_TIMEOUT
  TB_METRICS_WAIT_S
  TB_PLAIN TB_PM_KILL_GRACE TB_PROBE_TIMEOUT
  TB_PROGRESS_KUBECTL_TIMEOUT TB_PULL_TIMEOUT
  TB_WSL_INTEROP_KILL_AFTER TB_WSL_INTEROP_TIMEOUT
  GPU_DEVICE_PLUGIN_NAMESPACE SIGN_IN_ATTEMPTS
)
# tb_canonical_name LEGACY -- the TRACEBLOC_ spelling the naming rule gives.
tb_canonical_name() {
  case "$1" in
    TB_*) printf 'TRACEBLOC_%s' "${1#TB_}" ;;
    *)    printf 'TRACEBLOC_%s' "$1" ;;
  esac
}
# tb_resolve_tuning_aliases -- copy each non-empty canonical onto its legacy name.
tb_resolve_tuning_aliases() {
  local _legacy _canon
  for _legacy in "${tb_tuning_aliases[@]}"; do  # set-u-safe: a literal list, declared just above
    _canon="$(tb_canonical_name "$_legacy")"
    if [[ -n "${!_canon:-}" ]]; then printf -v "$_legacy" '%s' "${!_canon}"; fi
  done
}
tb_resolve_tuning_aliases

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
# Bugbot caught that this still hardcoded production at ten sites while
# `_backend_url` was correctly env-aware — so a `CLIENT_ENV=dev` install on Linux
# or macOS still sent the operator to ai.tracebloc.io for credentials `dev-api`
# then rejects. (The retired PowerShell core had been fixed first.)
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
# get it by construction rather than by accident.
#
# The hosts are the backend's OWN per-environment settings, not a guess:
# DEVICE_VERIFICATION_URI / RESET_PASSWORD_URL in
# xraybackend/settings/{dev,stg,prod}.py resolve to dev.tracebloc.io,
# stg.tracebloc.io and ai.tracebloc.io. Same `tb_client_env` alias reduction and
# the same unknown->prod fallback as `_backend_url`, so the two can never
# disagree about which environment an install belongs to.
#
#   $1 = path under the dashboard (default "secure-environment"; pass "" for the bare host)
#
# The default is My Secure Environment, the page that shows this client and
# whether it is connected. It was "clients" until the Clients page retired
# (frontend-app#2277): /clients now only redirects there.
_dashboard_url() {
  local path="${1-secure-environment}" base
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

# _credential_file_cmd / _credential_file_load_cmd — where a secure environment's
# Client ID and password come from, for every line that tells someone. The
# Clients page that showed them is retired (frontend-app#2277), and My Secure
# Environment shows neither. An interactive install needs no pair at all:
# provision_client signs in through the browser. An unattended one creates the
# pair on a machine signed in to tracebloc, which writes it to tb.env, then loads
# that file in the shell it installs from (docs: environment-setup/setup-guide).
# Here, not in install-client-helm.sh, for the reason `_dashboard_url` is: the
# summary's bad_creds outcome prints it too, and summary.sh sources neither
# sibling. common.bats holds every bash lib to spelling the commands only here.
_credential_file_cmd()      { printf '%s' 'tracebloc client create --no-cluster --yes --credential-file tb.env'; }
_credential_file_load_cmd() { printf '%s' 'set -a; . ./tb.env; set +a'; }

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
  # TRACEBLOC_MIN_DOWNLOAD_BYTES overrides the floor (set to 0 by the bats fetch tests,
  # whose curl mocks write tiny fixture files); unset in production, so the real
  # per-tool floor passed as $2 applies. $4 (optional) is the caller's mktemp -d
  # tree to remove before erroring, so a truncated transfer cleans up its partial
  # payload exactly like the checksum-mismatch branches do (Bugbot). $5 (optional)
  # names the hosts to allowlist when the download does not come from the tool hosts
  # below (the Apple container kernel is pulled from ghcr.io).
  local file="$1" min="${TRACEBLOC_MIN_DOWNLOAD_BYTES:-$2}" label="$3" cleanup="${4:-}" size=0
  local hosts="${5:-github.com / objects.githubusercontent.com / dl.k8s.io / get.helm.sh}"
  [ -f "$file" ] && size="$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$size" ] || size=0
  if [ "$size" -lt "$min" ]; then
    [ -n "$cleanup" ] && rm -rf "$cleanup"
    error "Download of ${label} was truncated or blocked — got ${size} bytes (expected at least ${min}). On a filtered network a proxy or antivirus may be cutting the transfer; allowlist the download host (${hosts}) or exclude the tools directory from AV scanning, then re-run."
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

# The "release the secure environment that is already here" remedy, printed from ONE
# place (backend#2077), for the sites that mean a FULL removal (switch account,
# switch Client ID), not a keep-your-data recreate.
#
# Why the release comes first: the backend record is anchored to the cluster's
# identity (the kube-system namespace UID), which dies with the cluster. Deleting
# k3s by hand never calls the API, so the record would keep a cluster_id that will
# never exist again and stay on the dashboard for good. `tracebloc delete` revokes
# it server-side first (an API call, so it works on a broken cluster too), then
# deletes it from this machine and, without --keep-data, wipes ~/.tracebloc, which
# is what these sites promise.
#
# It acts on this machine's active secure environment with the SIGNED-IN account's
# token, so it has to run as the account that owns it: the switch-account site has
# just signed in as the OTHER one, hence the `tracebloc login` in front. The last
# lines cover a machine where `tracebloc delete` can't run (it refuses with "no
# active client" when the pointer is gone): revoke it on the dashboard, then, on
# Linux, delete native k3s with its own uninstall script (k3s.sh,
# TB_K3S_UNINSTALL_PATH). A Mac gets no manual step.
#
# $1 (optional): the indent to print the command lines at.
_release_client_hint() {
  local in="${1:-}"
  hint "${in}tracebloc login  &&  tracebloc delete   (as the account that owns it: releases it on"
  hint "${in}                                         its dashboard, then wipes it + its local data)"
  hint "${in}(tracebloc delete refused, or you can't sign in as that account? revoke it on that"
  if [[ "${OS:-}" == "Linux" && -n "${TB_K3S_UNINSTALL_PATH:-}" ]]; then
    hint "${in} account's dashboard, then delete its k3s: sudo ${TB_K3S_UNINSTALL_PATH})"
  else
    hint "${in} account's dashboard.)"
  fi
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

# _refuse_invalid_cluster_name NAME -- validate_config's refusal of a cluster name
# outside the rule: a letter, then [a-zA-Z0-9._-], 63 characters at most.
_refuse_invalid_cluster_name() {
  [[ "${1:-}" =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,62}$ ]] \
    || error "CLUSTER_NAME must start with a letter, contain only [a-zA-Z0-9._-], max 63 chars (got '${1:-}')"
}

# Execute-gate a freshly-installed tool (#411). The old post-install "check" was a
# log-only interpolation (`... 2>/dev/null || echo present`) that masked failure,
# so a corrupt or wrong-architecture binary — a partial package-manager install, or a
# download no checksum path guarded — sat on PATH and failed only later, at
# cluster-create, after a green "System tools". Actually RUN the tool's cheapest
# self-check; on failure error() with an arch-aware remedy so the tool step fails
# loudly instead. NOTE: kubectl is gated with `version --client` (NOT --short,
# removed in kubectl 1.28+); helm with bare `version` (—short may go the same way).
#
# Removal is OPT-IN via a leading `--rm <path>`: pass it with the path where the
# installer PLACES the binary (TRACEBLOC_TOOLS_DIR/<tool>). On failure we remove that path
# ONLY when the binary that actually ran is that exact file (same inode, `-ef`).
# So: a broken binary WE installed there (fresh OR left by a prior run) is cleared,
# letting a re-run self-heal (Bugbot: otherwise `has` stays true → stuck loop);
# but a package manager's copy that lives elsewhere on PATH is never deleted — the
# resolved binary won't match our path (reviewer). Callers may pass --rm on every
# path; the `-ef` guard sorts out ownership.
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
# hang a headless install (installer rule: every kubectl/helm/systemctl probe must be
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
# the same everywhere.
#
# The --diagnose bundle is a read whose output is the point, and the one where the
# cost is the whole artifact rather than a stall: every read in it goes into a `{ … } > file`
# group, so ONE call that never returns means no file at all, from the one run
# collected BECAUSE the machine is already broken. A liveness gate passing in 5s
# does not make a slower read of the same daemon safe: more work, a different
# budget.
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

# _bounded_root SECONDS CMD… — like _bounded, but for a command that runs as root.
# `_bounded` execs `timeout`, a BINARY, which resolves `sudo` from PATH and so
# bypasses the root-aware `sudo()` shadow below — and as root (the normal
# `--prepare-host` path, where RFC 0001 often has no sudo binary at all)
# `timeout sudo CMD` then fails to find sudo and the caller misreads a live daemon
# as dead (Bugbot, #744). So the bound goes INSIDE the executor: `tb_root timeout
# SECS CMD` runs bare as root and through the real sudo otherwise, and under
# --print a read stays a read (`timeout` is on _tb_root_reads' list).
_bounded_root() {
  local t="$1"; shift
  if   has timeout;  then tb_root timeout  "$t" "$@"
  elif has gtimeout; then tb_root gtimeout "$t" "$@"
  else tb_root_bounded "$t" "$@"; fi   # a binary under the deadline, never the tb_root function (a killed subshell leaves CMD running)
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
# Mirrored by cli/internal/cli/sanitize.go and install-wsl.ps1's
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
# Lives here rather than in assess.sh (backend#2422) because k3s.sh and
# install-cli.sh call it and assess.sh is sourced only conditionally.
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
# ONE TABLE, HELD TO THE CHART BY A GUARD:
# scripts/tests/client-workloads-read-not-built.sh holds each right-hand side to
# exactly one Deployment in the rendered chart, with and without an override.
# Keep this on ONE line of role=app words.
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
# the same as a missing role. custom-columns rather than jsonpath: the retired
# PowerShell core ran the same argument vector, and Windows PowerShell 5.1
# mangles an embedded `"` in a native argument.
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
# scripts/tests/client-workloads-read-not-built.sh holds the helper below to the
# DaemonSet the chart renders, with and without an override.
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
# 10s); custom-columns, as in _client_workloads.
_resource_monitor_daemonset() {
  local ns="${1:-${TB_NAMESPACE:-default}}" timeout="${2:-10s}" rel="${3:-}" rows
  [[ -n "$rel" ]] || rel="$ns"
  rows="$(kubectl get daemonset -A -l "app.kubernetes.io/instance=${rel}" \
            -o 'custom-columns=RELNS:.metadata.annotations.meta\.helm\.sh/release-namespace,NS:.metadata.namespace,NAME:.metadata.name,CONTAINERS:.spec.template.spec.containers[*].name' \
            --no-headers --request-timeout="$timeout" 2>/dev/null)" || return 1
  _resource_monitor_from_rows "$rows" "$ns"
}

# ── Progress-line gate — animate only where a redraw reads (client-dev#1642) ──
# A spinner redraws its line with \r, \033[K and tput. Where colour is off
# (NO_COLOR / not a TTY / TERM=dumb / TB_PLAIN=1, decided once above as
# _tb_mode=none) those bytes land in a log as frame after frame of garbage, so
# every in-place progress line goes through these four helpers: animating, they
# draw and clear as before; plain, _tb_progress_start prints the message ONCE as a
# static line (the Go CLI's `  · msg` form) and the rest print nothing.
_tb_animate() { [[ "${_tb_mode:-none}" != "none" ]]; }
# _tb_progress_start MSG — hide the cursor (animating) or print MSG once (plain).
_tb_progress_start() {
  if _tb_animate; then
    tput civis 2>/dev/null || true
  else
    printf '  · %s\n' "$1"
  fi
}
# _tb_progress_frame GLYPH MSG — draw one frame in place; nothing when plain.
_tb_progress_frame() {
  _tb_animate || return 0
  printf "\r  ${CYAN}%s${RESET} %s" "$1" "$2"
}
# _tb_progress_clear — wipe the line in place (more output follows); nothing when plain.
_tb_progress_clear() {
  _tb_animate || return 0
  printf "\r\033[K"
}
# _tb_progress_end — wipe the line and restore the cursor; nothing when plain.
_tb_progress_end() {
  _tb_animate || return 0
  printf "\r\033[K"
  tput cnorm 2>/dev/null || true
}

# _tb_proc_tree PID — PID and every descendant, one per line, parents first.
# Captured BEFORE any signal: once a wrapper dies its children reparent to init
# and `pgrep -P` can no longer see them (Bugbot #442 r2).
_tb_proc_tree() {
  local _todo="$1" _next _p
  while [[ -n "$_todo" ]]; do
    _next=""
    for _p in $_todo; do
      echo "$_p"
      _next="$_next $(pgrep -P "$_p" 2>/dev/null || true)"
    done
    # shellcheck disable=SC2086  # word-splitting the pid list is the point
    _todo="$(printf '%s\n' $_next)"
  done
}

# _tb_proc_alive PID COMM — true while PID is a live (non-zombie) process still
# named COMM. `ps`, not `kill -0`: kill -0 on a root-owned `dnf` from a non-root
# installer fails with EPERM and would read a running process as gone. The
# name check means a pid the kernel reused is never taken for, or killed as,
# the process we captured.
_tb_proc_alive() {
  local _st="" _c=""
  read -r _st _c < <(ps -o stat= -o comm= -p "$1" 2>/dev/null || true) || true
  _c="${_c##*/}"; _c="${_c// /}"   # as _tb_spin_reap captured it: macOS prints a path, maybe with spaces
  [[ -n "$_st" && "$_st" != Z* && "$_c" == "$2" ]]
}

# _tb_spin_reap PID [GRACE_S] — spin's deadline path. TERM to PID and every
# descendant, wait up to GRACE_S whole seconds for all of them to exit, then
# KILL only those still alive under the same name. Empty GRACE_S is the
# historical 0.5 s, right for kubectl, curl and systemctl probes. A package manager
# is not one of those: rpm and dpkg defer TERM until the transaction is
# written, and a KILL 0.5 s later lands mid-transaction (client-dev#2063).
# Through sudo, sudo relays the TERM and only the reap of the WHOLE tree keeps
# its child from being orphaned holding the lock. Sets _TB_SPIN_SURVIVORS to
# "pid:name …" for whatever is still alive after the KILL (a root-owned
# process a non-root installer may not KILL), so the caller can name it.
_TB_SPIN_SURVIVORS=""
_tb_spin_reap() {
  local _pid="$1" _grace="${2:-}" _tree _p _c _pairs="" _pair _live _ticks=0 _t0=$SECONDS
  _TB_SPIN_SURVIVORS=""
  # A typo'd TB_PM_KILL_GRACE must not fall back to 0.5 s for a package
  # manager, nor abort the deadline path in $(( )): anything but digits is 60.
  if [[ -n "$_grace" ]]; then
    [[ "$_grace" =~ ^[0-9]+$ ]] && _grace=$(( 10#$_grace )) || _grace=60
  fi
  _tree="$(_tb_proc_tree "$_pid")"
  for _p in $_tree; do
    _c="$(ps -o comm= -p "$_p" 2>/dev/null || true)"
    _c="${_c##*/}"; _c="${_c// /}"
    [[ -n "$_c" ]] && _pairs="$_pairs $_p:$_c"
  done
  for _p in $_tree; do
    kill -TERM "$_p" 2>/dev/null || true
  done
  if [[ -z "$_grace" ]]; then
    sleep 0.5
  else
    # Ticks AND the wall clock, as spin's own deadline: a slow host stretches
    # every sleep, and the grace must not stretch with it (client-dev#1514).
    while (( _ticks * 2 < _grace * 10 && SECONDS - _t0 <= _grace )); do
      _live=0
      for _pair in $_pairs; do
        _tb_proc_alive "${_pair%%:*}" "${_pair#*:}" && { _live=1; break; }
      done
      (( _live )) || break
      sleep 0.2
      _ticks=$(( _ticks + 1 ))
    done
  fi
  for _pair in $_pairs; do
    _tb_proc_alive "${_pair%%:*}" "${_pair#*:}" && { kill -9 "${_pair%%:*}" 2>/dev/null || true; }
  done
  sleep 0.1
  for _pair in $_pairs; do
    [[ "${_pair%%:*}" == "$_pid" ]] && continue   # our own child: wait reaps it
    _tb_proc_alive "${_pair%%:*}" "${_pair#*:}" && _TB_SPIN_SURVIVORS="${_TB_SPIN_SURVIVORS:+$_TB_SPIN_SURVIVORS }$_pair"
  done
  return 0
}

# ── Spinner — hides noisy command output behind an animated status line ──────
#  Usage:  spin <pid> "Installing foo…" [deadline_seconds]
#  Animates only through the progress-line gate above: with colour off it prints
#  "  · Installing foo…" once and no frame, \r or escape (client-dev#1642).
#  The background process's stdout/stderr should already be redirected to a file
#  before calling spin. spin waits for the PID to exit and returns its exit code.
#  With the optional third argument, a still-running PID is killed once the
#  deadline passes and spin returns 124 (GNU timeout's convention) — the
#  backstop for commands that can wedge indefinitely (#426). The optional
#  fourth is the TERM-to-KILL grace in whole seconds (_tb_spin_reap below);
#  empty keeps the 0.5 s every non-package-manager caller has always had.
spin() {
  local pid="$1" msg="$2" deadline_s="${3:-}" grace_s="${4:-}"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  local ticks=0                           # one tick ≈ 0.12s
  local _spin_t0=$SECONDS                 # the deadline's wall clock: ticks alone stretch on a slow host (client-dev#1514)

  _tb_progress_start "$msg"               # hide cursor, or the one static line
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -n "$deadline_s" ]] && (( ticks * 12 >= deadline_s * 100 || SECONDS - _spin_t0 > deadline_s )); then
      # The whole tree, not just the pid: it is often a wrapper subshell
      # (spin_cmd_bounded's `tb_root dnf …`), and
      # signalling only the wrapper orphans the real worker (Bugbot #442).
      # Every line is failure-proofed (`|| true`): under `set -e` a bare
      # failure would abort the deadline path before `return 124`, and the
      # caller would never see the timeout (Bugbot #442 r3).
      _tb_spin_reap "$pid" "$grace_s" || true
      wait "$pid" 2>/dev/null || true
      _tb_progress_end
      return 124
    fi
    _tb_progress_frame "${frames[i]}" "$msg"
    i=$(( (i + 1) % ${#frames[@]} ))
    ticks=$(( ticks + 1 ))
    sleep 0.12
  done

  wait "$pid"
  local rc=$?
  _tb_progress_end                        # clear the spinner line, restore cursor
  return $rc
}

# ── Convenience wrapper: run a command quietly behind a spinner ───────────────
#  Usage:  spin_cmd "Installing foo…" apt-get install -y foo
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
#  `--grace N` first: N whole seconds between TERM and KILL instead of 0.5 —
#  for a package manager, which must be let finish its transaction
#  (client-dev#2063; callers pass "${TB_PM_KILL_GRACE:-60}"). Whatever is still
#  running after it is named, so the user knows a lock may still be held.
spin_cmd_bounded() {
  local grace=""
  if [[ "${1:-}" == "--grace" ]]; then grace="${2:-}"; shift 2; fi
  local secs="$1" msg="$2"; shift 2
  local logfile; _tb_spin_logfile; logfile="$_TB_SPIN_LOG"
  "$@" >> "$logfile" 2>&1 &
  local pid=$!
  local rc=0 _sv
  spin "$pid" "$msg" "$secs" "$grace" || rc=$?
  if (( rc == 124 )); then
    echo -e "  ${RED}${BOLD}✖ ${msg} — timed out after ${secs}s${RESET}" >&2
    echo -e "  ${DIM}Last 10 lines of log:${RESET}" >&2
    tail -10 "$logfile" >&2
    for _sv in ${_TB_SPIN_SURVIVORS:-}; do
      echo -e "  ${YELLOW}⚠ ${_sv#*:} (PID ${_sv%%:*}) is still running and may hold the package manager's lock — wait for it to exit (ps -p ${_sv%%:*}) before running the installer again.${RESET}" >&2
    done
    return 124
  elif (( rc != 0 )); then
    echo -e "  ${RED}${BOLD}✖ ${msg}${RESET}" >&2
    echo -e "  ${DIM}Last 10 lines of log:${RESET}" >&2
    tail -10 "$logfile" >&2
    return $rc
  fi
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

# ── The root executor (RFC-0175 D3, client-dev#1541) ─────────────────────────
#  Every privileged command prepare-host can reach is one call of:
#    tb_root CMD...          as root; may ask for the password (the sudo() shadow);
#    tb_root_n CMD...        as root, never asking (the install record's root copy);
#    tb_root_as USER CMD...  as USER, never asking (the named user's own record).
#  They are the one place `prepare-host --print` lists its plan from, so the plan
#  cannot drift from the run (CLAUDE.md rule 9). --print sets TRACEBLOC_ROOT_PLAN to a
#  file: a command that changes the host is appended to it and NOT run, and a read
#  (_tb_root_reads) runs as this user, never through sudo, so the plan follows
#  what the run would find. Without TRACEBLOC_ROOT_PLAN each runs exactly what the code
#  ran before it: tb_root through the sudo() shadow, the other two with `sudo -n`
#  (or runuser, as root). prepare-host-root-guard.py holds every function
#  prepare-host reaches to this: only the functions exported at the end of this
#  block may name sudo, _real_sudo or runuser.
tb_root()    { _tb_root root "$@"; }
tb_root_n()  { _tb_root root-n "$@"; }
tb_root_as() { local u="$1"; shift; _tb_root "user:${u}" "$@"; }

# tb_root_planning -- 0 under --print. A check of what an earlier step DID (a wait,
# a read-back) has nothing to check while nothing runs, and is skipped on it.
tb_root_planning() { [[ -n "${TRACEBLOC_ROOT_PLAN:-}" ]]; }

# tb_root_bounded SECS CMD... -- CMD as root under _tb_bounded_bg, the pure-bash
# deadline, for a host with no timeout(1) (client-dev#1618). _tb_bounded_bg signals
# the pid it started, so what it backgrounds must be a BINARY, never a function: a
# function runs in a subshell whose death leaves CMD running (measured: install.sh
# ran to its end). So the sudo() shadow's one rule is applied here -- root runs CMD
# bare, anyone else the real sudo binary -- and with neither, tb_root fails at once
# (127) and needs no bound. Under --print CMD is listed like any write, and nothing
# runs. A function of the executor: export -f below.
tb_root_bounded() {
  local secs="$1" real; shift
  if tb_root_planning; then tb_root "$@"; return; fi
  if [ "$(id -u)" -eq 0 ]; then _tb_bounded_bg "$secs" "$@"; return; fi
  real="$(type -P sudo)" || { tb_root "$@"; return; }
  _tb_bounded_bg "$secs" "$real" "$@"
}

_tb_root() {
  local how="$1"; shift
  if [[ -z "${TRACEBLOC_ROOT_PLAN:-}" ]]; then _tb_root_run "$how" "$@"; return; fi
  if _tb_root_reads "$@"; then "$@"; return; fi
  if ! printf '%s\n' "$(_tb_root_line "$how" "$@")" >> "$TRACEBLOC_ROOT_PLAN" 2>/dev/null; then
    # A plan that lost a line is no plan: the --print wrapper refuses to show it.
    : > "${TRACEBLOC_ROOT_PLAN}.broken" 2>/dev/null
    return 1
  fi
  # A body piped to the command (`printf … | tb_root tee FILE`) is read and dropped,
  # so the writer never dies of SIGPIPE. --print runs the plan with stdin from
  # /dev/null, so this never reads the installer itself under `curl | bash`.
  if [ -p /dev/stdin ]; then cat >/dev/null 2>&1 || :; fi
  return 0
}

# _tb_root_run HOW CMD... -- the run itself, one way per HOW.
_tb_root_run() {
  local how="$1" u; shift
  case "$how" in
    root) sudo "$@" ;;
    root-n)
      if [ "$(id -u)" -eq 0 ]; then "$@"; return; fi
      _have_sudo_bin && _real_sudo -n "$@" ;;
    user:*)
      u="${how#user:}"
      if _have_sudo_bin && _real_sudo -n true 2>/dev/null; then _real_sudo -n -u "$u" -- "$@"; return; fi
      if [[ "$(id -u 2>/dev/null)" == "0" ]] && type -P runuser >/dev/null 2>&1; then runuser -u "$u" -- "$@"; return; fi
      return 1 ;;
    *) echo "tb_root: unknown mode '${how}'" >&2; return 2 ;;
  esac
}

# A script run as root that only reads: does PATH ($1) exist? It answers
# present or absent, and nothing when sudo itself failed, which is cannot-tell.
# shellcheck disable=SC2016  # $1 is the inner sh's, on purpose
TRACEBLOC_ROOT_SH_EXISTS='if [ -e "$1" ]; then echo present; else echo absent; fi'

# _tb_root_reads CMD... -- 0 when CMD only reads: the probes prepare-host makes as
# root, which --print makes as this user instead. A closed list: anything else
# changes the host, is listed, and never runs under --print, even as root.
_tb_root_reads() {
  local a
  case "${1:-}" in
    true|test|cat|ls|stat|grep|cmp) return 0 ;;
    # fuser -k kills what holds the file; journalctl can delete or rotate the journal.
    fuser) for a in "$@"; do case "$a" in -*k*) return 1 ;; esac; done; return 0 ;;
    journalctl)
      for a in "$@"; do
        case "$a" in --vacuum-*|--rotate|--flush|--sync|--relinquish-var|--smart-relinquish-var|--setup-keys|--update-catalog) return 1 ;; esac
      done
      return 0 ;;
    find)
      for a in "$@"; do
        case "$a" in -delete|-exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls) return 1 ;; esac
      done
      return 0 ;;
    nft) [[ "${2:-}" == list ]] ;;
    iptables|ip6tables) case "${2:-}" in -S|-C|-L|--list|--check|--list-rules) return 0 ;; esac; return 1 ;;
    systemctl)
      shift
      for a in "$@"; do
        case "$a" in
          -*) continue ;;
          is-active|is-enabled|is-failed|status|show|cat) return 0 ;;
          *) return 1 ;;
        esac
      done
      return 1 ;;
    timeout|gtimeout|*/timeout|*/gtimeout) shift; [[ $# -ge 2 ]] && shift && _tb_root_reads "$@" ;;
    env)
      shift
      while [[ $# -gt 0 && ( "$1" == -i || "$1" == *=* ) ]]; do shift; done
      [[ $# -gt 0 ]] && _tb_root_reads "$@" ;;
    # Two fixed scripts read, word for word: the existence check and cluster.sh's
    # leftover scan. Not exported: a `bash -c` child has neither, and no sh is a read there.
    sh)
      [[ "${2:-}" == -c && -n "${3:-}" ]] || return 1
      [[ "$3" == "${TRACEBLOC_ROOT_SH_EXISTS:-}" || "$3" == "${TRACEBLOC_ROOT_SH_LEFTOVER_SCAN:-}" ]] ;;
    k3s|*/k3s) [[ "${2:-}" == kubectl ]] && case "${3:-}" in get|cluster-info|version) return 0 ;; esac; return 1 ;;
    *) return 1 ;;
  esac
}

# _tb_root_line HOW CMD... -- the plan's line for one command: its words, quoted
# for a shell, `as USER: ` before a command run as that user. A scratch path's
# random suffix reads XXXXXX, so the plan and a run name the same file, and a
# proxy URL's credentials read ***.
_tb_root_line() {
  local how="$1" a q out=""; shift
  case "$how" in user:*) out="as ${how#user:}: " ;; esac
  for a in "$@"; do
    a="$(printf '%s' "$a" | sed -E 's#(/tracebloc-[A-Za-z0-9-]*-)[A-Za-z0-9]{6}(/|$)#\1XXXXXX\2#g; s#(://)[^/@[:space:]]+@#\1***@#g')"
    case "$a" in
      '' | *[!A-Za-z0-9_./:=@%+,-]*) q="'$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'" ;;
      *) q="$a" ;;
    esac
    out+="${q} "
  done
  printf '%s' "${out% }"
}

# _tb_root_credential cached|prime|keepalive -- the password, for preflight_sudo:
# whether sudo answers without one, asking for it once, and keeping it warm.
_tb_root_credential() {
  case "$1" in
    cached) _real_sudo -n true 2>/dev/null ;;
    prime) _real_sudo -v ;;
    keepalive)
      ( while _real_sudo -n true 2>/dev/null; do sleep 50; done ) &
      SUDO_KEEPALIVE_PID=$! ;;
  esac
}

# Export the shadow (+ its helpers) so `sudo <cmd>` inside `bash -c '…'` subshells
# also routes through it — e.g. the apt-lock wait in setup-linux.sh runs
# `bash -c '… sudo … …'`. Without
# export, those child shells resolve the REAL sudo binary, so a root box without
# sudo installed would still hit "sudo: command not found" there — the exact case
# A2 fixes everywhere else (review #372). Harmless to non-bash children, which
# ignore the BASH_FUNC_* environment entries. The executor goes with it, so a
# `bash -c` child plans under --print too. prepare-host-root-guard.py reads this
# line as the executor: only these functions may name sudo.
export -f sudo _real_sudo _have_sudo_bin tb_root tb_root_n tb_root_as tb_root_planning tb_root_bounded _tb_root _tb_root_run _tb_root_reads _tb_root_line _tb_root_credential

# ── Sudo preflight — warm the credential cache before spinners hide prompts ──
#  Call once at the start of install_macos / install_linux. Establishes that the
#  privileged steps below can run, and (when a password is needed) primes the
#  sudo credential once so later steps behind spinners don't re-prompt.
# preflight_sudo [PURPOSE] -- PURPOSE finishes "tracebloc needs your password once
# to ...": by default, setting up native k3s and the system tools it needs.
preflight_sudo() {
  # --print runs nothing as root, so it asks for no password.
  if tb_root_planning; then
    return 0
  fi
  # Already root — nothing to prime; the sudo() shadow runs privileged steps
  # directly and needs no sudo binary. Fixes root containers/VMs and minimal
  # images without sudo (A2).
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  # Not root AND no sudo binary — the honest, actionable failure (previously
  # conflated with "no sudo access").
  if ! _have_sudo_bin; then
    error "This machine needs administrator rights to install k3s and system tools, but you are not root and sudo isn't installed. Re-run as root, or install sudo (e.g. apt-get install sudo) and try again."
  fi
  # Sudo present and already usable without a password (cached / NOPASSWD).
  if _tb_root_credential cached; then
    return 0
  fi
  # Prompt once, then keep the credential warm. One line, then the system's own
  # "Password:" prompt.
  hint "tracebloc needs your password once to ${1:-set up k3s and a few tools}."
  echo ""
  _tb_root_credential prime || error "Could not obtain administrator privileges (sudo authentication failed). ${2:-Re-run as a user allowed to sudo, or as root.}"
  _tb_root_credential keepalive
}

# ── Count bar — honest N-of-M progress for things pulled in discrete units ────
#  Usage:  count_bar <current> <total> [noun]      (renders ONE frame)
#  Draws a bar plus an "N of M <noun>" counter and NO newline, so a caller loop
#  can overwrite it in place (with \r) and clear it at the end via _tb_progress_end.
#  It always renders; a caller draws it only when _tb_animate says a redraw reads
#  (client-dev#1642), so plain its _tb_progress_start line and verdict are the report.
#  Use this — never a fabricated aggregate percentage — for multi-image pulls
#  (e.g. the client's container images), where the only honest signal is how many
#  of a known count have completed.
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
# The install log's file name, declared once. <stamp> is `date +%Y%m%d-%H%M%S`.
# In tracebloc's WSL distro both of the Windows installer's runs log into one
# directory (TRACEBLOC_LOG_DIR), so the name carries the run: <phase> is one of
# TB_WSL_PHASES below (client-dev#1810 section 5). e2e picks a run's log by it,
# and install-wsl.ps1's Pester case holds its phase names to TB_WSL_PHASES: change
# the names here, nowhere else. Every reader globs install-*.log.
TB_INSTALL_LOG_NAME='install-<stamp>.log'
TB_INSTALL_LOG_NAME_WSL='install-<stamp>-<phase>.log'
# Choose the log-file path: under HOST_DATA_DIR when it's creatable AND writable,
# else a temp file — so setup_log_file never dies on a bare `mkdir -p`/`tee` (#432).
# This matters for prepare-host, which logs BEFORE the data-dir guard runs: on an NFS
# home under sudo + root_squash the data dir isn't creatable/writable yet, and a
# cryptic mkdir failure there predates any friendly message. (The full install's
# early_data_dir_guard still refuses a network DATA dir before this runs.) Pure-ish
# (prints the path; no exec redirect) so it's unit-testable.
_choose_log_file() {
  local candidate="" dir="${HOST_DATA_DIR:-}" phase="" name
  # TRACEBLOC_LOG_DIR: where the Windows installer wants the core's log when it runs
  # it in tracebloc's WSL distro -- %USERPROFILE%\.tracebloc, as the distro sees it
  # (client-dev#1810 section 5) -- so the user finds it on Windows, beside the
  # host's own files. Unset everywhere else, where the data dir holds the log.
  if [[ -n "${TRACEBLOC_LOG_DIR:-}" ]]; then dir="$TRACEBLOC_LOG_DIR"; fi
  # Both of the Windows installer's runs log there, so the name says which run wrote
  # it (TB_INSTALL_LOG_NAME_WSL). Outside the distro there is no phase, and the name
  # is TB_INSTALL_LOG_NAME.
  phase="$(tb_wsl_phase)" || phase=""
  name="$TB_INSTALL_LOG_NAME"
  [[ -z "$phase" ]] || name="$TB_INSTALL_LOG_NAME_WSL"
  name="${name//<stamp>/$(date +%Y%m%d-%H%M%S)}"
  name="${name//<phase>/$phase}"
  if mkdir -p "$dir" 2>/dev/null; then
    candidate="${dir}/${name}"
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
  log "Substrate: ${TRACEBLOC_SUBSTRATE_RESOLVED}, from ${TB_SUBSTRATE_SOURCE:-the default}."
  if [[ -n "${TB_SUBSTRATE_NOTE:-}" ]]; then log "$TB_SUBSTRATE_NOTE"; fi
  if [[ -n "${TB_SUBSTRATE_MOVED:-}" ]]; then log "$TB_SUBSTRATE_MOVED"; fi
}

# ── Configuration (overridable via env) ──────────────────────────────────────
# Settings naming (backend#3846): every knob in this block has a TRACEBLOC_
# canonical name -- TRACEBLOC_<legacy>, a leading TB_ replaced (TB_STORAGE_MODE
# -> TRACEBLOC_STORAGE_MODE) -- and the legacy spelling still works (remove_by
# 2026-12-31). The rule TRACEBLOC_NAMESPACE / TRACEBLOC_HOST_DATA_DIR below set:
# a non-empty canonical wins, else the legacy, else the default. Each is
# resolved ONCE, here, into the legacy-named variable the rest of the installer
# reads and re-assigns (flags, validation, the node-local forcing), so a flag
# still beats the environment and nothing downstream changes. None of these is
# exported to a child, so no child can see a stale canonical.
if [[ -n "${TRACEBLOC_CLUSTER_NAME:-}" ]]; then CLUSTER_NAME="$TRACEBLOC_CLUSTER_NAME"; fi
CLUSTER_NAME="${CLUSTER_NAME:-tracebloc}"
# The secure-environment name (= the Helm release and the k8s namespace).
# Settings naming: TRACEBLOC_NAMESPACE is the canonical env var, TB_NAMESPACE
# the legacy alias (remove_by 2026-12-31). A non-empty TRACEBLOC_NAMESPACE wins,
# else TB_NAMESPACE, else it stays unset and each reader keeps its own default
# -- the same precedence and blank-means-unset rule as tb_client_env above.
# Resolved ONCE, here, into TB_NAMESPACE, the variable the rest of the installer
# reads and re-assigns (sanitising, adopting an existing release, provisioning);
# where the installer hands the name on it exports the decided value as the
# canonical (tb_export_namespace), so a child that resolves alias-first sees the
# SAME value and not a stale canonical the user set before the name was decided.
if [[ -n "${TRACEBLOC_NAMESPACE:-}" ]]; then TB_NAMESPACE="$TRACEBLOC_NAMESPACE"; fi

# tb_export_namespace — export the decided secure-environment name as
# TRACEBLOC_NAMESPACE. Only the canonical: no child of the installer reads
# TB_NAMESPACE from its environment (the CLI only ever sets it), and a core that
# sources this file again reads the canonical first. An unset TB_NAMESPACE
# exports an empty canonical, which every alias-first reader treats as unset.
tb_export_namespace() {
  TRACEBLOC_NAMESPACE="${TB_NAMESPACE:-}"
  export TRACEBLOC_NAMESPACE
}
# Settings this installer no longer reads: TRACEBLOC_SERVERS and TRACEBLOC_AGENTS
# were node counts for a runtime it no longer sets up, and native k3s runs one node;
# TRACEBLOC_K3D_VERSION pinned that runtime's version. validate_config names each one
# that is set, with tb_ignored_setting_reason's why (tb_say_ignored_settings), so a
# value nobody reads is never dropped without a word.
TB_IGNORED_SETTINGS="TRACEBLOC_SERVERS TRACEBLOC_AGENTS TRACEBLOC_K3D_VERSION"
# The leftover-data guard's non-interactive answer (cluster.sh). --reuse-data /
# --wipe-data assign TB_LEFTOVER_ACTION after this, so a flag still wins.
if [[ -n "${TRACEBLOC_LEFTOVER_ACTION:-}" ]]; then TB_LEFTOVER_ACTION="$TRACEBLOC_LEFTOVER_ACTION"; fi
# RFC-0003 — local dataset storage model. node-local is the DEFAULT as of the
# D15 flip (client#456, epic backend#1151), superseding the flag-gated prototype
# from #367. (D15 gates the flip on a green node-local dev training run on the dev
# environment; that sign-off is tracked on client#456, not asserted here.)
#   node-local (default, Option C): datasets live on k3s local-path INSIDE the
#                          node — they die with the cluster, are not a
#                          browsable host folder, and need no chmod 777. This is
#                          the RFC-0003 goal for the local install. The flip
#                          applies to the bash core, which Windows runs too,
#                          inside tracebloc's WSL distro.
#   hostpath   (opt-out) : the older model — datasets live in ~/.tracebloc on the
#                          host, bind-mounted into the cluster; survive cluster
#                          delete; world-writable dirs. Select with
#                          TRACEBLOC_STORAGE_MODE=hostpath (legacy:
#                          TB_STORAGE_MODE; still required for a
#                          TRACEBLOC_HOST_DATASET_DIR network mount).
# Record whether the operator chose the mode or is getting the D15 default: on an
# existing hostpath cluster the mismatch guard refuses an explicit node-local but
# adopts hostpath when node-local is only the default (client#456, client-dev#1669).
if [[ -n "${TRACEBLOC_STORAGE_MODE:-}" ]]; then TB_STORAGE_MODE="$TRACEBLOC_STORAGE_MODE"; fi
if [[ -n "${TB_STORAGE_MODE:-}" ]]; then TB_STORAGE_MODE_SOURCE="explicit"; else TB_STORAGE_MODE_SOURCE="default"; fi
TB_STORAGE_MODE="${TB_STORAGE_MODE:-node-local}"
# Pinned default; an empty value falls back to this pin (`:-` treats empty and
# unset the same — there is no opt-out to "latest" for k3s).
if [[ -n "${TRACEBLOC_K8S_VERSION:-}" ]]; then K8S_VERSION="$TRACEBLOC_K8S_VERSION"; fi
K8S_VERSION="${K8S_VERSION:-v1.36.5-k3s1}"
# Native k3s (RFC-0175 D4): the digests k3s.sh checks its downloads against, and
# the K8S_VERSION they were resolved for (facts.env K3S_BIN_SHA256_* /
# K3S_INSTALL_SH_SHA256 and K8S_VERSION, stamped by check-facts.sh --write). Stamped
# here, not in k3s.sh, because common.sh is in the signed manifest (RFC-0175 D12).
# TB_K3S_PIN_K8S_VERSION is a SECOND stamp of the k3s pin, and it exists because
# K8S_VERSION above takes an environment override: a k3s binary of any other
# version has no digest here, so the native path refuses an override by name
# (k3s.sh::_native_k3s_check_version). No TRACEBLOC_* override on any of the four:
# a digest from the environment could vouch for a download it was never resolved for.
# shellcheck disable=SC2034  # consumed cross-file by k3s.sh
TB_K3S_PIN_K8S_VERSION="v1.36.5-k3s1"
# shellcheck disable=SC2034  # consumed cross-file by k3s.sh
TB_K3S_BIN_SHA256_AMD64="d73847bcd3c5fccef0115b372e2f9a91f3032dc84bbf71518a4617565294d313"
# shellcheck disable=SC2034  # consumed cross-file by k3s.sh
TB_K3S_BIN_SHA256_ARM64="135e34cb9e8a1cfae3cb55577789e93501efe7edc080a8b2630458a85b07721e"
# shellcheck disable=SC2034  # consumed cross-file by k3s.sh
TB_K3S_INSTALL_SH_SHA256="46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad"
# The k3s node image the macOS node pulls, by its linux/arm64 manifest digest at the pinned
# K8S_VERSION (facts.env K3S_IMAGE_ARM64_DIGEST; the image is k3s.sh's
# _native_k3s_image_ref). No TRACEBLOC_* override, for the same reason.
# shellcheck disable=SC2034  # read by the macOS node from 2.1 part 3b (RFC-0175 D6)
TB_K3S_IMAGE_ARM64_DIGEST="sha256:4ceb591dd1e592b98b7c51ff3bdb7143914e1bee0677e7bf3c4f6addde2c93b3"
# Apple's `container` runtime for the macOS node (RFC-0175 D6): the release, the
# package's digest and the Team ID that signs it (facts.env APPLE_CONTAINER_*, stamped
# by check-facts.sh --write). Stamped here, not in mac-container.sh, for the reason the
# k3s pins above are. Not overridable from the environment: a different runtime has
# no digest here. TRACEBLOC_-named since backend#3846 (TB_ is a banned prefix), and
# assigned outright, so an exported TRACEBLOC_APPLE_* never reaches a reader.
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_APPLE_CONTAINER_VERSION="1.4.1"
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_APPLE_CONTAINER_PKG_SHA256="c0d2716afefbb194c93fae662e9cae7cc186bcbcf746816608ec673dd648a6a4"
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_APPLE_CONTAINER_TEAM_ID="UPBK2H6LZM"
# The VM's init image and our kernel, each a repository and a digest (facts.env
# APPLE_VMINIT_IMAGE / _DIGEST and MAC_KERNEL_IMAGE / _SHA256, the same stamping):
# mac-container.sh starts the runtime on them.
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_APPLE_VMINIT_IMAGE="ghcr.io/tracebloc/apple-container-vminit"
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_APPLE_VMINIT_DIGEST="sha256:aa6ab59d0938f7fadb54ac27e80959bdd2f1dafa8050011086d5f8ab1350fd6c"
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_MAC_KERNEL_IMAGE="ghcr.io/tracebloc/apple-container-kernel"
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_MAC_KERNEL_SHA256="fb2cfb79eb1ae19447a85d75682d7fa5cfec97e24beb2609a492b806e8072c8d"
# The NVIDIA GPU floors (facts.env NVIDIA_DRIVER_FLOOR_LINUX / NVIDIA_COMPUTE_CAP_FLOOR /
# NVIDIA_DRIVER_HARD_FLOOR_LINUX, stamped by check-facts.sh --write). Below the
# compute-capability floor or the hard driver floor (the CUDA 13 minimum) detect-gpu.sh
# leaves the GPU unwired and the install runs CPU-only. The driver floor is the driver
# the installer installs and asks for, never below the hard floor. Policy, so no
# TRACEBLOC_* override.
# shellcheck disable=SC2034  # consumed cross-file by detect-gpu.sh, gpu-nvidia.sh and gpu-plugins.sh
TB_NVIDIA_DRIVER_FLOOR="580"
# shellcheck disable=SC2034  # consumed cross-file by detect-gpu.sh
TB_NVIDIA_DRIVER_HARD_FLOOR="580"
# shellcheck disable=SC2034  # consumed cross-file by detect-gpu.sh
TB_NVIDIA_COMPUTE_CAP_FLOOR="7.5"
# Pinned default; ONLY the literal HELM_VERSION=latest resolves the newest Helm
# release at install time (an empty value falls back to this pin, like
# K8S_VERSION). The tarball is fetched directly from get.helm.sh and verified against
# its published .sha256sum either way (setup-linux.sh) — helm's get-helm-3
# script is NOT used: it floats on the mutable helm/helm@main and needs
# openssl, which minimal cloud images don't ship (#395).
if [[ -n "${TRACEBLOC_HELM_VERSION:-}" ]]; then HELM_VERSION="$TRACEBLOC_HELM_VERSION"; fi
HELM_VERSION="${HELM_VERSION:-v4.2.3}"
# The GPU training base image's footprint on a node, in GB (facts.env
# PREPULL_PARENT_DISK_GB, measured; stamped by check-facts.sh --write): what
# summary.sh's training prepull adds to the image store, which its disk rule weighs.
# A measurement, so no TRACEBLOC_* override.
# shellcheck disable=SC2034  # consumed cross-file by summary.sh
TB_PREPULL_PARENT_DISK_GB="11"
# Settings naming: TRACEBLOC_HOST_DATA_DIR is the canonical env var, HOST_DATA_DIR
# the legacy one (remove_by 2026-12-31) -- the same rule as TRACEBLOC_NAMESPACE
# above: a non-empty canonical wins, else the legacy, else the default. Resolved
# ONCE, here, into HOST_DATA_DIR, the variable the rest of the installer reads
# and re-assigns (--data-dir, validate_config's normalisation, the leftover
# guard's new-dir choice); validate_config then exports the decided path as
# TRACEBLOC_HOST_DATA_DIR (tb_export_host_data_dir), so a child reading it sees
# that path and not a stale canonical.
if [[ -n "${TRACEBLOC_HOST_DATA_DIR:-}" ]]; then HOST_DATA_DIR="$TRACEBLOC_HOST_DATA_DIR"; fi
# The default, named once: native k3s (k3s.sh) reads a data dir other than this
# one as the operator's choice of where the volumes live.
TB_HOST_DATA_DIR_DEFAULT="${HOME:-}/.tracebloc"
HOST_DATA_DIR="${HOST_DATA_DIR:-$TB_HOST_DATA_DIR_DEFAULT}"

# tb_export_host_data_dir — export the decided data dir as TRACEBLOC_HOST_DATA_DIR
# alone, as tb_export_namespace does. Its one child reader is the tracebloc CLI,
# which finds the installer's telemetry spool there and reads TRACEBLOC_HOST_DATA_DIR
# first. Every CLI this installer goes on with is at or above the platform's floor
# (require_tracebloc_cli_floor), well past the 0.10.60 that started reading it.
# HOST_DATA_DIR stays this shell's variable; one the caller exported still reaches a
# child, with the decided value.
tb_export_host_data_dir() {
  TRACEBLOC_HOST_DATA_DIR="${HOST_DATA_DIR:-}"
  export TRACEBLOC_HOST_DATA_DIR
}
# _hostpath_root -- the host directory a native k3s hostpath install's PVs sit under:
# the root an installed release keeps (TB_HOSTPATH_KEPT, _native_k3s_release_storage),
# else HOST_DATA_DIR (client-dev#1782). The values file (_hostpath_paths_block) and the
# summary both read it, so they name the same directory.
_hostpath_root() {
  if [[ "${TB_HOSTPATH_KEPT:-}" == 1 ]]; then printf '%s' "${TB_HOSTPATH_ROOT:-}"; else printf '%s' "${HOST_DATA_DIR:-}"; fi
}
# Optional separate host dir for the big DATASET volume (backend#743). Empty
# (default) keeps datasets under HOST_DATA_DIR. When set — e.g. a network/NFS
# mount like /data01/tracebloc — the chart's dataset PV points there, while mysql
# + logs stay on the local HOST_DATA_DIR (InnoDB over NFS is unsafe).
if [[ -n "${TRACEBLOC_HOST_DATASET_DIR:-}" ]]; then HOST_DATASET_DIR="$TRACEBLOC_HOST_DATASET_DIR"; fi
HOST_DATASET_DIR="${HOST_DATASET_DIR:-}"

# ── Input validation ────────────────────────────────────────────────────────
# _tb_system_path DIR -- true when the absolute path DIR is `/` or lies in a system
# tree no install data may live in. ONE list: validate_config refuses HOST_DATA_DIR
# here, and k3s.sh's renderer refuses the native local-storage path here.
_tb_system_path() {
  case "${1:-}" in
    /|/etc|/etc/*|/usr|/usr/*|/var|/var/*|/bin|/sbin|/lib|/lib64) return 0 ;;
  esac
  return 1
}

# _tb_home_path DIR -- DIR as validate_config reads a data dir: a leading ~ or ~/ is
# $HOME (users type --data-dir=~/foo and the shell does not expand ~ inside a quoted
# value), and a relative path is under $HOME. Empty stays empty. ONE rule: the
# refusals that run before validate_config (_mac_ct_hostpath_dirs,
# _native_k3s_refuse_windows_drive) read HOST_DATA_DIR through it too, so they judge
# the folder the install will use (client-dev#2183).
_tb_home_path() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 0
  case "$dir" in
    "~")   dir="$HOME" ;;
    "~/"*) dir="$HOME/${dir#\~/}" ;;
  esac
  [[ "$dir" == /* ]] || dir="$HOME/$dir"
  printf '%s' "$dir"
}

# tb_say_ignored_settings -- one warning for each setting of TB_IGNORED_SETTINGS
# that is set (blank is unset, as for every TRACEBLOC_* setting).
tb_say_ignored_settings() {
  local n
  for n in $TB_IGNORED_SETTINGS; do
    if [[ -n "${!n:-}" ]]; then
      warn "${n} is set, but this installer does not use it: $(tb_ignored_setting_reason "$n")."
    fi
  done
}

# tb_ignored_setting_reason NAME -- why this installer does not use NAME, one of
# TB_IGNORED_SETTINGS. Every one has a reason (shared-state.bats); any other name
# has none and returns 1.
tb_ignored_setting_reason() {
  case "$1" in
    TRACEBLOC_SERVERS|TRACEBLOC_AGENTS) printf '%s' "tracebloc runs on this one machine" ;;
    TRACEBLOC_K3D_VERSION) printf '%s' "it no longer sets up k3d" ;;
    *) return 1 ;;
  esac
}

validate_config() {
  [[ -n "${HOME:-}" ]]  || error "\$HOME is not set — cannot determine user home directory"
  [[ -n "${USER:-}" ]]  || USER="$(whoami)" || error "Cannot determine current user"

  _refuse_invalid_cluster_name "$CLUSTER_NAME"

  [[ "$TB_STORAGE_MODE" == "hostpath" || "$TB_STORAGE_MODE" == "node-local" ]] \
    || error "TB_STORAGE_MODE must be 'hostpath' or 'node-local' (got '$TB_STORAGE_MODE')"

  # node-local forces hostPath.enabled=false, so a HOST_DATASET_DIR network export
  # would be ignored and datasets would silently land on ephemeral local-path
  # storage (gone on 'cluster delete'). Combining the two is a documented follow-up
  # (backend#743 + RFC-0003); until then, refuse it rather than misroute datasets.
  [[ "$TB_STORAGE_MODE" == "node-local" && -n "${HOST_DATASET_DIR:-}" ]] \
    && error "TRACEBLOC_HOST_DATASET_DIR is not supported with node-local storage (datasets would land on ephemeral in-node storage, not the export). Use hostpath mode (TRACEBLOC_STORAGE_MODE=hostpath) for network-mount datasets."

  # HOST_DATA_DIR must be under $HOME and must not be a system path (security)
  local dir="$HOST_DATA_DIR"
  # Fail closed on an empty value (e.g. --data-dir= with no path) — otherwise the
  # $HOME-relative rewrite below resolves "" to a surprise dir like $HOME/$USER.
  [[ -n "$dir" ]] || error "HOST_DATA_DIR must not be empty (got '')."
  # Expand a leading ~ / ~/ and a $HOME-relative path (_tb_home_path): otherwise
  # --data-dir=~/foo is read as the literal "$HOME/~/foo" and fails parent resolution.
  dir="$(_tb_home_path "$dir")"
  # Resolve via parent directory — the target itself may not exist yet on first run
  local parent
  parent="$(cd -P "$(dirname "$dir")" 2>/dev/null && pwd)" || true
  [[ -z "$parent" ]] && error "HOST_DATA_DIR parent directory could not be resolved: $(dirname "$dir")"
  dir="$parent/$(basename "$dir")"
  [[ "$dir" == "/" ]] && error "HOST_DATA_DIR cannot be root (/)"
  _tb_system_path "$dir" && error "HOST_DATA_DIR cannot be a system path: $dir"
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
  tb_say_ignored_settings
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

# True if this machine runs amd64 binaries through QEMU binfmt. Preflight's _pf_arch and
# the engine gate _assert_engine_runs_on_this_arch must give one verdict, so both ask this
# probe and name amd64_emulation_remedy below; a function, so bats can override it.
amd64_emulation_available() { [[ -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ]]; }

# The command that registers that handler on this Linux machine: the distro's QEMU package
# (binfmt-support registers it on Debian and Ubuntu, systemd-binfmt on Fedora). Native k3s's
# containerd execs through the kernel's own handlers, so the remedy needs no Docker.
amd64_emulation_remedy() {
  if has apt-get; then
    printf 'sudo apt-get install -y qemu-user-static binfmt-support'
  elif has dnf; then
    printf 'sudo dnf install -y qemu-user-static'
  elif has zypper; then
    printf 'sudo zypper install -y qemu-linux-user'
  else
    printf "install your distribution's qemu-user-static package"
  fi
}

# nvidia | amd | apple_silicon | none, or amd_unsupported / nvidia_unsupported for a GPU
# detect_gpu found and left off, because tracebloc has no training image for it (an AMD
# GPU; an NVIDIA GPU on a machine that is not x86_64: client-dev#1697, #1698). Every GPU
# step keys on exactly nvidia or amd, so an _unsupported vendor sets nothing up.
GPU_VENDOR="none"
NVIDIA_DRIVER_OK=false
# detect-gpu.sh's floor verdict for a present NVIDIA driver: ok | below-hard-floor |
# below-compute | unreadable. Empty = not judged (no NVIDIA driver on the host yet).
TB_GPU_FLOOR_VERDICT=""
# Why the GPU was left off as UNSUPPORTED, for the platform (client-dev#1633): one
# human sentence and the card's name, set by detect-gpu.sh's floor gate on
# below-compute and below-hard-floor, by detect_gpu for a GPU that is not NVIDIA or an
# NVIDIA GPU on a machine that is not x86_64 (client-dev#1698), and
# by the container runtime's GPU probe for an NVIDIA GPU no container can see
# (backend#5296), and in tracebloc's WSL distro by the Windows installer's report of an
# NVIDIA GPU WSL cannot give it (wsl_cannot_see_gpu) -- ONLY those -- and passed to the chart as
# env.GPU_UNSUPPORTED_REASON / env.GPU_UNSUPPORTED_NAME (install-client-helm.sh).
# Empty otherwise: an unreadable host or a failed GPU step is not "unsupported".
# Assigned, never defaulted from the environment.
TB_GPU_UNSUPPORTED_REASON=""
TB_GPU_UNSUPPORTED_NAME=""
# The kind beside the sentence (backend#5296): compute_too_old | driver_too_old |
# not_nvidia | runtime_cannot_see_gpu | arch_unsupported, or, in tracebloc's WSL
# distro, the Windows installer's wsl_cannot_see_gpu; or empty. Passed as
# env.GPU_UNSUPPORTED_CODE.
TB_GPU_UNSUPPORTED_CODE=""
# nvidia-smi's name answer, one line per GPU, for a runtime_cannot_see_gpu report.
TB_GPU_NVIDIA_NAMES=""

# _host_os_label -- this host's operating system as the dashboard shows it
# (client-runtime#914): "Ubuntu 22.04", "Debian GNU/Linux 12", "macOS 15". Printed
# to stdout, empty when it cannot tell. Passed to the chart as env.TRACEBLOC_HOST_OS
# (install-client-helm.sh _host_os_set_args), and the resource monitor sends it on
# every heartbeat as `os`. Only the installer can answer: the monitor runs in a pod,
# whose /etc/os-release is the image's, and the macOS node's osImage is k3s's.
# os-release is READ, never sourced (it is the host's file, and sourcing it would run
# it); its path and the macOS version take the overrides the setup steps already
# honour (TRACEBLOC_OS_RELEASE_FILE, TRACEBLOC_MACOS_VER).
#
# Inside WSL2 the machine is the Windows host, not the distro: the label is the
# host's ("Windows 11"), from the OS caption the host reports over interop
# (_windows_host_identity_once, install-client-helm.sh). When interop
# cannot answer, or the caption is not one it can read, the distro's label stands.
# Without probe.sh or install-client-helm.sh loaded the distro's label stands too.
_os_release_value() {  # $1 = key, $2 = file: the value, unquoted, or nothing
  sed -n "/^$1=/{s/^$1=//;p;q;}" "$2" 2>/dev/null \
    | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}
# _windows_os_label CAPTION -- "Windows 11", "Windows Server 2022" from a Windows
# OS caption ("Microsoft Windows 11 Pro"), without the vendor and the edition;
# nothing for a caption it cannot read. Case-insensitive. Pure.
_windows_os_label() {
  local re='Windows[[:space:]]+(Server[[:space:]]+[0-9]{4}([[:space:]]+R2)?|[0-9]+)' had_nocase=0 out=""
  shopt -q nocasematch && had_nocase=1
  shopt -s nocasematch
  if [[ "${1:-}" =~ $re ]]; then out="Windows ${BASH_REMATCH[1]}"; fi
  [[ "$had_nocase" == 1 ]] || shopt -u nocasematch
  printf '%s' "$out"
}
_host_os_label() {
  local os name ver major
  os="${OS:-$(uname -s 2>/dev/null)}"
  case "$os" in
    Darwin)
      ver="${TRACEBLOC_MACOS_VER:-$(sw_vers -productVersion 2>/dev/null)}"
      major="${ver%%.*}"
      [[ "$major" =~ ^[0-9]+$ ]] || return 0
      # 10.x named its release by the minor (10.15 Catalina); 11 on, by the major.
      if [[ "$major" == 10 ]]; then printf 'macOS %s' "$(cut -d. -f1-2 <<<"$ver")"
      else printf 'macOS %s' "$major"; fi
      ;;
    Linux)
      if declare -F _probe_wsl >/dev/null 2>&1 && _probe_wsl \
         && declare -F _windows_host_identity_once >/dev/null 2>&1; then
        local ident="" caption="" label=""
        if ident="$(_windows_host_identity_once)"; then
          IFS='|' read -r _ _ _ _ _ caption <<<"$ident"
          label="$(_windows_os_label "$caption")"
          if [[ -n "$label" ]]; then printf '%s' "$label"; return 0; fi
        fi
      fi
      local f="${TRACEBLOC_OS_RELEASE_FILE:-/etc/os-release}"
      [[ -r "$f" ]] || return 0
      name="$(_os_release_value NAME "$f")"
      ver="$(_os_release_value VERSION_ID "$f")"
      [[ -n "$name" ]] || return 0
      if [[ -n "$ver" ]]; then printf '%s %s' "$name" "$ver"; else printf '%s' "$name"; fi
      ;;
  esac
  return 0
}
# 1 once an NVIDIA GPU is wired into this cluster, else 0. Assigned, never
# defaulted from the environment: only the installer's own GPU steps may set it.
TRACEBLOC_GPU_WIRED=0
PM_INSTALL=""
PM_UPDATE=""

# True when an NVIDIA GPU has been WIRED INTO THIS CLUSTER — not merely detected.
# TRACEBLOC_GPU_WIRED becomes 1 only in native k3s's step c, once k3s's own containerd
# has registered the NVIDIA runtime (k3s.sh _native_k3s_gpu_wire, slim client 1.1i).
# So this is the one honest gate for "should we request a GPU for jobs". Requesting nvidia.com/gpu on a
# node that advertises 0 GPUs strands every job Pending (client#835), so the GPU
# chart values (install-client-helm.sh) ride this, not bare GPU_VENDOR detection.
# Wired means exactly GPU_VENDOR=nvidia and TRACEBLOC_GPU_WIRED=1; any other value of
# either is "not wired". set -u safe: a unit test that sources only a single lib
# may not have TRACEBLOC_GPU_WIRED, so it defaults here.
_gpu_wired() {
  [[ "${GPU_VENDOR:-}" == "nvidia" && "${TRACEBLOC_GPU_WIRED:-0}" == "1" ]]
}

# True when detect_gpu's floor verdict skips the GPU: below-compute (the card is too
# old for the images), below-hard-floor (the driver is older than the CUDA 13 minimum
# tracebloc's GPU images need, client-dev#1632) or unreadable (cannot tell). The GPU
# steps then install no toolkit and never set TRACEBLOC_GPU_WIRED, so the install runs
# CPU-only; detect_gpu has already printed why and the remedy. Every verdict that is
# not ok skips: there is no warning band (2026-10-18). Not judged (no driver yet, the
# driver-install path) is not a skip.
_gpu_floor_skips() {
  case "${TB_GPU_FLOOR_VERDICT:-}" in
    below-compute|below-hard-floor|unreadable) return 0 ;;
  esac
  return 1
}

# The RuntimeClass a wired NVIDIA GPU runs under: the device plugin's
# runtimeClassName, the client's RUNTIME_CLASS_NAME and the summary's GPU test all
# read it here (install-client-helm.sh, summary.sh). It is the runtime native k3s's
# own containerd registered and step c's gate asked for (k3s.sh TB_K3S_GPU_RUNTIME;
# k3s creates the RuntimeClass of the same name), so the two can never disagree.
_gpu_runtime_class() {
  printf '%s' "${TB_K3S_GPU_RUNTIME:-}"
}

# ── Failure diagnostics (client#681) ─────────────────────────────────────────
#  Under `set -euo pipefail` a command that fails outside an if/&&/|| context
#  kills the installer with NO output at all: the user got a generic "did not
#  complete", and the install log — which is the WHOLE session tee'd — recorded
#  nothing about why. A single ERR trap records where it died so both the log
#  and the closer can name it (#577).
#
#  install-k8s.sh arms this with `set -E` (errtrace) so the trap is inherited by
#  functions and subshells — without it an ERR trap fires only at top level, and
#  every failure inside install_macos/install_linux (i.e. nearly all of them)
#  would still be invisible.
TRACEBLOC_ERR_LOC=""    # "file:line" of the LAST failing command — see _record_err
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
  TRACEBLOC_ERR_LOC="${1:-?}"
  TB_ERR_CMD="${2:-}"

  # The full trail, log only. The benign entries are not noise: they are how you
  # tell a probe that always fails from the command that actually ended the run,
  # and reading them in order is what identified this bug.
  log "err: ${TRACEBLOC_ERR_LOC} exit=${TB_ERR_CODE} cmd=${TB_ERR_CMD}"

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

# tb_exit_rc RC — the status an EXIT trap exits with (client-dev#1752). On
# macOS's bash 3.2 a `set -u` abort ("unbound variable") reaches the EXIT trap
# with `$?` = 0, and the trap's own last command then sets the process's status:
# an installer that died mid-run exited 0 and reported success. `exit N` and a
# `set -e` failure keep their status on every bash, so only a 0 is in doubt, and
# a 0 counts only once the script has said it meant one: every intended `exit 0`
# under the trap, and the normal end of install-k8s.sh, sets _tb_done=1 first.
# Any other 0 is read as the failure it was. Unset counts as not done.
tb_exit_rc() {
  if [[ "$1" -eq 0 && "${_tb_done:-0}" != 1 ]]; then echo 1; else echo "$1"; fi
}

# ── Cleanup on exit ──────────────────────────────────────────────────────────
# install-k8s.sh wires it as `trap 'install_cleanup; exit "${_TB_EXIT_RC:-1}"' EXIT`:
# the explicit exit is what makes the status tb_exit_rc's on bash 3.2 too.
install_cleanup() {
  local exit_code=$?
  # Stop recording before doing anything else. This handler's own lines can fail
  # (a `kill` on a dead pid, an `[[ … ]]` that is simply false), and with `set -E`
  # each of those fires the ERR trap — which under last-wins would overwrite the
  # fatal command with a cleanup detail before the report below ever reads it.
  trap - ERR
  # A 0 nobody declared is an abort bash 3.2 lost the status of (tb_exit_rc), so
  # everything below — the footer and the telemetry outcome — sees a failure.
  if [[ $exit_code -eq 0 && "${_tb_done:-0}" != 1 ]]; then
    log "Exited 0 before the run declared it finished — read as a failure (an abort, e.g. an unbound variable under bash 3.2)."
  fi
  exit_code="$(tb_exit_rc "$exit_code")"
  _TB_EXIT_RC="$exit_code"
  [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  # Never leave the transient machine credential on disk (#838): provision.sh sets
  # _PROVISION_CRED_FILE before minting and removes it after sourcing — this is the
  # backstop for an error/signal between mint and that cleanup.
  [[ -n "${_PROVISION_CRED_FILE:-}" ]] && rm -f "$_PROVISION_CRED_FILE" 2>/dev/null || true
  # The private download/scratch directories (backend#4279): a fatal error mid
  # download must not leave a partial binary behind in the user's TMPDIR.
  declare -F tb_scratch_reap >/dev/null 2>&1 && tb_scratch_reap
  # Record WHERE it died, always and first (client#681). The log is the artifact
  # users send to support, and until now a `set -e` death left it with no trace of
  # the failure at all. Logged even on the exit-2 / interrupted paths, so a
  # re-run-required stop that was actually caused by an error is still traceable.
  if [[ -n "${TB_ERR_CODE:-}" ]]; then
    log "FAILED at ${TRACEBLOC_ERR_LOC} — exit ${TB_ERR_CODE} — command: ${TB_ERR_CMD}"
  fi
  # A run that ends before its outcome (TRACEBLOC_CLIENT_STATE) stops the macOS node it started.
  if [[ $exit_code -ne 0 && -z "${TRACEBLOC_CLIENT_STATE:-}" ]] && declare -F _mac_ct_stop_run_node >/dev/null 2>&1; then
    _mac_ct_stop_run_node
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
    # indistinguishable from a real one in the log.
    echo ""
    warn "Installation was interrupted before it finished."
    [[ -n "${LOG_FILE:-}" ]] && hint "Log: $LOG_FILE"
    hint "Nothing is broken — this installer is safe to re-run."
  elif [[ $exit_code -ne 0 ]]; then
    # If print_summary already reported a specific outcome (TRACEBLOC_CLIENT_STATE set),
    # don't tack on a second, generic "did not complete" message. Nor after a
    # refusal (TB_EXIT_REFUSED): its own line says what to change, and "just try
    # again" would send the user straight back into the same refusal.
    if [[ -z "${TRACEBLOC_CLIENT_STATE:-}" && -z "${TB_EXIT_REFUSED:-}" ]]; then
      echo ""
      warn "Installation did not complete."
      # Name the failing site on screen too. The command text stays in the log
      # only: it is unexpanded, but it is still installer internals, and the
      # user is shown a reason, never a stack trace (#577).
      if [[ -n "${TB_ERR_CODE:-}" ]]; then
        hint "Stopped at ${TRACEBLOC_ERR_LOC} (exit ${TB_ERR_CODE})."
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
  # Everything it reads (TRACEBLOC_CLIENT_STATE, TB_ERR_*, the phase clock) is final by
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
#    TB_SUBSTRATES                  properties.substrate.enum less the substrates
#                                   every key of x-tracebloc-substrate.retired
#                                   retires, space-separated: what a run can select
#    TB_SUBSTRATE_DEFAULT           x-tracebloc-substrate.default
#    TB_SUBSTRATE_FRESH_LINUX       x-tracebloc-substrate.fresh-default.linux
#    TB_SUBSTRATE_RETIRED_LINUX     x-tracebloc-substrate.retired.linux, space-separated
#    TB_SUBSTRATE_RETIRED_MACOS     x-tracebloc-substrate.retired.macos, space-separated
#    TB_SUBSTRATE_RETIRED_WINDOWS   x-tracebloc-substrate.retired.windows, space-separated
#    TB_SUBSTRATE_TOKEN_PREFIX      x-tracebloc-substrate.token-prefix
#    TB_SUBSTRATE_TOKEN_UNSUPPORTED x-tracebloc-substrate.token-unsupported
#    TB_INSTALL_RECORD_VERSION      properties.schema_version.const
#    TB_ARTEFACT_KINDS              $defs.artefact.properties.kind.enum, space-separated
#    TB_ARTEFACT_FLAGS              $defs.artefact's boolean properties, space-separated
#    TB_RECORD_USER_PATH            x-tracebloc-record.user-path (a leading ~ is $HOME)
#    TB_RECORD_ROOT_PATH            x-tracebloc-record.root-path (<user> is the login name)
#    TB_RECORD_LAST_IN_USE          x-tracebloc-last-in-use.kinds, space-separated
TB_SUBSTRATES="k3s"
TB_SUBSTRATE_DEFAULT="k3s"
TB_SUBSTRATE_FRESH_LINUX="k3s"
TB_SUBSTRATE_RETIRED_LINUX="k3d"
TB_SUBSTRATE_RETIRED_MACOS="k3d"
TB_SUBSTRATE_RETIRED_WINDOWS="k3d"
TB_SUBSTRATE_TOKEN_PREFIX="tracebloc-installer substrate="
TB_SUBSTRATE_TOKEN_UNSUPPORTED="unsupported"
TB_INSTALL_RECORD_VERSION=1
TB_ARTEFACT_KINDS="k3d-cluster binary launch-agent launch-daemon helm-release k3s-install file firewall-rule wsl-distro logon-task kube-context group apple-container container-node job-data engine-bundles"
TB_ARTEFACT_FLAGS="created_by_prepare_host"
# shellcheck disable=SC2088  # a template: tb_record_path substitutes the ~, never the shell
TB_RECORD_USER_PATH="~/.tracebloc/install-record.json"
TB_RECORD_ROOT_PATH="/var/lib/tracebloc/<user>/install-record.json"
TB_RECORD_LAST_IN_USE="apple-container"
# The substrate this run was asked for: TRACEBLOC_SUBSTRATE, else the default
# (blank means unset, as for every TRACEBLOC_* setting). There is no flag and no
# alias. main() refines it with tb_substrate_resolve, so a re-run keeps the
# substrate its install recorded, and refuses a value outside the schema's enum
# (tb_substrate_supported) or one retired where it runs, by name, AFTER the
# substrate line has printed. A library caller that never calls the resolver
# keeps this source-time value.
TRACEBLOC_SUBSTRATE_RESOLVED="${TRACEBLOC_SUBSTRATE:-$TB_SUBSTRATE_DEFAULT}"
# Where TRACEBLOC_SUBSTRATE_RESOLVED came from, and what the resolver could not consult, for the
# install log; and a finding it refuses by name after the substrate line.
TB_SUBSTRATE_SOURCE="${TRACEBLOC_SUBSTRATE:+TRACEBLOC_SUBSTRATE}"
TB_SUBSTRATE_NOTE=""
TB_SUBSTRATE_REFUSAL=""
# Why this run moves a machine off a substrate retired where it runs (its record
# names one, tb_substrate_resolve): the line print_substrate_token prints right
# after the substrate line.
TB_SUBSTRATE_MOVED=""
# Set by a refusal just before it exits: install_cleanup then prints no failure
# footer, because a re-run with nothing changed is refused again.
TB_EXIT_REFUSED=""

# tb_substrate_supported -- TRACEBLOC_SUBSTRATE_RESOLVED is a value of the schema's
# enum: one this installer sets up (TB_SUBSTRATES), or one a TB_SUBSTRATE_RETIRED_*
# stamp retires, which the substrate line still names, so that its refusal
# belongs to it (tb_substrate_resolve).
tb_substrate_supported() {
  local s v known="$TB_SUBSTRATES"
  for v in ${!TB_SUBSTRATE_RETIRED_@}; do known+=" ${!v}"; done
  for s in $known; do
    [[ "$s" == "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" ]] && return 0
  done
  return 1
}

# The substrate line: one line, fixed grammar, no colour, so a harness can read it
# from the installer's own output. It names the substrate this run resolved, or
# the "unsupported" sentinel, never the raw request: a free-form value must not
# be able to bend the grammar.
tb_substrate_token() {
  if tb_substrate_supported; then
    printf '%s%s\n' "$TB_SUBSTRATE_TOKEN_PREFIX" "$TRACEBLOC_SUBSTRATE_RESOLVED"
  else
    printf '%s%s\n' "$TB_SUBSTRATE_TOKEN_PREFIX" "$TB_SUBSTRATE_TOKEN_UNSUPPORTED"
  fi
}

# Printed by main() before anything that can refuse; setup_log_file copies it
# into the install log once that exists.
print_substrate_token() {
  tb_substrate_token
  TB_SUBSTRATE_TOKEN_PRINTED=1
  if [[ -n "${TB_SUBSTRATE_MOVED:-}" ]]; then info "$TB_SUBSTRATE_MOVED"; fi
}

refuse_unsupported_substrate() {
  tb_substrate_supported && return 0
  TB_EXIT_REFUSED=1
  if [[ "${TB_SUBSTRATE_SOURCE:-TRACEBLOC_SUBSTRATE}" == "TRACEBLOC_SUBSTRATE" ]]; then
    error "TRACEBLOC_SUBSTRATE='${TRACEBLOC_SUBSTRATE_RESOLVED}' is not a runtime this installer can set up (it supports: ${TB_SUBSTRATES// /, }). Unset it to use the default runtime ($(OS=Darwin _tb_substrate_fresh_here) on a Mac, ${TB_SUBSTRATE_FRESH_LINUX} on Linux, inside WSL too)."
  fi
  error "${TB_SUBSTRATE_SOURCE} says this machine runs on '${TRACEBLOC_SUBSTRATE_RESOLVED}', which is not a runtime this installer can set up (it supports: ${TB_SUBSTRATES// /, }). Set TRACEBLOC_SUBSTRATE to the runtime this machine uses, then re-run."
}

# The finding tb_substrate_resolve kept, refused by name: main() calls this right
# after refuse_unsupported_substrate, so the substrate line has printed first.
refuse_unresolved_substrate() {
  [[ -n "${TB_SUBSTRATE_REFUSAL:-}" ]] || return 0
  TB_EXIT_REFUSED=1
  error "$TB_SUBSTRATE_REFUSAL"
}

# tb_in_wsl_distro -- this run is inside tracebloc's WSL distro: Linux, and probe.sh's
# _probe_wsl_ours (the WSL kernel, and WSL_DISTRO_NAME is TB_WSL_DISTRO). The one
# predicate the distro's paths read: the run contract below, step d's stdin
# credential (provision.sh) and native k3s's steps (k3s.sh _native_k3s_on_wsl).
# Without probe.sh (a stale bootstrap) nothing is told apart, so nothing is ours.
tb_in_wsl_distro() {
  [[ "${OS:-}" == "Linux" ]] && declare -F _probe_wsl_ours >/dev/null 2>&1 && _probe_wsl_ours
}

# tb_over_ssh -- this run was started from an ssh session: OpenSSH sets
# SSH_CONNECTION on every session and SSH_TTY when it gives it a terminal. Whoever
# runs it is at another machine, not at this one's screen, and may be a script.
tb_over_ssh() {
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]]
}

# ── The Windows installer's two runs (client-dev#1810 section 5's contract) ──────
# In tracebloc's WSL distro this core runs twice, and only as the Windows installer
# runs it: `wsl -d tracebloc -u root -- env TRACEBLOC_SUBSTRATE=k3s
# TRACEBLOC_WSL_PHASE=<phase> … bash install-k8s.sh`. The sign-in and `client create`
# are the host CLI's (RFC-0175 D2), and create needs the cluster, so:
#   cluster  steps a, b (no CLI), c, then exit 0: the host signs in and creates;
#   client   the credential on stdin (provision_read_stdin_credential), then steps
#            a, b (no CLI), c (finds the cluster), d as that credential, e and f.
# The phase never selects anything: the substrate is named on the line, and the
# phase and the distro's name are refusals (refuse_wsl_run).
TB_WSL_PHASES="cluster client"

# refuse_wsl_run -- the run in tracebloc's WSL distro is the Windows installer's,
# and only its. Refused by name, after the substrate line (main()): in the distro, a
# substrate other than k3s, a phase outside TB_WSL_PHASES, and a client run with no
# credential on stdin (step d would sign in, with no CLI here); in any other WSL
# distro, the run itself, whatever its substrate (RFC-0175 D10: a user's own
# distro is no longer served, and native k3s serves tracebloc's distro only),
# told apart by probe.sh's _probe_wsl_kernel and _probe_wsl_ours (a WSL kernel,
# never WSL's environment names alone, which any Linux host can export), so a
# process without probe.sh (a stale bootstrap) refuses nothing here; anywhere else, a
# phase; a stdin credential outside the distro's `client` phase; and what
# provision_read_stdin_credential found wrong with the credential it read
# (TB_STDIN_CRED_REFUSAL). Read-only.
refuse_wsl_run() {
  local ours=0 wsl=0 p ok=0 have="none" why=""
  if tb_in_wsl_distro; then
    ours=1
  elif [[ "${OS:-}" == "Linux" ]] && declare -F _probe_wsl_ours >/dev/null 2>&1 && _probe_wsl_kernel; then
    # probe.sh is loaded and can tell tracebloc's distro from another (its
    # _probe_wsl_ours), and this is a WSL kernel, but not that distro.
    wsl=1
  fi
  if [[ "$ours" -eq 1 ]]; then
    for p in $TB_WSL_PHASES; do
      if [[ "${TRACEBLOC_WSL_PHASE:-}" == "$p" ]]; then ok=1; fi
    done
    [[ -z "${TRACEBLOC_WSL_PHASE:-}" ]] || have="TRACEBLOC_WSL_PHASE='${TRACEBLOC_WSL_PHASE}'"
    if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" != "k3s" ]]; then
      why="In tracebloc's WSL distro the installer sets up native k3s only, and this run resolved '${TRACEBLOC_SUBSTRATE_RESOLVED:-}'. Install from Windows with install.ps1, which runs it here."
    elif [[ "$ok" -ne 1 ]]; then
      why="In tracebloc's WSL distro the installer runs as one of the Windows installer's two runs (TRACEBLOC_WSL_PHASE=${TB_WSL_PHASES// / or }), and this run has ${have}. Install from Windows with install.ps1, which runs both."
    elif [[ "${TRACEBLOC_WSL_PHASE}" == "client" && "${TRACEBLOC_CREDENTIAL_STDIN:-}" != 1 ]]; then
      why="In tracebloc's WSL distro the client run takes the credential the Windows installer hands over on stdin (TRACEBLOC_CREDENTIAL_STDIN=1), and this run was handed none. Install from Windows with install.ps1, which hands it over."
    fi
  elif [[ "$wsl" -eq 1 ]]; then
    why="Inside WSL the installer runs only in tracebloc's own distro, '${TB_WSL_DISTRO:-}', which install.ps1 sets up"
    if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
      why+=", and this is the distro '${WSL_DISTRO_NAME}'"
    fi
    why+=". Install from Windows with install.ps1."
  elif [[ -n "${TRACEBLOC_WSL_PHASE:-}" ]]; then
    why="TRACEBLOC_WSL_PHASE='${TRACEBLOC_WSL_PHASE}' belongs to the Windows installer's runs in tracebloc's WSL distro, and this is not that distro. Unset it, then re-run."
  fi
  if [[ -z "$why" && "${TRACEBLOC_CREDENTIAL_STDIN:-}" == 1 ]] && [[ "$ours" -ne 1 || "${TRACEBLOC_WSL_PHASE:-}" != "client" ]]; then
    why="TRACEBLOC_CREDENTIAL_STDIN=1 belongs to the Windows installer's client run in tracebloc's WSL distro, and this run is not that one. Unset it, then re-run."
  fi
  if [[ -z "$why" && "${TRACEBLOC_CREDENTIAL_STDIN:-}" == 1 ]] && ! declare -F provision_read_stdin_credential >/dev/null 2>&1; then
    why="This installer build can't take a credential on stdin (provision.sh is missing: stale bootstrap). Re-run the installer from Windows."
  fi
  [[ -n "$why" ]] || why="${TB_STDIN_CRED_REFUSAL:-}"
  [[ -n "$why" ]] || return 0
  TB_EXIT_REFUSED=1
  error "$why"
}

# tb_wsl_phase -- this run's phase in tracebloc's WSL distro, or nothing elsewhere.
# Read after refuse_wsl_run, so a phase it prints is one of TB_WSL_PHASES.
tb_wsl_phase() {
  if tb_in_wsl_distro; then printf '%s' "${TRACEBLOC_WSL_PHASE:-}"; fi
}

# tb_wsl_handover_write -- the cluster run's verdict, handed to the Windows installer
# (3.2 part 2c, client-dev#1810). The host names a file on the cluster run's line,
# TRACEBLOC_WSL_HANDOVER, in a folder only this user can open and the host deletes
# after the install. It reads the file only when the cluster run exits 0, and refuses
# to go on when the file or its line is missing. So main() writes it last, just before
# that exit 0: a file there means this run reached its end. Exactly five lines, which
# replace whatever the file held:
#   INSTALL_STATE_REASON=<word>, the reason the stop-and-check gate set (assess.sh), as
#   it set it -- a tag such as credential-rejected, ns:<namespace> for a healthy
#   client, or empty when the gate did not assess (--force, or a stale bootstrap
#   without assess.sh). On credential-rejected the host runs `client create --reissue`
#   and puts TRACEBLOC_CREDENTIAL_REISSUED=1 on the client run's line;
#   TB_PREV_KUBE_CONTEXT=<context>, the context kubectl pointed at before this run's
#   kubeconfig merge made its own current (k3s.sh), or empty when it pointed at no
#   other one. The client run merges again after this one, so only this run can tell;
#   the host puts it on the client run's line (TRACEBLOC_WSL_PREV_KUBE_CONTEXT), and
#   that run's summary says how to switch back (backend#5025 O-19);
#   TRACEBLOC_MACHINE_KIND=, TRACEBLOC_CLOUD_PROVIDER= and TRACEBLOC_HOST_OS=, where
#   this machine runs (provision.sh's _registration_machine_facts, the facts the
#   chart's heartbeat gets in this distro), each empty when it cannot be read. The
#   host runs `client create`, so it puts them in that call's environment, as
#   provision.sh does for its own create, and the registration says where the
#   machine runs before its first heartbeat (backend#5797).
# Only the cluster run writes it, and only to a file the host named. A write that
# fails is an error, so the run never exits 0 without the lines.
tb_wsl_handover_write() {
  [[ "$(tb_wsl_phase 2>/dev/null)" == "cluster" && -n "${TRACEBLOC_WSL_HANDOVER:-}" ]] || return 0
  _TB_REG_MACHINE_KIND=""; _TB_REG_CLOUD_PROVIDER=""; _TB_REG_HOST_OS=""
  if declare -F _registration_machine_facts >/dev/null 2>&1; then _registration_machine_facts; fi
  { printf 'INSTALL_STATE_REASON=%s\nTB_PREV_KUBE_CONTEXT=%s\nTRACEBLOC_MACHINE_KIND=%s\nTRACEBLOC_CLOUD_PROVIDER=%s\nTRACEBLOC_HOST_OS=%s\n' \
      "${INSTALL_STATE_REASON:-}" "${TB_PREV_KUBE_CONTEXT:-}" \
      "${_TB_REG_MACHINE_KIND//[$'\r\n']/}" "${_TB_REG_CLOUD_PROVIDER//[$'\r\n']/}" "${_TB_REG_HOST_OS//[$'\r\n']/}" >"$TRACEBLOC_WSL_HANDOVER"; } 2>/dev/null \
    || error "Couldn't hand what this run found to the Windows installer: ${TRACEBLOC_WSL_HANDOVER} could not be written. Re-run the installer from Windows."
  log "handover: INSTALL_STATE_REASON=${INSTALL_STATE_REASON:-} TB_PREV_KUBE_CONTEXT=${TB_PREV_KUBE_CONTEXT:-} TRACEBLOC_MACHINE_KIND=${_TB_REG_MACHINE_KIND} TRACEBLOC_CLOUD_PROVIDER=${_TB_REG_CLOUD_PROVIDER} TRACEBLOC_HOST_OS=${_TB_REG_HOST_OS} written to ${TRACEBLOC_WSL_HANDOVER}"
}

# tb_wsl_client_state_write -- the client run's TRACEBLOC_CLIENT_STATE, handed to the
# Windows installer, which runs the example use case only on `connected` (as
# setup_example_use_case does). One line, to the file the host named on this run's line.
# A failed write only warns: the host reads a missing file as not connected.
tb_wsl_client_state_write() {
  [[ "$(tb_wsl_phase 2>/dev/null)" == "client" && -n "${TRACEBLOC_WSL_HANDOVER:-}" ]] || return 0
  local state="${TRACEBLOC_CLIENT_STATE:-}"
  state="${state//[$'\r\n']/}"
  { printf 'TRACEBLOC_CLIENT_STATE=%s\n' "$state" >"$TRACEBLOC_WSL_HANDOVER"; } 2>/dev/null \
    || { warn "Couldn't hand the client's state to the Windows installer (${TRACEBLOC_WSL_HANDOVER}); it will not set up the example use case."; return 0; }
  log "handover: TRACEBLOC_CLIENT_STATE=${state} written to ${TRACEBLOC_WSL_HANDOVER}"
}

# ── The macOS floor (RFC-0175 D6, D10) ───────────────────────────────────────
# Apple silicon with macOS 26 or later (D6, decided 2026-09-29). macOS 26 is the last
# release for Intel Macs, and every M1 or later Mac runs it. This is the floor's one
# declaration, and its words. A Mac below it is stopped by name on every path, before
# anything is written (refuse_unsupported_mac; D10, decision F, tracebloc/cli-dev#1056),
# whether or not it already runs tracebloc: one that does keeps the version it runs,
# unsupported, and is not switched off.
TB_MACOS_FLOOR_MAJOR=26

# _tb_macos_version -- this Mac's macOS version, `sw_vers -productVersion`.
# TRACEBLOC_MACOS_VER is the test seam.
_tb_macos_version() { printf '%s' "${TRACEBLOC_MACOS_VER:-$(sw_vers -productVersion 2>/dev/null)}"; }

# tb_mac_floor_verdict -- whether this Mac meets the floor. Prints "ok", "intel",
# "old VERSION", or "unknown [ANSWER]" when sw_vers gave no version; nothing off macOS.
# The processor is ARCH, which the runtime globals above take from `sysctl
# hw.optional.arm64`, never from `uname -m` alone: a shell running under Rosetta on
# Apple silicon is Apple silicon. Intel is named first, because updating macOS cannot
# fix it.
tb_mac_floor_verdict() {
  [[ "${OS:-}" == "Darwin" ]] || return 0
  if [[ "${ARCH:-}" != "arm64" ]]; then
    printf 'intel\n'
    return 0
  fi
  local v major
  v="$(_tb_macos_version)"
  major="${v%%.*}"
  if ! [[ "$major" =~ ^[0-9]+$ ]]; then
    printf 'unknown%s\n' "${v:+ $v}"
    return 0
  fi
  if [ "$major" -lt "$TB_MACOS_FLOOR_MAJOR" ]; then
    printf 'old %s\n' "$v"
    return 0
  fi
  printf 'ok\n'
}

# tb_mac_floor_reason VERDICT -- the words for a verdict below the floor: what this Mac
# is, and what tracebloc needs. They are (a)'s, cli-dev scripts/install.sh. Each caller
# adds only what its own path does next.
tb_mac_floor_reason() {
  local answer
  case "${1:-}" in
    intel)
      printf '%s' "This Mac has an Intel processor (${ARCH:-x86_64}). tracebloc for macOS needs Apple silicon (M1 or later) with macOS ${TB_MACOS_FLOOR_MAJOR} or later." ;;
    old\ *)
      printf '%s' "This Mac runs macOS ${1#old }. tracebloc needs macOS ${TB_MACOS_FLOOR_MAJOR} or later. Update macOS (System Settings > General > Software Update), then run this again." ;;
    unknown|unknown\ *)
      answer="${1#unknown}"
      answer="${answer# }"
      printf '%s' "This installer couldn't read this Mac's macOS version ('sw_vers -productVersion' answered '${answer:-nothing}'), so it can't tell whether this Mac has Apple silicon with macOS ${TB_MACOS_FLOOR_MAJOR} or later." ;;
    *) return 1 ;;
  esac
}

# tb_upgrade_run -- this run is a `tracebloc upgrade`: the CLI's flag (TB_ spelling
# first, as install.sh and assess.sh read it). The one rule for leaving out the
# first-install pointer at `tracebloc data ingest`.
tb_upgrade_run() {
  [[ "${TB_UPGRADE_CLI:-${TRACEBLOC_UPGRADE_CLI:-0}}" == 1 ]]
}

# refuse_unsupported_mac -- a Mac below the floor, stopped by name, on every path.
# main() calls it right after the substrate refusals, so the substrate line has
# printed, and before setup_log_file, so nothing is written yet: no CLI install, no
# repair, no log. The macOS node's refusals (_mac_ct_refuse_host) call it too. One
# message serves a new Mac and an installed one, so nothing probes for an install.
# `tracebloc upgrade` (TRACEBLOC_UPGRADE_CLI, or TB_UPGRADE_CLI from a CLI older than
# its dual emit) reads any other exit as a failed upgrade and sends the user to the
# installer again (cli-dev#1056, check 2), so on that path the same stop exits 0.
refuse_unsupported_mac() {
  local verdict why
  verdict="$(tb_mac_floor_verdict)"
  case "$verdict" in ''|ok) return 0 ;; esac
  why="$(tb_mac_floor_reason "$verdict")"
  why+=" A tracebloc already installed here keeps the version it has, without updates. Nothing was changed on this Mac."
  if [[ "${TRACEBLOC_UPGRADE_CLI:-${TB_UPGRADE_CLI:-0}}" == 1 ]]; then
    warn "$why"
    _tb_done=1   # an intended exit 0 under install_cleanup (tb_exit_rc, client-dev#1752)
    exit 0
  fi
  TB_EXIT_REFUSED=1
  error "$why"
}

# ── Re-run resolution (1.1f) ─────────────────────────────────────────────────
# tb_substrate_retired_here SUBSTRATE -- 0 when SUBSTRATE is retired where this
# run is: in this OS's TB_SUBSTRATE_RETIRED_<OS> stamp. Darwin reads _MACOS; Linux
# inside WSL (_probe_wsl, probe.sh) is the Windows installer's distro
# (refuse_wsl_run) and reads _WINDOWS; Linux outside WSL reads _LINUX. 1 when it is
# not, or on any other OS; 2 when this cannot tell: Linux, SUBSTRATE retired on one
# side of WSL's line, and no WSL probe loaded (a stale bootstrap). The one predicate
# every reader of the retirement asks: the resolver, the substrates it offers
# (_tb_substrates_here), the substrate a Mac gets instead (_tb_substrate_fresh_here)
# and cluster.sh's unmeasured-reservation warning. It has one case per stamp this
# build sets, because a TB_ name nothing stamps is read from the user's environment
# (installer-env-canonical.bats). install-contract.bats holds every key of the
# schema's retired map to a stamp this predicate reads, and every stamp to a key.
tb_substrate_retired_here() {
  local s list found=1 os="${OS:-$(uname -s 2>/dev/null)}"
  case "$os" in
    Darwin) list="${TB_SUBSTRATE_RETIRED_MACOS:-}" ;;
    Linux)
      for s in ${TB_SUBSTRATE_RETIRED_LINUX:-} ${TB_SUBSTRATE_RETIRED_WINDOWS:-}; do [[ "$s" == "${1:-}" ]] && found=0; done
      [[ "$found" -eq 0 ]] || return 1
      found=1
      declare -F _probe_wsl >/dev/null 2>&1 || return 2
      if _probe_wsl; then list="${TB_SUBSTRATE_RETIRED_WINDOWS:-}"; else list="${TB_SUBSTRATE_RETIRED_LINUX:-}"; fi ;;
    *) return 1 ;;
  esac
  for s in $list; do [[ "$s" == "${1:-}" ]] && found=0; done
  [[ "$found" -eq 0 ]] || return 1
  return 0
}

# _tb_substrate_fresh_here -- the substrate a machine here gets instead of a
# retired one. On a Mac, the one substrate of TB_SUBSTRATES that retired.macos
# leaves (k3s, in Apple's container runtime); the schema names no fresh default
# for a Mac, because 4.1 leaves it no other. Prints nothing, and fails, when that is not
# exactly one, or on an OS with no case: Linux's is the schema's own
# fresh-default.linux (TB_SUBSTRATE_FRESH_LINUX).
_tb_substrate_fresh_here() {
  local s left=""
  case "${OS:-$(uname -s 2>/dev/null)}" in
    Darwin)
      for s in $TB_SUBSTRATES; do
        tb_substrate_retired_here "$s" && continue
        [[ -z "$left" ]] || return 1
        left="$s"
      done ;;
    *) return 1 ;;
  esac
  [[ -n "$left" ]] || return 1
  printf '%s' "$left"
}

# _tb_substrates_here -- the substrates this installer sets up where this run is,
# comma-separated: TB_SUBSTRATES less those retired here (tb_substrate_retired_here).
# One whose retirement here cannot be told stays listed: a run that asks for it is
# refused by name then. What a refusal that asks for a substrate offers.
_tb_substrates_here() {
  local s out=""
  for s in $TB_SUBSTRATES; do
    if tb_substrate_retired_here "$s"; then continue; fi
    out+="${out:+, }${s}"
  done
  printf '%s' "$out"
}

# _tb_substrate_where -- where this run is, as the retirement's texts name it ("on
# a Mac", "on Linux outside WSL", "inside WSL"). Fails on an OS with no case, and on
# Linux with no WSL probe loaded.
_tb_substrate_where() {
  case "${OS:-$(uname -s 2>/dev/null)}" in
    Darwin) printf '%s' "on a Mac" ;;
    Linux)
      declare -F _probe_wsl >/dev/null 2>&1 || return 1
      if _probe_wsl; then printf '%s' "inside WSL"; else printf '%s' "on Linux outside WSL"; fi ;;
    *) return 1 ;;
  esac
}

# tb_substrate_resolve -- the substrate this run sets up. A machine installed on
# one runtime stays on it without the variable, so the order is:
#   1. TRACEBLOC_SUBSTRATE, when set;
#   2. the substrate in the daily user's install record (tb_record_path);
#   3. on Linux, the root copy, read only as root or through a password-free sudo.
#      Without either it is not consulted and the log says so: a plain user
#      cannot read it by design, so its absence from view is not "cannot tell";
#   4. on Linux, a tracebloc native k3s this user can see without privileges
#      (_native_k3s_live_probe), which catches one whose record is out of reach;
#   5. the default (TB_SUBSTRATE_DEFAULT: native k3s).
# A Mac gets no substrate retired there (TB_SUBSTRATE_RETIRED_MACOS: k3d, slim client
# 4.1, client-dev#1948), so it has one, the substrate left (_tb_substrate_fresh_here: k3s
# in Apple's container runtime, RFC-0175 D1/D6). There TRACEBLOC_SUBSTRATE naming a
# retired one is refused by name, and every other run resolves the Mac's one: a
# record from a k3d install does not keep k3d, and reinstall.sh's refuse_k3d_machine
# refuses such a Mac with the way off k3d (D10); the record's other substrate goes
# in TB_SUBSTRATE_NOTE for the log.
# On Linux a substrate retired where this run is (TB_SUBSTRATE_RETIRED_LINUX outside
# WSL, TB_SUBSTRATE_RETIRED_WINDOWS inside it: k3d, slim client 4.1) is never set up
# there (tb_substrate_retired_here): asked for by the variable, it is refused; named
# by a record, the run resolves the fresh default and TB_SUBSTRATE_MOVED says why,
# and reinstall.sh's refuse_k3d_machine refuses the machine with the way off k3d.
# A record that exists but cannot be read or parsed is "cannot tell", never
# absent: the finding goes in TB_SUBSTRATE_REFUSAL, which main() refuses by name
# after the substrate line, naming the substrates set up here (_tb_substrates_here).
# TRACEBLOC_SUBSTRATE_RESOLVED keeps the requested value, so the line prints it.
# Prints nothing and writes nothing.
tb_substrate_resolve() {
  local rec sub rc=0 dst left
  TB_SUBSTRATE_NOTE=""; TB_SUBSTRATE_REFUSAL=""; TB_SUBSTRATE_MOVED=""
  if [[ -n "${TRACEBLOC_SUBSTRATE:-}" ]]; then
    TRACEBLOC_SUBSTRATE_RESOLVED="$TRACEBLOC_SUBSTRATE"; TB_SUBSTRATE_SOURCE="TRACEBLOC_SUBSTRATE"
    if [[ "${OS:-$(uname -s 2>/dev/null)}" == "Darwin" ]]; then
      if tb_substrate_retired_here "$TRACEBLOC_SUBSTRATE_RESOLVED"; then
        TB_SUBSTRATE_REFUSAL="TRACEBLOC_SUBSTRATE=${TRACEBLOC_SUBSTRATE_RESOLVED}, but this installer no longer sets up ${TRACEBLOC_SUBSTRATE_RESOLVED} $(_tb_substrate_where): $(_tb_substrate_where) it sets up $(_tb_substrate_fresh_here) in Apple's container runtime, and no other runtime. Unset TRACEBLOC_SUBSTRATE, then re-run."
      fi
      return 0
    fi
    rc=0; tb_substrate_retired_here "$TRACEBLOC_SUBSTRATE_RESOLVED" || rc=$?
    case "$rc" in
      0)
        # Inside WSL the run is tracebloc's distro or another, which refuse_wsl_run
        # refuses next: either way the way on is the Windows installer.
        if [[ "$(_tb_substrate_where)" == "inside WSL" ]]; then
          TB_SUBSTRATE_REFUSAL="TRACEBLOC_SUBSTRATE=${TRACEBLOC_SUBSTRATE_RESOLVED}, which this installer no longer sets up inside WSL: there it sets up native ${TB_SUBSTRATE_FRESH_LINUX}, and only in tracebloc's own distro, which install.ps1 sets up. Install from Windows with install.ps1."
        else
          TB_SUBSTRATE_REFUSAL="TRACEBLOC_SUBSTRATE=${TRACEBLOC_SUBSTRATE_RESOLVED}, which this installer no longer sets up $(_tb_substrate_where). Unset TRACEBLOC_SUBSTRATE: it sets up native ${TB_SUBSTRATE_FRESH_LINUX} here."
        fi ;;
      2) TB_SUBSTRATE_REFUSAL="TRACEBLOC_SUBSTRATE=${TRACEBLOC_SUBSTRATE_RESOLVED}, and this installer build cannot tell whether it runs inside WSL (probe.sh is missing), so it cannot tell whether ${TRACEBLOC_SUBSTRATE_RESOLVED} is set up here. Re-run: curl -fsSL https://tracebloc.io/i.sh | bash" ;;
    esac
    return 0
  fi
  TRACEBLOC_SUBSTRATE_RESOLVED="$TB_SUBSTRATE_DEFAULT"; TB_SUBSTRATE_SOURCE="the default"
  rec="$(tb_record_path)"
  if [[ "${OS:-$(uname -s 2>/dev/null)}" == "Darwin" ]]; then
    if ! left="$(_tb_substrate_fresh_here)"; then
      TB_SUBSTRATE_REFUSAL="This installer build retires every runtime it supports (${TB_SUBSTRATES// /, }) on a Mac, or none, so it cannot tell which one to set up here. Re-run: curl -fsSL https://tracebloc.io/i.sh | bash"
      return 0
    fi
    TRACEBLOC_SUBSTRATE_RESOLVED="$left"; TB_SUBSTRATE_SOURCE="the one substrate on a Mac"
    if [[ -e "$rec" ]]; then
      if ! sub="$(_tb_record_substrate_of "$rec")"; then
        TB_SUBSTRATE_NOTE="Substrate: the install record ${rec} exists, but its substrate could not be read from it; $(_tb_substrate_where) this installer sets up ${left} whatever it says."
      elif [[ "$sub" != "$left" ]]; then
        TB_SUBSTRATE_NOTE="Substrate: the install record ${rec} says ${sub}, which this installer no longer sets up $(_tb_substrate_where)."
      fi
    fi
    return 0
  fi
  if [[ -e "$rec" ]]; then
    if sub="$(_tb_record_substrate_of "$rec")"; then
      TRACEBLOC_SUBSTRATE_RESOLVED="$sub"; TB_SUBSTRATE_SOURCE="the install record ${rec}"
      _tb_substrate_move_retired "$sub" "The install record ${rec}"
    else
      TB_SUBSTRATE_REFUSAL="The install record ${rec} exists, but its substrate could not be read from it, so this run cannot tell which runtime this machine was set up on. Set TRACEBLOC_SUBSTRATE to that runtime (it supports: $(_tb_substrates_here)), then re-run."
    fi
    return 0
  fi
  [[ "${OS:-$(uname -s 2>/dev/null)}" == "Linux" ]] || return 0
  if dst="$(_tb_record_root_copy_path)" && _tb_record_root_access; then
    if _tb_record_root_run test -e "$dst"; then
      if sub="$(_tb_record_root_run cat "$dst" 2>/dev/null | _tb_record_substrate_in)"; then
        TRACEBLOC_SUBSTRATE_RESOLVED="$sub"; TB_SUBSTRATE_SOURCE="the root copy ${dst}"
        _tb_substrate_move_retired "$sub" "The install record's root copy ${dst}"
      else
        TB_SUBSTRATE_REFUSAL="The install record's root copy ${dst} exists, but its substrate could not be read from it, so this run cannot tell which runtime this machine was set up on. Set TRACEBLOC_SUBSTRATE to that runtime (it supports: $(_tb_substrates_here)), then re-run."
      fi
      return 0
    fi
  else
    TB_SUBSTRATE_NOTE="Substrate: the root copy of the install record was not consulted (this run has neither root nor a password-free sudo)."
  fi
  rc=0; _tb_substrate_k3s_live || rc=$?
  case "$rc" in
    1) ;;
    0) TRACEBLOC_SUBSTRATE_RESOLVED="k3s"; TB_SUBSTRATE_SOURCE="the tracebloc native k3s set up on this machine (systemctl: k3s)" ;;
    *) TB_SUBSTRATE_REFUSAL="tracebloc's native k3s files are on this machine, but systemctl did not answer, so this run cannot tell whether that k3s is set up to run. Check 'systemctl status k3s', or set TRACEBLOC_SUBSTRATE to the runtime this machine uses, then re-run." ;;
  esac
  return 0
}

# _tb_substrate_move_retired SUB WHO -- a record (WHO, as a sentence's subject)
# names SUB: where SUB is retired, the run resolves the fresh default, and
# TB_SUBSTRATE_MOVED says why after the substrate line; reinstall.sh's
# refuse_k3d_machine then refuses it with the way off k3d. Where this cannot tell,
# the run is refused by name. Elsewhere nothing changes.
_tb_substrate_move_retired() {
  local rc=0
  tb_substrate_retired_here "$1" || rc=$?
  case "$rc" in
    0) TRACEBLOC_SUBSTRATE_RESOLVED="$TB_SUBSTRATE_FRESH_LINUX"
       TB_SUBSTRATE_MOVED="${2} says this machine runs on ${1}, which this installer no longer sets up $(_tb_substrate_where)." ;;
    2) TB_SUBSTRATE_REFUSAL="${2} says this machine runs on ${1}, and this installer build cannot tell whether it runs inside WSL (probe.sh is missing), so it cannot tell whether ${1} is still set up here. Re-run: curl -fsSL https://tracebloc.io/i.sh | bash" ;;
  esac
  return 0
}

# _tb_substrate_k3s_live -- _native_k3s_live_probe's answer: 0 when a tracebloc
# native k3s is set up here, 1 when not, 2 when it cannot tell. k3s.sh holds the
# probe; a process that did not source it cannot tell.
_tb_substrate_k3s_live() {
  declare -F _native_k3s_live_probe >/dev/null 2>&1 || return 2
  local rc=0
  _native_k3s_live_probe || rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
    *) return 2 ;;
  esac
}

# _tb_record_substrate_of FILE -- the substrate FILE records. Fails when FILE
# cannot be read, or names no substrate, or more than one.
_tb_record_substrate_of() {
  local text
  text="$(cat "$1" 2>/dev/null)" || return 1
  printf '%s' "$text" | _tb_record_substrate_in
}

# _tb_record_substrate_in -- the substrate in the record text on stdin: the value
# of its one "substrate" key, as a JSON string of [a-z0-9-]. Not tied to the
# writer's layout, so a record another tool rewrote still reads; anything else
# fails, and the value can never bend the substrate line (tb_substrate_token).
_tb_record_substrate_in() {
  local flat n v
  flat="$(tr '\n' ' ')"
  n="$(printf '%s' "$flat" | grep -o '"substrate"' | wc -l | tr -d ' ')"
  [[ "$n" == "1" ]] || return 1
  v="$(printf '%s' "$flat" | sed -n 's/.*"substrate"[[:space:]]*:[[:space:]]*"\([a-z0-9][a-z0-9-]*\)".*/\1/p')"
  [[ -n "$v" ]] || return 1
  printf '%s\n' "$v"
}

# ── Install record ──────────────────────────────────────────────────────────
#  What this install created, for an uninstall to remove exactly that. Written
#  as the install goes: tb_record_write KIND ID PATH [FLAG=true|false] records
#  one artefact the moment it exists, tb_record_drop KIND ID PATH takes one out
#  once it is gone, and tb_record_write alone refreshes the other fields. FLAG is
#  one boolean member the schema declares for an artefact
#  (TB_ARTEFACT_FLAGS: created_by_prepare_host, on a group). The writer reads its
#  previous output back: an artefact an earlier run recorded is kept
#  (_tb_record_artefacts, any layout), and so is a field this run has not decided
#  yet (_tb_record_prior, the writer's layout). No jq or python3 on this path.
#  Best-effort: a record that cannot be written is logged, never fatal.
#  Written only once main() has armed it, after the refusals, when the run is
#  committed to installing. Assigned here, never read from the environment: a
#  library function a unit test or a harness calls directly writes nothing.
#  TRACEBLOC_RECORD_ARMED and TRACEBLOC_KUBE_CONTEXT are the canonical names
#  (backend#3846). cli-dev's install-record drift check and its delete e2e source
#  this file at a pinned ref and ASSIGN the two after sourcing, under their old
#  TB_RECORD_ARMED / TB_KUBE_CONTEXT spellings, so the reads below are
#  canonical-first with the old name as the fallback (blank counts as unset;
#  remove_by 2026-12-31). The old armed flag is reset here too: with a fallback
#  read, an inherited TB_RECORD_ARMED=1 would otherwise arm the writer.
TRACEBLOC_RECORD_ARMED=""
TB_RECORD_ARMED=""
# _tb_record_armed -- true once main() (or a harness) has armed the writer.
_tb_record_armed() { [[ "${TRACEBLOC_RECORD_ARMED:-${TB_RECORD_ARMED:-}}" == "1" ]]; }
# _tb_kube_context -- the kube context this run pointed kubectl at, if any.
_tb_kube_context() { printf '%s' "${TRACEBLOC_KUBE_CONTEXT:-${TB_KUBE_CONTEXT:-}}"; }
# Prepared mode (prepare-host on native k3s, 1.1g): the record belongs to the user
# the administrator named, never to the administrator who runs it. TB_RECORD_FOR_USER
# is that user's login name (the record's `user`, and the root copy's <user>),
# TB_RECORD_FOR_HOME their home from passwd, where their own copy goes, and
# TRACEBLOC_RECORD_HOME the private directory this process builds the record in. Set only by
# tb_record_for_user, and assigned here like TRACEBLOC_RECORD_ARMED, so the environment can
# never point a record at another user.
TB_RECORD_FOR_USER=""
TB_RECORD_FOR_HOME=""
TRACEBLOC_RECORD_HOME=""
# The key prepare-host records the NVIDIA runtime its GPU gate registered under, and
# that runtime (k3s.sh _native_k3s_prepared_finish sets it), for the named user's
# Tier 0 install to read (_native_k3s_gpu_adopt): that user cannot ask k3s's
# containerd. Assigned here, like TB_RECORD_FOR_USER, never read from the environment.
TB_RECORD_PREPARED_GPU_KEY="prepared_gpu_runtime"
TB_RECORD_PREPARED_GPU_RUNTIME=""
# The user copy: x-tracebloc-record.user-path, its leading ~ as $HOME (in prepared
# mode, as the directory the record is built in).
tb_record_path() { printf '%s%s' "${TRACEBLOC_RECORD_HOME:-${HOME:-}}" "${TB_RECORD_USER_PATH#\~}"; }

# The login name the record is written for: the named user in prepared mode, else
# the user this process runs as.
_tb_record_user() {
  if [[ -n "${TB_RECORD_FOR_USER:-}" ]]; then printf '%s' "$TB_RECORD_FOR_USER"; return 0; fi
  id -un 2>/dev/null || printf '%s' "${USER:-}"
}

# tb_record_for_user USER HOME -- prepared mode: from here this process's record is
# USER's. It is built in a private scratch directory, seeded with USER's own record
# when they have one, so an artefact an earlier install recorded is kept. Every write
# then copies it to USER's own record path under HOME, written as USER
# (_tb_record_user_copy), and to the root copy keyed on USER. Fails when the scratch
# directory cannot be made.
tb_record_for_user() {
  local u="$1" h="$2" scratch=""
  [[ -n "$u" && "$h" == /* ]] || return 1
  tb_scratch_dir scratch tracebloc-record || return 1
  mkdir -p "${scratch}/.tracebloc" || return 1
  TB_RECORD_FOR_USER="$u"; TB_RECORD_FOR_HOME="$h"; TRACEBLOC_RECORD_HOME="$scratch"
  _tb_record_as_user "$u" cat "${h}${TB_RECORD_USER_PATH#\~}" > "$(tb_record_path)" 2>/dev/null \
    || rm -f "$(tb_record_path)"
  return 0
}

# _tb_record_as_user USER CMD... -- CMD as USER, never prompting: tb_root_as, which
# goes through sudo when this process can sudo without a password (preflight_sudo
# primed it), else through runuser when it is root. The sudo() shadow cannot do
# this: as root it runs its arguments as a command.
_tb_record_as_user() {
  local u="$1"; shift
  tb_root_as "$u" "$@"
}

# _tb_record_user_copy REC -- prepared mode: REC to the named user's own record path
# under their home, written AS that user under umask 077, so the directory comes out
# 0700 and the file 0600, both theirs, and root never writes into a directory the
# user controls. Logged, never fatal, like every record write: prepare-host reads
# the copy back at its end.
_tb_record_user_copy() {
  [[ -n "${TB_RECORD_FOR_USER:-}" && -n "${TB_RECORD_FOR_HOME:-}" ]] || return 0
  local dst="${TB_RECORD_FOR_HOME}${TB_RECORD_USER_PATH#\~}"
  # shellcheck disable=SC2016  # $1 is the inner sh's, on purpose
  if _tb_record_as_user "$TB_RECORD_FOR_USER" sh -c 'umask 077 && mkdir -p "${1%/*}" && cat > "$1.tmp" && mv -f "$1.tmp" "$1"' sh "$dst" < "$1" 2>/dev/null; then
    return 0
  fi
  log "Install record: couldn't write ${TB_RECORD_FOR_USER}'s copy ${dst}."
  return 0
}

# The root copy for login name $1: x-tracebloc-record.root-path with <user> filled
# in. TRACEBLOC_RECORD_ROOT_DIR, a test seam, replaces the directory above <user>.
_tb_record_root_path() {
  printf '%s/%s%s' "${TRACEBLOC_RECORD_ROOT_DIR:-${TB_RECORD_ROOT_PATH%%/<user>*}}" "$1" "${TB_RECORD_ROOT_PATH#*<user>}"
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
# previous write left in record text $3, else null.
_tb_record_field() {
  local p; p="$(_tb_record_prior "$1" "${3:-}")"
  if [[ -n "${2:-}" ]]; then _tb_json "$2"; return 0; fi
  printf '%s' "${p:-null}"
}

# _tb_record_artefacts -- the artefacts of the record text on stdin, one per line
# in the writer's own form (_tb_record_render), so a record reformatted or with
# its keys reordered (jq, an editor, json.dump(indent=2)) keeps every artefact
# and the kind+id+path match still finds it. Fails when the text holds anything
# it cannot read as a record of declared artefact members: the caller must not
# rewrite what it could not read. No text, no artefacts.
_tb_record_artefacts() {
  LC_ALL=C awk -v flags="$TB_ARTEFACT_FLAGS" '
    { text = text $0 "\n" }
    function lex(s,   n, i, j, c) {
      n = length(s); i = 1; nt = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == " " || c == "\t" || c == "\r" || c == "\n") { i++; continue }
        if (c == "\"") {
          for (j = i + 1; j <= n; j++) {
            c = substr(s, j, 1)
            if (c == "\\") { j++; continue }
            if (c == "\"" || c == "\n") break
          }
          if (j > n || c != "\"") return 0
          tok[++nt] = substr(s, i, j - i + 1); i = j + 1; continue
        }
        if (index("{}[]:,", c)) { tok[++nt] = c; i++; continue }
        for (j = i; j <= n && index("{}[]:,\" \t\r\n", substr(s, j, 1)) == 0; j++) ;
        tok[++nt] = substr(s, i, j - i); i = j
      }
      return 1
    }
    function scalar(t) { return substr(t, 1, 1) == "\"" || t == "true" || t == "false" || t == "null" }
    # value(p) -- the token after the value starting at p, or 0 when it is not one.
    function value(p,   d) {
      if (scalar(tok[p]) || tok[p] ~ /^-?[0-9]/) return p + 1
      if (tok[p] != "{" && tok[p] != "[") return 0
      for (d = 0; p <= nt; p++) {
        if (tok[p] == "{" || tok[p] == "[") d++
        else if (tok[p] == "}" || tok[p] == "]") { if (--d == 0) return p + 1 }
      }
      return 0
    }
    # artefact(p) -- one artefact object at p printed in the writer form; the token
    # after it, or 0.
    function artefact(p,   k, v, f, nf, i, line) {
      if (tok[p++] != "{") return 0
      split("", m)
      while (tok[p] != "}") {
        k = tok[p]; v = tok[p + 2]
        if (k !~ /^"[a-z_]+"$/ || tok[p + 1] != ":" || !scalar(v) || (k in m)) return 0
        m[k] = v; p += 3
        if (tok[p] == ",") p++
        else if (tok[p] != "}") return 0
      }
      if (!("\"kind\"" in m) || !("\"id\"" in m) || !("\"path\"" in m) || !("\"created_at\"" in m)) return 0
      line = "{\"kind\": " m["\"kind\""] ", \"id\": " m["\"id\""] ", \"path\": " m["\"path\""] ", "
      nf = split(flags, f, " ")
      for (i = 1; i <= nf; i++) {
        k = "\"" f[i] "\""
        if (k in m) { line = line k ": " m[k] ", "; delete m[k] }
      }
      line = line "\"created_at\": " m["\"created_at\""] "}"
      delete m["\"kind\""]; delete m["\"id\""]; delete m["\"path\""]; delete m["\"created_at\""]
      for (k in m) return 0
      out[++no] = line
      return p + 1
    }
    END {
      if (!lex(text)) exit 1
      if (nt == 0) exit 0
      if (tok[1] != "{") exit 1
      p = 2
      while (tok[p] != "}") {
        if (substr(tok[p], 1, 1) != "\"" || tok[p + 1] != ":") exit 1
        if (tok[p] == "\"artefacts\"") {
          if (seen++ || tok[p + 2] != "[") exit 1
          p += 3
          while (tok[p] != "]") {
            if (!(p = artefact(p))) exit 1
            if (tok[p] == ",") p++
            else if (tok[p] != "]") exit 1
          }
          p++
        } else if (!(p = value(p + 2))) exit 1
        if (tok[p] == ",") p++
        else if (tok[p] != "}") exit 1
      }
      if (p != nt) exit 1
      for (i = 1; i <= no; i++) print out[i]
    }'
}

tb_record_write() {
  # The record's home is tb_record_path's: in prepared mode the scratch directory,
  # so a prepare-host run with HOME unset (systemd, cloud-init, env -i) still records.
  _tb_record_armed && [[ -n "${TRACEBLOC_RECORD_HOME:-${HOME:-}}" ]] || return 0
  local rec dir now prior="" arts="" root_copy prepared_for prepared_gpu k3s_data_fs=""
  rec="$(tb_record_path)"; dir="${rec%/*}"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$dir" 2>/dev/null || { log "Install record: couldn't create ${dir}; not recorded."; return 0; }
  if [[ -f "$rec" ]]; then prior="$(cat "$rec" 2>/dev/null || true)"; fi
  if ! arts="$(printf '%s\n' "$prior" | _tb_record_artefacts)"; then
    log "Install record: couldn't read the artefacts in ${rec}; left as it is${1:+, ${1} ${2:-} not recorded}."
    return 0
  fi
  if [[ -n "${1:-}" ]]; then
    # A kind the schema does not declare would make the whole record invalid, so
    # it is refused by name and the record keeps what it had.
    case " ${TB_ARTEFACT_KINDS} " in
      *" $1 "*) ;;
      *) log "Install record: '${1}' is not an artefact kind the schema declares; not recorded."; return 0 ;;
    esac
    # FLAG: one boolean member the schema declares, NAME=true|false. Anything else
    # would make the whole record invalid, so it is refused by name like a kind.
    local flag=""
    if [[ -n "${4:-}" ]]; then
      local name="${4%%=*}" val="${4#*=}"
      if [[ "$name" == *[!a-z_]* || " ${TB_ARTEFACT_FLAGS} " != *" ${name} "* || ( "$val" != true && "$val" != false ) ]]; then
        log "Install record: '${4}' is not a NAME=true|false flag the schema declares; ${1} not recorded."; return 0
      fi
      flag="\"${name}\": ${val}, "
    fi
    # Keyed on kind + id + path, never the flag: a re-run that finds it already
    # recorded keeps the first line, its created_at and its flag. For a kind whose
    # last entry is the one in use (TB_RECORD_LAST_IN_USE), that line also moves to
    # the end, so a downgrade to a version recorded earlier is what the record
    # names last.
    local key line kept="" rest=""
    key="{\"kind\": $(_tb_json "$1"), \"id\": $(_tb_json "${2:-}"), \"path\": $(_tb_json "${3:-}"), "
    if [[ -n "${_tb_record_dropping:-}" ]]; then
      # tb_record_drop: every line under the key goes, and nothing is added.
      while IFS= read -r line; do
        [[ "$line" == "$key"* ]] || rest="${rest:+${rest}$'\n'}${line}"
      done <<<"$arts"
      arts="$rest"
    else
      case "$arts" in
        *"$key"*)
          case " ${TB_RECORD_LAST_IN_USE} " in
            *" $1 "*)
              while IFS= read -r line; do
                if [[ "$line" == "$key"* ]]; then kept="${kept:+${kept}$'\n'}${line}"; else rest="${rest:+${rest}$'\n'}${line}"; fi
              done <<<"$arts"
              arts="${rest:+${rest}$'\n'}${kept}" ;;
          esac ;;
        *) arts="${arts:+${arts}$'\n'}${key}${flag}\"created_at\": \"${now}\"}" ;;
      esac
    fi
  fi
  local substrate
  substrate="$(_tb_json "$TRACEBLOC_SUBSTRATE_RESOLVED")"
  # root_copy: the root copy's path once one exists. The previous write's value
  # stands until this run writes the copy; the first write that does re-renders
  # the user copy with it and copies again, so the two copies stay identical.
  root_copy="$(_tb_record_field root_copy "" "$prior")"
  # prepared_for: the user an administrator prepared this host for. Only prepared mode
  # (tb_record_for_user, prepare-host) names one; that user's own later writes keep the
  # previous write's value; any other record has none, so the key is left out.
  if [[ -n "${TB_RECORD_FOR_USER:-}" ]]; then prepared_for="$(_tb_json "$TB_RECORD_FOR_USER")"
  else prepared_for="$(_tb_record_prior prepared_for "$prior")"; fi
  # prepared_gpu_runtime, beside it: in prepared mode this run's value or null, never
  # the previous write's, so a prepare-host re-run that wires no GPU takes it away.
  # The user's own later writes keep it; any other record has none.
  if [[ -n "${TB_RECORD_FOR_USER:-}" ]]; then prepared_gpu="$(_tb_json "${TB_RECORD_PREPARED_GPU_RUNTIME:-}")"
  else prepared_gpu="$(_tb_record_prior "$TB_RECORD_PREPARED_GPU_KEY" "$prior")"; fi
  # k3s_data_fs (client-dev#1976): the filesystem under native k3s's data directory,
  # read afresh on every write of a native k3s install on Linux, the WSL distro
  # included, by k3s.sh's reader. A Mac writes none: the Mac's node runs
  # tracebloc's pinned VM image.
  if [[ "${OS:-}" == Linux && "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == k3s ]] && declare -F _native_k3s_data_fs >/dev/null 2>&1; then
    k3s_data_fs="$(_native_k3s_data_fs)"
  fi
  _tb_record_put "$rec" "$(_tb_record_render "$substrate" "$prior" "$arts" "$now" "$root_copy" "$prepared_for" "$k3s_data_fs" "$prepared_gpu")" || return 0
  _TB_RECORD_ROOT_WRITTEN=""
  _tb_record_root_copy "$rec"
  if [[ -n "$_TB_RECORD_ROOT_WRITTEN" && "$(_tb_json "$_TB_RECORD_ROOT_WRITTEN")" != "$root_copy" ]]; then
    root_copy="$(_tb_json "$_TB_RECORD_ROOT_WRITTEN")"
    _tb_record_put "$rec" "$(_tb_record_render "$substrate" "$prior" "$arts" "$now" "$root_copy" "$prepared_for" "$k3s_data_fs" "$prepared_gpu")" || return 0
    _tb_record_root_copy "$rec"
  fi
  _tb_record_user_copy "$rec"
  return 0
}

# tb_record_drop KIND ID PATH -- the artefact tb_record_write recorded under KIND ID
# PATH is gone: its line leaves both copies, through tb_record_write's own read, key
# and write (the local reaches it, as bash scopes it into its callees).
tb_record_drop() {
  local _tb_record_dropping=1
  tb_record_write "$1" "${2:-}" "${3:-}"
}

# The record's text: SUBSTRATE ($1) and ROOT_COPY ($5) as JSON literals, the
# previous write's text ($2), its artefact lines ($3) and the time ($4). PREPARED_FOR
# ($6), K3S_DATA_FS ($7) and PREPARED_GPU ($8), JSON literals, are written only when
# there is one.
_tb_record_render() {
  local out line n i
  out="{
  \"schema_version\": ${TB_INSTALL_RECORD_VERSION},
  \"substrate\": $1,
  \"user\": $(_tb_record_field user "$(_tb_record_user)" "$2"),
  \"cluster_name\": $(_tb_record_field cluster_name "${CLUSTER_NAME:-}" "$2"),
  \"kube_context\": $(_tb_record_field kube_context "$(_tb_kube_context)" "$2"),
  \"data_dir\": $(_tb_record_field data_dir "${HOST_DATA_DIR:-}" "$2"),
  \"namespace\": $(_tb_record_field namespace "${TB_NAMESPACE:-}" "$2"),
  \"installer_version\": $(_tb_record_field installer_version "${TB_VERSION:-}" "$2"),
  \"root_copy\": $5,"
  if [[ -n "${6:-}" ]]; then out+=$'\n  "prepared_for": '"$6"','; fi
  if [[ -n "${8:-}" ]]; then out+=$'\n  "'"${TB_RECORD_PREPARED_GPU_KEY}"'": '"$8"','; fi
  if [[ -n "${7:-}" ]]; then out+=$'\n  "k3s_data_fs": '"$7"','; fi
  out+="
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
  local user="${TB_RECORD_FOR_USER:-}" dst
  [[ -n "$user" ]] || user="$(id -un 2>/dev/null)" || return 0
  [[ -n "$user" ]] || return 0
  dst="$(_tb_record_root_path "$user")"
  if tb_root_n true 2>/dev/null; then
    if { tb_root_n mkdir -p "${dst%/*}" && tb_root_n cp "$1" "$dst"; } 2>/dev/null; then _TB_RECORD_ROOT_WRITTEN="$dst"
    else log "Install record: couldn't write the root copy ${dst}."; fi
  fi
  return 0
}

# The root copy's path for this user. Fails when the user has no name.
_tb_record_root_copy_path() {
  local user
  user="$(id -un 2>/dev/null)" || return 1
  [[ -n "$user" ]] || return 1
  _tb_record_root_path "$user"
}

# Whether this process can reach the root copy at all: it is root, or its sudo
# needs no password. Never prompts.
_tb_record_root_access() {
  [[ "$(id -u 2>/dev/null)" == "0" ]] && return 0
  _have_sudo_bin && _real_sudo -n true 2>/dev/null
}

# _tb_record_root_run CMD... -- CMD as root: directly when this is root, else
# through the password-free sudo _tb_record_root_access found.
_tb_record_root_run() {
  if [[ "$(id -u 2>/dev/null)" == "0" ]]; then "$@"; return; fi
  _real_sudo -n "$@"
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
  curl -fsSL https://tracebloc.io/i.sh | bash
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

Advanced configuration (environment variables; each one's older name without
the TRACEBLOC_ prefix -- TB_STORAGE_MODE for TRACEBLOC_STORAGE_MODE -- still works):
  TRACEBLOC_CLUSTER_NAME   Cluster name     (default: tracebloc)
  TRACEBLOC_NAMESPACE  Secure-environment name  (default: tracebloc; legacy: TB_NAMESPACE)
  TRACEBLOC_HELM_VERSION   Helm release tag (default: v4.2.3; "latest" resolves at install time)
  TRACEBLOC_STORAGE_MODE   node-local (default) or hostpath
  TRACEBLOC_HOST_DATASET_DIR  Separate dataset directory, e.g. a network mount (hostpath only)
  TRACEBLOC_HOST_DATA_DIR  Persistent data directory  (default: ~/.tracebloc; legacy: HOST_DATA_DIR)
                 Must be on a LOCAL disk — NFS/CIFS/SMB is rejected (the database
                 corrupts on network storage). TRACEBLOC_ALLOW_NETWORK_FS=1 overrides.

Example use case:
  After a connected install, the tracebloc CLI you signed in with sets up your
  account's example use case, once per account. Set TRACEBLOC_SKIP_EXAMPLE=1 to
  skip it.

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
  irm https://tracebloc.io/i.ps1 | iex

Learn more: https://docs.tracebloc.io
HELP
  _tb_done=1   # an intended exit 0 under install_cleanup (tb_exit_rc, client-dev#1752)
  exit 0
}
