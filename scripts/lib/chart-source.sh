#!/usr/bin/env bash
# =============================================================================
#  chart-source.sh — how the chart and its images are reached: the corporate
#  proxy and the image mirror rendered into the chart's values, and the chart
#  verified as tracebloc's (verify_client_chart) and resolved (_resolve_chart_ref).
# =============================================================================

# ── Corporate-proxy passthrough into the chart ───────────────────────
# The node gets the host's HTTP(S)_PROXY (cluster.sh, _node_proxy_env) so
# containerd can pull images behind a corporate proxy. But the client
# *workloads* — jobs-manager (api + pods-monitor), the egress gate, the
# image-refresh / auto-upgrade cronjobs — only get proxy egress if the CHART
# renders it, and the chart's tracebloc.proxyEnv helper is driven by the SPLIT
# keys (HTTP_PROXY_HOST/_PORT/_USERNAME/_PASSWORD), not a raw HTTP_PROXY URL.
# Without them every backend-dialing pod CrashLoopBackOffs on api-token-auth/
# behind a corporate proxy (observed on a hospital / proxy-only tenant, 2026-06-09). This fills the workload half
# of the proxy support that node-level propagation alone missed.
#
# We deliberately emit the SPLIT form, not a raw env.HTTP_PROXY: on the released
# 1.6.0 chart a raw env.HTTP_PROXY with no HTTP_PROXY_HOST is dropped by the
# proxy-key exclusion (a past regression). HTTP_PROXY_HOST drives
# proxyEnv and is correct on every released chart.
#
# Reads the first set of HTTP_PROXY/HTTPS_PROXY (upper- then lower-case);
# supports authenticated proxies (http://user:pass@host:port), splitting on the
# LAST '@' so a ':' or '@' inside the password is tolerated. Echoes YAML lines
# for the env: block (each prefixed with a newline, 2-space indent), or nothing
# when the host has no proxy set.
# _chart_proxy_env_yaml runs with bash -x held off, the secret it holds out of the trace (output.sh);
# _tb_untraced__chart_proxy_env_yaml below is the function itself.
_chart_proxy_env_yaml() { { _tb_trace_off; } 2>/dev/null; _tb_untraced__chart_proxy_env_yaml "$@"; local _tb_rc=$?; _tb_trace_on; return "$_tb_rc"; }
_tb_untraced__chart_proxy_env_yaml() {
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
# chart pulls at a private registry mirror (restricted-network installs).
# TRACEBLOC_IMAGE_REGISTRY sets global.imageRegistry: the chart's
# global.imageRegistry convention re-homes tracebloc/*, the spawned ingestor and
# training-job images, and the alpine/* utility images onto that host (the
# egress gateway's squid-tracebloc is a tracebloc/* image), so an air-gapped /
# mirror-only network pulls nothing from a public
# registry. When the mirror needs authentication, TRACEBLOC_REGISTRY_USERNAME /
# TRACEBLOC_REGISTRY_PASSWORD also mint the chart's imagePullSecret
# (dockerRegistry), whose server defaults to the mirror host. Emits nothing when
# no mirror is configured, so a default install's values are unchanged.
# _image_mirror_yaml runs with bash -x held off, the secret it holds out of the trace (output.sh);
# _tb_untraced__image_mirror_yaml below is the function itself.
_image_mirror_yaml() { { _tb_trace_off; } 2>/dev/null; _tb_untraced__image_mirror_yaml "$@"; local _tb_rc=$?; _tb_trace_on; return "$_tb_rc"; }
_tb_untraced__image_mirror_yaml() {
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

# ── The chart is tracebloc's (verify_client_chart) ───────────────────────────
# Who may sign the chart, and the cosign build that checks it: install.sh's
# SIGNER_REPOS, SIGNER_ID_RE and COSIGN_VERSION, which install-chart-verify.bats holds
# these copies to (the core runs without install.sh in tracebloc's WSL distro).
TB_COSIGN_VERSION="v2.4.1"
TB_CHART_SIGNER_REPOS='client|client-dev'
TB_CHART_SIGNER_RE="^https://github\.com/tracebloc/(${TB_CHART_SIGNER_REPOS})/\.github/workflows/release-helm-chart\.yaml@refs/tags/v.*"
TB_CHART_SIGNER_ISSUER='https://token.actions.githubusercontent.com'
# Where cosign's `initialize` fetches Sigstore's trust root from (its default TUF mirror).
TB_SIGSTORE_TUF_HOST="tuf-repo-cdn.sigstore.dev"
TRACEBLOC_COSIGN_MIN_BYTES="${TRACEBLOC_COSIGN_MIN_BYTES:-1048576}"   # a real cosign build is far larger
TB_CHART_VERIFIED=""   # the checked chart file, which _resolve_chart_ref installs
_TB_CHART_HTTP=""
_TB_COSIGN=""

# _tb_chart_get URL DEST -- fetch URL to DEST, up to three tries 5 s then 10 s apart
# while the answer is one a wait can cure (none, 408, 429, a 5xx). The last HTTP status
# is left in _TB_CHART_HTTP (000: no answer); 0 only for a 200 whose body curl delivered
# whole. Any curl failure (a cut transfer, a redirect loop) is no answer, wait-curable.
_tb_chart_get() {
  local try rc
  for try in 1 2 3; do
    rc=0
    _TB_CHART_HTTP="$(curl_secure -sSL --speed-limit 1024 --speed-time 60 -o "$2" -w '%{http_code}' "$1" 2>>"${LOG_FILE:-/dev/null}")" || rc=$?
    [[ "$_TB_CHART_HTTP" != 200 || "$rc" != 0 ]] || return 0
    [[ "$rc" == 0 ]] || _TB_CHART_HTTP=000
    log "Chart check: $1 answered ${_TB_CHART_HTTP:-000} (try $try of 3)"
    case "$_TB_CHART_HTTP" in ""|000|408|429|5[0-9][0-9]) ;; *) return 1 ;; esac
    [[ "$try" == 3 ]] || sleep $(( try * 5 ))
  done
  return 1
}

# _tb_chart_unreachable URL STATUS -- stop: the check could not download from URL's host,
# said in step 1's words for a host it cannot reach (preflight's _pf_connectivity).
_tb_chart_unreachable() {
  local host="${1#*://}"
  host="${host%%/*}"
  case "${2:-000}" in
    ""|000|408|429|5[0-9][0-9])
      tb_fail_next "Check this machine's connection and proxy, then run the installer again:"
      error_said "No answer from · ${host}" "The chart check could not download $1 (last status ${2:-000})." ;;
    *)
      tb_fail_next "Allow HTTPS to those addresses, then run the installer again:"
      error_said "Blocked on this network · ${host}" "The chart check could not download $1 (status $2)." ;;
  esac
}

# _tb_chart_unsigned WHY -- stop: the chart is not one tracebloc's release signed. Only
# step a's check (verify_client_chart --before-deps, which sets _tb_chart_step_a) runs
# before anything changes, so only it says so; the install-time check runs after steps b-d.
_tb_chart_unsigned() {
  if [[ "${_tb_chart_step_a:-}" == 1 ]]; then
    tb_fail_head "This release isn't signed by tracebloc, so nothing was changed"
  else
    tb_fail_head "This release isn't signed by tracebloc, so it wasn't installed"
  fi
  error_said "" "The client chart was not installed: $1"
}

# _tb_chart_cosign DIR -- the pinned cosign build in _TB_COSIGN: the one install.sh hands
# down (TRACEBLOC_COSIGN), or the one on PATH, when it is that build by its published
# checksum, else that build downloaded into DIR and held to it. Only that build: after its
# `initialize` it verifies with no network, so a failure is the signature's, not Sigstore's.
_tb_chart_cosign() {
  local dir="$1" os arch base want c
  case "$OS" in Linux) os=linux ;; Darwin) os=darwin ;; *) error_said "" "No cosign build for $OS to check the chart with." ;; esac
  case "$ARCH" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) error_said "" "No cosign build for $ARCH to check the chart with." ;; esac
  base="https://github.com/sigstore/cosign/releases/download/${TB_COSIGN_VERSION}"
  _tb_chart_get "$base/cosign_checksums.txt" "$dir/cosign_checksums.txt" \
    || _tb_chart_unreachable "$base/cosign_checksums.txt" "$_TB_CHART_HTTP"
  want="$(awk -v a="cosign-${os}-${arch}" '$2 == a { print $1; exit }' "$dir/cosign_checksums.txt")"
  [[ -n "$want" ]] || error_said "" "cosign ${TB_COSIGN_VERSION} publishes no checksum for cosign-${os}-${arch}."
  for c in "${TRACEBLOC_COSIGN:-}" "$(command -v cosign 2>/dev/null || true)"; do
    [[ -n "$c" && -f "$c" && -x "$c" ]] || continue
    if _verify_sha256 "$want" "$c"; then _TB_COSIGN="$c"; return 0; fi
    log "Chart check: $c is not cosign ${TB_COSIGN_VERSION} for ${os}/${arch}."
  done
  _tb_chart_get "$base/cosign-${os}-${arch}" "$dir/cosign" \
    || _tb_chart_unreachable "$base/cosign-${os}-${arch}" "$_TB_CHART_HTTP"
  # A real cosign build is tens of MB: a smaller 200 is a proxy's error page, not tampering.
  if [[ "$(wc -c <"$dir/cosign" | tr -d ' ')" -lt "$TRACEBLOC_COSIGN_MIN_BYTES" ]]; then
    log "Chart check: $base/cosign-${os}-${arch} answered 200 with a body under ${TRACEBLOC_COSIGN_MIN_BYTES} bytes."
    tb_fail_next "Check this machine's connection and proxy, then run the installer again:"
    error_said "No answer from · github.com" "The chart check downloaded $base/cosign-${os}-${arch} but got a short reply, not the cosign build."
  fi
  _verify_sha256 "$want" "$dir/cosign" || error "System tool checksum verification failed"
  chmod +x "$dir/cosign"
  _TB_COSIGN="$dir/cosign"
}

# _tb_chart_newest INDEX CHART -- "VERSION URL" of CHART's newest stable release in the
# Helm repository index INDEX, the one helm takes with no --version: the highest X.Y.Z
# (build metadata ignored, pre-releases left out) and its first URL. Nothing for none.
_tb_chart_newest() {
  awk -v chart="$2" '
    function keep(   core, v) {
      core = ver; sub(/\+.*/, "", core)
      if (name == chart && url != "" && core ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) {
        split(core, v, ".")
        if (best == "" || v[1] + 0 > b1 || (v[1] + 0 == b1 && (v[2] + 0 > b2 || (v[2] + 0 == b2 && v[3] + 0 > b3)))) {
          best = ver; bu = url; b1 = v[1] + 0; b2 = v[2] + 0; b3 = v[3] + 0
        }
      }
      ver = ""; url = ""; key = ""
    }
    /^entries:/ { inent = 1; next }
    inent && /^[^ ]/ { keep(); inent = 0 }
    !inent { next }
    /^  [^ -][^:]*:/ { keep(); name = $1; sub(/:$/, "", name); next }
    /^  - / { keep(); sub(/^  - /, "    ") }
    /^    [A-Za-z]+:/ {
      key = $1; sub(/:$/, "", key)
      if (key == "version") { ver = $2; gsub(/[\042\047]/, "", ver) }
      next
    }
    /^    - / && key == "urls" && url == "" { url = $2; gsub(/[\042\047]/, "", url) }
    END { keep(); if (best != "") print best, bu }
  ' "$1"
}

# verify_client_chart [--before-deps] -- the chart this run installs, checked before
# anything changes: the newest stable client chart in the Helm repository, against the
# Sigstore bundle its release attaches beside it (<chart url>.bundle), signed as
# TB_CHART_SIGNER_RE. Leaves the checked file in TB_CHART_VERIFIED. A local chart
# (TRACEBLOC_CHART_PATH) is not checked; TRACEBLOC_ALLOW_UNVERIFIED=1 skips it and says
# so. Anything else stops the run. --before-deps (main()'s step a) leaves a host with no
# curl yet, which step b installs, to _resolve_chart_ref's call, which never skips; and
# only it lets a refusal say nothing was changed (_tb_chart_unsigned).
verify_client_chart() {
  [[ -z "$TB_CHART_VERIFIED" ]] || return 0
  if [[ -n "${TRACEBLOC_CHART_PATH:-}" ]]; then
    log "Chart check: the local chart ${TRACEBLOC_CHART_PATH} is installed as it is (TRACEBLOC_CHART_PATH)."
    return 0
  fi
  if [[ "${TRACEBLOC_ALLOW_UNVERIFIED:-0}" == 1 ]]; then
    warn "The chart's signature isn't checked (TRACEBLOC_ALLOW_UNVERIFIED=1, for development only)"
    return 0
  fi
  if [[ "${1:-}" == --before-deps ]] && ! has curl; then
    log "Chart check: nothing to fetch with before step b; the chart is checked before it is installed."
    return 0
  fi
  local dir pick ver url tgz try _tb_chart_step_a=""
  [[ "${1:-}" != --before-deps ]] || _tb_chart_step_a=1
  tb_scratch_dir dir tracebloc-chart || error_said "" "No private folder for the chart check could be made."
  tb_live_quiet "Checking the release..."
  _tb_chart_get "${TRACEBLOC_HELM_REPO_URL%/}/index.yaml" "$dir/index.yaml" \
    || _tb_chart_unreachable "${TRACEBLOC_HELM_REPO_URL%/}/index.yaml" "$_TB_CHART_HTTP"
  grep -q '^entries:' "$dir/index.yaml" \
    || _tb_chart_unreachable "${TRACEBLOC_HELM_REPO_URL%/}/index.yaml" 200
  pick="$(_tb_chart_newest "$dir/index.yaml" "$TRACEBLOC_CHART_NAME")"
  [[ -n "$pick" ]] || _tb_chart_unsigned "${TRACEBLOC_HELM_REPO_URL} lists no stable ${TRACEBLOC_CHART_NAME} chart."
  ver="${pick%% *}"; url="${pick#* }"
  [[ "$url" == *://* ]] || url="${TRACEBLOC_HELM_REPO_URL%/}/${url#/}"
  [[ "$url" == https://* ]] || _tb_chart_unsigned "the ${TRACEBLOC_CHART_NAME} chart ${ver} is listed at ${url}, not an https URL."
  tgz="$dir/${TRACEBLOC_CHART_NAME}-${ver}.tgz"
  _tb_chart_get "$url" "$tgz" || _tb_chart_unreachable "$url" "$_TB_CHART_HTTP"
  if ! _tb_chart_get "${url}.bundle" "${tgz}.bundle"; then
    [[ "$_TB_CHART_HTTP" != 404 ]] || _tb_chart_unsigned "its release attaches no ${url##*/}.bundle (404)."
    _tb_chart_unreachable "${url}.bundle" "$_TB_CHART_HTTP"
  fi
  _tb_chart_cosign "$dir"
  # TUF_ROOT inside the scratch folder, as install.sh's _cosign keeps it: nothing of the
  # user's ~/.sigstore is read or written, and it goes when the run ends.
  local init_rc
  for try in 1 2 3; do
    init_rc=0
    _bounded 60 env TUF_ROOT="$dir/sigstore-root" "$_TB_COSIGN" initialize >"$dir/initialize.out" 2>&1 || init_rc=$?
    cat "$dir/initialize.out" >>"${LOG_FILE:-/dev/null}" 2>/dev/null || true
    [[ "$init_rc" != 0 ]] || break
    # 125-127: the shell or timeout(1) could not run cosign at all, so retrying and blaming Sigstore's host is wrong.
    case "$init_rc" in 125|126|127)
      error_said "Couldn't run the signature check (cosign exit ${init_rc})" "The chart check could not run cosign ${TB_COSIGN_VERSION} (exit ${init_rc})." ;; esac
    [[ "$try" != 3 ]] || _tb_chart_unreachable "https://${TB_SIGSTORE_TUF_HOST}/" 000
    sleep $(( try * 5 ))
  done
  TUF_ROOT="$dir/sigstore-root" "$_TB_COSIGN" verify-blob \
      --bundle "${tgz}.bundle" \
      --certificate-identity-regexp "$TB_CHART_SIGNER_RE" \
      --certificate-oidc-issuer "$TB_CHART_SIGNER_ISSUER" \
      --offline \
      "$tgz" >>"${LOG_FILE:-/dev/null}" 2>&1 \
    || _tb_chart_unsigned "${url##*/} does not verify against ${url##*/}.bundle as ${TB_CHART_SIGNER_RE}."
  tb_live_done
  log "Chart check: ${url##*/} is signed by tracebloc's release workflow; installing that file."
  TB_CHART_VERIFIED="$tgz"
}

# _resolve_chart_ref — resolve the chart reference (local dev path, the chart
# verify_client_chart checked, or under TRACEBLOC_ALLOW_UNVERIFIED=1 the remote repo)
# and set `chart_ref` in the caller's scope (bash dynamic scope). Extracted so a
# fresh install and an adopt reconcile resolve it identically. Logging is a side
# effect only — never command-substitute this (that would capture the log lines).
_resolve_chart_ref() {
  if [[ -n "${TRACEBLOC_CHART_PATH:-}" ]]; then
    [[ -d "$TRACEBLOC_CHART_PATH" ]] || error "TRACEBLOC_CHART_PATH not found: $TRACEBLOC_CHART_PATH"
    chart_ref="$TRACEBLOC_CHART_PATH"
    info "Dev mode: using local chart at $chart_ref"
    log "Using local chart: $chart_ref"
    return 0
  fi
  # main() checks the chart in step a; a caller that did not, or a host that had no curl
  # then, gets the same check here, with nothing skipped.
  verify_client_chart
  if [[ -n "$TB_CHART_VERIFIED" ]]; then
    chart_ref="$TB_CHART_VERIFIED"
    log "Using the checked chart: $chart_ref"
  else
    # Capture-then-match: `helm repo list | grep -q` lets grep
    # close the pipe on its first hit, helm takes SIGPIPE and pipefail makes it
    # 141 — which the `if !` reads as "repo absent" and re-runs `helm repo add`
    # on the next line. That line is unguarded, and `helm repo add` fails when
    # the name already exists with a different URL, so the misbranch escalates
    # into an aborted install under `set -e`.
    local _helm_repos
    _helm_repos="$(helm repo list 2>/dev/null || true)"
    if ! grep -q "^${TRACEBLOC_HELM_REPO_NAME}[[:space:]]" <<<"$_helm_repos"; then
      log "Adding Helm repo: $TRACEBLOC_HELM_REPO_URL"
      helm repo add "$TRACEBLOC_HELM_REPO_NAME" "$TRACEBLOC_HELM_REPO_URL" >> "${LOG_FILE:-/dev/null}" 2>&1
    fi
    log "Updating Helm repos..."
    helm repo update >> "${LOG_FILE:-/dev/null}" 2>&1
    chart_ref="$TRACEBLOC_HELM_REPO_NAME/$TRACEBLOC_CHART_NAME"
  fi
}
