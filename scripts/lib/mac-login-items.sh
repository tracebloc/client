#!/usr/bin/env bash
# =============================================================================
#  mac-login-items.sh -- the macOS node's login items: io.tracebloc.node (part 4)
#  and the Apple-GPU runner's io.tracebloc.runner (part 4b). Moved out of
#  mac-container.sh, which holds the node (part 3) and every Mac's install
#  (part 6); the runtime (parts 1 and 2) is mac-runtime.sh.
#
#  macOS tools only (launchctl, plutil), under bash 3.2. The bats suites run with
#  those tools stubbed (mac-container.bats, mac-container-runner.bats).
# =============================================================================

# The xtrace hold (output.sh). A no-op with an output.sh from before it, so a mixed
# set of libs runs, unheld, rather than stopping on a missing command.
declare -F _tb_trace_off >/dev/null 2>&1 || _tb_trace_off() { :; }
declare -F _tb_trace_on >/dev/null 2>&1 || _tb_trace_on() { :; }

# ── Part 4: the login item io.tracebloc.node ────────────────────────────────
#  Apple's runtime has no restart policy: after a login, a reboot, a stopped node or a
#  killed VM, nothing brings the node back A per-user LaunchAgent does,
#  as in spike S-M. launchd runs our signed CLI's `tracebloc node ensure` at load and every
#  60 s: it starts the container system when none runs, then the node, and
#  waits for it to be Ready. It reads the runtime and the node from the install record, so
#  the plist names neither.
#    - ProgramArguments is [the CLI's absolute path, node, ensure]:
#      launchd has no PATH, and the login item then reads "tracebloc". The caller passes
#      the path the CLI's installer reported. A binary without the verb is refused by
#      name; the binary itself is asked, so no version is restated here.
#    - Before anything is written, the binary's `node ensure` runs once, as launchd will
#      run it. A command that fails would fail every minute with nobody told: measured on
#      the e2e Mac, a CLI whose record schema predates this install's kinds refuses the
#      record each time ("newer than this tracebloc reads"). That one, any other failure,
#      and a run past its bound are each refused by name.
#    - EnvironmentVariables: HOME is the home this run records into (tb_record_path), so
#      the agent reads the record the installer wrote; TRACEBLOC_SKIP_TELEMETRY=1, or each
#      tick would record a CLI outcome, about 1,440 a day.
#    - LimitLoadToSessionType Aqua: it loads in a login session only, so a headless Mac
#      never runs it ProcessType Background.
#  The plist is rewritten and the agent reloaded only when its bytes change: that is how
#  a CLI that moved (an upgrade between /usr/local/bin and ~/.local/bin) is followed.
#  It is a Mac's one login item, loaded by step c (_mac_ct_create_cluster).
TB_MAC_CT_AGENT_LABEL="io.tracebloc.node"
TB_MAC_CT_AGENT_INTERVAL=60

# _mac_ct_agent_home -- the home the install record is written under: tb_record_path
# without the record's user path: the agent's HOME, where its plist and log live.
_mac_ct_agent_home() {
  local rec home
  rec="$(tb_record_path)"
  home="${rec%"${TB_RECORD_USER_PATH#\~}"}"
  if [[ "$home" == "$rec" || "$home" != /?* ]]; then
    echo "Apple container: the install record's path is '${rec}', which is not under a home folder, so the login item has no home."
    return 1
  fi
  printf '%s\n' "$home"
}

TRACEBLOC_MAC_CT_AGENT_HELP_S=30
# _mac_ct_agent_bin_check BIN -- prints nothing and returns 0 when the login item can
# run BIN: an absolute path to an executable file that knows `node ensure`. Otherwise
# prints why and returns 1. `--help` runs nothing: an older tracebloc fails it, because
# its root takes no unknown command.
_mac_ct_agent_bin_check() {
  local bin="$1" out rc
  case "$bin" in
    /*) ;;
    *) echo "Apple container: the tracebloc CLI's path '${bin}' is not absolute, and launchd starts the login item with no PATH."; return 1 ;;
  esac
  [[ -f "$bin" && -x "$bin" ]] \
    || { echo "Apple container: ${bin} is not an executable file, so the login item would have nothing to run."; return 1; }
  rc=0
  out="$(TRACEBLOC_SKIP_TELEMETRY=1 _bounded "$TRACEBLOC_MAC_CT_AGENT_HELP_S" "$bin" node ensure --help </dev/null 2>/dev/null)" || rc=$?
  if [[ "$rc" -eq 124 ]]; then
    echo "Apple container: \`${bin} node ensure --help\` did not finish within ${TRACEBLOC_MAC_CT_AGENT_HELP_S} s, so this run cannot tell whether the CLI knows the command the login item runs. It's safe to re-run this installer."
    return 1
  fi
  [[ "$rc" -eq 0 && "$out" == *"node ensure"* ]] \
    || { echo "Apple container: ${bin} does not know \`tracebloc node ensure\`, the command the login item runs, so it is older than this installer needs. Run \`tracebloc upgrade\`, then re-run this installer."; return 1; }
}

# _mac_ct_agent_trial BIN HOME -- prints nothing and returns 0 when BIN's `node ensure`,
# run once as the login item runs it (HOME the record's home, telemetry off), succeeds
# within TRACEBLOC_MAC_CT_AGENT_TRIAL_S; its output goes to the install log. Otherwise prints
# why and returns 1. Step c calls it just after the node is Ready, so `node ensure` only
# probes; a run past the bound cannot tell, and fails closed.
TRACEBLOC_MAC_CT_AGENT_TRIAL_S=120
_mac_ct_agent_trial() {
  local bin="$1" home="$2" out rc=0 ver="" first _w _rest nl=$'\n'
  out="$(HOME="$home" TRACEBLOC_SKIP_TELEMETRY=1 _bounded "$TRACEBLOC_MAC_CT_AGENT_TRIAL_S" "$bin" node ensure </dev/null 2>&1)" || rc=$?
  printf '%s\n' "$out" >>"${LOG_FILE:-/dev/null}"
  [[ "$rc" -ne 0 ]] || return 0
  if [[ "$rc" -eq 124 ]]; then
    echo "Apple container: \`${bin} node ensure\`, the command the login item runs, did not finish within ${TRACEBLOC_MAC_CT_AGENT_TRIAL_S} s, so this run cannot tell whether the login item would bring the node back. It's safe to re-run this installer."
    return 1
  fi
  if [[ "$out" == *"newer than this tracebloc reads"* ]]; then
    first="$(HOME="$home" TRACEBLOC_SKIP_TELEMETRY=1 _bounded 30 "$bin" version </dev/null 2>/dev/null)" || first=""
    first="${first%%"$nl"*}"
    read -r _w ver _rest <<<"$first" || true
    echo "Apple container: the tracebloc CLI at ${bin} (${ver:-version unknown}) cannot read this install's record, which is newer than it, so the login item's \`node ensure\` would fail every ${TB_MAC_CT_AGENT_INTERVAL} s and the node would not come back after a restart. Run \`tracebloc upgrade\`, then re-run this installer."
    return 1
  fi
  echo "Apple container: \`${bin} node ensure\`, the command the login item runs every ${TB_MAC_CT_AGENT_INTERVAL} s, failed (exit ${rc}), so the node would not come back after a restart. It said:"
  printf '%s\n' "$out" | tail -n 10 | sed 's/^/    /'
  return 1
}

# _mac_ct_agent_log -- the file the login item logs to: in the runtime's log folder, so
# the runtime's removal (apple-container, whose path is the runtime's home) removes it too.
_mac_ct_agent_log() { local logs; logs="$(_mac_ct_log_root)" || return 1; printf '%s/tracebloc-node.log' "$logs"; }

# TB_MAC_CT_AGENT_OLD_LOG -- where the login item logged before it logged into the
# runtime's folder, under its home. Nothing removed it, so a rewrite of the plist removes
# that one file.
TB_MAC_CT_AGENT_OLD_LOG="Library/Logs/tracebloc-node.log"

# _mac_ct_agent_plist BIN HOME LOG -- the login item's plist, by setup-macos.sh's writer.
_mac_ct_agent_plist() {
  local extra
  extra="  <key>StartInterval</key><integer>${TB_MAC_CT_AGENT_INTERVAL}</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Background</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${2}</string>
    <key>TRACEBLOC_SKIP_TELEMETRY</key><string>1</string>
  </dict>"
  _emit_launch_plist "$TB_MAC_CT_AGENT_LABEL" "$extra" "$3" "$1" node ensure
}

# _mac_ct_agent_loaded -- 0 when this user's GUI domain has the login item, 1 when it
# does not (launchctl's 113), 2 when launchctl cannot say.
_mac_ct_agent_loaded() {
  local rc=0
  _bounded 30 launchctl print "gui/$(id -u)/${TB_MAC_CT_AGENT_LABEL}" </dev/null >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    113) return 1 ;;
    *) return 2 ;;
  esac
}

# _mac_ct_ensure_agent BIN -- the login item io.tracebloc.node, running BIN's
# `node ensure`: written, recorded as a launch-agent and loaded into this login session.
# A loaded agent whose plist is already these bytes is left as it is.
_mac_ct_ensure_agent() {
  local bin="$1" why home dir plist agent_log old_log want have="" loaded=0
  if [[ -n "${TRACEBLOC_SKIP_AUTOSTART:-}" ]]; then
    warn "Login item skipped (TRACEBLOC_SKIP_AUTOSTART set): after a reboot, or when its VM stops, the node stays down until you run \`tracebloc node ensure\`."
    return 0
  fi
  why="$(_mac_ct_agent_bin_check "$bin")" || error "$why"
  home="$(_mac_ct_agent_home)" || error "$home"
  agent_log="$(_mac_ct_agent_log)" || error "Apple container: cannot tell where the login item logs (above)."
  # A plist string holds these only escaped, and the writer prints values as they are.
  case "${bin}${home}${agent_log}" in
    *[\&\<\>]*) error "Apple container: '${bin}', '${home}' or '${agent_log}' holds &, < or >, which the login item's plist cannot hold as it is." ;;
  esac
  # Run as launchd will, before anything is written or loaded.
  why="$(_mac_ct_agent_trial "$bin" "$home")" || error "$why"
  dir="${TRACEBLOC_LAUNCHAGENTS_DIR:-${home}/Library/LaunchAgents}"
  plist="${dir}/${TB_MAC_CT_AGENT_LABEL}.plist"
  want="$(_mac_ct_agent_plist "$bin" "$home" "$agent_log")"
  if [[ -e "$plist" ]]; then
    have="$(cat "$plist")" || error "Apple container: ${plist} cannot be read, so this run cannot tell what the login item runs."
  fi
  _mac_ct_agent_loaded || loaded=$?
  [[ "$loaded" -ne 2 ]] \
    || error "Apple container: launchctl could not say whether the login item ${TB_MAC_CT_AGENT_LABEL} is loaded, so this run leaves it as it is."
  if [[ "$loaded" -eq 0 && "$have" == "$want" ]]; then
    tb_record_write launch-agent "$TB_MAC_CT_AGENT_LABEL" "$plist"
    log "Apple container: the login item ${TB_MAC_CT_AGENT_LABEL} is loaded and runs ${bin} node ensure."
    return 0
  fi
  if [[ "$loaded" -eq 0 ]]; then
    _bounded 30 launchctl bootout "gui/$(id -u)/${TB_MAC_CT_AGENT_LABEL}" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
      || error "Apple container: could not unload the login item ${TB_MAC_CT_AGENT_LABEL} to rewrite it. Run launchctl bootout gui/$(id -u)/${TB_MAC_CT_AGENT_LABEL}, then re-run."
  fi
  # launchd fails the job (EX_CONFIG) when its log's folder is missing.
  mkdir -p "$dir" "${agent_log%/*}" || error "Apple container: could not create ${dir} or ${agent_log%/*}."
  # What an early exit takes back (_mac_ct_stop_run_node): the item this run loads, and
  # its plist when there was none.
  [[ -e "$plist" ]] || TB_MAC_CT_RUN_PLIST="$plist"
  [[ "$loaded" -eq 0 ]] || TB_MAC_CT_RUN_AGENT=1
  printf '%s\n' "$want" > "${plist}.tmp" && mv "${plist}.tmp" "$plist" \
    || { rm -f "${plist}.tmp"; error "Apple container: could not write ${plist}."; }
  # The log an earlier plist named, which nothing else removes: that one file, by its
  # exact path, and nothing beside it.
  old_log="${home}/${TB_MAC_CT_AGENT_OLD_LOG}"
  if [[ -f "$old_log" ]]; then
    rm -f "$old_log" || warn "Apple container: could not remove the login item's old log ${old_log}; remove it yourself."
  fi
  # Recorded before it loads: a run cut off here leaves an artefact delete knows.
  tb_record_write launch-agent "$TB_MAC_CT_AGENT_LABEL" "$plist"
  _bounded 30 launchctl bootstrap "gui/$(id -u)" "$plist" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 \
    || error "Apple container: launchd did not load the login item ${plist}, so the node would not come back after a reboot. It's safe to re-run this installer."
  log "Apple container: the login item ${TB_MAC_CT_AGENT_LABEL} is loaded and runs ${bin} node ensure every ${TB_MAC_CT_AGENT_INTERVAL} s."
}

# What this run started, for _mac_ct_stop_run_node: the node (its runtime's container
# CLI and its name), and the login item and the plist it added. Cleared where the lib is
# sourced, so a value in the environment decides nothing.
TB_MAC_CT_RUN_CT=""; TB_MAC_CT_RUN_NODE=""; TB_MAC_CT_RUN_AGENT=""; TB_MAC_CT_RUN_PLIST=""

# _mac_ct_run_started CT NAME -- this run starts node NAME, which was not running.
_mac_ct_run_started() { TB_MAC_CT_RUN_CT="$1"; TB_MAC_CT_RUN_NODE="$2"; }

# _mac_ct_stop_run_node -- an install that did not finish (install_cleanup) stops the node
# this run started, so no VM it started keeps holding this Mac's memory, and says so in
# one line: stopped, or still running with the command that stops it. A node that ran
# before the run, or that an earlier install's login item keeps running, is left alone.
# The login item this run loaded goes first, with the plist when the run wrote the only
# one, or it would start the node again within a minute and after every login. Never fails.
_mac_ct_stop_run_node() {
  local ct="${TB_MAC_CT_RUN_CT:-}" name="${TB_MAC_CT_RUN_NODE:-}" stop rc=0
  [[ -n "$name" ]] || return 0
  stop="\"${ct}\" stop ${name}"
  if [[ -n "${TB_MAC_CT_RUN_AGENT:-}" ]]; then
    _bounded 30 launchctl bootout "gui/$(id -u)/${TB_MAC_CT_AGENT_LABEL}" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || true
    _mac_ct_agent_loaded || rc=$?
    if [[ "$rc" -ne 1 ]]; then
      warn "The VM this install started is still running. To stop it: launchctl bootout gui/$(id -u)/${TB_MAC_CT_AGENT_LABEL}; ${stop}"
      return 0
    fi
    [[ -z "${TB_MAC_CT_RUN_PLIST:-}" ]] || rm -f "$TB_MAC_CT_RUN_PLIST" || true
  else
    # Only a confirmed none (1) lets this run stop the node: an earlier install's item (0)
    # keeps it running, and one launchctl cannot answer for (2) may.
    _mac_ct_agent_loaded || rc=$?
    [[ "$rc" -ne 0 ]] || return 0
    [[ "$rc" -eq 1 ]] || { warn "The VM this install started is still running. To stop it: ${stop}"; return 0; }
  fi
  rc=0; _mac_ct_node_running "$ct" "$name" || rc=$?
  [[ "$rc" -ne 1 ]] || return 0
  _bounded 120 "$ct" stop "$name" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || true
  rc=0; _mac_ct_node_running "$ct" "$name" || rc=$?
  if [[ "$rc" -eq 1 ]]; then
    info "Stopped the VM to free this Mac's memory."
  else
    warn "The VM this install started is still running. To stop it: ${stop}"
  fi
  return 0
}

# ── Part 4b: the runner's login item io.tracebloc.runner ────────────────────
#  The Apple-GPU runner is the CLI's hidden `tracebloc
#  runner`: a node of this Mac's own cluster that runs GPU jobs as sandboxed processes
#  on the Mac. A second login item keeps it running, beside io.tracebloc.node. It needs
#  the chart's ServiceAccount (apple-gpu-runner-rbac.yaml), so step e sets it up right
#  after the chart, not step c.
#    - DARK until the CLI carries the runner. The CLI step b installed is asked:
#      `tracebloc runner --released` exits 0 only in a release whose runner is switched
#      on. Any other answer, an older CLI's unknown flag included, is "not released":
#      no login item, and the chart's appleGpuRunner stays off. So the CLI's one
#      switch decides both, and an installer newer than its CLI adds nothing.
#    - Its kubeconfig names the API on 127.0.0.1:6443, the one server the runner dials,
#      with the node's CA, and reads the runner's token from a file beside it. The token
#      is a bound ServiceAccount token for TB_MAC_CT_RUNNER_TOKEN_S, issued again by every
#      run, so an upgrade renews it; the runner re-reads the file. Both files are 0600,
#      in a 0700 folder in the node's, so the runtime's removal takes them.
#    - KeepAlive: launchd starts the runner again when it ends, at most once every
#      TB_MAC_CT_RUNNER_THROTTLE_S. LimitLoadToSessionType Aqua and the environment as
#      io.tracebloc.node's.
#    - Not part of a CPU install: a runner that cannot be set up is a warning, and GPU
#      jobs then run on the CPU (D3). It's safe to re-run the installer.
TB_MAC_CT_RUNNER_LABEL="io.tracebloc.runner"
# The chart's ServiceAccount for the runner (tracebloc.appleGpuRunnerAccount).
TB_MAC_CT_RUNNER_ACCOUNT="tracebloc-runner"
# The ConfigMap the chart renders exactly when it sends GPU trainings to the runner
# (client/templates/apple-gpu-bundle-configmap.yaml). Its name is fixed there, the
# runner's contract constant, never the release's; mac-container-runner.bats reads it
# back from the template.
TB_MAC_CT_RUNNER_BUNDLE_CM="tracebloc-apple-gpu-bundle"
TB_MAC_CT_RUNNER_TOKEN_S=31536000
TB_MAC_CT_RUNNER_THROTTLE_S=30
TRACEBLOC_MAC_CT_RUNNER_PROBE_S=30
# 1 once _mac_ct_ensure_runner leaves the runner's login item loaded over a job-data
# folder this Mac keeps (_mac_ct_runner_gpu_ready); the summary's Mode reads it. Cleared
# where the lib is sourced, so a value in the environment decides nothing.
TRACEBLOC_MAC_GPU_RUNNER_READY=""
# 1 once _mac_ct_runner_gpu_ready finds the runner ready but the chart sending it no GPU
# training (_mac_ct_runner_bundle_rendered); the summary's Training row reads it. Cleared
# the same way.
TRACEBLOC_MAC_GPU_TRAINING_OFF=""
# This run's answer to "does the CLI carry the runner?", asked once (_mac_ct_runner_on).
# Cleared where the lib is sourced, so a value in the environment decides nothing.
TRACEBLOC_MAC_CT_RUNNER_ON=""

# _mac_ct_runner_released BIN -- 0 when BIN, an absolute path to an executable, answers
# `runner --released` with exit 0 within TRACEBLOC_MAC_CT_RUNNER_PROBE_S; 1 for any other
# answer, a run past the bound included. Its output goes to the install log.
_mac_ct_runner_released() {
  local bin="$1" rc=0
  case "$bin" in /*) ;; *) return 1 ;; esac
  [[ -f "$bin" && -x "$bin" ]] || return 1
  TRACEBLOC_SKIP_TELEMETRY=1 _bounded "$TRACEBLOC_MAC_CT_RUNNER_PROBE_S" "$bin" runner --released \
    </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
}

# _mac_ct_runner_host -- 0 on the machine the runner is set up on: the macOS node (native
# k3s on a Mac). The half of _mac_ct_runner_on known before step b installs the CLI, so
# step a's GPU line (detect_gpu) says what step e then does.
_mac_ct_runner_host() {
  [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "${OS:-}" == "Darwin" ]]
}

# _mac_ct_runner_on -- 0 when this run sets up the runner: the macOS node
# (_mac_ct_runner_host) and a CLI that carries it (TRACEBLOC_CLI_BIN, step b). Asked once
# a run; the chart's value and the login item read the same answer.
_mac_ct_runner_on() {
  if [[ -z "$TRACEBLOC_MAC_CT_RUNNER_ON" ]]; then
    TRACEBLOC_MAC_CT_RUNNER_ON=0
    if _mac_ct_runner_host \
      && _mac_ct_runner_released "${TRACEBLOC_CLI_BIN:-}"; then
      TRACEBLOC_MAC_CT_RUNNER_ON=1
    fi
  fi
  [[ "$TRACEBLOC_MAC_CT_RUNNER_ON" == 1 ]]
}

# _mac_ct_runner_off_why -- why _mac_ct_runner_on said no, from the same conditions it read
# (the CLI is not asked again): the substrate, the CLI's path, or the CLI's answer.
_mac_ct_runner_off_why() {
  local bin="${TRACEBLOC_CLI_BIN:-}"
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" != "k3s" ]]; then
    printf 'it runs only on the macOS node (native k3s), and this Mac runs %s' "${TRACEBLOC_SUBSTRATE_RESOLVED:-no substrate}"
  elif [[ "$bin" != /* || ! -f "$bin" || ! -x "$bin" ]]; then
    printf 'this run has no tracebloc CLI to ask (%s)' "${bin:-none}"
  else
    printf 'the tracebloc CLI at %s did not report it as part of its release' "$bin"
  fi
}

_mac_ct_runner_dir() { local d; d="$(_mac_ct_node_dir)" || return 1; printf '%s/runner' "$d"; }
_mac_ct_runner_log() { local logs; logs="$(_mac_ct_log_root)" || return 1; printf '%s/tracebloc-runner.log' "$logs"; }

# The runner's engine bundle store (§8 Q16): the folder it keeps the verified
# macOS engine bundles in, HOME/Library/Application Support/tracebloc/engine-bundles, the
# daily user's own at mode 0700. It is the install record's engine-bundles entry, id the
# runner's label. The runner reads the record once, when it starts, and keeps no bundle
# where the record names no such folder of this user's own, so the folder is made and
# recorded before its login item loads. tracebloc delete removes it.
# _mac_ct_runner_bundles_dir HOME -- the folder's path under HOME.
_mac_ct_runner_bundles_dir() { printf '%s/Library/Application Support/tracebloc/engine-bundles' "$1"; }

# _mac_ct_runner_bundles_listed DIR -- 0 when the install record already lists DIR as the
# runner's engine-bundles folder.
_mac_ct_runner_bundles_listed() {
  local rec
  rec="$(tb_record_path)"
  [[ -f "$rec" ]] || return 1
  grep -qF "{\"kind\": \"engine-bundles\", \"id\": $(_tb_json "$TB_MAC_CT_RUNNER_LABEL"), \"path\": $(_tb_json "$1"), " "$rec"
}

# _mac_ct_runner_bundles DIR -- makes DIR, the runner's engine bundle store, 0700. Exit 1,
# printing why, when DIR is there and is not a folder of this user's own (a symbolic link,
# a file, another user's folder: the runner and delete refuse each), or cannot be made.
_mac_ct_runner_bundles() {
  local d="$1" saved_umask
  if [[ -L "$d" ]] || { [[ -e "$d" ]] && ! [[ -d "$d" && -O "$d" ]]; }; then
    echo "${d} is there and is not a folder of your own, so the runner has nowhere to keep the GPU engine"; return 1
  fi
  saved_umask="$(umask)"
  umask 077
  if ! { mkdir -p "$d" && chmod 0700 "$d"; }; then
    umask "$saved_umask"; echo "could not create ${d}"; return 1
  fi
  umask "$saved_umask"
}

# _mac_ct_runner_kubeconfig_yaml CA_DATA TOKEN_FILE NAMESPACE -- the runner's kubeconfig.
_mac_ct_runner_kubeconfig_yaml() {
  printf '%s\n' 'apiVersion: v1' 'kind: Config' 'clusters:' '- name: tracebloc' '  cluster:' \
    '    server: https://127.0.0.1:6443'
  printf '    certificate-authority-data: %s\n' "$1"
  printf '%s\n' 'users:' "- name: ${TB_MAC_CT_RUNNER_ACCOUNT}" '  user:'
  printf '    tokenFile: %s\n' "$2"
  printf '%s\n' 'contexts:' "- name: ${TB_MAC_CT_RUNNER_ACCOUNT}" '  context:' '    cluster: tracebloc' \
    "    user: ${TB_MAC_CT_RUNNER_ACCOUNT}"
  printf '    namespace: %s\n' "$3"
  printf 'current-context: %s\n' "$TB_MAC_CT_RUNNER_ACCOUNT"
}

# _mac_ct_runner_kubeconfig NAMESPACE -- issues the runner's token and writes it and the
# runner's kubeconfig, each 0600 in a 0700 folder; prints the kubeconfig's path. Exit 1,
# printing why, when the node's CA cannot be read, kubectl issues no token, or a file
# cannot be written. The token never reaches the log or the output.
# _mac_ct_runner_kubeconfig runs with bash -x held off, the secret it holds out of the trace (output.sh);
# _tb_untraced__mac_ct_runner_kubeconfig below is the function itself.
_mac_ct_runner_kubeconfig() { { _tb_trace_off; } 2>/dev/null; _tb_untraced__mac_ct_runner_kubeconfig "$@"; local _tb_rc=$?; _tb_trace_on; return "$_tb_rc"; }
_tb_untraced__mac_ct_runner_kubeconfig() {
  local ns="$1" node dir ca tok rc=0 saved_umask
  node="$(_mac_ct_node_dir)" || { echo "cannot tell where the node's files are"; return 1; }
  dir="${node}/runner"
  ca="$(sed -n 's/^ *certificate-authority-data: *//p' "${node}/k3s.yaml" 2>/dev/null)" || ca=""
  ca="${ca%%$'\n'*}"
  [[ "$ca" =~ ^[A-Za-z0-9+/=]+$ ]] || { echo "the node's kubeconfig ${node}/k3s.yaml holds no certificate-authority-data"; return 1; }
  tok="$(_bounded 30 kubectl --kubeconfig "$(_native_k3s_kubeconfig_target)" --context "$(_native_k3s_context)" \
    -n "$ns" create token "$TB_MAC_CT_RUNNER_ACCOUNT" --duration="${TB_MAC_CT_RUNNER_TOKEN_S}s" --request-timeout=20s \
    </dev/null 2>>"${LOG_FILE:-/dev/null}")" || rc=$?
  [[ "$rc" -eq 0 ]] || { echo "kubectl could not issue a token for the ServiceAccount ${ns}/${TB_MAC_CT_RUNNER_ACCOUNT} (exit ${rc})"; return 1; }
  [[ "$tok" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] \
    || { echo "kubectl's answer for the ServiceAccount ${ns}/${TB_MAC_CT_RUNNER_ACCOUNT} is not one token"; return 1; }
  saved_umask="$(umask)"
  umask 077
  if ! { mkdir -p "$dir" && chmod 0700 "$dir"; }; then
    umask "$saved_umask"; echo "could not create ${dir}"; return 1
  fi
  if ! { printf '%s' "$tok" > "${dir}/token.tmp" && chmod 0600 "${dir}/token.tmp" && mv "${dir}/token.tmp" "${dir}/token"; }; then
    rm -f "${dir}/token.tmp"; umask "$saved_umask"; echo "could not write ${dir}/token"; return 1
  fi
  if ! { _mac_ct_runner_kubeconfig_yaml "$ca" "${dir}/token" "$ns" > "${dir}/kubeconfig.tmp" \
         && chmod 0600 "${dir}/kubeconfig.tmp" && mv "${dir}/kubeconfig.tmp" "${dir}/kubeconfig"; }; then
    rm -f "${dir}/kubeconfig.tmp"; umask "$saved_umask"; echo "could not write ${dir}/kubeconfig"; return 1
  fi
  umask "$saved_umask"
  printf '%s/kubeconfig' "$dir"
}

# _mac_ct_runner_plist BIN HOME LOG KUBECONFIG NAMESPACE -- the runner's login item, by
# setup-macos.sh's writer.
_mac_ct_runner_plist() {
  local extra
  extra="  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>${TB_MAC_CT_RUNNER_THROTTLE_S}</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Standard</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${2}</string>
    <key>TRACEBLOC_SKIP_TELEMETRY</key><string>1</string>
  </dict>"
  _emit_launch_plist "$TB_MAC_CT_RUNNER_LABEL" "$extra" "$3" "$1" runner --kubeconfig "$4" --namespace "$5"
}

# _mac_ct_runner_loaded -- 0 when this user's GUI domain has the runner's login item, 1
# when it does not (launchctl's 113), 2 when launchctl cannot say.
_mac_ct_runner_loaded() {
  local rc=0
  _bounded 30 launchctl print "gui/$(id -u)/${TB_MAC_CT_RUNNER_LABEL}" </dev/null >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    113) return 1 ;;
    *) return 2 ;;
  esac
}

# _mac_ct_runner_bundle_rendered NS -- whether the release in NS sends GPU trainings to
# the runner: `yes` when the chart rendered ConfigMap TB_MAC_CT_RUNNER_BUNDLE_CM there,
# `no` when the API says it is not there, `unknown` for any other answer. The chart
# renders it exactly where tracebloc.appleGpuBundle holds (a pinned macOS engine bundle,
# the training pins, which only prod turns on by itself, and appleGpuRunner.gpuTraining;
# client/templates/apple-gpu-bundle-configmap.yaml), the one gate jobs-manager's GPU
# routing reads too, and it reflects every value the release keeps, overrides included.
# It reads no Helm values, so none of their secrets.
_mac_ct_runner_bundle_rendered() {
  local ns="$1" out rc=0
  [[ -n "$ns" ]] || { printf unknown; return 0; }
  out="$(_bounded 30 kubectl --kubeconfig "$(_native_k3s_kubeconfig_target)" --context "$(_native_k3s_context)" \
    -n "$ns" get configmap "$TB_MAC_CT_RUNNER_BUNDLE_CM" -o name --request-timeout=20s </dev/null 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 && "$out" == "configmap/${TB_MAC_CT_RUNNER_BUNDLE_CM}" ]]; then printf yes; return 0; fi
  if [[ "$rc" -ne 0 && "$out" == *NotFound* ]]; then printf no; return 0; fi
  log "The tracebloc runner: whether ConfigMap ${ns}/${TB_MAC_CT_RUNNER_BUNDLE_CM} exists cannot be told (kubectl exit ${rc}): ${out%%$'\n'*}"
  printf unknown
}

# _mac_ct_runner_gpu_ready -- sets TRACEBLOC_MAC_GPU_RUNNER_READY=1, and says so, when this
# run keeps a job-data folder on this Mac and it is there (the runner refuses the GPU
# without it), and the release sends GPU trainings to the runner
# (_mac_ct_runner_bundle_rendered). Where it sends none (GPU training off in the chart,
# or no pinned macOS engine bundle, as on a dev or stg install) it says nothing and sets
# TRACEBLOC_MAC_GPU_TRAINING_OFF=1 instead: every training on this Mac runs on the CPU.
# An answer it cannot read sets neither.
_mac_ct_runner_gpu_ready() {
  local jd
  jd="$(_mac_ct_job_data_dir)"
  [[ -n "$jd" && -d "$jd" ]] || return 0
  case "$(_mac_ct_runner_bundle_rendered "${namespace:-}")" in
    yes)
      TRACEBLOC_MAC_GPU_RUNNER_READY=1
      success "GPU training set up" ;;
    no)
      TRACEBLOC_MAC_GPU_TRAINING_OFF=1
      log "The tracebloc runner: GPU training on Macs is switched off for now; training runs on the CPU (the chart sends it no GPU training: no ConfigMap ${TB_MAC_CT_RUNNER_BUNDLE_CM}, so appleGpuRunner.gpuTraining is off or this environment pins no macOS engine bundle)." ;;
    *)
      log "The tracebloc runner: whether the chart sends it GPU trainings cannot be told, so the summary does not name the Apple GPU." ;;
  esac
}

# _mac_ct_ensure_runner -- the runner's login item, when this run sets up the runner
# (_mac_ct_runner_on): its kubeconfig and token written, its engine bundle store made, its
# plist written, recorded as a launch-agent and loaded into this login session. A loaded
# item whose plist is already these bytes is left loaded, unless the record did not list
# the bundle store before this run: the runner read the record when it started, so it is
# unloaded, the store recorded, and the item loaded again to read it. Its token is issued again either way. Anything
# that stops it is a warning, never the install's failure: GPU jobs then run on the CPU.
_mac_ct_ensure_runner() {
  local ns="${namespace:-}" bin="${TRACEBLOC_CLI_BIN:-}" home dir plist runner_log kcfg want have="" loaded=0 why
  local bundles listed=0 bad
  local cpu="GPU training falls back to the CPU. It's safe to re-run this installer."
  TRACEBLOC_MAC_GPU_RUNNER_READY=""; TRACEBLOC_MAC_GPU_TRAINING_OFF=""
  if ! _mac_ct_runner_on; then
    [[ "${OS:-}" != "Darwin" ]] || log "The tracebloc runner: $(_mac_ct_runner_off_why), so no runner login item."
    # On the macOS node this run sets out to train on the GPU (detect_gpu logs it), so a
    # CLI that does not carry the runner is said, not only logged.
    if _mac_ct_runner_host; then
      warn "The tracebloc runner: $(_mac_ct_runner_off_why), so it is not set up. ${cpu}"
    fi
    return 0
  fi
  if [[ -n "${TRACEBLOC_SKIP_AUTOSTART:-}" ]]; then
    warn "The tracebloc runner's login item skipped (TRACEBLOC_SKIP_AUTOSTART set): ${cpu}"
    return 0
  fi
  [[ -n "$ns" ]] || { warn "The tracebloc runner: this run has no namespace for it. ${cpu}"; return 0; }
  home="$(_mac_ct_agent_home)" || { warn "The tracebloc runner: ${home} ${cpu}"; return 0; }
  runner_log="$(_mac_ct_runner_log)" || { warn "The tracebloc runner: cannot tell where its login item logs. ${cpu}"; return 0; }
  kcfg="$(_mac_ct_runner_kubeconfig "$ns")" || { warn "The tracebloc runner: ${kcfg}. ${cpu}"; return 0; }
  # A plist string holds these only escaped, and the writer prints values as they are.
  case "${bin}${home}${runner_log}${kcfg}${ns}" in
    *[\&\<\>]*) warn "The tracebloc runner: '${bin}', '${home}', '${runner_log}' or '${kcfg}' holds &, < or >, which its login item's plist cannot hold as it is. ${cpu}"; return 0 ;;
  esac
  bundles="$(_mac_ct_runner_bundles_dir "$home")"
  if _mac_ct_runner_bundles_listed "$bundles"; then listed=1; fi
  bad="$(_mac_ct_runner_bundles "$bundles")" || { warn "The tracebloc runner: ${bad}. ${cpu}"; return 0; }
  dir="${TRACEBLOC_LAUNCHAGENTS_DIR:-${home}/Library/LaunchAgents}"
  plist="${dir}/${TB_MAC_CT_RUNNER_LABEL}.plist"
  want="$(_mac_ct_runner_plist "$bin" "$home" "$runner_log" "$kcfg" "$ns")"
  if [[ -e "$plist" ]]; then
    have="$(cat "$plist")" || { warn "The tracebloc runner: ${plist} cannot be read, so this run cannot tell what its login item runs. ${cpu}"; return 0; }
  fi
  _mac_ct_runner_loaded || loaded=$?
  if [[ "$loaded" -eq 2 ]]; then
    warn "The tracebloc runner: launchctl could not say whether ${TB_MAC_CT_RUNNER_LABEL} is loaded, so this run leaves it as it is. ${cpu}"
    return 0
  fi
  if [[ "$loaded" -eq 0 && "$have" == "$want" && "$listed" -eq 1 ]]; then
    tb_record_write launch-agent "$TB_MAC_CT_RUNNER_LABEL" "$plist"
    log "The tracebloc runner: its login item ${TB_MAC_CT_RUNNER_LABEL} is loaded; its token was issued again."
    _mac_ct_runner_gpu_ready
    return 0
  fi
  if [[ "$loaded" -eq 0 ]] && ! _bounded 30 launchctl bootout "gui/$(id -u)/${TB_MAC_CT_RUNNER_LABEL}" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1; then
    warn "The tracebloc runner: could not unload ${TB_MAC_CT_RUNNER_LABEL} to rewrite it. Run launchctl bootout gui/$(id -u)/${TB_MAC_CT_RUNNER_LABEL}, then re-run. Until then ${cpu}"
    return 0
  fi
  # Recorded once the old item is gone and before the new one loads: the runner reads the
  # record when it starts, and a run that stopped above must not leave it listed.
  tb_record_write engine-bundles "$TB_MAC_CT_RUNNER_LABEL" "$bundles"
  # launchd fails the job (EX_CONFIG) when its log's folder is missing.
  if ! mkdir -p "$dir" "${runner_log%/*}"; then
    warn "The tracebloc runner: could not create ${dir} or ${runner_log%/*}. ${cpu}"; return 0
  fi
  if ! { printf '%s\n' "$want" > "${plist}.tmp" && mv "${plist}.tmp" "$plist"; }; then
    rm -f "${plist}.tmp"; warn "The tracebloc runner: could not write ${plist}. ${cpu}"; return 0
  fi
  # Recorded before it loads: a run cut off here leaves an artefact delete knows.
  tb_record_write launch-agent "$TB_MAC_CT_RUNNER_LABEL" "$plist"
  why=0
  _bounded 30 launchctl bootstrap "gui/$(id -u)" "$plist" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || why=$?
  if [[ "$why" -ne 0 ]]; then
    warn "The tracebloc runner: launchd did not load ${plist} (exit ${why}). ${cpu}"; return 0
  fi
  log "The tracebloc runner: its login item ${TB_MAC_CT_RUNNER_LABEL} is loaded and runs ${bin} runner."
  _mac_ct_runner_gpu_ready
}
