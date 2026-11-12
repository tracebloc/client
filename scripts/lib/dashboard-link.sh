#!/usr/bin/env bash
# =============================================================================
#  dashboard-link.sh — the end of an interactive install: open the dashboard
#  as "this machine" with a one-time link, or print it to the terminal.
# =============================================================================

# ── Open the dashboard as "this machine" (the install link) ─────────────────
# At the end of an interactive install the installer opens the dashboard with a
# one-time link that marks the browser as on this machine, so the page shows
# "You're on this machine" without asking the local API first.
#
#   1. api-token-auth/ with the machine credential -> the client's token (the
#      same call verify_credentials and jobs-manager make; for a client it is the
#      token jobs-manager already uses, never a new one, so nothing is revoked);
#   2. POST local-session/link/ with that token -> {"url": ...}, a dashboard URL
#      whose fragment carries a one-time ticket: five minutes, one use, and only
#      for a signed-in user who may reach this client;
#   3. open it: `open` on macOS, `xdg-open` on a Linux desktop, Start-Process
#      through interop in WSL. With no browser to open it in, it is printed.
#
# THE LINK IS A BEARER CAPABILITY. It never reaches the install log, telemetry
# or argv-visible curl flags: the password goes to curl on stdin, the token as a
# header read from stdin, and a link that must be printed goes to the terminal
# ($TRACEBLOC_TTY) only, never to stdout, which the install log tees.
#
# IT NEVER FAILS THE INSTALL. Every step answers "no link" on any failure (a
# backend without the endpoint answers 404, an older one or a proxy something
# else), and the caller carries on silently: the summary already printed the
# plain dashboard URL. Every function here returns 0 unless it says otherwise.

# The one shape of URL this installer will hand to a browser: https, a host, a
# path, and the ticket in the fragment as url-safe base64. Anything else (an
# unexpected answer, a host the backend did not mean) is not opened or printed.
_dashboard_link_url_ok() {
  [[ "${1:-}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9/_-]*#local-session-link=[A-Za-z0-9_-]{32,128}$ ]]
}

# _dashboard_link_json_field JSON KEY -- a string field of a compact JSON object,
# or nothing. No jq or python3 here (neither is a prerequisite); every value read
# with it is a token or a URL, which carry no quote or backslash.
_dashboard_link_json_field() {
  local out
  out="$(sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"\\\\]*\)\".*/\1/p" <<<"${1:-}")"
  printf '%s' "${out%%$'\n'*}"
}

# _dashboard_link_mint ID PASSWORD -- the install link's URL on stdout, or nothing.
# _dashboard_link_mint runs with bash -x held off, the secret it holds out of the trace (output.sh);
# _tb_untraced__dashboard_link_mint below is the function itself.
_dashboard_link_mint() { { _tb_trace_off; } 2>/dev/null; _tb_untraced__dashboard_link_mint "$@"; local _tb_rc=$?; _tb_trace_on; return "$_tb_rc"; }
_tb_untraced__dashboard_link_mint() {
  local client_id="${1:-}" client_password="${2:-}" backend body token scheme url
  [[ -n "$client_id" && -n "$client_password" ]] || return 0
  backend="$(_backend_url)"
  body="$(printf '%s' "$client_password" | curl_secure -sS -f -m 30 \
    --data-urlencode "username=${client_id}" \
    --data-urlencode "password@-" \
    "${backend}api-token-auth/" 2>/dev/null)" || return 0
  token="$(_dashboard_link_json_field "$body" token)"
  scheme="$(_dashboard_link_json_field "$body" token_scheme)"
  [[ -n "$token" ]] || return 0
  case "$scheme" in Token|Bearer) ;; *) scheme="Token" ;; esac
  body="$(printf 'Authorization: %s %s\n' "$scheme" "$token" | curl_secure -sS -f -m 30 \
    -H @- -H "Accept: application/json" --data "" \
    "${backend}local-session/link/" 2>/dev/null)" || return 0
  url="$(_dashboard_link_json_field "$body" url)"
  _dashboard_link_url_ok "$url" || return 0
  printf '%s' "$url"
}

# _dashboard_link_credential -- "ID<newline>PASSWORD" for this machine's client:
# the release's Secret first (what its pods authenticate with, on every path,
# the adopt and re-run ones included), else this run's TB_CLIENT_ID /
# TB_CLIENT_PASSWORD. Nothing when neither is readable.
# _dashboard_link_credential runs with bash -x held off, the secret it holds out of the trace (output.sh);
# _tb_untraced__dashboard_link_credential below is the function itself.
_dashboard_link_credential() { { _tb_trace_off; } 2>/dev/null; _tb_untraced__dashboard_link_credential "$@"; local _tb_rc=$?; _tb_trace_on; return "$_tb_rc"; }
_tb_untraced__dashboard_link_credential() {
  local ns="${namespace:-}" id="" pw=""
  if [[ -n "$ns" ]]; then
    id="$(_client_id_from_secret "$ns" "$ns")"
    pw="$(_client_password_from_secret "$ns" "$ns")" || pw=""
  fi
  if [[ -z "$id" || -z "$pw" ]]; then
    id="${TB_CLIENT_ID:-}"; pw="${TB_CLIENT_PASSWORD:-}"
  fi
  [[ -n "$id" && -n "$pw" ]] || return 0
  printf '%s\n%s' "$id" "$pw"
}

# _dashboard_link_open URL -- hand URL to this machine's browser. 0 when an opener
# took it, 1 when there is none to take it (no desktop, root, no opener) or the run
# came over ssh: a browser here would open on this machine's screen, not in front
# of whoever runs the install (tb_over_ssh).
_dashboard_link_open() {
  local url="$1" ps="" fallback
  _dashboard_link_url_ok "$url" || return 1
  ! tb_over_ssh || return 1
  if declare -F _probe_wsl >/dev/null 2>&1 && _probe_wsl; then
    # The browser is the Windows host's. The URL is validated above, so it
    # carries no quote to break out of the single-quoted PowerShell string.
    fallback="${TRACEBLOC_WINDOWS_POWERSHELL:-/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe}"
    if command -v powershell.exe >/dev/null 2>&1; then ps="powershell.exe"
    elif [[ -x "$fallback" ]]; then ps="$fallback"
    fi
    [[ -n "$ps" ]] || return 1
    _bounded "${TB_WSL_INTEROP_TIMEOUT:-20}" "$ps" -NoProfile -NonInteractive \
      -Command "Start-Process '$url'" >/dev/null 2>&1 || return 1
    return 0
  fi
  # A browser started as root is the wrong user's (or refuses to start).
  [[ "$(id -u 2>/dev/null)" != 0 ]] || return 1
  case "${OS:-$(uname -s)}" in
    Darwin)
      has open || return 1
      open "$url" >/dev/null 2>&1 || return 1
      ;;
    Linux)
      # A desktop session. XWayland sets DISPLAY on the common Wayland desktops
      # too; with no DISPLAY the link is printed instead.
      [[ -n "${DISPLAY:-}" ]] || return 1
      has xdg-open || return 1
      _bounded 15 xdg-open "$url" >/dev/null 2>&1 || return 1
      ;;
    *) return 1 ;;
  esac
  return 0
}

# _dashboard_link_interactive -- a person is at this install: a terminal that can
# really be OPENED, for reading and for the print. Mode bits say yes for a
# /dev/tty with no controlling terminal (the house probe, _tty_usable and
# _login_tty_ok, opens it for that reason), and `>` would truncate a regular file
# a case names as TRACEBLOC_TTY, so this opens it for append.
_dashboard_link_interactive() {
  local tty="${TRACEBLOC_TTY:-/dev/tty}"
  { : <"$tty" >>"$tty"; } 2>/dev/null
}

# open_dashboard_link -- before the summary of a connected install: opens the
# dashboard, and says so to the summary (_TB_DASHBOARD_OPENED, its first next step),
# or keeps a link with no browser to open it in for print_dashboard_link. Prints
# nothing itself.
_TB_DASHBOARD_OPENED=""; _TB_DASHBOARD_LINK=""
# open_dashboard_link runs with bash -x held off, the secret it holds out of the trace (output.sh);
# _tb_untraced_open_dashboard_link below is the function itself.
open_dashboard_link() { { _tb_trace_off; } 2>/dev/null; _tb_untraced_open_dashboard_link "$@"; local _tb_rc=$?; _tb_trace_on; return "$_tb_rc"; }
_tb_untraced_open_dashboard_link() {
  _TB_DASHBOARD_OPENED=""; _TB_DASHBOARD_LINK=""
  [[ "${TRACEBLOC_CLIENT_STATE:-}" == "connected" ]] || return 0
  _dashboard_link_interactive || return 0
  local cred id pw url
  cred="$(_dashboard_link_credential)"
  id="${cred%%$'\n'*}"; pw="${cred#*$'\n'}"
  url="$(_dashboard_link_mint "$id" "$pw")"
  cred=""; pw=""
  if [[ -z "$url" ]]; then
    log "Dashboard link: not available; the summary's dashboard URL stands."
    return 0
  fi
  if _dashboard_link_open "$url"; then
    log "Dashboard link: opened in the browser."
    _TB_DASHBOARD_OPENED=1
    return 0
  fi
  log "Dashboard link: no browser to open it in; printed to the terminal only."
  _TB_DASHBOARD_LINK="$url"
  return 0
}

# print_dashboard_link -- after the summary: the link open_dashboard_link had no
# browser to open in, to the terminal only (never the log; it signs in once).
print_dashboard_link() {
  [[ -n "${_TB_DASHBOARD_LINK:-}" ]] || return 0
  {
    printf '  Open your dashboard in a browser on this machine.\n'
    printf '  This link works once, for 5 minutes:\n'
    printf '    %s\n\n' "$_TB_DASHBOARD_LINK"
  } >"${TRACEBLOC_TTY:-/dev/tty}" 2>/dev/null || true
  _TB_DASHBOARD_LINK=""
  return 0
}
