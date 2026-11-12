#!/usr/bin/env bash
# =============================================================================
#  download.sh — how this installer fetches: curl_secure, the sha256 and size
#  checks of what it fetched, and what a live line's downloads brought in
#  (tb_live_expect, _tb_dl_*). Sourced by install-k8s.sh.
# =============================================================================

# Minimum TLS version, as a bare flag. Retained for backward compatibility only
# (an out-of-tree caller may still splice it in by hand); everything in this repo
# goes through curl_secure() below, which names the flag itself rather than
# reading this — so growing this constant can never silently reshape every fetch
# in the installer. It must stay a SINGLE flag regardless: two call sites
# historically quoted it ("$CURL_SECURE"), and a space-separated value collapses
# into one argv element that curl rejects.
readonly CURL_SECURE="--tlsv1.2"

# curl_secure — the one way this installer fetches anything.
#
# The TLS floor used to be opt-in: every call site had to remember to splice
# $CURL_SECURE in, and seven of them had silently lost it — including the POST
# that carries the client's password. A wrapper makes the floor
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
  (( _stall_bounded )) || _bounds+=(--max-time "${TRACEBLOC_CURL_MAX_TIME:-300}")
  # A download the live line shows (a terminal only): _tb_dl_curl, the same call.
  if _tb_dl_watch "$@"; then
    _tb_dl_curl "$_TB_DL_K" "${_bounds[@]}" "$@"  # set-u-safe: always carries --connect-timeout
    return
  fi
  # checker false positive: _bounds ALWAYS carries --connect-timeout (plus
  # --max-time unless the call stall-bounds itself) — flags inside a bash
  # array expansion are invisible to the grep. house-rules: ignore=curl-timeout
  curl --tlsv1.2 "${_bounds[@]}" "$@"  # set-u-safe: always carries --connect-timeout
}

# Verify FILE against an EXPECTED sha256, portably and FAIL-CLOSED. Linux ships
# sha256sum (coreutils); macOS ships NO sha256sum but has shasum -a 256 — so the
# same pinned-download verification works on both. We feed "<hash>  <file>"
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
  # prints its usage and exits 1 (measured on 26.6.2), so on real
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
# . On a filtered network a proxy or antivirus can return a truncated stream
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

# ── What a live line's downloads brought in ─────────────────────────────────
#  Animating, every download this installer's own curl makes while a live line runs
#  (curl_secure with -o FILE) is watched: the bytes in FILE, and its size from the
#  answer's headers (curl -D). Once a second the ticker adds them up and shows them
#  after the time spent:
#    ⠋ Installing system tools...  2m 19s · 63% · 8.4 MB/s     every size known
#    ⠋ Installing system tools...  1m 05s · 17 MB · 4.2 MB/s    a size not known
#  The share is shown only when the line was told every download it makes before the
#  first byte (tb_live_expect) and every size is known: it is never estimated. The
#  speed is the average over the last _TB_DL_WINDOW_S seconds, shown while a download
#  runs. Plain, nothing is watched or shown, and the log gets nothing new; animating,
#  it gets one line per download, its size and the time it took.
#  One folder per line (_TB_DL_DIR, made by _tb_live_begin, removed when the line
#  ends; a scratch folder, so every EXIT trap's tb_scratch_reap drops it on an abort),
#  so a download in any subshell reaches the ticker. A download is K.* in it,
#  K its URL made a file name (_tb_dl_key), so a retry starts the same download again:
#    K.url  its URL           K.out   the file curl writes, while it runs
#    K.hdr  curl's headers    K.done  the bytes it wrote, once it ended
#    K.size its size, when the server said it or the download ended
#    K.plan  the line was told this download (tb_live_expect): a failure keeps its K.url
#  and `planned` marks a line that was told its downloads.
_TB_DL_WINDOW_S=5
_TB_DL_K=""

# tb_live_watching -- the live line shows what downloads bring in (a terminal).
tb_live_watching() { [[ -n "${_TB_DL_DIR:-}" && -d "$_TB_DL_DIR" ]]; }

# tb_live_expect URL [CURL-ARG...] -- tell the live line, before its first download
# starts, that it will download URL, and ask the server its size: one byte of it,
# whose answer names the whole (Content-Range), with CURL-ARG (a pull token) as the
# download sends them. --max-filesize stops a server that ignores the range after its
# headers. A size it does not learn leaves the line its bytes. An empty URL is a
# download whose address the line cannot name yet, so no share is shown. Nothing when
# no live line is watching.
tb_live_expect() {
  local url="$1" k size=""
  shift
  tb_live_watching || return 0
  : >"${_TB_DL_DIR}/planned" 2>/dev/null || return 0
  if [[ -z "$url" ]]; then
    printf 'unknown\n' >"${_TB_DL_DIR}/unknown.url" 2>/dev/null || true
    return 0
  fi
  k="${_TB_DL_DIR}/$(_tb_dl_key "$url")"
  printf '%s\n' "$url" >"${k}.url" 2>/dev/null || return 0
  : >"${k}.plan" 2>/dev/null || true
  # || true inside: a server that ignores the range ends curl at --max-filesize, after
  # it printed the headers this reads.
  size="$({ curl_secure -sSL --max-time 15 -r 0-0 --max-filesize 1 -o /dev/null -D - "$@" "$url" 2>/dev/null || true; } | _tb_dl_header_size)" || size=""
  if [[ -n "$size" ]]; then
    printf '%s\n' "$size" >"${k}.size" 2>/dev/null || true
  else
    log "The live line could not learn the size of ${url}; it shows the bytes, not a share."
  fi
  return 0
}

# _tb_dl_key URL -- URL as a file name in the line's folder: no slash, at most 100 bytes.
_tb_dl_key() {
  local k="${1//[!A-Za-z0-9._-]/_}"
  (( ${#k} <= 100 )) || k="${k:$(( ${#k} - 100 ))}"
  printf '%s' "$k"
}

# _tb_dl_header_size -- the size a download's headers (on stdin, curl -D) give for the
# whole file: the last answer's Content-Range total on a 206, its Content-Length on
# any other 2xx. Nothing when they give none (a chunked answer, an error).
_tb_dl_header_size() {
  awk '{ l = tolower($0); sub(/\r$/, "", l) }
    l ~ /^http\// { st = $2; len = ""; rng = "" }
    l ~ /^content-length:/ { len = l; sub(/^content-length:[ \t]*/, "", len) }
    l ~ /^content-range:/ { rng = l; sub(/^.*\//, "", rng) }
    END {
      if (st == "206") { if (rng ~ /^[0-9]+$/) print rng }
      else if (st ~ /^2/ && len ~ /^[0-9]+$/) print len
    }'
}

# _tb_dl_watch CURL-ARG... -- a download the live line shows: curl writes a file (-o),
# a live line is watching, and the call keeps no headers of its own (-D). Starts its
# entry (_TB_DL_K, the path without the suffix) over again, as a retry starts the file
# over.
_tb_dl_watch() {
  local a prev="" out="" url="" k
  _TB_DL_K=""
  tb_live_watching || return 1
  for a in "$@"; do
    case "$prev" in -o|--output) out="$a" ;; esac
    case "$a" in
      -D|--dump-header) return 1 ;;
      http://*|https://*) url="$a" ;;
    esac
    prev="$a"
  done
  [[ -n "$url" && -n "$out" && "$out" != /dev/null && "$out" != - ]] || return 1
  [[ "$out" == /* ]] || out="${PWD}/${out}"
  k="${_TB_DL_DIR}/$(_tb_dl_key "$url")"
  # The file a failed attempt left is not this attempt's bytes: curl truncates it only
  # when its first byte arrives, after the ticker reads K.out.
  [[ ! -s "$out" ]] || : >"$out" 2>/dev/null || true
  rm -f "${k}.done" 2>/dev/null || true
  { : >"${k}.hdr" && printf '%s\n' "$url" >"${k}.url" && printf '%s\n' "$out" >"${k}.out"; } 2>/dev/null || return 1
  _TB_DL_K="$k"
}

# _tb_dl_curl K CURL-ARG... -- curl_secure's call for a download the live line shows
# (_tb_dl_watch): the same call, with its headers into K.hdr; then what it wrote.
_tb_dl_curl() {
  local k="$1" t0=$SECONDS rc=0
  shift
  # house-rules: ignore=curl-timeout -- curl_secure passes its bounds in.
  curl --tlsv1.2 -D "${k}.hdr" "$@" || rc=$?
  _tb_dl_end "$k" "$rc" "$t0"
  return "$rc"
}

# _tb_dl_end K RC T0 -- the download K ended with curl's RC, started at T0 (SECONDS).
# Done, its bytes are its size, and the log gets one line: its size and the time it
# took. Failed, it is not running any more: a retry starts it again, or the run stops.
_tb_dl_end() {
  local k="$1" out="" b url=""
  if [[ "$2" -eq 0 ]]; then
    read -r out 2>/dev/null <"${k}.out" || true
    read -r url 2>/dev/null <"${k}.url" || true
    b="$(wc -c 2>/dev/null <"$out")" || b=0
    b="${b//[!0-9]/}"
    { printf '%s\n' "${b:-0}" >"${k}.size" && printf '%s\n' "${b:-0}" >"${k}.done"; } 2>/dev/null || true
    log "Downloaded ${url##*/}: $(_tb_dl_bytes "${b:-0}") in $(_tb_elapsed $(( SECONDS - $3 )))"
  else
    rm -f "${k}.out" "${k}.hdr" 2>/dev/null || true
    # A download nobody planned has no size to wait for: it leaves nothing for _tb_dl_sample.
    [[ -e "${k}.plan" ]] || rm -f "${k}.url" 2>/dev/null || true
  fi
}

# _tb_dl_drop -- the line's folder removed (its owner, when the line ends).
_tb_dl_drop() {
  [[ -z "${_TB_DL_DIR:-}" ]] || tb_scratch_rm "$_TB_DL_DIR"
  _TB_DL_DIR=""
}

# _tb_dl_sample DIR -- the line's downloads added up, into _TB_DL_BYTES (bytes so far),
# _TB_DL_TOTAL (their sizes), _TB_DL_KNOWN (1: the line was told its downloads, and
# every size is known), _TB_DL_RUNNING (1: one is running) and _TB_DL_STARTED (1: one
# started). A download nobody planned whose answer has not come yet counts nothing,
# and misses nothing either; a planned one whose size was not learned keeps the share
# unknown.
_tb_dl_sample() {
  local f k p b t
  _TB_DL_BYTES=0; _TB_DL_TOTAL=0; _TB_DL_KNOWN=0; _TB_DL_RUNNING=0; _TB_DL_STARTED=0
  [[ ! -e "$1/planned" ]] || _TB_DL_KNOWN=1
  for f in "$1"/*.url; do
    [[ -e "$f" ]] || continue
    k="${f%.url}"; b=0; t=""
    [[ ! -s "${k}.size" ]] || read -r t 2>/dev/null <"${k}.size" || true
    if [[ -s "${k}.done" ]]; then
      read -r b 2>/dev/null <"${k}.done" || true
      _TB_DL_STARTED=1
    elif [[ -s "${k}.out" ]]; then
      _TB_DL_STARTED=1; _TB_DL_RUNNING=1
      p=""; read -r p 2>/dev/null <"${k}.out" || true
      b="$(wc -c 2>/dev/null <"$p")" || b=0
      [[ -n "$t" || ! -s "${k}.hdr" ]] || t="$(_tb_dl_header_size <"${k}.hdr")"
      [[ -n "$t" || -s "${k}.hdr" || -e "${k}.plan" ]] || t=0
    fi
    b="${b//[!0-9]/}"; t="${t//[!0-9]/}"
    [[ -n "$t" ]] || _TB_DL_KNOWN=0
    _TB_DL_BYTES=$(( _TB_DL_BYTES + ${b:-0} )); _TB_DL_TOTAL=$(( _TB_DL_TOTAL + ${t:-0} ))
  done
}

# _tb_dl_tick DIR NOW -- the ticker's once-a-second read of the line's downloads at
# NOW (SECONDS): _TB_DL_TAIL is what follows the time spent. _TB_DL_RING keeps the
# samples of the last _TB_DL_WINDOW_S seconds ("SECONDS BYTES" pairs, oldest first)
# for the speed; a count that went down (a retry starting over) starts them again.
_tb_dl_tick() {
  local now="$2" rate=""
  _tb_dl_sample "$1"
  _TB_DL_TAIL=""
  if (( ! _TB_DL_STARTED )); then _TB_DL_RING=""; _TB_DL_PREV=0; return 0; fi
  (( _TB_DL_BYTES >= _TB_DL_PREV )) || _TB_DL_RING=""
  _TB_DL_PREV=$_TB_DL_BYTES
  _TB_DL_RING="${_TB_DL_RING:+$_TB_DL_RING }${now} ${_TB_DL_BYTES}"
  # shellcheck disable=SC2086  # the pairs split into words on purpose
  set -- $_TB_DL_RING
  while (( $# > 2 && now - $1 > _TB_DL_WINDOW_S )); do shift 2; done
  _TB_DL_RING="$*"
  if (( _TB_DL_RUNNING && now > $1 )); then rate=$(( (_TB_DL_BYTES - $2) / (now - $1) )); fi
  _TB_DL_TAIL="$(_tb_dl_tail "$_TB_DL_BYTES" "$_TB_DL_TOTAL" "$_TB_DL_KNOWN" "$rate")"
}

# _tb_dl_tail BYTES TOTAL KNOWN [RATE] -- " · 63% · 8.4 MB/s": the share of TOTAL when
# KNOWN is 1, else the bytes; then RATE (bytes a second), when given.
_tb_dl_tail() {
  local s
  if [[ "$3" == 1 ]] && (( $2 > 0 )); then
    s=$(( $1 * 100 / $2 )); (( s <= 100 )) || s=100
    s="${s}%"
  else
    s="$(_tb_dl_bytes "$1")"
  fi
  printf ' · %s' "$s"
  [[ -z "${4:-}" ]] || printf ' · %s' "$(_tb_dl_rate "$4")"
}

# _tb_dl_bytes BYTES -- "64 bytes", "640 KB", "312 MB", "1.2 GB", whole units rounded
# down (1 MB = 1024 KB, as the installer's other sizes count).
_tb_dl_bytes() {
  local b="${1:-0}"
  if (( b < 1024 )); then printf '%s bytes' "$b"
  elif (( b < 1048576 )); then printf '%s KB' "$(( b / 1024 ))"
  elif (( b < 1073741824 )); then printf '%s MB' "$(( b / 1048576 ))"
  else printf '%s.%s GB' "$(( b / 1073741824 ))" "$(( b % 1073741824 * 10 / 1073741824 ))"
  fi
}
# _tb_dl_rate BYTES -- BYTES a second: "640 KB/s", or MB/s to the nearest tenth, "8.4 MB/s".
_tb_dl_rate() {
  local r="${1:-0}" t
  t=$(( (r + 512) / 1024 ))
  if (( t < 1024 )); then printf '%s KB/s' "$t"; return; fi
  t=$(( (r * 10 + 524288) / 1048576 ))
  printf '%s.%s MB/s' "$(( t / 10 ))" "$(( t % 10 ))"
}
