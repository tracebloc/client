#!/usr/bin/env bash
# =============================================================================
#  mysql-engine.sh — which MySQL engine (5.7 or 8.4) the client runs: the image
#  pins, the engine an existing release or datadir already holds, the values that
#  pin it, and the gate that refuses a 5.7 engine this machine cannot run.
#  install_client_helm (install-client-helm.sh) and preflight's arch gate call them.
# =============================================================================

# ── MySQL engine channel (decision A2 2026-08-05) ─────────────
# The chart's default is the multi-arch 8.4 engine by default; the frozen 5.7-lineage image is no longer a default anywhere,
# only an explicit pin (TB_MYSQL_57_PIN_* below) that this installer writes for
# an install it resolves to 5.7. `auto` picks 8.4 on every fresh install,
# whatever the arch: it used to pick 8.4 only on arm64 and keep
# fresh amd64 hosts on 5.7, so every new x86 install joined the 5.7 -> 8.4
# migration backlog the day it came up. Anything that smells like existing
# state stays 5.7: an existing release, or real mysql datadir content on the
# host (legacy or per-release layout). EVERY resolution is written down as an
# explicit image pin -- 8.4 as `tag "8.4"` + TB_MYSQL_84_DEFAULT_DIGEST, 5.7 as
# TB_MYSQL_57_PIN_* -- so what runs never depends on which engine a chart
# version defaults to: a 5.7 install that relied on the default would be moved
# onto 8.4 by the first chart that changed it, and 8.4 refuses a 5.7 datadir.
# A previous opt-in stays sticky across re-runs (the values file is
# regenerated every run, so it is re-derived from the old file first). The
# chart's mysql-format-guard init container backstops whatever this
# heuristic misses — a wrong pick fails loudly before mysqld starts, it
# never opens a datadir with the wrong engine.
#   TB_MYSQL_ENGINE=auto|5.7|8.4    explicit value always wins (default auto)
# Reads (bash dynamic scope, set by install_client_helm before the call):
# values_file, existing_id, host_data_dir, namespace. Not ARCH: the arch
# decides whether a 5.7 verdict can RUN here (_assert_engine_runs_on_this_arch),
# never which engine a fresh host gets.
# Sets: TB_MYSQL_ENGINE_RESOLVED.
#
# Two of those inputs are `local`s of install_client_helm, which has NOT run at
# preflight time — so the helpers below derive them, and preflight's arch gate
# calls the same helpers rather than restating the paths.
# The explicit pin for an install that stays on MySQL 5.7: the frozen
# 5.7-lineage `:prod` image the chart defaulted to until the 8.4 default switch. The
# chart's tracebloc.mysqlEngineMajor maps exactly this digest to "5.7", which
# keeps mysql-format-guard armed for these datadirs; install-client-helm.bats
# holds both values against the chart's own literal, so they cannot drift apart.
TB_MYSQL_57_PIN_TAG="prod"
TB_MYSQL_57_PIN_DIGEST="sha256:f546e47fb339e0982c902cef063b081ccf2cbbaf35b475287d583b9bf3163354"
# The chart's DEFAULT images.mysqlClient.digest (the 8.4 manifest index): the
# digest the installer's 8.4 block pins and what an absent
# digest renders for the dev-mode reader (_values_mysql_engine). Held to
# client/values.yaml by the same bats case.
TB_MYSQL_84_DEFAULT_DIGEST="sha256:31fe86bd6777894b98059c3dd3f678e8ef6f164eaa44cdcfd9b1790d7a24a470"
# The chart's earlier 8.4 defaults, newest first: PREVIOUS is the unsigned
# :8.4-ca822dea index, PRIOR is :8.4-bc3756a9. Earlier installers wrote them
# into the values file, so clients carry them: every reader below still reads
# them as 8.4, as tracebloc.mysqlEngineMajor does (held by install-client-helm.bats).
TB_MYSQL_84_PREVIOUS_DIGEST="sha256:0050bd8f38d07bed86a4f5b5791314516efd47134c98ee75a8968471aa2ebc93"
TB_MYSQL_84_PRIOR_DIGEST="sha256:f58060c5bba7e88190725c6f4c980c45bc39cad186f507dd5557522db7cda35d"

# The engine a mysql-client image reference runs: 5.7, 8.4, 8.0 or unknown. The
# same classification tracebloc.mysqlEngineMajor makes of the values that
# rendered it, applied to the rendered reference: a digest names its engine only
# when it is one of the pins above (anything else is unknown); a bare tag
# reads prod/5.7* as 5.7, 8.4* as 8.4 and 8.0* as 8.0. A reference with no tag at
# all runs `latest`, which names no engine.
_mysql_image_engine() {
  local ref="$1" digest="" last tag=""
  case "$ref" in
    *@sha256:*) digest="sha256:${ref##*@sha256:}"; ref="${ref%%@*}" ;;
  esac
  if [[ -n "$digest" ]]; then
    case "$digest" in
      "$TB_MYSQL_84_DEFAULT_DIGEST"|"$TB_MYSQL_84_PREVIOUS_DIGEST"|"$TB_MYSQL_84_PRIOR_DIGEST") echo 8.4 ;;
      "$TB_MYSQL_57_PIN_DIGEST")     echo 5.7 ;;
      *)                             echo unknown ;;
    esac
    return 0
  fi
  last="${ref##*/}"
  case "$last" in *:*) tag="${last##*:}" ;; esac
  case "$tag" in
    prod|5.7*) echo 5.7 ;;
    8.4*)      echo 8.4 ;;
    8.0*)      echo 8.0 ;;
    *)         echo unknown ;;
  esac
}

# The engine the release in namespace <ns> RUNS, read from the image of its live
# mysql Deployment (the chart names it mysql-client). Echoes
#   5.7 | 8.4  the image names that engine
#   unknown    the image was read and names neither (a custom pin, the 8.0
#              transit hop)
#   (nothing)  it could not be read: no namespace, no Deployment, an API that
#              did not answer
# What RUNS, not what the release's values say: since chart 1.10.0 a release that
# carries no image keys runs whatever its chart version defaults to, 5.7 before
# 1.10.0 and 8.4 from it, so the values alone cannot tell.
# Bounded (--request-timeout), and never logs: _mysql_engine_decision calls it.
_release_mysql_engine() {
  local ns="$1" img eng
  [[ -n "$ns" ]] || return 0
  img="$(kubectl get deployment mysql-client -n "$ns" --request-timeout=10s \
    -o 'jsonpath={.spec.template.spec.containers[?(@.name=="mysql-client")].image}' 2>/dev/null)" || return 0
  [[ -n "$img" ]] || return 0
  eng="$(_mysql_image_engine "$img")"
  case "$eng" in 5.7|8.4) echo "$eng" ;; *) echo unknown ;; esac
  return 0
}

# The format of a host mysql datadir, by the marker the chart's format guard
# reads: `mysql.ibd` (the 8.0+ data dictionary) present = an 8.x datadir, which
# 8.4 opens; real content without it = 5.7-format, which only 5.7 opens. Echoes
#   (nothing)  absent, a symlink (never trusted as data, the leftover guard's
#              stance), or empty: the dirs _ensure_tracebloc_dirs creates
#   8.x        mysql.ibd is there
#   5.7        content, and no mysql.ibd
#   unknown    the host user cannot list it (a uid-999/root-owned dir): it
#              cannot be proven empty or read, so it counts as content whose
#              format is unknown. FAIL CLOSED (mirrors _leftover_data_dirs and
#              the same ownership case), never an 8.4 opt-in by default.
_mysql_datadir_format() {
  local d="$1"
  [[ -d "$d" && ! -L "$d" ]] || return 0
  [[ -r "$d" && -x "$d" ]] || { echo unknown; return 0; }
  [[ -n "$(ls -A "$d" 2>/dev/null)" ]] || return 0
  if [[ -e "$d/mysql.ibd" ]]; then echo 8.x; else echo 5.7; fi
}

# The format of this install's host datadirs, both layouts (legacy
# host_data_dir/mysql and per-release host_data_dir/<namespace>/mysql) in one
# word, the most conservative first: unknown, then 5.7, then 8.x; nothing when
# neither holds data. 5.7 beats 8.x because any 5.7 data here may be what the
# release mounts, and only 5.7 opens it.
_host_mysql_datadir_format() {
  local legacy perrel
  legacy="$(_mysql_datadir_format "${host_data_dir:-/nonexistent}/mysql")"
  perrel="$(_mysql_datadir_format "${host_data_dir:-/nonexistent}/${namespace:-}/mysql")"
  case " $legacy $perrel " in
    *" unknown "*) echo unknown ;;
    *" 5.7 "*)     echo 5.7 ;;
    *" 8.x "*)     echo 8.x ;;
  esac
}

# The generated values file install_client_helm reads (for the sticky 8.4
# check) and writes. Factored out of the `local values_file=…` it used to be so
# a caller running BEFORE install_client_helm — preflight's arch gate — resolves
# the same file instead of restating the path. A restated path would silently
# stop seeing an existing 8.4 opt-in the day this one moves.
_client_values_file() { echo "${TRACEBLOC_VALUES_FILE:-${host_data_dir}/values.yaml}"; }

# The namespace this install will use when nothing else has determined one yet
# (an existing release can override it later — see install_client_helm). Same
# reason as above: preflight needs the per-release datadir path, which is
# host_data_dir/<namespace>/mysql.
_client_default_namespace() { _sanitize_workspace_name "${namespace:-tracebloc}"; }

# Whether the values on STDIN pin the MySQL 8.4 engine — i.e. the engine that will
# ACTUALLY run is 8.4. Reads STDIN so a caller streams a file (`< values.yaml`)
# rather than slurping it (a 60k-line fixture). The ONE
# reader three callers share so they cannot drift on what "pins 8.4" means: the
# sticky rule below, the dev-mode TRACEBLOC_VALUES_FILE arch gate, and the
# adopt-reconcile arch gate.
#
# STRUCTURAL, not a fixed line window. The chart's own
# client/values.yaml documents the 8.4 opt-in in a COMMENT several lines below the
# real `tag:` — literally `#   tag: "8.4"` — so a `grep -A N` is wrong in BOTH
# directions: too narrow misses the real tag and refuses a legitimate 8.4 opt-in on
# arm64; too wide reads that DECOY comment as the pin and skips the gate on a 5.7
# default (fail OPEN). So walk the indent-delimited mysqlClient block, drop comment
# and blank lines (the decoy goes with them), and read the real `tag:`/`digest:` by
# EXACT value — "8.40"/"8.4.1" are not 8.4. Handles the quoted form our heredoc
# writes (tag: "8.4") and the unquoted form `helm get values` re-serializes
# (tag: 8.4).
#
# DIGEST WINS OVER TAG. tracebloc.image renders
# repository@<digest> when a digest is set and ignores the tag entirely. So
# `tag: "8.4"` with a NON-empty digest actually runs whatever that (opaque sha256)
# digest is — which we cannot decode — not 8.4. Report 8.4 ONLY when tag is 8.4
# AND the digest is one that provably runs 8.4: TB_MYSQL_84_DEFAULT_DIGEST, the
# chart's own 8.4 pin and what our heredoc writes, the
# earlier defaults an installer wrote (TB_MYSQL_84_PREVIOUS_DIGEST and
# TB_MYSQL_84_PRIOR_DIGEST), or
# AFFIRMATIVELY empty, the documented opt-in (`tag: "8.4"` + `digest: ""`) and
# what the heredoc wrote before it pinned — so a client installed then stays 8.4
# sticky and its re-run writes the pinned block. Any other set digest is treated
# as "not provably 8.4" so the 5.7 arch gate runs — fail closed, refuse rather
# than CrashLoop.
#
# AN ABSENT DIGEST IS NOT AN EMPTY ONE.
# This reader is fed PARTIAL views: `_release_pins_mysql_84` reads `helm get values`
# WITHOUT `--all`, which omits chart defaults, and a dev-mode overlay can carry only
# `mysqlClient.tag`. In both, the chart-default `digest` (the amd64-only 5.7 pin) is
# still what renders — `tracebloc.image` makes it win over the tag — yet the digest
# line is nowhere on STDIN. Treating that missing line as `digest: ""` reported a
# real 8.4 pin, skipped the 5.7 arch gate, and CrashLooped the amd64-only image on
# arm64. So we require the digest key to actually APPEAR and be empty (`sawdigest`);
# a digest we never saw is "not provably cleared" → not 8.4 → the 5.7 gate runs.
# (We deliberately do NOT switch the caller to `helm get values --all`: coalescing
# can re-default an operator's explicit `digest: ""` back to the chart's 5.7 pin,
# which would false-REFUSE a genuine 8.4 reconcile. Reading only supplied values and
# demanding an explicit known digest is the fail-closed direction that costs nothing
# real — our heredoc always writes the digest key explicitly.)
#
# Reads to EOF and decides in END — it never exits on first match, so a producer
# piping in (helm get values) is never SIGPIPE'd (the trap an early
# `exit`/`grep -q` would spring).
_values_pin_mysql_84() {
  awk -v d84="$TB_MYSQL_84_DEFAULT_DIGEST" -v d84p="$TB_MYSQL_84_PRIOR_DIGEST" -v d84q="$TB_MYSQL_84_PREVIOUS_DIGEST" '
    # 8.4 iff tag is 8.4 AND the digest was SEEN and is empty or an 8.4 pin.
    # sawdigest guards the "absent digest is not an empty one" rule:
    # a digest we never saw on STDIN may still be a non-empty default that wins.
    function flush() { if (inblk && tag == "8.4" && sawdigest && (digest == "" || digest == d84 || digest == d84p || digest == d84q)) found = 1 }
    /^[[:space:]]*#/ { next }                      # comment line — drops the decoy
    /^[[:space:]]*$/ { next }                      # blank line
    { match($0, /^[[:space:]]*/); indent = RLENGTH }
    !inblk {
      if ($0 ~ /^[[:space:]]*mysqlClient:[[:space:]]*$/) { inblk=1; base=indent; tag=""; digest=""; sawdigest=0 }
      next
    }
    {
      if (indent <= base) {                        # dedented out of the block
        flush()                                    # decide this block before leaving it
        inblk = ($0 ~ /^[[:space:]]*mysqlClient:[[:space:]]*$/)
        if (inblk) { base=indent; tag=""; digest=""; sawdigest=0 }
        next
      }
      if ($0 ~ /^[[:space:]]*tag:[[:space:]]*/) {
        v = $0
        sub(/^[[:space:]]*tag:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)             # strip an inline comment
        gsub(/"/, "", v)                           # strip quotes (quoted or not)
        sub(/[[:space:]]+$/, "", v)
        tag = v
      } else if ($0 ~ /^[[:space:]]*digest:[[:space:]]*/) {
        v = $0
        sub(/^[[:space:]]*digest:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)
        gsub(/"/, "", v)
        sub(/[[:space:]]+$/, "", v)
        digest = v
        sawdigest = 1                              # the key is present (empty or not)
      }
    }
    END { flush(); exit(found ? 0 : 1) }
  '
}

# Whether the live Helm release <rel> in namespace <ns> runs the MySQL 8.4 engine,
# read from its STORED values — adopt/reconcile keeps those via --reuse-values, so
# this is the engine that will actually run, not a fresh resolution. Bounded the
# way _existing_training_values bounds its read: `helm get values` has no request
# timeout, so gate it behind a bounded namespace probe and let a wedged API degrade
# to "not 8.4" (→ the 5.7 arch gate) instead of hanging. Unreadable is deliberately
# fail-closed: refuse an arm64 reconcile we cannot prove is 8.4 rather than report
# success and CrashLoop (the same stance as the adopt-reconcile arch gate).
_release_pins_mysql_84() {
  local _rel="$1" _ns="$2"
  [[ -n "$_rel" && -n "$_ns" ]] || return 1
  kubectl get namespace "$_ns" --request-timeout=5s >/dev/null 2>&1 || return 1
  # The stored values hold clientPassword and the chart's other secrets: piped
  # straight into the reader, never held, so a trace shows no value. A helm that
  # fails is read as empty values (`|| :`), "not 8.4", whatever pipefail says.
  { helm get values "$_rel" -n "$_ns" 2>/dev/null </dev/null || :; } | _values_pin_mysql_84
}

# _values_hostpath_storage -- the top-level hostPath block of `helm get values` on
# STDIN, and the macOS node's jobData.path, as four lines:
# enabled=<v>, root=<v>, datasetPath=<v>, jobDataPath=<v> (absent is empty; null and ~
# are empty too). Values are unquoted the way helm serializes them:
# plain, '...' with '' for a quote, or "..." without escapes. Anything else -- a
# "..." holding a backslash, a block scalar, a flow-style hostPath or jobData mapping, a root, datasetPath or jobData path folded
# onto a second line -- prints the single word `unreadable`: a path read half-right is
# worse than none. Reads to EOF (no early exit, so a producer is never SIGPIPE'd).
_values_hostpath_storage() {
  awk -v sq="'" '
    function unq(v,   dq) {
      dq = "\""
      if (v == "null" || v == "~") return ""
      if (length(v) >= 2 && substr(v, 1, 1) == sq && substr(v, length(v), 1) == sq) {
        v = substr(v, 2, length(v) - 2); gsub(sq sq, sq, v); return v
      }
      if (length(v) >= 2 && substr(v, 1, 1) == dq && substr(v, length(v), 1) == dq) {
        v = substr(v, 2, length(v) - 2)
        if (index(v, "\\")) bad = 1
        return v
      }
      if (substr(v, 1, 1) == sq || substr(v, 1, 1) == dq || v ~ /^[|>&*!%@`]/) bad = 1
      return v
    }
    /^[[:space:]]*$/ { next }
    { match($0, /^ */); ind = RLENGTH }
    ind == 0 {
      inblk = ($0 ~ /^hostPath:[[:space:]]*(#.*)?$/); injd = ($0 ~ /^jobData:[[:space:]]*(#.*)?$/); child = -1; last = ""
      if (!inblk && !injd && $0 ~ /^(hostPath|jobData):/) {
        rest = $0; sub(/^[^:]*:[[:space:]]*/, "", rest); sub(/[[:space:]]+#.*$/, "", rest); sub(/[[:space:]]+$/, "", rest)
        if (rest != "null" && rest != "~" && rest != "{}") bad = 1
      }
      next
    }
    !inblk && !injd { next }
    child < 0 { child = ind }
    ind > child { if (last == "root" || last == "datasetPath" || last == "jobData.path") bad = 1; next }
    {
      line = $0; sub(/^ */, "", line)
      key = line; sub(/:.*/, "", key)
      v = line; sub(/^[^:]*:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      last = key
      if (injd) { if (key == "path") { last = "jobData.path"; jd = unq(v) }; next }
      if (key == "enabled") en = v
      else if (key == "root") root = unq(v)
      else if (key == "datasetPath") ds = unq(v)
    }
    END {
      if (bad) { print "unreadable"; exit 0 }
      print "enabled=" en; print "root=" root; print "datasetPath=" ds; print "jobDataPath=" jd
    }
  '
}

# _native_k3s_release_storage -- native k3s only: keep the storage
# an installed release was made with. Native k3s has no node to inspect, so
# the answer is the release's own stored hostPath values. A release's volumes cannot
# change in place -- a PV's path and a PVC's class are immutable, so a re-run that
# rendered the other mode, or another root, would fail the upgrade.
#   - a hostpath release, this run's node-local only the default: hostpath is kept,
#     in this shell, for the values and the dirs below (every bare re-run and
#     `tracebloc upgrade`, which passes no storage mode and no data dir);
#   - an explicit mode that differs from the release's: refused by name;
#   - a hostpath release's root and datasetPath are kept (TB_HOSTPATH_KEPT, read by
#     _hostpath_paths_block), with one warning when this run asked for others --
#     as config.yaml's storage path is kept for node-local
#     (_native_k3s_storage_drift_warn, k3s.sh).
# No namespace, or no release in it, is a fresh install. A read that does not answer
# is "cannot tell" and stops the run by name, never "no release".
#
# TWICE, ONE READ. install-k8s.sh calls it EARLY, right after validate_config, so
# every pre-install reader of TB_STORAGE_MODE -- the pre-log guard, preflight's disk
# and storage-type checks, guard_leftover_data -- judges the release's storage, not
# the default's. Before the create path nothing
# else has set the cluster up for this run, so the early read only acts when it can
# see the release: a k3s this installer recorded (`k3s-install`), the tracebloc
# context in the kubeconfig, an API that answers, and the release in the namespace.
# Anything short of that is a fresh install, or a k3s the create path is about to
# start, and the call returns without deciding; install_client_helm's call then
# reads it once the cluster is up, as before. When the record lists this installer's
# k3s, that return marks the release unread (TB_RELEASE_STORAGE_UNREAD), so the
# create path's config.yaml does not newly confine k3s over what may be hostPath
# volumes (_native_k3s_selinux_deferred, k3s.sh). Once a read has decided
# (TB_RELEASE_STORAGE_READ), the second call returns at once.
# Both calls name the kubeconfig the merge writes and the tracebloc context: before
# the create path, the current context can be any cluster the user works with.
_native_k3s_release_storage() {
  [[ "${TRACEBLOC_SUBSTRATE_RESOLVED:-}" == "k3s" ]] || return 0
  [[ "${TB_RELEASE_STORAGE_READ:-}" != 1 ]] || return 0
  local early="" ns="${namespace:-}" out rc=0 line enabled="" root="" ds="" jd="" want="${TB_STORAGE_MODE:-node-local}" kc ctx rec
  if [[ "${1:-}" == early ]]; then early=1; ns="$(_client_default_namespace)"; fi
  [[ -n "$ns" ]] || return 0
  kc="$(_native_k3s_kubeconfig_target)"; ctx="$(_native_k3s_context)"
  if [[ -n "$early" ]]; then
    rec="$(tb_record_path)"
    if [[ ! -r "$rec" ]] || ! grep -qF '"kind": "k3s-install"' "$rec" 2>/dev/null; then return 0; fi
    # This installer set a k3s up here, so a release may be on it: until its API
    # answers, the release's storage is unread, and config.yaml, written before k3s
    # is up, is not newly confined (_native_k3s_selinux_deferred, k3s.sh).
    TB_RELEASE_STORAGE_UNREAD=1
    if ! has kubectl || ! has helm; then return 0; fi
    out="$(kubectl --kubeconfig "$kc" config get-contexts -o name 2>/dev/null)" || out=""
    grep -qxF -- "$ctx" <<<"$out" || return 0
    if ! kubectl --kubeconfig "$kc" --context "$ctx" get --raw /readyz --request-timeout=5s >/dev/null 2>&1; then
      log "Storage mode: this machine's k3s API is not answering yet, so its release's storage is read once k3s is up."
      return 0
    fi
    TB_RELEASE_STORAGE_UNREAD=""
  fi
  local cant="native k3s: couldn't read this machine's tracebloc release '${ns}', so which storage its volumes use can't be told"
  out="$(kubectl --kubeconfig "$kc" --context "$ctx" get namespace "$ns" --ignore-not-found -o name --request-timeout=5s 2>/dev/null)" || rc=$?
  [[ "$rc" -eq 0 ]] || error "${cant}. Check that 'kubectl --context ${ctx} get namespace ${ns}' answers, then re-run."
  if [[ -z "$out" ]]; then [[ -n "$early" ]] || TB_RELEASE_STORAGE_READ=1; return 0; fi
  out="$(_bounded "${TB_HELM_LIST_TIMEOUT:-20}" helm --kubeconfig "$kc" --kube-context "$ctx" list -n "$ns" -q --deployed --failed --pending --uninstalling 2>/dev/null)" || rc=$?
  [[ "$rc" -eq 0 ]] || error "${cant}. Check that 'helm --kube-context ${ctx} list -n ${ns}' answers, then re-run."
  if ! grep -qxF -- "$ns" <<<"$out"; then [[ -n "$early" ]] || TB_RELEASE_STORAGE_READ=1; return 0; fi
  TB_RELEASE_STORAGE_READ=1
  # The stored values hold clientPassword and the chart's other secrets: piped
  # straight into the reader, never held, so a trace shows only its four lines.
  # pipefail: a helm that fails stops the run as before. The reader reads to EOF
  # (it decides in END), so helm is never SIGPIPE'd.
  out="$(set -o pipefail; _bounded "${TB_HELM_VALUES_TIMEOUT:-20}" helm --kubeconfig "$kc" --kube-context "$ctx" get values "$ns" -n "$ns" 2>/dev/null </dev/null | _values_hostpath_storage)" || rc=$?
  [[ "$rc" -eq 0 ]] || error "${cant}. Check that 'helm --kube-context ${ctx} get values ${ns} -n ${ns}' answers, then re-run."
  [[ "$out" != unreadable ]] \
    || error "${cant}: its stored hostPath values are in a form this installer does not read. Check them with 'helm --kube-context ${ctx} get values ${ns} -n ${ns}', then re-run."
  while IFS= read -r line; do
    case "$line" in
      enabled=*)     enabled="${line#enabled=}" ;;
      root=*)        root="${line#root=}" ;;
      datasetPath=*) ds="${line#datasetPath=}" ;;
      jobDataPath=*) jd="${line#jobDataPath=}" ;;
    esac
  done <<<"$out"

  if [[ "$enabled" != true ]]; then
    [[ "$want" != hostpath ]] \
      || error "TRACEBLOC_STORAGE_MODE=hostpath, but this machine's tracebloc release '${ns}' keeps its data in k3s's local-path volumes (node-local), and an installed release can't change its storage in place. Unset TRACEBLOC_STORAGE_MODE to keep node-local, or remove tracebloc from this machine and install again with hostpath."
    # The macOS node's job-data folder: the release keeps the one its
    # claims' PVs name, or keeps having none (a v1.11 Mac's release: its claims are in
    # the node and cannot move). _mac_ct_job_data_dir reads the two.
    if [[ -n "$jd" ]]; then TRACEBLOC_JOB_DATA_KEPT=1; TRACEBLOC_JOB_DATA_KEPT_DIR="$jd"; else TRACEBLOC_JOB_DATA_KEPT=0; fi
    return 0
  fi
  root="${root:-/tracebloc}"   # the chart's default, which is what rendered
  if [[ "$want" == node-local ]]; then
    [[ "${TB_STORAGE_MODE_SOURCE:-default}" != explicit ]] \
      || error "TRACEBLOC_STORAGE_MODE=node-local, but this machine's tracebloc release '${ns}' keeps its data in hostPath volumes under ${root}, and an installed release can't change its storage in place. Unset TRACEBLOC_STORAGE_MODE to keep hostpath, or remove tracebloc from this machine and install again with node-local."
    TB_STORAGE_MODE=hostpath
    log "Storage mode: hostpath — kept from the release '${ns}' (node-local is only the default, and the release was installed with hostpath)."
    info "Keeping hostpath storage: this machine's tracebloc release was installed with it, and its data stays in ${root}."
  fi
  TB_HOSTPATH_KEPT=1
  TB_HOSTPATH_ROOT="$root"
  TB_HOSTPATH_DATASET="$ds"
  if [[ "$root" != "${host_data_dir:-}" || "${ds:-$root}" != "${HOST_DATASET_DIR:-${host_data_dir:-}}" ]]; then
    warn "This machine's tracebloc release keeps its data in ${root}${ds:+ (datasets in ${ds})}; this run asked for ${host_data_dir:-}${HOST_DATASET_DIR:+ (datasets in ${HOST_DATASET_DIR})}, which is not used."
    hint "hostPath volumes can't move: to use the new directory, remove tracebloc from this machine, then install again with it."
  fi
  return 0
}

# _hostpath_paths_block -- the hostPath keys after `enabled: true` in the values file.
# The node is the host, so the PVs name the host's own directories:
# root is host_data_dir, datasetPath HOST_DATASET_DIR when one is set (unset, the
# chart follows root). An installed release keeps the two it was made with
# (_native_k3s_release_storage).
# Single-quoted (_yaml_sq_escape): a data dir is a path the operator chose.
_hostpath_paths_block() {
  local ds="${HOST_DATASET_DIR:-}"
  [[ "${TB_HOSTPATH_KEPT:-}" != 1 ]] || ds="${TB_HOSTPATH_DATASET:-}"
  printf "  root: '%s'\n" "$(_yaml_sq_escape "$(_hostpath_root)")"
  [[ -z "$ds" ]] || printf "  datasetPath: '%s'\n" "$(_yaml_sq_escape "$ds")"
}

# The engine decision itself, with NO logging and NO globals set, so a second
# caller can ask this rule a question instead of restating it:
# preflight's arch gate refused a fresh arm64 install that this rule was about
# to serve natively. Echoes "<engine> <reason>" — always exit 0, the reason
# carries the verdict:
#   5.7|8.4 explicit      an explicit TB_MYSQL_ENGINE=<value>
#   invalid <value>        TB_MYSQL_ENGINE is not auto|5.7|8.4
#   8.4 sticky             this machine already opted into 8.4 (its values.yaml)
#   8.4 existing-release   this machine's live release runs 8.4
#   8.4 existing-datadir   this host's mysql datadir is 8.x-format (mysql.ibd)
#   5.7 existing-datadir   this host holds mysql data that is 5.7-format, or that
#                          cannot be read (fail closed)
#   5.7 existing-release   this machine's live release runs 5.7, or runs an engine
#                          that cannot be read, and no host datadir says more
#   8.4 fresh              fresh install, on every arch — native multi-arch engine
_mysql_engine_decision() {
  local requested="${TB_MYSQL_ENGINE:-auto}"
  case "$requested" in
    5.7|8.4) echo "${requested} explicit"; return 0 ;;
    auto) ;;
    *) echo "invalid ${requested}"; return 0 ;;
  esac
  # Sticky: an edge that opted into 8.4 stays there on every later re-run.
  # _values_pin_mysql_84 streams the file (never slurps it), skips comments, and
  # reads to EOF — it owns the structural-vs-window and SIGPIPE reasoning
  if [[ -f "${values_file:-}" ]] && _values_pin_mysql_84 < "${values_file}"; then
    echo "8.4 sticky"; return 0
  fi
  # Existing state keeps the engine it RUNS (since the 8.4 default switch):
  # since chart 1.10.0 the chart's default is 8.4, so a 5.7 client must be pinned
  # to 5.7 explicitly and an 8.4 client must not be. Read from the state itself,
  # most authoritative first:
  #
  #   the live release: the image of its mysql Deployment
  #     (_release_mysql_engine). It is what runs on the release's datadir, and the
  #     format guard admitted that pairing at its last start. Its values cannot
  #     say: a release with no image keys runs its chart version's default.
  #
  #   the host datadir: its format marker (_host_mysql_datadir_format), for a
  #     host with data and no readable release (a reinstall over kept data, an
  #     API that would not answer). 8.x-format opens on 8.4; 5.7-format only on
  #     5.7; an UNLISTABLE dir counts as content of unknown format and keeps 5.7
  #     (fail closed; see the helper).
  #
  # Reason 'existing-datadir' whenever there IS 5.7 (or unreadable) data on this
  # host, release or not: a clean start then means clearing the data dir, and a
  # release-only "uninstall" remedy would leave those files to re-pin 5.7 on the
  # next run. 'existing-release' for a release with no host
  # datadir files (TB_STORAGE_MODE=node-local, where both probes are empty): 5.7
  # when it runs 5.7 or cannot be read, because 8.4 cannot open a 5.7-format
  # datadir and an existing one is never flipped automatically; "uninstall the
  # release" is then a COMPLETE fresh-start remedy, as no files remain to
  # re-trigger the gate.
  #
  # The empty dirs _ensure_tracebloc_dirs just created don't count — only files.
  local fmt live=""
  fmt="$(_host_mysql_datadir_format)"
  if [[ -n "${existing_id:-}" ]]; then
    live="$(_release_mysql_engine "${existing_ns:-${namespace:-}}")"
  fi
  if [[ "$live" == "8.4" ]]; then
    echo "8.4 existing-release"; return 0
  fi
  if [[ "$live" != "5.7" && "$fmt" == "8.x" ]]; then
    echo "8.4 existing-datadir"; return 0
  fi
  if [[ -n "$fmt" ]]; then
    echo "5.7 existing-datadir"; return 0
  fi
  if [[ -n "${existing_id:-}" ]]; then
    echo "5.7 existing-release"; return 0
  fi
  # Fresh: nothing here is 5.7-format, so the multi-arch 8.4 engine, on every
  # arch. A fresh amd64 host used to answer "5.7 amd64" and keep the chart's 5.7
  # pin, which made each new x86 install a later 5.7 -> 8.4 migration.
  echo "8.4 fresh"
}

# Dev-mode (TRACEBLOC_VALUES_FILE) engine resolution — DELIBERATELY not the auto
# rule above. When the caller supplies a values file, install_client_helm deploys
# it as-is (only this run's GPU decision rides on top) and never
# generates the mysqlClient pin the normal path writes, so the engine that RUNS is
# what the file's images.mysqlClient block renders over THIS chart's defaults
# (_values_mysql_engine) — since the 8.4 default switch that is the multi-arch 8.4 engine
# unless the file pins the 5.7-lineage image. _mysql_engine_decision answers for
# the normal path, whose pin dev-mode never writes; consulting it for a dev-mode
# install is what let a past case pass preflight and then refuse after the
# cluster was already up. This helper is the ONE reader both the step-e install
# path and preflight's early arch gate share, so the two cannot drift.
# Fail-closed: a missing/unreadable file, or an engine the reader cannot name (a
# custom digest), reads as 5.7 — the answer that keeps the arch gate armed,
# refusing rather than false-passing. Echoes "<engine> values-file".
_devmode_engine_decision() {
  local vf="${TRACEBLOC_VALUES_FILE:-}" engine=""
  if [[ -n "$vf" && -f "$vf" && -r "$vf" ]]; then
    engine="$(_values_mysql_engine < "$vf")"
  fi
  if [[ "$engine" == "8.4" ]]; then
    echo "8.4 values-file"
  else
    echo "5.7 values-file"
  fi
}

# _values_mysql_engine -- the MySQL engine a values file (on STDIN) runs on THIS
# chart: its images.mysqlClient block laid over the chart's defaults, then
# tracebloc.mysqlEngineMajor's own rule. Prints 5.7, 8.4, 8.0 or unknown.
#   digest absent   -> the chart default, TB_MYSQL_84_DEFAULT_DIGEST -> 8.4
#   digest = that, TB_MYSQL_84_PREVIOUS_DIGEST or TB_MYSQL_84_PRIOR_DIGEST -> 8.4
#   digest = TB_MYSQL_57_PIN_DIGEST -> 5.7
#   other digest    -> unknown (a custom pin; the guard stands down)
#   digest ""       -> the tag (absent = the chart default "8.4"):
#                      ""/prod/5.7* -> 5.7, 8.4* -> 8.4, 8.0* -> 8.0, else unknown
#   `mysqlClient: null` / `images: null` -> the template fallbacks, tag prod -> 5.7
# It RESTATES the chart's helper, so install-client-helm.bats renders the chart on
# every input shape above and holds this reader to the guard's own answer.
# Unlike _values_pin_mysql_84 an ABSENT key here means the default of the chart
# being installed: right for a dev-mode file, which is deployed against this
# chart, and wrong for a values file a 5.7 release stored under an older one
# (there an absent digest was the 5.7 pin) -- so the sticky and release reads
# keep _values_pin_mysql_84. Reads to EOF and decides in END (no SIGPIPE on a
# producer).
_values_mysql_engine() {
  awk -v d57="$TB_MYSQL_57_PIN_DIGEST" -v d84="$TB_MYSQL_84_DEFAULT_DIGEST" -v d84p="$TB_MYSQL_84_PRIOR_DIGEST" -v d84q="$TB_MYSQL_84_PREVIOUS_DIGEST" -v sq="'" '
    function val(line,   v) {
      v = line
      sub(/^[[:space:]]*[A-Za-z]+:[[:space:]]*/, "", v)
      sub(/[[:space:]]+#.*$/, "", v)
      gsub(/"/, "", v)
      gsub(sq, "", v)
      sub(/[[:space:]]+$/, "", v)
      return v
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*(images|mysqlClient):[[:space:]]*(null|~)[[:space:]]*$/ { nil = 1; next }
    { match($0, /^[[:space:]]*/); indent = RLENGTH }
    !inblk {
      if ($0 ~ /^[[:space:]]*mysqlClient:[[:space:]]*$/) { inblk = 1; base = indent; tag = ""; sawtag = 0; digest = ""; sawdigest = 0 }
      next
    }
    {
      if (indent <= base) {
        inblk = ($0 ~ /^[[:space:]]*mysqlClient:[[:space:]]*$/)
        if (inblk) { base = indent; tag = ""; sawtag = 0; digest = ""; sawdigest = 0 }
        next
      }
      if ($0 ~ /^[[:space:]]*tag:/)         { tag = val($0); sawtag = 1 }
      else if ($0 ~ /^[[:space:]]*digest:/) { digest = val($0); sawdigest = 1 }
    }
    END {
      if (nil) { print "5.7"; exit 0 }
      if (!sawdigest) digest = d84
      if (!sawtag) tag = "8.4"
      if (digest == d84 || digest == d84p || digest == d84q) e = "8.4"
      else if (digest == d57)  e = "5.7"
      else if (digest != "")   e = "unknown"
      else if (tag == "" || tag == "prod" || tag ~ /^5\.7/) e = "5.7"
      else if (tag ~ /^8\.4/) e = "8.4"
      else if (tag ~ /^8\.0/) e = "8.0"
      else e = "unknown"
      print e
    }
  '
}

# The logging wrapper around the rule above: sets TB_MYSQL_ENGINE_RESOLVED and
# narrates the choice. Kept separate so the rule can be consulted without
# emitting an install-time log line (preflight would otherwise log the engine
# choice minutes before the engine is chosen).
_resolve_mysql_engine() {
  local decision engine reason
  decision="$(_mysql_engine_decision)"
  engine="${decision%% *}"; reason="${decision#* }"
  if [[ "$engine" == "invalid" ]]; then
    error "TB_MYSQL_ENGINE must be 'auto', '5.7' or '8.4' (got '${reason}')"
  fi
  TB_MYSQL_ENGINE_RESOLVED="$engine"
  # WHY, not just what: the arch gate below needs to name the real cause, and
  # "existing datadir" vs "you asked for 5.7" are different fixes.
  TB_MYSQL_ENGINE_REASON="$reason"
  case "${engine} ${reason}" in
    *" explicit")           log "MySQL engine: ${engine} (explicit TB_MYSQL_ENGINE)" ;;
    "8.4 sticky")           log "MySQL engine: 8.4 (kept from this machine's existing values.yaml)" ;;
    "8.4 fresh")            log "MySQL engine: 8.4 (fresh install on ${ARCH:-$(uname -m)} — native multi-arch engine)" ;;
    "8.4 existing-release") log "MySQL engine: 8.4 (this machine's tracebloc release runs it)" ;;
    "8.4 existing-datadir") log "MySQL engine: 8.4 (this host's MySQL data is 8.x-format)" ;;
    "5.7 existing-release") log "MySQL engine: 5.7, pinned explicitly (this machine's tracebloc release runs 5.7, or its engine could not be read; the chart's default, 8.4, cannot open 5.7 data)" ;;
    "5.7 existing-datadir") log "MySQL engine: 5.7, pinned explicitly (this host holds MySQL data that is 5.7-format or could not be read; the chart's default, 8.4, cannot open 5.7 data)" ;;
  esac
}

# ── The arch gate, asked where the engine is actually known ────
# preflight's _pf_arch asks the same question early (that is the fast-fail), but
# it runs before the Helm release and the per-release namespace are known — so an
# existing edge can still look fresh there and only resolve to the amd64-only 5.7
# image here. Without this second ask, letting the fresh case through preflight
# would let that edge proceed to an exec-format CrashLoop with no earlier signal.
# Same conditions as _pf_arch: non-amd64, no emulation, no escape hatch — with a
# PER-OS emulation probe (binfmt on Linux, the macOS node's Rosetta on a Mac).
#
# macOS IS covered here. This comment used to say the opposite —
# "this gate is Linux-only … deliberately out of scope" — and stayed behind when
# the Darwin arm landed below, which reads as "macOS is ungated" to anyone who
# trusts the prose over the code. On macOS this is the ONLY gate:
# preflight only notes Rosetta on the macOS node (_pf_arch), before the engine is
# known; here the engine is resolved for real, and this refuses fail-closed.
#
# It probes the real host, so anything calling install_client_helm under test
# must declare OS/ARCH rather than inherit the machine — see install-client-helm.bats::setup.
_assert_engine_runs_on_this_arch() {
  [[ "${TB_MYSQL_ENGINE_RESOLVED:-}" == "5.7" ]] || return 0
  [[ -z "${TRACEBLOC_ALLOW_ARM64:-}" ]] || return 0
  case "${ARCH:-$(uname -m)}" in x86_64|amd64) return 0 ;; esac
  # arm64 + 5.7 needs amd64 emulation. Check it PER OS — binfmt on Linux; on a Mac,
  # whether the macOS node runs amd64 images under Rosetta (binfmt does not exist
  # there). This gate runs on macOS too: here the engine is resolved
  # for real, so an arm64 Mac that resolved to 5.7 (an existing release) without
  # Rosetta is refused.
  case "${OS:-}" in
    Linux)
      amd64_emulation_available && return 0
      ;;  # fall through to the Linux (binfmt) reason-messages below
    Darwin)
      declare -F _macos_amd64_emulation_ok >/dev/null 2>&1 && _macos_amd64_emulation_ok && return 0
      # Emulation missing (or the helper somehow absent): the macOS Rosetta
      # remedy, then exit. Do NOT fall through to the binfmt messages below.
      declare -F _macos_amd64_refusal >/dev/null 2>&1 && _macos_amd64_refusal
      error "MySQL 5.7 is required here, but amd64 emulation could not be verified on this Apple Silicon Mac — enable Rosetta and re-run (or set TRACEBLOC_ALLOW_ARM64=1 to override)." ;;
    *)
      return 0 ;;  # unknown OS: no emulation model — do not gate
  esac
  # LINUX ONLY past here. Name the actual cause, matched rather than assumed: `explicit`,
  # `existing-release`, `existing-datadir` and dev mode's `values-file` (the `*)` arm) reach
  # here, and a future reason must not inherit a false claim about this machine's data.
  # The remedy is the one preflight gives: amd64_emulation_remedy.
  local remedy; remedy="$(amd64_emulation_remedy)"
  case "${TB_MYSQL_ENGINE_REASON:-}" in
    explicit)
      warn "TB_MYSQL_ENGINE=5.7 was requested, and the MySQL 5.7 image is amd64-only — it cannot run on ${ARCH}."
      hint "Drop TB_MYSQL_ENGINE (or set TB_MYSQL_ENGINE=8.4) to use the native multi-arch 8.4 engine — fresh data directories only."
      hint "To keep 5.7, enable amd64 emulation and re-run:"
      hint "  ${remedy}"
      error "MySQL 5.7 was requested explicitly and cannot run on ${ARCH} without amd64 emulation." ;;
    existing-release)
      warn "An existing tracebloc release is installed here, so the install keeps the MySQL 5.7 engine as a data-safety default — and that image is amd64-only."
      hint "Whether this release's data is actually 5.7-format cannot be told from here: the release is detected via 'helm list', not the data directory. 5.7 is kept because 8.4 cannot open a 5.7-format datadir if one exists."
      hint "Keep the existing release — enable amd64 emulation, then re-run:"
      hint "  ${remedy}"
      hint "Or start fresh on the native 8.4 engine — this needs BOTH the release AND its retained data removed. 'helm uninstall' alone is not enough: the MySQL volume is annotated 'helm.sh/resource-policy: keep', so it survives the uninstall, and 8.4 cannot open a 5.7-format datadir, which that retained volume may be (the next run resolves to 8.4 and fails the format guard after cluster setup). Delete the retained MySQL PVC (and any host data directory) as well before re-running."
      error "MySQL 5.7 (kept for the existing release) cannot run on ${ARCH} without amd64 emulation." ;;
    existing-datadir)
      warn "This host holds existing MySQL 5.7 data, so the install must keep the MySQL 5.7 engine — and that image is amd64-only."
      hint "This is a data-format constraint, not an architecture one: MySQL 8.4 runs natively on ${ARCH}, but it cannot open a 5.7-format datadir (MySQL upgrades only in stages, 5.7 → 8.0 → 8.4)."
      hint "Keep this data — enable amd64 emulation, then re-run:"
      hint "  ${remedy}"
      hint "Or start fresh on the native 8.4 engine — uninstall any existing release, then install into an empty data directory (the existing files keep the install on 5.7):"
      hint "  --data-dir=/path/to/new/empty/dir"
      error "MySQL 5.7 is required by the existing data on this host and cannot run on ${ARCH} without amd64 emulation." ;;
    *)
      warn "This install resolved to the MySQL 5.7 engine (${TB_MYSQL_ENGINE_REASON:-unknown reason}), and that image is amd64-only — it cannot run on ${ARCH}."
      hint "Enable amd64 emulation and re-run:"
      hint "  ${remedy}"
      error "MySQL 5.7 cannot run on ${ARCH} without amd64 emulation." ;;
  esac
}
