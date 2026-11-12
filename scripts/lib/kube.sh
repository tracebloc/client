#!/usr/bin/env bash
# =============================================================================
#  kube.sh — kube and Helm helpers: the dashboard and credential file, chart
#  version, the client's workloads and resource monitor read from the cluster,
#  the namespace and hostpath root handed on, the wired GPU, and the kube context
#  kubectl and helm are shown with. Sourced by install-k8s.sh.
# =============================================================================

# The DASHBOARD for this environment — where a human goes to create a client,
# read their credentials, or see whether it came online.
#
# Bugbot caught that this still hardcoded production at ten sites while
# `_backend_url` was correctly env-aware — so a `TRACEBLOC_ENV=dev` install on Linux
# or macOS still sent the operator to ai.tracebloc.io for credentials `dev-api`
# then rejects. (The retired PowerShell core had been fixed first.)
#
# IT LIVES HERE, NOT IN install-client-helm.sh, and that placement is the whole
# point. It was defined in install-client-helm.sh and
# CALLED from summary.sh — sibling libraries where neither sources the other — so
# summary.sh silently depended on a load order nothing enforced. Standalone (which
# is exactly what summary.bats does) the four call sites rendered an EMPTY link:
# `See it on your dashboard:` followed by nothing. That is WORSE than the bug
# being fixed, because a wrong link a reader can recover from and a missing one
# they cannot. settings.sh is sourced first by install-k8s.sh AND by the bats
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
# whether it is connected. It was "clients" until the Clients page retired;
# /clients now only redirects there.
_dashboard_url() {
  local path="${1-secure-environment}" base
  # Bare call: tb_client_env reads the ambient TRACEBLOC_ENV, and an
  # unset/unrecognised result lands in the *) branch below the same way an
  # explicit "prod" would.
  case "$(tb_client_env)" in
    dev) base='https://dev.tracebloc.io' ;;
    stg) base='https://stg.tracebloc.io' ;;
    *)   base='https://ai.tracebloc.io' ;;
  esac
  if [[ -n "$path" ]]; then printf '%s/%s' "$base" "$path"; else printf '%s' "$base"; fi
}

# _credential_file_cmd / _credential_file_load_cmd — where a secure environment's
# Client ID and password come from, for every line that tells someone. The
# Clients page that showed them is retired, and My Secure
# Environment shows neither. An interactive install needs no pair at all:
# provision_client signs in through the browser. An unattended one creates the
# pair on a machine signed in to tracebloc, which writes it to tb.env, then loads
# that file in the shell it installs from (docs: environment-setup/setup-guide).
# Here, not in install-client-helm.sh, for the reason `_dashboard_url` is: the
# summary's bad_creds outcome prints it too, and summary.sh sources neither
# sibling. common.bats holds every bash lib to spelling the commands only here.
_credential_file_cmd()      { printf '%s' 'tracebloc client create --no-cluster --yes --credential-file tb.env'; }
_credential_file_load_cmd() { printf '%s' 'set -a; . ./tb.env; set +a'; }

# _version_lt A B — true when dotted-numeric A < B. Pure and self-contained: no
# `sort -V` (BSD sort predates it, and this must behave the same on macOS) and no
# jq. Missing or non-numeric components read as 0, so "0.10" < "0.10.1" and a
# pre-release suffix ("0.10.0-rc.1") compares as its base version.
#
# Lives here rather than in assess.sh because k3s.sh and
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
  local ns="${1:-${namespace:-tracebloc}}"
  has helm || return 0
  # Trailing `|| true`: when no client-* release exists, `grep` exits 1 and, under
  # `set -o pipefail`, the pipeline (this function's last command) returns 1 —
  # which would abort callers that assign it under `set -e` (e.g. diagnose.sh).
  # The version (or empty) has already been emitted to stdout regardless.
  helm list -n "$ns" 2>/dev/null | grep -oE 'client-[0-9][^[:space:]]*' | head -1 | sed 's/^client-//' || true
}

# THE CLIENT'S CORE WORKLOADS, READ FROM THE CLUSTER, NEVER BUILT FROM A NAME
# . These three Deployments are the set whose readiness DEFINES
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
_TB_CLIENT_WORKLOAD_ROLES="mysql-client=mysql-client jobs-manager=manager egress-gate=egress-gate"

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
# jobs-manager, egress-gate). RELEASE defaults to NS: the installer names the
# release after the namespace (scripts/tests/release-name-equals-namespace.sh).
# ONE bounded read (TIMEOUT, default 10s); a failed or unanswered read returns 1,
# the same as a missing role. custom-columns rather than jsonpath: the retired
# PowerShell core ran the same argument vector, and Windows PowerShell 5.1
# mangles an embedded `"` in a native argument.
_client_workloads() {
  local ns="${1:-${namespace:-default}}" timeout="${2:-10s}" rel="${3:-}" rows
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
# . --diagnose used to fetch
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
  local ns="${1:-${namespace:-default}}" timeout="${2:-10s}" rel="${3:-}" rows
  [[ -n "$rel" ]] || rel="$ns"
  rows="$(kubectl get daemonset -A -l "app.kubernetes.io/instance=${rel}" \
            -o 'custom-columns=RELNS:.metadata.annotations.meta\.helm\.sh/release-namespace,NS:.metadata.namespace,NAME:.metadata.name,CONTAINERS:.spec.template.spec.containers[*].name' \
            --no-headers --request-timeout="$timeout" 2>/dev/null)" || return 1
  _resource_monitor_from_rows "$rows" "$ns"
}

# tb_export_namespace — export the decided secure-environment name as
# TRACEBLOC_NAMESPACE alone; namespace is this shell's own, never exported. An empty
# namespace exports an empty canonical, which every reader treats as unset.
tb_export_namespace() {
  TRACEBLOC_NAMESPACE="${namespace:-}"
  export TRACEBLOC_NAMESPACE
}

# _hostpath_root -- the host directory a native k3s hostpath install's PVs sit under:
# the root an installed release keeps (TB_HOSTPATH_KEPT, _native_k3s_release_storage),
# else host_data_dir. The values file (_hostpath_paths_block) and the
# summary both read it, so they name the same directory.
_hostpath_root() {
  if [[ "${TB_HOSTPATH_KEPT:-}" == 1 ]]; then printf '%s' "${TB_HOSTPATH_ROOT:-}"; else printf '%s' "${host_data_dir:-}"; fi
}

# True when an NVIDIA GPU has been WIRED INTO THIS CLUSTER — not merely detected.
# TRACEBLOC_GPU_WIRED becomes 1 only in native k3s's step c, once k3s's own containerd
# has registered the NVIDIA runtime (k3s-gpu.sh _native_k3s_gpu_wire, slim client 1.1i).
# So this is the one honest gate for "should we request a GPU for jobs". Requesting nvidia.com/gpu on a
# node that advertises 0 GPUs strands every job Pending, so the GPU
# chart values (install-client-helm.sh) ride this, not bare GPU_VENDOR detection.
# Wired means exactly GPU_VENDOR=nvidia and TRACEBLOC_GPU_WIRED=1; any other value of
# either is "not wired". set -u safe: a unit test that sources only a single lib
# may not have TRACEBLOC_GPU_WIRED, so it defaults here.
_gpu_wired() {
  [[ "${GPU_VENDOR:-}" == "nvidia" && "${TRACEBLOC_GPU_WIRED:-0}" == "1" ]]
}

# True when detect_gpu's floor verdict skips the GPU: below-compute (the card is too
# old for the images), below-hard-floor (the driver is older than the CUDA 13 minimum
# tracebloc's GPU images need) or unreadable (cannot tell). The GPU
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
# own containerd registered and step c's gate asked for (k3s-gpu.sh TB_K3S_GPU_RUNTIME;
# k3s creates the RuntimeClass of the same name), so the two can never disagree.
_gpu_runtime_class() {
  printf '%s' "${TB_K3S_GPU_RUNTIME:-}"
}

# _tb_kube_context -- the kube context this run added to the user's kubeconfig, if any.
_tb_kube_context() { printf '%s' "${TRACEBLOC_KUBE_CONTEXT:-}"; }
# tb_kubectl_shown, tb_helm_shown -- how a kubectl or helm command printed for the
# user starts: naming tracebloc's context once the run has added one, since the
# install leaves the user's current context on whatever cluster they chose.
tb_kubectl_shown() {
  local ctx; ctx="$(_tb_kube_context)"
  if [[ -n "$ctx" ]]; then printf 'kubectl --context %s' "$ctx"; else printf 'kubectl'; fi
}
tb_helm_shown() {
  local ctx; ctx="$(_tb_kube_context)"
  if [[ -n "$ctx" ]]; then printf 'helm --kube-context %s' "$ctx"; else printf 'helm'; fi
}
# tb_kube_set_namespace NS -- the context kubectl and the CLI read defaults to NS:
# tracebloc's, by name, once the run added one; with none, the current context, the
# cluster the user chose. Best-effort: a failure never aborts the install.
tb_kube_set_namespace() {
  local ctx; ctx="$(_tb_kube_context)"
  if [[ -n "$ctx" ]]; then
    kubectl config set-context "$ctx" --namespace "$1" >/dev/null 2>&1 || true
  else
    kubectl config set-context --current --namespace "$1" >/dev/null 2>&1 || true
  fi
}
