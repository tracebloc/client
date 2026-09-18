# Windows installer e2e — self-hosted runner setup

> **⚠️ DORMANT since 2026-08-27 (backend#2627).** This workflow has **never once succeeded**: it ran nightly for 22 days and every run was recorded `cancelled` — GitHub's 24h queue-timeout, because **no `self-hosted, windows, nested-virt` runner is registered**. A `cancelled` conclusion is not a red check and raises no alert, so a job with zero successful runs read for weeks as "the Windows path is covered nightly" when it never was. The nightly `schedule:` trigger has been **removed**; the workflow is now **manual-dispatch only** so it stops emitting a phantom daily cancel.
>
> **Windows install coverage today** is the credentialed EC2 journey (**backend#2619**): the e2e-agent boots an `m7i.xlarge` with `--cpu-options NestedVirtualization=enabled` — ordinary EC2, no metal, no surcharge — which *can* run WSL2, so `install-client-windows` exercises the real installer end-to-end there. Once that journey is reliably green this file can be deleted; it is kept so the self-hosted job can be revived the moment a runner exists.
>
> **To revive:** complete the runner setup below, then restore the `schedule:` trigger in `windows-e2e.yaml`. A manual dispatch will queue-timeout until such a runner is online — expected while dormant, but (unlike the old cron) an explicit, visible action rather than a silent phantom.

The **Windows e2e** (`.github/workflows/windows-e2e.yaml`, issue #436 / RFC-CLIENT-0003 **D5**) runs the *real* `install-k8s.ps1` end-to-end on a self-hosted runner. GitHub's `windows-latest` runners can't nest virtualization, so the PowerShell installer otherwise has only mocked Pester coverage — regressions and never-ported behaviors stay green. This job closes that gap: bootstrap → verify Docker/WSL up → install tools → `New-K3dCluster` → credential-free stub discovery → teardown, uploading the install log on failure.

When revived it is **schedule-only** (nightly + manual `workflow_dispatch`), not per-PR, and tears the k3d cluster down every run so the box stays reusable.

## One-time runner setup

1. **A nested-virt-capable Windows host** — bare metal, or a VM with nested virtualization enabled (e.g. Hyper-V "expose virtualization extensions", VMware "Virtualize Intel VT-x/EPT", or a cloud VM SKU that supports nested virt). GitHub-hosted `windows-latest` will **not** work.

2. **WSL2 + Docker Desktop (WSL2 backend), running.** The e2e *verifies* Docker is up; it deliberately does **not** reinstall Docker Desktop or toggle WSL features per run (a persistent runner must not reboot itself nightly). Set Docker Desktop to start on login so the runner always has it available.

3. **Register the runner with these labels** (Settings → Actions → Runners → New self-hosted runner, Windows):

   ```
   self-hosted, windows, nested-virt
   ```

   The workflow targets `runs-on: [self-hosted, windows, nested-virt]` — all three labels must be present.

4. **The runner must run as Administrator.** The Windows installer is inherently elevated — it creates `%ProgramFiles%\tracebloc\bin`, writes the **Machine** `PATH`, and (in a full install) installs Docker Desktop. Register/run the self-hosted runner service under an account with Administrator rights (or configure the runner service to run elevated). The e2e asserts elevation up front and fails fast with a pointer if it isn't. The account also needs Docker access (member of `docker-users`, Docker Desktop running).

## What "green" means

- **PASS:** the installer brought up a real k3d cluster and the credential-free stub is discovery-shaped (the `client`-labelled `*-jobs-manager` Deployment + the `ingestor` ServiceAccount exist).
- **RED (the point of the job):** a broken installer commit turns the run red, and the install log (`%USERPROFILE%\.tracebloc-e2e\install-*.log`, uploaded as the `windows-e2e-install-log` artifact) shows where it failed.

Credentials are **not** used — the run stops before `Invoke-ProvisionClient` (Steps 5–6 mint a real machine credential against the backend), exactly as the bash `e2e-journey.sh` stops before the CLI connects. No secrets are required.

## Scope note (WSL adapter, D2)

The job runs whichever Windows path is current — the PowerShell monolith today. If RFC-CLIENT-0003 **D2** later replaces it with a WSL adapter, point the driver (`scripts/tests/e2e-windows.ps1`) at the new entrypoint; the runner setup and workflow are unchanged.
