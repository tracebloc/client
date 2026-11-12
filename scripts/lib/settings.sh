#!/usr/bin/env bash
# =============================================================================
#  settings.sh — the installer's settings: has(), the launch path and PATH
#  hardening, the TRACEBLOC_ tuning aliases and stage, the cluster name, storage
#  mode, pins, floors, Helm and prepull defaults, the host data dir, the settings
#  no longer read, and validate_config. Sourced by install-k8s.sh, first.
# =============================================================================
has() { command -v "$1" &>/dev/null; }   # has CMD: CMD is on PATH. First, so every module has it

# ── Security hardening ───────────────────────────────────────────────────────
# The launching shell's PATH, read before the prepend below (install.sh sets it first on the
# curl|bash path; this covers install-k8s.sh run directly). See install-cli.sh _cli_on_launch_path.
# A bootstrap older than this file never set it, and has already put ~/.local/bin in
# front of PATH: that entry is the installer's, not the user's, so it is dropped from
# the capture. The cost is one conservative "open a new terminal" for a user whose
# own PATH starts with ~/.local/bin and who pairs a stale bootstrap with these libs.
TRACEBLOC_LAUNCH_PATH="${TRACEBLOC_LAUNCH_PATH:-}"
if [[ -z "$TRACEBLOC_LAUNCH_PATH" ]]; then
  TRACEBLOC_LAUNCH_PATH="${PATH:-}"
  TRACEBLOC_LAUNCH_PATH="${TRACEBLOC_LAUNCH_PATH#"${HOME}/.local/bin:"}"
fi
export TRACEBLOC_LAUNCH_PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
# In a bats run only, the suite's sudo fence goes back in front of the directories
# just prepended. Behind them, a case that dropped its own sudo stub would run the
# host's sudo (scripts/tests/setup_suite.bash). An install never sets either.
if [[ -n "${TRACEBLOC_HERMETIC_SUDO_BIN:-}" && -n "${BATS_SUITE_TMPDIR:-}" ]]; then
  export PATH="${TRACEBLOC_HERMETIC_SUDO_BIN}:${PATH}"
fi
umask 077

# ── Settings naming: the TRACEBLOC_ spellings of the tuning knobs ────────────
# Every timeout, wait and bound below can be set as
# TRACEBLOC_<name> -- the TB_ prefix REPLACED (TB_PULL_TIMEOUT ->
# TRACEBLOC_PULL_TIMEOUT), an unprefixed name prefixed (SIGN_IN_ATTEMPTS ->
# TRACEBLOC_SIGN_IN_ATTEMPTS). The old spelling still works (remove_by 2026-12-31).
# A non-empty canonical is copied, ONCE and here at the top of the core, into
# the legacy-named variable every reader across scripts/lib reads inline
# (`${TB_PULL_TIMEOUT:-600}`), so those dozens of reads, their defaults and
# their blank-means-default behaviour are unchanged; a blank canonical is unset.
# Nothing here is exported, so no child sees a value its parent did not.
tb_tuning_aliases=(
  TB_API_WAIT_S
  TB_ASSESS_KUBECTL_TIMEOUT TB_CLI_MIN_VERSION TB_CLI_PROBE_TIMEOUT TB_CLI_VERSION_TIMEOUT
  TB_CURL_CONNECT_TIMEOUT
  TB_GPU_CDI_TIMEOUT TB_GPU_PROFILER_TIMEOUT
  TB_HELM_LIST_TIMEOUT TB_HELM_TIMEOUT_MIN TB_HELM_VALUES_TIMEOUT TB_INSTALL_CMD
  TB_K3S_CRI_TIMEOUT TB_K3S_INSTALL_SH_TIMEOUT
  TB_METRICS_WAIT_S
  TB_PM_KILL_GRACE TB_PROBE_TIMEOUT
  TB_PROGRESS_KUBECTL_TIMEOUT TB_PULL_TIMEOUT
  TB_WSL_INTEROP_KILL_AFTER TB_WSL_INTEROP_TIMEOUT
  GPU_DEVICE_PLUGIN_NAMESPACE SIGN_IN_ATTEMPTS
)
# tb_canonical_name LEGACY -- the TRACEBLOC_ spelling the naming rule gives.
tb_canonical_name() {
  case "$1" in
    TB_*) printf 'TRACEBLOC_%s' "${1#TB_}" ;;
    *)    printf 'TRACEBLOC_%s' "$1" ;;
  esac
}
# tb_resolve_tuning_aliases -- copy each non-empty canonical onto its legacy name.
tb_resolve_tuning_aliases() {
  local _legacy _canon
  for _legacy in "${tb_tuning_aliases[@]}"; do  # set-u-safe: a literal list, declared just above
    _canon="$(tb_canonical_name "$_legacy")"
    if [[ -n "${!_canon:-}" ]]; then printf -v "$_legacy" '%s' "${!_canon}"; fi
  done
}
tb_resolve_tuning_aliases

# tb_client_env — TRACEBLOC_ENV reduced to the canonical dev|stg|prod.
#
# The chart, client-runtime and this installer all key on dev|stg|prod, while
# values.schema.json documents development|staging|production as accepted
# aliases. Every consumer must reduce through here rather than matching the raw
# value, because a `case`
# that knows only dev|stg with a `*)` catch-all sends a documented alias to the
# PROD branch silently.
#
# That is not hypothetical here. `_backend_url` feeds verify_credentials(),
# so a `TRACEBLOC_ENV=staging` install validated the customer's STAGING client
# credentials against the PRODUCTION backend and told them their correct
# credentials were wrong.
#
# The ambient stage is TRACEBLOC_ENV alone, blank meaning absent; no other
# name is read. An explicit $1 (even "") still wins outright, so a caller that
# has already resolved its own value (e.g. from a values-file read) is unaffected.
#
# Unknown values pass through unchanged: this normalises spellings, it does not
# validate. Each caller keeps its own fallback for genuinely unrecognised input.
tb_client_env() {
  local raw
  if [ "$#" -ge 1 ]; then
    raw="$1"
  else
    raw="${TRACEBLOC_ENV:-}"
  fi
  case "$raw" in
    development) printf 'dev'  ;;
    staging)     printf 'stg'  ;;
    production)  printf 'prod' ;;
    *)           printf '%s' "$raw" ;;
  esac
}

# _refuse_invalid_cluster_name NAME -- validate_config's refusal of a cluster name
# outside the rule: a letter, then [a-zA-Z0-9._-], 63 characters at most.
_refuse_invalid_cluster_name() {
  [[ "${1:-}" =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,62}$ ]] \
    || error "TRACEBLOC_CLUSTER_NAME must start with a letter, contain only [a-zA-Z0-9._-], max 63 chars (got '${1:-}')"
}

# Strip ANSI escape sequences and C0 control characters from a value. A raw
# `read` captures whatever the terminal sends — this can include:
#   • bracketed-paste wrappers:  ESC[200~ ... ESC[201~
#   • arrow keys / cursor moves: ESC[A/B/C/D, ESC[1;5C, ESC[3~ (Delete), …
#   • function keys, modifier combos, mode-switch sequences
# Two shapes carry all of those:
#   CSI  ESC '[' <params ∈ [0-9;]> <final ∈ [A-Za-z~]>
#   SS3  ESC 'O' <final ∈ [A-Za-z~]>   — ESC OA/OB/OC/OD, ESC OH/OF, ESC OP…OS
# SS3 is what the SAME keys emit once the terminal is in DECCKM
# application-cursor mode, the state vim/less/tmux leave behind on an unclean
# exit. It was the hole left by the CSI-only fix of 2026-07-21
# : ESC is dropped as a C0 byte but 'O' and the final byte
# are printable, so ESC OD ESC OA survived as the plausible name "ODOA" and
# minted a permanent namespace — where CSI residue cleans to empty and re-prompts.
# Strip iteratively to handle consecutive sequences (e.g. paste-wrappers).
#
# Also handles the post-corruption case where ESC was stripped by an earlier
# (buggy) sanitizer but the literal `[200~`/`[201~` markers survived. Only
# self-heals the two well-defined bracketed-paste markers — generic `[X]`
# shapes could plausibly be real password content.
#
# UTF-8 bytes (0x80+) preserved so international characters survive. Lives here
# (shared) so BOTH the credential path (install-client-helm.sh) and the client-
# name prompt (provision.sh) sanitize identically (customer-reported 2026-07-20).
# Mirrored by cli/internal/cli/sanitize.go and install-wsl.ps1's
# ConvertTo-SanitizedInput — change all three together.
_strip_paste_garbage() {
  local s="$1"
  local esc=$'\e'
  local esc_pattern="${esc}(\\[[0-9;]*|O)[A-Za-z~]"
  while [[ "$s" =~ $esc_pattern ]]; do
    s="${s/${BASH_REMATCH[0]}/}"
  done
  s="${s//\[200\~/}"
  s="${s//\[201\~/}"
  # The floor. The loop above knows CSI, SS3 and the paste markers; it cannot
  # know the escape family nobody has reported yet — and that is exactly how SS3
  # got here, one rule hand-copied into three languages with only CSI ever
  # tested. So if an ESC SURVIVED the loop, this value carries a shape we do not
  # recognise and its printable bytes are not trustworthy content. Require one
  # alphanumeric that did not come from an escape final byte, probing with ESC +
  # intermediates + AT MOST TWO final-class bytes. Two, not one and not
  # unbounded: one leaves the 'D' of an unrecognised SS3-shaped pair behind and
  # the floor stops firing on the very shape this is about, while unbounded
  # swallows a whole ASCII name (ESC N C h e l l o) yet spares a non-Latin one,
  # making keep-vs-reject depend on the script the name is written in. An escape final is one byte, an intro plus a final is two, and every
  # keyboard-input escape family fits in that. The probe's output is only a
  # yes/no — it is never returned. Nothing but residue ⇒ emit empty, which every
  # caller already treats as "no answer" (re-prompt, or auto-name in the CLI).
  if [[ "$s" == *"$esc"* ]]; then
    # `sed`, NOT the `while [[ =~ ]]; do s="${s/$BASH_REMATCH/}"` loop the strip
    # above uses. Pattern substitution treats BASH_REMATCH as a GLOB, and this
    # pattern — unlike the CSI one, whose match can never contain `]` — can match
    # a complete bracket expression: on ESC [ ; ] A the regex matches the whole
    # thing, the glob `<ESC>[;]A` then means ESC ';' 'A', which is NOT in the
    # string, the substitution removes nothing, and the loop never terminates.
    # That is a hang at the installer's name prompt. One sed pass has no glob
    # semantics and no loop.
    #
    # And "alphanumeric" via tr, not `=~ [[:alnum:]]`: bash's regex engine is
    # locale-dependent, and under the C locale the installer often runs in,
    # [[:alnum:]] does not match a UTF-8 letter — which would auto-name a
    # perfectly good "日本" the moment an unknown escape sat next to it. Keeping
    # every byte >= 0x80 makes "is there real content here" locale-independent
    # and matches what the strip itself already preserves.
    local probe
    probe="$(printf '%s' "$s" | LC_ALL=C sed -E "s/${esc}[^A-Za-z0-9~]*[A-Za-z~]{1,2}//g" | LC_ALL=C tr -dc '0-9A-Za-z\200-\377')"
    if [[ -z "$probe" ]]; then
      printf ''
      return 0
    fi
  fi
  printf '%s' "$s" | tr -d '\000-\037\177'
}

# ── Configuration (overridable via env) ──────────────────────────────────────
# Settings naming: every knob in this block is set by its TRACEBLOC_ name, resolved
# ONCE, here, into the shorter variable the rest of the installer reads and
# re-assigns (flags, validation, the node-local forcing), so a flag still beats the
# environment. A knob read as `X="${TRACEBLOC_X:-}"` takes the canonical alone and
# overwrites an inherited X; one read as `if [[ -n "${TRACEBLOC_X:-}" ]]` still
# takes its older spelling when the canonical is unset or blank. None is exported.
cluster_name="${TRACEBLOC_CLUSTER_NAME:-}"
cluster_name="${cluster_name:-tracebloc}"
# The secure-environment name (= the Helm release and the k8s namespace):
# TRACEBLOC_NAMESPACE alone, blank meaning unset, resolved into namespace, which
# sanitising, adopting an existing release and provisioning re-assign. Empty, each
# reader keeps its own default. Where the installer hands the name on it exports the
# decided value as the canonical (tb_export_namespace), never a stale one the user set.
namespace="${TRACEBLOC_NAMESPACE:-}"

# Settings this installer no longer reads: TRACEBLOC_SERVERS and TRACEBLOC_AGENTS
# were node counts for a runtime it no longer sets up, and native k3s runs one node;
# TRACEBLOC_K3D_VERSION pinned that runtime's version. validate_config names each one
# that is set, with tb_ignored_setting_reason's why (tb_say_ignored_settings), so a
# value nobody reads is never dropped without a word.
TB_IGNORED_SETTINGS="TRACEBLOC_SERVERS TRACEBLOC_AGENTS TRACEBLOC_K3D_VERSION"
# The leftover-data guard's non-interactive answer (cluster.sh): TRACEBLOC_LEFTOVER_ACTION
# alone. --reuse-data / --wipe-data assign leftover_action after this, so a flag still wins.
leftover_action="${TRACEBLOC_LEFTOVER_ACTION:-}"
# Local dataset storage model. node-local is the DEFAULT, superseding the
# flag-gated prototype. (The flip is gated on a green node-local dev training run
# on the dev environment; that sign-off is not asserted here.)
#   node-local (default, Option C): datasets live on k3s local-path INSIDE the
#                          node — they die with the cluster, are not a
#                          browsable host folder, and need no chmod 777. This is
#                          the goal for the local install. The flip
#                          applies to the bash core, which Windows runs too,
#                          inside tracebloc's WSL distro.
#   hostpath   (opt-out) : the older model — datasets live in ~/.tracebloc on the
#                          host, bind-mounted into the cluster; survive cluster
#                          delete; world-writable dirs. Select with
#                          TRACEBLOC_STORAGE_MODE=hostpath (required for a
#                          TRACEBLOC_HOST_DATASET_DIR network mount).
# Record whether the operator chose the mode or is getting the D15 default: on an
# existing hostpath cluster the mismatch guard refuses an explicit node-local but
# adopts hostpath when node-local is only the default.
TB_STORAGE_MODE="${TRACEBLOC_STORAGE_MODE:-}"
if [[ -n "${TB_STORAGE_MODE:-}" ]]; then TB_STORAGE_MODE_SOURCE="explicit"; else TB_STORAGE_MODE_SOURCE="default"; fi
TB_STORAGE_MODE="${TB_STORAGE_MODE:-node-local}"
# Pinned default; an empty value falls back to this pin (`:-` treats empty and
# unset the same — there is no opt-out to "latest" for k3s).
if [[ -n "${TRACEBLOC_K8S_VERSION:-}" ]]; then K8S_VERSION="$TRACEBLOC_K8S_VERSION"; fi
K8S_VERSION="${K8S_VERSION:-v1.36.5-k3s1}"
# Native k3s: the digests k3s.sh checks its downloads against, and
# the K8S_VERSION they were resolved for (facts.env K3S_BIN_SHA256_* /
# K3S_INSTALL_SH_SHA256 and K8S_VERSION, stamped by check-facts.sh --write). Stamped
# here, not in k3s.sh, because settings.sh is in the signed manifest.
# TB_K3S_PIN_K8S_VERSION is a SECOND stamp of the k3s pin, and it exists because
# K8S_VERSION above takes an environment override: a k3s binary of any other
# version has no digest here, so the native path refuses an override by name
# (k3s.sh::_native_k3s_check_version). No TRACEBLOC_* override on any of the four:
# a digest from the environment could vouch for a download it was never resolved for.
# shellcheck disable=SC2034  # consumed cross-file by k3s.sh
TB_K3S_PIN_K8S_VERSION="v1.36.5-k3s1"
# shellcheck disable=SC2034  # consumed cross-file by k3s.sh
TB_K3S_BIN_SHA256_AMD64="d73847bcd3c5fccef0115b372e2f9a91f3032dc84bbf71518a4617565294d313"
# shellcheck disable=SC2034  # consumed cross-file by k3s.sh
TB_K3S_BIN_SHA256_ARM64="135e34cb9e8a1cfae3cb55577789e93501efe7edc080a8b2630458a85b07721e"
# shellcheck disable=SC2034  # consumed cross-file by k3s.sh
TB_K3S_INSTALL_SH_SHA256="46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad"
# The k3s node image the macOS node pulls, by its linux/arm64 manifest digest at the pinned
# K8S_VERSION (facts.env K3S_IMAGE_ARM64_DIGEST; the image is k3s.sh's
# _native_k3s_image_ref). No TRACEBLOC_* override, for the same reason.
# shellcheck disable=SC2034  # read by the macOS node from 2.1 part 3b
TB_K3S_IMAGE_ARM64_DIGEST="sha256:4ceb591dd1e592b98b7c51ff3bdb7143914e1bee0677e7bf3c4f6addde2c93b3"
# Apple's `container` runtime for the macOS node: the release, the
# package's digest and the Team ID that signs it (facts.env APPLE_CONTAINER_*, stamped
# by check-facts.sh --write). Stamped here, not in mac-container.sh, for the reason the
# k3s pins above are. Not overridable from the environment: a different runtime has
# no digest here. TRACEBLOC_-named (TB_ is a banned prefix), and
# assigned outright, so an exported TRACEBLOC_APPLE_* never reaches a reader.
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_APPLE_CONTAINER_VERSION="1.7.1"
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_APPLE_CONTAINER_PKG_SHA256="b6739caf3d47ca53a78f1a7edf32521420a75c7941838c3cefa75f30b80f5a97"
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_APPLE_CONTAINER_TEAM_ID="UPBK2H6LZM"
# The VM's init image and our kernel, each a repository and a digest (facts.env
# APPLE_VMINIT_IMAGE / _DIGEST and MAC_KERNEL_IMAGE / _SHA256, the same stamping):
# mac-container.sh starts the runtime on them.
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_APPLE_VMINIT_IMAGE="ghcr.io/tracebloc/apple-container-vminit"
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_APPLE_VMINIT_DIGEST="sha256:ab76bf71fbedcbf67a54dc5f37b0acefd68b1ba090d93f752f8e27c9961a685c"
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_MAC_KERNEL_IMAGE="ghcr.io/tracebloc/apple-container-kernel"
# shellcheck disable=SC2034  # consumed cross-file by mac-container.sh
TRACEBLOC_MAC_KERNEL_SHA256="98a1005f8cc395e99b85775b9dce2b239190520b102bf549f4225104dcd7f511"
# The NVIDIA GPU floors (facts.env NVIDIA_DRIVER_FLOOR_LINUX / NVIDIA_COMPUTE_CAP_FLOOR /
# NVIDIA_DRIVER_HARD_FLOOR_LINUX, stamped by check-facts.sh --write). Below the
# compute-capability floor or the hard driver floor (the CUDA 13 minimum) detect-gpu.sh
# leaves the GPU unwired and the install runs CPU-only. The driver floor is the driver
# the installer installs and asks for, never below the hard floor. Policy, so no
# TRACEBLOC_* override.
# shellcheck disable=SC2034  # consumed cross-file by detect-gpu.sh, gpu-nvidia.sh and gpu-plugins.sh
TB_NVIDIA_DRIVER_FLOOR="580"
# shellcheck disable=SC2034  # consumed cross-file by detect-gpu.sh
TB_NVIDIA_DRIVER_HARD_FLOOR="580"
# shellcheck disable=SC2034  # consumed cross-file by detect-gpu.sh
TB_NVIDIA_COMPUTE_CAP_FLOOR="7.5"
# Pinned default; ONLY the literal HELM_VERSION=latest resolves the newest Helm
# release at install time (an empty value falls back to this pin, like
# K8S_VERSION). The tarball is fetched directly from get.helm.sh and verified against
# its published .sha256sum either way (setup-linux.sh) — helm's get-helm-3
# script is NOT used: it floats on the mutable helm/helm@main and needs
# openssl, which minimal cloud images don't ship.
HELM_VERSION="${TRACEBLOC_HELM_VERSION:-}"
HELM_VERSION="${HELM_VERSION:-v4.2.3}"
# The GPU training base image's footprint on a node, in GB (facts.env
# PREPULL_PARENT_DISK_GB, measured; stamped by check-facts.sh --write): what
# summary.sh's training prepull adds to the image store, which its disk rule weighs.
# A measurement, so no TRACEBLOC_* override.
# shellcheck disable=SC2034  # consumed cross-file by summary.sh
TB_PREPULL_PARENT_DISK_GB="11"
# The tabular CPU training image's footprint on a node, in GB (facts.env
# PREPULL_CPU_DISK_GB, measured; stamped by check-facts.sh --write): what summary.sh's
# CPU training prepull adds to the image store. A measurement, so no TRACEBLOC_* override.
# shellcheck disable=SC2034  # consumed cross-file by summary.sh
TB_PREPULL_CPU_DISK_GB="4"
# The data dir: TRACEBLOC_HOST_DATA_DIR alone, resolved into host_data_dir, which
# --data-dir, validate_config's normalisation and the leftover guard re-assign;
# validate_config then exports the decided path (tb_export_host_data_dir).
host_data_dir="${TRACEBLOC_HOST_DATA_DIR:-}"
# The default, named once: native k3s (k3s.sh) reads a data dir other than this
# one as the operator's choice of where the volumes live.
TB_HOST_DATA_DIR_DEFAULT="${HOME:-}/.tracebloc"
host_data_dir="${host_data_dir:-$TB_HOST_DATA_DIR_DEFAULT}"

# tb_export_host_data_dir — export the decided data dir as TRACEBLOC_HOST_DATA_DIR
# alone, as tb_export_namespace does. Its one child reader is the tracebloc CLI,
# which finds the installer's telemetry spool there and reads TRACEBLOC_HOST_DATA_DIR
# first. Every CLI this installer goes on with is at or above the platform's floor
# (require_tracebloc_cli_floor), well past the 0.10.60 that started reading it.
# host_data_dir is this shell's own, never exported; a HOST_DATA_DIR in the
# caller's environment is neither read nor changed.
tb_export_host_data_dir() {
  TRACEBLOC_HOST_DATA_DIR="${host_data_dir:-}"
  export TRACEBLOC_HOST_DATA_DIR
}
# Optional separate host dir for the big DATASET volume. Empty
# (default) keeps datasets under host_data_dir. When set — e.g. a network/NFS
# mount like /data01/tracebloc — the chart's dataset PV points there, while mysql
# + logs stay on the local host_data_dir (InnoDB over NFS is unsafe).
HOST_DATASET_DIR="${TRACEBLOC_HOST_DATASET_DIR:-}"

# ── Input validation ────────────────────────────────────────────────────────
# _tb_system_path DIR -- true when the absolute path DIR is `/` or lies in a system
# tree no install data may live in. ONE list: validate_config refuses host_data_dir
# here, and k3s.sh's renderer refuses the native local-storage path here.
_tb_system_path() {
  case "${1:-}" in
    /|/etc|/etc/*|/usr|/usr/*|/var|/var/*|/bin|/sbin|/lib|/lib64) return 0 ;;
  esac
  return 1
}

# _tb_home_path DIR -- DIR as validate_config reads a data dir: a leading ~ or ~/ is
# $HOME (users type --data-dir=~/foo and the shell does not expand ~ inside a quoted
# value), and a relative path is under $HOME. Empty stays empty. ONE rule: the
# refusals that run before validate_config (_mac_ct_hostpath_dirs,
# _native_k3s_refuse_windows_drive) read host_data_dir through it too, so they judge
# the folder the install will use.
_tb_home_path() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 0
  case "$dir" in
    "~")   dir="$HOME" ;;
    "~/"*) dir="$HOME/${dir#\~/}" ;;
  esac
  [[ "$dir" == /* ]] || dir="$HOME/$dir"
  printf '%s' "$dir"
}

# tb_say_ignored_settings -- one warning for each setting of TB_IGNORED_SETTINGS
# that is set (blank is unset, as for every TRACEBLOC_* setting).
tb_say_ignored_settings() {
  local n
  for n in $TB_IGNORED_SETTINGS; do
    if [[ -n "${!n:-}" ]]; then
      warn "${n} is ignored: $(tb_ignored_setting_reason "$n")."
    fi
  done
}

# tb_ignored_setting_reason NAME -- why this installer does not use NAME, one of
# TB_IGNORED_SETTINGS. Every one has a reason (shared-state.bats); any other name
# has none and returns 1.
tb_ignored_setting_reason() {
  case "$1" in
    TRACEBLOC_SERVERS|TRACEBLOC_AGENTS) printf '%s' "tracebloc runs on this one machine" ;;
    TRACEBLOC_K3D_VERSION) printf '%s' "the installer no longer sets up k3d" ;;
    *) return 1 ;;
  esac
}

# _tb_data_dir_check DIR -- whether DIR can hold this machine's data: a directory under
# $HOME, never $HOME itself, whose parent exists and that is no system path. Sets
# _TB_DATA_DIR to DIR as far as it was resolved (a leading ~ and a $HOME-relative path
# expanded, the parent's links followed) and, when DIR can't be used, _TB_DATA_DIR_WHY to
# empty, parent, root, system, home or outside. validate_config's host_data_dir rule and
# the new-directory prompt (cluster.sh, guard_leftover_data) both read it.
_tb_data_dir_check() {
  local dir="${1:-}" parent
  _TB_DATA_DIR="$dir"; _TB_DATA_DIR_WHY=""
  # Fail closed on an empty value (e.g. --data-dir= with no path) — otherwise the
  # $HOME-relative rewrite below resolves "" to a surprise dir like $HOME/$USER.
  [[ -n "$dir" ]] || { _TB_DATA_DIR_WHY=empty; return 1; }
  # Expand a leading ~ / ~/ and a $HOME-relative path (_tb_home_path): otherwise
  # --data-dir=~/foo is read as the literal "$HOME/~/foo" and fails parent resolution.
  dir="$(_tb_home_path "$dir")"; _TB_DATA_DIR="$dir"
  # Resolve via parent directory — the target itself may not exist yet on first run
  parent="$(cd -P "$(dirname "$dir")" 2>/dev/null && pwd)" || true
  [[ -n "$parent" ]] || { _TB_DATA_DIR_WHY=parent; return 1; }
  dir="$parent/$(basename "$dir")"; _TB_DATA_DIR="$dir"
  [[ "$dir" != "/" ]] || { _TB_DATA_DIR_WHY=root; return 1; }
  ! _tb_system_path "$dir" || { _TB_DATA_DIR_WHY=system; return 1; }
  # Must be strictly UNDER $HOME — never $HOME itself. $HOME is reachable via a
  # bare '~', TRACEBLOC_HOST_DATA_DIR=$HOME, or --data-dir=$HOME; adopting it would make the
  # installer chmod 777 home-level logs/mysql dirs, bind-mount all of $HOME into
  # the cluster, and treat any existing ~/data or ~/mysql as install data.
  [[ "$dir" != "$HOME" ]] || { _TB_DATA_DIR_WHY=home; return 1; }
  [[ "${dir#$HOME/}" != "$dir" ]] || { _TB_DATA_DIR_WHY=outside; return 1; }
}

# _tb_data_dir_said DIR -- why _tb_data_dir_check refused DIR, as the ✖ line under a
# typed directory says it. _TB_DATA_DIR_RULE is the line under it: what can be used.
_TB_DATA_DIR_RULE='Use a directory under $HOME whose parent exists, as an absolute path or relative to $HOME.'
_tb_data_dir_said() {
  case "$_TB_DATA_DIR_WHY" in
    empty)       printf 'A directory is required.' ;;
    parent)      printf '"%s" can'"'"'t be used: its parent directory doesn'"'"'t exist.' "$1" ;;
    root|system) printf '"%s" can'"'"'t be used: it is a system directory.' "$1" ;;
    home)        printf '"%s" can'"'"'t be used: it is $HOME itself.' "$1" ;;
    *)           printf '"%s" can'"'"'t be used: it isn'"'"'t under $HOME.' "$1" ;;
  esac
}

validate_config() {
  [[ -n "${HOME:-}" ]]  || error "\$HOME is not set — cannot determine user home directory"
  [[ -n "${USER:-}" ]]  || USER="$(whoami)" || error "Cannot determine current user"

  _refuse_invalid_cluster_name "$cluster_name"

  [[ "$TB_STORAGE_MODE" == "hostpath" || "$TB_STORAGE_MODE" == "node-local" ]] \
    || error "TRACEBLOC_STORAGE_MODE must be 'hostpath' or 'node-local' (got '$TB_STORAGE_MODE')"

  # node-local forces hostPath.enabled=false, so a HOST_DATASET_DIR network export
  # would be ignored and datasets would silently land on ephemeral local-path
  # storage (gone on 'cluster delete'). Combining the two is a documented follow-up
  # ; until then, refuse it rather than misroute datasets.
  [[ "$TB_STORAGE_MODE" == "node-local" && -n "${HOST_DATASET_DIR:-}" ]] \
    && error "TRACEBLOC_HOST_DATASET_DIR is not supported with node-local storage (datasets would land on ephemeral in-node storage, not the export). Use hostpath mode (TRACEBLOC_STORAGE_MODE=hostpath) for network-mount datasets."

  # host_data_dir must be under $HOME and must not be a system path (security):
  # _tb_data_dir_check, the rule the new-directory prompt asks again by.
  if ! _tb_data_dir_check "$host_data_dir"; then
    case "$_TB_DATA_DIR_WHY" in
      empty)  error "TRACEBLOC_HOST_DATA_DIR must not be empty (got '')." ;;
      parent) error "TRACEBLOC_HOST_DATA_DIR parent directory could not be resolved: $(dirname "$_TB_DATA_DIR")" ;;
      root)   error "TRACEBLOC_HOST_DATA_DIR cannot be root (/)" ;;
      system) error "TRACEBLOC_HOST_DATA_DIR cannot be a system path: $_TB_DATA_DIR" ;;
      home)   error "TRACEBLOC_HOST_DATA_DIR must be a subdirectory of \$HOME, not \$HOME itself (got: $host_data_dir)." ;;
      *)      error "TRACEBLOC_HOST_DATA_DIR must be under \$HOME (got: $host_data_dir)" ;;
    esac
  fi
  host_data_dir="$_TB_DATA_DIR"
  tb_export_host_data_dir

  # Optional dataset dir: unlike host_data_dir it MAY live outside
  # $HOME (a mounted network volume like /data01). It must already EXIST and be
  # WRITABLE as the host user — we never mkdir a network-share root — and is
  # barred from system paths. The host_data_dir rules above are unchanged.
  if [[ -n "${HOST_DATASET_DIR:-}" ]]; then
    local ddir="$HOST_DATASET_DIR" rddir
    [[ "$ddir" == /* ]] || error "TRACEBLOC_HOST_DATASET_DIR must be an absolute path (got '$HOST_DATASET_DIR')"
    [[ -d "$ddir" ]]    || error "TRACEBLOC_HOST_DATASET_DIR does not exist: $ddir (mount the dataset volume before installing)"
    [[ -w "$ddir" ]]    || error "TRACEBLOC_HOST_DATASET_DIR is not writable (uid $(id -u)): $ddir — check its permissions."
    rddir="$(cd -P "$ddir" 2>/dev/null && pwd)" || error "TRACEBLOC_HOST_DATASET_DIR could not be resolved: $ddir"
    case "$rddir" in
      /) error "TRACEBLOC_HOST_DATASET_DIR cannot be root (/)" ;;
      /etc|/etc/*|/usr|/usr/*|/var|/var/*|/bin|/sbin|/lib|/lib64)
        error "TRACEBLOC_HOST_DATASET_DIR cannot be a system path: $rddir" ;;
    esac
    HOST_DATASET_DIR="$rddir"
  fi
  tb_say_ignored_settings
}
