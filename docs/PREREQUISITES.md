# Prerequisites for the one-line installer

What a machine needs before `bash <(curl -fsSL https://tracebloc.io/i.sh)` (macOS, Linux) or `irm https://tracebloc.io/i.ps1 | iex` (Windows) sets up a secure environment on it. The installer checks each of these before it changes anything, and when one is not met it stops and names it.

This page is the one place these prerequisites are written down. The [README](../README.md) and [INSTALL.md](INSTALL.md) link here rather than repeat them, and the product docs at [docs.tracebloc.io](https://docs.tracebloc.io) carry a copy that is checked against this page. Every figure, path and host in the Linux, macOS and Windows blocks below is read back from the installer's own code by a test, so those blocks cannot quietly disagree with what the installer enforces. [The Mac's GPU](#the-macs-gpu) states the rules of the tracebloc runner, which the tracebloc CLI enforces.

A Mac has its own section, [macOS](#macos), and Windows has its own, [Windows](#windows).

## Linux

<!-- prerequisites:linux:start -->
On Linux the installer sets up **native k3s**: Kubernetes runs on the machine itself as a system service, with no Docker and no k3d. Inside WSL the installer runs only in tracebloc's own distro, which the Windows installer sets up: in any other distro it stops and says so.

| | What the machine needs |
|---|---|
| Processor | 64-bit: `amd64` or `arm64` |
| Administrator rights | Once, as `sudo` or root, because k3s runs as root. Or an administrator prepares the machine for you once, and you install with no `sudo` (see below). |
| Memory | At least 7.0 GB: the installer stops below that, because a smaller machine cannot fit one training run beside the platform. 10 GB fits the smallest training run as installed, and 16 GB is recommended. An 8 GB machine trains too, once `tracebloc resources set max` has sized training to what is free beside the platform (tracebloc CLI 0.10.93 or later). |
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

**An NVIDIA GPU.** GPU training needs NVIDIA driver R580 or newer (CUDA 13). With an older driver the installer sets the machine up in CPU mode. To use the GPU, update the driver, reboot, and run the installer again. On Ubuntu, this command updates it:

```bash
sudo ubuntu-drivers install --gpgpu nvidia:580-server
```

**Without administrator rights.** An administrator runs this once, with your user name in place of `<user>`:

```bash
export TRACEBLOC_SUBSTRATE=k3s TB_PREPARE_USER=<user> && curl -fsSL https://tracebloc.io/i.sh | bash -s -- prepare-host
```

This sets up k3s and adds you to the `tracebloc` group. Log out and back in, then run the installer with no `sudo`. To list the commands it would run as root, without running any, add `--print` after `prepare-host`.

**A machine that runs tracebloc on k3d.** The installer no longer sets up k3d on Linux outside WSL, and it refuses `TRACEBLOC_SUBSTRATE=k3d` there. k3d is no longer supported: a machine already on k3d keeps running as it is until you move it.

**Moving a k3d machine to native k3s.** The installer does not move it. Run on a machine that runs tracebloc on k3d, it stops before it changes anything, and it asks nothing. It names what says the machine is on k3d (the install record or its root copy, or, for an install older than the record, the kubeconfig context k3d writes; with none of them, the containers Docker still has for k3d's cluster), then prints the way out: delete that secure environment with `tracebloc delete`, then the file that said so and the context's entries if they are still there. Over the install record:

```text
This installer no longer sets up k3d, and it never sets up native k3s beside it.
Moving this machine to native k3s is a reinstall: its secure environment and its data are deleted, its datasets must be ingested again, and it comes back as a new secure environment. Your use cases and models stay on tracebloc.
To move it, delete that secure environment with 'tracebloc delete'. Then delete ~/.tracebloc/install-record.json and the k3d-tracebloc entries from your kubeconfig if they are still there, and run this installer again.
✖ Nothing was changed.
```

Over the record's root copy alone, with no install record in your home folder, the path names your user, here `alice`:

```text
This installer no longer sets up k3d, and it never sets up native k3s beside it.
Moving this machine to native k3s is a reinstall: its secure environment and its data are deleted, its datasets must be ingested again, and it comes back as a new secure environment. Your use cases and models stay on tracebloc.
To move it, delete that secure environment with 'tracebloc delete'. Then delete /var/lib/tracebloc/alice/install-record.json and the k3d-tracebloc entries from your kubeconfig if they are still there, and run this installer again.
✖ Nothing was changed.
```

In `prepare-host`, it names the install record of the user it sets the machine up for, here `alice`:

```text
This installer no longer sets up k3d, and it never sets up native k3s beside it.
Moving this machine to native k3s is a reinstall: its secure environment and its data are deleted, its datasets must be ingested again, and it comes back as a new secure environment. Your use cases and models stay on tracebloc.
To move it, delete that secure environment with 'tracebloc delete'. Then delete /home/alice/.tracebloc/install-record.json and the k3d-tracebloc entries from your kubeconfig if they are still there, and run this installer again.
✖ Nothing was changed.
```

Over the kubeconfig context alone, or the containers Docker has for k3d's cluster, the way out names no file:

```text
This installer no longer sets up k3d, and it never sets up native k3s beside it.
Moving this machine to native k3s is a reinstall: its secure environment and its data are deleted, its datasets must be ingested again, and it comes back as a new secure environment. Your use cases and models stay on tracebloc.
To move it, delete that secure environment with 'tracebloc delete'. Then delete the k3d-tracebloc entries from your kubeconfig if they are still there, and run this installer again.
✖ Nothing was changed.
```

Deleting the file and the context's entries by hand does not get the installer past a k3d cluster that is still there: while Docker lists that cluster's containers, stopped ones too, it stops the same way. With k3d installed and Docker not answering, it cannot tell, and stops: start Docker and check that `docker ps` works for you, then run it again.

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
On a Mac with Apple silicon and macOS 26 or later, the installer sets up **k3s in Apple's `container` runtime**. Kubernetes runs in a small Linux VM that Apple's runtime starts from your own user folder, with no Docker, no k3d and no administrator rights. It is the one runtime the installer sets up on a Mac: any other `TRACEBLOC_SUBSTRATE` stops it before it changes anything.

| | What the Mac needs |
|---|---|
| Processor | Apple silicon (M1 or later). The installer stops on an Intel Mac. |
| macOS | 26 or later. The installer stops on an older version. |
| Administrator rights | None. |
| Memory | 16 GB recommended. The node is a VM that holds part of the Mac's memory while it runs: 6 GB of an 8 GB Mac, 10 GB of a 16 GB Mac, 12 GB of a 24 GB Mac, and 16 GB of a Mac with 32 GB or more. 10 GB fits the smallest training run. On a smaller Mac, the installer stops before it creates the node if a training run would not fit beside the platform. |
| Disk | At least 10 GB free, and 20 GB recommended, on the disk that holds `~/Library/Application Support/tracebloc/container`, where the node's images and its volume are kept. The installer stops below 10 GB. The volume grows as data is written, up to 64 GB. The installer checks the disk that holds your job data too. |
| CPU | 2 cores, 4 recommended. The node gets all but one of them. |
| Network | Outbound HTTPS (port 443) to the hosts below |

**What the installer puts on the Mac:**

- Apple's `container` runtime, from its signed package, in `~/Library/Application Support/tracebloc/container`;
- the Linux kernel the node boots (`ghcr.io/tracebloc/apple-container-kernel`) and the k3s node image (`rancher/k3s`, by digest);
- a login item, `io.tracebloc.node`, that keeps the node running and brings it back when you log in again;
- a folder for your job data, `~/.tracebloc/job-data`: the datasets, logs and resume points training uses. Only you can open it.
- kubectl and Helm in `~/.local/bin`;
- the tracebloc CLI.

The installer installs no Docker, no colima, no Homebrew and no k3d. `tracebloc delete` removes the node, its login item, the runtime and your job data.

**The one prompt.** When the node first starts, macOS asks whether `container-runtime-linux` may find devices on your local network. It is part of Apple's runtime, and it makes the cluster's API reachable from this Mac only. Click Allow. The installer waits up to 2 minutes for your answer. Without it, the installer stops and says where to allow it: System Settings › Privacy & Security › Local Network.

**A Mac that runs tracebloc on k3d.** k3d is no longer supported. The installer does not move such a Mac, and never sets up the node beside it. Run on such a Mac, it stops before it changes anything, and it asks nothing. It names what says the Mac is on k3d (the install record, or, for an install older than the record, the kubeconfig context k3d writes; with neither, the containers Docker still has for k3d's cluster), then prints the way out. Over the install record:

```text
This installer no longer sets up k3d, and it never sets up k3s in Apple's container runtime beside it.
Moving this machine to k3s in Apple's container runtime is a reinstall: its secure environment and its data are deleted, its datasets must be ingested again, and it comes back as a new secure environment. Your use cases and models stay on tracebloc.
To move it, delete that secure environment with 'tracebloc delete'. Then delete ~/.tracebloc/install-record.json and the k3d-tracebloc entries from your kubeconfig if they are still there, and run this installer again.
✖ Nothing was changed.
```

A Mac the table above rules out (an Intel Mac, or an older macOS) is stopped by that first. Until the Mac moves, neither the installer nor `tracebloc upgrade` updates its secure environment.

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

### The Mac's GPU

<!-- Maintainers: these figures are the tracebloc runner's, in the CLI's code, and no test reads them back here. The 8 GB kept for macOS, the 8 GB side-by-side line and the half-the-memory cap are in internal/runner/admission; the 7 days, the feed and the 7-day hold are in internal/runner/macos; the GPU test is internal/runner/gputest; the reason codes are internal/runner/node.go; the flags are internal/cli/resources_applegpu.go. The engine's sizes are the published bundle's (ghcr.io/tracebloc/engine-macos-arm64: its layer, and its disk-bytes annotation), measured 2026-10-20. The login item's label is TB_MAC_CT_RUNNER_LABEL in scripts/lib/mac-container.sh. Re-read them when any of those change. -->

A Mac that meets what this section asks for also trains on its GPU. The tracebloc runner, part of the tracebloc CLI, runs each GPU training as a process on the Mac rather than in tracebloc's VM, inside a sandbox of its own ([SECURITY.md § The runner](SECURITY.md#the-runner-gpu-training-on-the-mac)). A second login item, `io.tracebloc.runner`, keeps the runner going beside `io.tracebloc.node`. A training the GPU cannot take trains on the CPU instead, so a Mac without its GPU still takes every training.

| | What the GPU needs |
|---|---|
| macOS | The current update of the Mac's macOS version. Once Apple has posted a newer update of the same version for 7 days, the Mac trains on the CPU until the update is installed. A newer major version never counts against it, and a beta of the next major version gets no GPU. |
| Memory | 16 GB or more. A GPU training may use at most half the Mac's memory, GPU memory included, and always leaves tracebloc's VM and 8 GB for macOS and you: 12 GB on a 36 GB Mac. Where a GPU training beside a CPU training would get less than 8 GB, as on a 16 or 24 GB Mac, the Mac trains one training at a time, CPU or GPU. On an 8 GB Mac no GPU training fits, and the GPU stays off. |
| The GPU test | When the runner starts, and each time the GPU is turned on, it compiles and runs a small Metal program on the GPU, and takes GPU trainings only when the program gives the right answer. It refuses a virtual GPU, so a macOS that runs in a virtual machine trains on the CPU. |
| Network | `gdmf.apple.com`, Apple's public list of macOS releases, and `ghcr.io`, for the GPU engine: about 460 MB to download and about 1.7 GB on disk. When the list cannot be read, the last answer holds for 7 days; after that the GPU stays off until the list can be read again. |

`tracebloc resources set --gpus 0` turns the GPU off. `--gpu-jobs` sets how many GPU trainings may share it at once (one by default), and they split the memory a GPU training may use. `--gpu-memory` lowers what each GPU training may use; it never raises it.

**Why a Mac trains on its CPU.** When the GPU takes no trainings, the runner names one reason. `tracebloc resources` shows it, and the dashboard says it in words.

| Reason | What it means | What to do |
|---|---|---|
| `gpu-off` | The GPU is turned off. | `tracebloc resources set --gpus 1` |
| `gpu-test-failed` | The GPU test failed, or macOS runs in a virtual machine. | Turn the GPU off and on again to repeat the test. |
| `macos-update-pending` | A newer update of this macOS has been out for 7 days. | Install it: System Settings › General › Software Update. |
| `macos-currency-unknown` | The runner has not been able to read Apple's list of releases for 7 days, or the list has no release of this macOS for this Mac, as with a beta. | Let the Mac reach `gdmf.apple.com`, or run a released macOS. |
| `memory` | No GPU training fits beside tracebloc's VM and the 8 GB macOS keeps. A 16 or 24 GB Mac also says this until the runner has measured the VM. | None on a Mac this size. |
| `no-bundle` | The GPU engine for this release has not been downloaded and verified yet. | Keep the Mac online. |
| `gpu-unhealthy` | A GPU training did not stop when it was ended. | Restart the Mac. |
| `storage` | This install keeps training data where the GPU cannot reach it. | Reinstall tracebloc. |

## Windows

<!-- prerequisites:windows:start -->
On Windows, the installer sets up **k3s in tracebloc's own WSL distro**. This is native k3s, as on Linux, inside a WSL 2 distro named `tracebloc` that belongs to the signed-in user, with no Docker Desktop and no k3d. It is the one runtime the installer sets up on Windows: any other `TRACEBLOC_SUBSTRATE` stops it before it changes anything.

| | What the machine needs |
|---|---|
| Windows | Windows 11 (build 22000 or later). The installer stops on an older Windows. |
| Processor | 64-bit `amd64` (x64): tracebloc's distro image is built for it |
| WSL | 2.5 or later. If it is missing or older, an administrator turns it on once (see below). |
| Administrator rights | Once, for that step. Everything after it runs as the signed-in user, and the installer refuses to run as the SYSTEM account. |
| Memory | At least 8 GB in WSL's VM: the installer warns below that, because a smaller VM cannot fit one training run beside the tracebloc platform. 10 GB in the VM fits the smallest training run, and 16 GB is recommended. WSL gives its VM half of the machine's memory by default; `memory=` under `[wsl2]` in `%UserProfile%\.wslconfig`, WSL's own setting, changes that. |
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

**A machine that runs tracebloc on k3d.** This installer no longer sets up tracebloc on Docker Desktop with k3d, nor moves a machine off it. On such a machine it stops before WSL is touched, names the secure environment it found, and changes nothing on this machine. It finds one from the files that install left, or, with none of them, from the containers Docker still has for its cluster; with k3d installed and Docker not answering, it cannot tell, and stops. To move the machine, delete that secure environment with `tracebloc delete`. Then delete `%USERPROFILE%\.tracebloc\install-state.json` and the `k3d-tracebloc` entries from your kubeconfig if they are still there, and run this installer again. Moving is a reinstall: its secure environment and that environment's data are deleted, its datasets are ingested again, and it comes back as a new secure environment. Your use cases and models stay on tracebloc.

**A proxy.** Set `HTTPS_PROXY`, and `HTTP_PROXY` and `NO_PROXY` if your network needs them, in Windows' environment before the install. The installer stops before it sets up the distro if a proxy variable holds a value the cluster could not use. Windows' own downloads use `HTTPS_PROXY`. The installer hands these variables into the distro, and k3s gets them there.

**A proxy that inspects TLS.** Its root certificate needs no extra step. The installer copies this computer's trusted root certificates, the machine's and the signed-in user's, into the distro before its first download there. It stops if the distro's trust bundle does not hold every one, and restarts k3s if it already runs, so k3s reads them too.

**An NVIDIA GPU.** GPU training needs NVIDIA driver R580 or newer (CUDA 13), from NVIDIA's download page, https://www.nvidia.com/Download/index.aspx. With an older driver the installer sets the machine up in CPU mode. To use the GPU, update the driver, reboot, and run the installer again.

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
