# RFC 0001 — Least-privilege install

**Status:** Decisions recorded 2026-07-22 — pending @saadqbal sign-off
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

**The insight:** we don't need "admin." We need **a usable container runtime**
(plus, on Linux, two kernel modules). That is the *entire* privileged surface.
Everything else is user-space.

## Proposal — tiered, least-privilege install

Probe the machine and pick the **lowest tier that works**, instead of demanding
sudo up front:

> **Runtime decision (2026-07-22): Docker only.** We standardize on Docker as
> the single supported runtime for now — Docker with the user in the `docker`
> group at Tier 0, **rootless Docker** at Tier 1. We are *not* taking on Podman
> or k3s-rootless as parallel targets; one runtime keeps the detection matrix
> and the support surface small. (Revisit if a customer environment forces it.)

**Tier 0 — zero root (target for shared/managed hosts).**
A usable Docker already exists — the user is in the `docker` group (or rootless
Docker is already running) — and the kernel modules are loaded (common on
well-run shared hosts). Then: download tools to `~/.local/bin`, create the
k3d/k3s cluster in the existing runtime, register, done. **No sudo at any
point.** Many hospital/HPC boxes already provide Docker; we should detect and
use it.

**Tier 1 — rootless Docker, no system Docker.**
No usable system Docker, but **rootless Docker** can run as the user. Setup may
need a **one-time, narrow** privileged touch on some hosts (subuid/subgid
ranges, a `sysctl`) — nameable and grantable, not blanket admin. rootless Docker
is the chosen rootless target (not Podman / k3s-rootless).

**Tier 2 — install a runtime + load modules (the only genuine root need).**
Nothing usable and rootless isn't viable → install Docker + load the kernel
modules. This is the **one** privileged step. It should be:
- **Scoped and explicit** — print exactly what will run (the Docker install +
  `modprobe br_netfilter overlay`), not a vague "enter your password."
- **Decoupled** — runnable as a standalone "prepare this machine" step an admin
  does **once** (`tracebloc prepare-host`), after which the researcher installs
  with zero privilege (drops to Tier 0).

**Kernel modules are a hard Tier-2 requirement (2026-07-22).** If
`br_netfilter` / `overlay` aren't loaded and we can't `modprobe` them, there is
**no userspace fallback** — loading a kernel module is inherently privileged.
That host needs the Tier-2 `prepare-host` step run by an admin once. We do not
attempt to fake or work around it; we detect it and route to `prepare-host`.

**Detection + honest failure (2026-07-22: yes, build it).** The installer probes
— is Docker usable? are the modules loaded? am I root? is sudo available? — and
selects the lowest workable tier. Probes must be **side-effect-free** (e.g.
`docker info` / a throwaway `hello-world`, `lsmod`, `id -u`, `command -v sudo`).
If it can only reach Tier 2 and there's no admin path, it fails with an
**actionable** message — the exact `prepare-host` command to hand to IT — never
the current misleading "re-run with a user that has sudo access."

**Audit report (2026-07-22: yes).** Before doing anything, the installer prints
a short, plain-language **host audit** so the user sees *why* a given tier was
chosen and what (if anything) an admin must do. Sketch:

```
Host check
  Container runtime   Docker 27.0 — usable (you're in the 'docker' group)   ✓
  Kernel modules      br_netfilter loaded, overlay loaded                    ✓
  Privilege           regular user (no root, sudo available)                 –
  → Install tier      Tier 0 (zero root). Proceeding with no privileged steps.
```

…and when it can't proceed unprivileged, the report names the single blocker
and the exact remedy:

```
  Kernel modules      br_netfilter NOT loaded, cannot modprobe (no root)     ✗
  → Blocked at Tier 2. Ask an admin to run once:
        curl -fsSL https://tracebloc.io/i.sh | bash -s -- prepare-host
    Then re-run this installer as yourself — it will proceed at Tier 0.
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

## Decisions (resolved 2026-07-22, Lukas — pending @saadqbal confirmation)

The open questions from the first draft, now decided:

1. **Rootless target → Docker.** We use **Docker** for now: `docker`-group at
   Tier 0, **rootless Docker** at Tier 1. Podman and k3s-rootless are explicitly
   out of scope until an environment forces the question. Rationale: one runtime,
   one detection matrix, one support surface.
2. **Kernel modules on locked-down hosts → hard Tier-2.** No userspace fallback.
   If the modules aren't loaded and we can't `modprobe`, the host requires the
   admin-run `prepare-host` step; we detect and route, never work around.
3. **`prepare-host` → build it, with an audit report.** Ship `tracebloc
   prepare-host` (the standalone Tier-2 privileged step an admin runs once) **and**
   surface a short host-audit report (see the Proposal) so the user always sees
   which tier was picked and what an admin must do. The audit is shared with
   `doctor` and the main install path.
4. **Windows/WSL2 → WSL2 is Linux; native Windows prefers rootless Docker.**
   Under WSL2 the environment *is* Linux, so the Linux tiers apply unchanged
   (probe the WSL2 distro exactly as a native Linux host). For **native Windows**
   we prefer **rootless Docker** (Docker Desktop's non-admin path) rather than a
   separate privileged Windows story. WSL2 is the recommended and primary Windows
   route; native Windows is best-effort on rootless Docker.
5. **Detection → yes, build robust side-effect-free probing.** As described under
   Proposal → *Detection + honest failure*.

**Still open for @saadqbal:** the rootless-Docker security posture we're
comfortable endorsing (Tier 1 caveats below), and whether `prepare-host` lives in
the CLI (`tracebloc prepare-host`) or stays a documented installer sub-command
(`i.sh -s -- prepare-host`) — the RFC currently assumes the latter for the audit
snippet, since a non-admin may not have the CLI yet.

## Non-goals / risks

- Not proposing to *drop* the convenient root path for users who have it — just
  to stop *requiring* it and to pick the least-privilege tier automatically.
- Rootless has real caveats (cgroup v2, overlayfs/fuse-overlayfs, port <1024,
  some storage drivers) — needs validation per target.
- Some managed hosts forbid user containers entirely; there we should fail
  honestly (it genuinely isn't installable there) rather than pretend.

## Rollout

Incremental, no big-bang. Ordered by unlock-per-effort:

1. **Detection + host-audit report.** The side-effect-free probe (runtime usable?
   modules loaded? root? sudo?) plus the short audit report that prints the chosen
   tier and any admin remedy. This is the foundation every later step reads from,
   and on its own it replaces the misleading "re-run with sudo access" abort with
   an honest, actionable message.
2. **Detect + reuse an existing usable Docker → Tier 0** (biggest unlock for the
   least effort; also fixes A2's "sudo not installed / already root" abort).
3. **A2 mechanics:** root-detection (`$SUDO` empty when root) + accurate
   "sudo missing vs no sudo access" messaging.
4. **B2:** prefer-on-PATH dir + same-shell activation.
5. **`prepare-host`** — the decoupled Tier-2 privileged step (Docker install +
   `modprobe br_netfilter overlay`), runnable once by an admin so the researcher
   then installs at Tier 0. Reuses the audit report from step 1.
6. **Tier 1 (rootless Docker)** as a follow-up spike, once the posture in
   "still open for @saadqbal" is settled.
7. **Windows/WSL2:** verify the Linux probe path works unchanged under WSL2;
   document native-Windows rootless Docker as best-effort.

Steps 1–4 are the near-term batch (they also close A2 + B2 from the backlog);
5–7 follow once Asad signs off on the posture questions.
