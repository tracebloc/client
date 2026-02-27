# =============================================================================
#  install-k8s.ps1  --  One-command Kubernetes + GPU installer  (Windows)
#
#  Engine  : k3d  (k3s inside Docker -- lightweight, prod-topology capable)
#  GPUs    : NVIDIA (via WSL2 passthrough)      AMD (unsupported on Windows)
#
#  Usage (PowerShell as Administrator):
#    irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex
#    -- OR locally --
#    Set-ExecutionPolicy Bypass -Scope Process -Force; .\install-k8s.ps1
#
#  macOS / Linux:
#    curl -fsSL https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.sh | bash
#
#  Environment variable overrides (optional, set before running):
#    $env:CLUSTER_NAME  = "myapp"          default: tracebloc
#    $env:SERVERS       = "1"              default: 1  (control-plane nodes)
#    $env:AGENTS        = "1"              default: 1  (worker nodes)
#    $env:K8S_VERSION   = "v1.29.4-k3s1"  default: latest
#    $env:HTTP_PORT     = "80"             default: 80
#    $env:HTTPS_PORT    = "443"            default: 443
#    $env:HOST_DATA_DIR = "C:\data"        default: $env:USERPROFILE\.tracebloc
# =============================================================================

#Requires -Version 5.1
param([switch]$Help)

# -- Admin check --------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "[ERROR] Run this script as Administrator (right-click > Run as Administrator)." -ForegroundColor Red
  exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =============================================================================
#  HELPERS
# =============================================================================

function Info($m)  { Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Ok($m)    { Write-Host "[OK]    $m" -ForegroundColor Green }
function Warn($m)  { Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Err($m)   { Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }
function Step($m)  { Write-Host "`n=== $m ===" -ForegroundColor White }
function Has($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function RefreshPath {
  $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
              [System.Environment]::GetEnvironmentVariable("PATH","User")
}

function Invoke-WithRetry {
  param(
    [scriptblock]$ScriptBlock,
    [int]$MaxAttempts = 3,
    [int]$DelaySeconds = 5,
    [string]$Label = "Operation"
  )
  for ($i = 1; $i -le $MaxAttempts; $i++) {
    try {
      $result = & $ScriptBlock
      return $result
    }
    catch {
      if ($i -eq $MaxAttempts) { throw }
      Warn "$Label -- attempt $i/$MaxAttempts failed: $_. Retrying in ${DelaySeconds}s..."
      Start-Sleep -Seconds $DelaySeconds
    }
  }
}

# =============================================================================
#  CONFIGURATION  (aligned with bash common.sh)
# =============================================================================

$CLUSTER_NAME  = if ($env:CLUSTER_NAME)  { $env:CLUSTER_NAME }  else { "tracebloc" }
$SERVERS       = if ($env:SERVERS)       { $env:SERVERS }       else { "1" }
$AGENTS        = if ($env:AGENTS)        { $env:AGENTS }        else { "1" }
$K8S_VERSION   = if ($env:K8S_VERSION)   { $env:K8S_VERSION }   else { "" }
$HTTP_PORT     = if ($env:HTTP_PORT)     { $env:HTTP_PORT }     else { "80" }
$HTTPS_PORT    = if ($env:HTTPS_PORT)    { $env:HTTPS_PORT }    else { "443" }
$HOST_DATA_DIR = if ($env:HOST_DATA_DIR) { $env:HOST_DATA_DIR } else { "$env:USERPROFILE\.tracebloc" }

$GPU_VENDOR       = "none"    # nvidia | amd | amd_unsupported | none
$NVIDIA_DRIVER_OK = $false
$K3D_GPU_FLAG     = ""        # "--gpus=all" when NVIDIA is ready

# =============================================================================
#  HELP
# =============================================================================

function Print-Help {
  Write-Host @"

Usage:
  irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex
  .\install-k8s.ps1 [-Help]

Environment variable overrides:
  CLUSTER_NAME   Cluster name                   (default: tracebloc)
  SERVERS        Control-plane nodes             (default: 1)
  AGENTS         Worker nodes                    (default: 1)
  K8S_VERSION    k3s image tag (empty = latest)  (default: "")
  HTTP_PORT      Host HTTP  ingress port         (default: 80)
  HTTPS_PORT     Host HTTPS ingress port         (default: 443)
  HOST_DATA_DIR  Persistent data directory       (default: ~\.tracebloc)

macOS / Linux:
  curl -fsSL https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.sh | bash

"@
  exit 0
}

# =============================================================================
#  INPUT VALIDATION
# =============================================================================

function Confirm-Config {
  if ($SERVERS -notmatch '^\d+$') { Err ("SERVERS must be a positive integer (got '" + $SERVERS + "')") }
  if ($AGENTS  -notmatch '^\d+$') { Err ("AGENTS must be a positive integer (got '" + $AGENTS + "')") }
  if ($HTTP_PORT  -notmatch '^\d+$') { Err ("HTTP_PORT must be a number (got '" + $HTTP_PORT + "')") }
  if ($HTTPS_PORT -notmatch '^\d+$') { Err ("HTTPS_PORT must be a number (got '" + $HTTPS_PORT + "')") }
}

# =============================================================================
#  LOG FILE
# =============================================================================

function Start-InstallLog {
  if (-not (Test-Path $HOST_DATA_DIR)) {
    New-Item -ItemType Directory -Path $HOST_DATA_DIR -Force | Out-Null
  }
  $script:LOG_FILE = "$HOST_DATA_DIR\install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
  try {
    Start-Transcript -Path $LOG_FILE -Append | Out-Null
    Info "Install log: $LOG_FILE"
  } catch {
    Warn "Could not start transcript logging: $_"
  }
}

# =============================================================================
#  BANNER
# =============================================================================

function Print-Banner {
  Write-Host ""
  Write-Host "+===============================================================+" -ForegroundColor Cyan
  Write-Host "|   Kubernetes (k3d/k3s) + GPU  One-Command Installer           |" -ForegroundColor Cyan
  Write-Host "|   Windows                                                     |" -ForegroundColor Cyan
  Write-Host "+===============================================================+" -ForegroundColor Cyan
  Info "Cluster='$CLUSTER_NAME'  Servers=$SERVERS  Agents=$AGENTS  HTTP=$HTTP_PORT  HTTPS=$HTTPS_PORT"
  Info "Host data dir: $HOST_DATA_DIR"
}

# =============================================================================
#  GPU DETECTION
# =============================================================================

function Confirm-NvidiaDriver {
  try {
    $cmd = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
    $nvSmi = if ($cmd) { $cmd.Source } else { $null }

    if (-not $nvSmi) {
      $found = Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" `
        -Recurse -Filter "nvidia-smi.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
      $nvSmi = if ($found) { $found.FullName } else { $null }
    }
    if (-not $nvSmi) {
      Warn "nvidia-smi not found -- NVIDIA drivers may not be installed."
      Warn "Download: https://www.nvidia.com/Download/index.aspx"
      return
    }

    $driverVer = (& $nvSmi --query-gpu=driver_version --format=csv,noheader 2>&1).Trim()
    $majorVer  = [int]($driverVer -replace '\..*', '')
    if ($majorVer -ge 460) {
      $script:NVIDIA_DRIVER_OK = $true
      Ok "NVIDIA driver $driverVer -- WSL2 GPU passthrough supported"
    } else {
      Warn "NVIDIA driver $driverVer is too old (need 460+)."
      Warn "Download latest: https://www.nvidia.com/Download/index.aspx"
    }
  } catch {
    Warn "Could not verify NVIDIA driver: $_"
  }
}

function Find-Gpu {
  Step "GPU Detection"

  try {
    $gpus = Get-CimInstance Win32_VideoController |
            Where-Object { $_.Name -notmatch "Microsoft|Basic|VirtualBox" }
    foreach ($gpu in $gpus) {
      if ($gpu.Name -match "NVIDIA") {
        $script:GPU_VENDOR = "nvidia"; Ok "NVIDIA GPU: $($gpu.Name)"; break
      }
      if ($gpu.Name -match "AMD|Radeon") {
        $script:GPU_VENDOR = "amd"; Ok "AMD GPU: $($gpu.Name)"; break
      }
    }
    if ($GPU_VENDOR -eq "none") { Warn "No discrete GPU found -- CPU-only mode." }
  } catch {
    Warn "GPU detection failed ($_) -- continuing in CPU-only mode."
  }

  if ($GPU_VENDOR -eq "nvidia") { Confirm-NvidiaDriver }

  if ($GPU_VENDOR -eq "amd") {
    Warn "AMD GPU detected but GPU passthrough via Docker Desktop on Windows is not supported."
    Warn "For AMD GPU in Kubernetes, use a Linux host with the bash installer instead."
    $script:GPU_VENDOR = "amd_unsupported"
  }
}

# =============================================================================
#  STEP 1 -- WINDOWS VIRTUALISATION FEATURES
# =============================================================================

function Enable-VirtualisationFeatures {
  Step "Step 1/5 -- Enabling Windows Virtualisation Features"

  $rebootNeeded = $false
  $features = @{
    "Microsoft-Windows-Subsystem-Linux" = "WSL2"
    "VirtualMachinePlatform"            = "Virtual Machine Platform"
    "Microsoft-Hyper-V-All"             = "Hyper-V"
  }

  $features.GetEnumerator() | ForEach-Object {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $_.Key -ErrorAction SilentlyContinue).State
    if ($state -ne "Enabled") {
      Info "Enabling $($_.Value)..."
      Enable-WindowsOptionalFeature -Online -FeatureName $_.Key -NoRestart | Out-Null
      $rebootNeeded = $true
    } else {
      Ok "$($_.Value) already enabled."
    }
  }

  if ($rebootNeeded) {
    Warn "A reboot is required to finish enabling virtualisation features."
    $choice = Read-Host "Reboot now? [y/N]"
    if ($choice -match "^[Yy]$") { Restart-Computer -Force }
    Err "Please reboot manually, then re-run this script."
  }

  Info "Updating WSL (this can take a few minutes on first run)..."
  $wslJob = Start-Job -ScriptBlock { cmd /c "wsl --update 2>&1" }
  Write-Host -NoNewline "  Updating"
  while ($wslJob.State -eq "Running") {
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 2
  }
  Write-Host ""
  $wslUpdate = Receive-Job -Job $wslJob
  $wslExitOk = $wslJob.State -eq "Completed"
  Remove-Job -Job $wslJob -Force
  if (-not $wslExitOk) { Warn "WSL update may not have completed cleanly. Continuing..." }

  $wslSet = cmd /c "wsl --set-default-version 2 2>&1"
  if ($LASTEXITCODE -eq 0) {
    Ok "WSL2 set as default."
  } else {
    Warn "Could not set WSL2 as default: $wslSet"
    Warn "Try running 'wsl --update' manually, then re-run this script."
  }
}

# =============================================================================
#  STEP 2 -- WINGET
# =============================================================================

function Install-Winget {
  Step "Step 2/5 -- Windows Package Manager (winget)"

  if (Has "winget") { Ok "winget: $(winget --version)"; return }

  Info "Installing winget..."
  $url  = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
  $dest = "$env:TEMP\winget-installer.msixbundle"
  Invoke-WithRetry -Label "winget download" -ScriptBlock {
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
  }
  Add-AppxPackage -Path $dest
  Remove-Item $dest -Force -ErrorAction SilentlyContinue
  RefreshPath
  Ok "winget installed."
}

# =============================================================================
#  STEP 3 -- DOCKER DESKTOP
# =============================================================================

function Install-DockerDesktop {
  Step "Step 3/5 -- Docker Desktop"

  $dockerExe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"

  if (-not (Test-Path $dockerExe)) {
    Info "Installing Docker Desktop..."
    if (Has "winget") {
      winget install -e --id Docker.DockerDesktop `
        --accept-package-agreements --accept-source-agreements --silent
    } else {
      $installer = "$env:TEMP\DockerDesktopInstaller.exe"
      Invoke-WithRetry -Label "Docker Desktop download" -ScriptBlock {
        Invoke-WebRequest -Uri "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" `
          -OutFile $installer -UseBasicParsing
      }
      Start-Process -FilePath $installer -ArgumentList "install --quiet --accept-license" -Wait
      Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }
    RefreshPath
    Ok "Docker Desktop installed."
  }

  $dockerRunning = $false
  try { docker info 2>&1 | Out-Null; $dockerRunning = ($LASTEXITCODE -eq 0) } catch {}

  if (-not $dockerRunning) {
    Info "Starting Docker Desktop..."
    Start-Process $dockerExe -ErrorAction SilentlyContinue
    Info "First launch? Accept the Docker license agreement in the UI."

    $maxWait = 60
    Write-Host -NoNewline "  Waiting for Docker engine"
    for ($i = 1; $i -le $maxWait; $i++) {
      Start-Sleep -Seconds 3
      try { docker info 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $dockerRunning = $true; break } } catch {}
      Write-Host -NoNewline "."
    }
    Write-Host ""

    if (-not $dockerRunning) {
      Warn "Docker did not start within $($maxWait * 3)s."
      Warn "On first install, open Docker Desktop and accept the license agreement."
      Err "Re-run this script once Docker Desktop is running."
    }
  }

  Ok "Docker running: $(docker --version)"
}

# =============================================================================
#  NVIDIA CONTAINER TOOLKIT (inside WSL2)
# =============================================================================

function Install-NvidiaContainerToolkit {
  if ($GPU_VENDOR -ne "nvidia" -or -not $NVIDIA_DRIVER_OK) { return }

  Step "NVIDIA Container Toolkit (inside WSL2)"
  Info "Installing nvidia-container-toolkit in the WSL2 environment..."

  # Find a usable WSL2 distro (prefer Ubuntu)
  $distroRaw = cmd /c "wsl --list --quiet 2>&1"
  $distros = ($distroRaw -split "`n") | ForEach-Object { $_.Trim() -replace '\x00','' } |
             Where-Object { $_ -match '^\w' }
  $wslDistro = ($distros | Where-Object { $_ -match 'Ubuntu' } | Select-Object -First 1)
  if (-not $wslDistro -and $distros) { $wslDistro = $distros[0] }

  if (-not $wslDistro) {
    Info "No WSL2 distro found -- installing Ubuntu..."
    cmd /c "wsl --install -d Ubuntu --no-launch 2>&1" | Out-Null
    cmd /c "wsl --setdefault Ubuntu 2>&1" | Out-Null
    Warn "Ubuntu WSL2 installed. Complete first-run setup in a separate terminal:"
    Warn "  Open Ubuntu from Start Menu, set a username/password, then close it."
    Err "Please complete WSL2 Ubuntu setup first, then re-run."
  }

  Info "Using WSL2 distro: $wslDistro"

  $nctScript = @'
#!/bin/bash
set -e
if command -v nvidia-ctk &>/dev/null; then echo "NCT already installed."; exit 0; fi
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
sudo apt-get update -qq
sudo apt-get install -y -q nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker --set-as-default 2>/dev/null || true
sudo nvidia-ctk runtime configure --runtime=containerd 2>/dev/null || true
echo "NCT installed successfully."
'@

  $scriptPath = "$env:TEMP\install-nct.sh"
  [System.IO.File]::WriteAllText($scriptPath, $nctScript.Replace("`r`n", "`n"))
  $wslPath = "/mnt/" + ($scriptPath -replace '\\','/' -replace '^([A-Za-z]):/', { $_.Groups[1].Value.ToLower() + '/' })

  cmd /c "wsl -d $wslDistro -- /bin/bash `"$wslPath`" 2>&1"
  Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue

  $nctVer = cmd /c "wsl -d $wslDistro -- nvidia-ctk --version 2>&1"
  if ($LASTEXITCODE -eq 0) {
    Ok "NVIDIA Container Toolkit in WSL2: $nctVer"
    $script:K3D_GPU_FLAG = "--gpus=all"
  } else {
    Warn "Could not verify nvidia-ctk inside WSL2 -- GPU support may be limited."
  }
}

# =============================================================================
#  STEP 4 -- KUBECTL
# =============================================================================

function Install-Kubectl {
  Step "Step 4/5 -- kubectl"

  if (Has "kubectl") { Ok "kubectl: $(kubectl version --client --short 2>$null)"; return }

  $kVer = Invoke-WithRetry -Label "kubectl version check" -ScriptBlock {
    (Invoke-WebRequest "https://dl.k8s.io/release/stable.txt" -UseBasicParsing).Content.Trim()
  }
  Info "Downloading kubectl $kVer..."
  Invoke-WithRetry -Label "kubectl download" -ScriptBlock {
    Invoke-WebRequest "https://dl.k8s.io/release/$kVer/bin/windows/amd64/kubectl.exe" `
      -OutFile "C:\Windows\System32\kubectl.exe" -UseBasicParsing
  }
  Ok "kubectl $kVer installed."
}

# =============================================================================
#  STEP 5 -- K3D AND HELM
# =============================================================================

function Install-K3dAndHelm {
  Step "Step 5/5 -- k3d and Helm"

  # -- k3d --
  if (-not (Has "k3d")) {
    if (Has "winget") {
      Info "Installing k3d via winget..."
      winget install -e --id Rancher.k3d `
        --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
    }
    RefreshPath

    if (-not (Has "k3d")) {
      Info "Downloading k3d binary directly..."
      $k3dVer = Invoke-WithRetry -Label "k3d version lookup" -ScriptBlock {
        (Invoke-WebRequest "https://api.github.com/repos/k3d-io/k3d/releases/latest" `
          -UseBasicParsing | ConvertFrom-Json).tag_name
      }
      Invoke-WithRetry -Label "k3d download" -ScriptBlock {
        Invoke-WebRequest "https://github.com/k3d-io/k3d/releases/download/$k3dVer/k3d-windows-amd64.exe" `
          -OutFile "C:\Windows\System32\k3d.exe" -UseBasicParsing
      }
    }
  }
  Ok "k3d: $(k3d version | Select-Object -First 1)"

  # -- Helm --
  if (-not (Has "helm")) {
    if (Has "winget") {
      Info "Installing Helm..."
      winget install -e --id Helm.Helm `
        --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
      RefreshPath
    }
    if (Has "helm") { Ok "helm: $(helm version --short 2>$null)" }
    else { Warn "Helm not installed -- install manually from https://helm.sh/docs/intro/install/" }
  } else {
    Ok "helm: $(helm version --short 2>$null)"
  }
}

# =============================================================================
#  CLUSTER CREATION
# =============================================================================

function New-K3dCluster {
  Step "Creating k3d Cluster: '$CLUSTER_NAME'"

  $clusterExists = (k3d cluster list 2>&1) -match "^$CLUSTER_NAME"

  if ($clusterExists) {
    $running = (k3d cluster list -o json 2>&1 | ConvertFrom-Json |
                Where-Object { $_.name -eq $CLUSTER_NAME }).serversRunning
    if ($running -gt 0) {
      Ok "Cluster '$CLUSTER_NAME' already running -- skipping creation."
    } else {
      Info "Cluster '$CLUSTER_NAME' exists but stopped -- starting..."
      k3d cluster start $CLUSTER_NAME
      Ok "Cluster started."
    }
  } else {
    if (-not (Test-Path $HOST_DATA_DIR)) {
      Info "Creating host data directory: $HOST_DATA_DIR"
      New-Item -ItemType Directory -Path $HOST_DATA_DIR -Force | Out-Null
    }

    $k3dArgs = @(
      "cluster", "create", $CLUSTER_NAME,
      "--servers", $SERVERS,
      "--agents",  $AGENTS,
      "--port",    "${HTTP_PORT}:80@loadbalancer",
      "--port",    "${HTTPS_PORT}:443@loadbalancer",
      "--api-port","6550",
      "-v",        "${HOST_DATA_DIR}:/tracebloc@all",
      "--wait"
    )

    if ($K8S_VERSION -ne "") { $k3dArgs += @("--image", "rancher/k3s:$K8S_VERSION") }
    if ($K3D_GPU_FLAG -ne "") {
      $k3dArgs += $K3D_GPU_FLAG
      Info "GPU flag active: $K3D_GPU_FLAG"
    }

    $modeMsg = if ($K3D_GPU_FLAG) { "with NVIDIA GPU passthrough" } else { "CPU-only" }
    Info "Creating cluster ($modeMsg): $SERVERS server(s) + $AGENTS agent(s)..."
    Info "(First run pulls the k3s image -- ~1 min on a good connection)"

    & k3d $k3dArgs
    if ($LASTEXITCODE -ne 0) { Err "k3d cluster creation failed -- see output above." }
    Ok "Cluster '$CLUSTER_NAME' created!"
  }

  k3d kubeconfig merge $CLUSTER_NAME --kubeconfig-switch-context | Out-Null
  Ok "kubeconfig updated -- kubectl now points to '$CLUSTER_NAME'."
}

# =============================================================================
#  GPU DEVICE PLUGIN AND VERIFICATION
# =============================================================================

function Install-GpuDevicePlugin {
  if ($GPU_VENDOR -ne "nvidia" -or -not $NVIDIA_DRIVER_OK -or $K3D_GPU_FLAG -eq "") { return }

  Step "Deploying NVIDIA k8s Device Plugin"

  $dpExists = kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset 2>&1
  if ($LASTEXITCODE -eq 0) {
    Ok "NVIDIA device plugin already deployed."
  } else {
    $dpUrl = "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml"
    Info "Applying NVIDIA device plugin DaemonSet..."
    kubectl apply -f $dpUrl
    kubectl rollout status daemonset/nvidia-device-plugin-daemonset `
      -n kube-system --timeout=120s 2>&1 | Out-Null
    Ok "NVIDIA device plugin deployed."
  }
}

function Confirm-GpuNode {
  if ($GPU_VENDOR -ne "nvidia" -or -not $NVIDIA_DRIVER_OK -or $K3D_GPU_FLAG -eq "") { return }

  Step "Verifying GPU Node Resource"
  Info "Waiting up to 90s for GPU to appear as allocatable..."

  $gpuCount = 0
  for ($i = 1; $i -le 18; $i++) {
    Start-Sleep -Seconds 5
    $alloc = kubectl get node -o jsonpath='{.items[0].status.allocatable}' 2>$null
    if ($alloc -match '"nvidia\.com/gpu":"?(\d+)') { $gpuCount = [int]$Matches[1]; break }
  }

  if ($gpuCount -gt 0) { Ok "GPU visible on node -- allocatable count: $gpuCount" }
  else { Warn "GPU not yet visible. Re-check: kubectl describe node | Select-String 'nvidia'" }
}

# =============================================================================
#  CLUSTER VERIFICATION
# =============================================================================

function Confirm-Cluster {
  Step "Cluster Status"
  kubectl cluster-info
  Write-Host ""
  kubectl get nodes -o wide
}

# =============================================================================
#  SUMMARY
# =============================================================================

function Print-Summary {
  Write-Host ""
  Write-Host "+===============================================================+" -ForegroundColor Green
  Write-Host "|  Kubernetes cluster '$CLUSTER_NAME' is ready!                  " -ForegroundColor Green -NoNewline
  Write-Host "|" -ForegroundColor Green
  if ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK) {
    Write-Host "|  NVIDIA GPU support enabled                                  |" -ForegroundColor Green
  } elseif ($GPU_VENDOR -eq "nvidia" -and -not $NVIDIA_DRIVER_OK) {
    Write-Host "|  NVIDIA GPU found -- update driver to 460+ for GPU support   |" -ForegroundColor Yellow
  } elseif ($GPU_VENDOR -eq "amd_unsupported") {
    Write-Host "|  AMD GPU -- use Linux host for AMD GPU in Kubernetes         |" -ForegroundColor Yellow
  }
  Write-Host "+===============================================================+" -ForegroundColor Green

  Write-Host ""
  Write-Host "  Cluster topology:" -ForegroundColor White
  Write-Host "  Servers (control-plane) : $SERVERS" -ForegroundColor Cyan
  Write-Host "  Agents  (workers)       : $AGENTS" -ForegroundColor Cyan
  Write-Host "  Ingress                 : localhost:$HTTP_PORT  /  localhost:$HTTPS_PORT" -ForegroundColor Cyan
  Write-Host "  Data dir                : $HOST_DATA_DIR -> /tracebloc (inside k3s nodes)" -ForegroundColor Cyan

  Write-Host ""
  Write-Host "  Common commands:" -ForegroundColor White
  Write-Host "  kubectl get nodes -o wide           " -NoNewline -ForegroundColor Cyan; Write-Host "-- all cluster nodes"
  Write-Host "  kubectl get pods -A                 " -NoNewline -ForegroundColor Cyan; Write-Host "-- all pods"
  Write-Host "  kubectl apply -f <manifest.yaml>    " -NoNewline -ForegroundColor Cyan; Write-Host "-- deploy your app"
  Write-Host "  helm install <name> <chart>         " -NoNewline -ForegroundColor Cyan; Write-Host "-- deploy via Helm"

  Write-Host ""
  Write-Host "  Cluster lifecycle:" -ForegroundColor White
  Write-Host "  k3d cluster stop   $CLUSTER_NAME   " -NoNewline -ForegroundColor Cyan; Write-Host "-- pause"
  Write-Host "  k3d cluster start  $CLUSTER_NAME   " -NoNewline -ForegroundColor Cyan; Write-Host "-- resume"
  Write-Host "  k3d cluster delete $CLUSTER_NAME   " -NoNewline -ForegroundColor Cyan; Write-Host "-- destroy"
  Write-Host "  k3d cluster list                    " -NoNewline -ForegroundColor Cyan; Write-Host "-- all clusters"

  if ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK) {
    Write-Host ""
    Write-Host "  GPU quick-test:" -ForegroundColor White
    Write-Host '  kubectl run gpu-test --rm -it --image=nvidia/cuda:12.3.1-base-ubuntu22.04 --limits="nvidia.com/gpu=1" -- nvidia-smi' -ForegroundColor Cyan
  }

  Write-Host ""
}

# =============================================================================
#  MAIN
# =============================================================================

if ($Help) { Print-Help }

Confirm-Config
Start-InstallLog
Print-Banner
Find-Gpu
Enable-VirtualisationFeatures
Install-Winget
Install-DockerDesktop
Install-NvidiaContainerToolkit
Install-Kubectl
Install-K3dAndHelm
New-K3dCluster
Install-GpuDevicePlugin
Confirm-GpuNode
Confirm-Cluster
Print-Summary

try { Stop-Transcript | Out-Null } catch {}
