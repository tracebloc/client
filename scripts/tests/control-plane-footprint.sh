#!/usr/bin/env bash
#
#  control-plane-footprint.sh — how much memory and CPU the chart's own control
#  plane REQUESTS, summed from the rendered chart, ratcheted so it cannot grow
#  worse without a conscious decision (backend#2870, part of RFC-BACKEND-664).
#
#  WHY THIS EXISTS
#  ---------------
#  A training pod is sized `node_allocatable − overhead`, where `overhead` is a
#  single embedded constant (`_TB_ENVELOPE_OVERHEAD_MEM_BYTES`, 3 GiB) meant to
#  stand in for everything that is NOT the training pod: kubelet, the runtime,
#  and this chart's control plane. backend#2870's finding is that NOTHING sums
#  what the control plane actually requests, so nobody can tell whether that one
#  constant still covers it. Grep the three consumers for `3008`, `platform
#  footprint`, `control plane requests`: zero hits. The number was invisible.
#
#  Measured here by rendering the chart: the steady-state control plane requests
#  ~3136 MiB, already ABOVE the 3 GiB (3072 MiB) the envelope reserves for it.
#  That 64 MiB overshoot is the memory half of the reason a training pod on a
#  freshly-installed single-node edge can sit `Pending / Insufficient memory`
#  (backend#2870). CPU fits: 900m requested against a 1000m reserve.
#
#  WHAT THIS GUARD DOES, AND DELIBERATELY DOES NOT
#  -----------------------------------------------
#  It does NOT assert schedulability (`footprint <= overhead`). That assertion is
#  RED today by construction, and making it green needs measured, per-platform
#  kubelet reservations (backend#2460) and/or a control-plane request trim under
#  load (backend#2461) -- both empirical campaigns, neither a code change. Landing
#  a red gate would train people to skip the tier (org rule 4).
#
#  It RATCHETS instead: the footprint may not grow past the recorded ceiling. A
#  chart change that adds a component or raises a request -- making an already
#  tight fit worse, silently, on every edge -- reddens here and forces the author
#  to see the schedulability cost and bump the ceiling on purpose. It also REPORTS
#  the current gap against the reserve, so the number backend#2460/#2461 must
#  close is tracked rather than rediscovered.
#
#  IT DERIVES, IT DOES NOT RESTATE (backend#1729). The footprint is summed from
#  `helm template`, the ground truth of what installs; the reserve is parsed from
#  the installer's own embedded constant, not a second copy. The only written-down
#  numbers are the ratchet ceilings, and a ceiling is a bound to hold under, not a
#  restatement of the render -- raising a request is what moves it.
#
set -euo pipefail

# --print-footprint (backend#2870, DoD part 1): the same render and the same
# ratchet, but the ONLY thing on stdout is `<mem MiB> <cpu m>` for the worst
# profile. That pair is what scripts/gen-footprint-embed.sh embeds into the
# installer and what scripts/tests/envelope-schedulability.sh verifies every
# golden vector against -- so the installer's footprint is DERIVED from this
# render, never typed. Everything informational moves to stderr so a caller can
# `read -r mem cpu` without parsing prose; a breached ratchet still exits 1 and
# prints nothing on stdout, so a caller cannot read a refused run as a number.
PRINT=0
case "${1:-}" in
  '') ;;
  --print-footprint) PRINT=1; exec 3>&1 1>&2 ;;
  *) echo "usage: $0 [--print-footprint]" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TB_CP_FOOTPRINT_ROOT lets this guard's own test point it at a fixture tree.
root="${TB_CP_FOOTPRINT_ROOT:-$(cd "$here/../.." && pwd)}"
chart="$root/client"
installer="$root/scripts/lib/install-client-helm.sh"

# THE RATCHET CEILINGS. Current measured steady-state control-plane requests,
# consistent across every client/ci/*-values.yaml profile (2026-09-01). A change
# that pushes the footprint above either of these must raise the ceiling in the
# same PR -- which is the moment to weigh whether the training envelope can still
# afford it. Overridable so the guard's own test can drive a lower ceiling and
# watch a real render breach it.
MEM_CEIL_MIB="${TB_CP_FOOTPRINT_MEM_CEIL:-3136}"
CPU_CEIL_MILLI="${TB_CP_FOOTPRINT_CPU_CEIL:-900}"

command -v helm >/dev/null 2>&1 || { echo "[ERROR] helm is required to render the chart footprint" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "[ERROR] python3 is required to sum the rendered requests" >&2; exit 3; }
[ -d "$chart" ] || { echo "[ERROR] no chart at $chart -- refusing to report a footprint I could not render" >&2; exit 1; }
[ -f "$installer" ] || { echo "[ERROR] no installer at $installer -- cannot read the reserve to compare against" >&2; exit 1; }

# THE RESERVE, DERIVED from the installer's embedded constant, not restated. A
# `\b` word match on the exact assignment; missing it is a finding, not a pass.
# awk, not `sed ... | head -1`: `head` closes the pipe early, which the org
# pipefail gate flags (SIGPIPE on the upstream would be masked under pipefail).
# awk `exit`s after the FIRST match -- one process, no pipe -- and is portable
# across the BSD sed on macOS and GNU sed in CI (the `{s;q}` sed form is not).
reserve_bytes="$(awk -F= '$1=="_TB_ENVELOPE_OVERHEAD_MEM_BYTES"{v=$2; sub(/[^0-9].*/,"",v); print v; exit}' "$installer")"
reserve_cpu_milli="$(awk -F= '$1=="_TB_ENVELOPE_OVERHEAD_CPU_MILLI"{v=$2; sub(/[^0-9].*/,"",v); print v; exit}' "$installer")"
if [ -z "$reserve_bytes" ] || [ -z "$reserve_cpu_milli" ]; then
  echo "[ERROR] could not read _TB_ENVELOPE_OVERHEAD_{MEM_BYTES,CPU_MILLI} from $installer." >&2
  echo "        The reserve moved or was renamed; this guard compares against it and cannot 'cannot tell' into a pass." >&2
  exit 1
fi
reserve_mib=$(( reserve_bytes / 1024 / 1024 ))

profiles=("$chart"/ci/*-values.yaml)
[ -e "${profiles[0]}" ] || { echo "[ERROR] no client/ci/*-values.yaml to render against -- this guard would check nothing" >&2; exit 1; }

worst_mem=0
worst_cpu=0
fail=0
# The summer, INLINE in this .sh with a shell-level PyYAML preflight (Bugbot,
# backend#2870). A separate `.py` sidecar carried a top-level `import yaml` that
# `pyyaml-preflight.bats` does not scan (it reads `.sh`/`.bats`), so a runner with
# python3 but no PyYAML would die as a bare traceback. Inlined, the import lives in
# the heredoc the preflight guard already checks, and a missing module is a NAMED
# refusal. STEADY STATE ONLY -- Deployment/StatefulSet/DaemonSet, never Job/CronJob
# (the egress-reachability and storage-assertions hooks are one-shot and exit); a
# DaemonSet is one replica per node, x1 on the single-node edge this ticket is about.
# $1 = a file of rendered manifests. Read from the FILE, not stdin: `python3 -
# <<'PY'` already occupies stdin with the heredoc, so a piped manifest would never
# arrive -- the sibling guards pass their input as an argv for exactly this reason.
_sum_requests() {
  python3 - "$1" <<'PY'
import sys, re
try:
    import yaml
except ImportError:
    sys.exit("[ERROR] PyYAML required (pip install pyyaml)")
# The FULL Kubernetes memory-quantity grammar, and FAIL CLOSED on anything else
# (Bugbot, backend#2870). The first version matched only Ki|Mi|Gi|Ti and silently
# returned 0 otherwise -- so a valid `250M` (decimal) or a plain-byte integer would
# count as ZERO, undercount the footprint and slip the ratchet, which is the exact
# blind spot this guard exists to remove. A quantity that is present but
# unrecognised is a finding, not a free pass: raise so the guard refuses.
_BIN={'Ki':2**10,'Mi':2**20,'Gi':2**30,'Ti':2**40,'Pi':2**50,'Ei':2**60}
_DEC={'k':1e3,'M':1e6,'G':1e9,'T':1e12,'P':1e15,'E':1e18}
_MIB=2**20
def mib(v):
    if v in (None, ''): return 0.0
    s=str(v).strip()
    m=re.match(r'^(\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)([A-Za-z]+)?$', s)
    if not m:
        raise ValueError("unparseable memory quantity %r" % v)
    num=float(m.group(1)); suf=m.group(2)
    if suf is None:      bytes_=num                 # a bare number is BYTES (k8s)
    elif suf in _BIN:    bytes_=num*_BIN[suf]
    elif suf in _DEC:    bytes_=num*_DEC[suf]
    else:                raise ValueError("unknown memory unit %r in %r" % (suf, v))
    return bytes_/_MIB
def milli(v):
    if v in (None, ''): return 0.0
    s=str(v).strip()
    if s.endswith('m'):
        try: return float(s[:-1])
        except ValueError: raise ValueError("unparseable cpu quantity %r" % v)
    try: return float(s)*1000                       # cores -> millicores
    except ValueError: raise ValueError("unparseable cpu quantity %r" % v)
mem=cpu=0.0; n=0
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        for d in yaml.safe_load_all(fh):
            if not d: continue
            if d.get('kind') not in ('Deployment','StatefulSet','DaemonSet'): continue
            reps=1 if d.get('kind')=='DaemonSet' else (d.get('spec',{}).get('replicas',1) or 1)
            sp=d.get('spec',{}).get('template',{}).get('spec',{}) or {}
            # THE SCHEDULER'S FORMULA, NOT sum(everything) (@aptracebloc nit 1).
            #
            # A pod's effective request per resource is
            #   max( sum(app containers), max(init containers) )
            # because init containers run to completion ONE AT A TIME before the
            # app containers start -- they are never resident alongside them.
            # Summing both CONTRADICTED this guard's own "STEADY STATE ONLY" note
            # and inflated the figure the ceiling is compared against. Conservative
            # is not harmless here: this number is the input to backend#2460/#2461,
            # so an inflated one sends that work after MiB no scheduler reserves.
            #
            # PER-RESOURCE, not per-pod: k8s takes the max independently for memory
            # and cpu, so a pod can take its memory from the init side and its cpu
            # from the app side.
            #
            # THE NUMBER DOES NOT MOVE ON THIS CHART -- 3136 MiB / 900 m either way,
            # because these init containers carry no requests. So the "64 MiB OVER"
            # finding stands; the method was wrong, the conclusion was not. It also
            # means the fix is INERT on the real render, which is why the bats
            # fixture is built so the two formulas disagree.
            def _req(c, key):
                return ((c.get('resources', {}) or {}).get('requests') or {}).get(key)
            apps  = sp.get('containers', []) or []
            inits = sp.get('initContainers', []) or []
            csum_m = sum(mib(_req(c, 'memory')) for c in apps)
            csum_c = sum(milli(_req(c, 'cpu')) for c in apps)
            imax_m = max([mib(_req(c, 'memory')) for c in inits] or [0.0])
            imax_c = max([milli(_req(c, 'cpu')) for c in inits] or [0.0])
            for c in apps + inits:
                r=(c.get('resources',{}) or {}).get('requests') or {}
                if r.get('memory') or r.get('cpu'): n+=1
            mem += max(csum_m, imax_m)*reps
            cpu += max(csum_c, imax_c)*reps
except ValueError as exc:
    # FAIL CLOSED: a quantity we cannot read is not a footprint of zero. Refusing
    # is the whole posture of this guard -- a silent 0 would undercount and pass.
    sys.exit("[ERROR] %s -- refusing to sum a footprint from a quantity this guard cannot parse" % exc)
print(f"{mem:.0f} {cpu:.0f} {n}")
PY
}

# Render one profile, or -- when TB_CP_FOOTPRINT_FIXTURE points at a manifest --
# read that instead, so the arithmetic can be tested on a KNOWN render without helm.
_render_profile() {
  local vf="$1"
  if [ -n "${TB_CP_FOOTPRINT_FIXTURE:-}" ]; then
    cat "$TB_CP_FOOTPRINT_FIXTURE"
    return   # propagate cat's status -- an unreadable fixture is a failed render
  fi
  helm template be "$chart" --set image.tag=footprint-probe -f "$vf"
}

for vf in "${profiles[@]}"; do
  prof="$(basename "$vf" -values.yaml)"
  # A FAILED render is not a smaller footprint (Bugbot, backend#2870). helm streams
  # documents, so a template error partway through still emits YAML for the earlier
  # resources -- an undercount that would sit under the ceiling and print OK while
  # hiding the error. Capture helm's EXIT CODE and refuse on non-zero, rather than
  # `|| true`-ing it into a success.
  # `mktemp`, not /tmp/...$$ (Bugbot Low): a PID-predictable path in a world-
  # writable dir is a symlink-clobber vector and can collide; mktemp is unguessable.
  rendered=""
  errf="$(mktemp "${TMPDIR:-/tmp}/cp-footprint-helm.XXXXXX")"
  if ! rendered="$(_render_profile "$vf" 2>"$errf")"; then
    echo "[ERROR] $prof: the render exited non-zero, so its footprint is incomplete: $(tail -1 "$errf" 2>/dev/null)" >&2
    rm -f "$errf"
    fail=1
    continue
  fi
  rm -f "$errf"
  if [ -z "$rendered" ]; then
    echo "[ERROR] $prof: the chart rendered nothing -- a footprint cannot be summed from an empty render." >&2
    fail=1
    continue
  fi
  # `_sum_requests` exits non-zero (the PyYAML refusal) rather than printing a sum;
  # propagate that as a finding instead of reading an empty `summed` as zero.
  mf="$(mktemp)"; printf '%s' "$rendered" > "$mf"
  if ! summed="$(_sum_requests "$mf")"; then
    echo "[ERROR] $prof: could not sum the rendered requests ($summed)." >&2
    rm -f "$mf"; fail=1; continue
  fi
  rm -f "$mf"
  read -r mem cpu n <<<"$summed"
  if [ -z "${n:-}" ] || [ "${n:-0}" -eq 0 ]; then
    echo "[ERROR] $prof: rendered workloads carried ZERO resource requests -- the sum walked nothing, which is not the same as a footprint of zero." >&2
    fail=1
    continue
  fi
  echo "  $prof: control plane requests ${mem} MiB / ${cpu} m (from ${n} container(s))"
  (( mem > worst_mem )) && worst_mem=$mem
  (( cpu > worst_cpu )) && worst_cpu=$cpu
done

[ "$fail" -eq 0 ] || exit 1

# THE RATCHET.
if (( worst_mem > MEM_CEIL_MIB )); then
  echo "[ERROR] control-plane memory requests ${worst_mem} MiB exceed the recorded ceiling ${MEM_CEIL_MIB} MiB." >&2
  echo "        A chart change raised the footprint. Every MiB here is a MiB the training envelope loses on every edge," >&2
  echo "        and the footprint is ALREADY above the ${reserve_mib} MiB reserve (backend#2870). If the increase is intended," >&2
  echo "        raise TB_CP_FOOTPRINT_MEM_CEIL's default in this file -- and weigh whether backend#2460/#2461 must land first." >&2
  fail=1
fi
if (( worst_cpu > CPU_CEIL_MILLI )); then
  echo "[ERROR] control-plane cpu requests ${worst_cpu} m exceed the recorded ceiling ${CPU_CEIL_MILLI} m (backend#2870)." >&2
  echo "        Raise TB_CP_FOOTPRINT_CPU_CEIL's default in this file if intended." >&2
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1

# The machine-readable answer, on the stdout saved above -- and ONLY after the
# ratchet, so a footprint that breached it is never handed out as a number.
if (( PRINT )); then
  printf '%s %s\n' "$worst_mem" "$worst_cpu" >&3
  exit 0
fi

# THE GAP, reported not asserted (see the header). Positive = the control plane
# already out-requests its reserve; that overshoot is what backend#2460 (measured
# kubelet reservation) and backend#2461 (control-plane trim) exist to close.
mem_gap=$(( worst_mem - reserve_mib ))
cpu_gap=$(( worst_cpu - reserve_cpu_milli ))
if (( mem_gap > 0 )); then
  echo "  note: the control plane requests ${worst_mem} MiB against a ${reserve_mib} MiB reserve -- ${mem_gap} MiB OVER."
  echo "        This is the memory half of the unschedulable gap (backend#2870); closing it is backend#2460/#2461, not this guard."
else
  echo "  note: control-plane memory ${worst_mem} MiB fits within the ${reserve_mib} MiB reserve (${mem_gap#-} MiB headroom)."
fi
(( cpu_gap > 0 )) \
  && echo "  note: control-plane cpu ${worst_cpu} m is ${cpu_gap} m OVER the ${reserve_cpu_milli} m reserve." \
  || echo "  note: control-plane cpu ${worst_cpu} m fits the ${reserve_cpu_milli} m reserve (${cpu_gap#-} m headroom)."

echo "control-plane-footprint: OK -- ${worst_mem} MiB / ${worst_cpu} m, at or under the recorded ceiling."
