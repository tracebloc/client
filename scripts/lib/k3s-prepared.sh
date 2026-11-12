#!/usr/bin/env bash
# =============================================================================
#  k3s-prepared.sh — the prepared host (1.1g): prepare-host's admin half and its adoption
#
#  LINUX ONLY. Moved out of k3s.sh; install-k8s.sh sources it right
#  after k3s.sh and k3s-firewall.sh, and both bootstraps fetch it. Every function keeps the
#  `_native_k3s_` prefix and calls into k3s.sh's install path.
#  bash 3.2-safe; sourcing it has no side effects: constants and functions only.
# =============================================================================

# ── The prepared host (1.1g) ──────────────────────────────────────────────────
#
# The admin half. An administrator runs prepare-host once, naming the daily
# user; it sets k3s up for them as root, grants k3s.yaml to the prepared group with
# them in it, and writes their records. Their own install then finds the host
# prepared and adopts it at Tier 0, with no administrator rights.

# _native_k3s_prepared_for_me -- 0 when an administrator prepared this host for this
# user, read with no privileges: all four hold -- this user's own record names them
# in prepared_for (prepare-host writes it; tracebloc delete reads the same field), the
# prepared group lists them (root's, so a record they edit alone does not count), k3s
# is active, and this user can read k3s.yaml. Otherwise 1; on a host prepared for
# this user (the record names them), stdout then names what is missing, a key of
# _native_k3s_prepared_reason: k3s itself, gone after an administrator's offboard
# (their delete cannot edit this user's record, so it still names them); k3s not
# running; k3s.yaml unreadable; or a login older than the group. A record prepare-host
# wrote before prepared_for existed names no one: the remedy, prepare-host again,
# writes it.
_native_k3s_prepared_for_me() {
  local rec me members
  rec="$(tb_record_path)"
  [[ -f "$rec" ]] || return 1
  me="$(id -un 2>/dev/null)" || return 1
  [[ -n "$me" && "$(_tb_record_prior prepared_for "$(cat "$rec" 2>/dev/null)")" == "$(_tb_json "$me")" ]] || return 1
  if [[ ! -e "$TB_K3S_BIN_PATH" ]]; then
    printf 'gone'
    return 1
  fi
  # The record is this user's to edit; the prepared group is root's, and only prepare-host
  # adds a user to it. A record that names them while the group does not (edited by hand,
  # or the administrator took them out) is not a host prepared for them.
  members="$(getent group "$TB_K3S_PREPARED_GROUP" 2>/dev/null)" || members=""
  case ",${members##*:}," in
    *",${me},"*) ;;
    *) return 1 ;;
  esac
  if ! _bounded "${TB_PROBE_TIMEOUT:-5}" systemctl is-active --quiet k3s 2>/dev/null; then
    printf 'stopped'
    return 1
  fi
  if [[ ! -r "$TB_K3S_KUBECONFIG_PATH" ]]; then
    case " $(id -Gn 2>/dev/null) " in
      *" ${TB_K3S_PREPARED_GROUP} "*) printf 'unreadable' ;;
      *) printf 'relogin' ;;
    esac
    return 1
  fi
  return 0
}

# _native_k3s_prepared_reason KEY WHAT -- what is missing on a host prepared for this
# user (KEY, from _native_k3s_prepared_for_me), said for WHAT: why (the log's clause
# after "An administrator prepared this machine for you, but"), next (a person's end
# block: the reason line, then what to do, as tb_fail_next takes it) or cmd (the
# command under it; none where it is the install command). An unknown KEY says nothing.
_native_k3s_prepared_reason() {
  local line remedy="Ask an administrator to run this once, then run the installer again:" cmd
  cmd="$(_native_k3s_prepare_host_cmd)"
  case "$1:$2" in
    gone:why)       printf 'the k3s they set up is gone from it (no %s)' "$TB_K3S_BIN_PATH"; return 0 ;;
    stopped:why)    printf 'k3s is not running on it (systemctl is-active k3s)'; return 0 ;;
    unreadable:why) printf 'you cannot read %s' "$TB_K3S_KUBECONFIG_PATH"; return 0 ;;
    relogin:why)    printf 'this session started before you joined the %s group, so you cannot read %s yet: log out and back in, then re-run' "$TB_K3S_PREPARED_GROUP" "$TB_K3S_KUBECONFIG_PATH"; return 0 ;;
    gone:*)         line="This machine was prepared for you, but k3s has been deleted since." ;;
    stopped:*)      line="This machine was prepared for you, but k3s isn't running on it." ;;
    unreadable:*)   line="This machine was prepared for you, but you can't read ${TB_K3S_KUBECONFIG_PATH}." ;;
    relogin:*)      line="This machine was prepared for you, but this login started before you joined the ${TB_K3S_PREPARED_GROUP} group."
                    remedy="Log out and back in, then run the installer again:"; cmd="" ;;
    *)              return 0 ;;
  esac
  case "$2" in
    next) printf '%s\\n%s' "$line" "$remedy" ;;
    cmd)  printf '%s' "$cmd" ;;
  esac
}

# _native_k3s_prepare_host_cmd -- the command an administrator runs, once, to prepare
# this machine for this user: what a person reads (tb_fail_next).
_native_k3s_prepare_host_cmd() {
  local me
  me="$(id -un 2>/dev/null)" || me=""
  printf 'curl -fsSL https://tracebloc.io/i.sh | TRACEBLOC_PREPARE_USER=%s bash -s -- prepare-host' "${me:-<your-username>}"
}

# _native_k3s_prepare_host_remedy [KEY] -- the way forward for a user who cannot
# sudo: an administrator prepares the host for them once. KEY, when given, is what
# is missing on a host already prepared for them (_native_k3s_prepared_reason).
_native_k3s_prepare_host_remedy() {
  local me
  me="$(id -un 2>/dev/null)" || me=""
  [[ -z "${1:-}" ]] || printf 'An administrator prepared this machine for you, but %s. ' "$(_native_k3s_prepared_reason "$1" why)"
  printf 'An administrator can prepare this machine for you once: export TRACEBLOC_SUBSTRATE=k3s TRACEBLOC_PREPARE_USER=%s && curl -fsSL https://tracebloc.io/i.sh | bash -s -- prepare-host -- then re-run this installer, with no sudo.' "${me:-<your-username>}"
}

# _native_k3s_adopt_tools -- step b at Tier 0 on a host prepared for this user. k3s,
# its files and its firewall are the administrator's, so nothing here asks for
# administrator rights: helm goes user-local (_set_tools_target), and create_cluster
# takes the adopt path.
_native_k3s_adopt_tools() {
  # shellcheck disable=SC2034  # consumed cross-file (setup-linux.sh's tools target, record.sh's root copy, diagnose.sh)
  INSTALL_TIER=0
  # shellcheck disable=SC2034  # consumed cross-file by diagnose.sh
  INSTALL_TIER_REASON="native-k3s-prepared"
  TB_K3S_ADOPTED=1
  log "step b: native k3s: tier 0 (an administrator prepared this machine for $(id -un 2>/dev/null); no administrator rights)"
  info "An administrator prepared native k3s on this machine for you, so this install needs no administrator rights."
  _set_tools_target
  local saved_umask
  saved_umask="$(umask)"
  umask 022
  tb_live_quiet "Installing system tools..."
  _helm_expect
  install_helm
  tb_live_done "System tools ready"
  umask "$saved_umask"
  log "step b: native k3s: helm ready in ${TRACEBLOC_TOOLS_DIR:-?} (k3s is the administrator's)"
}

# _native_k3s_adopt_cluster -- step c on a prepared host. The k3s an administrator set
# up for this user is used as it is: no firewall, file, binary or restart here, and
# no sudo. k3s.yaml, readable through the prepared group, is merged into this user's
# kubeconfig and recorded; then the API and the node are waited for on the one
# budget the full path uses. The k3d check ran in main(), before step b
# (reinstall.sh's refuse_k3d_machine), from this user's own install record and
# kubeconfig.
_native_k3s_adopt_cluster() {
  local name
  _native_k3s_refuse_host
  log "native k3s: using the k3s an administrator prepared for $(id -un 2>/dev/null) (prepare-host)."
  name="$(_native_k3s_node_name)" || _native_k3s_node_name_stop "$?"
  TB_K3S_WAITED_S=0; TB_K3S_WAIT_T0="$(date +%s)"
  _native_k3s_merge_kubeconfig
  tb_record_write kube-context "$(_native_k3s_context)" "$(_native_k3s_kubeconfig_target)"
  _native_k3s_wait_for_api
  _native_k3s_wait_for_node_ready "$name"
  _native_k3s_gpu_adopt
  _export_host_no_proxy
}

# _native_k3s_gpu_adopt -- step c's GPU gate on a host adopted at Tier 0. This user
# cannot ask k3s's containerd (`k3s crictl` needs root), so the answer is the one
# prepare-host's gate (_native_k3s_gpu_wire) gave as root, read from the record it
# wrote for this user, never re-detected here. TRACEBLOC_GPU_WIRED=1 only when that
# runtime is TB_K3S_GPU_RUNTIME and this run's floor verdict keeps the GPU; the GPUs
# are counted after the install (_native_k3s_gpu_verify), as on the full path, so a
# record that outlived its GPU is caught there.
_native_k3s_gpu_adopt() {
  local rec rt=""
  rec="$(tb_record_path)"
  if [[ -f "$rec" ]]; then rt="$(_tb_record_prior "$TB_RECORD_PREPARED_GPU_KEY" "$(cat "$rec" 2>/dev/null)")"; fi
  TRACEBLOC_GPU_WIRED=0
  # detect_gpu said why and what to do.
  if declare -F _gpu_floor_skips >/dev/null 2>&1 && _gpu_floor_skips; then return 0; fi
  if [[ "$rt" == "$(_tb_json "$TB_K3S_GPU_RUNTIME")" ]]; then
    GPU_VENDOR=nvidia
    # shellcheck disable=SC2034  # consumed cross-file by kube.sh (_gpu_wired)
    TRACEBLOC_GPU_WIRED=1
    # No runtime name: the gate's own line is the one success line naming it alone, which
    # e2e reads (e2e-test-agent producer_contracts.py, native_k3s_gpu_wiring); the count
    # after Helm names it.
    success "prepare-host registered the NVIDIA runtime for you; the GPUs are counted after the install."
    return 0
  fi
  [[ "${GPU_VENDOR:-}" == nvidia ]] || return 0
  warn "This machine has an NVIDIA GPU, but prepare-host did not set it up for k3s, so this install runs in CPU mode."
  hint "Ask the administrator to re-run prepare-host for you (it sets the GPU up when 'nvidia-smi' works), then re-run this installer."
}

# _native_k3s_prepared_finish NAME -- step 4 and 5 in prepared mode: the API, asked
# as root on k3s.yaml (_native_k3s_kubectl_on); k3s.yaml's grant to the prepared
# group, read back; the node password; node NAME Ready; the GPU gate, as root, whose
# runtime goes into the named user's record (TB_RECORD_PREPARED_GPU_RUNTIME) for their
# adopt to read (_native_k3s_gpu_adopt); this process's NO_PROXY. The shared wait
# budget started with the wait for k3s.yaml, as on the full path.
_native_k3s_prepared_finish() {
  local name="$1"
  _native_k3s_wait_for_api
  _native_k3s_check_prepared_grant
  tb_record_write file node-password "$TB_K3S_NODE_PASSWORD_PATH"
  _native_k3s_wait_for_node_ready "$name"
  _native_k3s_gpu_wire "$name"
  # shellcheck disable=SC2034  # consumed cross-file by record.sh (tb_record_write)
  TB_RECORD_PREPARED_GPU_RUNTIME=""
  # shellcheck disable=SC2034  # consumed cross-file by record.sh (tb_record_write)
  if _gpu_wired; then TB_RECORD_PREPARED_GPU_RUNTIME="$TB_K3S_GPU_RUNTIME"; fi
  _export_host_no_proxy
}

# _native_k3s_prepared_group USER -- the prepared group exists (a system group, made
# here when missing) and USER is in it, BEFORE k3s starts: k3s grants k3s.yaml to a
# group that exists when it writes the file, and only logs one that does not. The
# members are named to the administrator, since each of them is cluster-admin.
_native_k3s_prepared_group() {
  local user="$1" g="$TB_K3S_PREPARED_GROUP" line
  TB_K3S_GROUP_MADE=0
  if ! getent group "$g" >/dev/null 2>&1; then
    tb_root groupadd --system "$g" \
      || error "prepare-host: couldn't create the '${g}' group. Check 'sudo groupadd --system ${g}', then re-run."
    TB_K3S_GROUP_MADE=1
    log "prepare-host: created the system group '${g}'."
  fi
  tb_root usermod -aG "$g" "$user" \
    || error "prepare-host: couldn't add ${user} to the '${g}' group. Check 'sudo usermod -aG ${g} ${user}', then re-run."
  line="$(getent group "$g" 2>/dev/null)" || line=""
  log "prepare-host: ${user} is in '${g}' (members: ${line##*:})."
  warn "Members of the ${g} group can administer k3s on this machine: ${line##*:}."
}

# _native_k3s_check_prepared_grant -- prepared mode: k3s.yaml must be root's, group
# TB_K3S_PREPARED_GROUP, mode 0640, or the named user cannot read it. k3s sets the
# mode and then the group, and a group it cannot set is only a line in its log
# (pkg/server/server.go, v1.36.3+k3s1), so the grant is read back, and anything else
# fails the run.
_native_k3s_check_prepared_grant() {
  local have want="root:${TB_K3S_PREPARED_GROUP} 640"
  # --print: nothing ran, so there is nothing to wait for or read back.
  if tb_root_planning; then return 0; fi
  have="$(tb_root stat -c '%U:%G %a' "$TB_K3S_KUBECONFIG_PATH" 2>/dev/null)" || have=""
  [[ "$have" == "$want" ]] \
    || error "native k3s: ${TB_K3S_KUBECONFIG_PATH} is '${have:-unreadable}' (owner:group mode), not '${want}', so ${TB_RECORD_FOR_USER:-the named user} cannot read it. 'sudo journalctl -u k3s | grep -i kubeconfig' says why; it's safe to re-run prepare-host."
  log "native k3s: ${TB_K3S_KUBECONFIG_PATH} is ${have}."
}

# _native_k3s_check_user_record USER HOME -- USER's own record must be there and
# list k3s-install: their Tier 0 install adopts the host by it. Record writes are
# best-effort, so prepare-host reads the copy back, as USER.
_native_k3s_check_user_record() {
  local dst="${2}${TB_RECORD_USER_PATH#\~}" body
  # --print: nothing ran, so there is nothing to wait for or read back.
  if tb_root_planning; then return 0; fi
  body="$(_tb_record_as_user "$1" cat "$dst" 2>/dev/null)" || body=""
  case "$body" in
    *'"kind": "k3s-install"'*) log "prepare-host: ${1}'s install record ${dst} lists k3s-install." ;;
    *) error "prepare-host: k3s is set up, but ${1}'s install record ${dst} could not be written, and their install adopts k3s by it. Check that 'sudo -u ${1} true' works, then re-run prepare-host." ;;
  esac
}

# _native_k3s_prepare_host USER -- prepare-host on native k3s: an
# administrator sets k3s up once FOR the daily user USER, who then installs tracebloc
# with no administrator rights. It refuses before anything is written unless USER is
# a user of this machine other than root, with a home, whose own data does not say
# they run tracebloc on k3d (refuse_k3d_for_user, D10). It runs step b's privileged
# half and the whole of step c as the administrator, with k3s.yaml and config.yaml
# granted to the prepared group (mode 0640) and USER added to it first, and writes
# USER's two records: their own copy, as them, and the root copy. It never installs
# helm or the tracebloc release, never mints a credential, and never touches the
# administrator's kubeconfig or record.
_native_k3s_prepare_host() {
  local user="${1:-}" pw home made=false
  [[ -n "$user" ]] \
    || error "prepare-host on native k3s sets k3s up for one named user, and none was named. Name them: export TRACEBLOC_PREPARE_USER=<their-username>, then re-run prepare-host."
  pw="$(getent passwd "$user" 2>/dev/null)" || pw=""
  [[ -n "$pw" ]] \
    || error "prepare-host: '${user}' is not a user on this machine (getent passwd ${user}). Name the user who will run tracebloc, then re-run."
  [[ "$user" != root && "$(printf '%s' "$pw" | cut -d: -f3)" != 0 ]] \
    || error "prepare-host sets k3s up for a daily user, never for root, and '${user}' is root (uid 0). Name the user who will run tracebloc."
  home="$(printf '%s' "$pw" | cut -d: -f6)"
  [[ "$home" == /* && -d "$home" ]] \
    || error "prepare-host: ${user}'s home directory '${home}' does not exist, and their install record goes there. Create it, then re-run prepare-host."
  _native_k3s_refuse_host
  # The data dir is the named user's: the record names it, and the leftover guard
  # scans it. An administrator's own default is never theirs; a data dir the
  # administrator chose stays their choice of where the volumes live.
  if [[ -z "$(_native_k3s_storage_choice)" ]]; then
    TB_HOST_DATA_DIR_DEFAULT="${home}/.tracebloc"
    host_data_dir="$TB_HOST_DATA_DIR_DEFAULT"
  fi
  # Data found there is the named user's, and prepare-host never deletes it: the
  # leftover guard lists it and offers no wipe (cluster.sh), and --wipe-data is
  # refused here, before anything is written.
  [[ "${leftover_action:-}" != wipe ]] \
    || error "prepare-host never wipes data, and --wipe-data asks it to: tracebloc data in ${host_data_dir} is ${user}'s. ${user} removes it with 'tracebloc delete', or you keep it with --reuse-data; then re-run prepare-host."

  step_header a 1 "Preparing this host for ${user} on native k3s (one-time administrator step)"
  # A corporate CA, trusted before the first download (as main() does for an install).
  if declare -F wire_ca_trust >/dev/null 2>&1; then wire_ca_trust; fi
  # shellcheck disable=SC2034  # consumed cross-file (record.sh's root copy, diagnose.sh)
  INSTALL_TIER=2
  # shellcheck disable=SC2034  # consumed cross-file by diagnose.sh
  INSTALL_TIER_REASON="native-k3s"
  # USER's own files are read as USER, so the password comes first; the k3d check
  # runs before step a writes anything.
  preflight_sudo "set up k3s for ${user}"
  declare -F refuse_k3d_for_user >/dev/null 2>&1 \
    || error "This installer build can't check whether ${user} runs tracebloc on k3d (stale bootstrap), and native k3s is never set up beside it. Re-run: curl -fsSL https://tracebloc.io/i.sh | bash -s -- prepare-host"
  refuse_k3d_for_user "$user" "$home"
  _native_k3s_host_prereqs "set up k3s for ${user}"
  _native_k3s_prepared_group "$user"
  tb_record_for_user "$user" "$home" \
    || error "prepare-host: couldn't make a private directory to build ${user}'s install record in."
  # shellcheck disable=SC2034  # consumed cross-file by record.sh's tb_record_write
  TRACEBLOC_RECORD_ARMED=1
  TB_K3S_PREPARED=1
  # The group, recorded in both of USER's records as soon as they are armed, before
  # k3s. created_by_prepare_host is true only when this run's
  # groupadd made it; a group found already there is false, so delete removes only
  # USER's membership and never a group it cannot prove tracebloc made. An earlier
  # record's line is kept as it is (the writer keys on kind + id + path), so one
  # that said true stays true. A schema without the kind refuses it by name.
  if [[ "${TB_K3S_GROUP_MADE:-}" == 1 ]]; then made=true; fi
  tb_record_write group "$TB_K3S_PREPARED_GROUP" "" "created_by_prepare_host=${made}"
  # The NVIDIA GPU's root half, before k3s first starts, as step b runs it on the
  # full path: the floor, the driver, the toolkit and a CDI spec. The gate runs once
  # the node is Ready (_native_k3s_prepared_finish).
  detect_gpu
  if [[ "${GPU_VENDOR:-}" == nvidia ]]; then _nvidia_gpu_setup; fi
  _native_k3s_create_cluster
  tb_record_write
  _native_k3s_check_user_record "$user" "$home"

  echo ""
  success "Host prepared: k3s is running, and ${user} can install tracebloc with no administrator rights."
  if _gpu_wired; then info "The NVIDIA GPU is set up for k3s; ${user}'s install counts the GPUs."; fi
  info "After a fresh login (so the ${TB_K3S_PREPARED_GROUP} group applies), ${user} runs:"
  echo "    curl -fsSL https://tracebloc.io/i.sh | bash"
  return 0
}
