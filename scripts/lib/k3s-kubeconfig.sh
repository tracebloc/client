#!/usr/bin/env bash
# =============================================================================
#  k3s-kubeconfig.sh — native k3s's kubeconfig and API: the merge into the
#  operator's kubeconfig, the context pin, the wait for the API and the node, and the
#  unprivileged probe re-run resolution reads (1.1f)
#
#  LINUX ONLY. Moved out of k3s.sh; install-k8s.sh sources it right after k3s.sh and
#  k3s-firewall.sh, and both bootstraps fetch it. Every function keeps the
#  `_native_k3s_` prefix and reads k3s.sh's paths.
#  bash 3.2-safe; sourcing it has no side effects: constants and functions only.
# =============================================================================

# ── kubeconfig and the API ────────────────────────────────────────────────────

# _native_k3s_rename_kubeconfig CONTEXT -- stdin k3s.yaml, stdout the same with its
# `default` cluster, user and context, and the current-context, renamed CONTEXT. Every
# k3s names all three `default`, so a merge without the rename would collide with any
# other tool's `default` in the user's kubeconfig. Returns 1 when any `default` name is
# left, or when the current context did not become CONTEXT: a file of another shape
# is not one this can vouch for.
_native_k3s_rename_kubeconfig() {
  local ctx="$1" out
  out="$(sed -e "s/^\(  name: \)default\$/\1${ctx}/" \
             -e "s/^\(    cluster: \)default\$/\1${ctx}/" \
             -e "s/^\(    user: \)default\$/\1${ctx}/" \
             -e "s/^\(- name: \)default\$/\1${ctx}/" \
             -e "s/^\(current-context: \)default\$/\1${ctx}/")" || return 1
  if printf '%s\n' "$out" | grep -E '^([ -]*name|[ ]*cluster|[ ]*user|current-context): *default$' >/dev/null; then
    return 1
  fi
  case $'\n'"$out"$'\n' in
    *$'\n'"current-context: ${ctx}"$'\n'*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# _native_k3s_wsl_server_localhost -- stdin a renamed k3s.yaml, stdout the same with
# its server's host `localhost` in place of k3s's `127.0.0.1`. Inside tracebloc's WSL
# distro the merge writes the Windows user's own kubeconfig (the Windows installer
# hands the core that file as KUBECONFIG), and Windows reaches
# the API through WSL's localhost forwarding. Spike S-W measured that forwarding on
# `::1` only on a Windows 11 laptop (WSL 2.7.11): `127.0.0.1:6443` was refused from
# Windows while the API answered (rows 6 and 7 of that spike). On
# Server 2025 (WSL 3.0.3) `127.0.0.1` answered. `localhost`, which a client tries on
# both loopbacks, serves both hosts. k3s puts `localhost` in its serving certificate
# beside 127.0.0.1 and ::1, and inside the distro `localhost` is the distro's own
# loopback, so the core's own reads through this file keep working. Returns 1 unless
# the file held exactly one `server:` line and that line now names localhost: a file of
# another shape is not one this can vouch for.
_native_k3s_wsl_server_localhost() {
  local out
  out="$(sed -e 's#^\(    server: https://\)127\.0\.0\.1:\([0-9][0-9]*\)$#\1localhost:\2#')" || return 1
  [[ "$(printf '%s\n' "$out" | grep -c '^ *server:')" == 1 ]] || return 1
  grep -Eq '^    server: https://localhost:[0-9]+$' <<<"$out" || return 1
  printf '%s\n' "$out"
}

# _native_k3s_context -- the kubeconfig context native k3s is merged as:
# k3s-<cluster_name> (decided 2026-10-01). The cluster
# and the user entries carry the same name. One definition, read by the merge, the
# record and the API wait.
_native_k3s_context() { printf 'k3s-%s' "${cluster_name}"; }

# _native_k3s_kubeconfig_target -- the kubeconfig the merge writes: the first entry
# of KUBECONFIG, else ~/.kube/config. The run's context pin
# (_native_k3s_pin_context) goes first once the merge has run, and is never it.
_native_k3s_kubeconfig_target() {
  local target="${KUBECONFIG:-${HOME}/.kube/config}"
  if [[ -n "${TB_KUBE_CONTEXT_PIN:-}" && "${target%%:*}" == "$TB_KUBE_CONTEXT_PIN" ]]; then
    target="${target#*:}"
  fi
  printf '%s' "${target%%:*}"
}

# _native_k3s_current_context FILE KUBECTL... -- FILE's own current-context, read by
# KUBECTL (the command and its leading words, expanded by the caller: this reads no
# variable of its caller's), "" when FILE sets none or does not exist. Returns 1 when
# kubectl cannot read it, and when no KUBECTL is given.
_native_k3s_current_context() {
  local file="$1"
  shift
  (( $# > 0 )) || return 1
  [[ -e "$file" ]] || return 0
  KUBECONFIG="$file" "$@" config view -o 'jsonpath={.current-context}' 2>/dev/null
}

# _native_k3s_pin_context CTX -- every kubectl and helm this process starts from now
# on reaches CTX, and the user's kubeconfig keeps its own current-context: a file
# that holds only `current-context: CTX` goes first in KUBECONFIG (the first file
# that sets it wins), the user's after it. A HELM_KUBECONTEXT from the user's shell is
# unset, so helm reads that file as kubectl does. The file is removed when the run exits
# (tb_scratch_dir). A second call rewrites it, and puts it first again if KUBECONFIG
# was set since. Returns 1, with KUBECONFIG as it was, when the file cannot be written.
_native_k3s_pin_context() {
  local ctx="$1" dir pin="${TB_KUBE_CONTEXT_PIN:-}"
  if [[ -z "$pin" ]]; then
    tb_scratch_dir dir tracebloc-kube-context || return 1
    pin="${dir}/kubeconfig"
  fi
  printf 'apiVersion: v1\nkind: Config\ncurrent-context: %s\n' "$ctx" > "$pin" || return 1
  [[ "${KUBECONFIG:-}" == "${pin}:"* ]] \
    || export KUBECONFIG="${pin}:${KUBECONFIG:-$(_native_k3s_kubeconfig_target)}"
  TB_KUBE_CONTEXT_PIN="$pin"
  unset HELM_KUBECONTEXT
}

# _native_k3s_persist_kubeconfig TARGET -- a NEW shell reaches tracebloc's context
# too. k3s's kubectl, which /usr/local/bin/kubectl is, reads
# root's k3s.yaml whenever KUBECONFIG is unset, never TARGET, so in a fresh login
# shell `kubectl --context k3s-<name>` said the context does not exist; the
# summary's export line goes only to the log when a person is watching. One
# commented line in the user's shell rc (_tools_rc_for_shell) sets KUBECONFIG to
# TARGET when the shell has none, with k3s.yaml after it when this user can read
# it, so a bare kubectl that reached k3s's `default` context still does. Called only
# when the merge set TB_K3S_KUBECONFIG_HINT (no KUBECONFIG, not the Mac). Not in
# tracebloc's WSL distro (Windows reads TARGET), not for fish (it reads none of
# these files), and not when the rc already names KUBECONFIG (a
# prior run, or the user's own line). Best-effort: a hiccup never fails the install.
_native_k3s_persist_kubeconfig() {
  local target="$1" rc
  ! _native_k3s_on_wsl || return 0
  declare -F _tools_rc_for_shell >/dev/null || return 0
  [[ "$(basename "${SHELL:-sh}")" != fish ]] || return 0
  rc="$(_tools_rc_for_shell)"
  if [[ -f "$rc" ]] && grep -qF 'KUBECONFIG' "$rc" 2>/dev/null; then return 0; fi
  {
    printf '\n# Added by tracebloc installer: kubectl reads the kubeconfig with tracebloc'"'"'s context\n'
    # shellcheck disable=SC2016  # the rc file must get ${KUBECONFIG:-} literally, for its own shell to expand
    printf 'if [ -z "${KUBECONFIG:-}" ]; then if [ -r %s ]; then export KUBECONFIG="%s:%s"; else export KUBECONFIG="%s"; fi; fi\n' \
      "$TB_K3S_KUBECONFIG_PATH" "$target" "$TB_K3S_KUBECONFIG_PATH" "$target"
  } >> "$rc" 2>/dev/null || return 0
  log "Set KUBECONFIG=${target} for new terminals in ${rc}: there kubectl reaches the $(_native_k3s_context) context."
}

# _native_k3s_merge_kubeconfig -- add k3s's kubeconfig to the daily user's
# (_native_k3s_kubeconfig_target) as _native_k3s_context, pin that context for the
# rest of this run (_native_k3s_pin_context), and set TRACEBLOC_KUBE_CONTEXT. The
# user's current-context is theirs and stays exactly as it was: the merge is refused
# before anything is written if it would change it. The file is written by this (the
# daily user's) process, mode 0600, so the user owns it; k3s's own copy stays root's.
#
# Merged by `$TB_K3S_BIN_PATH kubectl config view --flatten` with the RENAMED file FIRST in
# KUBECONFIG: the first file wins a conflict, so a re-install's fresh credentials
# replace the previous install's. The renamed file's current-context is dropped first,
# so the user's file decides it.
#
# SRC, when given, is a k3s.yaml this user already holds, read without sudo: the macOS
# node's copy, which mac-container.sh fetches from the node. There the Mac has no k3s
# binary, so the kubectl is the one on PATH (TB_K3S_ON_MAC).
#
# KUBECONFIG is then EXPORTED with the pin first and the user's kubeconfig after it,
# for the rest of the run. Upstream links kubectl to k3s (D3), and k3s's kubectl reads
# root's k3s.yaml, never ~/.kube/config, whenever KUBECONFIG is unset and that file
# exists: on the 1.1e VM every kubectl the run made failed "permission denied" and the
# API wait ran out.
_native_k3s_merge_kubeconfig() {
  local src="${1:-}" ctx target td kc before after
  kc=("$TB_K3S_BIN_PATH" kubectl)
  [[ "${TB_K3S_ON_MAC:-}" != 1 ]] || kc=(kubectl)
  ctx="$(_native_k3s_context)"; target="$(_native_k3s_kubeconfig_target)"
  # set-u-safe: kc is seeded with the kubectl in both branches
  before="$(_native_k3s_current_context "$target" "${kc[@]}")" \
    || error "native k3s: couldn't read ${target}, so tracebloc's ${ctx} context was not added to it."
  td="$(mktemp -d "${TMPDIR:-/tmp}/tracebloc-k3s-kc-XXXXXX")" || error "native k3s: could not create a temporary directory for the kubeconfig merge."
  # Read as root (adopted: through the prepared group), written as the user: the
  # redirect stays outside the read.
  if [[ -n "$src" ]]; then
    cat "$src" > "${td}/k3s.yaml" \
      || { rm -rf "$td"; error "native k3s: couldn't read ${src}, the node's kubeconfig. It's safe to re-run this installer."; }
  else
    _native_k3s_read cat "$TB_K3S_KUBECONFIG_PATH" > "${td}/k3s.yaml" \
      || { rm -rf "$td"; error "native k3s: couldn't read ${TB_K3S_KUBECONFIG_PATH}; k3s writes it when it starts. Check 'sudo systemctl status k3s', then re-run."; }
  fi
  _native_k3s_rename_kubeconfig "$ctx" < "${td}/k3s.yaml" > "${td}/renamed.yaml" \
    || { rm -rf "$td"; error "native k3s: ${src:-$TB_K3S_KUBECONFIG_PATH} is not the shape k3s writes (one cluster, user and context, all named 'default'), so it was not merged into ${target}."; }
  # In tracebloc's WSL distro the target is the Windows user's kubeconfig, and
  # Windows reaches the API as localhost (_native_k3s_wsl_server_localhost). Linux
  # and the Mac keep k3s's 127.0.0.1.
  if _native_k3s_on_wsl; then
    _native_k3s_wsl_server_localhost < "${td}/renamed.yaml" > "${td}/hosted.yaml" \
      || { rm -rf "$td"; error "native k3s: ${src:-$TB_K3S_KUBECONFIG_PATH} does not name the API as k3s writes it (one server, https://127.0.0.1:<port>), so it was not merged into ${target}: Windows reaches the API as localhost, and this file cannot be told to."; }
    mv -f "${td}/hosted.yaml" "${td}/renamed.yaml" \
      || { rm -rf "$td"; error "native k3s: couldn't stage the kubeconfig for Windows in ${td}."; }
  fi
  sed '/^current-context:/d' "${td}/renamed.yaml" > "${td}/added.yaml" \
    || { rm -rf "$td"; error "native k3s: couldn't stage the k3s kubeconfig in ${td}."; }
  mkdir -p "$(dirname "$target")" \
    || { rm -rf "$td"; error "native k3s: couldn't create $(dirname "$target")."; }
  # set-u-safe: kc is seeded with the kubectl in both branches
  KUBECONFIG="${td}/added.yaml:${target}" "${kc[@]}" config view --flatten > "${td}/merged.yaml" \
    || { rm -rf "$td"; error "native k3s: couldn't merge the k3s kubeconfig into ${target}."; }
  # set-u-safe: kc is seeded with the kubectl in both branches
  after="$(_native_k3s_current_context "${td}/merged.yaml" "${kc[@]}")" \
    || { rm -rf "$td"; error "native k3s: couldn't read the merged kubeconfig, so ${target} was left as it was."; }
  [[ "$after" == "$before" ]] \
    || { rm -rf "$td"; error "native k3s: adding the ${ctx} context would change your current kubectl context from '${before}' to '${after}', so ${target} was left as it was."; }
  install -m 0600 "${td}/merged.yaml" "$target" \
    || { rm -rf "$td"; error "native k3s: couldn't write ${target}."; }
  rm -rf "$td"
  # The user's own shell has no KUBECONFIG either, and there k3s's kubectl reads
  # k3s.yaml (context default, no namespace), never this file: print_summary
  # prints the export line for it. Not on the macOS node: there kubectl is the one
  # step b installed, which reads this file by default.
  # shellcheck disable=SC2034  # consumed cross-file by summary.sh (print_summary)
  [[ -n "${KUBECONFIG:-}" || "${TB_K3S_ON_MAC:-}" == 1 ]] || TB_K3S_KUBECONFIG_HINT="$target"
  [[ -z "${TB_K3S_KUBECONFIG_HINT:-}" ]] || _native_k3s_persist_kubeconfig "$target"
  _native_k3s_pin_context "$ctx" \
    || error "native k3s: couldn't write the temporary file that names the ${ctx} context for the rest of this run. It's safe to re-run this installer."
  log "kubeconfig updated: added the ${ctx} context to ${target}; its current context is still '${before}'."
  # shellcheck disable=SC2034  # consumed cross-file by record.sh (tb_record_write's kube_context)
  TRACEBLOC_KUBE_CONTEXT="$ctx"
}

# The ONE TB_API_WAIT_S budget the three waits share: the wait for k3s.yaml starts
# it, and the API and node Ready waits spend what is left, so a slow k3s start never
# earns a second full budget. TWO CLOCKS, and the budget is spent when either runs
# out, as the core's deadlines are held. TB_K3S_WAITED_S counts the
# sleeps, so a stubbed sleep still reaches the deadline (noop-sleep-deadline-guard);
# TB_K3S_WAIT_T0 is the epoch second the budget started, so the time a probe itself
# takes (_api_answers: up to 5 s a request) counts too.
TB_K3S_WAITED_S=0
TB_K3S_WAIT_T0=0

# _native_k3s_budget_left BUDGET -- true while the shared budget has time left on both
# clocks. A wait that runs first, with no start recorded, starts the clock.
_native_k3s_budget_left() {
  (( TB_K3S_WAIT_T0 > 0 )) || TB_K3S_WAIT_T0="$(date +%s)"
  (( TB_K3S_WAITED_S < $1 )) && (( $(date +%s) - TB_K3S_WAIT_T0 < $1 ))
}

# _native_k3s_kubectl_on CTX ARGS... -- kubectl on this k3s: on context CTX, by name,
# as the daily user; in prepared mode (prepare-host, 1.1g) as root on k3s.yaml,
# because prepare-host never merges into the administrator's kubeconfig.
_native_k3s_kubectl_on() {
  local ctx="$1"; shift
  if [[ "${TB_K3S_PREPARED:-}" == 1 ]]; then
    tb_root env KUBECONFIG="$TB_K3S_KUBECONFIG_PATH" "$TB_K3S_BIN_PATH" kubectl "$@"
  else
    kubectl --context "$ctx" "$@"
  fi
}

# _native_k3s_api_answers CTX -- cluster.sh's _api_answers on context CTX; in
# prepared mode the same question (cluster-info, 5 s a request) asked as root.
_native_k3s_api_answers() {
  if [[ "${TB_K3S_PREPARED:-}" == 1 ]]; then
    _native_k3s_kubectl_on "$1" cluster-info --request-timeout=5s &>/dev/null
  else
    _api_answers "$1"
  fi
}

# _native_k3s_node_ready CTX NAME -- node NAME's Ready condition on context CTX, as
# STATUS|REASON|MESSAGE (STATUS True, False or Unknown), or nothing when the API does
# not say.
_native_k3s_node_ready() {
  _native_k3s_kubectl_on "$1" get node "$2" --request-timeout=5s \
    -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}|{.status.conditions[?(@.type=="Ready")].reason}|{.status.conditions[?(@.type=="Ready")].message}' \
    2>/dev/null || true
}

# _native_k3s_ready_said LAST -- the Ready condition a refused node-Ready wait read last
# (LAST: STATUS|REASON|MESSAGE, or nothing), as a sentence for the refusal
# . With it, a slow Ready, a node that never goes Ready and a k3s that
# keeps exiting no longer read the same. The macOS node's refusal says it too.
_native_k3s_ready_said() {
  local st="${1%%|*}" rest
  rest="${1#"$st"}"; rest="${rest#|}"; rest="${rest%.}"; [[ "$rest" != "|" ]] || rest=""
  if [[ -n "$st" ]]; then
    printf 'Its last Ready condition read %s%s.' "$st" "${rest:+: ${rest}}"
  else
    printf 'The API never gave its Ready condition.'
  fi
}

# _native_k3s_ready_why LAST -- why a node-Ready wait on this host's k3s was refused:
# the last Ready condition it read (_native_k3s_ready_said), and how many times systemd
# has restarted k3s (NRestarts), which tells a k3s that keeps exiting from a slow one.
_native_k3s_ready_why() {
  local n
  _native_k3s_ready_said "$1"
  n="$(_bounded 10 systemctl show k3s -p NRestarts --value 2>/dev/null)" || n=""
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    printf ' systemd has restarted k3s %s time(s) (NRestarts).' "$n"
  else
    printf " systemd did not say how many times it restarted k3s ('systemctl show k3s -p NRestarts' answered '%s')." "$n"
  fi
}

# _native_k3s_wait_for_node_ready NAME -- the install is done only when node NAME is
# Ready, asked on the k3s context by name, on the budget the two waits before it
# share. Neither install.sh's exit 0 nor `systemctl is-active k3s` says so: on cgroup
# v1 without fail-cgroupv1=false both read success while the kubelet exits every
# ~14 s, and the API answers in between (S-R2).
_native_k3s_wait_for_node_ready() {
  local name="$1" budget ctx ready last=""
  # --print: nothing ran, so there is nothing to wait for or read back.
  if tb_root_planning; then return 0; fi
  budget="$(_api_wait_budget_s)"; ctx="$(_native_k3s_context)"
  log "Waiting for node '${name}' to be Ready..."
  until ready="$(_native_k3s_node_ready "$ctx" "$name")"; [[ "${ready%%|*}" == True ]]; do
    # The last read that said something, for the refusal: an API that stops answering
    # near the deadline does not erase what the node said before.
    [[ -z "${ready%%|*}" ]] || last="$ready"
    _native_k3s_budget_left "$budget" \
      || error "Node '${name}' did not become Ready within ${budget}s. $(_native_k3s_ready_why "$last") It's safe to re-run this installer; on a slow machine, extend the wait with TRACEBLOC_API_WAIT_S=<seconds>. 'sudo journalctl -u k3s' says why the kubelet is not up."
    sleep 2
    TB_K3S_WAITED_S=$(( TB_K3S_WAITED_S + 2 ))
  done
  log "Node '${name}' is Ready."
}

# _native_k3s_wait_for_api -- wait for the API to answer on the k3s context BY NAME,
# never on the user's current context, which may be another cluster's. On
# cluster.sh's _api_answers (the one definition of "answers") and its
# _api_wait_budget_s (the TB_API_WAIT_S budget), continuing the
# count _native_k3s_wait_for_kubeconfig started.
_native_k3s_wait_for_api() {
  local budget ctx
  # --print: nothing ran, so there is nothing to wait for or read back.
  if tb_root_planning; then return 0; fi
  budget="$(_api_wait_budget_s)"; ctx="$(_native_k3s_context)"
  log "Waiting for the k3s API server to answer on context ${ctx}..."
  until _native_k3s_api_answers "$ctx"; do
    _native_k3s_budget_left "$budget" \
      || error "The k3s API server did not answer within ${budget}s. It's safe to re-run this installer; on a slow machine, extend the wait with TRACEBLOC_API_WAIT_S=<seconds>. 'sudo systemctl status k3s' and 'sudo journalctl -u k3s' say why it is not up."
    sleep 2
    TB_K3S_WAITED_S=$(( TB_K3S_WAITED_S + 2 ))
  done
  log "k3s API server is answering."
}

# ── Re-run resolution's probe (1.1f) ───────────────────────────────────────────

# _native_k3s_files_here -- tracebloc's k3s files are on this host, read with no
# privileges: tracebloc's kubelet drop-in (0644; on the host only the native path
# writes it, so a k3s without it is not tracebloc's) and k3s's uninstall script,
# which upstream's install.sh writes beside the unit. The re-run probe below and the
# stop-and-check gate (assess.sh) both ask it.
_native_k3s_files_here() {
  [[ -f "$TB_KUBELET_CONFIG_K3S_PATH" && -f "$TB_K3S_UNINSTALL_PATH" ]]
}

# _native_k3s_live_probe -- whether a tracebloc native k3s is set up on this
# machine, read with no privileges, for substrate.sh's tb_substrate_resolve. The
# marker in config.yaml is out of reach (root's, 0600), so it reads what any user
# can: tracebloc's kubelet drop-in (0644; on the host only the native path writes
# it, so a k3s without it is not tracebloc's), k3s's uninstall script, and
# systemctl. "Set up" is running OR enabled: a k3s that is crash-looping or not yet
# started reads inactive, and it comes back at the next boot either way.
# 0 = set up, 1 = not here (or installed, stopped and disabled), 2 = tracebloc's
# files are here but systemctl did not answer (cannot tell). Linux only.
_native_k3s_live_probe() {
  [[ "${OS:-$(uname -s 2>/dev/null)}" == "Linux" ]] || return 1
  _native_k3s_files_here || return 1
  local rc=0
  _bounded "${TB_PROBE_TIMEOUT:-5}" systemctl is-active --quiet k3s 2>/dev/null || rc=$?
  [[ "$rc" -eq 0 ]] && return 0
  [[ "$rc" -eq 3 || "$rc" -eq 4 ]] || return 2
  rc=0
  _bounded "${TB_PROBE_TIMEOUT:-5}" systemctl is-enabled --quiet k3s 2>/dev/null || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}
