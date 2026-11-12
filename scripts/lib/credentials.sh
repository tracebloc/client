#!/usr/bin/env bash
# =============================================================================
#  credentials.sh — the client's credentials: read back from an installed
#  release's secret, cleaned as typed, the workspace name made DNS-safe, and
#  checked against the backend (_backend_url, verify_credentials).
#  install_client_helm (install-client-helm.sh), provisioning (provision.sh)
#  and the assess step (assess.sh) call them.
# =============================================================================

# YAML single-quoted-scalar escaping, in one place.
#
# A YAML single-quoted string escapes a quote by DOUBLING it: a'b -> 'a''b'.
# Both directions must build the replacement from a VARIABLE, never a `\'`
# literal: bash 3.2 (the macOS system bash) keeps the backslash in an escaped-quote
# REPLACEMENT, so "${v//\'/\'\'}" yields a\'\'b and corrupts the value. A variable
# expands to a bare quote on 3.2 and 4/5 alike. Verified on GNU bash 3.2.57:
#   input a'b -> escaped-literal form a\'\'b (WRONG) · variable form a''b (right)
#
# Keep these two as the ONLY place that rule is encoded — every credential written
# into or read back out of the generated values file goes through them, so the
# portability constraint can't drift between call sites.
_yaml_sq_escape() {                      # raw value -> body of a '...' scalar
  local _sq="'"
  printf '%s' "${1//$_sq/$_sq$_sq}"
}
_yaml_sq_unescape() {                    # body of a '...' scalar -> raw value
  local _sq="'"
  printf '%s' "${1//$_sq$_sq/$_sq}"
}

# _extract_yaml_value — value of top-level scalar key $2 in values file $1 (`-`
# reads STDIN, so a caller can pipe values in without writing them to a file).
# CONTRACT: echoes nothing and returns 0 when the key is absent (or the file is
# unreadable). Callers rely on "empty means no value"; they must not have to
# distinguish absent-key from read-error, and none of them do.
_extract_yaml_value() {
  local file="$1" key="$2"
  local line
  # `|| line=""`: on an ABSENT key grep exits 1 and, under `set -o pipefail`,
  # that rc propagates out of the pipeline and out of the assignment — so under
  # `set -e` the installer would abort HERE and never reach the empty-check on
  # the next line, the very line that exists to handle "key not found".
  # Latent until now only because every call site wraps this in `$( )`, which
  # suspends errexit for the function body; a bare call aborts the install
  # mid-step. Same house idiom as assess.sh / kube.sh `_chart_version`.
  #
  # NO `| head -1` on the pipeline: with head in play, a DUPLICATE key makes
  # head exit after the first line and SIGPIPE grep (141) — and under pipefail
  # `|| line=""` would then wipe the successfully captured value, so
  # detect_installed_client could miss a clientId and fail open toward
  # overwrite. Capture every match, then take the first line in
  # the shell, where nothing can signal anything: grep's rc is 1 only when
  # there is genuinely no match.
  line=$(grep -E "^${key}:" "$file" 2>/dev/null) || line=""
  line="${line%%$'\n'*}"
  [[ -z "$line" ]] && return
  line="${line#*:}"
  line="${line#"${line%%[![:space:]]*}"}"
  if [[ "$line" == \'*\' ]]; then
    line="${line#\'}"
    line="${line%\'}"
    line="$(_yaml_sq_unescape "$line")"
  else
    line="${line#\"}"
    line="${line%\"}"
  fi
  # Defend against self-perpetuation: a previous corrupted save may have the
  # bracketed-paste markers and/or C0 controls. _strip_paste_garbage
  # handles both. UTF-8 (0x80+) preserved.
  _strip_paste_garbage "$line"
}

# _client_id_from_secret_rows ROWS — the base64 client id out of
# `NAME TRACEBLOC_CLIENT_ID CLIENT_ID` rows (the custom-columns read below), or
# nothing. PURE, so the guard and the tests can drive it without a cluster.
# CANONICAL KEY FIRST: the chart writes the id under TRACEBLOC_CLIENT_ID (both
# keys from 1.9.180, the canonical only since then); a Secret
# written by an older chart has only CLIENT_ID, so the legacy column is the
# fallback when the canonical prints `<none>`. Exactly ONE row may carry an id: none is a release whose
# Secret is not there, and two cannot be told apart, so either is "couldn't read
# it" -- never a guess. A Secret without either key (the registry pull Secret)
# prints `<none>` and is not a candidate.
_client_id_from_secret_rows() {
  local rows="$1" name canon legacy b64 hit="" n=0
  while read -r name canon legacy _; do
    b64="$canon"
    [[ -n "$b64" && "$b64" != "<none>" ]] || b64="$legacy"
    [[ -n "$name" && -n "$b64" && "$b64" != "<none>" ]] || continue
    hit="$b64"; n=$((n + 1))
  done <<<"$rows"
  (( n == 1 )) || return 0
  printf '%s' "$hit"
  return 0
}

# _client_id_from_secret — CLIENT_ID out of release $1's chart-managed Secret in
# namespace $2, or empty. THE SECOND PLACE THE ID CAN LIVE: the chart lets
# clientId resolve from the Secret instead of release values, and the chart now
# recommends dropping it from values once it is there — so "no clientId in
# values" stopped meaning "not a client" and detect_installed_client has to look
# here before it may conclude anything.
# THE SECRET IS READ FROM THE RELEASE, NEVER NAMED. The chart
# names it `tracebloc.secretName` -- `<fullnameOverride or release>-secrets` --
# and rebuilding that here restated the chart's rule from `helm get values`, so
# the lookup was right only while the two copies agreed and nothing compared
# them. The Secrets are listed by `app.kubernetes.io/instance=<release>` instead
# (the label the chart's `tracebloc.labels` puts on it, which by the chart's own
# table never follows the override), and the one carrying the id is the one --
# under TRACEBLOC_CLIENT_ID, else CLIENT_ID (see _client_id_from_secret_rows).
# Same shape as _client_workloads, custom-columns rather than a
# jsonpath like it (chosen while the retired PowerShell core had to quote the
# same read). Guard:
# scripts/tests/client-secret-read-not-built.sh.
# CONTRACT: echoes the id or nothing, and ALWAYS returns 0. Callers assign it
# inside `$( )`; a non-zero rc there would abort the installer under `set -e`
# (the same trap _extract_yaml_value documents above), and "couldn't read it" is
# a state the caller handles, not an error it should die on.
_client_id_from_secret() {
  local rel="$1" ns="$2" rows b64 out=""
  # kubectl is not guaranteed this early (the pre-provision pre-flight runs
  # before the cluster exists), and its absence is "couldn't read", not "absent".
  has kubectl || return 0
  # BOUNDED, because this call is now on the COMMON path. Once
  # clientId is dropped from release values — which this chart recommends — every
  # scanned release reaches here, so an unbounded read against a wedged API would
  # hang a headless install or assess with no further output. kubectl's default
  # is no timeout at all; 5s matches the other existence probes in this repo.
  # A timeout exits
  # non-zero and is handled by the same `|| return 0` as any other unreadable
  # Secret: "couldn't read it" is a state the caller already knows how to treat,
  # and the caller's fail-closed path turns it into an unidentifiable client
  # rather than an absent one.
  rows="$(kubectl get secret -n "$ns" -l "app.kubernetes.io/instance=${rel}" \
            -o 'custom-columns=NAME:.metadata.name,TRACEBLOC_CLIENT_ID:.data.TRACEBLOC_CLIENT_ID,CLIENT_ID:.data.CLIENT_ID' \
            --no-headers --request-timeout=5s 2>/dev/null)" || return 0
  b64="$(_client_id_from_secret_rows "$rows")"
  [[ -n "$b64" ]] || return 0
  # -d is GNU/coreutils and modern macOS; -D is the older BSD spelling, so both
  # are tried in turn.
  out="$(printf '%s' "$b64" | base64 -d 2>/dev/null)" \
    || out="$(printf '%s' "$b64" | base64 -D 2>/dev/null)" \
    || out=""
  printf '%s' "$out"
  return 0
}

# _client_password_from_secret REL NS — the machine credential the client's pods
# authenticate with, from the release's Secret (canonical key first, the legacy
# one as fallback). Same bounded, one-Secret read as _client_id_from_secret; the
# value never reaches argv (verify_credentials feeds it to curl on stdin).
# CONTRACT: echoes the password and returns 0; echoes nothing and returns 0 when
# the release has no Secret carrying a password (a first install); echoes
# nothing and returns 2 when it CANNOT TELL -- no kubectl, a failed or timed-out
# read, two Secrets carrying one, a value that does not decode. The two empties
# are different facts: the restart after helm reads "absent" as "no pod holds an
# old credential" and "cannot tell" as "maybe one does".
# Callers in `$( )` under `set -e` must handle the 2 (`|| …`).
# _client_password_from_secret runs with bash -x held off, the secret it holds out of the trace (output.sh);
# _tb_untraced__client_password_from_secret below is the function itself.
_client_password_from_secret() { { _tb_trace_off; } 2>/dev/null; _tb_untraced__client_password_from_secret "$@"; local _tb_rc=$?; _tb_trace_on; return "$_tb_rc"; }
_tb_untraced__client_password_from_secret() {
  local rel="$1" ns="$2" rows b64 out="" name canon legacy n=0
  has kubectl || return 2
  rows="$(kubectl get secret -n "$ns" -l "app.kubernetes.io/instance=${rel}" \
            -o 'custom-columns=NAME:.metadata.name,TRACEBLOC_CLIENT_PASSWORD:.data.TRACEBLOC_CLIENT_PASSWORD,CLIENT_PASSWORD:.data.CLIENT_PASSWORD' \
            --no-headers --request-timeout=5s 2>/dev/null)" || return 2
  b64="$(_client_id_from_secret_rows "$rows")"
  if [[ -z "$b64" ]]; then
    # No row carrying a password is "absent"; more than one is "cannot tell".
    while read -r name canon legacy _; do
      [[ -n "$name" ]] || continue
      [[ -n "$canon" && "$canon" != "<none>" ]] || canon="$legacy"
      [[ -n "$canon" && "$canon" != "<none>" ]] || continue
      n=$((n + 1))
    done <<<"$rows"
    (( n == 0 )) && return 0
    return 2
  fi
  out="$(printf '%s' "$b64" | base64 -d 2>/dev/null)" \
    || out="$(printf '%s' "$b64" | base64 -D 2>/dev/null)" \
    || out=""
  [[ -n "$out" ]] || return 2
  printf '%s' "$out"
  return 0
}

# _restart_credential_consumers REL — roll the workloads that authenticate with the
# machine credential: the release's Deployments except MySQL (`mysql-client`,
# which never uses it) and its node-agent DaemonSets (they read the mirrored
# Secret). The DaemonSets are found by the release's instance label across ALL
# namespaces, never by a namespace named here, so a chart that moves them does not
# silently leave them on the rejected credential. Bounded and best-effort, but
# never silent: a listing that fails or finds no Deployment counts as a failed
# restart, because "nothing to roll" is the state that leaves every pod on the old
# credential. Returns 1 when any restart failed: the Secret already holds the new,
# valid credential, so no later run classifies `credential-rejected` and nothing
# would roll these pods again. The caller makes that fatal; the hint is the fix.
_restart_credential_consumers() {
  local rel="$1" d ns nm row failed=0 listed rows
  listed="$(kubectl get deployment -n "$rel" -l "app.kubernetes.io/instance=${rel}" \
              -o 'jsonpath={.items[*].metadata.name}' --request-timeout=15s 2>/dev/null)" || failed=1
  [[ -n "$listed" ]] || failed=1
  for d in $listed; do
    [[ "$d" == mysql-client ]] && continue
    kubectl rollout restart "deployment/$d" -n "$rel" --request-timeout=15s >>"${LOG_FILE:-/dev/null}" 2>&1 || failed=1
  done
  rows="$(kubectl get daemonset -A -l "app.kubernetes.io/instance=${rel}" \
            -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name' \
            --no-headers --request-timeout=15s 2>/dev/null)" || failed=1
  while read -r ns nm; do
    [[ -n "$ns" && -n "$nm" ]] || continue
    kubectl rollout restart "daemonset/$nm" -n "$ns" --request-timeout=15s >>"${LOG_FILE:-/dev/null}" 2>&1 || failed=1
  done <<<"$rows"
  if [[ "$failed" == 1 ]]; then
    warn "Couldn't restart every tracebloc service onto the new credential, so this machine stays offline until they restart. Re-running the installer won't redo it. Run:"
    hint "  $(tb_kubectl_shown) rollout restart deployment -n ${rel} -l app.kubernetes.io/instance=${rel}"
    hint "  $(tb_kubectl_shown) get daemonset -A -l app.kubernetes.io/instance=${rel}   # then: $(tb_kubectl_shown) rollout restart daemonset/<name> -n <namespace>"
    return 1
  fi
  log "restarted the services that authenticate, onto the new credential"
  return 0
}

# _credential_changed_under_pods PREV NOW — 0 when the release Secret held a
# password before this run's helm call (PREV) and holds a different one after it
# (NOW), i.e. pods already running were started on a credential that is gone.
# The reissue flag covers only the credential-rejected repair; a preset (the
# ID-only prompt, the env pair) or any other route that writes a new password into
# a running release's Secret changes it just the same, so the
# restart keys on the observed change, not on the route. An empty PREV is a first
# install: no pod holds an old credential -- so the caller must never hand an
# UNREADABLE previous read in as PREV; it restarts on that itself
# An empty NOW (the read after helm failed) with a PREV is
# "cannot tell", and that restarts: a needless roll is cheap, pods left on a dead
# credential are offline.
_credential_changed_under_pods() {
  [[ -n "${1:-}" && "${1:-}" != "${2:-}" ]]
}

# detect_installed_client — report the tracebloc client already installed on this
# cluster, if any, via the globals INSTALLED_CLIENT_ID / INSTALLED_CLIENT_NS
# (both empty when none is found). Enumerate client-chart releases across ALL
# namespaces WITHOUT jq (not a guaranteed prerequisite): helm's NAME/NAMESPACE are
# the first two whitespace-free columns and the CHART column matches
# `client-<ver>`, the same jq-free parse _chart_version uses. Shared by the
# pre-provision ownership pre-flight and the Helm-step one-client guard so
# the two can never disagree on "what already runs here". Always returns 0. A
# missing helm just yields the empty (no-client) result — but a helm/API FAILURE
# is reported as INSTALLED_CLIENT_UNKNOWN=1 (not "no client"), so guards can fail
# CLOSED instead of silently overwriting a client they couldn't see. The id is
# read from release values first and from the release Secret second
# (_client_id_from_secret): since either place is legitimate, and a
# client-chart release that names an id in NEITHER is UNKNOWN, not absent.
detect_installed_client() {
  # shellcheck disable=SC2034  # INSTALLED_CLIENT_RELEASE is consumed cross-file by assess.sh
  INSTALLED_CLIENT_ID=""; INSTALLED_CLIENT_NS=""; INSTALLED_CLIENT_RELEASE=""; INSTALLED_CLIENT_UNKNOWN=0
  # No helm => nothing helm-installed here; a genuine (documented) "no client".
  has helm || return 0
  local _rel _ns _id _list _unreadable=0
  # Capture `helm list`'s exit code: a FAILED enumeration (wedged/unreachable API,
  # kubeconfig glitch) must NOT read as "no client here" — that fails OPEN and lets
  # a re-install silently overwrite an existing client. `helm list` returns 0 with
  # empty output when there are genuinely no releases, so only a non-zero exit is
  # "unknown".
  # Name the states explicitly: Helm 3 lists only deployed by default while
  # Helm 4 (the pinned v4.2.3) lists all — so relying on the default hides a wedged
  # client on one version or the other. We enumerate the full "a client is present"
  # set — deployed, failed, and every wedge state (pending-*, uninstalling) that
  # _recover_pending_helm_release knows how to clear — so a killed-mid-flight client
  # stays visible and the one-client guard can't wave through an overwrite.
  if ! _list="$(helm list -A --deployed --failed --pending --uninstalling 2>/dev/null)"; then
    INSTALLED_CLIENT_UNKNOWN=1; return 0
  fi
  while read -r _rel _ns; do
    [[ -z "$_rel" ]] && continue
    # The values hold clientPassword and the chart's other secrets, so clientId is
    # read inside the pipe: no file an interrupted run would leave behind, and no
    # variable a trace would print. pipefail: a helm that fails is an unreadable
    # client. _extract_yaml_value's grep reads to EOF, so helm is never SIGPIPE'd. house-rules: ignore=pipefail
    if _id="$(set -o pipefail; helm get values "$_rel" -n "$_ns" 2>/dev/null </dev/null | _extract_yaml_value - clientId)"; then
      # VALUES READABLE BUT NO clientId IS NO LONGER "not a client":
      # clientId stopped being `required` and the chart now tells
      # operators to drop it from release values once the Secret carries it — so
      # under the new contract a perfectly live client legitimately has no
      # clientId in its values, and reading that as "not a match" let the
      # one-client guard wave through an install that re-points the machine.
      # Fall back to where the id now lives.
      #
      # THE SECRET'S NAME IS NOT ALWAYS THE RELEASE NAME (the name
      # differs): `tracebloc.secretName` follows `fullnameOverride`. So the
      # Secret is found by the RELEASE, whatever the chart named it
      # -- rebuilding the name from the override in these
      # values restated the chart's rule, and was right only while it matched.
      [[ -z "$_id" ]] && _id="$(_client_id_from_secret "$_rel" "$_ns")"
      # shellcheck disable=SC2034  # INSTALLED_CLIENT_RELEASE: consumed by assess.sh
      [[ -n "$_id" ]] && { INSTALLED_CLIENT_ID="$_id"; INSTALLED_CLIENT_NS="$_ns"; INSTALLED_CLIENT_RELEASE="$_rel"; break; }
      # A client-chart release with no id in EITHER place is a client we cannot
      # NAME, not an absent one. Record it and keep scanning; if nothing else
      # names one, the fail-closed check below reports UNKNOWN.
      _unreadable=1
    else
      # Couldn't read THIS client release's values -> an UNIDENTIFIABLE client.
      # Record it and keep scanning (a later release may give a definitive id);
      # if none does, fail closed below rather than read it as "no client here".
      _unreadable=1
    fi
  done < <(printf '%s\n' "$_list" | awk '/[[:space:]]client-[0-9]/ { print $1, $2 }')
  # A client release existed but we couldn't read its clientId, and no OTHER
  # release gave a definitive id -> unknown (fail closed).
  [[ -z "$INSTALLED_CLIENT_ID" && "$_unreadable" == 1 ]] && INSTALLED_CLIENT_UNKNOWN=1
  return 0
}

# _strip_paste_garbage now lives in settings.sh (shared with provision.sh's client-
# name prompt); install-k8s.sh sources settings.sh before this file, so it's in
# scope here for _sanitize_credential below.

# Sanitize a user-entered credential. Calls _strip_paste_garbage and notifies
# the user on stderr (NOT stdout — this function is called from inside $(...),
# so stdout is captured into the credential value itself).
_sanitize_credential() {
  local input="$1"
  local clean
  clean=$(_strip_paste_garbage "$input")
  if [[ "$clean" != "$input" ]]; then
    warn "Stripped non-printable / paste-mode characters from input." >&2
  fi
  printf '%s' "$clean"
}

# Sanitize workspace name to comply with DNS-1123 (lowercase, alphanumeric + hyphens)
_sanitize_workspace_name() {
  local input="$1"
  local sanitized
  sanitized=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
  sanitized="${sanitized// /-}"
  sanitized="${sanitized//_/-}"
  sanitized=$(printf '%s' "$sanitized" | sed 's/[^a-z0-9-]//g')
  sanitized=$(printf '%s' "$sanitized" | sed 's/--*/-/g')
  sanitized=$(printf '%s' "$sanitized" | sed 's/^-//; s/-$//')
  if [[ -z "$sanitized" ]]; then
    sanitized="default"
  fi
  if [[ ${#sanitized} -gt 63 ]]; then
    sanitized="${sanitized:0:63}"
    sanitized=$(printf '%s' "$sanitized" | sed 's/-$//')
  fi
  printf '%s' "$sanitized"
}

# ── Credential verification ────────────────────────────────────────
# Resolve the backend base URL the same way jobs-manager does
# (client-runtime/controller.py: TRACEBLOC_ENV → backend), defaulting to prod.
_backend_url() {
  # Reduce aliases FIRST: a raw `staging` fell through to the
  # prod branch, so verify_credentials() checked staging credentials against
  # the production backend and reported them invalid.
  # Bare call: tb_client_env reads the ambient TRACEBLOC_ENV, and the *)
  # branch below is the prod-equivalent for any unset/unrecognised result.
  case "$(tb_client_env)" in
    dev) printf 'https://dev-api.tracebloc.io/' ;;
    stg) printf 'https://stg-api.tracebloc.io/' ;;
    *)   printf 'https://api.tracebloc.io/' ;;
  esac
}

# Validate the entered Client ID / password against the backend's
# api-token-auth/ endpoint — the same call jobs-manager makes at runtime —
# using curl (already a dependency). Echoes: valid | invalid | inactive | unverified.
# verify_credentials runs with bash -x held off, the secret it holds out of the trace (output.sh);
# _tb_untraced_verify_credentials below is the function itself.
verify_credentials() { { _tb_trace_off; } 2>/dev/null; _tb_untraced_verify_credentials "$@"; local _tb_rc=$?; _tb_trace_on; return "$_tb_rc"; }
_tb_untraced_verify_credentials() {
  local client_id="$1" client_password="$2" backend code
  backend="$(_backend_url)"
  # SECURITY: never put the password on curl's argv — it would be world-readable
  # via `ps` / /proc/<pid>/cmdline for the request's lifetime, and tracebloc runs
  # on shared institutional/on-prem compute where a co-tenant could scrape it
  # (CWE-214). Feed it through stdin instead: `--data-urlencode password@-` reads
  # the value from stdin and URL-encodes it, so the secret never appears in the
  # process table. `printf '%s'` is a bash builtin (no fork, no argv exposure) and
  # emits no trailing newline (a here-string `<<<` would append one and corrupt
  # the password). The username (client_id, a UUID) isn't secret, so it stays inline.
  # curl_secure (not bare curl) pins the minimum TLS version: this request carries
  # the client's password, and a TLS-inspecting proxy in front of it would happily
  # negotiate whatever the client accepts. -m 60 keeps the tighter
  # deadline this call already had.
  code=$(printf '%s' "$client_password" | curl_secure -sS -m 60 -o /dev/null -w '%{http_code}' \
    --data-urlencode "username=${client_id}" \
    --data-urlencode "password@-" \
    "${backend}api-token-auth/" 2>/dev/null) || code="000"
  case "$code" in
    200) printf 'valid' ;;
    400) printf 'invalid' ;;
    401) printf 'inactive' ;;
    *)   printf 'unverified' ;;   # 429 throttled, 000 unreachable, 5xx, …
  esac
}
