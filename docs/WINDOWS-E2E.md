# Windows installer e2e — self-hosted runner setup

The nightly **Windows e2e** (`.github/workflows/windows-e2e.yaml`, issue #436 / RFC-CLIENT-0003 **D5**) runs the *real* `install-k8s.ps1` end-to-end on a self-hosted runner. GitHub's `windows-latest` runners can't nest virtualization, so the PowerShell installer otherwise has only mocked Pester coverage — regressions and never-ported behaviors stay green. This job closes that gap: bootstrap → verify Docker/WSL up → install tools → `New-K3dCluster` → credential-free stub discovery → teardown, uploading the install log on failure.

It is **schedule-only** (nightly + manual `workflow_dispatch`), not per-PR, and tears the k3d cluster down every run so the box stays reusable.

## One-time runner setup

1. **A nested-virt-capable Windows host** — bare metal, or a VM with nested virtualization enabled (e.g. Hyper-V "expose virtualization extensions", VMware "Virtualize Intel VT-x/EPT", or a cloud VM SKU that supports nested virt). GitHub-hosted `windows-latest` will **not** work.

2. **WSL2 + Docker Desktop (WSL2 backend), running.** The e2e *verifies* Docker is up; it deliberately does **not** reinstall Docker Desktop or toggle WSL features per run (a persistent runner must not reboot itself nightly). Set Docker Desktop to start on login so the runner always has it available.

3. **Register the runner with these labels** (Settings → Actions → Runners → New self-hosted runner, Windows):

   ```
   self-hosted, windows, nested-virt
   ```

   The workflow targets `runs-on: [self-hosted, windows, nested-virt]` — all three labels must be present.

4. **Runner account rights:** the runner service account must be able to install user-space tools (`kubectl` / `k3d` / `helm`) and create k3d clusters (Docker access). Running the runner as a user in the `docker-users` group with Docker Desktop available is sufficient.

## What "green" means

- **PASS:** the installer brought up a real k3d cluster and the credential-free stub is discovery-shaped (the `client`-labelled `*-jobs-manager` Deployment + the `ingestor` ServiceAccount exist).
- **RED (the point of the job):** a broken installer commit turns the run red, and the install log (`%USERPROFILE%\.tracebloc-e2e\install-*.log`, uploaded as the `windows-e2e-install-log` artifact) shows where it failed.

Credentials are **not** used — the run stops before `Invoke-ProvisionClient` (Steps 5–6 mint a real machine credential against the backend), exactly as the bash `e2e-journey.sh` stops before the CLI connects. No secrets are required.

## Scope note (WSL adapter, D2)

The job runs whichever Windows path is current — the PowerShell monolith today. If RFC-CLIENT-0003 **D2** later replaces it with a WSL adapter, point the driver (`scripts/tests/e2e-windows.ps1`) at the new entrypoint; the runner setup and workflow are unchanged.
