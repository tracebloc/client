# Prerequisites for the one-line installer

What a machine needs before `bash <(curl -fsSL https://tracebloc.io/i.sh)` (macOS, Linux) or `irm https://tracebloc.io/i.ps1 | iex` (Windows) sets up a secure environment on it. The installer checks each of these before it changes anything, and when one is not met it stops and names it.

This page is the one place these prerequisites are written down. The [README](../README.md) and [INSTALL.md](INSTALL.md) link here rather than repeat them, and the product docs at [docs.tracebloc.io](https://docs.tracebloc.io) carry a copy that is checked against this page. Every figure, path and host below is read back from the installer's own code by a test, so the page cannot quietly disagree with what the installer enforces.

A Mac with Apple's container runtime has its own section, [macOS](#macos), and Windows has its own, [Windows](#windows). A Mac on k3d is covered by the [local deployment guide](https://docs.tracebloc.io/environment-setup/deploy-local) until its own runtime changes. At that point it moves here too.

## Linux

<!-- prerequisites:linux:start -->
On a new Linux machine the installer sets up **native k3s**: Kubernetes runs on the machine itself as a system service, with no Docker and no k3d. A new machine is one outside WSL with no tracebloc install, no k3d, and no k3d cluster in Docker. Every other Linux machine keeps k3d, and so does WSL. When it keeps k3d, the installer says why in one line.

| | What the machine needs |
|---|---|
| Processor | 64-bit: `amd64` or `arm64` |
| Administrator rights | Once, as `sudo` or root, because k3s runs as root. Or an administrator prepares the machine for you once, and you install with no `sudo` (see below). |
| Memory | At least 7.0 GB: the installer stops below that, because a smaller machine cannot fit one training run beside the platform. 11 GB fits the smallest training run as installed, and 16 GB is recommended. An 8 GB machine trains too, once `tracebloc resources set max` has sized training to what is free beside the platform (tracebloc CLI 0.10.93 or later). |
| Disk | At least 10 GB free, and 20 GB recommended. This applies both where k3s keeps its data (`/var/lib/rancher/k3s`) and where your data is kept (`/var/lib/rancher/k3s/storage`, or the directory you set with `TRACEBLOC_HOST_DATA_DIR`). The installer stops below 10 GB. |
| CPU | 2 cores, 4 recommended |
| Network | Outbound HTTPS (port 443) to the hosts below |

**What the installer puts on the machine:**

- k3s, a pinned release downloaded from GitHub, whose digest the installer checks;
- Helm;
- the firewall tool k3s needs (nftables);
- the tracebloc CLI;
- on an NVIDIA machine, the driver and the NVIDIA container toolkit.

kubectl comes with k3s. The installer installs no Docker and no k3d. k3s lives in `/usr/local/bin/k3s`, `/etc/rancher/k3s` and `/var/lib/rancher/k3s`, and runs as the `k3s` service. `tracebloc delete` removes them.

**Without administrator rights.** An administrator runs this once, with your user name in place of `<user>`:

```bash
export TRACEBLOC_SUBSTRATE=k3s TB_PREPARE_USER=<user> && curl -fsSL https://tracebloc.io/i.sh | bash -s -- prepare-host
```

This sets up k3s and adds you to the `tracebloc` group. Log out and back in, then run the installer with no `sudo`. To list the commands it would run as root, without running any, add `--print` after `prepare-host`.

**Keeping k3d.** To install on k3d instead, set `TRACEBLOC_SUBSTRATE=k3d`; the installer then sets up Docker as well. A machine that already runs tracebloc on k3d stays on k3d through every upgrade.

**Moving a k3d machine to native k3s.** Re-run the installer with `TRACEBLOC_SUBSTRATE=k3s`. This is a reinstall:

- the machine's secure environment and its data are deleted;
- its datasets must be ingested again;
- it comes back as a new secure environment.

Your use cases and models stay on tracebloc. To confirm, the installer asks you to type the secure environment's name, or reads it from `TRACEBLOC_REINSTALL_CONSENT=<name>`.

**Hosts.** Before a run changes anything, the installer checks each host that run needs. The last column says which runs need it.

| Host | Why | Needed |
|---|---|---|
| `registry-1.docker.io`, `auth.docker.io` | Docker Hub | every run |
| `ghcr.io` | the tracebloc images | every run |
| `api.tracebloc.io` | the tracebloc API | every run |
| `tracebloc.github.io` | the tracebloc Helm charts | every run |
| `rpm.rancher.io` | k3s's SELinux policy, on an SELinux-enforcing RHEL, Fedora or SUSE machine | every run |
| `github.com`, `release-assets.githubusercontent.com` | the k3s release | until k3s is installed, and on a run that upgrades it |
| `get.helm.sh` | Helm | until Helm is installed |
<!-- prerequisites:linux:end -->

Once it is installed, the secure environment also reaches the hosts in [INSTALL.md § Network requirements](INSTALL.md#network-requirements-egress-allowlist).

## macOS

<!-- prerequisites:macos:start -->
On a new Mac with Apple silicon and macOS 26 or later, the installer sets up **k3s in Apple's `container` runtime**. Kubernetes runs in a small Linux VM that Apple's runtime starts from your own user folder, with no Docker, no k3d and no administrator rights. A new Mac is one with no tracebloc install, no k3d, and no k3d cluster in Docker; a Docker that is installed but not running counts as none, since every k3d install leaves k3d itself behind. Every other Mac keeps k3d, which the [local deployment guide](https://docs.tracebloc.io/environment-setup/deploy-local) covers, and the installer says why in one line. To keep k3d on a new Mac, set `TRACEBLOC_SUBSTRATE=k3d`.

| | What the Mac needs |
|---|---|
| Processor | Apple silicon (M1 or later). The installer stops on an Intel Mac. |
| macOS | 26 or later. The installer stops on an older version. |
| Administrator rights | None. |
| Memory | 16 GB recommended. The node is a VM that holds part of the Mac's memory while it runs: 6 GB of an 8 GB Mac, 11 GB of a 16 GB Mac, 12 GB of a 24 GB Mac, and 16 GB of a Mac with 32 GB or more. 11 GB fits the smallest training run. On a smaller Mac, the installer stops before it creates the node if a training run would not fit beside the platform. |
| Disk | At least 10 GB free, and 20 GB recommended, on the disk that holds `~/Library/Application Support/tracebloc/container`, where the node's images and its volume are kept. The installer stops below 10 GB. The volume grows as data is written, up to 64 GB. |
| CPU | 2 cores, 4 recommended. The node gets all but one of them. |
| Network | Outbound HTTPS (port 443) to the hosts below |

**What the installer puts on the Mac:**

- Apple's `container` runtime, from its signed package, in `~/Library/Application Support/tracebloc/container`;
- the Linux kernel the node boots (`ghcr.io/tracebloc/apple-container-kernel`) and the k3s node image (`rancher/k3s`, by digest);
- a login item, `io.tracebloc.node`, that keeps the node running and brings it back when you log in again;
- kubectl and Helm in `~/.local/bin`;
- the tracebloc CLI.

The installer installs no Docker, no colima, no Homebrew and no k3d. `tracebloc delete` removes the node, its login item and the runtime.

**The one prompt.** When the node first starts, macOS asks whether `container-runtime-linux` may find devices on your local network. It is part of Apple's runtime, and it makes the cluster's API reachable from this Mac only. Click Allow. The installer waits up to 2 minutes for your answer. Without it, the installer stops and says where to allow it: System Settings › Privacy & Security › Local Network.

**Hosts.** The installer checks each of these before it starts. The first five rows are always needed. The rest are needed only until Apple's runtime or Helm is installed.

| Host | Why |
|---|---|
| `registry-1.docker.io`, `auth.docker.io` | Docker Hub: the k3s node image |
| `ghcr.io` | the tracebloc images and the node's kernel |
| `api.tracebloc.io` | the tracebloc API |
| `tracebloc.github.io` | the tracebloc Helm charts |
| `dl.k8s.io` | kubectl |
| `github.com`, `release-assets.githubusercontent.com` | Apple's `container` runtime, its signed package |
| `get.helm.sh` | Helm |
<!-- prerequisites:macos:end -->

Once it is installed, the secure environment also reaches the hosts in [INSTALL.md § Network requirements](INSTALL.md#network-requirements-egress-allowlist).

## Windows

<!-- prerequisites:windows:start -->
On Windows, the installer sets up **k3s in tracebloc's own WSL distro**. This is native k3s, as on Linux, inside a WSL 2 distro named `tracebloc` that belongs to the signed-in user, with no Docker Desktop and no k3d. It is the one runtime the installer sets up on Windows: any other `TRACEBLOC_SUBSTRATE` stops it before it changes anything.

| | What the machine needs |
|---|---|
| Windows | Windows 11 (build 22000 or later). The installer stops on an older Windows. |
| Processor | 64-bit `amd64` (x64): tracebloc's distro image is built for it |
| WSL | 2.5 or later. If it is missing or older, an administrator turns it on once (see below). |
| Administrator rights | Once, for that step. Everything after it runs as the signed-in user, and the installer refuses to run as the SYSTEM account. |
| Memory | At least 9 GB in WSL's VM: the installer warns below that, because a smaller VM cannot fit one training run beside the tracebloc platform. 11 GB in the VM fits the smallest training run, and 16 GB is recommended. WSL gives its VM half of the machine's memory by default; `memory=` under `[wsl2]` in `%UserProfile%\.wslconfig`, WSL's own setting, changes that. |
| Disk | At least 30 GB free on the drive that holds the distro. The distro's disk is capped at what is free there, less 20 GB that is left to Windows. The installer stops if that leaves less than 10 GB for the distro. |
| CPU | 2 cores, 4 recommended |
| Network | Outbound HTTPS (port 443) to the hosts below |

**The one administrator step.** When WSL 2.5 or later is missing, the installer stops and says: "Ask your IT team to run this once in an administrator PowerShell, then restart Windows if it asks:"

```powershell
wsl --install --no-distribution
```

If you are an administrator yourself, Windows asks you once to allow it, and that command is the only thing the installer runs elevated. Where `wsl --install` cannot run, for example from a deployment tool running as SYSTEM, IT can instead turn on the Windows features `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform`, install WSL's own package, and restart. If Windows asks for a restart, the installer says: "Restart Windows, then run the same install command again: it continues from here."

**What the installer puts on the machine:**

- the `tracebloc` WSL distro in `%LOCALAPPDATA%\tracebloc\wsl`, the signed-in user's own folder, imported from tracebloc's image on `ghcr.io`, a download of about 126 MB: Ubuntu 24.04.5 with `ca-certificates`, `curl`, `dbus`, `nftables`, `systemd` and `systemd-sysv`, and k3s;
- inside the distro, what native k3s puts on a Linux machine, as the Linux section above lists it;
- the `tracebloc` CLI, for the signed-in user only, in `%LOCALAPPDATA%\Programs\tracebloc` unless `TRACEBLOC_INSTALL_PREFIX` names another folder;
- the install record `%USERPROFILE%\.tracebloc\install-record.json`, where `tracebloc delete` finds what to remove;
- the logon task `tracebloc-keepalive`, the signed-in user's own, set up without administrator rights. At each sign-in it starts the distro, with no window, and keeps it running.

The installer installs no Docker Desktop, no winget packages and no k3d. `tracebloc delete` removes the logon task, then the distro, with everything inside it.

**After a restart.** The secure environment runs while you are signed in. After Windows restarts, it starts again when you sign in.

**A machine that runs tracebloc on k3d.** The installer never sets up the distro beside a live k3d cluster. Moving the machine is a reinstall: its secure environment and that environment's data are deleted, its datasets are ingested again, and it comes back as a new secure environment. Your use cases and models stay on tracebloc. The installer offboards the old environment only after you type its name when asked, or set `TRACEBLOC_REINSTALL_CONSENT` to it. A k3d cluster that is not tracebloc's stops the installer, which never removes it.

**A proxy.** Set `HTTPS_PROXY`, and `HTTP_PROXY` and `NO_PROXY` if your network needs them, in Windows' environment before the install. The installer stops before it sets up the distro if a proxy variable holds a value the cluster could not use. Windows' own downloads use `HTTPS_PROXY`. The installer hands these variables into the distro, and k3s gets them there.

**A proxy that inspects TLS.** Its root certificate needs no extra step. The installer copies this computer's trusted root certificates, the machine's and the signed-in user's, into the distro before its first download there. It stops if the distro's trust bundle does not hold every one, and restarts k3s if it already runs, so k3s reads them too.

**Hosts.** Windows downloads the installer and the tracebloc CLI from `github.com`, whose release files come from `release-assets.githubusercontent.com`, and the distro's image from `ghcr.io`. Inside the distro, the installer checks each of these before it starts. The first four rows are always needed. The distro's image carries k3s, so the k3s release is needed only on a run that upgrades it. Helm is needed until Helm is installed.

| Host | Why |
|---|---|
| `registry-1.docker.io`, `auth.docker.io` | Docker Hub |
| `ghcr.io` | the tracebloc images |
| `api.tracebloc.io` | the tracebloc API |
| `tracebloc.github.io` | the tracebloc Helm charts |
| `github.com`, `release-assets.githubusercontent.com` | the k3s release |
| `get.helm.sh` | Helm |
<!-- prerequisites:windows:end -->
