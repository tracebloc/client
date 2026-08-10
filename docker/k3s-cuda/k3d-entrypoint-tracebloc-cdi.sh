#!/bin/sh
# =============================================================================
#  tracebloc GPU-on-WSL2 node setup — k3d entrypoint DROP-IN (#616)
# =============================================================================
# WHY THE FILENAME MATTERS: k3d does NOT use the image's ENTRYPOINT. It replaces it
# with its own /bin/k3d-entrypoint.sh, which runs every /bin/k3d-entrypoint-*.sh
# drop-in and then execs k3s. An image ENTRYPOINT wrapper is therefore silently
# never executed (that's exactly how this shipped broken the first time: the CDI spec
# was never generated, and the installer correctly fell back to CPU). So this ships as
# /bin/k3d-entrypoint-tracebloc-cdi.sh and must:
#   * RETURN (never exec k3s — k3d's entrypoint does that afterwards), and
#   * always `exit 0` — k3d runs drop-ins with `|| exit 1`, so a non-zero exit here
#     would abort the whole node. GPU is optional; it must never break the cluster.
#
# On Docker Desktop / WSL2 the NVIDIA k8s device plugin can't work (NVML returns
# ERROR_NOT_SUPPORTED through the paravirtualized GPU), so we wire the GPU into
# pods via CDI instead. This MUST run at node start: the WSL driver-store path is a
# dynamic per-machine hash, so the CDI spec has to be generated live on this node.
# Entirely no-op on a non-WSL2 node (no /dev/dxg) -> a normal (Linux/CPU) node is
# unaffected and k3s starts exactly as before.
#
# Proven recipe (validated live on an RTX 4050 laptop, driver 532.10):
#   1. nvidia-container-runtime in CDI mode (baked at image build).
#   2. `nvidia-ctk cdi generate --mode=wsl` -> /etc/cdi/nvidia.yaml.
#   3. inject libdxcore.so, which the WSL generator omits (it lives in the standard
#      lib path, not the driver store) -- without it libcuda loads but can't reach
#      /dev/dxg and CUDA fails with a misleading "driver insufficient" error.
# GPU is OPTIONAL: every step is guarded so a failure never blocks k3s from starting.

if [ -e /dev/dxg ]; then
  mkdir -p /etc/cdi 2>/dev/null || true
  nvidia-ctk cdi generate --mode=wsl --output=/etc/cdi/nvidia.yaml 2>/dev/null || true

  # Add libdxcore.so to the spec's mounts list. `nvidia-ctk cdi generate --mode=wsl` OMITS it
  # (it searches the WSL driver store; libdxcore lives in the standard lib path), and WITHOUT it
  # libcuda loads but can't reach /dev/dxg -- CUDA then fails with the misleading "CUDA driver
  # version is insufficient for CUDA runtime version".
  #
  # Indentation is MIRRORED from the generator's own first mount item, never hardcoded: YAML
  # forbids mixing indent levels within one list, so a fixed 4-space item next to the generator's
  # (differently indented) items makes the WHOLE spec unparseable -- CDI then silently injects
  # nothing and CUDA fails exactly as if the mount were missing. Anchor is also indent-agnostic.
  # libdxcore's location is NOT fixed across Docker Desktop / WSL2 versions (Bugbot): it may sit
  # in the standard lib path, under /usr/lib/wsl/lib, or inside the WSL driver store. Hardcoding
  # one path meant a miss silently skipped the injection while the spec still looked fine, so GPU
  # was advertised and pods then failed CUDA with the misleading driver error. Probe the known
  # locations, then fall back to the linker cache. Mounted at the path where it was found, so the
  # in-pod loader resolves it the same way the node does.
  DXCORE=""
  for _c in /usr/lib/x86_64-linux-gnu/libdxcore.so /usr/lib/wsl/lib/libdxcore.so \
            /usr/lib/wsl/drivers/*/libdxcore.so /usr/lib/libdxcore.so; do
    if [ -f "$_c" ]; then DXCORE="$_c"; break; fi
  done
  if [ -z "$DXCORE" ]; then
    _c="$(ldconfig -p 2>/dev/null | awk '/libdxcore\.so/ { print $NF; exit }')"
    if [ -n "$_c" ] && [ -f "$_c" ]; then DXCORE="$_c"; fi
  fi

  if [ -f /etc/cdi/nvidia.yaml ] && [ -n "$DXCORE" ] \
       && ! grep -q 'libdxcore\.so' /etc/cdi/nvidia.yaml; then
    awk -v dx="$DXCORE" '
      # remember the indent of the first list item that follows a `mounts:` key
      !done && $0 ~ /^[[:space:]]*mounts:[[:space:]]*$/ { inmounts = 1; print; next }
      inmounts && !done && match($0, /^[[:space:]]*-[[:space:]]/) {
        item = substr($0, 1, RLENGTH - 2)          # leading whitespace before the dash
        keys = item "  "                            # mapping keys sit one level deeper
        print item "- hostPath: " dx
        print keys "containerPath: " dx
        print keys "options:"
        print keys "- ro"
        print keys "- nosuid"
        print keys "- nodev"
        print keys "- rbind"
        done = 1
        print                                       # then the generator item we matched
        next
      }
      { print }
    ' /etc/cdi/nvidia.yaml > /etc/cdi/nvidia.yaml.new 2>/dev/null || true
    # Only adopt the edit if the result still PARSES as a CDI spec -- otherwise keep the original
    # (GPU without libdxcore beats a broken spec that disables the GPU entirely and silently).
    #
    # The revert is gated on `cdi list` EXISTING, exactly like the cdi_ok check below (Bugbot):
    # that subcommand is version-dependent, so calling it unconditionally meant a toolkit without
    # it reverted a PERFECTLY GOOD injection -- and the installer then reported "spec is missing
    # libdxcore", which is false and unactionable. Revert only when the parser is available AND
    # actively rejects the result.
    if [ -s /etc/cdi/nvidia.yaml.new ] && grep -q 'libdxcore\.so' /etc/cdi/nvidia.yaml.new; then
      cp /etc/cdi/nvidia.yaml /etc/cdi/nvidia.yaml.orig 2>/dev/null || true
      mv /etc/cdi/nvidia.yaml.new /etc/cdi/nvidia.yaml 2>/dev/null || true
      if nvidia-ctk cdi list --help >/dev/null 2>&1; then
        if ! nvidia-ctk cdi list >/dev/null 2>&1; then
          mv /etc/cdi/nvidia.yaml.orig /etc/cdi/nvidia.yaml 2>/dev/null || true
        fi
      fi
    fi
    rm -f /etc/cdi/nvidia.yaml.new /etc/cdi/nvidia.yaml.orig 2>/dev/null || true
  fi

  # Is CDI injection actually USABLE? Advertising nvidia.com/gpu without it is worse than not
  # advertising at all: pods schedule onto a device they can't use and fail CUDA with a
  # misleading driver error, and no cluster-level signal says why (Bugbot, HIGH). The installer
  # already refuses in that case, but this reconciler runs again on every restart -- so it must
  # apply the SAME standard rather than re-asserting capacity onto a broken node.
  # Structural checks first, and NOT gated on `nvidia-ctk cdi list` existing: that subcommand is
  # version-dependent, so keying the decision on it would disable a perfectly working GPU on a
  # toolkit build that lacks it (a false negative on someone else's machine). We require the spec
  # to be non-empty, to declare the nvidia.com/gpu kind, to expose /dev/dxg, and to carry our
  # libdxcore mount -- all format-stable facts. `cdi list` is then used only as an EXTRA veto when
  # it is available, so a spec it actively rejects still can't advertise a GPU.
  cdi_ok=0
  if [ -s /etc/cdi/nvidia.yaml ] \
       && grep -q 'nvidia\.com/gpu' /etc/cdi/nvidia.yaml \
       && grep -q '/dev/dxg' /etc/cdi/nvidia.yaml \
       && grep -q 'libdxcore\.so' /etc/cdi/nvidia.yaml; then
    cdi_ok=1
    if nvidia-ctk cdi list --help >/dev/null 2>&1; then
      nvidia-ctk cdi list >/dev/null 2>&1 || cdi_ok=0
    fi
  fi

  # Keep nvidia.com/gpu advertised across restarts (Bugbot, HIGH). A manually patched
  # extended resource is NOT durable: the kubelet re-reports node status on every
  # start, zeroing it -- so after a Docker Desktop or Windows restart the installer's
  # one-shot patch is gone, the chart still requests a GPU, and every job would sit
  # Pending with "Insufficient nvidia.com/gpu" until someone re-ran the installer.
  # There's no device plugin to own the resource here, so this node re-asserts it
  # itself: a background reconciler waits for the local API, then re-patches whenever
  # the capacity is missing. Runs on EVERY node start (k3d runs this drop-in each time),
  # so a reboot self-heals with no user action. Fully guarded + backgrounded: it can
  # never delay or block k3s. Interval override: TRACEBLOC_GPU_RECONCILE_SECS.
  # Gated on cdi_ok so a broken/incomplete CDI spec never gets a GPU advertised onto it.
  #
  # Fully DETACHED (</dev/null, output to /dev/null): this drop-in exits immediately after
  # forking, so the loop is orphaned and reparented to PID 1 (k3s, which k3d's entrypoint
  # execs). Holding the inherited stdio would risk blocking on a closed pipe.
  if [ "$cdi_ok" = "1" ]; then
  (
    interval="${TRACEBLOC_GPU_RECONCILE_SECS:-60}"
    kube="/etc/rancher/k3s/k3s.yaml"
    while :; do
      if [ -s "$kube" ]; then
        current="$(/bin/k3s kubectl --kubeconfig "$kube" get node "$(hostname)" \
          -o "jsonpath={.status.capacity.nvidia\\.com/gpu}" \
          --request-timeout=10s 2>/dev/null || true)"
        case "$current" in
          ''|0)
            /bin/k3s kubectl --kubeconfig "$kube" patch node "$(hostname)" \
              --subresource=status --type=json --request-timeout=15s \
              -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"1"}]' \
              >/dev/null 2>&1 || true
            ;;
        esac
      fi
      sleep "$interval"
    done
  ) </dev/null >/dev/null 2>&1 &
  fi
fi

# Return control to k3d's entrypoint, which runs the remaining drop-ins and then execs
# k3s. ALWAYS 0: k3d aborts the node on a non-zero drop-in exit, and GPU is optional.
exit 0
