#!/usr/bin/env bash
# =============================================================================
#  install-client-helm.sh — Install Tracebloc client (steps 3 & 4)
#  Generates values from defaults + user prompts (workspace, clientId, clientPassword)
#  and GPU detection. Values file is written to HOST_DATA_DIR/values.yaml.
# =============================================================================

TRACEBLOC_HELM_REPO_URL="https://tracebloc.github.io/client"
TRACEBLOC_HELM_REPO_NAME="tracebloc"
TRACEBLOC_CHART_NAME="client"

_ensure_helm_runnable() {
  if helm version --short &>/dev/null; then
    return 0
  fi
  local helm_bin
  helm_bin="$(command -v helm 2>/dev/null)" || true
  if [[ -z "$helm_bin" || ! -f "$helm_bin" ]]; then
    error "Installation tools are not available. Re-run the installer."
  fi
  if [[ ! -x "$helm_bin" ]]; then
    log "Helm at $helm_bin is not executable — fixing permissions"
    if sudo chmod 755 "$helm_bin" 2>/dev/null; then
      log "Helm permissions fixed."
      return 0
    fi
    error "Could not fix tool permissions. Run manually: sudo chmod 755 $helm_bin"
  fi
  error "Installation tools could not be run. Try: sudo chmod 755 $helm_bin then re-run this script."
}

_extract_yaml_value() {
  local file="$1" key="$2"
  local line
  line=$(grep -E "^${key}:" "$file" 2>/dev/null | head -1)
  [[ -z "$line" ]] && return
  line="${line#*:}"
  line="${line#"${line%%[![:space:]]*}"}"
  if [[ "$line" == \'*\' ]]; then
    line="${line#\'}"
    line="${line%\'}"
    line="${line//\'\'/\'}"
  else
    line="${line#\"}"
    line="${line%\"}"
  fi
  # Defend against self-perpetuation: a previous corrupted save may have the
  # bracketed-paste markers and/or C0 controls (#168). _strip_paste_garbage
  # handles both. UTF-8 (0x80+) preserved.
  _strip_paste_garbage "$line"
}

# detect_installed_client — report the tracebloc client already installed on this
# cluster, if any, via the globals INSTALLED_CLIENT_ID / INSTALLED_CLIENT_NS
# (both empty when none is found). Enumerate client-chart releases across ALL
# namespaces WITHOUT jq (not a guaranteed prerequisite): helm's NAME/NAMESPACE are
# the first two whitespace-free columns and the CHART column matches
# `client-<ver>`, the same jq-free parse _chart_version uses. Shared by the
# pre-provision ownership pre-flight (#303) and the Helm-step one-client guard so
# the two can never disagree on "what already runs here". Always returns 0. A
# missing helm just yields the empty (no-client) result — but a helm/API FAILURE
# is reported as INSTALLED_CLIENT_UNKNOWN=1 (not "no client"), so guards can fail
# CLOSED instead of silently overwriting a client they couldn't see.
detect_installed_client() {
  INSTALLED_CLIENT_ID=""; INSTALLED_CLIENT_NS=""; INSTALLED_CLIENT_UNKNOWN=0
  # No helm => nothing helm-installed here; a genuine (documented) "no client".
  has helm || return 0
  local _gvf _rel _ns _id _list
  # A mktemp failure is an environment error, NOT proof of "no client here" — flag
  # UNKNOWN so the guards fail closed rather than skip. Fall back to a path in a
  # dir we own (never a predictable world-writable /tmp path under sudo) before
  # giving up.
  _gvf="$(mktemp 2>/dev/null)" || _gvf="${HOST_DATA_DIR:+${HOST_DATA_DIR}/.tb-detect-values.$$}"
  [[ -n "$_gvf" ]] || { INSTALLED_CLIENT_UNKNOWN=1; return 0; }
  # Capture `helm list`'s exit code: a FAILED enumeration (wedged/unreachable API,
  # kubeconfig glitch) must NOT read as "no client here" — that fails OPEN and lets
  # a re-install silently overwrite an existing client. `helm list` returns 0 with
  # empty output when there are genuinely no releases, so only a non-zero exit is
  # "unknown".
  if ! _list="$(helm list -A 2>/dev/null)"; then
    INSTALLED_CLIENT_UNKNOWN=1; rm -f "$_gvf"; return 0
  fi
  while read -r _rel _ns; do
    [[ -z "$_rel" ]] && continue
    if helm get values "$_rel" -n "$_ns" > "$_gvf" 2>/dev/null; then
      _id="$(_extract_yaml_value "$_gvf" clientId)"
      [[ -n "$_id" ]] && { INSTALLED_CLIENT_ID="$_id"; INSTALLED_CLIENT_NS="$_ns"; break; }
    fi
  done < <(printf '%s\n' "$_list" | awk '/[[:space:]]client-[0-9]/ { print $1, $2 }')
  rm -f "$_gvf"
  return 0
}

# Strip ANSI escape sequences and C0 control characters from a value.
# `read -r -s` captures whatever the terminal sends — this can include:
#   • bracketed-paste wrappers:  ESC[200~ ... ESC[201~
#   • arrow keys / cursor moves: ESC[A/B/C/D, ESC[1;5C, ESC[3~ (Delete), …
#   • function keys, modifier combos, mode-switch sequences
# All follow the ANSI CSI shape:  ESC '[' <params> <final-byte>
# where params ∈ [0-9;] and final ∈ [A-Za-z~]. Strip them iteratively to
# handle consecutive sequences (e.g. paste-wrappers).
#
# Also handles the post-corruption case where ESC was stripped by an earlier
# (buggy) sanitizer but the literal `[200~`/`[201~` markers survived. Only
# self-heals the two well-defined bracketed-paste markers — generic `[X]`
# shapes could plausibly be real password content.
#
# UTF-8 bytes (0x80+) preserved so international characters survive.
_strip_paste_garbage() {
  local s="$1"
  local esc=$'\e'
  local csi_pattern="${esc}\\[[0-9;]*[A-Za-z~]"
  while [[ "$s" =~ $csi_pattern ]]; do
    s="${s/${BASH_REMATCH[0]}/}"
  done
  s="${s//\[200\~/}"
  s="${s//\[201\~/}"
  printf '%s' "$s" | tr -d '\000-\037\177'
}

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

# ── Credential verification (#717) ────────────────────────────────────────
# Resolve the backend base URL the same way jobs-manager does
# (client-runtime/controller.py: CLIENT_ENV → backend), defaulting to prod.
_backend_url() {
  case "${CLIENT_ENV:-prod}" in
    dev) printf 'https://dev-api.tracebloc.io/' ;;
    stg) printf 'https://stg-api.tracebloc.io/' ;;
    *)   printf 'https://api.tracebloc.io/' ;;
  esac
}

# Validate the entered Client ID / password against the backend's
# api-token-auth/ endpoint — the same call jobs-manager makes at runtime —
# using curl (already a dependency). Echoes: valid | invalid | inactive | unverified.
verify_credentials() {
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
  code=$(printf '%s' "$client_password" | curl -sS -m 60 -o /dev/null -w '%{http_code}' \
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

# ── Corporate-proxy passthrough into the chart (#242) ───────────────────────
# cluster.sh propagates the host's HTTP(S)_PROXY to the k3d *nodes* so
# containerd can pull images behind a corporate proxy (#166). But the client
# *workloads* — jobs-manager (api + pods-monitor), requests-proxy, the
# image-refresh / auto-upgrade cronjobs — only get proxy egress if the CHART
# renders it, and the chart's tracebloc.proxyEnv helper is driven by the SPLIT
# keys (HTTP_PROXY_HOST/_PORT/_USERNAME/_PASSWORD), not a raw HTTP_PROXY URL.
# Without them every backend-dialing pod CrashLoopBackOffs on api-token-auth/
# behind a corporate proxy (Charité, 2026-06-09). This fills the workload half
# of #166 that node-level propagation alone missed.
#
# We deliberately emit the SPLIT form, not a raw env.HTTP_PROXY: on the released
# 1.6.0 chart a raw env.HTTP_PROXY with no HTTP_PROXY_HOST is dropped by the
# #236 proxy-key exclusion (the #238 regression). HTTP_PROXY_HOST drives
# proxyEnv and is correct on every released chart.
#
# Reads the first set of HTTP_PROXY/HTTPS_PROXY (upper- then lower-case);
# supports authenticated proxies (http://user:pass@host:port), splitting on the
# LAST '@' so a ':' or '@' inside the password is tolerated. Echoes YAML lines
# for the env: block (each prefixed with a newline, 2-space indent), or nothing
# when the host has no proxy set.
_chart_proxy_env_yaml() {
  local raw="" var
  for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    if [[ -n "${!var:-}" ]]; then raw="${!var}"; break; fi
  done
  [[ -z "$raw" ]] && return 0

  local rest="${raw#*://}"      # strip scheme
  rest="${rest%%/*}"            # strip any trailing /path
  local creds="" hostport="$rest" host port="" user="" pass=""
  if [[ "$rest" == *"@"* ]]; then
    creds="${rest%@*}"          # everything before the LAST '@'
    hostport="${rest##*@}"      # host:port after the LAST '@'
  fi
  host="${hostport%%:*}"
  [[ "$hostport" == *:* ]] && port="${hostport##*:}"
  [[ -z "$host" ]] && return 0
  if [[ -n "$creds" ]]; then
    user="${creds%%:*}"
    [[ "$creds" == *:* ]] && pass="${creds#*:}"
  fi

  printf '\n  HTTP_PROXY_HOST: "%s"' "$host"
  [[ -n "$port" ]] && printf '\n  HTTP_PROXY_PORT: "%s"' "$port"
  [[ -n "$user" ]] && printf '\n  HTTP_PROXY_USERNAME: "%s"' "$user"
  [[ -n "$pass" ]] && printf '\n  HTTP_PROXY_PASSWORD: "%s"' "$pass"
  # Pass the host's NO_PROXY through; tracebloc.proxyEnv unions it with the
  # cluster-internal bypass list (mirrors cluster.sh's node-side _augment_no_proxy).
  local hostnp="${NO_PROXY:-${no_proxy:-}}"
  [[ -n "$hostnp" ]] && printf '\n  NO_PROXY: "%s"' "$hostnp"
  return 0
}

# _resolve_chart_ref — resolve the chart reference (local dev path or remote repo)
# and set `chart_ref` in the caller's scope (bash dynamic scope). Extracted so a
# fresh install and an adopt reconcile resolve it identically. Logging is a side
# effect only — never command-substitute this (that would capture the log lines).
_resolve_chart_ref() {
  if [[ -n "${TRACEBLOC_CHART_PATH:-}" ]]; then
    [[ -d "$TRACEBLOC_CHART_PATH" ]] || error "TRACEBLOC_CHART_PATH not found: $TRACEBLOC_CHART_PATH"
    chart_ref="$TRACEBLOC_CHART_PATH"
    info "Dev mode: using local chart at $chart_ref"
    log "Using local chart: $chart_ref"
  else
    if ! helm repo list 2>/dev/null | grep -q "^${TRACEBLOC_HELM_REPO_NAME}[[:space:]]"; then
      log "Adding Helm repo: $TRACEBLOC_HELM_REPO_URL"
      helm repo add "$TRACEBLOC_HELM_REPO_NAME" "$TRACEBLOC_HELM_REPO_URL" >> "${LOG_FILE:-/dev/null}" 2>&1
    fi
    log "Updating Helm repos..."
    helm repo update >> "${LOG_FILE:-/dev/null}" 2>&1
    chart_ref="$TRACEBLOC_HELM_REPO_NAME/$TRACEBLOC_CHART_NAME"
  fi
}

# _reconcile_adopted_client — RFC-0001 §7.2 adopt path. provision_client (Step 3)
# sets TRACEBLOC_CLIENT_ADOPTED=1 when `tracebloc client create` matched this cluster
# to an EXISTING client on the account (get-or-create keyed on the cluster). Adopt
# issues no new password — the existing one stands (write-only on the backend) — so
# there is nothing to prompt for or verify. Reconcile the live release in place,
# reusing its stored credential, and heal the stored clientId to the adopted UUID:
# installs from the cli#125 window stored the numeric dashboard id, which can't
# authenticate. Returns 0 on a successful reconcile; non-zero (caller falls back to
# the normal connect flow) when no live tracebloc release is found to reconcile.
_reconcile_adopted_client() {
  # provision_client (Step 3) hands over the adopted client id (UUID) + the marker on
  # adopt (no password — the existing credential stands). Find the live client release
  # and reconcile it in place. Enumerate it the same jq-free way the one-per-machine
  # guard does. One client per machine, so take the first.
  local _rel="" _ns="" _r _n
  while read -r _r _n; do
    [[ -n "$_r" ]] && { _rel="$_r"; _ns="$_n"; break; }
  done < <(helm list -A 2>/dev/null | awk '/[[:space:]]client-[0-9]/ { print $1, $2 }')
  if [[ -z "$_rel" ]]; then
    warn "This client is already registered, but no live tracebloc release was found here to reconcile — continuing with a normal connect."
    return 1
  fi

  TB_NAMESPACE="$_ns"
  info "This machine already runs a tracebloc client — reconciling '${_rel}' (namespace '${_ns}') in place."

  _ensure_helm_runnable
  local chart_ref=""
  _resolve_chart_ref

  # Reconcile in place, reusing the release's stored values (clientPassword +
  # install-time config). Prefer --reset-then-reuse-values (Helm >= 3.14: reset to
  # chart defaults, then re-apply the stored user values, picking up new chart
  # defaults); fall back to --reuse-values on older Helm.
  local _reuse="--reuse-values"
  helm upgrade --help 2>/dev/null | grep -q -- '--reset-then-reuse-values' && _reuse="--reset-then-reuse-values"

  # Heal the stored clientId to the adopted UUID when provision_client handed one
  # over (export TRACEBLOC_CLIENT_ID on the adopt path): a cli#125-era install stored
  # the numeric dashboard id, which can't authenticate, and --reuse-values alone
  # would preserve it (the reused password is still correct). With no id (rebuilt
  # host / R7 orphan) reconcile WITHOUT a heal rather than bail — the existing
  # credential stands. Built as an array so the optional --set is bash-3.2 safe.
  local _args=(upgrade "$_rel" "$chart_ref" --namespace "$_ns" "$_reuse")
  local _uuid; _uuid="$(_sanitize_credential "${TRACEBLOC_CLIENT_ID:-}")"
  [[ -n "$_uuid" ]] && _args+=(--set "clientId=$_uuid")

  _ensure_release_dirs "$_ns"

  # Reconcile blocks too — same spinner treatment (RFC-0002 §2).
  if ! spin_cmd "Reconciling the existing client…" helm "${_args[@]}"; then
    error "Reconcile of the existing client failed. Check the log for details: ${LOG_FILE:-}"
  fi

  kubectl config set-context --current --namespace "$_ns" >/dev/null 2>&1 || true
  return 0
}

# TB_TTY is where interactive credential prompts READ from. Under `curl … | bash`
# stdin is the piped script, not the terminal, so an unredirected `read` hits EOF
# and (under set -e) aborts the installer with an opaque failure — read the
# controlling terminal directly instead. Overridable so tests can feed canned
# input on stdin (TB_TTY=/dev/stdin).
: "${TB_TTY:=/dev/tty}"

# _tty_available: true when there's a terminal we can prompt on (TB_TTY readable).
# Mirrors provision.sh's _prompt_tty; defined locally because provision.sh is
# sourced conditionally and AFTER this file, so its helper may not exist when
# install_client_helm runs.
_tty_available() { [[ -r "$TB_TTY" ]]; }

# _no_interactive_creds_die: abort with actionable env-var guidance when we can't
# collect credentials interactively. Covers BOTH no-terminal-at-all AND a
# readable-but-dead-input tty (non-PTY ssh, an IDE terminal, a drained/queued
# tty): _tty_available only checks `-r`, so a `read <"$TB_TTY"` can still hit EOF
# and would otherwise abort opaquely under set -e (Bugbot / #326 review) — the
# same failure class the TB_TTY change set out to remove. Mirrors provision.sh,
# whose name read breaks on rc!=0 and falls through to the same guidance.
_no_interactive_creds_die() {
  error "No credentials supplied and no terminal to prompt on.
  Set TRACEBLOC_CLIENT_ID and TRACEBLOC_CLIENT_PASSWORD (find them at
  https://ai.tracebloc.io/clients), then re-run — under \`curl … | bash\` the
  prompt cannot read your input."
}

# _download_services_progress NS — render an honest N-of-M count bar as the
# client's container images pull onto the node (the "services download" in step
# e). The only TRUTHFUL per-unit signal is how many containers report a populated
# imageID (image present) out of the total the pods declare — never a fabricated
# aggregate percentage. Best-effort, BOUNDED, and NON-FATAL: it must never block
# or fail the install — the authoritative readiness gate is wait_for_client_ready
# (step f). Skipped entirely when TB_NO_SERVICE_PROGRESS is set (the bats suite,
# where kubectl is mocked and a poll loop would hang) or kubectl is unavailable.
_download_services_progress() {
  local ns="$1"
  if [[ -n "${TB_NO_SERVICE_PROGRESS:-}" ]]; then return 0; fi
  has kubectl || return 0
  [[ -n "$ns" ]] || return 0

  # Every kubectl call is bounded with --request-timeout so a wedged/unreachable
  # API can never make the poll BLOCK — the between-iteration deadline check below
  # only fires if kubectl actually returns, so an unbounded call would hang step e
  # forever despite TB_PULL_TIMEOUT. Overridable; mirrors assess.sh's bounded probe.
  local kube_timeout="${TB_PROGRESS_KUBECTL_TIMEOUT:-5s}"

  # Establish the total container count once the pods are scheduled (bounded).
  local total=0 tries=0
  while (( tries < 15 )); do
    total="$(kubectl get pods -n "$ns" --request-timeout="$kube_timeout" \
      -o jsonpath='{range .items[*].spec.containers[*]}{"x"}{end}' 2>/dev/null \
      | tr -cd 'x' | wc -c | tr -d ' ')" || total=0
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    if (( total > 0 )); then break; fi
    tries=$(( tries + 1 )); sleep 2
  done
  if (( total < 1 )); then return 0; fi   # never saw pods — skip the bar silently

  local deadline pulled=0
  deadline=$(( $(date +%s) + ${TB_PULL_TIMEOUT:-300} ))
  tput civis 2>/dev/null || true
  while :; do
    pulled="$(kubectl get pods -n "$ns" --request-timeout="$kube_timeout" \
      -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}' 2>/dev/null \
      | grep -c '.')" || pulled=0
    [[ "$pulled" =~ ^[0-9]+$ ]] || pulled=0
    if (( pulled > total )); then pulled=$total; fi
    count_bar "$pulled" "$total" "services"
    if (( pulled >= total )); then break; fi
    if (( $(date +%s) >= deadline )); then break; fi
    sleep 2
  done
  printf "\r\033[K"
  tput cnorm 2>/dev/null || true
  if (( pulled >= total )); then
    success "Downloaded — ${total} services"
  else
    info "Services are still downloading — they'll finish starting in the background."
  fi
  return 0
}

install_client_helm() {
  # Step e (Install tracebloc) — main() prints the "e) Installing tracebloc"
  # header. The credential + namespace were provisioned in step d
  # (provision_client) or supplied via dual-mode (TRACEBLOC_CLIENT_ID/PASSWORD or
  # TRACEBLOC_VALUES_FILE). This step renders the values, runs Helm, and shows the
  # services download; the final connect + summary is step f.
  _ensure_tracebloc_dirs
  local values_file="${HOST_DATA_DIR}/values.yaml"

  # ── Dev-mode override: caller-supplied values file ───────────────────────
  # When TRACEBLOC_VALUES_FILE is set, skip prompts and values.yaml generation
  # and use the provided file as-is. Used for local testing against an
  # unreleased chart (pair with TRACEBLOC_CHART_PATH).
  if [[ -n "${TRACEBLOC_VALUES_FILE:-}" ]]; then
    [[ -f "$TRACEBLOC_VALUES_FILE" ]] || error "TRACEBLOC_VALUES_FILE not found: $TRACEBLOC_VALUES_FILE"
    values_file="$TRACEBLOC_VALUES_FILE"
    TB_NAMESPACE="${TB_NAMESPACE:-tracebloc}"
    info "Dev mode: using caller-provided values file"
    log "Using values file: $values_file (namespace: $TB_NAMESPACE)"
  else

  local use_existing=""
  local default_client_id=""
  local default_client_password=""

  # Non-interactive credentials (RFC-0001 Phase 0): set TRACEBLOC_CLIENT_ID +
  # TRACEBLOC_CLIENT_PASSWORD to provision without typing the secret inline
  # (CI / automation / golden images). Verified the same way as the prompt.
  local _noninteractive_creds=0
  if [[ -n "${TRACEBLOC_CLIENT_ID:-}" && -n "${TRACEBLOC_CLIENT_PASSWORD:-}" ]]; then
    _noninteractive_creds=1
  fi

  if [[ "$_noninteractive_creds" == 0 && -f "$values_file" && "${TRACEBLOC_CLIENT_ADOPTED:-}" != 1 ]] && _tty_available; then
    hint "Previous configuration found."
    while true; do
      read -r -p "  Use previous settings as defaults? [Y/n]: " use_existing <"$TB_TTY" || _no_interactive_creds_die
      use_existing="$(echo "${use_existing}" | tr '[:upper:]' '[:lower:]')"
      [[ "$use_existing" == "y" || "$use_existing" == "yes" || "$use_existing" == "n" || "$use_existing" == "no" || -z "$use_existing" ]] && break
      warn "Please enter y or n."
    done
    if [[ "$use_existing" == "y" || "$use_existing" == "yes" || -z "$use_existing" ]]; then
      default_client_id=$(_extract_yaml_value "$values_file" "clientId")
      default_client_password=$(_extract_yaml_value "$values_file" "clientPassword")
      [[ -n "$default_client_id" ]] && log "Using existing clientId as default."
      [[ -n "$default_client_password" ]] && log "Using existing clientPassword as default."
    fi
  fi

  # ── Namespace (fixed; not prompted) ──────────────────────────────────────
  # The on-prem client is one-per-machine and is identified to the backend by
  # its credentials (clientId), not by this name — so we don't ask the user to
  # invent one. It's just the local k8s namespace / Helm release name.
  # Advanced / GitOps setups can override with TB_NAMESPACE=<name>.
  TB_NAMESPACE=$(_sanitize_workspace_name "${TB_NAMESPACE:-tracebloc}")

  # RFC-0001 §7.2 — a re-run on an already-connected client must reconcile in place,
  # not re-provision. Step 3 marks that case with TRACEBLOC_CLIENT_ADOPTED=1 (+ the
  # UUID, no password). Honor it: reconcile the live release silently — no credential
  # prompt, no verify, no duplicate. Only if there's no live release to reconcile do
  # we fall through to the normal connect flow below.
  if [[ "${TRACEBLOC_CLIENT_ADOPTED:-}" == 1 ]] && _reconcile_adopted_client; then
    success "tracebloc installed"
    log "Reconciled adopted client in namespace '$TB_NAMESPACE'"
    return 0
  fi

  if [[ "$_noninteractive_creds" == 1 ]]; then
    # Credentials supplied via env — verify once, no prompt, no re-prompt.
    TB_CLIENT_ID=$(_sanitize_credential "$TRACEBLOC_CLIENT_ID")
    TB_CLIENT_PASSWORD=$(_sanitize_credential "$TRACEBLOC_CLIENT_PASSWORD")
    [[ -n "$TB_CLIENT_ID" && -n "$TB_CLIENT_PASSWORD" ]] || \
      error "TRACEBLOC_CLIENT_ID / TRACEBLOC_CLIENT_PASSWORD must be non-empty."
    info "Verifying credentials with tracebloc…"
    case "$(verify_credentials "$TB_CLIENT_ID" "$TB_CLIENT_PASSWORD")" in
      valid)      success "Credentials verified." ;;
      invalid)    error "TRACEBLOC_CLIENT_ID / TRACEBLOC_CLIENT_PASSWORD was rejected by tracebloc — check it at https://ai.tracebloc.io/clients and re-run." ;;
      inactive)   error "This tracebloc account is not active yet. Check your email for the activation link, then re-run." ;;
      unverified) warn "Couldn't reach tracebloc to verify credentials right now — continuing (the client will stay offline if they are wrong)." ;;
    esac
  else

  # We must prompt for credentials, but there may be no terminal to prompt on
  # (typically `curl … | bash`, where stdin is the piped script). Fail here with
  # an actionable message rather than aborting opaquely under set -e. The
  # per-read `|| _no_interactive_creds_die` guards below catch the harder case
  # this cheap check can't: a tty that is readable (`-r`) but yields no input.
  if ! _tty_available; then
    _no_interactive_creds_die
  fi

  prompt_header "Connect this machine to a tracebloc client."
  hint "A client links your secure environment to the tracebloc"
  hint "platform so other collaborators can submit models for evaluation."
  echo ""
  hint "Already have one? Enter its credentials below — or set"
  hint "TRACEBLOC_CLIENT_ID / TRACEBLOC_CLIENT_PASSWORD to skip this prompt."
  hint "Need one? Create it (free) at:"
  echo -e "    ${BOLD}${WHITE}https://ai.tracebloc.io/clients${RESET}"
  echo ""

  # Collect + verify credentials. The entered Client ID / password are checked
  # against the backend (the same api-token-auth/ call jobs-manager makes)
  # before we deploy, so a wrong credential is caught here — with a re-prompt —
  # instead of surfacing later as a silently crash-looping pod.
  local _cred_attempt=0 _cred_max=5 _cred_status
  while true; do
    if [[ -n "$default_client_id" ]]; then
      read -r -p "  Client ID [${default_client_id}]: " TB_CLIENT_ID_INPUT <"$TB_TTY" || _no_interactive_creds_die
      TB_CLIENT_ID="${TB_CLIENT_ID_INPUT:-$default_client_id}"
    else
      read -r -p "  Client ID: " TB_CLIENT_ID <"$TB_TTY" || _no_interactive_creds_die
    fi
    TB_CLIENT_ID=$(_sanitize_credential "$TB_CLIENT_ID")
    if [[ -z "$TB_CLIENT_ID" ]]; then warn "Client ID cannot be empty."; continue; fi

    if [[ -n "$default_client_password" ]]; then
      read -r -s -p "  Client password [press Enter to keep existing]: " TB_CLIENT_PASSWORD_INPUT <"$TB_TTY" || _no_interactive_creds_die
      echo ""
      TB_CLIENT_PASSWORD="${TB_CLIENT_PASSWORD_INPUT:-$default_client_password}"
    else
      read -r -s -p "  Client password: " TB_CLIENT_PASSWORD <"$TB_TTY" || _no_interactive_creds_die
      echo ""
    fi
    TB_CLIENT_PASSWORD=$(_sanitize_credential "$TB_CLIENT_PASSWORD")
    if [[ -z "$TB_CLIENT_PASSWORD" ]]; then warn "Client password cannot be empty."; continue; fi

    info "Verifying credentials with tracebloc…"
    _cred_status=$(verify_credentials "$TB_CLIENT_ID" "$TB_CLIENT_PASSWORD")
    case "$_cred_status" in
      valid)
        success "Credentials verified."
        break ;;
      invalid)
        warn "That Client ID / password was rejected by tracebloc — please re-enter."
        hint "Find your credentials at https://ai.tracebloc.io/clients" ;;
      inactive)
        error "This tracebloc account is not active yet. Check your email for the activation link, then re-run." ;;
      unverified)
        warn "Couldn't reach tracebloc to verify your credentials right now — continuing."
        hint "If they are wrong, your client will stay offline at https://ai.tracebloc.io/clients after install."
        break ;;
    esac

    _cred_attempt=$((_cred_attempt + 1))
    if [[ $_cred_attempt -ge $_cred_max ]]; then
      error "Too many failed attempts. Double-check your credentials at https://ai.tracebloc.io/clients and re-run."
    fi
    # Force an active re-entry on retry (don't silently reuse a rejected default).
    default_client_id=""; default_client_password=""
  done
  fi

  # ── One-client-per-machine guard ─────────────────────────────────────────
  # A machine runs exactly one tracebloc client: it shares this cluster and the
  # host's CPU/RAM/GPU, and the platform counts each client as separate
  # capacity. If a DIFFERENT client is already installed here, a re-install
  # would silently re-point the machine — so we stop and let the operator
  # decide. The same clientId is a normal re-run/upgrade and passes through.
  # Check ANY namespace: a fresh install lands in `tracebloc`, but an install
  # from an older installer version may be in a different namespace. The jq-free
  # enumeration lives in detect_installed_client (shared with the #303 pre-provision
  # pre-flight so the two can't disagree on what's installed here).
  local existing_id="" existing_ns=""
  detect_installed_client
  existing_id="$INSTALLED_CLIENT_ID"; existing_ns="$INSTALLED_CLIENT_NS"
  # Fail CLOSED when we couldn't enumerate what's here (API/helm failure): refuse
  # rather than risk overwriting a client the guard simply couldn't see.
  if [[ "${INSTALLED_CLIENT_UNKNOWN:-0}" == 1 ]]; then
    echo ""
    warn "Couldn't determine which tracebloc client (if any) is already installed here."
    hint "tracebloc runs one client per machine, so the installer won't risk overwriting"
    hint "an existing client it can't see — usually the cluster API is briefly unreachable."
    hint "Check it and re-run:"
    hint "  kubectl cluster-info"
    hint "  helm list -A"
    echo ""
    error "Refusing to install without verifying what's already on this machine."
  fi
  if [[ -n "$existing_id" && "$existing_id" != "$TB_CLIENT_ID" ]]; then
    echo ""
    warn "This machine already runs the tracebloc client '${existing_id}' (namespace '${existing_ns}')."
    hint "tracebloc runs one client per machine — it shares this cluster and host"
    hint "resources, and the platform counts each client as separate capacity."
    echo ""
    hint "You entered a different Client ID ('${TB_CLIENT_ID}'). Pick one:"
    hint "  • Repair / update '${existing_id}'  →  re-run with that same Client ID"
    hint "  • Switch to '${TB_CLIENT_ID}'        →  remove the current client first:"
    hint "        k3d cluster delete ${CLUSTER_NAME:-tracebloc}   (wipes this client + its local data)"
    hint "      then re-run this installer"
    hint "  • Run both clients                   →  install on a separate machine"
    echo ""
    error "Refusing to replace the existing client. See the options above."
  fi

  # Same client, but already installed under a DIFFERENT namespace — e.g. a release
  # from an older installer that used the fixed `tracebloc` namespace, before #838
  # began deriving the namespace from the minted client slug. Upgrade THAT release
  # in place rather than installing a second one under the new namespace: the
  # platform counts each release as separate capacity, so a fork would silently
  # double-book this host (and orphan the original). Reuse the existing namespace;
  # an intentional namespace move is a delete-then-reinstall, not a silent fork.
  if [[ -n "$existing_id" && "$existing_id" == "$TB_CLIENT_ID" && -n "$existing_ns" && "$existing_ns" != "$TB_NAMESPACE" ]]; then
    log "Client '${existing_id}' already installed in namespace '${existing_ns}'; upgrading it in place instead of creating '${TB_NAMESPACE}'."
    info "Updating the existing client (namespace '${existing_ns}')."
    TB_NAMESPACE="$existing_ns"
  fi

  TB_CLIENT_PASSWORD_ESCAPED="${TB_CLIENT_PASSWORD//\'/\'\'}"

  # ── GPU limits ──────────────────────────────────────────────────────────
  local gpu_val
  if [[ "${GPU_VENDOR:-}" == "nvidia" ]]; then
    gpu_val="nvidia.com/gpu=1"
    log "NVIDIA GPU detected — setting GPU_LIMITS and GPU_REQUESTS to nvidia.com/gpu=1"
  else
    gpu_val=""
    log "No NVIDIA GPU — GPU_LIMITS and GPU_REQUESTS left empty"
  fi

  # ── Write generated values.yaml ─────────────────────────────────────────
  log "Writing values to $values_file"

  # Translate a corporate proxy on the host into the chart's split proxy keys so
  # every egress-needing workload inherits it (see _chart_proxy_env_yaml). Empty
  # when the host has no proxy — the env: block is then unchanged.
  local proxy_env_yaml
  proxy_env_yaml="$(_chart_proxy_env_yaml)"
  [[ -n "$proxy_env_yaml" ]] && log "Corporate proxy detected on host — propagating to client workloads via chart values."

  cat <<EOF > "$values_file"
# ============================================================
# Generated by tracebloc installer — client configuration
# ============================================================

env:
$([ -n "${CLIENT_ENV:-}" ] && printf '  CLIENT_ENV: "%s"\n' "$CLIENT_ENV")${proxy_env_yaml}
  # Training size: how much CPU/RAM each training run gets. One knob sets
  # requests == limits (Guaranteed QoS; client-runtime keeps them in lockstep).
  # Set at install time with TRACEBLOC_TRAINING_RESOURCES="cpu=4,memory=16Gi".
  RESOURCE_LIMITS: "${TRACEBLOC_TRAINING_RESOURCES:-cpu=2,memory=8Gi}"
  RESOURCE_REQUESTS: "${TRACEBLOC_TRAINING_RESOURCES:-cpu=2,memory=8Gi}"
  GPU_LIMITS: "$gpu_val"
  GPU_REQUESTS: "$gpu_val"
  RUNTIME_CLASS_NAME: ""
  # client-runtime#92: installer-provisioned k3d is a fixed single-host cluster
  # that cannot autoscale, so jobs-manager applies the hard CPU-or-GPU rule —
  # a Pending GPU pod is downgraded to CPU rather than waiting for a GPU node
  # that will never arrive.
  SINGLE_NODE: "true"
$([ -n "${HOST_DATASET_DIR:-}" ] && printf '  HOST_UID: "%s"\n  HOST_GID: "%s"\n' "$(id -u)" "$(id -g)")
storageClass:
  create: true
  name: client-storage-class
  provisioner: manual
  allowVolumeExpansion: true
  parameters: {}

hostPath:
  enabled: true
$([ -n "${HOST_DATASET_DIR:-}" ] && printf '  datasetPath: /tracebloc-data\n')
pvc:
  mysql: 2Gi
  logs: 10Gi
  data: 50Gi

pvcAccessMode: ReadWriteOnce

clusterScope: true

clientId: "$TB_CLIENT_ID"
clientPassword: '$TB_CLIENT_PASSWORD_ESCAPED'

EOF

  chmod 600 "$values_file" 2>/dev/null || true
  log "Values file written to $values_file"
  fi

  _ensure_helm_runnable

  # ── Resolve chart reference: local path (dev) or remote repo (default) ──
  local chart_ref=""
  _resolve_chart_ref

  echo ""
  log "Installing $TB_NAMESPACE from $chart_ref in namespace '$TB_NAMESPACE'..."

  # What the user is about to see download (the "e) Installing tracebloc" body).
  echo -e "  ${DIM}Downloading the tracebloc services — a training runner that runs models${RESET}"
  echo -e "  ${DIM}on your data, a data manager, a live monitor, and a local database. They${RESET}"
  echo -e "  ${DIM}run entirely on your machine; your data never leaves it.${RESET}"
  echo ""

  # Pre-create per-release hostPath dirs so they're owned by the host user, not
  # root:root from kubelet's DirectoryOrCreate. See _ensure_release_dirs.
  _ensure_release_dirs "$TB_NAMESPACE"

  # The chart install blocks ~10-15s (render + apply + image pull), so run it
  # behind a spinner instead of a frozen terminal — spin_cmd streams helm output
  # to $LOG_FILE and, on failure, tails the log to stderr. Honours RFC-0002 §2
  # "progress on every wait".
  if ! spin_cmd "Installing the tracebloc client…" \
    helm upgrade --install "$TB_NAMESPACE" "$chart_ref" \
    --namespace "$TB_NAMESPACE" \
    --create-namespace \
    --values "$values_file"; then
    error "Client installation failed. Check the log for details: ${LOG_FILE:-}"
  fi

  # Point the kubeconfig's current context at the client namespace, so kubectl and
  # the tracebloc CLI default to it with no -n / --namespace flag. Best-effort:
  # a failure here must not abort an otherwise-successful install.
  kubectl config set-context --current --namespace "$TB_NAMESPACE" >/dev/null 2>&1 || true

  # Honest N-of-M count bar as the service images pull onto the node. Best-effort +
  # bounded + non-fatal — the real readiness gate is step f (wait_for_client_ready).
  _download_services_progress "$TB_NAMESPACE"

  success "tracebloc installed"
  log "Values file: $values_file"
}
