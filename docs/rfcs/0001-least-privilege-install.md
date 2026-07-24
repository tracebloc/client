# RFC 0001 — Least-privilege install

**Status:** Decisions recorded 2026-07-22, revised after @saadqbal review (rootless Docker primary) — one validation spike open
**Author:** Lukas (drafted with Claude)
**Reviewers:** @saadqbal
**Repos affected:** `client` (installer), `cli` (CLI install + PATH)
**Related:** backlog A2 (sudo/root handling), A3 (rootless), B2 (post-install PATH)

## Summary

The installer today assumes the operator has **root / blanket sudo**. That
assumption silently excludes a large and important slice of our users —
**data scientists and researchers on machines they don't administer**
(hospitals, universities, HPC login nodes). They may have an admin somewhere,
or not, and they can rarely get "give me sudo."

This RFC argues we should require the **minimum privilege actually needed** to
stand up a secure environment, and design the install as **tiers** that degrade
gracefully — from "zero root" up to "one clearly-scoped privileged step" — never
a blanket sudo demand up front. The goal: a non-admin researcher can install on
their instance with, ideally, **no elevated rights at all**, or at worst a
single nameable request an admin can grant once.

## Motivation

Our ICP includes the hospital/university data scientist who has a powerful
machine (or a slice of a shared one) and wants to run tracebloc on their own
data. Two real installs this week hit the wall:

- A shared cluster login node (`/data01/home/…`), regular user, no `sudo`
  installed → the installer aborted at "needs your password" with a misleading
  "re-run with a user that has sudo access."
- Even where sudo exists, requiring it is a non-starter in environments where
  admin is one central IT team for the whole institution.

If "install tracebloc" reads as "get root on a managed machine," we lose these
users before they start.

## Current state — what actually needs root

Audit of every `sudo` call site in the installer (`scripts/lib/setup-linux.sh`,
`setup-macos.sh`, `install-cli.sh`, `cluster.sh`). **Every one is about the
container runtime or its kernel/daemon prerequisites** — nothing else:

| Touchpoint | Where | Why root |
|---|---|---|
| Install Docker (apt/dnf/yum/zypper/pacman, get.docker.com, Docker Desktop) | setup-linux/macos | system package / daemon |
| `usermod -aG docker $USER` | setup-linux | add user to the docker group |
| `modprobe br_netfilter/overlay` + `/etc/modules-load.d/tracebloc.conf` | setup-linux | k3s kernel prereqs |
| Docker daemon proxy config `/etc/systemd/system/docker.service.d/…` + `systemctl daemon-reload/restart` | setup-linux | daemon config |
| `systemctl enable/start docker` | setup-linux | start the daemon |
| `rm -rf /Applications/Docker.app` (wrong-arch/uninstall only) | setup-macos | protected paths |

**What does NOT need root, today, already:** the CLI tools — `kubectl`, `helm`,
`k3d`, and the `tracebloc` CLI itself — are downloaded to `~/.local/bin`
(`install-cli.sh`), no sudo. And the environment itself (k3d = k3s-in-Docker,
plus kubectl/helm operations) runs **inside Docker as the user** — no additional
root once a usable Docker exists.

**The insight:** we don't need "admin." We need **a usable container runtime**.
On Linux, a *system* Docker also pulls in two kernel modules — but **rootless
Docker removes even those from the privileged surface** (`overlay` →
fuse-overlayfs in userspace; `br_netfilter` → unneeded once networking goes
through slirp4netns). So if we make rootless the primary target, the entire
privileged surface collapses to a single question — *can this user run a
container at all?* — which on any modern kernel (cgroup v2 + unprivileged
userns, default-on for Ubuntu 22.04+ / RHEL 9+) is **yes, with no root**.
Everything else — kubectl, helm, k3d, the CLI, the k3d/k3s cluster — is already
user-space.

## Proposal — tiered, least-privilege install

Probe the machine and pick the **lowest tier that works**, instead of demanding
sudo up front:

> **Runtime decision (updated 2026-07-22, post-review): rootless Docker is the
> *primary* target.** Docker stays the one supported runtime, but we lead with
> **rootless Docker**, not system Docker. It keeps the entire k3d code path
> intact (just a different socket), it's a genuine security *selling point* to
> hospital/uni IT, and — critically — it removes the kernel modules from the
> privileged surface entirely (see the insight above). Podman-as-k3d-backend is
> too flaky to be primary (best-effort only); k3s-rootless is the cleaner
> long-term end state but a bigger rewrite — parked as a future spike, not a
> competing option now. *(First draft had system Docker primary with rootless as
> a fallback; Asad's review flipped this, which is what dissolves the
> kernel-module question below.)*

**Tier 0 — zero root (the common case).**
The user can already run a container — rootless Docker is already up, **or** the
user is in the `docker` group. Then: download tools to `~/.local/bin`, create
the k3d/k3s cluster in the existing runtime, register, done. **No sudo at any
point.** Many hospital/HPC boxes already provide one of these; detect and use it.

**Tier 1 — set up rootless Docker as the user (the primary path when nothing
exists yet).**
No runtime yet, but the kernel supports unprivileged containers (cgroup v2 +
unprivileged userns — default-on for Ubuntu 22.04+ / RHEL 9+). Install rootless
Docker into the user's account and run everything through it. On a modern kernel
this needs **no root**; on some hosts it needs a **one-time, narrow** privileged
touch (subuid/subgid ranges or a single `sysctl`) — nameable and grantable, not
blanket admin. **No kernel modules**: rootless uses fuse-overlayfs + slirp4netns.

**Tier 2 — the rare genuine root need.**
Only when the kernel itself can't run an unprivileged container (old kernel:
no cgroup v2 / userns disabled) or the host has no container capability at all.
Then something privileged must happen once — update/configure the kernel or
install a system runtime — plus, on Windows, **enabling WSL2 is the equivalent
one-time admin step**. This is the *only* privileged tier, and it should be:
- **Scoped and explicit** — print exactly what will run, not a vague "enter your
  password."
- **Decoupled** — a standalone "prepare this machine" step an admin does **once**
  (see `prepare-host` below), after which the researcher installs at Tier 0/1
  with zero privilege.

**"Can't `modprobe`" now means *fall to rootless*, not fail (updated
2026-07-22).** This reverses the first draft. Because rootless sidesteps both
modules, a host where `br_netfilter` / `overlay` aren't loaded is **not**
blocked — it drops to rootless Docker (Tier 1). The thing we actually probe is
**cgroup v2 + unprivileged userns**; only their absence (a genuinely old
kernel) forces Tier 2. We never fail a host just because a module isn't loaded.

**`prepare-host` — thin, and shipped two ways.** The Tier-2 privileged step is a
single reviewable snippet IT approves once, exposed as **both** a readable shell
snippet (`curl … | bash -s -- prepare-host`, for a host with no CLI yet) **and**
a `tracebloc prepare-host` subcommand that runs the *same* audited snippet. IT
reviews one thing; researchers then self-serve at Tier 0.

**Detection — behavioral and side-effect-free (updated 2026-07-22).** One
test settles the tier:
- **`docker info` exit 0 is the Tier-0 check.** It proves binary + daemon +
  user-in-group all at once — no separate group/socket probing. Do **not** run
  `docker run hello-world` by default (it pulls an image); gate that behind an
  opt-in `--verify`.
- **If `docker info` fails**, probe **cgroup v2 + unprivileged userns**
  (`/sys/fs/cgroup/cgroup.controllers` present; `kernel.unprivileged_userns_clone`
  / `max_user_namespaces` > 0). Present → Tier 1 (set up rootless). Absent →
  Tier 2.
- **Privilege trio for honest messaging:** `id -u` (already root?),
  `command -v sudo` (sudo installed?), `sudo -n true` (sudo without a password?).
  This cleanly separates *already root* vs *sudo missing* vs *sudo needs a
  password* — and kills the current misleading "re-run with a user that has sudo
  access" abort (backlog A2).

If the only workable tier is 2 and there's no admin path, fail with an
**actionable** message — the exact `prepare-host` command to hand to IT.

**Audit report (2026-07-22: yes).** Before doing anything, the installer prints
a short, plain-language **host audit** so the user sees *why* a given tier was
chosen and what (if anything) an admin must do. Sketch:

Tier 0 — a container is already runnable, nothing to do:

```
Host check
  Container runtime   Docker 27.0 — usable (docker info OK)                  ✓
  Privilege           regular user (no root; sudo available)                 –
  → Install tier      Tier 0 (zero root). Proceeding with no privileged steps.
```

Tier 1 — no runtime yet, but the kernel supports unprivileged containers, so we
set up rootless Docker as the user — still no root:

```
Host check
  Container runtime   none found                                            –
  Kernel             cgroup v2 + unprivileged userns present                ✓
  Privilege           regular user (no root)                                –
  → Install tier      Tier 1. Setting up rootless Docker in your account
                      (no admin needed) — fuse-overlayfs, slirp4netns.
```

Tier 2 — the rare block: the kernel itself can't run unprivileged containers.
The report names the single blocker and the exact remedy:

```
Host check
  Container runtime   none found                                            –
  Kernel             unprivileged userns DISABLED (kernel too old/locked)   ✗
  → Blocked at Tier 2. Ask an admin to run once:
        curl -fsSL https://tracebloc.io/i.sh | bash -s -- prepare-host
    Then re-run this installer as yourself — it will proceed at Tier 0/1.
```

The same audit is what `tracebloc doctor` / `prepare-host` reuse — one probe,
one report format.

## The B2 connection — post-install PATH (why the issue exists)

Least-privilege means the CLI lands in `~/.local/bin` (no sudo to write
`/usr/local/bin`). A child-process installer **cannot** change the PATH of the
shell that launched it, so the binary isn't resolvable in the current shell —
"command not found" right after a successful install. That's the whole of B2:
it's a *consequence* of (correctly) avoiding sudo, not a separate bug.

Design it away, in this order:
1. **Prefer a writable directory already on `$PATH`.** If one exists (e.g. a
   `~/bin` or a Homebrew bin already set up), install there → usable in the same
   terminal, no PATH edit, no new shell.
2. **Otherwise `~/.local/bin` + activate in the current shell.** Print the exact
   one-liner to run *now* (`source ~/.zshrc`, or `export PATH="$HOME/.local/bin:$PATH"`)
   so the user stays in the same terminal — instead of "open a new terminal."
3. The final summary's CTA must reflect this (don't say "Run `tracebloc`" when it
   isn't yet on the current PATH).

So "run it in the same terminal" is achievable: either we land on-PATH (no
action) or we hand the user one paste. A brand-new machine where *nothing* we
control is yet on PATH is the only case that truly needs a re-source — and even
then it's one command, not a new terminal.

## Decisions (2026-07-22 — Lukas's first pass, then revised after @saadqbal review)

The first draft's five open questions are decided. Asad's review collapsed the
first two into one and flipped the kernel-module call — that revision is folded
in here and is now the RFC's position.

1. **Runtime → rootless Docker, primary (was: system Docker primary, rootless
   fallback).** Docker is the one supported runtime; we lead with **rootless
   Docker**. It keeps the k3d code path intact, is a security selling point, and
   removes the kernel modules from the privileged surface. Podman → best-effort
   only; k3s-rootless → parked future spike.
2. **Kernel modules → moot; "can't `modprobe`" falls to rootless, not fail (was:
   hard Tier-2).** Rootless uses fuse-overlayfs (`overlay`) + slirp4netns
   (`br_netfilter` unneeded). We probe **cgroup v2 + unprivileged userns**
   instead; only their absence (a genuinely old/locked kernel) forces Tier 2.
3. **`prepare-host` → build it thin, shipped two ways.** A single reviewable
   snippet IT approves once, exposed as **both** `curl … | bash -s -- prepare-host`
   (host with no CLI yet) **and** a `tracebloc prepare-host` subcommand running
   that same audited snippet — plus the shared host-audit report. Last in the
   rollout. *(This also settles my earlier "CLI vs installer sub-command" open
   item: both.)*
4. **Windows/WSL2 → WSL2 is Linux; enabling WSL2 is the Windows Tier-2 step.**
   Inside the distro the Linux tiers apply unchanged. **Prefer rootless Docker
   inside WSL over Docker Desktop** — Docker Desktop's commercial licensing is a
   real blocker for large hospital systems; use its WSL integration only if it's
   already present.
5. **Detection → yes; behavioral + side-effect-free.** `docker info` exit 0 is
   the single Tier-0 test; `hello-world` only behind `--verify`; the
   `id -u` / `command -v sudo` / `sudo -n true` trio for honest A2 messaging;
   cgroup v2 + userns probe to split Tier 1 from Tier 2. (See Proposal → Detection.)

**The one remaining question needing a hands-on spike** (Asad): validate
**rootless Docker as the k3d backend across our target hosts** — confirm cgroup
v2 + unprivileged userns coverage (Ubuntu 22.04+ / RHEL 9+ and the specific
hospital/HPC images we've seen), and settle the security posture we endorse
(fuse-overlayfs, slirp4netns, port <1024, storage-driver caveats). Everything
else is build work, not open design.

## Non-goals / risks

- Not proposing to *drop* the system-Docker path for users who already have it
  (Tier 0 uses it when the user is in the `docker` group) — just to stop
  *requiring* it and to lead with rootless.
- **Rootless is now the primary path, so its caveats are load-bearing, not
  footnotes** — cgroup v2, fuse-overlayfs vs native overlay (slower large-file
  I/O, which matters for dataset copies), slirp4netns networking, port <1024,
  storage-driver support. This is exactly what the spike must validate on our
  target hosts before we commit the rollout.
- Some managed hosts disable unprivileged userns entirely (hardened kernels,
  older RHEL). There rootless genuinely can't run — we detect it, route to Tier 2
  `prepare-host`, and fail honestly rather than pretend.

## Rollout

Incremental, no big-bang. Ordered by unlock-per-effort:

1. **Detection + host-audit report.** The side-effect-free probe (`docker info`;
   cgroup v2 + userns; the `id -u` / `sudo` / `sudo -n` trio) plus the short audit
   report that prints the chosen tier and any admin remedy. Foundation every later
   step reads from, and on its own it replaces the misleading "re-run with sudo
   access" abort with an honest, actionable message (closes A2's messaging half).
2. **Detect + reuse an existing usable Docker → Tier 0** (biggest unlock for the
   least effort; also fixes A2's "sudo not installed / already root" abort).
3. **A2 mechanics:** root-detection (`$SUDO` empty when root) + accurate
   "sudo missing vs no sudo access" messaging.
4. **B2:** prefer-on-PATH dir + same-shell activation.
5. **Rootless spike (the gating unknown).** Validate rootless Docker as the k3d
   backend across our target hosts — cgroup v2 + userns coverage, fuse-overlayfs
   dataset-copy performance, security posture. Because rootless is now the primary
   path, this gates the core build, so it moves *up* — not a tail-end follow-up.
6. **Tier 1 — set up rootless Docker as the user.** The core no-runtime path,
   built on the spike's findings.
7. **`prepare-host`** — the decoupled Tier-2 step (the rare old/locked-kernel
   case: enable userns / install a runtime), thin, shipped as snippet +
   `tracebloc prepare-host`. Reuses the audit report from step 1.
8. **Windows/WSL2:** verify the Linux probe path works unchanged under WSL2;
   prefer rootless Docker over Docker Desktop; document enabling WSL2 as the
   Windows one-time admin step.

Steps 1–4 are the near-term batch (they also close A2 + B2 from the backlog);
5 is the spike that unblocks the rest; 6–8 follow. The whole thing degrades
gracefully — a host that already has Docker never sees any of the tier machinery.
