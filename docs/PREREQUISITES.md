# Prerequisites for the one-line installer

What a machine needs before `bash <(curl -fsSL https://tracebloc.io/i.sh)` (macOS, Linux) or `irm https://tracebloc.io/i.ps1 | iex` (Windows) sets up a secure environment on it. The installer checks each of these before it changes anything, and when one is not met it stops and names it.

This page is the one place these prerequisites are written down. The [README](../README.md) and [INSTALL.md](INSTALL.md) link here rather than repeat them, and the product docs at [docs.tracebloc.io](https://docs.tracebloc.io) carry a copy that is checked against this page. Every figure, path and host below is read back from the installer's own code by a test, so the page cannot quietly disagree with what the installer enforces.

macOS and Windows are covered by the [local deployment guide](https://docs.tracebloc.io/environment-setup/deploy-local) until their own runtime changes. At that point they move here too.

## Linux

<!-- prerequisites:linux:start -->
On a new Linux machine the installer sets up **native k3s**: Kubernetes runs on the machine itself as a system service, with no Docker and no k3d. A new machine is one outside WSL with no tracebloc install, no k3d, and no k3d cluster in Docker. Every other Linux machine keeps k3d, and so does WSL. When it keeps k3d, the installer says why in one line.

| | What the machine needs |
|---|---|
| Processor | 64-bit: `amd64` or `arm64` |
| Administrator rights | Once, as `sudo` or root, because k3s runs as root. Or an administrator prepares the machine for you once, and you install with no `sudo` (see below). |
| Memory | At least 5 GB: the installer stops below that. 11 GB fits the smallest training run as installed, and 16 GB is recommended. An 8 GB machine trains too, once `tracebloc resources set max` has sized training to what is free beside the platform (tracebloc CLI 0.10.93 or later). |
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
