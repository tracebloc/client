#!/usr/bin/env bash
# =============================================================================
#  preflight-storage.sh — the preflight's disk and storage checks
#
#  The disk a run will write to, graded against PF_MIN_DISK_GB and PF_WARN_DISK_GB
#  (_pf_disk: the macOS node's app root, or native k3s's data path, images and
#  hostPath volumes), and the filesystem the data directory sits on: a network
#  or opaque FUSE filesystem is refused or warned about (_pf_storage_type), and
#  early_data_dir_guard refuses a network data directory before logging starts.
#
#  Moved out of preflight.sh, which keeps the thresholds, the readers these
#  checks call (_pf_free_kb, _pf_nearest_existing, _pf_fstype), the line helpers
#  and run_preflight. Sourced right after preflight.sh. Side-effect-safe to
#  source (function definitions only).
# =============================================================================

_pf_disk() {
  if _pf_on_mac_node; then _pf_disk_mac_node; return 0; fi
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]]; then _pf_disk_k3s; return 0; fi
  # Any other substrate was refused before preflight (tb_substrate_resolve): there is
  # no disk of its to grade.
  return 0
}

# On macOS, native k3s runs in a VM on Apple's runtime (slim client 2.1), and all it
# writes lands under the runtime's app root (mac-container.sh's _mac_ct_app_root): the
# images, the kernel, and the node's volume, a sparse image that takes only what is
# written. That is one disk, graded against the same floors as Linux's
# (PF_MIN_DISK_GB, PF_WARN_DISK_GB). It does not exist before the install, so it is
# measured on its nearest existing parent (_pf_mac_node_disk_at), as the summary line
# measures it. A re-run gets no credit for the images it reuses: nothing has measured
# them on a Mac yet, so the floor counts them as on a fresh one. Without mac-container.sh
# (a stale bootstrap), where the app root is cannot be told, and the line says so.
_pf_mac_node_disk_at() {
  local root at
  declare -F _mac_ct_app_root >/dev/null 2>&1 || return 1
  root="$(_mac_ct_app_root 2>/dev/null)" || return 1
  [[ "$root" == /* ]] || return 1
  at="$(_pf_nearest_existing "$root")"; [[ -n "$at" ]] || at="/"
  printf '%s\t%s' "$at" "$root"
}
# Under hostpath the training data is not in the node's volume but in the hostPath
# folder on this Mac, which the node mounts (_mac_ct_node_mounts): a second line grades
# that folder's disk, as _pf_disk_k3s grades host_data_dir for native k3s's hostpath.
# Under node-local the job data is in the job-data folder (_mac_ct_job_data_dir) when the
# install keeps one, and the second line grades that folder's disk.
_pf_disk_mac_node() {
  local both tab=$'\t' root at
  both="$(_pf_mac_node_disk_at)" \
    || { warn "Disk: couldn't tell where Apple's container runtime will keep the node (skipping)."; return 0; }
  _pf_disk_grade "${both%%"$tab"*}" "the node's images and volume (${both#*"$tab"})"
  # node-local: the job data is in the job-data folder on this Mac.
  if [[ "${TB_STORAGE_MODE:-node-local}" != "hostpath" ]]; then
    root=""
    if declare -F _mac_ct_job_data_dir >/dev/null; then root="$(_mac_ct_job_data_dir)"; fi
    [[ -n "$root" ]] || return 0
    at="$(_pf_nearest_existing "$root")"; [[ -n "$at" ]] || at="/"
    _pf_disk_grade "$at" "the job data (${root})"
    return 0
  fi
  root="$(_hostpath_root)"; root="${root:-${host_data_dir:-}}"
  at="$(_pf_nearest_existing "$root")"; [[ -n "$at" ]] || at="/"
  _pf_disk_grade "$at" "the hostPath volumes (${root})"
}

# Native k3s (TRACEBLOC_SUBSTRATE_RESOLVED=k3s): its disk is two paths, each named in
# the line, against the disk floors (PF_MIN_DISK_GB, PF_WARN_DISK_GB):
#   - k3s's data path (/var/lib/rancher/k3s): the images, containerd and its state;
#   - the storage path, where local-path keeps the volumes: k3s's default under the
#     data path, or the operator's data dir (_native_k3s_storage_path, k3s.sh).
# Neither exists before the install, so each is measured on its nearest existing
# parent, and the line names the directory it measured. Two paths measured on the
# same directory are one disk: one line names both, and the floor is asked once.
#
# On a node-local re-run the storage path is the one config.yaml froze, which only
# root reads.
# This is the first reader of a run and runs in the main shell, so when the reader
# needs the password it asks here, once, through preflight_sudo (whose keepalive the
# install then keeps). A config.yaml that cannot be read refuses: where the volumes
# live is not something to guess.
#
# A re-run of the k3s this installer set up already holds its images, and reuses
# them: the floor is the room a k3s install needs, and those bytes are part of it,
# not a claim on the free space left. So on such a re-run each line on the image
# store's filesystem counts them back (_pf_k3s_reused_kb). Measured on the k3s
# journey: 13 GB free before the first install, 9 to 10 GB at the re-run's
# preflight, where an unchanged re-run pulls nothing ("No change detected").
_pf_disk_k3s() {
  local data="$TB_K3S_DATA_PATH" storage at_data at_storage rc=0 reused store_at why=""
  # hostpath: the volumes are the chart's hostPath PVs under
  # host_data_dir (an installed release's own root, _hostpath_root), so that is the
  # disk the training data needs. The storage path config.yaml names holds none of
  # it, so config.yaml is not read at all: a file this check then ignores must not
  # refuse the run, or ask for the password. Its drift is no news
  # here either. rc stays 0, so the reader's branches below are node-local's.
  if [[ "${TB_STORAGE_MODE:-node-local}" == "hostpath" ]]; then
    storage="$(_hostpath_root)"; storage="${storage:-${host_data_dir:-}}"
  else
    storage="$(_native_k3s_storage_path)" || rc=$?
  fi
  if [[ "$rc" -eq 4 ]]; then
    # A host prepared for this user that cannot be adopted yet (1.1g): a password
    # would end in preflight_sudo's prompt, and is not what is missing. A person
    # reads what is, and its way forward, in the end block (_native_k3s_prepared_reason);
    # the log keeps the reason with the prepare-host remedy.
    why="$(_native_k3s_prepared_for_me)" || true
    _pf_detail _pf_fail_line "Disk: where this machine's k3s keeps its volumes is in ${TB_K3S_CONFIG_PATH}, which you cannot read yet."
    PF_HARD_FAIL=$(( ${PF_HARD_FAIL:-0} + 1 ))
    _pf_detail hint "$(_native_k3s_prepare_host_remedy "$why")"
    _pf_person disk ✖ "Can't read this machine's k3s settings yet" \
      "$(_native_k3s_prepared_reason "$why" next)" "$(_native_k3s_prepared_reason "$why" cmd)"
    return 0
  fi
  if [[ "$rc" -eq 3 ]]; then
    preflight_sudo
    rc=0; storage="$(_native_k3s_storage_path)" || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    _pf_fail_line "Disk: couldn't read ${TB_K3S_CONFIG_PATH}, so where this machine's k3s keeps its volumes can't be told."
    PF_HARD_FAIL=$(( ${PF_HARD_FAIL:-0} + 1 ))
    hint "Check it with 'sudo cat ${TB_K3S_CONFIG_PATH}', then re-run."
    return 0
  fi
  if [[ "${TB_STORAGE_MODE:-node-local}" != "hostpath" ]]; then
    _native_k3s_storage_drift_warn
  fi
  at_data="$(_pf_nearest_existing "$data")"; [[ -n "$at_data" ]] || at_data="/"
  at_storage="$(_pf_nearest_existing "$storage")"; [[ -n "$at_storage" ]] || at_storage="/"
  reused="$(_pf_k3s_reused_kb)"; store_at=""
  # The store's disk is read as root, like its size: k3s creates its agent/ directory
  # 0700 (pkg/agent/run.go, MkdirAll(agentDir, 0700)), so this user's df cannot reach
  # the store below it, and the credit came out 0 on every re-run.
  # A df that fails leaves store_at empty (no credit); as the last command of a && list
  # its status would abort the installer under set -e, so the || keeps it fail-closed.
  if [[ "$reused" -gt 0 ]]; then
    store_at="$(_pf_mount_of "${TB_K3S_DATA_PATH}/agent/containerd" sudo)" || store_at=""
  fi
  if [[ "$at_data" == "$at_storage" ]]; then
    _pf_disk_grade "$at_data" "k3s's data (${data}) and the training data (${storage})" "$(_pf_k3s_credit_on "$at_data" "$store_at" "$reused")"
  else
    _pf_disk_grade "$at_data" "k3s's data (${data})" "$(_pf_k3s_credit_on "$at_data" "$store_at" "$reused")"
    _pf_disk_grade "$at_storage" "the training data (${storage})" "$(_pf_k3s_credit_on "$at_storage" "$store_at" "$reused")"
  fi
  return 0
}

# _pf_k3s_reused_kb -- on a re-run of the k3s this installer set up, the KB its image
# store holds (TB_K3S_DATA_PATH/agent/containerd, which the re-run reuses); 0 otherwise.
# "Set up by this installer" is the install record listing `k3s-install`. The credit
# is given only when it is known: no record, a record that cannot be read, a root that
# cannot answer without a prompt, or a store du cannot measure all give 0, and the
# floor then counts the store as on a fresh host (fail closed). A user on a host
# prepared for them (1.1g) gets 0 the same way, on purpose: the store sits below
# k3s's 0700 agent/, so only root can measure it, and prepared mode asks for no root.
_pf_k3s_reused_kb() {
  local rec kb
  rec="$(tb_record_path)"
  if [[ ! -f "$rec" || ! -r "$rec" ]] || ! grep -qF '"kind": "k3s-install"' "$rec" 2>/dev/null; then
    echo 0; return 0
  fi
  _native_k3s_root_ready || { echo 0; return 0; }
  kb="$(sudo du -sxk "${TB_K3S_DATA_PATH}/agent/containerd" 2>/dev/null | awk 'NR==1 {print $1}')"
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  echo "$kb"
}

# _pf_mount_of DIR [CMD...] -- the mount point of the filesystem holding DIR (POSIX df),
# so two directories can be told to share a disk; empty when df cannot answer. CMD
# (sudo) runs the df, for a directory only root can reach.
_pf_mount_of() { local d="$1"; shift; "$@" df -Pk "$d" 2>/dev/null | awk 'NR==2 {print $6}'; }

# _pf_k3s_credit_on DIR STORE_MOUNT KB -- KB when DIR is on the image store's
# filesystem, else 0. An unknown mount on either side is 0: the credit is not guessed.
_pf_k3s_credit_on() {
  local m
  [[ "$3" -gt 0 && -n "$2" ]] || { echo 0; return 0; }
  m="$(_pf_mount_of "$1")"
  if [[ -n "$m" && "$m" == "$2" ]]; then echo "$3"; else echo 0; fi
}

# _pf_disk_grade DIR WHAT [REUSED_KB] -- one disk line: the free space on DIR, which
# will hold WHAT, graded against the Linux floors. REUSED_KB, the images a re-run of
# this installer's k3s already holds on DIR's disk, counts as free, and the line says so.
_pf_disk_grade() {
  local at="$1" what="$2" reused="${3:-0}" free_kb free_gb rq ru=GB
  free_kb="$(_pf_free_kb "$at")"
  if [[ -z "$free_kb" ]]; then warn "Disk: couldn't determine free space on ${at} for ${what} (skipping)."; return 0; fi
  if [[ "$reused" -gt 0 ]]; then
    free_kb=$(( free_kb + reused ))
    rq=$(( reused / 1024 / 1024 )); [[ "$rq" -gt 0 ]] || { rq=$(( reused / 1024 )); ru=MB; }
    what="${what}, counting the ${rq} ${ru} of images this k3s already holds, which the re-run reuses"
  fi
  free_gb=$(( free_kb / 1024 / 1024 ))
  if [[ "$free_gb" -lt "$PF_MIN_DISK_GB" ]]; then
    _pf_detail _pf_fail_line "Disk: only ${free_gb} GB free on ${at} for ${what} — need ≥ ${PF_MIN_DISK_GB} GB."
    PF_HARD_FAIL=$(( ${PF_HARD_FAIL:-0} + 1 ))
    _pf_detail hint "Free up space or attach a larger disk, then re-run."
    _pf_person disk ✖ "${free_gb} GB free disk · tracebloc needs ${PF_MIN_DISK_GB} GB" "Free up disk space, then run the installer again:"
  elif [[ "$free_gb" -lt "$PF_WARN_DISK_GB" ]]; then
    _pf_detail warn "Disk: ${free_gb} GB free on ${at} for ${what} — recommended ≥ ${PF_WARN_DISK_GB} GB; images + data may fill it."
    _pf_person disk ⚠ "Low disk space · tracebloc recommends ${PF_WARN_DISK_GB} GB free"
  else
    _pf_ok "Disk: ${free_gb} GB free on ${at} for ${what}"
  fi
  return 0
}

# The network-filesystem classification shared by the full storage check and
# the pre-log early_data_dir_guard. Everything listed corrupts or
# crash-loops MySQL/InnoDB (broken POSIX locking, unsafe O_DIRECT/fsync).
#
# The name is NORMALISED before matching, so the list carries BARE names only and
# a FUSE filesystem can never fall through it for want of a spelling. A FUSE mount
# reaches us spelled either way, depending on which reader in _pf_fstype answered:
# findmnt and mount(8) report the libfuse SUBTYPE (`fuse.sshfs`), so the list used
# to carry `fuse.`-prefixed entries — but half of them had no bare twin, which is
# the shape that regrows this bug. Strip the prefix once instead of extending the
# list twice. (Measured on Ubuntu 24.04 / libfuse 3.14 / util-linux 2.39 and
# Ubuntu 20.04 / libfuse 2.9: sshfs and rclone both mount as `fuse.<subtype>`.)
_pf_is_network_fstype() {
  local t
  t="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  t="${t#fuse.}"                       # fuse.sshfs -> sshfs; nfs4 -> nfs4
  case "$t" in
    nfs|nfs3|nfs4|nfsd|cifs|smb|smbfs|smb2|smb3|afpfs|9p|ncpfs|gfs|gfs2|ocfs2|lustre|glusterfs|ceph|beegfs|sshfs|s3fs|gcsfuse|blobfuse|blobfuse2|davfs|webdav|rclone) return 0 ;;
    # AN UNRECOGNISED FUSE SUBTYPE IS NOT EVIDENCE OF LOCAL STORAGE 
    # `fuse.gcsfuse` and `fuse.blobfuse2` are named above now, but the
    # list can only ever hold the drivers someone thought of -- and the next
    # cloud FUSE ships without asking us. Before this, `fuse.<anything else>`
    # stripped to a name nobody matched and fell through to a confident
    # "Local storage", which is the failure mode this predicate exists to
    # prevent, one subtype at a time.
    #
    # Returning 1 ("not network") is still right -- we have no evidence it IS
    # network, and a hard fail on a local ntfs-3g would be worse. The caller
    # asks `_pf_is_opaque_fuse_fstype` next, which now claims this shape and
    # warns, so an unknown FUSE reads as unknown rather than as local.
    *) return 1 ;;
  esac
}

# FUSE with the subtype ERASED: the mount table says "this is FUSE" without saying
# WHICH FUSE, so sshfs/s3fs/rclone (fatal for the database) is indistinguishable
# from a local ntfs-3g/gocryptfs/bindfs (fine). This is not an edge case — two of
# _pf_fstype's three readers produce ONLY this shape, so _pf_is_network_fstype above
# never sees a name it can classify:
#   * `stat -f -c %T` — the Linux fallback when findmnt is missing — answers
#     `fuseblk` for EVERY fuse mount (the fuse and fuseblk kernel filesystems share
#     one magic number). Measured: sshfs, rclone AND bindfs all read back `fuseblk`.
#   * macOS has no findmnt and skips the stat reader (BSD `stat -f` is a format
#     string), so the df+mount path answers with the macFUSE vfs name — `macfuse`,
#     or `osxfuse` before 4.x — never a `fuse.*` subtype.
#   * A FUSE program that sets no subtype mounts as bare `fuse` even under findmnt
#     (measured with bindfs; libfuse only defaults the subtype to the program name).
# Callers WARN rather than refuse: refusing every unnamed FUSE mount would block a
# legitimate local one, and TRACEBLOC_ALLOW_NETWORK_FS reads as nonsense advice to
# someone who is not on a network filesystem.
_pf_is_opaque_fuse_fstype() {
  local t
  t="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    fuse|fuseblk|macfuse|osxfuse|osxfusefs) return 0 ;;
    # A NAMED SUBTYPE WE DO NOT KNOW `fuse.gcsfuse` used to
    # be neither network (not on the list) nor opaque (not bare `fuse`), so it
    # reached the `else` and was announced as "Local storage" -- a confident
    # answer about a mount we could not identify.
    #
    # THE TWO PREDICATES STAY MUTUALLY EXCLUSIVE, which the bats suite asserts and which
    # is worth more than it looks: without the negation below, `fuse.sshfs` would satisfy
    # BOTH, and the only thing keeping it a hard fail rather than a warning would be the
    # order the caller happens to ask in. A future caller asking "opaque?" first would
    # silently downgrade a database-corrupting mount to a notice. Excluding the names the
    # network classifier claims makes the correct answer independent of call order.
    fuse.*) _pf_is_network_fstype "$t" && return 1; return 0 ;;
    *) return 1 ;;
  esac
}

# The shared advisory for an opaque FUSE mount (see above): say what we can and
# cannot tell, and let the install continue. $1 = path, $2 = fstype as read.
_pf_opaque_fuse_warn() {
  # TWO DIFFERENT UNKNOWNS, AND SAYING THE WRONG ONE IS A FALSE STATEMENT
  # The original line — "the mount table doesn't say which
  # one" — is true for `fuse`/`fuseblk`, where the subtype really is erased. It
  # would be a lie for `fuse.gocryptfs`, where the table says exactly which one
  # and the gap is that WE have no opinion on it. Same advice, honest premise.
  case "$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')" in
    fuse.*) warn "Storage: ${1} is on a FUSE filesystem (${2}) — a driver this check does not recognise." ;;
    *)      warn "Storage: ${1} is on a FUSE filesystem (${2}) — the mount table doesn't say which one." ;;
  esac
  hint "If it is network-backed (sshfs, s3fs, rclone, a cloud-sync mount), the secure environment's database (MySQL/InnoDB) can corrupt or crash-loop — move TRACEBLOC_HOST_DATA_DIR to a local disk under your \$HOME."
  hint "If it is a local FUSE mount (ntfs-3g, gocryptfs, bindfs), this is only a notice — the install continues."
}

# The FOLLOWABLE remedy for a network-filesystem host_data_dir. validate_config
# requires the data dir UNDER $HOME (security), so "set TRACEBLOC_HOST_DATA_DIR to
# ~/.tracebloc" is un-followable on a network HOME — that path is still NFS. Name the
# options that actually work. Shared by _pf_storage_type and early_data_dir_guard so
# the two remedies can never drift (early_data_dir_guard already had the good text).
_pf_network_fs_remedy() {
  hint "TRACEBLOC_HOST_DATA_DIR must be a LOCAL disk under your \$HOME (paths outside \$HOME are rejected), so on a network home either:"
  hint "  1. install as a user whose home is on a local disk (ask your admin), or"
  hint "  2. set TRACEBLOC_ALLOW_NETWORK_FS=1 to proceed anyway - NOT recommended: the database can corrupt."
  hint "(Datasets may stay on network storage via TRACEBLOC_HOST_DATASET_DIR - only the data dir must be local.)"
}

# Pre-log guard: main() creates host_data_dir and tees the session log
# onto it (setup_log_file) BEFORE run_preflight fires — on an NFS home under
# sudo + root_squash that unguarded mkdir fails with a bare error (or the log
# dir lands squashed/nobody-owned) before _pf_storage_type below can print its
# friendly, named failure. Same classification, run first, output only on
# failure. TRACEBLOC_ALLOW_NETWORK_FS defers to the full check's warning.
#
# Native k3s under node-local judges the directory _pf_storage_type judges, the
# storage path, where its database lives (under hostpath, host_data_dir): an NFS home with k3s's default storage holds only logs and
# config, so it passes here as it passes there. When reading the storage path
# needs a password (or cannot answer), this pre-log guard defers to the full check,
# which asks and refuses by name. What k3s gives up: a root login whose own home is
# on a root_squash NFS gets mkdir's bare error instead of this one (a sudo-wrapped
# run is refused before this point, refuse_sudo_wrapped_install).
early_data_dir_guard() {
  local target fstype
  target="${host_data_dir:-${HOME:-}/.tracebloc}"
  [[ -n "${TRACEBLOC_ALLOW_NETWORK_FS:-}" ]] && return 0
  # hostpath keeps the database under host_data_dir on native k3s too.
  # The macOS node keeps its data in its own volume, so the directory created here is
  # host_data_dir (_pf_storage_type checks where the volume lives).
  if [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "${TB_STORAGE_MODE:-node-local}" == "node-local" ]] && ! _pf_on_mac_node; then
    target="$(_native_k3s_storage_path)" || return 0
  fi
  # An EXISTING data dir has no at-risk mkdir here, and a healthy machine's
  # re-run must keep reaching the assess hand-off exactly as it did when this
  # check lived only in run_preflight. The full preflight guard
  # below still classifies network storage for actual (re)installs.
  [[ -d "$target" ]] && return 0
  fstype="$(_pf_fstype "$target")"
  [[ -z "$fstype" ]] && return 0                 # undetermined — assume local
  if ! _pf_is_network_fstype "$fstype"; then
    # Opaque FUSE (`fuseblk`, `macfuse`): we cannot name it, so we must not refuse
    # — but staying silent is what let an sshfs data dir through on every reader
    # that erases the subtype. Say so and continue; the full check repeats it once
    # logging is up. (Explicit `if`, not `a && b`: under set -e a false `&&` chain
    # here would decide the function's exit status.)
    if _pf_is_opaque_fuse_fstype "$fstype"; then _pf_opaque_fuse_warn "$target" "$fstype"; fi
    return 0
  fi
  warn "Storage: ${target} is on a network filesystem (${fstype})."
  hint "The secure environment's database (MySQL/InnoDB) corrupts or crash-loops on network storage, and NFS root_squash blocks data-dir setup."
  _pf_network_fs_remedy   # shared followable remedy
  error "Refusing to create the data directory on ${fstype} before logging starts."
}

# Network-filesystem guard for host_data_dir. MySQL/InnoDB corrupts or crash-loops
# on NFS/CIFS/SMB (broken POSIX locking + unsafe O_DIRECT/fsync), and the chart's
# root chown init-container is blocked by NFS root_squash — so a network data dir
# fails ~20 min in with a cryptic CrashLoopBackOff. Catch it in seconds here.
_pf_storage_type() {
  local target fstype disp tab=$'\t'
  target="${host_data_dir:-$HOME/.tracebloc}"
  # Native k3s keeps the database in a local-path volume, under the storage path, so that
  # is the directory that must be local. _pf_disk_k3s has already read it (and refused
  # when it could not: PF_HARD_FAIL is raised and run_preflight stops), so a failure here
  # adds nothing (preflight.bats pins it). Under hostpath the database is the chart's
  # hostPath PV under host_data_dir , so host_data_dir is the directory judged -- on
  # native k3s an installed release's own root (_hostpath_root). The macOS node keeps it
  # in the node's volume, a sparse image under the runtime's app root, so that directory
  # must be local: measured where the disk line measures it, and when that cannot be told
  # the disk line has already said so. Under hostpath it is in the hostPath folder on this
  # Mac, which the node mounts, judged as on native k3s.
  if _pf_on_mac_node && [[ "${TB_STORAGE_MODE:-node-local}" != "hostpath" ]]; then
    target="$(_pf_mac_node_disk_at)" || return 0
    target="${target%%"$tab"*}"
  elif [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && "${TB_STORAGE_MODE:-node-local}" == "node-local" ]]; then
    target="$(_native_k3s_storage_path)" || return 0
  elif [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" && -n "$(_hostpath_root)" ]]; then
    target="$(_hostpath_root)"
  fi
  disp="$target"
  if [[ -n "${HOME:-}" && "$disp" == "$HOME"* ]]; then disp="~${disp#"$HOME"}"; fi
  fstype="$(_pf_fstype "$target")"
  if [[ -z "$fstype" ]]; then
    log "Storage: ${disp} — filesystem type undetermined; assuming local."
    success "Local storage available"
    return 0
  fi
  if _pf_is_network_fstype "$fstype"; then
      if [[ -n "${TRACEBLOC_ALLOW_NETWORK_FS:-}" ]]; then
        warn "Storage: ${target} is on a network filesystem (${fstype}) — proceeding (TRACEBLOC_ALLOW_NETWORK_FS set); the secure environment's database may corrupt or crash-loop on network storage."
        return 0
      fi
      _pf_fail_line "Storage: ${target} is on a network filesystem (${fstype}) — the secure environment's database (MySQL/InnoDB) corrupts or crash-loops on network storage, and NFS root_squash blocks data-dir setup."
      PF_HARD_FAIL=$(( ${PF_HARD_FAIL:-0} + 1 ))
      # The old remedy suggested TRACEBLOC_HOST_DATA_DIR=$HOME/.tracebloc — but on a network HOME
      # that's still NFS, and validate_config rejects paths OUTSIDE $HOME, so it could
      # never work. Use the shared followable remedy.
      _pf_network_fs_remedy
  elif _pf_is_opaque_fuse_fstype "$fstype"; then
      # FUSE, subtype unknown — advisory, never a hard fail (see the predicate).
      log "Storage: ${target} (${fstype})"
      _pf_opaque_fuse_warn "$target" "$fstype"
  else
      log "Storage: ${disp} (${fstype})"
      success "Local storage available"
  fi
  # datasets MAY live on a network mount (HOST_DATASET_DIR) — only
  # the database dir (host_data_dir, checked above) must be local. Note it, never fail.
  if [[ -n "${HOST_DATASET_DIR:-}" ]]; then
    local dfstype; dfstype="$(_pf_fstype "$HOST_DATASET_DIR")"
    info "Dataset dir: ${HOST_DATASET_DIR}${dfstype:+ (${dfstype})} — network mounts are supported here (the database stays on local disk)."
  fi
  return 0
}
