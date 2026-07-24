# RFC 0001 — Spike: rootless Docker as the k3d backend

**Ticket:** tracebloc/backend#1176 · **Epic:** tracebloc/backend#1168 · **RFC:** [0001-least-privilege-install.md](./0001-least-privilege-install.md)
**Status:** analysis + validation plan (preliminary go/no-go). The experiments in §5 need real target hosts before Tier 1 (#1177) ships.

## 0. Why this spike gates Tier 1

Asad's review made **rootless Docker the primary target** (Tier 1), which is what removes the kernel modules from the privileged surface. Before we commit the Tier-1 build (#1177) we must confirm rootless Docker actually works as our **k3d backend** across the hosts our users have — and that the `push` (dataset-copy) path stays fast enough on rootless storage. This doc collects what's knowable from documented behaviour and defines the experiments that must run on real hosts.

## 1. The one thing that must be true: unprivileged containers

Rootless Docker needs the kernel to allow **unprivileged user namespaces** and to be on **cgroup v2** (for resource delegation). Probe (from `probe.sh`, #1171):

- `/sys/fs/cgroup/cgroup.controllers` exists → unified cgroup v2.
- `/proc/sys/user/max_user_namespaces` > 0, and (Debian/Ubuntu) `kernel.unprivileged_userns_clone` == 1 where present.

**Expected coverage (documented defaults — must be confirmed per §5):**

| Distro / image | cgroup v2 default | unprivileged userns default | Expected tier |
|---|---|---|---|
| Ubuntu 22.04 / 24.04 | yes (since 21.10) | enabled | 1 (rootless) or 0 |
| Debian 12 (bookworm) | yes | enabled | 1 or 0 |
| RHEL / Alma / Rocky 9 | yes | enabled | 1 or 0 |
| RHEL / CentOS 7–8 | no (v1) / mixed | often restricted | **2 (prepare-host)** |
| openSUSE Leap 15.6 | yes | enabled | 1 or 0 |
| Amazon Linux 2 | no (v1) | restricted | **2** |
| Hardened / HPC login nodes | varies | **often disabled** (`user.max_user_namespaces=0`, or `kernel.unprivileged_userns_clone=0`) | **2** |

The honest-failure path (Tier 2 → `prepare-host`) exists precisely for the bottom rows.

## 2. Rootless Docker install — the mechanics

The `dockerd-rootless-setuptool.sh` flow (shipped with Docker's rootless extras) or `curl -fsSL https://get.docker.com/rootless | sh`:

1. Requires `uidmap` (the `newuidmap`/`newgidmap` setuid helpers) and per-user **subordinate UID/GID ranges** in `/etc/subuid` + `/etc/subgid`.
   - **This is the one place a privileged touch may still be needed** on a fresh host: if the user has no subuid/subgid range, an admin adds one line each. That is a *named, one-time* Tier-2/prepare-host action — not blanket sudo, and not per-install.
2. Installs `dockerd-rootless.sh`; starts it under **systemd --user** (`systemctl --user enable --now docker`), or a `nohup`/`XDG_RUNTIME_DIR` fallback where user-systemd is absent (some HPC nodes).
3. Socket lands at `$XDG_RUNTIME_DIR/docker.sock`; `DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock`.

**Constraint for #1177:** detect the subuid/subgid precondition and, when missing + unprivileged, route to `prepare-host` with the exact two lines to add — never fail opaquely.

## 3. k3d on the rootless socket

k3d is k3s-in-Docker; it talks to whatever `DOCKER_HOST` points at. Known rootless caveats to validate:

- **cgroup delegation**: k3s (inside the k3d node container) needs delegated cgroup controllers. With systemd --user, add the delegation drop-in (`Delegate=cpu cpuset io memory pids`). Without delegation, pods can't get CPU/memory limits — the chart *sets* limits, so this must work.
- **Loading kernel modules from inside the node**: k3s may try `modprobe` for networking; rootless can't. k3s flannel/VXLAN generally works via the userspace path, but confirm the client's `network_policy` + `requests-proxy` egress still function.
- **Port mapping < 1024**: the client doesn't need privileged host ports (traffic is via the k3d loadbalancer on high ports), but confirm the dashboard/registration flow doesn't assume a low host port.

## 4. The performance risk: fuse-overlayfs and `push`

Rootless Docker uses **fuse-overlayfs** (userspace) instead of the kernel `overlay` driver. Large-file I/O through FUSE is measurably slower. Our **`push`** path copies datasets into the environment — if fuse-overlayfs makes a multi-GB ingest crawl, that's a real UX regression, not a cosmetic one.

**Must measure (§5):** `tracebloc data ingest` wall-clock on rootless (fuse-overlayfs) vs a rooted install (native overlay) for a representative dataset (e.g. 1–5 GB). Decide an acceptable ceiling; if fuse-overlayfs is too slow, evaluate the native-overlay-in-rootless option (kernel ≥ 5.11 + `overlayfs` unprivileged support) as a fast path.

## 5. Validation plan — the experiments (need real hosts)

Run on: Ubuntu 24.04, Debian 12, RHEL/Rocky 9, openSUSE Leap 15.6, **and at least one hardened/HPC-style node** (userns disabled) to exercise the Tier-2 fall-through.

1. **Probe accuracy** — `probe.sh` classifies each host at the expected tier (§1 table). Confirm no false Tier-1 on a userns-disabled host.
2. **Rootless install** — `dockerd-rootless-setuptool.sh` completes as a non-root user; note whether subuid/subgid was pre-present or needed a prepare-host touch.
3. **k3d up** — cluster creates + all client workloads reach Ready on the rootless socket, with cgroup delegation.
4. **End-to-end** — sign-in, register, and a real `tracebloc data ingest` succeed.
5. **Perf** — ingest wall-clock, rootless vs rooted, for a 1–5 GB dataset. Record the ratio.
6. **Fall-through** — on the hardened node, the installer reaches Tier 2 and prints the exact `prepare-host` remedy (no opaque failure).

## 6. Preliminary go / no-go

**Provisional GO** for rootless-Docker-primary, conditioned on §5:

- ✅ Kernel prerequisites are default-on across our mainstream targets (Ubuntu/Debian/RHEL 9/SUSE) — most users land at Tier 0 or Tier 1 with no admin.
- ✅ The privileged residue shrinks to (a) subuid/subgid on some fresh hosts and (b) genuinely old/locked kernels — both handled by a *named* one-time `prepare-host`.
- ⚠️ **Blocking unknowns for #1177:** (1) fuse-overlayfs `push` performance (§4/§5.5); (2) k3s cgroup delegation under systemd --user (§3); (3) HPC nodes without user-systemd (need the nohup fallback).

**Recommendation:** proceed to build #1177 behind these results. If §5.5 shows fuse-overlayfs is unacceptably slow for ingests, add native-overlay-in-rootless as the fast path and keep fuse-overlayfs as the fallback. Nothing here blocks #1172 (routing) or #1175 (Tier 0), which don't depend on rootless.

---
*Spike deliverable for #1176. The §5 experiments require real target hosts / CI runners with the relevant kernels — they can't be run from a dev laptop. Assign a runner matrix or a manual pass before #1177 leaves draft.*
