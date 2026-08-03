#Requires -Version 5.1
<#
  e2e-windows.ps1 — real Windows installer e2e (self-hosted runner; #436 / RFC-CLIENT-0003 D5)
  ---------------------------------------------------------------------------------------------
  GitHub's `windows-latest` runners cannot nest virtualization, so install-k8s.ps1 is covered
  only by mocked Pester — while the bash installer gets a 9-distro prereq matrix + real-k3d
  e2e on every push. This driver exercises the REAL Windows installer, credential-free, on a
  SELF-HOSTED runner that DOES support nested virtualization (Docker Desktop + WSL2 are runner
  prerequisites — see docs/WINDOWS-E2E.md). It mirrors the credential-free shape of
  scripts/tests/e2e-journey.sh:

      Docker/WSL up  ->  install tools  ->  New-K3dCluster  ->  credential-free stub
      discovery  ->  assert the installer's copy on the way  ->  teardown

  It dot-sources install-k8s.ps1 with $env:TB_PESTER=1 so the installer's main() does NOT run,
  then calls the same functions the installer's Steps 2-3 use. Steps 5-6 (Invoke-ProvisionClient
  / Install-ClientHelm) mint a real machine credential against the backend and are out of scope
  here — exactly as e2e-journey stops before the CLI connects.

  It does NOT reinstall Docker Desktop / enable WSL features per run: those are one-time runner
  setup (a persistent runner must not reboot itself nightly). We verify Docker is up and fail
  loudly with a pointer if it isn't.

  Usage:  pwsh -NoProfile -File scripts/tests/e2e-windows.ps1   (run by .github/workflows/windows-e2e.yaml)
#>

$ErrorActionPreference = 'Stop'

function Write-E2e([string]$Message) { Write-Host "[e2e-windows] $Message" }
function Stop-E2e([string]$Message)  { Write-Host "[e2e-windows] FAIL: $Message" -ForegroundColor Red; exit 1 }
function Confirm-NativeOk([string]$What) { if ($LASTEXITCODE -ne 0) { Stop-E2e "$What (exit $LASTEXITCODE)" } }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '..\..')).Path

# Isolated config, set BEFORE the dot-source (install-k8s.ps1 reads these at top level):
#   • a throwaway cluster name so we never touch a real 'tracebloc' cluster
#   • a throwaway HOST_DATA_DIR so the install log + any data land in a temp dir
#     ($HOST_DATA_DIR\install-*.log is what the workflow uploads on failure)
#   • opt out of autostart so we don't reconfigure the host's boot state
if (-not $env:CLUSTER_NAME)  { $env:CLUSTER_NAME = 'tbe2ewin' }
if (-not $env:HOST_DATA_DIR) { $env:HOST_DATA_DIR = Join-Path $env:USERPROFILE '.tracebloc-e2e' }
$env:TRACEBLOC_NO_AUTOSTART = '1'
$env:TB_PESTER = '1'   # load the installer's functions WITHOUT running its main()

$stubNs = if ($env:TB_NAMESPACE) { $env:TB_NAMESPACE } else { 'tracebloc' }

# Load the REAL installer functions (Install-Kubectl / Install-K3dAndHelm / New-K3dCluster / …).
. (Join-Path $repo 'scripts\install-k8s.ps1')

try {
  Write-E2e "cluster=$env:CLUSTER_NAME  data=$env:HOST_DATA_DIR  ns=$stubNs"
  # The Windows installer is inherently ADMIN: Initialize-ToolDir creates
  # %ProgramFiles%\tracebloc\bin and writes the MACHINE PATH, and the tool installs land
  # there. TB_PESTER=1 skips the installer's own self-elevation gate, so assert elevation
  # here — fail fast with a clear pointer instead of a confusing mid-run failure at tool
  # setup (#436 Bugbot; the runner must run as Administrator — see docs/WINDOWS-E2E.md).
  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    Stop-E2e "the self-hosted runner must run as Administrator — the Windows installer creates %ProgramFiles%\tracebloc\bin and writes the Machine PATH (see docs/WINDOWS-E2E.md)."
  }

  Confirm-Config          # validates CLUSTER_NAME / HOST_DATA_DIR (no credentials involved)
  Initialize-ToolDir
  Start-InstallLog        # -> $HOST_DATA_DIR\install-<ts>.log (uploaded on failure)

  # 1. Docker/WSL must be UP. Docker Desktop + WSL2 + nested virt are runner prerequisites
  #    (docs/WINDOWS-E2E.md) — we verify, we do NOT reinstall Docker Desktop per run.
  docker info *> $null
  if ($LASTEXITCODE -ne 0) {
    Stop-E2e "Docker isn't running on this runner. Docker Desktop + WSL2 + nested virtualization are self-hosted-runner prerequisites for the Windows e2e (see docs/WINDOWS-E2E.md)."
  }
  Write-E2e "Docker is up."

  # 2. System tools (idempotent) — the same functions the installer's Step 2 uses.
  Install-Kubectl
  Install-K3dAndHelm

  # 3. Cluster — the installer's REAL bring-up path (Step 3).
  New-K3dCluster
  kubectl wait --for=condition=Ready nodes --all --timeout=180s --request-timeout=30s
  Confirm-NativeOk "nodes did not reach Ready"
  Write-E2e "Cluster is up and all nodes are Ready."

  # 4. Credential-free stub the CLI's discovery keys off (LABELS, not values) — mirrors
  #    e2e-journey.sh Step 3. No private image needed; pause is plenty (the pod never has to
  #    go Ready — discovery reads the Deployment's labels + the 'ingestor' ServiceAccount).
  kubectl create namespace $stubNs --request-timeout=30s 2>$null | Out-Null
  $stub = @"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ingestor
  namespace: $stubNs
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${stubNs}-jobs-manager
  namespace: $stubNs
  labels:
    app.kubernetes.io/name: client
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/instance: tbe2e-win
    app.kubernetes.io/version: 0.0.0-e2e
    helm.sh/chart: client-0.0.0-e2e
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: client
  template:
    metadata:
      labels:
        app.kubernetes.io/name: client
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
"@
  $stub | kubectl apply --request-timeout=30s -f -
  Confirm-NativeOk "stub release apply"

  # 5. Assert the discovery-shaped state exists (what DiscoverParentRelease selects on).
  $dep = (kubectl get deploy -n $stubNs -l app.kubernetes.io/name=client -o name --request-timeout=30s) -join ''
  if (-not $dep) { Stop-E2e "stub discovery: no client-labelled Deployment found" }
  kubectl get serviceaccount ingestor -n $stubNs --request-timeout=30s *> $null
  Confirm-NativeOk "stub discovery: 'ingestor' ServiceAccount missing"
  Write-E2e "Stub parent release is present and discovery-shaped ($dep)."

  # 6. "Copy catalog on the way" — assert the installer emitted its expected copy into the
  #    transcript (a smoke check that the installer output didn't silently drift/regress).
  # Fail if the log is missing — never report PASS on an unverified copy check (seal-check
  # rule: unsealed, never SILENTLY sealed; #436 Bugbot). Start-InstallLog set $LOG_FILE, so
  # its absence means the installer never got that far.
  if (-not ($script:LOG_FILE -and (Test-Path $script:LOG_FILE))) {
    Stop-E2e "install log not found ($($script:LOG_FILE)) — cannot verify the installer's copy; refusing to report PASS."
  }
  if ((Get-Content -Raw $script:LOG_FILE) -notmatch 'Creating k3d cluster') {
    Stop-E2e "install log is missing the expected 'Creating k3d cluster' copy — installer output drifted"
  }

  Write-E2e "PASS: bootstrap -> Docker up -> tools -> cluster -> credential-free stub discovery."
}
finally {
  # Teardown so the PERSISTENT runner is reusable (there is no per-run VM to destroy here).
  # Cluster only — leave $HOST_DATA_DIR\install-*.log for the workflow to upload on failure;
  # the workflow's always() step removes the data dir after the upload. Best-effort.
  try { k3d cluster delete $env:CLUSTER_NAME 2>$null | Out-Null } catch { }
}
