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

  # Add libdxcore.so to the spec's top-level mounts list if it's missing. Matches the
  # `  mounts:` line (2-space, top-level containerEdits) and inserts one entry after it.
  if [ -f /etc/cdi/nvidia.yaml ] && [ -f /usr/lib/x86_64-linux-gnu/libdxcore.so ] \
       && ! grep -q 'libdxcore\.so' /etc/cdi/nvidia.yaml; then
    awk '
      /^  mounts:$/ && !done {
        print
        print "    - hostPath: /usr/lib/x86_64-linux-gnu/libdxcore.so"
        print "      containerPath: /usr/lib/x86_64-linux-gnu/libdxcore.so"
        print "      options:"
        print "      - ro"
        print "      - nosuid"
        print "      - nodev"
        print "      - rbind"
        done = 1
        next
      }
      { print }
    ' /etc/cdi/nvidia.yaml > /etc/cdi/nvidia.yaml.new 2>/dev/null \
      && mv /etc/cdi/nvidia.yaml.new /etc/cdi/nvidia.yaml 2>/dev/null || true
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
  #
  # Fully DETACHED (</dev/null, output to /dev/null): this drop-in exits immediately after
  # forking, so the loop is orphaned and reparented to PID 1 (k3s, which k3d's entrypoint
  # execs). Holding the inherited stdio would risk blocking on a closed pipe.
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

# Return control to k3d's entrypoint, which runs the remaining drop-ins and then execs
# k3s. ALWAYS 0: k3d aborts the node on a non-zero drop-in exit, and GPU is optional.
exit 0
