# RFC 0001 — Least-privilege install

**Status:** Draft (for discussion)
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

**Tier 0 — zero root (target for shared/managed hosts).**
A usable container runtime already exists — Docker with the user in the
`docker` group, rootless Docker, or Podman — and the kernel modules are loaded
(common on well-run shared hosts). Then: download tools to `~/.local/bin`,
create the k3d/k3s cluster in the existing runtime, register, done. **No sudo at
any point.** Many hospital/HPC boxes already provide a container runtime; we
should detect and use it.

**Tier 1 — rootless runtime, no system Docker.**
No usable system Docker, but a rootless runtime can run as the user (rootless
Docker, Podman, or k3s rootless mode). Setup may need a **one-time, narrow**
privileged touch on some hosts (subuid/subgid ranges, a `sysctl`, or loading a
module) — nameable and grantable, not blanket admin. Investigate which of
rootless-Docker / Podman / k3s-rootless is the most portable target.

**Tier 2 — install a runtime (the only genuine root need).**
Nothing usable and rootless isn't viable → install Docker + load the kernel
modules. This is the **one** privileged step. It should be:
- **Scoped and explicit** — print exactly what will run (the Docker install +
  `modprobe br_netfilter overlay`), not a vague "enter your password."
- **Decoupled** — runnable as a standalone "prepare this machine" step an admin
  does **once** (`tracebloc prepare-host` / a documented snippet), after which
  the researcher installs with zero privilege (drops to Tier 0).

**Detection + honest failure.** The installer probes: is a runtime usable? are
the modules loaded? am I root? is sudo available? It selects the lowest workable
tier. If it can only reach Tier 2 and there's no admin path, it fails with an
**actionable** message — the exact commands to hand to IT — never the current
misleading "re-run with a user that has sudo access."

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

## Open questions (for discussion)

1. **Rootless target:** rootless Docker vs Podman vs k3s-rootless — which is the
   most portable, and what's the security posture we're comfortable with?
2. **Kernel modules on locked-down hosts:** if `br_netfilter`/`overlay` aren't
   loaded and we can't `modprobe`, is there a userspace fallback, or is that a
   hard Tier-2 admin requirement?
3. **The "prepare-host once" flow:** a `tracebloc prepare-host` command (or a
   documented admin snippet) that does the Tier-2 privileged bits, so the
   researcher install is then zero-privilege — worth building?
4. **Windows/WSL2:** same tiering? WSL2 + Docker Desktop has its own admin story.
5. **Detection cost/robustness:** probing "is Docker usable" reliably across
   distros without side effects.

## Non-goals / risks

- Not proposing to *drop* the convenient root path for users who have it — just
  to stop *requiring* it and to pick the least-privilege tier automatically.
- Rootless has real caveats (cgroup v2, overlayfs/fuse-overlayfs, port <1024,
  some storage drivers) — needs validation per target.
- Some managed hosts forbid user containers entirely; there we should fail
  honestly (it genuinely isn't installable there) rather than pretend.

## Rollout

Incremental, no big-bang:
1. **Detect + reuse an existing usable runtime → Tier 0** (biggest unlock for the
   least effort; also fixes A2's "sudo not installed / already root" abort).
2. **A2 mechanics:** root-detection (`$SUDO` empty when root) + accurate
   "sudo missing vs no sudo access" messaging.
3. **B2:** prefer-on-PATH dir + same-shell activation.
4. **Tier 1 (rootless)** as a follow-up spike.
5. **Tier 2 "prepare-host"** decoupled privileged step.
