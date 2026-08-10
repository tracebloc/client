#!/bin/sh
# =============================================================================
#  tracebloc GPU-on-WSL2 boot setup (#616)
# =============================================================================
# On Docker Desktop / WSL2 the NVIDIA k8s device plugin can't work (NVML returns
# ERROR_NOT_SUPPORTED through the paravirtualized GPU), so we wire the GPU into
# pods via CDI instead. This MUST run at node boot: the WSL driver-store path is a
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
fi

exec /bin/k3s "$@"
