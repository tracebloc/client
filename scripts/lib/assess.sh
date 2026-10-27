#!/usr/bin/env bash
# =============================================================================
#  assess.sh — installer "stop-and-check" gate.
#
#  A re-run of the installer on a machine that is ALREADY set up says what it
#  found before the normal flow reconciles it. This module inspects native k3s
#  READ-ONLY and classifies it; main() then runs the normal flow, which on k3s
#  moves the node forward on every re-run (RFC-0175 D4/D11).
#
#  NON-MUTATING. It must never start the cluster, run helm, mint a credential, or
#  write anything but the context file _assess_classify_k3s names and removes.
#  Every probe is read-only (`systemctl is-active k3s`, `helm list`/`get values`,
#  `kubectl get`) and BOUNDED (short timeouts) so it can't hang, and it is NEVER
#  fatal. On ANY probe failure or uncertainty it degrades toward "run the normal
#  flow" — never toward a false "healthy", which must be CERTAIN: k3s running AND
#  a tracebloc release present AND the client's core workloads Ready AND the CLI
#  present. Anything less is degraded (partial) or fresh (nothing here yet).
#
#  Sets INSTALL_STATE (+ INSTALL_STATE_REASON, a short machine-readable tag of
#  what is off):
#    fresh    — no tracebloc k3s, or a k3s with no tracebloc release.
#    healthy  — all four signals above true. The normal flow still runs.
#    degraded — a partial state (k3s stopped, workload not Ready, CLI missing,
#               or any other partial state).
#               cli-behind-latest is the ONE degraded reason where the
#               environment is fully healthy: it fires ONLY under an explicit
#               `tracebloc upgrade` (TB_UPGRADE_CLI) when the CLI is above the
#               floor but behind the latest release (backend#2253).
# =============================================================================

# --force / --reinstall (or TRACEBLOC_FORCE_REINSTALL=1) bypasses the gate and
# runs the full flow. Defaulted here so the gate is safe to consult even if the
# arg scan never set it; main()'s arg parsing flips it to 1 on the flag.
# Settings naming (backend#3846): TRACEBLOC_FORCE_REINSTALL is the canonical and
# is read FIRST; TB_FORCE_REINSTALL is the legacy hand-off name (remove_by
# 2026-12-31), which the bootstrap (install.sh) now exports beside the canonical.
TB_FORCE_REINSTALL="${TRACEBLOC_FORCE_REINSTALL:-${TB_FORCE_REINSTALL:-0}}"

# Bound on the readiness probe's API call — short so a stopped/unreachable API
# can never make the gate hang. Overridable for tests.
: "${TB_ASSESS_KUBECTL_TIMEOUT:=5s}"

# _assess_workload_ready NS — are ALL the client's core workloads Ready in
# namespace NS? "Ready" MUST match the installer's OWN definition, so this
# iterates the SAME deployment set as wait_for_client_ready (summary.sh) via the
# shared _client_workloads — mysql-client + jobs-manager + requests-proxy, READ
# from the release rather than rebuilt from the namespace (backend#2888), so an
# overridden release is judged on its real Deployments. A machine with
# jobs-manager up but requests-proxy (training egress) or mysql-client down is
# NOT healthy, and must reconcile rather than be told "already set up".
# Read-only + bounded via kubectl --request-timeout, so a stopped/unreachable API
# returns quickly instead of hanging. A Deployment is Ready when it reports >=1
# readyReplicas; a role that cannot be resolved, or ANY one missing / erroring /
# zero => not ready (return 1), which degrades toward the normal flow.
_assess_workload_ready() {
  local ns="$1" rows role d ready
  [[ -n "$ns" ]] || return 1
  has kubectl || return 1
  rows="$(_client_workloads "$ns" "$TB_ASSESS_KUBECTL_TIMEOUT")" || return 1
  while read -r role d; do
    [[ -n "$d" ]] || continue
    ready="$(kubectl get deployment "$d" -n "$ns" \
               --request-timeout="$TB_ASSESS_KUBECTL_TIMEOUT" \
               -o jsonpath='{.status.readyReplicas}' </dev/null 2>/dev/null)" || return 1
    [[ "$ready" =~ ^[0-9]+$ ]] && [[ "$ready" -ge 1 ]] || return 1
  done <<<"$rows"
  return 0
}

# _assess_cli_bin — the tracebloc CLI to interrogate, or non-zero when there is
# none. Counts a binary in ~/.local/bin (where the CLI installer drops it when
# /usr/local/bin isn't writable) even if THIS shell's PATH predates that dir —
# the same place provision.sh / install-cli.sh resolve it.
_assess_cli_bin() {
  has tracebloc && { printf 'tracebloc'; return 0; }
  if [[ -x "${HOME}/.local/bin/tracebloc" ]]; then
    printf '%s' "${HOME}/.local/bin/tracebloc"
    return 0
  fi
  return 1
}

# _assess_cli_present — is the tracebloc CLI available at all?
_assess_cli_present() {
  _assess_cli_bin >/dev/null
}

# _version_lt lives in common.sh (backend#2422): other libs compare versions too,
# and assess.sh is sourced CONDITIONALLY by
# install-k8s.sh (`[[ -f ]]`, for stale checkouts) while common.sh is not. A
# second copy here would be the restated-rule defect, so there is exactly one.
# assess.sh's callers get it because install-k8s.sh sources common.sh first and
# the bats helper's `load_lib` chains common.sh.

# _assess_cli_outdated — is the installed CLI below the floor the installer will
# actively repair? (client#707)
#
# The floor is 0.10.63, the platform's own CLI floor (backend#4959). It was
# 0.10.0, the release where the CLI gained its own update nudge: at or above it
# a user can keep themselves current; below it NOTHING on the machine can tell
# them they are behind — the cluster auto-upgrades hourly around a host binary
# that never moves. A field machine sat on v0.5.1 for five weeks that way.
#
# It moved to 0.10.63 with the chart release that stops writing the legacy
# credential Secret keys: a CLI below 0.10.63 reads the client id only from
# CLIENT_ID, so it can no longer find the client this chart installs, and the
# platform refuses it (426 upgrade_required). This installer drives the CLI to
# provision the client, so it has to repair it to that floor BEFORE it does.
# Raise it again only with the platform's floor (release-train releases/floors.yml).
#
# It is a FLOOR, not a "must be latest": the installer repairs users up to the
# point where the CLI works with this chart and maintains itself, and then stops
# caring. That keeps this free (no network call on every run).
: "${TB_CLI_MIN_VERSION:=0.10.63}"

# _assess_cli_version BIN — the version BIN reports, bare: "tracebloc 0.10.5
# (darwin/arm64)" -> "0.10.5". Whatever the first line holds there, unchecked;
# empty when BIN reports nothing.
_assess_cli_version() {
  local ver
  # No pipe: `tracebloc version | head -1` would let head close the pipe first,
  # and pipefail turns that into a 141 the caller never asked for (backend#1778).
  ver="$("$1" version 2>/dev/null || true)"
  ver="${ver%%$'\n'*}"                     # first line
  ver="${ver#* }"; ver="${ver%% *}"        # "tracebloc 0.10.5 (darwin/arm64)" -> "0.10.5"
  printf '%s' "${ver#v}"
}

_assess_cli_outdated() {
  local bin ver
  bin="$(_assess_cli_bin)" || return 1     # absent — cli-missing already covers it
  ver="$(_assess_cli_version "$bin")"
  # FAIL OPEN on anything unparseable. A version we cannot read is not evidence
  # of staleness, and treating it as outdated would reinstall the CLI on every
  # single run — worse than the staleness this exists to fix.
  [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  _version_lt "$ver" "$TB_CLI_MIN_VERSION"
}

# _assess_cli_behind_latest — for an EXPLICIT `tracebloc upgrade` only, is the
# installed CLI behind the LATEST release (as opposed to below the mandatory-
# reinstall floor)? This is the gap backend#2253 closed: the floor above stopped
# at 0.10.0 then, but the CLI's own update nudge fires against latest, so a CLI at e.g.
# 0.10.5 with latest 0.10.8 was nagged on every command while `tracebloc upgrade`
# — which re-runs this installer — found the machine "healthy" and changed
# nothing. The nag named a command that could not carry it out.
#
# GATED on TB_UPGRADE_CLI so it is INERT on every ordinary installer run. That
# matters twice over: it keeps this classifier free (no "what is latest?" lookup
# on a normal run — the property _assess_cli_outdated's floor was chosen to
# preserve), and it means a routine re-run is never reclassified by it. The
# comparison itself does NO network: `tracebloc upgrade` already resolved latest
# and passed it as TB_CLI_LATEST, so this is a pure version compare.
#
# Fail SAFE toward updating: under an explicit upgrade an unknown/unparseable
# latest (a copy-pasted manual retry carries the flag but not the version) or an
# unreadable installed version means "we cannot prove you are current" -> update,
# which is exactly what the user asked for. Only a latest we can read AND that the
# installed CLI already meets returns "not behind".
_assess_cli_behind_latest() {
  # TB_UPGRADE_CLI / TB_CLI_LATEST are read FIRST, their TRACEBLOC_ spellings
  # only when the TB_ one is unset or blank. Every released CLI sets the TB_
  # names and older CLIs set nothing else, so what the CLI set must outrank a
  # TRACEBLOC_ value left in the user's shell.
  [[ "${TB_UPGRADE_CLI:-${TRACEBLOC_UPGRADE_CLI:-0}}" == 1 ]] || return 1
  local bin ver latest
  bin="$(_assess_cli_bin)" || return 1     # absent — cli-missing already covers it
  ver="$("$bin" version 2>/dev/null || true)"
  ver="${ver%%$'\n'*}"                     # first line
  ver="${ver#* }"; ver="${ver%% *}"        # "tracebloc 0.10.5 (darwin/arm64)" -> "0.10.5"
  ver="${ver#v}"
  latest="${TB_CLI_LATEST:-${TRACEBLOC_CLI_LATEST:-}}"; latest="${latest#v}"
  # Can't prove current (missing/unparseable latest, or unreadable version) -> update.
  [[ "$latest" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 0
  [[ "$ver"    =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 0
  _version_lt "$ver" "$latest"
}

# _assess_release_pending NS — true when a release in NS is wedged (pending-* or
# uninstalling: a killed helm op, #554). Names both states so it doesn't depend on
# the pinned helm's default listing. `helm list -q` is jq-free; bounded per the
# installer's never-hang contract.
_assess_release_pending() {
  local _ns="$1" _out _rc=0
  [[ -n "$_ns" ]] || return 1
  _out="$(_bounded 15 helm list -n "$_ns" --pending --uninstalling -q 2>/dev/null)" || _rc=$?
  # A failed/timed-out probe is uncertainty, not "no wedge" — degrade rather than
  # let the caller fast-path to healthy (this module never fails open to healthy).
  [[ "$_rc" -ne 0 ]] && return 0
  [[ -n "$_out" ]]
}

# _assess_release_client_env REL NS — echo the stage (dev|stg|prod) the release
# was installed for: its stored env.TRACEBLOC_ENV, else env.CLIENT_ENV, else prod,
# reduced through tb_client_env as the chart's tracebloc.clientEnv does. Returns 1
# when the values can't be read. Read-only and bounded.
_assess_release_client_env() {
  local rel="$1" ns="$2" vals raw
  vals="$(_bounded "${TB_HELM_VALUES_TIMEOUT:-20}" helm get values "$rel" -n "$ns" 2>/dev/null)" || return 1
  raw="$(awk '
    /^[^[:space:]#]/ { in_env = ($0 ~ /^env:/); next }
    in_env && /^[[:space:]]+(TRACEBLOC_ENV|CLIENT_ENV):/ {
      k=$1; sub(/:$/, "", k); v=$0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/["\047[:space:]]/, "", v)
      if (v != "") val[k] = v
    }
    END { print (val["TRACEBLOC_ENV"] != "" ? val["TRACEBLOC_ENV"] : val["CLIENT_ENV"]) }' <<<"$vals")"
  raw="$(tb_client_env "${raw:-prod}")"
  printf '%s' "${raw:-prod}"
}

# _assess_credential_rejected NS — true only when tracebloc DEFINITELY refuses the
# machine credential in this release's Secret (verify_credentials: invalid or
# inactive). Read-only; any read that doesn't answer is "not rejected".
#
# `unverified` (unreachable, throttled, a TLS failure) is deliberately NOT a
# rejection: a credential is never rotated on a guess. Running this before
# wire_ca_trust does not change that answer, because wire_ca_trust never wires
# curl's trust (curl reads the user's CURL_CA_BUNDLE itself, see cluster.sh).
#
# verify_credentials asks the backend of THIS run's stage (the shell's
# TRACEBLOC_ENV/CLIENT_ENV, default prod), and a `--reissue` would mint against
# that same stage. So the probe only judges a release installed for that stage: a
# dev or staging client re-checked from a shell without its env would read
# `invalid` on prod and have a working credential rotated.
_assess_credential_rejected() {
  local ns="$1" rel id pw verdict rel_env run_env
  rel="${INSTALLED_CLIENT_RELEASE:-$ns}"
  declare -F verify_credentials >/dev/null 2>&1 || return 1
  declare -F _client_password_from_secret >/dev/null 2>&1 || return 1
  rel_env="$(_assess_release_client_env "$rel" "$ns")" || return 1
  run_env="$(tb_client_env)"; run_env="${run_env:-prod}"
  if [[ "$rel_env" != "$run_env" ]]; then
    log "assess: ${ns} is a ${rel_env} client but this run targets ${run_env}; not checking its credential."
    return 1
  fi
  id="$(_client_id_from_secret "$rel" "$ns")"
  pw="$(_client_password_from_secret "$rel" "$ns")" || pw=""   # rc 2 = cannot tell: not judged
  [[ -n "$id" && -n "$pw" ]] || return 1
  verdict="$(verify_credentials "$id" "$pw")"
  log "assess: stored credential for ${ns}: ${verdict}"
  [[ "$verdict" == invalid || "$verdict" == inactive ]]
}

# _assess_gpu_request_unsupported NS — true when the release in NS requests a GPU this
# installer no longer sets up (client-dev#1697, #1698): amd.com/gpu (there is no ROCm
# training image), or nvidia.com/gpu on a Linux machine that is not x86_64 (the GPU
# images are linux/amd64 only). Such a release was installed before the fix, so the
# caller degrades it, and the normal flow's step e writes this run's CPU-only
# GPU_REQUESTS / GPU_LIMITS.
# Values that cannot be read are NOT a reason to reinstall a healthy machine: false.
# Read-only and bounded. The release is named after its namespace.
_assess_gpu_request_unsupported() {
  local _ns="$1" _vals _re='^[[:space:]]*(TRACEBLOC_)?GPU_(REQUESTS|LIMITS):[[:space:]]*"?'
  [[ -n "$_ns" ]] || return 1
  _vals="$(_bounded "${TB_HELM_VALUES_TIMEOUT:-20}" helm get values "$_ns" -n "$_ns" 2>/dev/null)" || return 1
  grep -Eq "${_re}amd\.com/gpu" <<<"$_vals" && return 0
  if [[ "${OS:-}" == Linux && "${ARCH:-}" != x86_64 && "${ARCH:-}" != amd64 ]]; then
    grep -Eq "${_re}nvidia\.com/gpu" <<<"$_vals" && return 0
  fi
  return 1
}

# _assess_classify_release — the reads once k3s runs: the tracebloc release, a wedged helm op, the credential, the workloads, the
# CLI and the GPU request, through helm and kubectl on the current context, which
# _assess_classify_k3s names. Sets INSTALL_STATE (+ INSTALL_STATE_REASON),
# from fresh/cluster-no-release to healthy.
_assess_classify_release() {
  # Cluster is running (live API). Is a tracebloc release installed on it? Reuse
  # the shared jq-free probe (sets INSTALLED_CLIENT_NS) so this can never disagree
  # with the Helm-step / #303 ownership guards on "what runs here". A running
  # cluster with no release is still a first-time client setup.
  local ns=""
  if declare -F detect_installed_client >/dev/null 2>&1; then
    detect_installed_client
    ns="$INSTALLED_CLIENT_NS"
  fi
  if [[ -z "$ns" ]]; then
    INSTALL_STATE="fresh"; INSTALL_STATE_REASON="cluster-no-release"
    return 0
  fi

  # A pending-* wedge (killed helm op, #554) usually keeps its prior revision Ready,
  # so it would fast-path to healthy and skip recovery. Degrade so the normal flow
  # runs and _recover_pending_helm_release clears it.
  if _assess_release_pending "$ns"; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="pending-wedge"
    return 0
  fi

  # Does tracebloc still accept the credential this client runs with? A revoked one
  # looks healthy here (or crash-loops jobs-manager, which reads as
  # workload-not-ready) while the dashboard shows the client offline, and neither
  # repair path would ever renew it (backend#5365). Checked BEFORE readiness for
  # that reason. Only a definite rejection counts: an unreadable Secret or an
  # unreachable backend is not a reason to rotate a credential.
  if _assess_credential_rejected "$ns"; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="credential-rejected"
    return 0
  fi

  # Cluster running + release present -> healthy or degraded. Require CERTAINTY on
  # every remaining signal for "healthy"; anything less degrades to the normal
  # flow, which reconciles the specific layer that is off. The readiness probe
  # talks to a live API (and is bounded regardless). ANY of the client's core
  # workloads not Ready => degraded.
  if ! _assess_workload_ready "$ns"; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="workload-not-ready"
    return 0
  fi

  # The CLI reasons only where the run installs the CLI. In a WSL run the CLI is the
  # Windows host's and step b installs none (install-k8s.sh asks the same
  # tb_wsl_phase), so cli-missing, cli-outdated and cli-behind-latest cannot occur
  # in tracebloc's distro: the Windows installer keeps its own CLI current.
  local cli_here=1
  [[ -z "$(tb_wsl_phase 2>/dev/null)" ]] || cli_here=0

  # Env is up and Ready, but the CLI is missing => degraded (the normal flow
  # reinstalls the CLI).
  if [[ "$cli_here" == 1 ]] && ! _assess_cli_present; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="cli-missing"
    return 0
  fi

  # Present, but too old to keep itself current (client#707). Without this the
  # healthy fast-path pins a user to whatever CLI they first installed, forever
  # and silently — the ONE thing on the machine that no auto-upgrade reaches.
  if [[ "$cli_here" == 1 ]] && _assess_cli_outdated; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="cli-outdated"
    return 0
  fi

  # A release that requests a GPU no tracebloc image can use (client-dev#1697, #1698):
  # the normal flow re-stamps its GPU request to CPU-only. Ahead of cli-behind-latest, so
  # an explicit `tracebloc upgrade` says it switches the request to CPU mode, where
  # cli-behind-latest says nothing.
  if _assess_gpu_request_unsupported "$ns"; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="gpu-unsupported"
    return 0
  fi

  # Above the floor, but an explicit `tracebloc upgrade` and behind the latest
  # release (backend#2253). A DISTINCT reason from cli-outdated: the gate returns on
  # it without the degraded lines, and main() runs the full install, whose step b
  # updates the CLI. Ordered AFTER the floor check so a below-floor CLI stays
  # cli-outdated (a mandatory full reinstall), and inert on ordinary runs because
  # _assess_cli_behind_latest gates itself on TB_UPGRADE_CLI.
  if [[ "$cli_here" == 1 ]] && _assess_cli_behind_latest; then
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="cli-behind-latest"
    return 0
  fi

  INSTALL_STATE="healthy"; INSTALL_STATE_REASON="ns:${ns}"
  return 0
}

# _assess_classify_k3s — the classification on native k3s (client-dev#1926), on
# Linux and in tracebloc's WSL distro, in the INSTALL_STATE / INSTALL_STATE_REASON
# vocabulary main() handles (the degraded copy, provision.sh's --reissue on
# credential-rejected); a healthy k3s goes on to the normal flow
# (assess_existing_install). k3s's own service is read first:
#   tracebloc's k3s files are not here     fresh/no-cluster (a k3s someone else set
#                                          up among them: the create path refuses it)
#   systemd says k3s is stopped            degraded/cluster-stopped (the create
#                                          path's _native_k3s_ensure_running starts it)
#   systemd gives no state, or the API     degraded/cluster-indeterminate
#   does not answer on the k3s context
# Below that are the release reads (_assess_classify_release). In the
# distro the cluster run reads the same, but for the CLI: the CLI reasons cannot
# occur there (_assess_classify_release), and the client run is not assessed at all
# (assess_existing_install).
#
# k3s runs its own containerd inside the k3s service, so there is no runtime apart
# from the cluster to read: a runtime that is down is a k3s that is stopped.
#
# BY NAME, as _native_k3s_release_storage's early read is: before the create path the
# user's current context can be any cluster they work with, and a release read there
# is that cluster's (its credential judged rejected rotates this machine's). The
# release reads ask the current context, so the context is named the way kubeconfig allows:
# the first KUBECONFIG file that sets current-context wins it, and the user's
# kubeconfig after it supplies the cluster and the credential. That file holds one
# context name and nothing secret, and is removed once the reads are done. KUBECONFIG
# and HELM_KUBECONTEXT are set for the reads alone (bash restores a variable assigned
# on a function call when the function returns), so step c's merge still finds the
# user's own. With KUBECONFIG unset, k3s's kubectl reads root's k3s.yaml, never the
# user's kubeconfig, so the merge's target is named then (_native_k3s_kubeconfig_target).
_assess_classify_k3s() {
  INSTALL_STATE="fresh"; INSTALL_STATE_REASON="no-cluster"
  _native_k3s_files_here || return 0
  local state rc=0 ctx pin
  state="$(_native_k3s_run_state)" || rc=$?
  case "$rc" in
    0) : ;;
    1) INSTALL_STATE="degraded"; INSTALL_STATE_REASON="cluster-stopped"; return 0 ;;
    *) log "assess: native k3s: 'systemctl is-active k3s' answered '${state:-nothing}', so its state is not read."
       INSTALL_STATE="degraded"; INSTALL_STATE_REASON="cluster-indeterminate"; return 0 ;;
  esac
  ctx="$(_native_k3s_context)"
  pin="$(mktemp "${TMPDIR:-/tmp}/tracebloc-assess-ctx-XXXXXX" 2>/dev/null)" || pin=""
  if [[ -z "$pin" ]] || ! printf 'apiVersion: v1\nkind: Config\ncurrent-context: %s\n' "$ctx" >"$pin"; then
    [[ -z "$pin" ]] || rm -f "$pin"
    log "assess: native k3s: no temporary file to name context ${ctx} in, so its release is not read."
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="cluster-indeterminate"; return 0
  fi
  KUBECONFIG="${pin}:${KUBECONFIG:-$(_native_k3s_kubeconfig_target)}" HELM_KUBECONTEXT="$ctx" _assess_k3s_on_context "$ctx"
  rm -f "$pin"
}

# _assess_k3s_on_context CTX — the API on context CTX (cluster.sh's _api_answers,
# bounded per request), then the release reads. Called with KUBECONFIG naming CTX
# current, by _assess_classify_k3s.
_assess_k3s_on_context() {
  if ! _api_answers "$1"; then
    log "assess: native k3s: the API did not answer on context $1 (or the kubeconfig has no such context), so its release is not read."
    INSTALL_STATE="degraded"; INSTALL_STATE_REASON="cluster-indeterminate"; return 0
  fi
  _assess_classify_release
}

# assess_existing_install — the gate. Called from main() after print_banner and
# before the roadmap / Step 1. READ-ONLY, never fatal, and it always RETURNS 0:
# fresh / degraded print a warm one-liner, healthy one log line, and main() runs
# the normal flow to set up (fresh) or reconcile (degraded, healthy).
assess_existing_install() {
  # --force / --reinstall (or the env override): skip the gate entirely.
  if [[ "${TB_FORCE_REINSTALL:-0}" == 1 ]]; then
    log "assess: --force/--reinstall set — bypassing the stop-and-check gate."
    return 0
  fi

  # The Windows installer's client run in tracebloc's WSL distro: the cluster run
  # before it assessed this machine, and this run installs the credential the
  # Windows installer handed it. Read again, the gate would repeat the cluster run's
  # verdict and its copy in the middle of that install.
  if [[ "$(tb_wsl_phase 2>/dev/null)" == "client" ]]; then
    log "assess: the WSL client run -- the cluster run assessed this machine; continuing to the install."
    return 0
  fi

  # Native k3s is read from the host (_assess_classify_k3s). The presence checks
  # that refuse (a foreign k3s among them) stay the k3s create path's. On macOS,
  # native k3s is the node in Apple's VM (mac-container.sh), with no systemd or k3s
  # files on the Mac to read: one log line, and the normal flow. main() refuses a run
  # that resolved any other substrate before this gate (tb_substrate_resolve and
  # its refusals), so such a run reads nothing here either.
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" != "k3s" ]]; then
    log "assess: substrate '${TRACEBLOC_SUBSTRATE_RESOLVED:-}' is not one the stop-and-check assessment reads; continuing to the install."
    return 0
  fi
  if [[ "${OS:-$(uname -s 2>/dev/null)}" != "Linux" ]]; then
    log "assess: native k3s on ${OS:-$(uname -s 2>/dev/null)} runs in Apple's VM, which the stop-and-check assessment does not read; continuing to the install."
    return 0
  fi
  _assess_classify_k3s
  log "assess: INSTALL_STATE=${INSTALL_STATE} reason=${INSTALL_STATE_REASON:-}"

  # backend#2253: an explicit `tracebloc upgrade` on a box that is healthy on
  # every axis EXCEPT that its CLI is behind latest. Do NOT run the degraded
  # ceremony below: RETURN, and main() runs the full install, whose step b updates
  # the CLI and whose step c moves the node forward. Kept out of the case switch on
  # purpose: this file stays a read-only classifier.
  if [[ "$INSTALL_STATE" == "degraded" && "${INSTALL_STATE_REASON:-}" == "cli-behind-latest" ]]; then
    return 0
  fi

  case "$INSTALL_STATE" in
    healthy)
      # NATIVE K3S DOES NOT HAND OFF. RFC-0175 D4 and D11: every installer re-run on
      # k3s moves the node forward (the binary upgraded in place, its files rewritten
      # and k3s restarted when they changed), and that is step c's work. So a healthy
      # k3s goes on to the normal flow, as fresh/cluster-no-release does: no copy, one
      # log line.
      log "assess: native k3s is healthy; continuing, so step c moves the node forward."
      return 0
      ;;
    degraded)
      echo ""
      case "$INSTALL_STATE_REASON" in
        cluster-stopped)    info "Your secure environment is stopped — starting it and finishing setup." ;;
        workload-not-ready) info "Your secure environment is still starting up — finishing setup." ;;
        cli-missing)        info "The tracebloc CLI isn't installed yet — setting it up." ;;
        cli-outdated)       info "Your tracebloc CLI is out of date — updating it." ;;
        pending-wedge)      info "A previous update was interrupted — recovering it and finishing setup." ;;
        # The repair is provision.sh's `client create --reissue`, which the WSL cluster
        # run never reaches: it ends at step c, and the client run, a new process, takes
        # the credential the Windows installer hands it. So that run says what it found
        # and promises no repair it does not run.
        credential-rejected)
          if [[ "$(tb_wsl_phase 2>/dev/null)" == "cluster" ]]; then
                            info "tracebloc no longer accepts this machine's credential, so it shows offline. This run sets up the cluster; the Windows installer registers this machine after it."
          else
                            info "tracebloc no longer accepts this machine's credential, so it shows offline — issuing it a new one and reconnecting."
          fi ;;
        gpu-unsupported)    info "Your secure environment asks for a GPU tracebloc's training images can't use — switching it to CPU mode." ;;
        # "COULDN'T READ" IS NOT A STATE OF THE INSTALL (client#984). Without its own arm
        # it would fall into the generic line below, which claims an environment EXISTS
        # and is partly built, about a machine nobody could read. The read that did not
        # answer is systemd's or the k3s API's (_assess_classify_k3s), so the line names
        # those and claims nothing about what follows.
        cluster-indeterminate)
                            info "Couldn't read this machine's k3s — systemd or the k3s API didn't answer. Continuing without drawing a conclusion from a read that didn't answer; setup reads it again before it acts." ;;
        *)                  info "Your secure environment is only partly set up — finishing setup." ;;
      esac
      echo ""
      return 0               # fall through to the normal flow to reconcile
      ;;
    fresh|*)
      # Only the truly-empty machine gets a first-time header; a cluster that
      # merely lacks a release proceeds without ceremony.
      if [[ "$INSTALL_STATE_REASON" == "no-cluster" ]]; then
        info "Setting up your secure environment on this machine for the first time."
        echo ""
      fi
      return 0               # today's normal flow
      ;;
  esac
}
