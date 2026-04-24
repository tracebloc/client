# =============================================================================
#  install-k8s.ps1  --  tracebloc client installer  (Windows)
#
#  Sets up a secure compute environment and connects it to the tracebloc
#  network so external AI vendors can submit models for evaluation on
#  your infrastructure — without exposing your data.
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
#    $env:HOST_DATA_DIR = "C:\data"        default: $env:USERPROFILE\.tracebloc
#    $env:CLIENT_ENV    = "dev"            optional; if not set, CLIENT_ENV is not added to env in values
# =============================================================================

#Requires -Version 5.1
param([switch]$Help, [switch]$NoReboot)

# -- Admin check --------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red -NoNewline; Write-Host " Run this script as Administrator (right-click > Run as Administrator)." -ForegroundColor Red
  exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =============================================================================
#  HELPERS — logging functions matching bash UX
# =============================================================================

function Info($m)          { Write-Host "  " -NoNewline; Write-Host ([char]0x00B7) -ForegroundColor DarkGray -NoNewline; Write-Host " $m" -ForegroundColor DarkGray }
function Ok($m)            { Write-Host "  " -NoNewline; Write-Host ([char]0x2714) -ForegroundColor Green -NoNewline; Write-Host " $m" }
function Warn($m)          { Write-Host "  " -NoNewline; Write-Host ([char]0x26A0) -ForegroundColor Yellow -NoNewline; Write-Host "  $m" -ForegroundColor Yellow }
function Err($m)           { Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red -NoNewline; Write-Host " $m" -ForegroundColor Red; exit 1 }
function Step($n, $t, $l)  { Write-Host ""; Write-Host "Step $n/$t" -ForegroundColor Cyan -NoNewline; Write-Host "  $l" -ForegroundColor White }
function Log($m)           { if ($script:LOG_FILE) { Add-Content -Path $script:LOG_FILE -Value "[$(Get-Date -Format 'HH:mm:ss')] $m" -ErrorAction SilentlyContinue } }
function PromptHeader($m)  { Write-Host ""; Write-Host "  $m" -ForegroundColor White }
function Hint($m)          { Write-Host "  $m" -ForegroundColor DarkGray }
function Has($cmd)         { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function RefreshPath {
  $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
              [System.Environment]::GetEnvironmentVariable("PATH","User")
}

function Get-WindowsArch {
  switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64"  { return "amd64" }
    "ARM64"  { return "arm64" }
    default  { Err "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
  }
}

function Initialize-ToolDir {
  $script:TOOL_DIR = "$env:ProgramFiles\tracebloc\bin"
  if (-not (Test-Path $TOOL_DIR)) {
    New-Item -ItemType Directory -Path $TOOL_DIR -Force | Out-Null
  }
  $machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
  if ($machinePath -notlike "*$TOOL_DIR*") {
    [Environment]::SetEnvironmentVariable("PATH", "$machinePath;$TOOL_DIR", "Machine")
    RefreshPath
  }
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
      Warn "$Label -- attempt $i/$MaxAttempts failed. Retrying in ${DelaySeconds}s..."
      Start-Sleep -Seconds $DelaySeconds
    }
  }
}

# Sanitize workspace name to comply with DNS-1123
function ConvertTo-WorkspaceName {
  param([string]$Input_)
  $sanitized = $Input_.ToLower()
  $sanitized = $sanitized -replace '\s', '-'
  $sanitized = $sanitized -replace '_', '-'
  $sanitized = $sanitized -replace '[^a-z0-9-]', ''
  $sanitized = $sanitized -replace '-+', '-'
  $sanitized = $sanitized.Trim('-')
  if (-not $sanitized) { $sanitized = "default" }
  if ($sanitized.Length -gt 63) { $sanitized = $sanitized.Substring(0, 63).TrimEnd('-') }
  return $sanitized
}

# =============================================================================
#  CONFIGURATION
# =============================================================================

$CLUSTER_NAME  = if ($env:CLUSTER_NAME)  { $env:CLUSTER_NAME }  else { "tracebloc" }
$SERVERS       = if ($env:SERVERS)       { $env:SERVERS }       else { "1" }
$AGENTS        = if ($env:AGENTS)        { $env:AGENTS }        else { "1" }
$K8S_VERSION   = if ($env:K8S_VERSION)   { $env:K8S_VERSION }   else { "v1.29.4-k3s1" }
$HOST_DATA_DIR = if ($env:HOST_DATA_DIR) { $env:HOST_DATA_DIR } else { "$env:USERPROFILE\.tracebloc" }
$CLIENT_ENV    = $env:CLIENT_ENV

$GPU_VENDOR       = "none"
$NVIDIA_DRIVER_OK = $false
$K3D_GPU_FLAG     = ""

# =============================================================================
#  HELP
# =============================================================================

function Print-Help {
  Write-Host @"

tracebloc -- client setup

  Set up a secure compute environment on your machine
  and connect it to the tracebloc network.

Usage:
  irm https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.ps1 | iex
  .\install-k8s.ps1 [-Help] [-NoReboot]

Advanced configuration (environment variables):
  CLUSTER_NAME   Cluster name                   (default: tracebloc)
  SERVERS        Control-plane nodes             (default: 1)
  AGENTS         Worker nodes                    (default: 1)
  K8S_VERSION    k3s image tag                   (default: v1.29.4-k3s1)
  -NoReboot      Skip reboot prompt after enabling Windows features
  HOST_DATA_DIR  Persistent data directory       (default: ~\.tracebloc)

macOS / Linux:
  curl -fsSL https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.sh | bash

Learn more: https://docs.tracebloc.io

"@
  exit 0
}

# =============================================================================
#  INPUT VALIDATION
# =============================================================================

function Confirm-Config {
  if ($CLUSTER_NAME -notmatch '^[a-zA-Z][a-zA-Z0-9._-]{0,62}$') {
    Err ("CLUSTER_NAME must start with a letter, contain only [a-zA-Z0-9._-], max 63 chars (got '" + $CLUSTER_NAME + "')")
  }
  if ($SERVERS -notmatch '^[1-9]\d*$') { Err ("SERVERS must be a positive integer >= 1 (got '" + $SERVERS + "')") }
  if ($AGENTS  -notmatch '^\d+$') { Err ("AGENTS must be a non-negative integer (got '" + $AGENTS + "')") }
  $dataDir = [System.IO.Path]::GetFullPath($HOST_DATA_DIR)
  $userProfile = [System.IO.Path]::GetFullPath($env:USERPROFILE)
  if (-not $dataDir.StartsWith($userProfile, [StringComparison]::OrdinalIgnoreCase)) {
    Err ("HOST_DATA_DIR must be under USERPROFILE (got: " + $HOST_DATA_DIR + ")")
  }
  $forbidden = @("$env:SystemRoot", "${env:SystemRoot}\System32", "$env:ProgramFiles", "${env:ProgramFiles(x86)}")
  foreach ($f in $forbidden) {
    if ($f -and $dataDir.StartsWith([System.IO.Path]::GetFullPath($f), [StringComparison]::OrdinalIgnoreCase)) {
      Err ("HOST_DATA_DIR cannot be a system path: " + $HOST_DATA_DIR)
    }
  }
  $script:HOST_DATA_DIR = $dataDir
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
    Log "Install log: $LOG_FILE"
  } catch {
    Log "Could not start transcript logging: $_"
  }
}

# =============================================================================
#  BANNER
# =============================================================================

function Print-Banner {
  Write-Host ""
  Write-Host "  " -NoNewline; Write-Host "tracebloc" -ForegroundColor Cyan -NoNewline; Write-Host " -- client setup"
  Write-Host "  " -NoNewline; Write-Host ([string]([char]0x2500) * 40) -ForegroundColor DarkGray
  Write-Host ""
  Write-Host "  Test AI models from external vendors on your"
  Write-Host "  infrastructure -- without exposing your data."
  Write-Host ""
  Hint "This installer sets up a secure compute environment"
  Hint "on your machine and connects it to the tracebloc network."
  Write-Host ""
  Hint "Nothing will be modified outside:"
  Hint "  ~\.tracebloc\    (data and config)"
  Hint "  Docker           (container runtime)"
  Write-Host ""
  Log "Cluster='$CLUSTER_NAME'  Servers=$SERVERS  Agents=$AGENTS"
  Log "Host data dir: $HOST_DATA_DIR"
}

function Print-Roadmap {
  Write-Host "  Steps" -ForegroundColor White
  Hint ([string]([char]0x2500) * 5)
  Hint "1. Check system requirements"
  Hint "2. Set up secure compute environment"
  Hint "3. Install tracebloc client"
  Hint "4. Connect to tracebloc network"
  Write-Host ""
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
      Warn "NVIDIA drivers may not be installed."
      Hint "Download: https://www.nvidia.com/Download/index.aspx"
      return
    }

    $driverVer = (& $nvSmi --query-gpu=driver_version --format=csv,noheader 2>&1).Trim()
    $majorVer  = [int]($driverVer -replace '\..*', '')
    if ($majorVer -ge 460) {
      $script:NVIDIA_DRIVER_OK = $true
      Ok "NVIDIA GPU ready (driver $driverVer)"
    } else {
      Warn "NVIDIA driver $driverVer is too old (need 460+)."
      Hint "Download latest: https://www.nvidia.com/Download/index.aspx"
    }
  } catch {
    Warn "Could not verify NVIDIA driver: $_"
  }
}

function Find-Gpu {
  Log "GPU detection starting"

  try {
    $gpus = Get-CimInstance Win32_VideoController |
            Where-Object { $_.Name -notmatch "Microsoft|Basic|VirtualBox" }
    foreach ($gpu in $gpus) {
      if ($gpu.Name -match "NVIDIA") {
        $script:GPU_VENDOR = "nvidia"; Ok "NVIDIA GPU detected: $($gpu.Name)"; break
      }
      if ($gpu.Name -match "AMD|Radeon") {
        $script:GPU_VENDOR = "amd"; Ok "AMD GPU detected: $($gpu.Name)"; break
      }
    }
    if ($GPU_VENDOR -eq "none") { Info "No GPU detected. Your environment will run in CPU mode." }
  } catch {
    Info "No GPU detected. Your environment will run in CPU mode."
    Log "GPU detection failed: $_"
  }

  if ($GPU_VENDOR -eq "nvidia") { Confirm-NvidiaDriver }

  if ($GPU_VENDOR -eq "amd") {
    Warn "AMD GPU detected."
    Info "GPU acceleration is not available via Docker Desktop on Windows."
    Hint "For AMD GPU workloads, deploy tracebloc on a Linux machine."
    $script:GPU_VENDOR = "amd_unsupported"
  }
}

# =============================================================================
#  WINDOWS VIRTUALISATION FEATURES
# =============================================================================

function Enable-VirtualisationFeatures {
  $rebootNeeded = $false
  $features = @{
    "Microsoft-Windows-Subsystem-Linux" = "WSL2"
    "VirtualMachinePlatform"            = "Virtual Machine Platform"
  }
  $edition = (Get-CimInstance Win32_OperatingSystem).Caption
  if ($edition -notmatch "Home") {
    $features["Microsoft-Hyper-V-All"] = "Hyper-V"
  } else {
    Log "Windows Home detected -- Hyper-V not available, using WSL2 backend."
  }

  $features.GetEnumerator() | ForEach-Object {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $_.Key -ErrorAction SilentlyContinue).State
    if ($state -ne "Enabled") {
      Log "Enabling $($_.Value)..."
      Enable-WindowsOptionalFeature -Online -FeatureName $_.Key -NoRestart | Out-Null
      $rebootNeeded = $true
    } else {
      Log "$($_.Value) already enabled."
    }
  }

  if ($rebootNeeded) {
    Warn "A reboot is required to finish enabling system features."
    if ($NoReboot) {
      Hint "Reboot manually, then re-run this script."
      exit 2
    }
    $choice = Read-Host "  Reboot now? [y/N]"
    if ($choice -match "^[Yy]$") { Restart-Computer -Force }
    exit 2
  }

  Ok "System features"

  Log "Updating WSL..."
  $wslJob = Start-Job -ScriptBlock { cmd /c "wsl --update 2>&1" }
  Write-Host -NoNewline "  "
  $wslTimeoutSec = 90
  $wslElapsed = 0
  while ($wslJob.State -eq "Running" -and $wslElapsed -lt $wslTimeoutSec) {
    Write-Host -NoNewline "." -ForegroundColor DarkGray
    Start-Sleep -Seconds 2
    $wslElapsed += 2
  }
  Write-Host ""
  if ($wslJob.State -eq "Running") {
    Stop-Job $wslJob
    Log "WSL update timed out after ${wslTimeoutSec}s -- skipping."
    Warn "WSL update is taking too long. Skipping for now."
    Hint "Run 'wsl --update' manually after installation."
  } else {
    $wslUpdate = Receive-Job -Job $wslJob
    $wslExitOk = $wslJob.State -eq "Completed"
    if (-not $wslExitOk) { Log "WSL update may not have completed cleanly." }
  }
  Remove-Job -Job $wslJob -Force

  $wslSetJob = Start-Job -ScriptBlock { cmd /c "wsl --set-default-version 2 2>&1" }
  $wslSetDone = $wslSetJob | Wait-Job -Timeout 20
  if ($wslSetDone) {
    Receive-Job $wslSetJob | Out-Null
    Remove-Job $wslSetJob -Force
    Log "WSL2 set as default."
  } else {
    Stop-Job $wslSetJob; Remove-Job $wslSetJob -Force
    Warn "Could not set WSL2 as default."
    Hint "Try running 'wsl --set-default-version 2' manually."
  }
}

# =============================================================================
#  WINGET
# =============================================================================

function Install-Winget {
  if (Has "winget") { Log "winget: $(winget --version)"; return }

  Log "Installing winget..."
  $url  = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
  $dest = "$env:TEMP\winget-installer.msixbundle"
  Invoke-WithRetry -Label "winget download" -ScriptBlock {
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
  }
  Add-AppxPackage -Path $dest
  Remove-Item $dest -Force -ErrorAction SilentlyContinue
  RefreshPath
  Log "winget installed."
}

# =============================================================================
#  DOCKER DESKTOP
# =============================================================================

function Install-DockerDesktop {
  $dockerExe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"

  if (-not (Test-Path $dockerExe)) {
    if (Has "winget") {
      winget install -e --id Docker.DockerDesktop `
        --accept-package-agreements --accept-source-agreements --silent
    } else {
      $ddArch = Get-WindowsArch
      $installer = "$env:TEMP\DockerDesktopInstaller.exe"
      Invoke-WithRetry -Label "Docker download" -ScriptBlock {
        Invoke-WebRequest -Uri "https://desktop.docker.com/win/main/$ddArch/Docker%20Desktop%20Installer.exe" `
          -OutFile $installer -UseBasicParsing
      }
      Start-Process -FilePath $installer -ArgumentList "install --quiet --accept-license" -Wait
      Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }
    RefreshPath
  }

  $dockerRunning = $false
  try {
    $dkOut = (docker info --format '{{.ID}}' 2>$null) | Out-String
    if (-not [string]::IsNullOrWhiteSpace($dkOut)) { $dockerRunning = $true }
  } catch {}

  if (-not $dockerRunning) {
    Start-Process $dockerExe -ErrorAction SilentlyContinue

    $maxWait = 60
    Write-Host -NoNewline "  "
    $frames = @([char]0x2807, [char]0x2819, [char]0x2839, [char]0x2838, [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827, [char]0x2847, [char]0x280F)
    $f = 0
    for ($i = 1; $i -le $maxWait; $i++) {
      Start-Sleep -Seconds 3
      try {
        $dkOut = (docker info --format '{{.ID}}' 2>$null) | Out-String
        if (-not [string]::IsNullOrWhiteSpace($dkOut)) { $dockerRunning = $true; break }
      } catch {}
      Write-Host "`r  " -NoNewline
      Write-Host $frames[$f] -ForegroundColor Cyan -NoNewline
      Write-Host " Waiting for Docker..." -NoNewline
      $f = ($f + 1) % $frames.Count
    }
    Write-Host "`r                                    `r" -NoNewline

    if (-not $dockerRunning) {
      Write-Host ""
      Warn "Docker is not responding yet."
      Hint "This usually means it's still starting up."
      Write-Host ""
      Hint "1. Look for the Docker whale icon in your system tray"
      Hint "2. If Docker is open, wait until it says 'Docker Desktop is running'"
      Hint "3. Re-run this script once it's ready"
      Write-Host ""
      Hint "Nothing is broken -- Docker just needs a moment."
      Write-Host ""
      Err "Docker did not start in time. Re-run this script once Docker is ready."
    }
  }

  Ok "Docker"
}

# =============================================================================
#  NVIDIA CONTAINER TOOLKIT (inside WSL2)
# =============================================================================

function Install-NvidiaContainerToolkit {
  if ($GPU_VENDOR -ne "nvidia" -or -not $NVIDIA_DRIVER_OK) { return }

  Log "Setting up NVIDIA container toolkit in WSL2"

  $wslListJob = Start-Job -ScriptBlock {
    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    $raw = wsl --list --quiet 2>$null
    [Console]::OutputEncoding = $prevEncoding
    return $raw
  }
  $wslListDone = $wslListJob | Wait-Job -Timeout 30
  if (-not $wslListDone) {
    Stop-Job $wslListJob; Remove-Job $wslListJob -Force
    Warn "WSL did not respond in time. Skipping GPU container toolkit."
    Hint "Run 'wsl --update' manually, then re-run this script for GPU support."
    return
  }
  $distroRaw = Receive-Job $wslListJob
  Remove-Job $wslListJob -Force

  $distros = @($distroRaw | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' -and $_ -match '^\w' })
  $wslDistro = ($distros | Where-Object { $_ -match 'Ubuntu' } | Select-Object -First 1)
  if (-not $wslDistro -and $distros.Count -gt 0) { $wslDistro = $distros[0] }

  if (-not $wslDistro) {
    Log "No WSL2 distro found -- installing Ubuntu..."
    cmd /c "wsl --install -d Ubuntu --no-launch 2>&1" | Out-Null
    cmd /c "wsl --setdefault Ubuntu 2>&1" | Out-Null
    Warn "Ubuntu WSL2 installed but needs first-run setup."
    Hint "Open Ubuntu from the Start Menu and set a username/password."
    Hint "Then re-run this script for GPU support."
    return
  }

  Log "Using WSL2 distro: $wslDistro"

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

  $scriptPath = [System.IO.Path]::Combine($env:TEMP, "install-nct-$(Get-Random -Maximum 999999).sh")
  [System.IO.File]::WriteAllText($scriptPath, $nctScript.Replace("`r`n", "`n"))
  $wslPath = "/mnt/" + ($scriptPath -replace '\\','/' -replace '^([A-Za-z]):/', { $_.Groups[1].Value.ToLower() + '/' })

  $nctInstallJob = Start-Job -ScriptBlock {
    param($d, $p)
    cmd /c "wsl -d $d -- /bin/bash `"$p`" 2>&1"
  } -ArgumentList $wslDistro, $wslPath

  $nctDone = $nctInstallJob | Wait-Job -Timeout 180
  if (-not $nctDone) {
    Stop-Job $nctInstallJob; Remove-Job $nctInstallJob -Force
    Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
    Warn "GPU container toolkit installation timed out."
    Hint "You can set it up manually inside WSL later."
    return
  }
  Receive-Job $nctInstallJob | Out-Null
  Remove-Job $nctInstallJob -Force
  Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue

  $verJob = Start-Job -ScriptBlock {
    param($d)
    cmd /c "wsl -d $d -- nvidia-ctk --version 2>&1"
  } -ArgumentList $wslDistro

  $verDone = $verJob | Wait-Job -Timeout 15
  if ($verDone) {
    $nctVer = (Receive-Job $verJob | Out-String).Trim()
    Remove-Job $verJob -Force
    if ($nctVer -and $nctVer -notmatch 'error|not found') {
      Log "NVIDIA Container Toolkit in WSL2: $nctVer"
      $script:K3D_GPU_FLAG = "--gpus=all"
    } else {
      Warn "GPU setup may need manual attention."
    }
  } else {
    Stop-Job $verJob; Remove-Job $verJob -Force
    Warn "GPU setup may need manual attention."
  }
}

# =============================================================================
#  SYSTEM TOOLS (kubectl, k3d, helm)
# =============================================================================

function Install-Kubectl {
  if (Has "kubectl") { Log "kubectl: $(cmd /c 'kubectl version --client 2>&1' | Select-Object -First 1)"; return }

  $arch = Get-WindowsArch
  $kVer = Invoke-WithRetry -Label "version check" -ScriptBlock {
    (Invoke-WebRequest "https://dl.k8s.io/release/stable.txt" -UseBasicParsing).Content.Trim()
  }
  Log "Downloading kubectl $kVer ($arch)..."
  $kubectlDest = "$TOOL_DIR\kubectl.exe"
  Invoke-WithRetry -Label "download" -ScriptBlock {
    Invoke-WebRequest "https://dl.k8s.io/release/$kVer/bin/windows/$arch/kubectl.exe" `
      -OutFile $kubectlDest -UseBasicParsing
  }
  $expectedHash = Invoke-WithRetry -Label "checksum" -ScriptBlock {
    (Invoke-WebRequest "https://dl.k8s.io/release/$kVer/bin/windows/$arch/kubectl.exe.sha256" `
      -UseBasicParsing).Content.Trim()
  }
  $actualHash = (Get-FileHash $kubectlDest -Algorithm SHA256).Hash.ToLower()
  if ($actualHash -ne $expectedHash.ToLower()) {
    Remove-Item $kubectlDest -Force
    Err "System tool checksum verification failed."
  }
  RefreshPath
  Log "kubectl $kVer installed."
}

function Install-K3dAndHelm {
  # -- k3d --
  if (-not (Has "k3d")) {
    if (Has "winget") {
      Log "Installing k3d via winget..."
      $null = (winget install -e --id Rancher.k3d `
        --accept-package-agreements --accept-source-agreements --silent 2>&1)
    }
    RefreshPath

    if (-not (Has "k3d")) {
      $arch = Get-WindowsArch
      Log "Downloading k3d binary directly ($arch)..."
      $k3dVer = Invoke-WithRetry -Label "k3d version lookup" -ScriptBlock {
        (Invoke-WebRequest "https://api.github.com/repos/k3d-io/k3d/releases/latest" `
          -UseBasicParsing | ConvertFrom-Json).tag_name
      }
      $k3dDest = "$TOOL_DIR\k3d.exe"
      Invoke-WithRetry -Label "k3d download" -ScriptBlock {
        Invoke-WebRequest "https://github.com/k3d-io/k3d/releases/download/$k3dVer/k3d-windows-$arch.exe" `
          -OutFile $k3dDest -UseBasicParsing
      }
      try {
        $checksums = Invoke-WithRetry -Label "k3d checksums" -ScriptBlock {
          (Invoke-WebRequest "https://github.com/k3d-io/k3d/releases/download/$k3dVer/sha256sum.txt" `
            -UseBasicParsing).Content
        }
        $expectedHash = ($checksums -split "`n" |
          Where-Object { $_ -match "k3d-windows-$arch\.exe" }) -replace '\s+.*',''
        if ($expectedHash) {
          $actualHash = (Get-FileHash $k3dDest -Algorithm SHA256).Hash.ToLower()
          if ($actualHash -ne $expectedHash.Trim().ToLower()) {
            Remove-Item $k3dDest -Force
            Err "System tool checksum verification failed."
          }
          Log "k3d checksum verified."
        }
      } catch {
        Log "Could not verify k3d checksum: $_"
      }
      RefreshPath
    }
  }
  Log "k3d: $(k3d version | Select-Object -First 1)"

  # -- Helm --
  if (-not (Has "helm")) {
    if (Has "winget") {
      Log "Installing Helm via winget..."
      $null = (winget install -e --id Helm.Helm `
        --accept-package-agreements --accept-source-agreements --silent 2>&1)
      RefreshPath
    }

    if (-not (Has "helm")) {
      $arch = Get-WindowsArch
      Log "Downloading Helm binary directly ($arch)..."
      $helmVer = Invoke-WithRetry -Label "helm version lookup" -ScriptBlock {
        (Invoke-WebRequest "https://api.github.com/repos/helm/helm/releases/latest" `
          -UseBasicParsing | ConvertFrom-Json).tag_name
      }
      $helmZip = "$env:TEMP\helm-$helmVer-windows-$arch.zip"
      Invoke-WithRetry -Label "helm download" -ScriptBlock {
        Invoke-WebRequest "https://get.helm.sh/helm-$helmVer-windows-$arch.zip" `
          -OutFile $helmZip -UseBasicParsing
      }
      $helmExtract = "$env:TEMP\helm-extract"
      if (Test-Path $helmExtract) { Remove-Item $helmExtract -Recurse -Force }
      Expand-Archive -Path $helmZip -DestinationPath $helmExtract -Force
      Copy-Item "$helmExtract\windows-$arch\helm.exe" "$TOOL_DIR\helm.exe" -Force
      Remove-Item $helmZip -Force -ErrorAction SilentlyContinue
      Remove-Item $helmExtract -Recurse -Force -ErrorAction SilentlyContinue
      RefreshPath
    }

    if (-not (Has "helm")) { Err "Helm could not be installed. Install manually from https://helm.sh/docs/intro/install/ and re-run." }
  }
  Log "helm: $(cmd /c 'helm version --short 2>&1')"

  Ok "System tools"
}

# =============================================================================
#  CLUSTER CREATION
# =============================================================================

function New-K3dCluster {
  Log "Creating k3d cluster: '$CLUSTER_NAME'"

  $clusterExists = $false
  $clusterObj = $null
  try {
    $clusterListJson = k3d cluster list -o json 2>&1 | Out-String
    $clusterObj = $clusterListJson | ConvertFrom-Json | Where-Object { $_.name -eq $CLUSTER_NAME } | Select-Object -First 1
    $clusterExists = $null -ne $clusterObj
  } catch {}

  if ($clusterExists) {
    $running = $clusterObj.serversRunning
    if ($running -gt 0) {
      Ok "Compute environment already running."
    } else {
      Log "Cluster '$CLUSTER_NAME' exists but stopped -- starting..."
      k3d cluster start $CLUSTER_NAME
      Ok "Compute environment started."
    }
  } else {
    if (-not (Test-Path $HOST_DATA_DIR)) {
      New-Item -ItemType Directory -Path $HOST_DATA_DIR -Force | Out-Null
    }

    # The tracebloc client is outbound-only: jobs-manager + pods-monitor dial
    # out to the platform, and the only in-cluster Service (mysql-client) is
    # ClusterIP. Disable k3s components that exist solely to handle inbound
    # traffic or duplicate chart-provided resources:
    #   traefik        — no Ingress resources in the chart
    #   servicelb      — no LoadBalancer Services
    #   local-storage  — chart creates its own StorageClass (client-storage-class)
    #
    # metrics-server is kept: the tracebloc-resource-monitor DaemonSet queries
    # the metrics.k8s.io API for node CPU/memory; without it the DaemonSet
    # crash-loops with 404s against /apis/metrics.k8s.io/v1beta1.
    $k3dArgs = @(
      "cluster", "create", $CLUSTER_NAME,
      "--servers", $SERVERS,
      "--agents",  $AGENTS,
      "--api-port","6550",
      "-v",        "${HOST_DATA_DIR}:/tracebloc@all",
      "--k3s-arg", "--disable=traefik@server:*",
      "--k3s-arg", "--disable=servicelb@server:*",
      "--k3s-arg", "--disable=local-storage@server:*",
      "--wait"
    )

    if ($K8S_VERSION -ne "" -and $K8S_VERSION -ne "latest") { $k3dArgs += @("--image", "rancher/k3s:$K8S_VERSION") }
    if ($K3D_GPU_FLAG -ne "") {
      $k3dArgs += $K3D_GPU_FLAG
      Log "GPU flag active: $K3D_GPU_FLAG"
    }

    Log "Creating cluster: $SERVERS server(s) + $AGENTS agent(s)..."
    Hint "First run may take a few minutes to download components."

    $k3dExe = (Get-Command k3d -ErrorAction SilentlyContinue).Source
    if (-not $k3dExe) { $k3dExe = "k3d" }
    $k3dArgString = ($k3dArgs | ForEach-Object {
      if ($_ -match '[\s@]') { "`"$_`"" } else { $_ }
    }) -join " "
    $k3dOutLog = Join-Path $env:TEMP "k3d-create-$(Get-Random).log"
    $k3dErrLog = Join-Path $env:TEMP "k3d-create-err-$(Get-Random).log"

    $k3dProc = Start-Process -FilePath $k3dExe -ArgumentList $k3dArgString `
      -NoNewWindow -PassThru `
      -RedirectStandardOutput $k3dOutLog `
      -RedirectStandardError $k3dErrLog

    $frames = @([char]0x2807, [char]0x2819, [char]0x2839, [char]0x2838, [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827, [char]0x2847, [char]0x280F)
    $f = 0
    Write-Host -NoNewline "  "
    while (-not $k3dProc.HasExited) {
      Write-Host "`r  " -NoNewline
      Write-Host $frames[$f] -ForegroundColor Cyan -NoNewline
      Write-Host " Creating compute environment..." -NoNewline
      $f = ($f + 1) % $frames.Count
      Start-Sleep -Seconds 2
    }
    Write-Host "`r                                                   `r" -NoNewline

    $k3dExitCode = $k3dProc.ExitCode
    $k3dStdout = if (Test-Path $k3dOutLog) { Get-Content $k3dOutLog -Raw -ErrorAction SilentlyContinue } else { "" }
    $k3dStderr = if (Test-Path $k3dErrLog) { Get-Content $k3dErrLog -Raw -ErrorAction SilentlyContinue } else { "" }
    Remove-Item $k3dOutLog, $k3dErrLog -Force -ErrorAction SilentlyContinue
    if ($k3dStdout) { Log "k3d stdout: $k3dStdout" }
    if ($k3dStderr) { Log "k3d stderr: $k3dStderr" }

    if ($k3dExitCode -ne 0) { Err "Failed to create compute environment." }
    Ok "Compute environment ready."
  }

  k3d kubeconfig merge $CLUSTER_NAME --kubeconfig-switch-context | Out-Null

  $kubeConfigPath = "$env:USERPROFILE\.kube\config"
  if (Test-Path $kubeConfigPath) {
    (Get-Content $kubeConfigPath) -replace 'host\.docker\.internal', '127.0.0.1' | Set-Content $kubeConfigPath -Encoding UTF8
  }

  Log "kubeconfig updated -- kubectl now points to '$CLUSTER_NAME'."
}

# =============================================================================
#  GPU DEVICE PLUGIN AND VERIFICATION
# =============================================================================

function Install-GpuDevicePlugin {
  if ($GPU_VENDOR -ne "nvidia" -or -not $NVIDIA_DRIVER_OK -or $K3D_GPU_FLAG -eq "") { return }

  Log "Deploying NVIDIA k8s device plugin"

  $dpExists = kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset 2>&1
  if ($LASTEXITCODE -eq 0) {
    Ok "GPU acceleration enabled."
  } else {
    $dpUrl = "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml"
    $dpTmp = [System.IO.Path]::GetTempFileName()
    try {
      Invoke-WithRetry -Label "GPU plugin download" -ScriptBlock {
        Invoke-WebRequest -Uri $dpUrl -OutFile $dpTmp -UseBasicParsing
      }
      if ((Get-Item $dpTmp).Length -gt 0) {
        kubectl apply -f $dpTmp
        $null = (kubectl rollout status daemonset/nvidia-device-plugin-daemonset `
          -n kube-system --timeout=120s 2>&1)
        Ok "GPU acceleration enabled."
      } else { Err "Failed to enable GPU acceleration." }
    } finally {
      Remove-Item $dpTmp -Force -ErrorAction SilentlyContinue
    }
  }
}

function Confirm-GpuNode {
  if ($GPU_VENDOR -ne "nvidia" -or -not $NVIDIA_DRIVER_OK -or $K3D_GPU_FLAG -eq "") { return }

  Log "Verifying GPU on node..."

  $gpuCount = 0
  for ($i = 1; $i -le 18; $i++) {
    Start-Sleep -Seconds 5
    $alloc = kubectl get node -o jsonpath='{.items[0].status.allocatable}' 2>$null
    if ($alloc -match '"nvidia\.com/gpu":"?(\d+)') { $gpuCount = [int]$Matches[1]; break }
  }

  if ($gpuCount -gt 0) {
    Ok "GPU verified and available."
    Log "Allocatable GPU count: $gpuCount"
  } else {
    Warn "GPU may still be initializing. Check back shortly."
  }
}

# =============================================================================
#  INSTALL TRACEBLOC CLIENT
# =============================================================================

$TRACEBLOC_HELM_REPO_URL = "https://tracebloc.github.io/client"
$TRACEBLOC_HELM_REPO_NAME = "tracebloc"
$TRACEBLOC_CHART_NAME = "client"

function Get-TraceblocYamlValue {
  param([string]$Path, [string]$Key)
  if (-not (Test-Path $Path)) { return "" }
  $line = Get-Content $Path -ErrorAction SilentlyContinue | Where-Object { $_ -match "^\s*${Key}\s*:" } | Select-Object -First 1
  if (-not $line) { return "" }
  $val = $line -replace "^\s*${Key}\s*:\s*", ""
  $val = $val.Trim()

  if ($val.StartsWith("'") -and $val.EndsWith("'") -and $val.Length -ge 2) {
    $val = $val.Substring(1, $val.Length - 2)
    $val = $val -replace "''", "'"
  } elseif ($val.StartsWith('"') -and $val.EndsWith('"') -and $val.Length -ge 2) {
    $val = $val.Substring(1, $val.Length - 2)
  }

  return $val
}

function Install-ClientHelm {
  # -- Step 3/4: Install tracebloc client --
  Step 3 4 "Installing tracebloc client"

  if (-not (Test-Path $HOST_DATA_DIR)) {
    New-Item -ItemType Directory -Path $HOST_DATA_DIR -Force | Out-Null
  }
  $valuesFile = Join-Path $HOST_DATA_DIR "values.yaml"

  $defaultNamespace = "default"
  $defaultClientId = ""
  $defaultClientPassword = ""

  if (Test-Path $valuesFile) {
    Hint "Previous configuration found."
    do {
      $useExisting = Read-Host "  Use previous settings as defaults? [Y/n]"
      $useExisting = if ($useExisting) { $useExisting.Trim().ToLowerInvariant() } else { "y" }
      if ($useExisting -eq "y" -or $useExisting -eq "yes" -or $useExisting -eq "n" -or $useExisting -eq "no" -or $useExisting -eq "") { break }
      Warn "Please enter y or n."
    } while ($true)

    if ($useExisting -eq "y" -or $useExisting -eq "yes" -or $useExisting -eq "") {
      $defaultClientId = Get-TraceblocYamlValue -Path $valuesFile -Key "clientId"
      $defaultClientPassword = Get-TraceblocYamlValue -Path $valuesFile -Key "clientPassword"
      if ($defaultClientId) { Log "Using existing clientId as default." }
      if ($defaultClientPassword) { Log "Using existing clientPassword as default." }
    }
  }

  # -- Workspace name prompt --
  PromptHeader "Choose a workspace name"
  Hint "This identifies your tracebloc client on this machine."
  Write-Host ""
  Hint "Examples: myteam, vision-lab, lukas"
  Write-Host ""
  $nsInput = Read-Host "  Workspace name [$defaultNamespace]"
  $rawName = if ($nsInput) { $nsInput } else { $defaultNamespace }
  $TB_NAMESPACE = ConvertTo-WorkspaceName -Input_ $rawName

  if ($TB_NAMESPACE -ne $rawName) {
    Info "Using workspace: $TB_NAMESPACE"
  }

  # -- Step 4/4: Connect to tracebloc network --
  Step 4 4 "Connect to tracebloc network"

  PromptHeader "To connect this machine, you need a tracebloc client."
  Hint "A client links your secure environment to the tracebloc"
  Hint "platform so vendors can submit models for evaluation."
  Write-Host ""
  Hint "Create one here (free):"
  Write-Host "    " -NoNewline; Write-Host "https://ai.tracebloc.io/clients" -ForegroundColor White
  Write-Host ""

  if ($defaultClientId) {
    $idInput = Read-Host "  Client ID [$defaultClientId]"
    $TB_CLIENT_ID = if ($idInput) { $idInput } else { $defaultClientId }
  } else {
    $TB_CLIENT_ID = Read-Host "  Client ID"
  }
  if (-not $TB_CLIENT_ID) { Err "Client ID cannot be empty." }

  if ($defaultClientPassword) {
    $pwInput = Read-Host "  Client password [press Enter to keep existing]" -AsSecureString
    if ($pwInput -and $pwInput.Length -gt 0) {
      $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwInput)
      try { $TB_CLIENT_PASSWORD = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
    } else {
      $TB_CLIENT_PASSWORD = $defaultClientPassword
    }
  } else {
    $pwInput = Read-Host "  Client password" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwInput)
    try { $TB_CLIENT_PASSWORD = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
  }
  if (-not $TB_CLIENT_PASSWORD) { Err "Client password cannot be empty." }

  $passwordEscaped = $TB_CLIENT_PASSWORD -replace "'", "''"

  $gpuVal = ""
  if ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK) {
    $gpuVal = "nvidia.com/gpu=1"
    Log "NVIDIA GPU -- setting GPU_LIMITS and GPU_REQUESTS to nvidia.com/gpu=1"
  } else {
    Log "No NVIDIA GPU -- GPU_LIMITS and GPU_REQUESTS left empty"
  }

  Log "Writing values to $valuesFile"
  $envBlock = "env:`n"
  if ($CLIENT_ENV) {
    $envBlock += "  CLIENT_ENV: $CLIENT_ENV`n"
  }
  $envBlock += @"
  RESOURCE_LIMITS: "cpu=2,memory=8Gi"
  RESOURCE_REQUESTS: "cpu=2,memory=8Gi"
  GPU_LIMITS: "$gpuVal"
  GPU_REQUESTS: "$gpuVal"
  RUNTIME_CLASS_NAME: ""

storageClass:
  create: true
  name: client-storage-class
  provisioner: manual
  allowVolumeExpansion: true
  parameters: {}

hostPath:
  enabled: true

pvc:
  mysql: 2Gi
  logs: 10Gi
  data: 50Gi

pvcAccessMode: ReadWriteOnce

clusterScope: true

clientId: "$TB_CLIENT_ID"
clientPassword: '$passwordEscaped'

"@
  $valuesContent = @"
# ============================================================
# Generated by tracebloc installer -- client configuration
# ============================================================

$envBlock
"@
  Set-Content -Path $valuesFile -Value $valuesContent -Encoding UTF8
  Log "Values file written to $valuesFile"

  $repoList = (helm repo list 2>&1) | Out-String
  if ($repoList -notmatch [regex]::Escape($TRACEBLOC_HELM_REPO_NAME)) {
    Log "Adding Helm repo: $TRACEBLOC_HELM_REPO_URL"
    $null = (helm repo add $TRACEBLOC_HELM_REPO_NAME $TRACEBLOC_HELM_REPO_URL 2>&1)
    if ($LASTEXITCODE -ne 0) { Err "Failed to connect to tracebloc." }
  }
  Log "Updating Helm repos..."
  $null = (helm repo update 2>&1)

  Write-Host ""
  Log "Installing $TB_NAMESPACE from $TRACEBLOC_HELM_REPO_NAME/$TRACEBLOC_CHART_NAME in namespace '$TB_NAMESPACE'..."
  $helmOutput = (helm upgrade --install $TB_NAMESPACE "$TRACEBLOC_HELM_REPO_NAME/$TRACEBLOC_CHART_NAME" `
    --namespace $TB_NAMESPACE `
    --create-namespace `
    --values $valuesFile 2>&1) | Out-String
  Log "Helm Output: $helmOutput"
  if ($LASTEXITCODE -ne 0) { Err "Client installation failed. Helm output:`n$helmOutput`nCheck the log for details: $LOG_FILE" }

  Ok "Connected to tracebloc"
  Log "Values file: $valuesFile"
}

# =============================================================================
#  CLUSTER VERIFICATION
# =============================================================================

function Confirm-Cluster {
  Log "--- Cluster Status ---"
  $clusterInfo = kubectl cluster-info 2>&1 | Out-String
  Log $clusterInfo
  $nodes = kubectl get nodes -o wide 2>&1 | Out-String
  Log $nodes
  Log "--- End Cluster Status ---"
}

# =============================================================================
#  SUMMARY
# =============================================================================

function Print-Summary {
  $mode = "CPU"
  if ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK) { $mode = "NVIDIA GPU" }
  elseif ($GPU_VENDOR -eq "nvidia" -and -not $NVIDIA_DRIVER_OK) { $mode = "CPU (NVIDIA driver update needed)" }

  Write-Host ""
  Write-Host "  " -NoNewline; Write-Host ([string]([char]0x2501) * 46) -ForegroundColor Green
  Write-Host ""
  Write-Host "  " -NoNewline; Write-Host "tracebloc client installed successfully" -ForegroundColor Green
  Write-Host ""
  Write-Host "  " -NoNewline; Write-Host "Workspace" -ForegroundColor White -NoNewline; Write-Host " : " -NoNewline; Write-Host $TB_NAMESPACE -ForegroundColor Cyan
  Write-Host "  " -NoNewline; Write-Host "Mode     " -ForegroundColor White -NoNewline; Write-Host " : " -NoNewline; Write-Host $mode -ForegroundColor Cyan
  Write-Host ""
  Hint "This machine is now a secure compute environment"
  Hint "on the tracebloc network. External AI vendors can"
  Hint "submit models to be trained and evaluated here --"
  Hint "your data never leaves your infrastructure."
  Write-Host ""
  Write-Host "  What to do next" -ForegroundColor White
  Write-Host ""
  Write-Host "  1. " -NoNewline; Write-Host "Open the tracebloc dashboard"
  Write-Host "     " -NoNewline; Write-Host "https://ai.tracebloc.io" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  2. " -NoNewline; Write-Host "Ingest your training and test data"
  Write-Host ""
  Write-Host "  3. " -NoNewline; Write-Host "Define your first AI use case and"
  Write-Host "     invite vendors to submit models"
  Write-Host ""
  Hint "Need help?  https://docs.tracebloc.io"
  Hint "Logs:       ~\.tracebloc\"
  Hint "Data:       /tracebloc/$TB_NAMESPACE"
  Write-Host ""
  Write-Host "  " -NoNewline; Write-Host ([string]([char]0x2501) * 46) -ForegroundColor Green
  Write-Host ""

  # Advanced info for log only
  Log ""
  Log "=== Advanced Info (for debugging) ==="
  Log "Cluster topology: Servers=$SERVERS  Agents=$AGENTS"
  Log "Volume mount: $HOST_DATA_DIR -> /tracebloc"
  Log ""
  Log "Useful commands:"
  Log "  kubectl get nodes -o wide"
  Log "  kubectl get pods -A"
  Log "  kubectl get pods -n $TB_NAMESPACE"
  Log "  k3d cluster stop $CLUSTER_NAME"
  Log "  k3d cluster start $CLUSTER_NAME"
  Log "  k3d cluster delete $CLUSTER_NAME"
  if ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK) {
    Log '  GPU test: kubectl run gpu-test --rm -it --image=nvidia/cuda:12.3.1-base-ubuntu22.04 --limits="nvidia.com/gpu=1" -- nvidia-smi'
  }
  Log "=== End Advanced Info ==="
}

# =============================================================================
#  MAIN
# =============================================================================

if ($Help) { Print-Help }

Confirm-Config
Initialize-ToolDir
Start-InstallLog
Print-Banner
Print-Roadmap

# -- Step 1/4: Check system requirements --
Step 1 4 "Checking system requirements"
Find-Gpu
Enable-VirtualisationFeatures
Install-Winget
Install-DockerDesktop
Install-NvidiaContainerToolkit
Install-Kubectl
Install-K3dAndHelm

# -- Step 2/4: Set up secure compute environment --
Step 2 4 "Setting up secure compute environment"
New-K3dCluster
Install-GpuDevicePlugin
Confirm-GpuNode

# -- Steps 3/4 + 4/4 handled inside Install-ClientHelm --
Install-ClientHelm

Confirm-Cluster
Print-Summary

try { Stop-Transcript | Out-Null } catch {}
