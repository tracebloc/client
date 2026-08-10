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

# ── Training-size default (backend#1236, option A) ──────────────────────────
# One knob, requests == limits (Guaranteed QoS). The old static default
# ("cpu=2,memory=8Gi") was wrong at both ends: dead on arrival on nodes under
# 8 GiB (the WSL2 field case — nothing could ever schedule) and ~12% of a
# 64 GiB box. Precedence:
#   1. TRACEBLOC_TRAINING_RESOURCES  (explicit install-time override, client#308)
#   2. the installed release's current value — a `tracebloc resources set`
#      choice must survive re-install, never be clobbered back to a default
#   3. sized to this machine: LARGEST node allocatable − platform overhead
#      (~1 CPU / 3 GiB, the cli's constants; a pod schedules onto ONE node, and
#      k3d's server+agent are the same machine — summing would double-count)
#   4. the historic static default (tiny or undeterminable machines)
_TRAINING_DEFAULT="cpu=2,memory=8Gi"

# k8s cpu quantity -> millicores ("12" -> 12000, "11500m" -> 11500); empty on junk.
_cpu_to_milli() {
  case "$1" in
    *m) printf '%s' "${1%m}" ;;
    ''|*[!0-9]*) : ;;
    *) printf '%s' "$(( $1 * 1000 ))" ;;
  esac
}
# k8s memory quantity -> bytes (Ki/Mi/Gi or plain bytes); empty on junk.
_mem_to_bytes() {
  local v="$1"
  case "$v" in
    *Ki) printf '%s' "$(( ${v%Ki} * 1024 ))" ;;
    *Mi) printf '%s' "$(( ${v%Mi} * 1024 * 1024 ))" ;;
    *Gi) printf '%s' "$(( ${v%Gi} * 1024 * 1024 * 1024 ))" ;;
    ''|*[!0-9]*) : ;;
    *) printf '%s' "$v" ;;
  esac
}

# The installed release's RESOURCE_LIMITS (nested under env:), or nothing.
# Handles both the quoted form our values file writes and the unquoted form
# helm re-serializes (`helm get values` strips quotes — the #200 lesson).
_existing_training_resources() {
  local ns="${TB_NAMESPACE:-}" out
  [[ -n "$ns" ]] || return 0
  # helm get has no request timeout, so gate it behind a BOUNDED probe: a
  # wedged API degrades to machine sizing / the static default instead of
  # hanging values generation (Bugbot). A missing namespace also means there
  # is no release to carry — skip the helm call entirely.
  kubectl get namespace "$ns" --request-timeout=5s >/dev/null 2>&1 || return 0
  out="$(helm get values "$ns" -n "$ns" 2>/dev/null)" || return 0
  printf '%s\n' "$out" | awk '
    /^[[:space:]]*RESOURCE_LIMITS:/ {
      sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, ""); print; exit
    }'
}

# Echo "cpu=N,memory=MGi" sized to the largest node, or nothing when the
# cluster is unreadable / the machine cannot give a run the 1-CPU/2-GiB floor.
_machine_training_resources() {
  has kubectl || return 0
  local lines cpu mem cpu_m mem_b best_cpu=0 best_mem=0
  # Bounded: a wedged API server must degrade to the static default, never
  # hang values generation (Bugbot).
  lines="$(kubectl get nodes --request-timeout=10s -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{" "}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)" || return 0
  [[ -n "$lines" ]] || return 0
  while read -r cpu mem; do
    [[ -n "$cpu" && -n "$mem" ]] || continue
    cpu_m="$(_cpu_to_milli "$cpu")"
    mem_b="$(_mem_to_bytes "$mem")"
    [[ -n "$cpu_m" && -n "$mem_b" ]] || continue
    if (( mem_b > best_mem )) || { (( mem_b == best_mem )) && (( cpu_m > best_cpu )); }; then
      best_mem=$mem_b
      best_cpu=$cpu_m
    fi
  done <<< "$lines"
  (( best_mem > 0 )) || return 0
  local run_cpu_m=$(( best_cpu - 1000 ))            # − ~1 CPU platform overhead
  local run_mem_b=$(( best_mem - 3 * 1024 * 1024 * 1024 ))  # − ~3 GiB overhead
  { (( run_cpu_m >= 1000 )) && (( run_mem_b >= 2 * 1024 * 1024 * 1024 )); } || return 0
  printf 'cpu=%d,memory=%dGi' "$(( run_cpu_m / 1000 ))" "$(( run_mem_b / 1024 / 1024 / 1024 ))"
}

# The per-run training size for the generated values ("cpu=N,memory=MGi").
_training_resources() {
  if [[ -n "${TRACEBLOC_TRAINING_RESOURCES:-}" ]]; then
    printf '%s' "$TRACEBLOC_TRAINING_RESOURCES"
    return 0
  fi
  local prev
  prev="$(_existing_training_resources)"
  # The historic static default was the ABSENCE of a choice, not a choice —
  # carrying it would keep the unschedulable 8Gi on exactly the machines this
  # sizing exists to fix (Bugbot). Only a value that differs from it survives.
  if [[ -n "$prev" && "$prev" != "$_TRAINING_DEFAULT" ]]; then
    printf '%s' "$prev"
    return 0
  fi
  local sized
  sized="$(_machine_training_resources)"
  if [[ -n "$sized" ]]; then
    printf '%s' "$sized"
    return 0
  fi
  printf '%s' "$_TRAINING_DEFAULT"
}

# YAML single-quoted-scalar escaping, in one place (Saqlain review, #443).
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

# _extract_yaml_value — value of top-level scalar key $2 in values file $1.
# CONTRACT: echoes nothing and returns 0 when the key is absent (or the file is
# unreadable). Callers rely on "empty means no value"; they must not have to
# distinguish absent-key from read-error, and none of them do.
_extract_yaml_value() {
  local file="$1" key="$2"
  local line
  # `|| line=""`: on an ABSENT key grep exits 1 and, under `set -o pipefail`,
  # that rc propagates out of the pipeline and out of the assignment — so under
  # `set -e` the installer would abort HERE and never reach the empty-check on
  # the next line, the very line that exists to handle "key not found" (#523).
  # Latent until now only because every call site wraps this in `$( )`, which
  # suspends errexit for the function body; a bare call aborts the install
  # mid-step. Same house idiom as assess.sh / common.sh `_chart_version`.
  #
  # NO `| head -1` on the pipeline: with head in play, a DUPLICATE key makes
  # head exit after the first line and SIGPIPE grep (141) — and under pipefail
  # `|| line=""` would then wipe the successfully captured value, so
  # detect_installed_client could miss a clientId and fail open toward
  # overwrite (Bugbot, #525). Capture every match, then take the first line in
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
  local _gvf _rel _ns _id _list _unreadable=0
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
  #
  # Enumerate deployed + failed + pending client releases. All three are stated
  # EXPLICITLY: `helm list` only auto-enables --deployed "if no other status flag
  # is specified", so a lone --pending would return pending-only and drop the
  # deployed clients the guard exists to protect (Bugbot #619). We need:
  #   - deployed/failed: the normal "a client already runs here" case;
  #   - pending-*: a client wedged by a killed helm run — plain `helm list` hides
  #     these, so without them a re-run under a DIFFERENT clientId would slip past
  #     the guard and let _reconcile_pending_release mutate another client's release.
  #   - uninstalling: an interrupted `helm uninstall --wait` (timed out mid-removal)
  #     leaves the release in `uninstalling`; its resources are still present, so it
  #     is still an OWNED release. Without this a re-run under a DIFFERENT clientId
  #     would see "no client here" and mutate/replace resources still being removed
  #     (Bugbot #619) — the ownership guard must fail CLOSED on it.
  # NOT --all / --uninstalled: an `uninstalled` (keep-history) release is a REMOVED
  # client (removal finished) and must not count as installed, or it would block a
  # legitimate reinstall — unlike `uninstalling`, whose removal never completed.
  if ! _list="$(helm list -A --deployed --failed --pending --uninstalling 2>/dev/null)"; then
    INSTALLED_CLIENT_UNKNOWN=1; rm -f "$_gvf"; return 0
  fi
  while read -r _rel _ns; do
    [[ -z "$_rel" ]] && continue
    if helm get values "$_rel" -n "$_ns" > "$_gvf" 2>/dev/null; then
      _id="$(_extract_yaml_value "$_gvf" clientId)"
      [[ -n "$_id" ]] && { INSTALLED_CLIENT_ID="$_id"; INSTALLED_CLIENT_NS="$_ns"; break; }
      # Values readable but no clientId -> parsed fine, just not a match; keep
      # scanning (mirrors the PowerShell peer's null-clientId `continue`).
    else
      # Couldn't read THIS client release's values -> an UNIDENTIFIABLE client.
      # Record it and keep scanning (a later release may give a definitive id);
      # if none does, fail closed below rather than read it as "no client here".
      _unreadable=1
    fi
  done < <(printf '%s\n' "$_list" | awk '/[[:space:]]client-[0-9]/ { print $1, $2 }')
  # A client release existed but we couldn't read its clientId, and no OTHER
  # release gave a definitive id -> unknown (parity with the PowerShell guard's
  # $unreadableNs fail-closed path).
  [[ -z "$INSTALLED_CLIENT_ID" && "$_unreadable" == 1 ]] && INSTALLED_CLIENT_UNKNOWN=1
  rm -f "$_gvf"
  return 0
}

# _strip_paste_garbage now lives in common.sh (shared with provision.sh's client-
# name prompt); install-k8s.sh sources common.sh before this file, so it's in
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
  # curl_secure (not bare curl) pins the minimum TLS version: this request carries
  # the client's password, and a TLS-inspecting proxy in front of it would happily
  # negotiate whatever the client accepts (backend#1252). -m 60 keeps the tighter
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

# _image_mirror_yaml — emit the top-level chart values that point every image the
# chart pulls at a private registry mirror (#585 / restricted-network installs).
# TRACEBLOC_IMAGE_REGISTRY sets global.imageRegistry: the chart's
# global.imageRegistry convention re-homes tracebloc/*, the spawned ingestor and
# training-job images, and the alpine/* + ubuntu/squid utility images onto that
# host, so an air-gapped / mirror-only network pulls nothing from a public
# registry. When the mirror needs authentication, TRACEBLOC_REGISTRY_USERNAME /
# TRACEBLOC_REGISTRY_PASSWORD also mint the chart's imagePullSecret
# (dockerRegistry), whose server defaults to the mirror host. Emits nothing when
# no mirror is configured, so a default install's values are unchanged.
_image_mirror_yaml() {
  local mirror="${TRACEBLOC_IMAGE_REGISTRY:-}"
  local reg_user="${TRACEBLOC_REGISTRY_USERNAME:-}"
  local reg_pass="${TRACEBLOC_REGISTRY_PASSWORD:-}"
  [[ -z "$mirror" && -z "$reg_user" && -z "$reg_pass" ]] && return 0

  # global.imageRegistry is a BARE host (mirror.corp.example[:port]) — it becomes the
  # prefix of every image reference, so strip a pasted scheme to keep <host>/repo
  # well-formed.
  local mirror_host="${mirror#*://}"

  if [[ -n "$mirror_host" ]]; then
    printf '\nglobal:\n  imageRegistry: '\''%s'\''\n' "$(_yaml_sq_escape "$mirror_host")"
  fi
  if [[ -n "$reg_user" || -n "$reg_pass" ]]; then
    # dockerRegistry.server is the imagePullSecret's auths key and the chart schema
    # REQUIRES it whenever create is true (format:uri), so it must ALWAYS be
    # emitted here. Precedence: an explicit TRACEBLOC_REGISTRY_SERVER wins (e.g. a
    # registry whose auth realm differs from the image host); else derive
    # https://<mirror-host> when a mirror is set; else fall back to Docker Hub so
    # creds-only (authenticate to docker.io, no mirror) still renders a valid
    # secret instead of a schema error.
    local server="${TRACEBLOC_REGISTRY_SERVER:-}"
    if [[ -z "$server" ]]; then
      if [[ -n "$mirror_host" ]]; then
        server="https://$mirror_host"
      else
        server="https://index.docker.io/v1/"
      fi
    fi
    printf '\ndockerRegistry:\n  create: true\n'
    printf '  server: '\''%s'\''\n' "$(_yaml_sq_escape "$server")"
    printf '  username: '\''%s'\''\n' "$(_yaml_sq_escape "$reg_user")"
    printf '  password: '\''%s'\''\n' "$(_yaml_sq_escape "$reg_pass")"
    printf '  email: '\''%s'\''\n' "$(_yaml_sq_escape "${TRACEBLOC_REGISTRY_EMAIL:-}")"
  fi
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
# #554: a helm/k3d process killed mid-operation (Ctrl-C, OOM at a memory limit,
# reboot, laptop sleep) leaves the release in a pending-install /
# pending-upgrade / pending-rollback state. The NEXT `helm upgrade` then fails
# with "another operation is in progress" (exit 1, NOT 124), so the old
# `-eq 124`-guarded hint never fired and the install/reconcile was permanently
# wedged with no auto-recovery. Detect a stuck pending-* status and reconcile it
# in place BEFORE the upgrade:
#   pending-install / uninstalling     -> clear the release and reinstall from
#                                         preserved values (no prior revision to
#                                         roll back to; `uninstalling` is a prior
#                                         run's timed-out uninstall — Bugbot #619)
#   pending-upgrade / pending-rollback -> roll back to the last deployed revision
# jq-free (awk over `helm status -o yaml`, matching this file's conventions) and
# best-effort — a failure here is non-fatal; the subsequent upgrade (and its
# error path) still runs.
# _last_deployed_revision REL NS — echo the revision number of the most recent
# release revision whose status is `deployed` or `superseded` (a known-good,
# fully-rolled-out revision), or nothing if there is none. jq-free awk over
# `helm history -o yaml`, bounded like the other probes.
#
# Why not a bare `helm rollback REL` (previous revision)? After an interrupted
# ATOMIC rollback the immediately-preceding revision is the FAILED upgrade that
# atomic was undoing, so a bare rollback would redeploy the broken chart and
# mark it deployed (Bugbot #619). Roll back to the last KNOWN-GOOD revision
# explicitly instead. The awk carries NO `exit`: it reads the whole stream so
# the `helm history | awk` pipe can't SIGPIPE helm and trip pipefail.
#
# helm marshals each history entry from a Go struct whose FIRST field is
# `revision`, so the real `-o yaml` shape carries the revision on the list-item
# marker line itself — `- revision: N` — with `status:` on a following indented
# line. The parser must therefore associate the revision from EITHER the `- `
# marker line or an indented key line with the entry's status (Bugbot #619): the
# `^-` rule flushes+resets the previous entry FIRST, then the revision rule (which
# also matches the `- revision:` marker) captures this entry's revision. Both key
# rules are anchored to the line start so a value inside `description:` (which can
# legitimately contain the text `revision:`) is never mistaken for a key.
_last_deployed_revision() {
  local _rel="$1" _ns="$2" _hist
  _hist="$(_bounded "${TB_HELM_STATUS_TIMEOUT:-30}" \
    helm history "$_rel" -n "$_ns" -o yaml 2>/dev/null)" || _hist=""
  printf '%s\n' "$_hist" | awk '
    function flush() {
      if (rev != "" && (st == "deployed" || st == "superseded") && rev+0 > best+0) best = rev+0
    }
    /^-[[:space:]]/                          { flush(); rev=""; st="" }
    /^(-|[[:space:]])[[:space:]]*revision:/  { v=$0; sub(/.*revision:[[:space:]]*/, "", v); gsub(/[^0-9]/, "", v); rev=v }
    /^(-|[[:space:]])[[:space:]]*status:/    { v=$0; sub(/.*status:[[:space:]]*/, "", v);   gsub(/[^a-z-]/, "", v);  st=v }
    END { flush(); if (best+0 > 0) print best }
  '
}

# _reconcile_pending_release REL NS [PRESERVE_VALUES_FILE]
#
# PRESERVE_VALUES_FILE (optional, adopt path only): on pending-install the
# uninstall drops the release AND its stored values — including the write-only
# clientPassword the adopt reconcile has no other copy of (adopt issues no new
# password). When a path is given, capture the release's user-supplied values
# there BEFORE uninstalling and set TB_PENDING_REINSTALL=1, so the caller can
# reinstall from those values (`--install -f FILE`) instead of a `--reuse-values`
# upgrade against a release that no longer exists (Bugbot #619). The normal
# install path re-supplies its own values file and passes no path, keeping the
# plain uninstall.
_reconcile_pending_release() {
  local _rel="$1" _ns="$2" _preserve="${3:-}" _raw _status _target
  TB_PENDING_REINSTALL=0
  # Set to 1 only when a pending-install uninstall FAILED/timed out, so the caller
  # fails closed and skips the reinstall instead of racing still-present resources
  # (Bugbot #619). Reset every call so a stale value from an earlier probe can't leak.
  TB_PENDING_UNINSTALL_FAILED=0
  # `helm status` has no request timeout of its own, so a wedged kube-apiserver
  # could hang this recovery probe forever — bound it with _bounded
  # (timeout(1)/gtimeout(1)), the same mechanism the file's other helm/kubectl
  # probes use (Bugbot). On the deadline _bounded returns 124, which the
  # `|| _raw=""` below folds into the benign "nothing to recover" path.
  #
  # `|| _raw=""`: on a FIRST-TIME install there is NO release, so `helm status`
  # exits non-zero; under `set -euo pipefail` that rc would propagate out of the
  # command substitution and abort the installer HERE — before `helm upgrade
  # --install` ever runs (Bugbot). A missing release simply means "nothing to
  # recover", so swallow the failure and fall through with empty output.
  #
  # This is a deliberate fail-OPEN (unlike the CronJob, which fails closed): the
  # installer cannot distinguish "no release" (must proceed to a fresh install)
  # from a transient probe error without breaking first-time installs, and it
  # never silently succeeds on a missed wedge — recovery is best-effort and the
  # `helm upgrade --install` that follows still surfaces a real wedge as "another
  # operation is in progress" (error + the unwedge hint below). The CronJob has
  # no such downstream guard, so it fails closed on a bad probe instead (Bugbot #619).
  _raw="$(_bounded "${TB_HELM_STATUS_TIMEOUT:-30}" \
    helm status "$_rel" -n "$_ns" -o yaml 2>/dev/null)" || _raw=""
  # First status line, parsed in the shell — NO awk `exit` / `head` on a live
  # pipe: under pipefail an early close SIGPIPEs `helm status` on a large
  # release (exit 141) and the `||` fallback would then wipe the captured
  # status, so a real wedge looks absent (Bugbot #619). Same house idiom as
  # _extract_yaml_value: read the whole stream, take the first line in the shell.
  # Anchor at exactly-2-space indent so we match `info.status` and not some
  # `status:` line inside the deeper-indented `info.notes` block (which helm
  # emits BEFORE status, alphabetically).
  _status="$(printf '%s\n' "$_raw" | awk '/^  status:/ {print $2}')"
  _status="${_status%%$'\n'*}"
  case "$_status" in
    pending-install|uninstalling)
      # Two wedges recover the SAME way — clear the release, then reinstall from
      # preserved values:
      #   pending-install — an initial install killed mid-op left a half-created
      #     release with no prior revision to roll back to.
      #   uninstalling — an earlier `helm uninstall --wait` timed out mid-removal
      #     (typically THIS recovery's own uninstall below, on a prior run) and
      #     left the release in `uninstalling`, its resources still terminating.
      # helm refuses to `upgrade` a release in EITHER state, so a same-client
      # re-run must finish clearing it and reinstall rather than fall through to a
      # --reuse-values upgrade that cannot proceed (Bugbot #619).
      #
      # This unblocks only OUR OWN release: the ownership guard
      # (detect_installed_client) still enumerates `uninstalling` and blocks a
      # DIFFERENT client before it ever reaches here, and _reconcile_adopted_client
      # is entered only on the adopt path (provision already matched this cluster
      # to THIS client). So finishing an `uninstalling` release here never mutates
      # a foreign client's release (Bugbot #619).
      if [[ -n "$_preserve" ]]; then
        # Adopt path: stash the wedged release's user values before we drop it,
        # so the caller can reinstall with the only copy of the write-only
        # password. An `uninstalling` release still holds its stored values
        # (helm removes the release record only after the resources drain), so
        # `helm get values` reads them here too. `-o yaml` (not the default
        # header form) so the file feeds straight back with `-f`; helm prints
        # literal `null` when there are no user values.
        if _bounded "${TB_HELM_STATUS_TIMEOUT:-30}" \
             helm get values "$_rel" -n "$_ns" -o yaml > "$_preserve" 2>/dev/null \
           && [[ -s "$_preserve" ]] && [[ "$(head -1 "$_preserve" 2>/dev/null)" != "null" ]]; then
          TB_PENDING_REINSTALL=1
        else
          # Couldn't read the wedged release's values — do NOT uninstall, and do
          # NOT tell the operator to either: for an adopted client the wedged
          # release holds the ONLY copy of the write-only clientPassword, so
          # uninstalling when preservation just failed destroys it for good
          # (Bugbot #619). Leave it in place; re-running the installer retries
          # the preserve, and a persistent wedge is recovered by re-adopting from
          # the dashboard (which re-issues access) — never by uninstalling.
          warn "Release '$_rel' is wedged in $_status and its stored values could not be read; leaving it in place. Re-run the installer to retry recovery. Do NOT 'helm uninstall' — for an adopted client that drops the only stored clientPassword; if it stays wedged, re-adopt this client from the dashboard."
          return 0
        fi
      fi
      log "Release '$_rel' is wedged in $_status (a prior run was killed mid-op); clearing the release before reinstalling."
      # --wait so the uninstall blocks until its resources are actually gone: the
      # adopt path reinstalls the SAME release right after, and without --wait the
      # reinstall can race still-terminating objects and fail on "already exists" /
      # "being deleted" (Bugbot #619). Bounded by the spinner deadline. On an
      # already-`uninstalling` release this simply resumes/finishes the interrupted
      # removal, which is idempotent.
      #
      # Check the uninstall's exit status and fail CLOSED on failure/timeout: a
      # `|| true` here would let a timed-out uninstall (resources still present or
      # terminating) fall through to `helm upgrade --install`, racing exactly the
      # objects --wait exists to drain (Bugbot #619). On failure, do NOT reinstall
      # — signal the caller (TB_PENDING_UNINSTALL_FAILED=1) to skip the reinstall
      # and persist the preserved credential to the durable recovery file so a
      # re-run can retry. TB_PENDING_REINSTALL stays 1 so the caller still treats
      # the preserved values as the only copy of the write-only clientPassword.
      if ! spin_cmd_bounded 120 "Clearing a half-finished install…" \
             helm uninstall "$_rel" -n "$_ns" --wait; then
        TB_PENDING_UNINSTALL_FAILED=1
        warn "Uninstall of the wedged release '$_rel' ($_status) failed or timed out; not reinstalling, to avoid racing still-terminating resources. Re-run the installer to retry."
      fi
      ;;
    pending-upgrade|pending-rollback)
      _target="$(_last_deployed_revision "$_rel" "$_ns")"
      if [[ -z "$_target" ]]; then
        # No known-good revision to roll back to — a bare `helm rollback` here
        # would land on the failed upgrade (Bugbot #619). Leave it wedged for
        # the manual remedy rather than redeploy a broken revision.
        warn "Release '$_rel' is wedged in $_status but has no prior deployed revision to roll back to; leaving it in place. Inspect: helm -n $_ns history $_rel"
        return 0
      fi
      log "Release '$_rel' is wedged in $_status (a prior run was killed mid-op); rolling back to the last deployed revision (r$_target) before retrying."
      spin_cmd_bounded 120 "Recovering a half-finished upgrade…" \
        helm rollback "$_rel" "$_target" -n "$_ns" || true
      ;;
  esac
}

_reconcile_adopted_client() {
  # provision_client (Step 3) hands over the adopted client id (UUID) + the marker on
  # adopt (no password — the existing credential stands). Find the live client release
  # and reconcile it in place. Enumerate it the same jq-free way the one-per-machine
  # guard does. One client per machine, so take the first.
  local _rel="" _ns="" _r _n _recovery_reuse="" _list="" _list_rc=0 _meta_rel="" _meta_ns=""
  # Enumerate deployed + failed + pending + uninstalling, all stated EXPLICITLY:
  # `helm list` only auto-enables --deployed "if no other status flag is specified",
  # so a lone --pending would return pending-only and miss a normally-deployed
  # adopted client (Bugbot #619). --pending keeps a release wedged by a killed helm
  # run discoverable (plain `helm list` hides those) so _reconcile_pending_release
  # can unwedge it; --uninstalling keeps an interrupted `helm uninstall --wait`
  # discoverable as the OWNED release it still is (Bugbot #619). NOT
  # --all/--uninstalled: adoption must not pick a stale removed keep-history release.
  #
  # Capture the enumeration output AND its exit status explicitly (no process
  # substitution, which discards helm's rc): a FAILED `helm list` (unreachable API,
  # kubeconfig glitch) must NOT read as "no live release" and then, with a durable
  # recovery file present, fall through to `helm upgrade --install` — that fails OPEN
  # and mutates the cluster without proving which client already exists. On a
  # non-zero enumeration, FAIL CLOSED: abort rather than reinstall (Bugbot #619).
  _list="$(helm list -A --deployed --failed --pending --uninstalling 2>/dev/null)" || _list_rc=$?
  if [[ "$_list_rc" -ne 0 ]]; then
    error "Could not enumerate existing tracebloc releases (helm list failed); aborting rather than risk overwriting a client that may already be installed. Check cluster/kubeconfig access and re-run."
  fi
  while read -r _r _n; do
    [[ -n "$_r" ]] && { _rel="$_r"; _ns="$_n"; break; }
  done < <(printf '%s\n' "$_list" | awk '/[[:space:]]client-[0-9]/ { print $1, $2 }')
  if [[ -z "$_rel" ]]; then
    # No live release — but a PRIOR adopt reconcile may have uninstalled a wedged
    # pending-install release, failed to reinstall it, and saved the write-only
    # clientPassword to the durable recovery file (Bugbot #619). If that file is
    # here, the release is simply absent (not un-adopted): recover from it by
    # reinstalling, rather than fall through to the normal connect flow, which
    # would prompt for a password the adopt path never holds (adopt re-issues
    # none). The failure message that pointed operators at this file (below) is
    # now honoured by an actual read here. The removed release's ORIGINAL name +
    # namespace were stashed in the sidecar when the credential was saved; reinstall
    # into THOSE, not into a name/ns re-derived from the current TB_NAMESPACE — a
    # legacy or custom-namespace client would otherwise be reinstalled into the
    # wrong namespace/release (Bugbot #619). Fall back to TB_NAMESPACE only when the
    # sidecar is absent (a recovery file written before this fix), with a warning.
    _recovery_reuse="${HOST_DATA_DIR:+${HOST_DATA_DIR}/${_TB_ADOPT_RECOVERY_BASENAME}}"
    if [[ -n "$_recovery_reuse" && -s "$_recovery_reuse" ]]; then
      _meta_rel="$(_read_adopt_recovery_meta_field name)"
      _meta_ns="$(_read_adopt_recovery_meta_field namespace)"
      if [[ -n "$_meta_rel" && -n "$_meta_ns" ]]; then
        _rel="$_meta_rel"; _ns="$_meta_ns"
      else
        _rel="$TB_NAMESPACE"; _ns="$TB_NAMESPACE"
        warn "No recovery metadata found; assuming release name and namespace '$TB_NAMESPACE'. If this client was installed into a custom namespace, re-run with TB_NAMESPACE set to that namespace."
      fi
      info "Recovering this client from the credential saved by a prior interrupted run ($_recovery_reuse)."
    else
      _recovery_reuse=""
      warn "This client is already registered, but no live tracebloc release was found here to reconcile — continuing with a normal connect."
      return 1
    fi
  fi

  TB_NAMESPACE="$_ns"
  # Record the adopted release's ORIGINAL identity in module vars (NOT local) so
  # install_cleanup's signal backstop can stash the SAME name/namespace into the
  # recovery sidecar if a signal lands mid-recovery — a re-run then reinstalls into
  # this identity, not one re-derived from the current TB_NAMESPACE (Bugbot #619).
  _TB_ADOPT_REL="$_rel"; _TB_ADOPT_NS="$_ns"
  info "This machine already runs a tracebloc client — reconciling '${_rel}' (namespace '${_ns}') in place."

  _ensure_helm_runnable
  local chart_ref=""
  _resolve_chart_ref

  # Heal the stored clientId to the adopted UUID when provision_client handed one
  # over (export TRACEBLOC_CLIENT_ID on the adopt path): a cli#125-era install stored
  # the numeric dashboard id, which can't authenticate, and --reuse-values alone
  # would preserve it (the reused password is still correct). With no id (rebuilt
  # host / R7 orphan) reconcile WITHOUT a heal rather than bail — the existing
  # credential stands.
  local _uuid; _uuid="$(_sanitize_credential "${TRACEBLOC_CLIENT_ID:-}")"
  # The automated reconcile below applies `--set clientId=$_uuid` to heal an older
  # adopted release whose preserved values carry a numeric dashboard id (can't
  # authenticate). Any MANUAL recovery command we print must carry the SAME override,
  # or an operator following it reinstalls an unauthenticating client even though
  # helm reports success (Bugbot #619). Empty _uuid (rebuilt host / R7 orphan) => no
  # override, matching the automated path.
  local _id_override=""
  [[ -n "$_uuid" ]] && _id_override=" --set clientId=$_uuid"

  # node-local (RFC-0003 Option C) has no hostPath dirs to pre-create.
  [[ "${TB_STORAGE_MODE:-hostpath}" != "node-local" ]] && _ensure_release_dirs "$_ns"

  # #554: auto-recover a release left pending-* by a previously-killed helm run
  # before we reconcile it, so a re-run isn't permanently wedged. Pass a preserve
  # file: if the release is wedged in pending-install, recovery must uninstall
  # it, which drops the ONLY copy of the write-only clientPassword the adopt path
  # depends on — so _reconcile_pending_release stashes the release's user values
  # there first and sets TB_PENDING_REINSTALL=1, and we reinstall from them below
  # rather than run a --reuse-values upgrade against a release that no longer
  # exists (Bugbot #619).
  # Track the temp path in a module var (NOT `local`) so install_cleanup's
  # EXIT/INT/TERM trap can shred it if a signal lands between capture and the rm
  # below — it holds the write-only clientPassword. Same backstop pattern as
  # _PROVISION_CRED_FILE (#838 / Bugbot #619).
  # Skip when recovering from the durable file: there is no live release to probe
  # or unwedge, and the credential already lives in $_recovery_reuse (Bugbot #619).
  if [[ -z "$_recovery_reuse" ]]; then
    _TB_PENDING_VALUES_FILE="$(mktemp 2>/dev/null)" || _TB_PENDING_VALUES_FILE="${HOST_DATA_DIR:+${HOST_DATA_DIR}/.tb-pending-values.$$}"
    _reconcile_pending_release "$_rel" "$_ns" "$_TB_PENDING_VALUES_FILE"
  else
    TB_PENDING_REINSTALL=0
  fi

  # Build the reconcile command as an array (bash-3.2 safe for the optional
  # --set). Normal case: in-place upgrade reusing the release's stored values
  # (clientPassword + install-time config), preferring --reset-then-reuse-values
  # (Helm >= 3.14: reset to chart defaults, then re-apply the stored user values
  # so new chart defaults flow through) over plain --reuse-values on older Helm.
  # Recovered-from-pending-install case (TB_PENDING_REINSTALL=1): the release was
  # uninstalled, so --reuse-values has nothing to reuse — reinstall with
  # --install from the preserved user values instead (Bugbot #619).
  local _args
  if [[ -n "$_recovery_reuse" ]]; then
    # Re-run recovery: the release is gone; reinstall from the durable saved
    # credential file (Bugbot #619).
    _args=(upgrade --install "$_rel" "$chart_ref" --namespace "$_ns" --values "$_recovery_reuse")
  elif [[ "${TB_PENDING_REINSTALL:-0}" == "1" && -s "$_TB_PENDING_VALUES_FILE" ]]; then
    _args=(upgrade --install "$_rel" "$chart_ref" --namespace "$_ns" --values "$_TB_PENDING_VALUES_FILE")
  else
    local _reuse="--reuse-values"
    helm upgrade --help 2>/dev/null | grep -q -- '--reset-then-reuse-values' && _reuse="--reset-then-reuse-values"
    _args=(upgrade "$_rel" "$chart_ref" --namespace "$_ns" "$_reuse")
  fi
  [[ -n "$_uuid" ]] && _args+=(--set "clientId=$_uuid")

  # Reconcile blocks too — same spinner treatment (RFC-0002 §2), bounded so a
  # wedged kube-apiserver can't hang it forever (#426).
  local _helm_timeout_min
  _helm_timeout_min="$(tb_minutes_or "${TB_HELM_TIMEOUT_MIN:-}" 10)"
  local _helm_rc=0
  if [[ "${TB_PENDING_UNINSTALL_FAILED:-0}" == "1" ]]; then
    # Fail closed: the pending-install uninstall failed/timed out, so the release's
    # resources may still be present or terminating. Running `helm upgrade --install`
    # now would race them (the bug --wait exists to prevent). Skip the reinstall and
    # drop into the failure path below (_helm_rc != 0 with TB_PENDING_REINSTALL=1),
    # which persists the preserved credential to the durable recovery file so a
    # re-run can retry, then aborts (Bugbot #619).
    _helm_rc=1
  else
    spin_cmd_bounded "$(( _helm_timeout_min * 60 ))" "Reconciling the existing client…" helm "${_args[@]}" || _helm_rc=$?
  fi

  # Re-run recovery (reinstalled from the durable saved credential file): dispose of
  # the saved copy on the outcome (Bugbot #619). On success the credential now lives
  # in the reinstalled release, so the durable copy is redundant — shred it. On
  # failure KEEP it (still the only copy of the write-only clientPassword) so the
  # next re-run can retry. Handled here, ahead of the temp-file disposal below,
  # because this path created no temp file and must not fall into the generic
  # pending-* wedge remedy (there is no live release to roll back).
  if [[ -n "$_recovery_reuse" ]]; then
    if [[ "$_helm_rc" -eq 0 ]]; then
      rm -f "$_recovery_reuse" 2>/dev/null || true
      # Drop the identity sidecar too — it is only meaningful paired with the
      # credential file we just shredded (Bugbot #619).
      [[ -n "${HOST_DATA_DIR:-}" ]] && rm -f "${HOST_DATA_DIR}/${_TB_ADOPT_RECOVERY_META_BASENAME}" 2>/dev/null || true
      kubectl config set-context --current --namespace "$_ns" >/dev/null 2>&1 || true
      return 0
    fi
    warn "Recovery from the saved credential file failed; it is kept (0600) at: $_recovery_reuse"
    hint "Re-run the installer to retry, or reconcile manually:"
    hint "  helm -n $_ns upgrade --install $_rel $chart_ref -f $_recovery_reuse$_id_override"
    error "Reconcile of the existing client failed. Check the log for details: ${LOG_FILE:-}"
  fi

  # Dispose of the preserved clientPassword based on the outcome (Bugbot #619).
  # The credential is write-only: for an adopted client the wedged release was its
  # only copy, so we must NOT shred the preserved copy while it's still the only
  # one that exists.
  local _reinstalled="${TB_PENDING_REINSTALL:-0}"
  if [[ "$_helm_rc" -eq 0 || "$_reinstalled" != "1" ]]; then
    # Success (credential now stored in the reconciled release), OR a plain
    # --reuse-values upgrade that FAILED but left the existing release — and its
    # stored credential — intact. Either way the temp copy is redundant: shred it.
    [[ -n "${_TB_PENDING_VALUES_FILE:-}" && "$_TB_PENDING_VALUES_FILE" != /dev/null ]] && rm -f "$_TB_PENDING_VALUES_FILE"
    unset _TB_PENDING_VALUES_FILE
  else
    # Reinstall FAILED after the wedged release was already uninstalled: the temp
    # copy is now the ONLY copy of the write-only clientPassword. Persist it to a
    # durable 0600 file under HOST_DATA_DIR (the dir that already holds the normal
    # values.yaml) so it survives this failed run and a re-run can recover from it,
    # rather than losing the credential for good.
    local _recovery=""
    if [[ -n "${HOST_DATA_DIR:-}" && -s "${_TB_PENDING_VALUES_FILE:-/dev/null}" ]] && mkdir -p "$HOST_DATA_DIR" 2>/dev/null; then
      _recovery="${HOST_DATA_DIR}/${_TB_ADOPT_RECOVERY_BASENAME}"
      if cp "$_TB_PENDING_VALUES_FILE" "$_recovery" 2>/dev/null; then
        chmod 600 "$_recovery" 2>/dev/null || true
        # Persist the ORIGINAL release identity next to the credential so a re-run
        # reinstalls into THIS namespace/release, not one re-derived from the
        # current TB_NAMESPACE (Bugbot #619).
        _write_adopt_recovery_meta "$_rel" "$_ns"
      else
        _recovery=""
      fi
    fi
    [[ -n "${_TB_PENDING_VALUES_FILE:-}" && "$_TB_PENDING_VALUES_FILE" != /dev/null ]] && rm -f "$_TB_PENDING_VALUES_FILE"
    unset _TB_PENDING_VALUES_FILE
    if [[ -n "$_recovery" ]]; then
      warn "Reinstall failed after the wedged release was removed. Your client credential is saved (0600) at: $_recovery"
      hint "Re-run the installer to retry, or reconcile manually:"
      hint "  helm -n $_ns upgrade --install $_rel $chart_ref -f $_recovery$_id_override"
    else
      warn "Reinstall failed after the wedged release was removed and the credential copy could not be saved."
      hint "Re-adopt this client from the dashboard to reissue access."
    fi
    error "Reconcile of the existing client failed. Check the log for details: ${LOG_FILE:-}"
  fi
  if [[ "$_helm_rc" -ne 0 ]]; then
    # Non-reinstall failure path (the release still exists). A helm run killed
    # mid-operation can leave it wedged pending-*; surface the manual remedy on
    # ANY failure (#554). Point at the last DEPLOYED revision, never a bare
    # `helm rollback` (= previous revision, which after an interrupted atomic
    # rollback is the failed upgrade — Bugbot #619).
    hint "If a re-run reports 'another operation is in progress', unwedge the release first:"
    hint "  helm -n $_ns history $_rel     (find the newest DEPLOYED revision, then:)"
    hint "  helm -n $_ns rollback $_rel <REVISION>    (roll back to that revision)"
    error "Reconcile of the existing client failed. Check the log for details: ${LOG_FILE:-}"
  fi

  # Reconcile succeeded. A PRIOR interrupted run may have left a durable recovery
  # credential file (+ identity sidecar) after a timed-out pending-install uninstall
  # — e.g. the re-run that just recovered an `uninstalling` release by reinstalling
  # from the live release's preserved values (Bugbot #619). The credential now lives
  # in the reconciled release, so that copy is redundant: shred it rather than leave a
  # write-only clientPassword lingering in plaintext on disk. Best-effort; the
  # _recovery_reuse success path above already shreds its own source file and returns
  # before here, so this only clears a leftover from a DIFFERENT prior run.
  if [[ -n "${HOST_DATA_DIR:-}" ]]; then
    rm -f "${HOST_DATA_DIR}/${_TB_ADOPT_RECOVERY_BASENAME}" \
          "${HOST_DATA_DIR}/${_TB_ADOPT_RECOVERY_META_BASENAME}" 2>/dev/null || true
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
# Detect a PERMANENT image-pull failure among the namespace's pods, so the progress
# copy can tell the truth instead of "still downloading" (#425). On a visible pull
# failure it prints the concrete pod status line(s) + the matching pull event and
# returns 0; when no pull failure is visible it prints nothing and returns 1.
# Bounded + non-fatal; mirrors summary.sh::_diagnose_not_ready's pull signals but is
# self-contained so it needs no cross-lib sourcing.
_pull_failure_detail() {
  local ns="$1" kube_timeout="${TB_PROGRESS_KUBECTL_TIMEOUT:-5s}" pods bad events pull_fail
  has kubectl || return 1
  [[ -n "$ns" ]] || return 1
  pods="$(kubectl get pods -n "$ns" --request-timeout="$kube_timeout" 2>/dev/null || true)"
  bad="$(printf '%s\n' "$pods" | grep -iE 'ImagePullBackOff|ErrImagePull|InvalidImageName' || true)"
  [[ -n "$bad" ]] || return 1
  events="$(kubectl get events -n "$ns" --request-timeout="$kube_timeout" 2>/dev/null || true)"
  # Scope to the PULL-failure events only (like summary.sh::_diagnose_not_ready and the
  # PowerShell path) — never a bare x509/TLS match: kubectl prints one event per line,
  # so an x509 on a pull-failure line is already captured here, while an UNRELATED x509
  # event elsewhere in the ns must not, via tail, displace the real reason (#425 Bugbot).
  pull_fail="$(printf '%s\n' "$events" | grep -iE 'failed to pull|ErrImagePull' | tail -n 3 || true)"
  # Cap the failing-pod lines (like the PowerShell path's Select-Object -First 3) so a
  # cluster with many stuck pods doesn't print a wall of indented lines (reviewer).
  # Herestring, NOT `printf … | head -n 3`: under `set -o pipefail` head closes the
  # pipe after its 3rd line, so a namespace with enough stuck pods to push `$bad`
  # past the ~64KB pipe buffer makes printf take SIGPIPE → the pipeline exits 141 →
  # with errexit live this function aborts HERE and drops the scoped pull event
  # below — the one actionable line (x509 / blocked registry / auth). Measured on
  # bash 5.2.21 + coreutils 9.4: 65,622 bytes is already enough. `<<<` reads from a
  # temp file, so there is no writer left to signal and no `|| true` to mask it.
  head -n 3 <<< "$bad"
  [[ -n "$pull_fail" ]] && printf '%s\n' "$pull_fail"
  return 0
}

# Pure: pick the honest end-of-progress outcome (#425). Prints one token:
#   done       — every container has an image (pulled >= total)
#   failed     — a permanent pull failure is visible (has_fail non-empty)
#   downloading— no failure, but pulls demonstrably progressed (max_pulled > 0)
#   stalled    — nothing pulled and no failure signal yet (pods stuck Pending, etc.)
# A permanent failure NEVER maps to "downloading", so it can't be sold as background
# progress. Kept pure so the decision is unit-testable without a live cluster.
_progress_end_message() {
  local pulled="$1" total="$2" max_pulled="$3" has_fail="$4"
  if (( pulled >= total )); then printf 'done'; return; fi
  if [[ -n "$has_fail" ]];  then printf 'failed'; return; fi
  if (( max_pulled > 0 ));   then printf 'downloading'; return; fi
  printf 'stalled'
}

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

  local deadline pulled=0 max_pulled=0
  deadline=$(( $(date +%s) + ${TB_PULL_TIMEOUT:-300} ))
  tput civis 2>/dev/null || true
  while :; do
    pulled="$(kubectl get pods -n "$ns" --request-timeout="$kube_timeout" \
      -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}' 2>/dev/null \
      | grep -c '.')" || pulled=0
    [[ "$pulled" =~ ^[0-9]+$ ]] || pulled=0
    if (( pulled > total )); then pulled=$total; fi
    if (( pulled > max_pulled )); then max_pulled=$pulled; fi
    count_bar "$pulled" "$total" "services"
    if (( pulled >= total )); then break; fi
    if (( $(date +%s) >= deadline )); then break; fi
    sleep 2
  done
  printf "\r\033[K"
  tput cnorm 2>/dev/null || true

  # Tell the truth on timeout: a permanent pull failure (x509/blocked registry/auth)
  # must NOT be sold as "downloading in the background" (#425). Classify, then print
  # copy that matches reality; the authoritative diagnosis still follows in the
  # readiness gate + summary.
  local fail_detail="" outcome
  if (( pulled < total )); then fail_detail="$(_pull_failure_detail "$ns" || true)"; fi
  outcome="$(_progress_end_message "$pulled" "$total" "$max_pulled" "$fail_detail")"
  case "$outcome" in
    done)
      success "Downloaded — ${total} services" ;;
    failed)
      # Soften the wording (reviewer): ImagePullBackOff can also be a transient blip /
      # registry 429 that kubelet keeps retrying, so wait_for_client_ready may still
      # reach "connected" — don't state an absolute that a later ✔ could contradict.
      warn "Some images look stuck pulling — this usually needs action, not just more time:"
      printf '%s\n' "$fail_detail" | sed 's/^/      /'
      info "Likely a blocked registry, an untrusted TLS-inspection CA, or auth — see the diagnosis below." ;;
    downloading)
      info "Services are still downloading — they'll finish starting in the background." ;;
    stalled)
      info "Services haven't started pulling yet — see the diagnosis below if this persists." ;;
  esac
  return 0
}

# ── MySQL engine channel (backend#723, decision A2 2026-08-05) ─────────────
# The chart's frozen 5.7 digest pin stays the default for every existing
# install; FRESH installs may opt into the multi-arch 8.4 engine. `auto`
# picks 8.4 only on a fresh arm64 install — the one cohort 5.7 actually hurts
# (amd64-only image under emulation). Anything that smells like existing
# state stays 5.7: an existing release, real mysql datadir content on the
# host (legacy or per-release layout), or nothing at all to suggest 8.4.
# A previous opt-in stays sticky across re-runs (the values file is
# regenerated every run, so it is re-derived from the old file first). The
# chart's mysql-format-guard init container backstops whatever this
# heuristic misses — a wrong pick fails loudly before mysqld starts, it
# never opens a datadir with the wrong engine.
#   TB_MYSQL_ENGINE=auto|5.7|8.4    explicit value always wins (default auto)
# Reads (bash dynamic scope, set by install_client_helm before the call):
# values_file, existing_id, HOST_DATA_DIR, TB_NAMESPACE, ARCH.
# Sets: TB_MYSQL_ENGINE_RESOLVED.
# Content test for a host mysql datadir, FAIL-CLOSED on unlistable dirs
# (mirrors _leftover_data_dirs, and the same Bugbot ownership case): a
# uid-999/root-owned dir the host user can't read/enter cannot be proven
# empty — treat it as content, so `auto` keeps 5.7 rather than opting a
# reused datadir into 8.4 that the format guard would then refuse to boot.
# Symlinks are never trusted as data (same stance as the leftover guard).
_mysql_dir_has_content() {
  local d="$1"
  [[ -d "$d" && ! -L "$d" ]] || return 1   # absent -> no content
  [[ -r "$d" && -x "$d" ]] || return 0     # unlistable -> fail closed
  [[ -n "$(ls -A "$d" 2>/dev/null)" ]]
}

_resolve_mysql_engine() {
  local requested="${TB_MYSQL_ENGINE:-auto}"
  case "$requested" in
    5.7|8.4)
      TB_MYSQL_ENGINE_RESOLVED="$requested"
      log "MySQL engine: ${requested} (explicit TB_MYSQL_ENGINE)"
      return 0 ;;
    auto) ;;
    *)
      error "TB_MYSQL_ENGINE must be 'auto', '5.7' or '8.4' (got '${requested}')" ;;
  esac
  # Sticky: an edge that opted into 8.4 stays there on every later re-run.
  if [[ -f "${values_file:-}" ]] \
    && grep -A 3 'mysqlClient:' "${values_file}" 2>/dev/null | grep -q 'tag: "8.4"'; then
    TB_MYSQL_ENGINE_RESOLVED="8.4"
    log "MySQL engine: 8.4 (kept from this machine's existing values.yaml)"
    return 0
  fi
  # Never auto-flip existing state: a found release or real datadir content
  # means a 5.7-format datadir may exist, and 8.4 refuses to open it. The
  # empty dirs _ensure_tracebloc_dirs just created don't count — only files —
  # but an UNLISTABLE dir counts as content (fail closed; see the helper).
  if [[ -n "${existing_id:-}" ]] \
    || _mysql_dir_has_content "${HOST_DATA_DIR:-/nonexistent}/mysql" \
    || _mysql_dir_has_content "${HOST_DATA_DIR:-/nonexistent}/${TB_NAMESPACE:-}/mysql"; then
    TB_MYSQL_ENGINE_RESOLVED="5.7"
    return 0
  fi
  case "${ARCH:-$(uname -m)}" in
    x86_64|amd64)
      TB_MYSQL_ENGINE_RESOLVED="5.7" ;;
    *)
      TB_MYSQL_ENGINE_RESOLVED="8.4"
      log "MySQL engine: 8.4 (fresh install on ${ARCH:-$(uname -m)} — native multi-arch engine, backend#723)" ;;
  esac
}

# #553: give the bundled metrics-server APIService a bounded window to register
# before helm renders. On a freshly created k3d cluster k3s applies its bundled
# metrics-server (and the v1beta1.metrics.k8s.io APIService) shortly AFTER the
# API server is ready; `k3d cluster create --wait` only gates on node/serverlb
# readiness, not bundled addons. The resource-monitor DaemonSet template calls
# `{{ fail }}` at render time if that APIService isn't registered yet, so on a
# slow WSL2/laptop helm can render in that window and abort the WHOLE install.
# Best-effort: if the APIService never registers here we fall through and let
# the chart's render-time guard produce its actionable error, so a genuinely
# missing metrics-server is still caught (issue's preferred option (a)).
_wait_for_metrics_apiservice() {
  # Skipped entirely under the bats suite (TB_NO_SERVICE_PROGRESS, set in setup())
  # or when kubectl is unavailable — same guard the neighbouring network-y step
  # _download_services_progress uses. Without this the poll loop below would
  # `sleep 3` up to the full ${TB_METRICS_WAIT_S:-120}s in every mocked
  # install_client_helm test (kubectl absent on the CI runner just makes each
  # `kubectl get` fail instantly, so the loop still burns its whole deadline),
  # blowing the job's 10-min deadline. Real installs never set the flag and
  # always have kubectl, so the wait is unchanged for them.
  [[ -n "${TB_NO_SERVICE_PROGRESS:-}" ]] && return 0
  has kubectl || return 0
  local _timeout_s="${TB_METRICS_WAIT_S:-}"
  case "$_timeout_s" in ''|*[!0-9]*) _timeout_s=120 ;; *) _timeout_s=$((10#$_timeout_s)) ;; esac
  local _deadline=$(( SECONDS + _timeout_s ))
  while (( SECONDS < _deadline )); do
    if kubectl get apiservice v1beta1.metrics.k8s.io --request-timeout=10s >/dev/null 2>&1; then
      # Registered — give it a moment to also report Available, but don't fail
      # the install if it's merely slow to become ready; the DaemonSet only
      # needs the APIService present at render time.
      kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io \
        --timeout=30s >/dev/null 2>&1 || true
      log "metrics.k8s.io APIService registered — proceeding with helm install."
      return 0
    fi
    sleep 3
  done
  log "metrics.k8s.io APIService not registered after ${_timeout_s}s — proceeding; the chart guards if metrics-server is genuinely absent."
  return 0
}

install_client_helm() {
  # Step e (Install tracebloc) — main() prints the "e) Installing tracebloc"
  # header. The credential + namespace were provisioned in step d
  # (provision_client) or supplied via dual-mode (TRACEBLOC_CLIENT_ID/PASSWORD or
  # TRACEBLOC_VALUES_FILE). This step renders the values, runs Helm, and shows the
  # services download; the final connect + summary is step f.
  # node-local (RFC-0003 Option C): data lives inside the node, so skip the
  # world-writable ~/.tracebloc/{data,logs,mysql} dirs; just ensure the base dir
  # exists for values.yaml + the install log.
  if [[ "${TB_STORAGE_MODE:-hostpath}" == "node-local" ]]; then
    mkdir -p "$HOST_DATA_DIR"
  else
    _ensure_tracebloc_dirs
  fi
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

  # Both credentials go into SINGLE-quoted YAML scalars through the shared
  # escaper. clientId used to be interpolated raw into a DOUBLE-quoted scalar
  # (clientId: "$TB_CLIENT_ID"), where a `"` or `\` in the value would corrupt the
  # generated values file — the same bug class as the password, and unguarded:
  # _sanitize_credential only strips paste/non-printable characters. In practice
  # verify_credentials gates it to UUIDs, so this is hardening rather than a live
  # break, but the interpolation itself is now safe (Saqlain review, #443).
  TB_CLIENT_ID_ESCAPED="$(_yaml_sq_escape "$TB_CLIENT_ID")"
  TB_CLIENT_PASSWORD_ESCAPED="$(_yaml_sq_escape "$TB_CLIENT_PASSWORD")"

  # ── GPU limits ──────────────────────────────────────────────────────────
  local gpu_val
  if [[ "${GPU_VENDOR:-}" == "nvidia" ]]; then
    gpu_val="nvidia.com/gpu=1"
    log "NVIDIA GPU detected — setting GPU_LIMITS and GPU_REQUESTS to nvidia.com/gpu=1"
  else
    gpu_val=""
    log "No NVIDIA GPU — GPU_LIMITS and GPU_REQUESTS left empty"
  fi

  # backend#723 A2: pick the MySQL engine for this install (before the heredoc
  # below is rendered; see _resolve_mysql_engine for the full decision rules).
  _resolve_mysql_engine

  # ── Write generated values.yaml ─────────────────────────────────────────
  log "Writing values to $values_file"

  # Translate a corporate proxy on the host into the chart's split proxy keys so
  # every egress-needing workload inherits it (see _chart_proxy_env_yaml). Empty
  # when the host has no proxy — the env: block is then unchanged.
  local proxy_env_yaml
  proxy_env_yaml="$(_chart_proxy_env_yaml)"
  [[ -n "$proxy_env_yaml" ]] && log "Corporate proxy detected on host — propagating to client workloads via chart values."

  # Private registry mirror (#585): re-home every image onto TRACEBLOC_IMAGE_REGISTRY
  # for restricted-network / air-gapped installs. Empty when unset (values unchanged).
  local image_mirror_yaml
  image_mirror_yaml="$(_image_mirror_yaml)"
  if [[ -n "${TRACEBLOC_IMAGE_REGISTRY:-}" ]]; then
    log "Image registry mirror configured — pulling all images from ${TRACEBLOC_IMAGE_REGISTRY}."
    [[ -n "${TRACEBLOC_REGISTRY_USERNAME:-}" ]] && log "Mirror credentials provided — minting an imagePullSecret for the mirror."
  fi

  # backend#1236 (option A): size the default training budget to this machine.
  local training_size
  training_size="$(_training_resources)"
  log "Training size: ${training_size} (adjust any time with 'tracebloc resources set')"

  cat <<EOF > "$values_file"
# ============================================================
# Generated by tracebloc installer — client configuration
# ============================================================

env:
$([ -n "${CLIENT_ENV:-}" ] && printf '  CLIENT_ENV: "%s"\n' "$CLIENT_ENV")${proxy_env_yaml}
  # Training size: how much CPU/RAM each training run gets. One knob sets
  # requests == limits (Guaranteed QoS; client-runtime keeps them in lockstep).
  # Sized to this machine at install — largest node minus ~1 CPU / 3 GiB
  # platform overhead — unless TRACEBLOC_TRAINING_RESOURCES is set or the
  # installed release already carries a choice (backend#1236, option A).
  RESOURCE_LIMITS: "${training_size}"
  RESOURCE_REQUESTS: "${training_size}"
  GPU_LIMITS: "$gpu_val"
  GPU_REQUESTS: "$gpu_val"
  RUNTIME_CLASS_NAME: ""
  # client-runtime#92: installer-provisioned k3d is a fixed single-host cluster
  # that cannot autoscale, so jobs-manager applies the hard CPU-or-GPU rule —
  # a Pending GPU pod is downgraded to CPU rather than waiting for a GPU node
  # that will never arrive.
  SINGLE_NODE: "true"
$([ -n "${HOST_DATASET_DIR:-}" ] && printf '  HOST_UID: "%s"\n  HOST_GID: "%s"\n' "$(id -u)" "$(id -g)")
$(if [[ "${TB_STORAGE_MODE:-hostpath}" == "node-local" ]]; then
cat <<'STORAGE'
# RFC-0003 Option C — node-local: use k3s's built-in local-path StorageClass.
# No hostPath PVs, so dataset volumes are provisioned inside the k3d node and
# are destroyed by `cluster delete` rather than left as host files.
storageClass:
  create: false
  name: local-path

hostPath:
  enabled: false
STORAGE
else
cat <<'STORAGE'
storageClass:
  create: true
  name: client-storage-class
  provisioner: manual
  allowVolumeExpansion: true
  parameters: {}

hostPath:
  enabled: true
STORAGE
[ -n "${HOST_DATASET_DIR:-}" ] && printf '  datasetPath: /tracebloc-data\n'
fi)
$(if [[ "${TB_MYSQL_ENGINE_RESOLVED:-5.7}" == "8.4" ]]; then
cat <<'MYSQL84'

# MySQL engine opt-in (backend#723, decision A2): this install runs the
# multi-arch 8.4 engine natively — fresh datadirs only; the chart's
# mysql-format-guard init container refuses a mismatched datadir. Explicit
# tag + empty digest: the chart's 5.7 reproducibility pin stays for installs
# on the default engine. Sticky across installer re-runs; override with
# TB_MYSQL_ENGINE=5.7|8.4.
images:
  mysqlClient:
    tag: "8.4"
    digest: ""
MYSQL84
fi)
pvc:
  mysql: 2Gi
  logs: 10Gi
  data: 50Gi

pvcAccessMode: ReadWriteOnce

clusterScope: true
${image_mirror_yaml}
clientId: '$TB_CLIENT_ID_ESCAPED'
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
  # node-local (RFC-0003 Option C) has no hostPath dirs to pre-create.
  [[ "${TB_STORAGE_MODE:-hostpath}" != "node-local" ]] && _ensure_release_dirs "$TB_NAMESPACE"

  # #553: wait out the metrics-server APIService registration race before helm
  # renders the resource-monitor DaemonSet (whose template hard-fails if the
  # metrics API isn't registered yet). Bounded + best-effort. The outer spinner
  # deadline must never truncate the configured inner wait, so derive it from
  # TB_METRICS_WAIT_S (same parse as _wait_for_metrics_apiservice) plus slack for
  # the post-registration `kubectl wait --for=Available` (30s) and jitter.
  local _metrics_wait_s="${TB_METRICS_WAIT_S:-}"
  case "$_metrics_wait_s" in ''|*[!0-9]*) _metrics_wait_s=120 ;; *) _metrics_wait_s=$((10#$_metrics_wait_s)) ;; esac
  spin_cmd_bounded "$(( _metrics_wait_s + 60 ))" "Waiting for the metrics API to register…" \
    _wait_for_metrics_apiservice || true

  # #554: auto-recover a release left pending-* by a previously-killed helm run
  # (Ctrl-C, OOM, reboot, laptop sleep) before we try to install/upgrade, so a
  # re-run isn't permanently wedged on "another operation is in progress".
  _reconcile_pending_release "$TB_NAMESPACE" "$TB_NAMESPACE"

  # The chart install blocks ~10-15s (render + apply + image pull), so run it
  # behind a spinner instead of a frozen terminal — spin_cmd_bounded streams
  # helm output to $LOG_FILE and, on failure, tails the log to stderr. Honours
  # RFC-0002 §2 "progress on every wait"; the deadline stops a wedged
  # kube-apiserver from hanging the install forever (#426).
  local _helm_timeout_min
  _helm_timeout_min="$(tb_minutes_or "${TB_HELM_TIMEOUT_MIN:-}" 10)"
  local _helm_rc=0
  spin_cmd_bounded "$(( _helm_timeout_min * 60 ))" "Installing the tracebloc client…" \
    helm upgrade --install "$TB_NAMESPACE" "$chart_ref" \
    --namespace "$TB_NAMESPACE" \
    --create-namespace \
    --values "$values_file" || _helm_rc=$?
  if [[ "$_helm_rc" -ne 0 ]]; then
    # A helm run killed mid-operation (our timeout=124, or an earlier
    # Ctrl-C/OOM/reboot) can leave the release wedged pending-*; we auto-recover
    # before the upgrade (see _reconcile_pending_release), but surface the
    # manual remedy on ANY failure (#554) — not only our own timeout — since the
    # next run's "another operation is in progress" also exits 1.
    hint "If a re-run reports 'another operation is in progress', unwedge the release first:"
    hint "  first install:  helm -n $TB_NAMESPACE uninstall $TB_NAMESPACE    (removes only the half-installed release)"
    hint "  upgrade:        helm -n $TB_NAMESPACE history $TB_NAMESPACE      (find the newest DEPLOYED revision, then:)"
    hint "                  helm -n $TB_NAMESPACE rollback $TB_NAMESPACE <REVISION>   (roll back to that revision, not a bare rollback)"
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
