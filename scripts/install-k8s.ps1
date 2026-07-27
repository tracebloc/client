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
#    $env:HOST_DATA_DIR = "C:\data"        default: $env:USERPROFILE\.tracebloc (LOCAL disk; no NFS/UNC)
#    $env:CLIENT_ENV    = "dev"            optional; if not set, CLIENT_ENV is not added to env in values
#    $env:TRACEBLOC_TRAINING_RESOURCES = "cpu=4,memory=16Gi"   optional; overrides the machine-sized training default
# =============================================================================

#Requires -Version 5.1
param([switch]$Help, [switch]$NoReboot, [switch]$Diagnose)

# -- Admin check --------------------------------------------------------------
# $env:TB_PESTER lets the test suite dot-source this file to load the functions
# without triggering the admin gate (which throws off-Windows) or running main.
if (-not $env:TB_PESTER) {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    # In the documented flow (`irm tracebloc.io/i.ps1 | iex`) there is no script
    # file to right-click, so the old "right-click > Run as Administrator" advice
    # was impossible to follow (#386). Give the actual steps.
    Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red -NoNewline; Write-Host " Administrator rights required." -ForegroundColor Red
    Write-Host "  Open an elevated PowerShell: press Win+X and choose 'Terminal (Admin)'" -ForegroundColor DarkGray
    Write-Host "  (or search 'PowerShell' in Start and press Ctrl+Shift+Enter)," -ForegroundColor DarkGray
    Write-Host "  accept the User Account Control prompt, then re-run:" -ForegroundColor DarkGray
    Write-Host "    irm https://tracebloc.io/i.ps1 | iex" -ForegroundColor Cyan
    exit 1
  }

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

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

# Spin a braille spinner while a process runs, bounded by a deadline (#426):
# `k3d cluster create --wait` has no timeout of its own, so a stalled image
# pull would otherwise spin forever. Returns $true when the process exited on
# its own, $false on deadline expiry (the process is killed best-effort).
# Extracted as a function so the deadline/kill path is unit-testable (#412).
function Wait-ProcessWithDeadline {
  param([object]$Process, [datetime]$Deadline, [string]$Message)
  $frames = @([char]0x2807, [char]0x2819, [char]0x2839, [char]0x2838, [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827, [char]0x2847, [char]0x280F)
  $f = 0
  Write-Host -NoNewline "  "
  while (-not $Process.HasExited) {
    if ((Get-Date) -gt $Deadline) {
      try { $Process.Kill() } catch {}
      Write-Host "`r                                                   `r" -NoNewline
      return $false
    }
    Write-Host "`r  " -NoNewline
    Write-Host $frames[$f] -ForegroundColor Cyan -NoNewline
    Write-Host " $Message" -NoNewline
    $f = ($f + 1) % $frames.Count
    Start-Sleep -Seconds 2
  }
  Write-Host "`r                                                   `r" -NoNewline
  return $true
}

# Background jobs spawn their runspace in the user's HOME directory. On managed
# machines (roaming profiles) HOME is often a UNC share (\\fileserver\home\user);
# every cmd.exe a job starts there prints "CMD.EXE was started with the above
# path as the current directory. UNC paths are not supported." and its stderr
# surfaces as a red RemoteException error record — alarming noise on a healthy
# install (#409). Every Start-Job below passes this as -InitializationScript to
# pin the job to a local working directory before it runs anything. (SystemRoot
# is always local; the guard makes it a no-op on non-Windows Pester runs.)
$script:JobInit = { if ($env:SystemRoot) { Set-Location $env:SystemRoot } }

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

# Best-effort chart version of the installed client release (e.g. "1.4.4");
# empty if not found / cluster unreachable. Greps helm's CHART column.
function Get-ChartVersion {
  param([string]$Namespace = "tracebloc")
  $out = (helm list -n $Namespace 2>$null) | Out-String
  if ($out -match 'client-([0-9][^\s]*)') { return $Matches[1] }
  return ""
}

# =============================================================================
#  CONFIGURATION
# =============================================================================

$CLUSTER_NAME  = if ($env:CLUSTER_NAME)  { $env:CLUSTER_NAME }  else { "tracebloc" }
$SERVERS       = if ($env:SERVERS)       { $env:SERVERS }       else { "1" }
$AGENTS        = if ($env:AGENTS)        { $env:AGENTS }        else { "1" }
$K8S_VERSION   = if ($env:K8S_VERSION)   { $env:K8S_VERSION }   else { "v1.29.4-k3s1" }
$HOST_DATA_DIR = if ($env:HOST_DATA_DIR) { $env:HOST_DATA_DIR } else { "$env:USERPROFILE\.tracebloc" }
# backend#743: optional separate dir for the big dataset volume. Empty (default)
# keeps datasets under HOST_DATA_DIR. When set, it is bind-mounted at
# /tracebloc-data and the chart's dataset PV points there (mysql + logs stay
# local). The host-uid ingestion mechanism for root_squash NFS is Linux-only; on
# Windows k3d runs in a Linux VM where Docker Desktop handles mount ownership.
$HOST_DATASET_DIR = if ($env:HOST_DATASET_DIR) { $env:HOST_DATASET_DIR } else { "" }
$CLIENT_ENV    = $env:CLIENT_ENV

$GPU_VENDOR       = "none"
$NVIDIA_DRIVER_OK = $false
$K3D_GPU_FLAG     = ""
$ReadyTimeout     = if ($env:READY_TIMEOUT) { $env:READY_TIMEOUT } else { "300" }
$script:ClientState = "starting"

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

Reinstalling on a machine that still holds data:
  A new install won't silently adopt data left under HOST_DATA_DIR (both the
  flat and per-release layouts) — it stops and asks reuse / wipe / different dir.
  Non-interactive: TB_LEFTOVER_ACTION=reuse|wipe, or HOST_DATA_DIR=<new-path>
  (with no choice and no terminal the install aborts). Bypass entirely with
  TRACEBLOC_SKIP_LEFTOVER_GUARD=1.

macOS / Linux:
  curl -fsSL https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.sh | bash

Learn more: https://docs.tracebloc.io

"@
  exit 0
}

# =============================================================================
#  INPUT VALIDATION
# =============================================================================

# Resolve + validate HOST_DATA_DIR: it must be under USERPROFILE and never a
# system path. Sets $script:HOST_DATA_DIR to the resolved absolute path. Shared
# by Confirm-Config and the leftover-data guard's "install into a different
# directory" path so the two can't drift.
function Confirm-DataDir {
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

function Confirm-Config {
  if ($CLUSTER_NAME -notmatch '^[a-zA-Z][a-zA-Z0-9._-]{0,62}$') {
    Err ("CLUSTER_NAME must start with a letter, contain only [a-zA-Z0-9._-], max 63 chars (got '" + $CLUSTER_NAME + "')")
  }
  if ($SERVERS -notmatch '^[1-9]\d*$') { Err ("SERVERS must be a positive integer >= 1 (got '" + $SERVERS + "')") }
  if ($AGENTS  -notmatch '^\d+$') { Err ("AGENTS must be a non-negative integer (got '" + $AGENTS + "')") }
  Confirm-DataDir   # resolve + validate HOST_DATA_DIR (shared with the leftover-data guard's new-dir path)

  # backend#743: optional dataset dir. Unlike HOST_DATA_DIR it MAY live outside
  # USERPROFILE (a separate / network drive). It must already EXIST and be
  # writable; we never create a network-share root. System paths stay barred.
  if ($HOST_DATASET_DIR) {
    $dsDir = [System.IO.Path]::GetFullPath($HOST_DATASET_DIR)
    if (-not (Test-Path $dsDir -PathType Container)) {
      Err ("HOST_DATASET_DIR does not exist: " + $HOST_DATASET_DIR + " (mount the dataset volume before installing)")
    }
    try {
      $probe = Join-Path $dsDir (".tb-write-" + [guid]::NewGuid().ToString("N"))
      New-Item -ItemType File -Path $probe -ErrorAction Stop | Out-Null
      Remove-Item $probe -Force -ErrorAction SilentlyContinue
    } catch {
      Err ("HOST_DATASET_DIR is not writable: " + $HOST_DATASET_DIR)
    }
    foreach ($f in $forbidden) {
      if ($f -and $dsDir.StartsWith([System.IO.Path]::GetFullPath($f), [StringComparison]::OrdinalIgnoreCase)) {
        Err ("HOST_DATASET_DIR cannot be a system path: " + $HOST_DATASET_DIR)
      }
    }
    $script:HOST_DATASET_DIR = $dsDir
  }
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
  Hint "3. Install the tracebloc CLI"
  Hint "4. Register this machine"
  Hint "5. Install tracebloc client"
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
      # Expectation-setting only, never a gate (#387): entry-level cards pass
      # every check but are too small for real training (field: a 2 GB GT 710
      # installed fine and could never fit a model).
      try {
        $vramMiB = [int]((& $nvSmi --query-gpu=memory.total --format=csv,noheader,nounits 2>&1 | Select-Object -First 1).Trim())
        if ($vramMiB -gt 0 -and $vramMiB -lt 8192) {
          Hint "This GPU has $([math]::Round($vramMiB / 1024, 1)) GB VRAM - fine for setup; real training typically needs 8 GB+."
        }
      } catch {}
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
  $wslJob = Start-Job -InitializationScript $JobInit -ScriptBlock { cmd /c "wsl --update 2>&1" }
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

  $wslSetJob = Start-Job -InitializationScript $JobInit -ScriptBlock { cmd /c "wsl --set-default-version 2 2>&1" }
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
      Hint "3. If Docker shows an error window instead (e.g. 'Virtualization support not detected' or a WSL update prompt), fix that first - it may need a reboot"
      Hint "4. Re-run this script once it's ready"
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

  $wslListJob = Start-Job -InitializationScript $JobInit -ScriptBlock {
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
# --tlsv1.2 --connect-timeout/--max-time inline: this runs inside WSL2, where
# common.sh's curl_secure() isn't available, so the floor and the bounds are spelled
# out the same way the bootstrap (install.sh) spells them out (backend#1252).
curl -fsSL --tlsv1.2 --connect-timeout 30 --max-time 30 https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null
curl -fsSL --tlsv1.2 --connect-timeout 30 --max-time 30 https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
sudo apt-get update -qq
# needrestart on WSL Ubuntu would open a hidden prompt in this captured job and
# stall to the 180s timeout; DEBIAN_FRONTEND/NEEDRESTART_MODE keep apt non-interactive.
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -q nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker --set-as-default 2>/dev/null || true
sudo nvidia-ctk runtime configure --runtime=containerd 2>/dev/null || true
echo "NCT installed successfully."
'@

  $scriptPath = [System.IO.Path]::Combine($env:TEMP, "install-nct-$(Get-Random -Maximum 999999).sh")
  [System.IO.File]::WriteAllText($scriptPath, $nctScript.Replace("`r`n", "`n"))
  # Build the WSL path WITHOUT a scriptblock -replace: scriptblock substitution in
  # the -replace operator is PowerShell 6.1+, but the bootstrap (install.ps1) runs
  # this via powershell.exe (Windows PowerShell 5.1, per #Requires -Version 5.1),
  # where the scriptblock is coerced to its literal text and the drive letter is
  # NOT lowercased -> a malformed $wslPath and a 180s NCT-install timeout. -match
  # / $Matches is 5.1-safe.
  $fwd = $scriptPath -replace '\\','/'
  if ($fwd -match '^([A-Za-z]):/(.*)$') {
    $wslPath = "/mnt/" + $Matches[1].ToLower() + '/' + $Matches[2]
  } else {
    $wslPath = "/mnt/" + $fwd
  }

  $nctInstallJob = Start-Job -InitializationScript $JobInit -ScriptBlock {
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

  $verJob = Start-Job -InitializationScript $JobInit -ScriptBlock {
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

# ── Pinned tool versions (#382 / #410) ──────────────────────────────────────
# Defaults MUST stay in lockstep with scripts/lib/common.sh (K3D_VERSION /
# HELM_VERSION) until the shared facts spec (#435) single-sources them. Pinned
# defaults keep installs deterministic and immune to GitHub's unauthenticated
# releases/latest API, whose 60 req/hour/IP limit a single shared corporate NAT
# exhausts. Only the literal value "latest" resolves at install time — via the
# plain /releases/latest redirect or get.helm.sh, never api.github.com.
$script:K3dVersion  = if ($env:K3D_VERSION)  { $env:K3D_VERSION }  else { "v5.9.0" }
$script:HelmVersion = if ($env:HELM_VERSION) { $env:HELM_VERSION } else { "v4.2.3" }

# A tag is interpolated into a download URL — refuse separators and parent-dir
# tokens (path-traversal lever) and require a release shape. Mirrors the
# bootstrap's ref gate and cli install.sh's validate_version_tag.
function Test-ReleaseTagShape {
  param([string]$Tag)
  if (-not $Tag -or $Tag -match '/' -or $Tag -match '\.\.') { return $false }
  return [bool]($Tag -match '^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$')
}

# Resolve "latest" for a GitHub project WITHOUT the rate-limited API: read the
# tag from the /releases/latest redirect's Location header (same trick as
# cli/scripts/install.ps1 and lib/setup-linux.sh).
function Get-LatestGitHubTag {
  param([string]$Repo)
  $loc = $null
  try {
    $resp = Invoke-WebRequest -Uri "https://github.com/$Repo/releases/latest" `
      -Method Head -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
    $loc = $resp.Headers['Location']
  } catch {
    # Windows PowerShell 5.1 throws on a 3xx when redirects are disabled; the
    # response object still carries the Location header we want.
    $resp = $_.Exception.Response
    if ($resp) {
      try { $loc = $resp.Headers['Location'] } catch {}
      if (-not $loc) { try { $loc = $resp.Headers.Location } catch {} }
    }
  }
  if (-not $loc) { return $null }
  return ("$loc" -split '/')[-1]
}

# The version a tool install uses: the pinned default (or the operator's env
# override) validated for release shape; the literal "latest" resolves via the
# API-free path above. Aborts rather than building a URL from a bad value.
function Resolve-ToolVersion {
  param([string]$Name, [string]$Value, [scriptblock]$LatestResolver)
  $v = $Value
  if ($v -eq "latest") {
    $v = & $LatestResolver
    if (-not $v) { Err "Couldn't resolve the latest $Name release. Set $($Name.ToUpper())_VERSION to a release tag and re-run." }
  }
  if (-not (Test-ReleaseTagShape $v)) {
    Err "$($Name.ToUpper())_VERSION '$v' is not a release tag (expected vX.Y.Z) - refusing to build a download URL from it."
  }
  return $v
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
      # Pinned by default (#382 / #410) — no api.github.com on the default path.
      $k3dVer = Resolve-ToolVersion -Name "k3d" -Value $K3dVersion `
        -LatestResolver { Get-LatestGitHubTag -Repo "k3d-io/k3d" }
      $k3dDest = "$TOOL_DIR\k3d.exe"
      Invoke-WithRetry -Label "k3d download" -ScriptBlock {
        Invoke-WebRequest "https://github.com/k3d-io/k3d/releases/download/$k3dVer/k3d-windows-$arch.exe" `
          -OutFile $k3dDest -UseBasicParsing
      }
      # Fail-closed verification, matching the Linux path and the kubectl
      # precedent: an unfetchable checksums.txt, a missing asset line, or a
      # mismatch all abort and remove the download — never install unverified
      # bytes on a privileged path (Bugbot r3). The release's checksum asset is
      # named checksums.txt ("<sha256>  _dist/<asset>" lines); the previous
      # sha256sum.txt URL never existed, so the old fail-open verification
      # silently never ran (#382).
      try {
        $checksums = Invoke-WithRetry -Label "k3d checksums" -ScriptBlock {
          (Invoke-WebRequest "https://github.com/k3d-io/k3d/releases/download/$k3dVer/checksums.txt" `
            -UseBasicParsing).Content
        }
      } catch {
        Remove-Item $k3dDest -Force -ErrorAction SilentlyContinue
        Err "Couldn't fetch the k3d checksums ($_). Check egress to github.com and re-run."
      }
      $expectedHash = (($checksums -split "`n" |
        Where-Object { $_ -match "k3d-windows-$arch\.exe" }) -replace '\s+.*','' |
        Select-Object -First 1)
      if (-not $expectedHash) {
        Remove-Item $k3dDest -Force -ErrorAction SilentlyContinue
        Err "System tool checksum verification failed."
      }
      $actualHash = (Get-FileHash $k3dDest -Algorithm SHA256).Hash.ToLower()
      if ($actualHash -ne $expectedHash.Trim().ToLower()) {
        Remove-Item $k3dDest -Force
        Err "System tool checksum verification failed."
      }
      Log "k3d checksum verified."
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
      # Pinned by default (#410); "latest" resolves via get.helm.sh (no API),
      # mirroring lib/setup-linux.sh.
      $helmVer = Resolve-ToolVersion -Name "helm" -Value $HelmVersion -LatestResolver {
        try { (Invoke-WebRequest "https://get.helm.sh/helm-latest-version" -UseBasicParsing).Content.Trim() } catch { $null }
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

# --- Corporate-proxy support (mirrors scripts/lib/cluster.sh) ----------------
# Cluster-internal destinations that must never be routed through a corporate
# proxy: loopback, all RFC1918 private ranges (the k3s pod CIDR 10.42.0.0/16,
# service CIDR 10.43.0.0/16, the k3d docker network and node IPs), and the
# in-cluster DNS suffixes. Echoes host NO_PROXY/no_proxy unioned with these
# defaults, de-duplicated with host entries first.
function Get-EffectiveNoProxy {
  $defaults = @('localhost','127.0.0.1','0.0.0.0','169.254.169.254','10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','.svc','.svc.cluster.local','.cluster.local','host.k3d.internal')
  $existing = if ($env:NO_PROXY) { $env:NO_PROXY } elseif ($env:no_proxy) { $env:no_proxy } else { '' }
  $seen = @{}
  $out  = New-Object System.Collections.Generic.List[string]
  foreach ($tok in (($existing -split ',') + $defaults)) {
    $t = $tok.Trim()
    if ($t -ne '' -and -not $seen.ContainsKey($t)) { $seen[$t] = $true; $out.Add($t) }
  }
  return ($out -join ',')
}

# Build a k3d config file carrying proxy env as structured YAML entries and
# return its path ($null when no HTTP(S) proxy is set). We use --config rather
# than --env KEY=VALUE@FILTER because k3d splits the --env flag on '@', which
# corrupts authenticated-proxy URLs (http://user:pass@host); the YAML env list
# preserves them. NO_PROXY is always emitted (auto-augmented) so in-cluster
# traffic bypasses the proxy. Written UTF-8 without BOM (Windows PowerShell 5.1
# would otherwise prepend a BOM that breaks the YAML parser). Caller removes the
# parent temp dir.
function Write-K3dProxyConfig {
  $haveHttp = $env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:http_proxy -or $env:https_proxy
  if (-not $haveHttp) { return $null }

  $noProxy = Get-EffectiveNoProxy
  $tmpDir  = Join-Path ([System.IO.Path]::GetTempPath()) ("tracebloc-k3d-" + [System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
  $cfg = Join-Path $tmpDir "config.yaml"

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('apiVersion: k3d.io/v1alpha5')
  $lines.Add('kind: Simple')
  $lines.Add('env:')
  foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy')) {
    $val = [Environment]::GetEnvironmentVariable($name)
    if ($val) {
      $lines.Add('  - envVar: "' + $name + '=' + $val + '"')
      $lines.Add('    nodeFilters:')
      $lines.Add('      - all')
    }
  }
  foreach ($name in @('NO_PROXY','no_proxy')) {
    $lines.Add('  - envVar: "' + $name + '=' + $noProxy + '"')
    $lines.Add('    nodeFilters:')
    $lines.Add('      - all')
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($cfg, $lines, $utf8NoBom)
  return $cfg
}

# Guarantee the cluster returns after a reboot: ensure the k3d node containers
# restart when Docker starts. k3d already sets unless-stopped; this is defensive
# and also covers externally-created clusters. On Windows the remaining piece is
# Docker Desktop starting on login, which the summary tells the user to enable.
# Opt out with TRACEBLOC_NO_AUTOSTART=1.
function Set-ClusterAutostart {
  if ($env:TRACEBLOC_NO_AUTOSTART) { return }
  try {
    $nodes = docker ps -a --filter "name=k3d-$CLUSTER_NAME-" --format "{{.Names}}" 2>$null
    foreach ($n in $nodes) {
      if ($n) { docker update --restart unless-stopped $n 2>&1 | Out-Null }
    }
    if ($nodes) { Log "Set restart=unless-stopped on k3d nodes (auto-restart after reboot)." }
  } catch {}
}

# =============================================================================
#  LEFTOVER-DATA GUARD (RFC-0003 §4 / #376) — Windows parity with the bash
#  guard_leftover_data (scripts/lib/cluster.sh). A NEW install must never
#  silently adopt data an earlier install left under HOST_DATA_DIR. Windows is
#  hostpath-only (New-K3dCluster always bind-mounts HOST_DATA_DIR -> /tracebloc);
#  node-local (RFC-0003 Option C) is a Linux/k3s prototype with no Windows path,
#  so this is intentionally scoped to hostpath. Non-interactive knobs mirror the
#  bash env contract: $env:TB_LEFTOVER_ACTION (reuse|wipe), $env:HOST_DATA_DIR
#  (a different dir), $env:TRACEBLOC_SKIP_LEFTOVER_GUARD (bypass).
# =============================================================================

# Can we prompt? False under CI / piped / redirected stdin — where the guard must
# fail safe (abort) rather than hang or silently adopt.
function Test-CanPrompt {
  try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) }
  catch { return $false }
}

# Directories under HOST_DATA_DIR that hold real client data — a MySQL data dir
# or a dataset dir with at least one file — across BOTH on-disk layouts: flat
# (HOST_DATA_DIR\{mysql,data}) and per-release (HOST_DATA_DIR\<rel>\{mysql,data}).
# Empty dirs, values.yaml and install-*.log are not data. Reparse points
# (symlinks/junctions) are skipped so a later wipe can't traverse outside
# HOST_DATA_DIR. An unreadable dir can't be proven empty, so it is treated as a
# leftover (fail closed). Mirrors bash _leftover_data_dirs.
function Get-LeftoverDataDirs {
  param([string]$Base = $HOST_DATA_DIR)
  $out = @()
  if (-not $Base -or -not (Test-Path -LiteralPath $Base -PathType Container)) { return $out }
  $candidates = New-Object System.Collections.Generic.List[string]
  $candidates.Add((Join-Path $Base "mysql")); $candidates.Add((Join-Path $Base "data"))
  Get-ChildItem -LiteralPath $Base -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }   # skip symlink/junction
    if ($_.Name -eq "mysql" -or $_.Name -eq "data") { return }             # flat dirs already candidates
    $candidates.Add((Join-Path $_.FullName "mysql")); $candidates.Add((Join-Path $_.FullName "data"))
  }
  foreach ($d in $candidates) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
    $item = Get-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }  # never a data dir
    $hasFile = $false
    try {
      $f = Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction Stop | Select-Object -First 1
      $hasFile = [bool]$f
    } catch { $hasFile = $true }   # unlistable/unreadable -> can't prove empty -> leftover
    if ($hasFile) { $out += $d }
  }
  return $out
}

# Delete the detected leftover dirs. Only ever removes paths UNDER the validated
# HOST_DATA_DIR (Confirm-DataDir guarantees it is under USERPROFILE). Returns
# $true only if everything was removed, so the caller can fail closed on survivors
# (e.g. locked files) instead of adopting them. Mirrors bash _wipe_leftover_data.
# Recursively delete $Path the way bash `rm -rf` does — WITHOUT ever following a
# reparse point (junction/symlink) nested anywhere in the tree. Windows
# PowerShell 5.1's `Remove-Item -Recurse` descends INTO nested junctions and can
# delete their targets OUTSIDE the validated tree (Bugbot r3655703571); bash
# unlinks them instead. We walk depth-first: a reparse-point entry is unlinked
# (Directory.Delete(path,$false) for a dir link, File.Delete for a file link) and
# never descended; a real directory has its children removed first, then itself;
# plain files are deleted. Returns $true only when $Path is fully gone. Behaves
# identically on PS 5.1 and 7+ (no reliance on -Recurse's version-specific quirk).
function Remove-TreeNoFollow {
  param([string]$Path)
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $item) { return (-not (Test-Path -LiteralPath $Path)) }
  $isReparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
  if ($item.PSIsContainer -and -not $isReparse) {
    $ok = $true
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
      if (-not (Remove-TreeNoFollow -Path $child.FullName)) { $ok = $false }
    }
    try { [System.IO.Directory]::Delete($Path, $false) } catch { $ok = $false }
    return ($ok -and -not (Test-Path -LiteralPath $Path))
  }
  # Reparse point (dir junction / file symlink) or a plain file: unlink the entry
  # itself — for a directory reparse point Directory.Delete(...,$false) removes the
  # link without touching the target.
  try {
    if ($item.PSIsContainer) { [System.IO.Directory]::Delete($Path, $false) }
    else { [System.IO.File]::Delete($Path) }
  } catch {
    try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } catch {}
  }
  return (-not (Test-Path -LiteralPath $Path))
}

function Remove-LeftoverData {
  param([string[]]$Dirs)
  $base = [System.IO.Path]::GetFullPath($HOST_DATA_DIR)
  $userProfile = [System.IO.Path]::GetFullPath($env:USERPROFILE)
  if (-not $HOST_DATA_DIR -or -not $base.StartsWith($userProfile, [StringComparison]::OrdinalIgnoreCase)) {
    Err ("Refusing to wipe: HOST_DATA_DIR is unset or not under USERPROFILE (got: " + $HOST_DATA_DIR + ")")
  }
  $prefix = $base.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  $ok = $true
  foreach ($d in $Dirs) {
    $full = [System.IO.Path]::GetFullPath($d)
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
      Warn "Refusing to wipe $d - outside $HOST_DATA_DIR."; $ok = $false; continue
    }
    $item = Get-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      Warn "Refusing to wipe reparse point $d - it could point outside $HOST_DATA_DIR; remove it by hand."; $ok = $false; continue
    }
    Log "Wiping leftover data: $d"
    if (-not (Remove-TreeNoFollow -Path $d)) {
      Warn "Could not fully remove $d - files may be locked, owned by another user, or a nested reparse point was refused."; $ok = $false
    }
  }
  return $ok
}

# Guard entry point — called from New-K3dCluster ONLY when creating a NEW cluster
# (an existing cluster is an in-place reuse/upgrade whose data stays by design).
# Resolves an action from $env:TB_LEFTOVER_ACTION, else an interactive prompt;
# with no terminal and no explicit action it fails safe (abort, never adopt).
function Invoke-LeftoverDataGuard {
  if ($env:TRACEBLOC_SKIP_LEFTOVER_GUARD) { return }
  $found = @(Get-LeftoverDataDirs)
  if ($found.Count -eq 0) { return }   # clean slate — nothing to guard

  Warn "Existing tracebloc data found under ${HOST_DATA_DIR}:"
  foreach ($d in $found) { Hint "  * $d" }
  Hint "A fresh install would silently adopt it, so it would not really be fresh."

  $action = ""
  switch ("$($env:TB_LEFTOVER_ACTION)".Trim().ToLower()) {
    "reuse" { $action = "reuse" }
    "wipe"  { $action = "wipe" }
  }
  if (-not $action) {
    if (Test-CanPrompt) {
      Write-Host ""
      Hint "How should the installer handle it?"
      Hint "  [r] reuse - keep and adopt the existing data"
      Hint "  [w] wipe  - delete it and start fresh"
      Hint "  [n] new   - install into a different directory"
      Hint "  [a] abort - stop and sort it out myself (default)"
      $reply = ""
      try { $reply = (Read-Host "  Choice [r/w/n/a]") } catch { $reply = "" }
      switch ("$reply".Trim().ToLower()) {
        { $_ -in @("r","reuse") } { $action = "reuse" }
        { $_ -in @("w","wipe") }  { $action = "wipe" }
        { $_ -in @("n","new") }   { $action = "newdir" }
        default                   { $action = "abort" }
      }
    } else {
      Err ("Existing data found under $HOST_DATA_DIR and no choice was given (no terminal). Re-run with one of:`n" +
           "  `$env:TB_LEFTOVER_ACTION='reuse'   adopt the existing data`n" +
           "  `$env:TB_LEFTOVER_ACTION='wipe'    delete it and start fresh`n" +
           "  `$env:HOST_DATA_DIR='<new-path>'   install into a different directory`n" +
           "  (or `$env:TRACEBLOC_SKIP_LEFTOVER_GUARD='1' to bypass this guard entirely)")
    }
  }

  switch ($action) {
    "reuse" { Log "Reusing existing data under $HOST_DATA_DIR (user choice)." }
    "wipe"  {
      if (-not (Remove-LeftoverData -Dirs $found)) {
        Err "Could not fully wipe existing data under $HOST_DATA_DIR - some files could not be removed (locked, or owned by another user). Remove them manually and re-run, or choose a different directory. Refusing to proceed and adopt the leftovers."
      }
      Log "Wiped leftover data under $HOST_DATA_DIR (user choice)."
    }
    "newdir" {
      $newdir = ""
      if (Test-CanPrompt) { try { $newdir = (Read-Host "  New data directory (under $env:USERPROFILE)") } catch { $newdir = "" } }
      if (-not "$newdir".Trim()) { Err "No new directory given - aborting." }
      $script:HOST_DATA_DIR = "$newdir".Trim()
      Confirm-DataDir   # re-resolve + re-validate the new path
      Log "Switched HOST_DATA_DIR to $HOST_DATA_DIR; re-checking it for leftover data."
      Invoke-LeftoverDataGuard
    }
    default { Err "Aborted - existing data under $HOST_DATA_DIR left untouched. Choose reuse / wipe / a different directory and re-run." }
  }
}

function New-K3dCluster {
  Log "Creating k3d cluster: '$CLUSTER_NAME'"

  # Docker is up now (unlike at preflight); re-check the runtime's real memory budget.
  Test-PreflightRuntimeMem

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

    # Gap C parity: an externally-created cluster may bind its API to 0.0.0.0;
    # warn (the kubeconfig rewrite below still normalizes it to 127.0.0.1, so
    # reuse works). Silent if the serverlb can't be inspected.
    try {
      $binds = (docker inspect "k3d-$CLUSTER_NAME-serverlb" --format '{{range $p, $c := .NetworkSettings.Ports}}{{range $c}}{{.HostIp}} {{end}}{{end}}' 2>$null | Out-String)
      if ($binds -match '0\.0\.0\.0' -and $binds -notmatch '127\.0\.0\.1') {
        Warn "The existing '$CLUSTER_NAME' cluster binds its API to 0.0.0.0 (created outside this installer)."
        Hint "This installer binds clusters to 127.0.0.1; behind a corporate proxy a 0.0.0.0 bind can be intercepted."
        Hint "Your kubeconfig is normalized to 127.0.0.1 so reuse works. If kubectl is still intercepted, rebuild it:"
        Hint "  k3d cluster delete $CLUSTER_NAME  (then re-run this installer)."
      }
    } catch {}

    # backend#743: the dataset bind mount (HOST_DATASET_DIR -> /tracebloc-data)
    # is baked into the k3d nodes at create time; k3d can't add it to a running
    # cluster. Re-using an existing cluster without it would point the chart's
    # datasetPath PV at ephemeral in-node storage (datasets lost on a restart)
    # instead of the network export. Fail fast with the recreate remedy.
    if ($HOST_DATASET_DIR) {
      $dsMounts = ""
      try { $dsMounts = (docker inspect "k3d-$CLUSTER_NAME-server-0" --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>$null | Out-String) } catch {}
      if ($dsMounts -and ($dsMounts -notmatch '(?m)^/tracebloc-data\s*$')) {
        Warn "HOST_DATASET_DIR is set, but the existing '$CLUSTER_NAME' cluster has no /tracebloc-data bind mount."
        Hint "k3d bakes bind mounts in at create time - they can't be added to a running cluster. Re-using this"
        Hint "cluster would put datasets on ephemeral in-node storage (lost on a restart), not your network export."
        Hint "Recreate the cluster so the dataset volume is bound (data under HOST_DATASET_DIR is untouched):"
        Hint "  k3d cluster delete $CLUSTER_NAME   (then re-run this installer)."
        Err "Existing cluster is missing the dataset bind mount - refusing to install datasets onto ephemeral storage."
      }
    }
  } else {
    # Creating a FRESH cluster — never silently adopt data an earlier install
    # left under HOST_DATA_DIR (RFC-0003 §4 / #376; parity with the bash guard).
    # May prompt and/or update $script:HOST_DATA_DIR (new-dir choice) before we
    # bind-mount it below, or abort on wipe-failed / no-choice-no-terminal.
    Invoke-LeftoverDataGuard

    if (-not (Test-Path $HOST_DATA_DIR)) {
      New-Item -ItemType Directory -Path $HOST_DATA_DIR -Force | Out-Null
    }

    # The tracebloc client is outbound-only: jobs-manager + pods-monitor dial
    # out to the platform, and the only in-cluster Service (mysql-client) is
    # ClusterIP. Disable k3s components that exist solely to handle inbound
    # traffic or duplicate chart-provided resources.
    $k3dArgs = @(
      "cluster", "create", $CLUSTER_NAME,
      "--servers", $SERVERS,
      "--agents",  $AGENTS,
      "--api-port","127.0.0.1:6550",
      "-v",        "${HOST_DATA_DIR}:/tracebloc@all",
      "--k3s-arg", "--disable=traefik@server:*",
      "--k3s-arg", "--disable=servicelb@server:*",
      "--k3s-arg", "--disable=local-storage@server:*",
      "--wait"
    )

    # backend#743: bind-mount the customer dataset volume at a distinct cluster
    # path so the chart's dataset PV points there while mysql + logs stay on the
    # local /tracebloc tree. No-op when unset.
    if ($HOST_DATASET_DIR) { $k3dArgs += @("-v", "${HOST_DATASET_DIR}:/tracebloc-data@all") }

    if ($K8S_VERSION -ne "" -and $K8S_VERSION -ne "latest") { $k3dArgs += @("--image", "rancher/k3s:$K8S_VERSION") }
    if ($K3D_GPU_FLAG -ne "") {
      $k3dArgs += $K3D_GPU_FLAG
      Log "GPU flag active: $K3D_GPU_FLAG"
    }

    # Corporate-proxy propagation (mirrors scripts/lib/cluster.sh): pass proxy
    # env via a k3d --config file so authenticated proxies survive and NO_PROXY
    # is auto-augmented with the cluster-internal ranges (prevents in-cluster
    # misroute + the create-time --wait hang).
    $proxyCfg = Write-K3dProxyConfig
    if ($proxyCfg) {
      $k3dArgs += @("--config", $proxyCfg)
      Log "Propagating proxy settings to k3d nodes (authenticated proxies supported; NO_PROXY auto-augmented)."
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

    # -ErrorAction Stop + catch: a failed spawn (broken/invalid k3d.exe) used
    # to leave $k3dProc null, and `while (-not $null.HasExited)` spun the
    # spinner forever over a dead install (#412). Fail fast instead.
    $k3dProc = $null
    try {
      $k3dProc = Start-Process -FilePath $k3dExe -ArgumentList $k3dArgString `
        -NoNewWindow -PassThru -ErrorAction Stop `
        -RedirectStandardOutput $k3dOutLog `
        -RedirectStandardError $k3dErrLog
    } catch {
      Remove-Item $k3dOutLog, $k3dErrLog -Force -ErrorAction SilentlyContinue
      if ($proxyCfg) { Remove-Item (Split-Path $proxyCfg -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
      if ($script:LOG_FILE) { Hint "Full log: $LOG_FILE" }
      Err "Couldn't start k3d ($k3dExe): $($_.Exception.Message). Reinstall it (re-run this script) or check that the binary runs: k3d version"
    }

    $timeoutMin = 15
    if ("$env:TB_CREATE_TIMEOUT_MIN" -match '^\d+$') { $timeoutMin = [int]$env:TB_CREATE_TIMEOUT_MIN }
    if (-not (Wait-ProcessWithDeadline -Process $k3dProc -Deadline (Get-Date).AddMinutes($timeoutMin) -Message "Creating compute environment...")) {
      $tail = @()
      if (Test-Path $k3dErrLog) { $tail = @(Get-Content $k3dErrLog -ErrorAction SilentlyContinue | Select-Object -Last 5) }
      if (-not $tail -and (Test-Path $k3dOutLog)) { $tail = @(Get-Content $k3dOutLog -ErrorAction SilentlyContinue | Select-Object -Last 5) }
      foreach ($line in $tail) { Warn "k3d: $line" }
      if ($script:LOG_FILE) { Hint "Full log: $LOG_FILE" }
      Remove-Item $k3dOutLog, $k3dErrLog -Force -ErrorAction SilentlyContinue
      if ($proxyCfg) { Remove-Item (Split-Path $proxyCfg -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
      Err "Compute environment creation timed out after $timeoutMin minutes. Check that Docker is healthy and this network can pull images, then re-run. (TB_CREATE_TIMEOUT_MIN overrides the bound.)"
    }

    $k3dExitCode = $k3dProc.ExitCode
    $k3dStdout = if (Test-Path $k3dOutLog) { Get-Content $k3dOutLog -Raw -ErrorAction SilentlyContinue } else { "" }
    $k3dStderr = if (Test-Path $k3dErrLog) { Get-Content $k3dErrLog -Raw -ErrorAction SilentlyContinue } else { "" }
    Remove-Item $k3dOutLog, $k3dErrLog -Force -ErrorAction SilentlyContinue
    if ($proxyCfg) { Remove-Item (Split-Path $proxyCfg -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    if ($k3dStdout) { Log "k3d stdout: $k3dStdout" }
    if ($k3dStderr) { Log "k3d stderr: $k3dStderr" }

    if ($k3dExitCode -ne 0) { Err "Failed to create compute environment." }
    Ok "Compute environment ready."
  }

  k3d kubeconfig merge $CLUSTER_NAME --kubeconfig-switch-context | Out-Null

  $kubeConfigPath = "$env:USERPROFILE\.kube\config"
  if (Test-Path $kubeConfigPath) {
    (Get-Content $kubeConfigPath) `
      -replace 'host\.docker\.internal', '127.0.0.1' `
      -replace 'https://0\.0\.0\.0:', 'https://127.0.0.1:' | Set-Content $kubeConfigPath -Encoding UTF8
  }

  # Ensure THIS installer's own kubectl bypasses the proxy for the cluster API
  # (127.0.0.1) + in-cluster ranges (mirrors cluster.sh::_export_host_no_proxy).
  if ($env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:http_proxy -or $env:https_proxy) {
    $env:NO_PROXY = Get-EffectiveNoProxy
    $env:no_proxy = $env:NO_PROXY
  }

  Log "kubeconfig updated -- kubectl now points to '$CLUSTER_NAME'."

  Set-ClusterAutostart
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

# ── Training-size default (backend#1236, option A; mirrors install-client-helm.sh) ──
# One knob, requests == limits (Guaranteed QoS). The old static "cpu=2,memory=8Gi"
# was wrong at both ends: dead on arrival on nodes under 8 GiB (the WSL2 field
# case — nothing could ever schedule) and ~12% of a 64 GiB box. Precedence:
#   1. TRACEBLOC_TRAINING_RESOURCES (explicit install-time override)
#   2. the installed release's current value (a `tracebloc resources set` choice
#      must survive re-install, never be clobbered back to a default)
#   3. sized to this machine: LARGEST node allocatable - ~1 CPU / 3 GiB platform
#      overhead (a pod schedules onto ONE node; k3d's server+agent are the same
#      machine, so summing would double-count)
#   4. the historic static default (tiny or undeterminable machines)
function Get-TrainingResources {
  if ($env:TRACEBLOC_TRAINING_RESOURCES) { return $env:TRACEBLOC_TRAINING_RESOURCES }
  try {
    # helm get has no request timeout — gate it behind a bounded probe so a
    # wedged API degrades instead of hanging values generation (Bugbot). A
    # missing namespace also means there is no release to carry.
    $null = (kubectl get namespace $TB_NAMESPACE --request-timeout=5s 2>$null) | Out-String
    if ($LASTEXITCODE -eq 0) {
      $valsJson = (helm get values $TB_NAMESPACE -n $TB_NAMESPACE -o json 2>$null) | Out-String
      if ($LASTEXITCODE -eq 0 -and $valsJson.Trim()) {
        $prev = ($valsJson | ConvertFrom-Json).env.RESOURCE_LIMITS
        # The historic static default was the ABSENCE of a choice — carrying it
        # would keep the unschedulable 8Gi on exactly the machines this sizing
        # exists to fix (Bugbot). Only a differing value survives re-install.
        if ($prev -and $prev -ne "cpu=2,memory=8Gi") { return $prev }
      }
    }
  } catch {}
  try {
    # Bounded: a wedged API server must degrade to the static default, never
    # hang values generation (Bugbot). jsonpath extracts ONLY cpu/memory — no
    # full-JSON ConvertFrom-Json, mirroring the bash twin, so a parse hiccup on
    # unrelated node fields can never silently reinstate the static default
    # (Bugbot r5).
    $lines = kubectl get nodes --request-timeout=10s -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{" "}{.status.allocatable.memory}{"\n"}{end}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $lines) {
      $bestMemB = [long]0; $bestCpuM = [long]0
      foreach ($ln in @($lines)) {
        $parts = "$ln".Trim() -split '\s+'
        if ($parts.Count -lt 2) { continue }
        $cpuRaw = $parts[0]
        $memRaw = $parts[1]
        $cpuM = if ($cpuRaw -match '^(\d+)m$') { [long]$Matches[1] }
                elseif ($cpuRaw -match '^\d+$') { [long]$cpuRaw * 1000 }
                else { [long]0 }
        $memB = if ($memRaw -match '^(\d+)Ki$') { [long]$Matches[1] * 1KB }
                elseif ($memRaw -match '^(\d+)Mi$') { [long]$Matches[1] * 1MB }
                elseif ($memRaw -match '^(\d+)Gi$') { [long]$Matches[1] * 1GB }
                elseif ($memRaw -match '^\d+$') { [long]$memRaw }
                else { [long]0 }
        if ($memB -gt $bestMemB -or ($memB -eq $bestMemB -and $cpuM -gt $bestCpuM)) {
          $bestMemB = $memB; $bestCpuM = $cpuM
        }
      }
      $runCpuM = $bestCpuM - 1000
      $runMemB = $bestMemB - 3GB
      if ($runCpuM -ge 1000 -and $runMemB -ge 2GB) {
        return "cpu=$([math]::Floor($runCpuM / 1000)),memory=$([math]::Floor($runMemB / 1GB))Gi"
      }
    }
  } catch {}
  return "cpu=2,memory=8Gi"
}

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

# Resolve the backend base URL the same way jobs-manager does
# (client-runtime/controller.py: CLIENT_ENV -> backend), defaulting to prod.
function Get-BackendUrl {
  # Quote the value so a truly-unset CLIENT_ENV ($null) coerces to "" and the
  # default (prod) branch reliably fires across PowerShell versions.
  switch ("$env:CLIENT_ENV") {
    "dev"   { return "https://dev-api.tracebloc.io/" }
    "stg"   { return "https://stg-api.tracebloc.io/" }
    default { return "https://api.tracebloc.io/" }
  }
}

# Validate the entered Client ID / password against the backend's
# api-token-auth/ endpoint -- the same call jobs-manager makes at runtime.
# Returns: valid | invalid | inactive | unverified.
function Test-Credentials {
  param([string]$ClientId, [string]$ClientPassword)
  $backend = Get-BackendUrl
  try {
    $resp = Invoke-WebRequest -Uri "${backend}api-token-auth/" -Method Post `
      -Body @{ username = $ClientId; password = $ClientPassword } `
      -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
    if ($resp.StatusCode -eq 200) { return "valid" }
    return "unverified"
  } catch {
    $code = $null
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    switch ($code) {
      400     { return "invalid" }
      401     { return "inactive" }
      default { return "unverified" }   # 429 throttled, connection failure, 5xx, …
    }
  }
}

# =============================================================================
#  PROVISIONING (#388 — parity with scripts/lib/provision.sh)
# =============================================================================
# The bash installer registers the machine via the CLI: browser sign-in
# (`tracebloc login`, device flow) + `tracebloc client create` mints the
# machine credential, derives the namespace, and writes the CLI's
# active-client pointer — no secrets pass through the user's hands. These
# functions port that sequence; the legacy hand-copied Client-ID/password
# prompts survive only as the fallback for a too-old/missing CLI, and the
# TRACEBLOC_CLIENT_ID/TRACEBLOC_CLIENT_PASSWORD env pair stays as the
# unattended/automation path.

# True when the operator pre-supplied credentials -> browser sign-in is skipped
# and the Helm step consumes the env pair directly (mirrors _provisioning_preset).
function Get-ProvisioningPreset {
  return [bool]($env:TRACEBLOC_CLIENT_ID -and $env:TRACEBLOC_CLIENT_PASSWORD)
}

# Native-probe wrapper so Pester can mock per-invocation (a mocked FUNCTION
# doesn't set $LASTEXITCODE, so the callers below never shell out directly).
function Invoke-TraceblocProbe {
  param([string[]]$Args_)
  try { & tracebloc @Args_ *> $null } catch { return $false }
  return ($LASTEXITCODE -eq 0)
}

# Does the installed CLI ship the browser-auth mint commands? The CLI comes
# from the latest release, which can lag this installer — probe before
# committing (mirrors _cli_supports_provisioning; --help is side-effect-free
# and cobra exits non-zero on an unknown command).
function Test-CliProvisioningSupport {
  if (-not (Invoke-TraceblocProbe @("login", "--help"))) { return $false }
  if (-not (Invoke-TraceblocProbe @("client", "create", "--help"))) { return $false }
  return $true
}

# Fetch wrapper for `tracebloc client list --plain` (mockable, like the probe).
function Get-TraceblocClientList {
  $text = ""
  try { $text = (& tracebloc client list --plain 2>$null) | Out-String } catch { return [pscustomobject]@{ Ok = $false; Text = "" } }
  if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Ok = $false; Text = "" } }
  return [pscustomobject]@{ Ok = $true; Text = $text }
}

# Does the signed-in account's client list include namespace $Ns? Namespace is
# the only stable join key between a local Helm release and the list (they
# don't share an id) — mirrors _account_owns_namespace. Returns
# "owned" | "absent" | "unknown" (couldn't read the list).
function Test-AccountOwnsNamespace {
  param([string]$Ns)
  if (-not $Ns) { return "absent" }
  $list = Get-TraceblocClientList
  if (-not $list.Ok) { return "unknown" }
  if ($list.Text -match "namespace=$([regex]::Escape($Ns))(\s|$)") { return "owned" }
  return "absent"
}

# Surface the REAL reason `client create` failed instead of "see the log".
# Nothing sensitive: a failed create minted no credential. Special-cases the
# commonest tripwire — an unrecognized carbon zone (mirrors _report_create_failure).
function Print-CreateFailure {
  param([string]$OutFile, [string]$Location, [string]$Source = "env")
  Write-Host ""
  $text = ""
  if (Test-Path $OutFile) { $text = (Get-Content $OutFile -Raw -ErrorAction SilentlyContinue) }
  if ($text -match '(?i)location.*not a valid choice') {
    $locLabel = if ($Location) { "`"$Location`"" } else { "that location" }
    Warn "$locLabel isn't a recognized carbon zone - the client wasn't created."
    Hint "That value came from TRACEBLOC_CLIENT_LOCATION; set it to a valid code"
    Hint "(e.g. DE, FR, US, GB - all codes: https://api.electricitymap.org/v3/zones)"
    Hint "and re-run."
    return
  }
  $errLines = @()
  foreach ($l in ($text -split "`r?`n")) {
    if ($l -match 'Error:|HTTP [0-9][0-9][0-9]|refused|timed? ?out|unauthorized|forbidden|denied') { $errLines += $l }
    if ($errLines.Count -ge 4) { break }
  }
  if ($errLines.Count -gt 0) {
    Warn "The client couldn't be provisioned:"
    foreach ($l in $errLines) { if ($l.Trim()) { Hint $l.Trim() } }
  } else {
    Warn "The client couldn't be provisioned."
  }
}

# Strip ANSI CSI sequences (arrow keys, cursor moves), bracketed-paste markers,
# and C0 control characters from interactive input — they otherwise corrupt the
# name passed to `client create` into a garbage slug (mirrors common.sh's
# _strip_paste_garbage; customer-reported 2026-07-20 on the bash flow). UTF-8
# letters survive (only < 0x20 and DEL are dropped).
function ConvertTo-SanitizedInput {
  param([string]$Value)
  if (-not $Value) { return "" }
  $s = $Value -replace "$([char]27)\[[0-9;]*[A-Za-z~]", ""
  $s = $s.Replace("[200~", "").Replace("[201~", "")
  return (($s.ToCharArray() | Where-Object { [int]$_ -ge 32 -and [int]$_ -ne 127 }) -join "")
}

# Parse the credential file `tracebloc client create --credential-file` writes:
# plain KEY=value lines (split on the FIRST '=' — a password may contain '=').
# Mint writes TRACEBLOC_CLIENT_ID + TRACEBLOC_CLIENT_PASSWORD + TB_NAMESPACE;
# a re-run on an already-registered cluster writes TRACEBLOC_CLIENT_ID +
# TB_NAMESPACE + TRACEBLOC_CLIENT_ADOPTED=1 (no new credential is minted).
function Read-TraceblocCredentialFile {
  param([string]$Path)
  $cred = @{}
  foreach ($line in (Get-Content $Path -ErrorAction Stop)) {
    $idx = $line.IndexOf('=')
    if ($idx -gt 0) { $cred[$line.Substring(0, $idx).Trim()] = $line.Substring($idx + 1) }
  }
  return $cred
}

# Test-ApiReachable — a bounded liveness probe for the cluster API. helm has no
# request timeout, so any helm call against a wedged/unreachable API would hang
# indefinitely; callers gate helm behind this so they degrade gracefully instead
# of freezing the install. Returns $true only when kubectl reached the API within
# the timeout. Mirrors the bounded probe Get-TrainingResources runs before `helm
# get values` (Bugbot).
function Test-ApiReachable {
  param([int]$TimeoutSeconds = 5)
  $null = (kubectl get --raw='/readyz' --request-timeout="${TimeoutSeconds}s" 2>$null) | Out-String
  return ($LASTEXITCODE -eq 0)
}

# Enumerate what client (if any) is already installed on this cluster — the
# shared source for the provisioning pre-flight AND the Helm-step guard, so the
# two can never drift. Values are read with `-o json`, not YAML: helm
# re-serializes values on `get`, so the YAML view quotes clientId
# inconsistently and a quote-expecting regex silently bypassed the guard (#200).
# Returns Id/Ns (first identifiable client-chart release), UnreadableNs (a
# client release whose values couldn't be read — fail CLOSED, never treat as
# "no client here"), ListUnknown (couldn't even enumerate releases).
function Get-InstalledClientInfo {
  $existingId = ""; $existingNs = ""; $existingName = ""; $unreadableNs = ""; $listUnknown = $false
  # helm has no request timeout, so a wedged/unreachable API server would hang
  # `helm list`/`helm get values` indefinitely — freezing Step 4 (after browser
  # sign-in) and Step 5's one-client guard. Gate the enumeration behind a bounded
  # kubectl probe (mirrors Get-TrainingResources). If the API isn't reachable
  # within the timeout, degrade to the same "couldn't enumerate" (ListUnknown)
  # shape a helm failure produces, so callers fail closed instead of hanging (Bugbot).
  if (-not (Test-ApiReachable)) {
    return [pscustomobject]@{ Id = ""; Ns = ""; Name = ""; UnreadableNs = ""; ListUnknown = $true }
  }
  $listJson = (helm list -A -o json 2>$null) | Out-String
  if ($LASTEXITCODE -ne 0) {
    # helm list failed (wedged/unreachable API, kubeconfig glitch) -> unknown.
    # (helm returns 0 with an empty `[]` when there are genuinely no releases.)
    $listUnknown = $true
  } elseif ($listJson.Trim()) {
    try {
      foreach ($rel in ($listJson | ConvertFrom-Json)) {
        if ($rel.chart -and $rel.chart.StartsWith("client-")) {
          $valsJson = (helm get values $rel.name -n $rel.namespace -o json 2>$null) | Out-String
          # Values unavailable for THIS client release -> unidentifiable client.
          if ($LASTEXITCODE -ne 0 -or -not $valsJson.Trim()) {
            if (-not $unreadableNs) { $unreadableNs = $rel.namespace }
            continue
          }
          # No user values serializes as literal `null` (-> $vals = $null, a
          # parsed release with no clientId, NOT an error). An unparsable
          # release must not abort the scan, but it IS an unidentifiable
          # client -> record it and keep scanning.
          $vals = $null; $parsed = $true
          try { $vals = $valsJson | ConvertFrom-Json } catch { $parsed = $false }
          if (-not $parsed) {
            if (-not $unreadableNs) { $unreadableNs = $rel.namespace }
            continue
          }
          if ($null -eq $vals -or $null -eq $vals.clientId) { continue }
          $id = "$($vals.clientId)".Trim()
          if ($id) { $existingId = $id; $existingNs = $rel.namespace; $existingName = $rel.name; break }
        }
      }
    } catch {
      # helm list returned non-JSON/garbage -> can't trust the enumeration.
      $listUnknown = $true
    }
  }
  return [pscustomobject]@{ Id = $existingId; Ns = $existingNs; Name = $existingName; UnreadableNs = $unreadableNs; ListUnknown = $listUnknown }
}

# -- Step 4/5: Register this machine (browser sign-in; mirrors provision_client)
# Sets $script:TB_PROV_MODE to route the Helm step:
#   preset   - operator supplied TRACEBLOC_CLIENT_ID/PASSWORD (env automation)
#   minted   - fresh credential in TB_PROV_ID/TB_PROV_PASSWORD/TB_PROV_NS
#   adopted  - cluster already registered: TB_PROV_ID/TB_PROV_NS, no password
#   fallback - CLI missing/too old -> the legacy manual prompts in the Helm step
function Invoke-ProvisionClient {
  Step 4 5 "Registering this machine"
  $script:TB_PROV_MODE = "fallback"

  if (Get-ProvisioningPreset) {
    Info "Using the credentials you supplied - skipping browser sign-in."
    $script:TB_PROV_MODE = "preset"
    return
  }

  # The CLI was installed in Step 3; it may have landed on the *registry* PATH
  # only — re-read it so `tracebloc` resolves in THIS process.
  try { RefreshPath } catch { Log "RefreshPath failed before provisioning: $_" }
  if (-not (Has "tracebloc")) {
    Warn "The tracebloc CLI isn't available, so this machine can't be registered automatically - falling back to manual sign-in."
    Hint "Connect an existing client below, or install the CLI later for one-step browser sign-in:"
    Hint "  irm $TRACEBLOC_CLI_INSTALL_URL | iex"
    return
  }
  if (-not (Test-CliProvisioningSupport)) {
    Warn "This tracebloc CLI is too old to provision a client from the installer - falling back to manual sign-in."
    Hint "Connect an existing client below, or upgrade the CLI later for one-step browser sign-in:"
    Hint "  irm $TRACEBLOC_CLI_INSTALL_URL | iex"
    return
  }

  # Sign in (device flow). `tracebloc login` prints a URL + one-time code and
  # waits for approval — run it ATTACHED to the console (never captured), so
  # the user sees the link/code and the CLI can render its wait.
  Write-Host ""
  Write-Host "  Sign in to approve this machine - open the link in your browser"
  Write-Host "  (on this or any device) and enter the code:"
  Write-Host ""
  & tracebloc login
  if ($LASTEXITCODE -ne 0) { Err "Sign-in didn't complete - re-run the installer to try again." }

  # One-client-per-machine pre-flight (mirrors provision.sh #303): if a client
  # is already installed here and the signed-in account can't be shown to own
  # it, minting now would register a brand-new client that never installs (the
  # Helm-step guard refuses) — an orphan on the dashboard. Catch it BEFORE
  # minting. Inconclusive reads fail CLOSED; a client under the legacy fixed
  # 'tracebloc' namespace defers to `client create` + the Helm guard (they key
  # on clientId, which `client list` doesn't expose here).
  $inst = Get-InstalledClientInfo
  if ($inst.ListUnknown -or ($inst.UnreadableNs -and -not $inst.Id)) {
    Write-Host ""
    Warn "Couldn't determine whether a tracebloc client is already installed here."
    Hint "tracebloc runs one client per machine. Registering a new client now could strand"
    Hint "a second one if an existing client just couldn't be seen - usually the cluster API"
    Hint "is briefly unreachable. Check it and re-run:"
    Hint "  kubectl cluster-info"
    Hint "  helm list -A"
    Write-Host ""
    Err "Refusing to provision without verifying what's already on this machine."
  }
  if ($inst.Ns) {
    $own = Test-AccountOwnsNamespace -Ns $inst.Ns
    if ($own -eq "absent" -and $inst.Ns -ne "tracebloc") {
      Write-Host ""
      Warn "This machine already runs a tracebloc client (namespace '$($inst.Ns)') that isn't in the account you just signed in as."
      Hint "tracebloc runs one client per machine. Provisioning now would register a"
      Hint "second client and strand it (it could never install here). Pick one:"
      Hint "  - Repair / update it     -> sign in as the account that owns it, or re-run with that client's credentials"
      Hint "  - Switch to this account -> remove the current client first:"
      Hint "        k3d cluster delete $CLUSTER_NAME   (wipes this client + its local data)"
      Hint "      then re-run this installer"
      Hint "  - Run both               -> install on a separate machine"
      Write-Host ""
      Err "Refusing to provision a second client on this machine. See the options above."
    } elseif ($own -eq "absent") {
      Log "installed client is in the legacy 'tracebloc' namespace (not listed by its slug); deferring ownership to client create + the Helm one-client guard"
    }
  }

  # Name this machine. `client create` would prompt itself, but its output is
  # captured to the log below (the credential must never reach the terminal) —
  # so collect the name here. Precedence: TRACEBLOC_CLIENT_NAME (unattended) >
  # interactive prompt (3 tries on empty Enter) > fail closed.
  $clientName = ""
  if ($env:TRACEBLOC_CLIENT_NAME) { $clientName = $env:TRACEBLOC_CLIENT_NAME.Trim() }
  if (-not $clientName) {
    foreach ($try in 1..3) {
      $clientName = (Read-Host "  Name your secure environment (shown on your tracebloc dashboard)")
      # Strip paste/arrow-key escape garbage BEFORE the trim — it would slug-ify
      # into a garbage name like "d-d-d-a-a-a" (bash flow, 2026-07-20).
      $clientName = (ConvertTo-SanitizedInput -Value $clientName).Trim()
      if ($clientName) { break }
    }
  }
  if (-not $clientName) { Err "A name for this client is required to provision it. Re-run in a terminal to be prompted, or set TRACEBLOC_CLIENT_NAME for an unattended install." }

  # Location is NEVER prompted (RFC-0001 §6.4). Windows has no zone.tab to
  # derive a carbon zone from without an embedded Windows-timezone map that
  # would drift — so pass --location only when TRACEBLOC_CLIENT_LOCATION pins
  # one; the CLI treats it as optional and the backend defaults it.
  $clientLocation = ""
  if ($env:TRACEBLOC_CLIENT_LOCATION) { $clientLocation = $env:TRACEBLOC_CLIENT_LOCATION.Trim() }

  # Mint. --credential-file keeps the secret off the terminal; the file lives
  # in the user-profile data dir and is deleted right after parsing (its
  # durable home is the Helm/cluster secret — RFC §7.9).
  if (-not (Test-Path $HOST_DATA_DIR)) { New-Item -ItemType Directory -Path $HOST_DATA_DIR -Force | Out-Null }
  $credFile = Join-Path $HOST_DATA_DIR "client-credential.env"
  Remove-Item $credFile -Force -ErrorAction SilentlyContinue
  $createOut = Join-Path ([System.IO.Path]::GetTempPath()) "tb-client-create-$(Get-Random).log"
  $createArgs = @("client", "create", "--yes", "--name", $clientName, "--credential-file", $credFile)
  if ($clientLocation) { $createArgs += @("--location", $clientLocation) }
  # try/finally: PowerShell runs `finally` on Ctrl-C, terminating errors, AND
  # `exit` (Err), so the secret can never linger in the window between mint and
  # parse — the ps1 analogue of bash's _PROVISION_CRED_FILE + install_cleanup
  # (Bugbot #397 r2).
  $cred = $null
  try {
    & tracebloc @createArgs *> $createOut
    $createRc = $LASTEXITCODE
    if (Test-Path $createOut) { Get-Content $createOut -ErrorAction SilentlyContinue | ForEach-Object { Log $_ } }
    if ($createRc -ne 0) {
      Print-CreateFailure -OutFile $createOut -Location $clientLocation
      Err "Couldn't provision the client. Re-run to retry - full log: $LOG_FILE"
    }
    if (-not (Test-Path $credFile)) { Err "client create did not write the credential file ($credFile)." }
    $cred = Read-TraceblocCredentialFile -Path $credFile
  } finally {
    Remove-Item $credFile -Force -ErrorAction SilentlyContinue
    Remove-Item $createOut -Force -ErrorAction SilentlyContinue
  }

  $script:TB_PROV_ID = "$($cred['TRACEBLOC_CLIENT_ID'])".Trim()
  $script:TB_PROV_NS = "$($cred['TB_NAMESPACE'])".Trim()
  if ("$($cred['TRACEBLOC_CLIENT_ADOPTED'])".Trim() -eq "1") {
    # Re-run on an already-registered cluster: no fresh credential was minted
    # (the existing one stands, write-only on the backend). The Helm step
    # reconciles the existing release and heals a stale clientId to this UUID.
    Info "This cluster is already registered (client $($script:TB_PROV_ID)) - reconciling the existing install."
    $script:TB_PROV_PASSWORD = ""
    $script:TB_PROV_MODE = "adopted"
    return
  }
  $script:TB_PROV_PASSWORD = "$($cred['TRACEBLOC_CLIENT_PASSWORD'])"
  if (-not $script:TB_PROV_ID -or -not $script:TB_PROV_PASSWORD) { Err "The credential file was incomplete - re-run the installer to retry." }
  $script:TB_PROV_MODE = "minted"
  # The registered identity is the minted slug (= the dashboard name), which
  # may be de-duplicated from the raw typed name.
  Ok "Registered as `"$($script:TB_PROV_NS)`""
  Log "Provisioned - credential handed to the install (not shown)."
}

function Install-ClientHelm {
  # -- Step 5/5: Install tracebloc client --
  Step 5 5 "Installing tracebloc client"

  if (-not (Test-Path $HOST_DATA_DIR)) {
    New-Item -ItemType Directory -Path $HOST_DATA_DIR -Force | Out-Null
  }
  $valuesFile = Join-Path $HOST_DATA_DIR "values.yaml"

  # -- Credentials + namespace, routed by the Step-4 provisioning mode (#388) --
  $provMode = if ($script:TB_PROV_MODE) { $script:TB_PROV_MODE } else { "fallback" }
  $TB_CLIENT_ID = ""; $TB_CLIENT_PASSWORD = ""; $rawNs = ""

  switch ($provMode) {
    "minted" {
      # Freshly minted by `tracebloc client create`. The namespace MUST be the
      # minted slug (it equals the heartbeat-reported namespace). Verify even a
      # fresh mint (never skip verification by provisioning method — Bugbot
      # #397 r2): a mint that can't authenticate — backend skew, an account
      # deactivated mid-flow — fails HERE, not as a crash-looping pod later.
      $TB_CLIENT_ID = $script:TB_PROV_ID
      $TB_CLIENT_PASSWORD = $script:TB_PROV_PASSWORD
      $rawNs = $script:TB_PROV_NS
      Info "Verifying the new credential with tracebloc..."
      $credStatus = Test-Credentials -ClientId $TB_CLIENT_ID -ClientPassword $TB_CLIENT_PASSWORD
      if ($credStatus -eq "valid") { Ok "Credentials verified." }
      elseif ($credStatus -eq "inactive") { Err "This tracebloc account is not active yet. Check your email for the activation link, then re-run." }
      elseif ($credStatus -eq "invalid") { Err "The freshly minted credential was rejected by tracebloc - this shouldn't happen. Re-run the installer; if it persists, contact tracebloc support." }
      else {
        Warn "Couldn't reach tracebloc to verify the new credential right now - continuing."
      }
    }
    "adopted" {
      # Re-run on a registered cluster: no new credential was minted (the
      # existing one stands, write-only on the backend). With a LIVE release
      # the upgrade below is surgical (--reuse-values, heals only clientId —
      # Bugbot #397 r2) and needs no password at all; the previous values-file
      # password matters only on a rebuilt cluster with no release, decided
      # after the guard where the release enumeration is known.
      $TB_CLIENT_ID = $script:TB_PROV_ID
      $rawNs = $script:TB_PROV_NS
      if (Test-Path $valuesFile) {
        $TB_CLIENT_PASSWORD = Get-TraceblocYamlValue -Path $valuesFile -Key "clientPassword"
      }
    }
    "preset" {
      # Unattended/automation path: the operator-supplied env pair. Verify once,
      # non-interactively (the same api-token-auth call jobs-manager makes) —
      # a wrong credential fails here, not as a crash-looping pod later.
      $TB_CLIENT_ID = $env:TRACEBLOC_CLIENT_ID
      $TB_CLIENT_PASSWORD = $env:TRACEBLOC_CLIENT_PASSWORD
      Info "Verifying the supplied credentials with tracebloc..."
      $credStatus = Test-Credentials -ClientId $TB_CLIENT_ID -ClientPassword $TB_CLIENT_PASSWORD
      if ($credStatus -eq "valid") { Ok "Credentials verified." }
      elseif ($credStatus -eq "inactive") { Err "This tracebloc account is not active yet. Check your email for the activation link, then re-run." }
      elseif ($credStatus -eq "invalid") { Err "The supplied TRACEBLOC_CLIENT_ID / TRACEBLOC_CLIENT_PASSWORD was rejected by tracebloc. Check them at https://ai.tracebloc.io/clients and re-run." }
      else {
        Warn "Couldn't reach tracebloc to verify the supplied credentials right now - continuing."
        Hint "If they are wrong, your client will stay offline at https://ai.tracebloc.io/clients after install."
      }
    }
    default {
      # -- Legacy manual connect (fallback ONLY: the CLI was missing or too old
      # for browser provisioning in Step 4). Hand-copied credentials from the
      # web app — dropped from the primary path by #388.
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

      PromptHeader "To connect this machine, you need a tracebloc client."
      Hint "A client links your secure environment to the tracebloc"
      Hint "platform so other collaborators can submit models for evaluation."
      Write-Host ""
      Hint "Create one here (free):"
      Write-Host "    " -NoNewline; Write-Host "https://ai.tracebloc.io/clients" -ForegroundColor White
      Write-Host ""

      # Collect + verify credentials. The entered Client ID / password are checked
      # against the backend (the same api-token-auth/ call jobs-manager makes)
      # before we deploy, so a wrong credential is caught here -- with a re-prompt --
      # instead of surfacing later as a silently crash-looping pod.
      $credAttempt = 0; $credMax = 5
      while ($true) {
        if ($defaultClientId) {
          $idInput = Read-Host "  Client ID [$defaultClientId]"
          $TB_CLIENT_ID = if ($idInput) { $idInput } else { $defaultClientId }
        } else {
          $TB_CLIENT_ID = Read-Host "  Client ID"
        }
        if (-not $TB_CLIENT_ID) { Warn "Client ID cannot be empty."; continue }

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
        if (-not $TB_CLIENT_PASSWORD) { Warn "Client password cannot be empty."; continue }

        Info "Verifying credentials with tracebloc..."
        $credStatus = Test-Credentials -ClientId $TB_CLIENT_ID -ClientPassword $TB_CLIENT_PASSWORD
        if ($credStatus -eq "valid") { Ok "Credentials verified."; break }
        elseif ($credStatus -eq "inactive") { Err "This tracebloc account is not active yet. Check your email for the activation link, then re-run." }
        elseif ($credStatus -eq "unverified") {
          Warn "Couldn't reach tracebloc to verify your credentials right now - continuing."
          Hint "If they are wrong, your client will stay offline at https://ai.tracebloc.io/clients after install."
          break
        } else {
          Warn "That Client ID / password was rejected by tracebloc - please re-enter."
          Hint "Find your credentials at https://ai.tracebloc.io/clients"
        }

        $credAttempt++
        if ($credAttempt -ge $credMax) { Err "Too many failed attempts. Double-check your credentials at https://ai.tracebloc.io/clients and re-run." }
        # Force active re-entry on retry (don't silently reuse a rejected default).
        $defaultClientId = ""; $defaultClientPassword = ""
      }
    }
  }

  # -- Namespace --
  # Minted/adopted installs land in the client's SLUG namespace (bash parity —
  # it equals the heartbeat-reported namespace). Preset/fallback keep the fixed
  # default ('tracebloc'); advanced/GitOps setups can override with
  # TB_NAMESPACE=<name>. Never prompted — the client is identified to the
  # backend by clientId, not this name.
  if (-not $rawNs) { $rawNs = if ($env:TB_NAMESPACE) { $env:TB_NAMESPACE } else { "tracebloc" } }
  $TB_NAMESPACE = ConvertTo-WorkspaceName -Input_ $rawNs
  $script:TB_NAMESPACE = $TB_NAMESPACE   # share with Wait-ForClientReady / Print-Summary

  # -- One-client-per-machine guard --
  # A machine runs exactly one tracebloc client: it shares this cluster and the
  # host's CPU/RAM/GPU, and the platform counts each client as separate
  # capacity. If a DIFFERENT client is already installed here, a re-install
  # would silently re-point the machine -- so we stop and let the operator
  # decide. The same clientId is a normal re-run/upgrade and passes through.
  # Check ANY namespace: a fresh install lands in 'tracebloc', but an install
  # from an older installer version may be in a different namespace. The
  # enumeration lives in Get-InstalledClientInfo (#388 — shared with the
  # Step-4 provisioning pre-flight so the two can never drift; #200 fail-closed
  # semantics preserved there).
  $inst = Get-InstalledClientInfo
  $existingId = $inst.Id; $existingNs = $inst.Ns
  $unreadableNs = $inst.UnreadableNs; $listUnknown = $inst.ListUnknown
  # Fail closed when we couldn't identify a client we can see ($unreadableNs) OR
  # couldn't enumerate at all ($listUnknown). Refuse rather than overwrite an
  # unknown client -- the operator must resolve it explicitly.
  if (-not $existingId -and ($unreadableNs -or $listUnknown)) {
    Write-Host ""
    if ($listUnknown) {
      Warn "Couldn't determine which tracebloc client (if any) is already installed here -- helm could not enumerate releases."
    } else {
      Warn "A tracebloc client release is installed here (namespace '$unreadableNs') but its configuration could not be read."
    }
    Hint "tracebloc runs one client per machine, so the installer will not overwrite"
    Hint "a client it cannot see (usually the cluster API is briefly unreachable). Check and re-run:"
    Hint "  kubectl cluster-info         (is the API reachable?)"
    Hint "  helm get values -A           (see what is installed)"
    Hint "  k3d cluster delete $CLUSTER_NAME   (wipes this client + its local data)"
    Write-Host ""
    Err "Refusing to replace an unidentifiable existing client."
  }
  # Adopted mode is the ONE sanctioned id mismatch: the backend just anchored
  # THIS cluster to the adopted UUID (`client create`), while the local release
  # still stores a stale id (cli#125-era installs kept the numeric dashboard
  # id, which can't authenticate). That's not a different client — it's exactly
  # the skew the values write below heals; refusing here would make every
  # legacy-id re-run abort (Bugbot #397 r1, High).
  if ($existingId -and $existingId -ne $TB_CLIENT_ID -and $provMode -eq "adopted") {
    Log "one-client guard: healing stale clientId '$existingId' -> adopted '$TB_CLIENT_ID' (namespace '$existingNs')"
  } elseif ($existingId -and $existingId -ne $TB_CLIENT_ID) {
    Write-Host ""
    Warn "This machine already runs the tracebloc client '$existingId' (namespace '$existingNs')."
    Hint "tracebloc runs one client per machine -- it shares this cluster and host"
    Hint "resources, and the platform counts each client as separate capacity."
    Write-Host ""
    Hint "You entered a different Client ID ('$TB_CLIENT_ID'). Pick one:"
    Hint "  - Repair / update '$existingId'  -> re-run with that same Client ID"
    Hint "  - Switch to '$TB_CLIENT_ID'       -> remove the current client first:"
    Hint "        k3d cluster delete $CLUSTER_NAME   (wipes this client + its local data)"
    Hint "      then re-run this installer"
    Hint "  - Run both clients                -> install on a separate machine"
    Write-Host ""
    Err "Refusing to replace the existing client. See the options above."
  }

  # -- Adopted reconcile routing (#397 r2) --
  # With a LIVE release, reconcile surgically: upgrade THAT release, in ITS
  # namespace, with --reuse-values — preserving the deployed configuration and
  # secret, healing only clientId (bash parity: the reuse-values reconcile).
  # Regenerating values.yaml would clobber live config with fresh defaults.
  # Only a rebuilt cluster (adopted anchor on the backend, no local release)
  # needs the full values write — and that path needs the previous password.
  $adoptedReuse = $false
  $existingName = $inst.Name
  if ($provMode -eq "adopted" -and $existingId) {
    $adoptedReuse = $true
    $TB_NAMESPACE = $existingNs
    $script:TB_NAMESPACE = $TB_NAMESPACE   # Wait-ForClientReady watches the LIVE release's namespace
  } elseif ($provMode -eq "adopted" -and -not $TB_CLIENT_PASSWORD) {
    Write-Host ""
    Warn "This cluster is registered as client '$TB_CLIENT_ID', but no release survives locally and the previous configuration (with the client password) is gone."
    Hint "Pick one:"
    Hint "  - Re-run with the client's credentials:  set TRACEBLOC_CLIENT_ID + TRACEBLOC_CLIENT_PASSWORD, then re-run"
    Hint "  - Start fresh:  k3d cluster delete $CLUSTER_NAME   (wipes this client + its local data), then re-run"
    Write-Host ""
    Err "Can't reconcile the existing client without its password."
  }

  if (-not $adoptedReuse) {
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
  # backend#743: relocate the dataset PV onto the network mount when HOST_DATASET_DIR is set.
  $datasetPathLine = if ($HOST_DATASET_DIR) { "`n  datasetPath: /tracebloc-data" } else { "" }
  # backend#1236 (option A): size the default training budget to this machine.
  $trainingSize = Get-TrainingResources
  Log "Training size: $trainingSize"
  $envBlock += @"
  RESOURCE_LIMITS: "$trainingSize"
  RESOURCE_REQUESTS: "$trainingSize"
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
  enabled: true$datasetPathLine

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
  }   # end -not $adoptedReuse (values regeneration)

  # Register the chart repo unconditionally. `--force-update` is idempotent, heals
  # a stale/wrong URL from an earlier attempt, and re-fetches the repo index, so no
  # separate `helm repo update` pass is needed. (The old presence guard string-
  # matched `(helm repo list 2>&1)`: on a fresh machine helm reports "no
  # repositories" on stderr, and Windows PowerShell 5.1 renders that ErrorRecord
  # with this script's own ...\tracebloc-installer-<n>\install-k8s.ps1 temp path --
  # which contains "tracebloc" -- so the guard skipped the add on every fresh
  # install and Step 4 died later with "Error: repo tracebloc not found". #385)
  Log "Adding Helm repo: $TRACEBLOC_HELM_REPO_URL"
  $addOutput = (helm repo add $TRACEBLOC_HELM_REPO_NAME $TRACEBLOC_HELM_REPO_URL --force-update 2>&1) | Out-String
  Log "helm repo add: $addOutput"
  if ($LASTEXITCODE -ne 0) { Err "Couldn't add the tracebloc chart repo ($TRACEBLOC_HELM_REPO_URL). Helm output:`n$addOutput`nCheck the log for details: $LOG_FILE" }

  Write-Host ""
  if ($adoptedReuse) {
    # Surgical reconcile of the LIVE release: --reuse-values preserves the
    # deployed configuration + secret; only clientId is healed (#397 r2).
    Log "Reconciling release '$existingName' in namespace '$existingNs' (adopted; --reuse-values; healing clientId)..."
    $helmOutput = (helm upgrade $existingName "$TRACEBLOC_HELM_REPO_NAME/$TRACEBLOC_CHART_NAME" `
      --namespace $existingNs `
      --reuse-values `
      --set-string "clientId=$TB_CLIENT_ID" 2>&1) | Out-String
    Log "Helm Output: $helmOutput"
    if ($LASTEXITCODE -ne 0) { Err "Client reconcile failed. Helm output:`n$helmOutput`nCheck the log for details: $LOG_FILE" }
    # Keep the LOCAL record in step for future default-reuse prompts: heal only
    # the clientId line, never regenerate — the live release is the truth.
    if (Test-Path $valuesFile) {
      $vals = Get-Content $valuesFile -Raw
      $vals = $vals -replace '(?m)^clientId:\s*.*$', "clientId: `"$TB_CLIENT_ID`""
      Set-Content -Path $valuesFile -Value $vals -Encoding UTF8
    }
  } else {
    Log "Installing $TB_NAMESPACE from $TRACEBLOC_HELM_REPO_NAME/$TRACEBLOC_CHART_NAME in namespace '$TB_NAMESPACE'..."
    $helmOutput = (helm upgrade --install $TB_NAMESPACE "$TRACEBLOC_HELM_REPO_NAME/$TRACEBLOC_CHART_NAME" `
      --namespace $TB_NAMESPACE `
      --create-namespace `
      --values $valuesFile 2>&1) | Out-String
    Log "Helm Output: $helmOutput"
    if ($LASTEXITCODE -ne 0) { Err "Client installation failed. Helm output:`n$helmOutput`nCheck the log for details: $LOG_FILE" }
  }

  # Point kubeconfig's current context at the client namespace so kubectl + the
  # tracebloc CLI default to it (no -n / --namespace needed). Best-effort.
  kubectl config set-context --current --namespace $TB_NAMESPACE 2>$null | Out-Null

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
  $pods = kubectl get pods -n $script:TB_NAMESPACE -o wide 2>&1 | Out-String
  Log $pods
  Log "--- End Cluster Status ---"
}

# ── Readiness gate (#716) ─────────────────────────────────────────────────
# helm install only *applies* manifests; it does not wait for pods. Wait for the
# client's workloads to actually become Ready and set $script:ClientState so the
# summary reports the truth: connected | starting | bad_creds | image_pull | crash
function Wait-ForClientReady {
  $ns = $script:TB_NAMESPACE
  $deploys = @("mysql-client", "$ns-jobs-manager", "$ns-requests-proxy")
  $deadline = (Get-Date).AddSeconds([int]$ReadyTimeout)
  $allReady = $true

  Write-Host ""
  Info "Waiting for the client to start - first run downloads images, this can take a few minutes..."
  foreach ($d in $deploys) {
    $remaining = [int]((New-TimeSpan -Start (Get-Date) -End $deadline).TotalSeconds)
    if ($remaining -lt 10) { $remaining = 10 }
    & kubectl rollout status "deployment/$d" -n $ns "--timeout=${remaining}s" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Ok ("{0} ready" -f ($d -replace "^$ns-", ""))
    } else {
      $allReady = $false
      break
    }
  }

  Confirm-Cluster
  if ($allReady) { $script:ClientState = "connected" }
  else { $script:ClientState = (Get-NotReadyState -Namespace $ns) }
}

# Classify why the client isn't Ready, for an accurate message. Returns a state.
function Get-NotReadyState {
  param([string]$Namespace)
  # Wrong credentials: jobs-manager authenticates to the backend on startup and
  # crash-loops when rejected -- surfaced as an auth error in its logs.
  $jmLogs = (& kubectl logs -n $Namespace "deployment/$Namespace-jobs-manager" --all-containers --tail=50 2>$null | Out-String)
  if ($jmLogs -match '(?i)authentication failed|unable to log in') { return "bad_creds" }
  $pods = (& kubectl get pods -n $Namespace 2>$null | Out-String)
  if ($pods -match '(?i)ImagePullBackOff|ErrImagePull|InvalidImageName') { return "image_pull" }
  if ($pods -match '(?i)CrashLoopBackOff') { return "crash" }
  return "starting"
}

# =============================================================================
#  SUMMARY
# =============================================================================

# Reports the outcome based on $script:ClientState (set by Wait-ForClientReady).
# The "secure compute environment / your data never leaves" claim is printed
# ONLY when the client is verifiably connected -- never on a partial/failed run.
function Print-Summary {
  $mode = "CPU"
  if ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK) { $mode = "NVIDIA GPU" }
  elseif ($GPU_VENDOR -eq "nvidia" -and -not $NVIDIA_DRIVER_OK) { $mode = "CPU (NVIDIA driver update needed)" }
  $ns = $script:TB_NAMESPACE
  $line = [string]([char]0x2501) * 46

  Write-Host ""
  switch ($script:ClientState) {
    "connected" {
      Write-Host "  $line" -ForegroundColor Green
      Write-Host ""
      Write-Host "  " -NoNewline; Write-Host "$([char]0x2714) Connected to tracebloc" -ForegroundColor Green
      Write-Host ""
      Write-Host "  Environment : " -ForegroundColor DarkGray -NoNewline; Write-Host $ns
      $cver = Get-ChartVersion -Namespace $ns; if (-not $cver) { $cver = "unknown" }
      Write-Host "  Version     : " -ForegroundColor DarkGray -NoNewline; Write-Host $cver
      Write-Host "  Mode        : " -ForegroundColor DarkGray -NoNewline; Write-Host $mode
      Write-Host ""
      Write-Host "  Your client is live. Confirm it shows as Online:"
      Write-Host "    https://ai.tracebloc.io/clients" -ForegroundColor Cyan
      Write-Host ""
      Hint "Models other collaborators submit train on this machine -- your data never leaves it."
      Write-Host ""
      Hint "After a reboot, start Docker Desktop to bring your client back (enable 'Start Docker Desktop when you sign in' in Settings -> General to automate)."
      Write-Host ""
      Write-Host "  What to do next" -ForegroundColor Cyan
      Write-Host "  1. Ingest your training and test data with the tracebloc CLI:"
      Write-Host "       tracebloc data ingest ./data" -ForegroundColor Green
      Write-Host "  2. Create your use case and invite other collaborators: https://ai.tracebloc.io/my-use-cases"
      Write-Host ""
      Hint "Dashboard: https://ai.tracebloc.io   Logs: ~\.tracebloc\   Data: /tracebloc/$ns"
      Write-Host ""
      Write-Host "  $line" -ForegroundColor Green
    }
    "starting" {
      Write-Host "  " -NoNewline; Write-Host "$([char]0x26A0)  Almost there - tracebloc is installed but still starting." -ForegroundColor Yellow
      Write-Host ""
      Write-Host "  Components are still downloading/starting (first run can take a few minutes)."
      Write-Host "  Check progress:   " -NoNewline; Write-Host "kubectl get pods -n $ns" -ForegroundColor Green
      Write-Host ""
      Write-Host "  Your client will show as Online at https://ai.tracebloc.io/clients once it finishes."
      Hint "Re-running this installer is safe."
    }
    "bad_creds" {
      Write-Host "  " -NoNewline; Write-Host "$([char]0x2716) Couldn't connect - your Client ID or password was rejected." -ForegroundColor Red
      Write-Host ""
      Write-Host "  The environment installed, but tracebloc refused those credentials."
      Write-Host "    1. Re-check them at https://ai.tracebloc.io/clients" -ForegroundColor Cyan
      Write-Host "    2. Re-run this installer (safe to re-run)"
    }
    default {
      $reason = "a component didn't start"
      if ($script:ClientState -eq "image_pull") { $reason = "an image couldn't be pulled" }
      if ($script:ClientState -eq "crash")      { $reason = "a container is restarting (crash loop)" }
      Write-Host "  " -NoNewline; Write-Host "$([char]0x2716) Setup didn't finish - $reason." -ForegroundColor Red
      Write-Host ""
      Write-Host "  Inspect:  " -NoNewline; Write-Host "kubectl get pods -n $ns" -ForegroundColor Green
      Write-Host "  Logs:     ~\.tracebloc\install-*.log"
      Hint "Re-running this installer is safe."
    }
  }
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
#  PREFLIGHT — fail-fast environment checks (mirrors scripts/lib/preflight.sh)
# =============================================================================

# Non-exiting failure line (Err exits; preflight must finish all checks first).
function Write-PfFail($m) { Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red -NoNewline; Write-Host " $m" -ForegroundColor Red }

# Probe a URL for reachability. Returns: ok|tls|dns|timeout|blocked (or "http <code>"
# under -RequireSuccess). By default any HTTP response (incl. 401/403/404) counts as
# reachable (TLS + HTTP completed) -- registry endpoints answer 401 by design. Pass
# -RequireSuccess for targets whose CONTENT must exist (e.g. the Helm repo index.yaml:
# the site root 404s by design, so plain reachability proves nothing there, #385).
# Honors the system / HTTP_PROXY proxy automatically.
function Test-PfUrl([string]$Url, [switch]$RequireSuccess) {
  try {
    Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop | Out-Null
    return "ok"
  } catch {
    if ($null -ne $_.Exception.Response) {                 # reached the server, got an HTTP error
      if ($RequireSuccess) { return "http $([int]$_.Exception.Response.StatusCode)" }
      return "ok"
    }
    $m = "$($_.Exception.Message)"
    if ($m -match 'trust|SSL|certificate|TLS|secure channel') { return "tls" }
    if ($m -match 'resolve|name or service|known')            { return "dns" }
    if ($m -match 'timed out|timeout')                        { return "timeout" }
    return "blocked"
  }
}

# Free GB on the drive holding $HOST_DATA_DIR (or C:); $null if undeterminable
# (e.g. non-Windows under Pester — tests mock this).
function Get-PfFreeGb {
  try {
    $qualifier = (Split-Path -Qualifier $HOST_DATA_DIR -ErrorAction SilentlyContinue)
    if (-not $qualifier) { $qualifier = "C:" }
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$qualifier'" -ErrorAction Stop
    return [math]::Floor($d.FreeSpace / 1GB)
  } catch { return $null }
}

# "network" if $HOST_DATA_DIR is on a UNC path or a mapped network drive
# (Win32_LogicalDisk DriveType 4); "local" otherwise; $null if undeterminable
# (e.g. non-Windows under Pester - tests mock this). Mirrors preflight.sh
# _pf_storage_type: MySQL/InnoDB corrupts or crash-loops on network storage.
function Get-PfFsType {
  try {
    if ($HOST_DATA_DIR -like '\\*') { return "network" }   # UNC path (\\server\share)
    $qualifier = (Split-Path -Qualifier $HOST_DATA_DIR -ErrorAction SilentlyContinue)
    if (-not $qualifier) { return "local" }                # no drive letter, not UNC
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$qualifier'" -ErrorAction Stop
    if ($d.DriveType -eq 4) { return "network" }           # DriveType 4 = network drive
    return "local"
  } catch { return $null }
}

# Memory/CPU as the container runtime sees it (the Docker Desktop / WSL2 VM budget,
# which is what the pods actually get — smaller than the host). $null if the daemon
# is down or the value is junk, so callers fall back to the host (CIM) reader.
function Get-PfRuntimeMemGb {
  try {
    $v = ((docker info --format '{{.MemTotal}}' 2>$null) | Out-String).Trim()
    if ($v -match '^\d+$' -and [int64]$v -gt 0) { return [math]::Floor([int64]$v / 1GB) }
  } catch {}
  return $null
}
function Get-PfRuntimeCpu {
  try {
    $v = ((docker info --format '{{.NCPU}}' 2>$null) | Out-String).Trim()
    if ($v -match '^\d+$' -and [int]$v -gt 0) { return [int]$v }
  } catch {}
  return $null
}

# Prefer the runtime view, fall back to the host (CIM).
function Get-PfMemGb {
  $r = Get-PfRuntimeMemGb; if ($null -ne $r) { return $r }
  try { return [math]::Floor((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB) }
  catch { return $null }
}

function Get-PfCpu {
  $r = Get-PfRuntimeCpu; if ($null -ne $r) { return $r }
  try { return [int](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).NumberOfLogicalProcessors }
  catch { if ($env:NUMBER_OF_PROCESSORS) { return [int]$env:NUMBER_OF_PROCESSORS } else { return $null } }
}

# $true when this machine can host Docker's VM: a hypervisor is already running
# (check FIRST — when Hyper-V owns VT-x, VirtualizationFirmwareEnabled reads
# $false on a perfectly healthy machine), or virtualization is enabled in
# firmware. $false = disabled in BIOS/UEFI. $null if undeterminable (non-Windows
# under Pester — tests mock this). #387
function Get-PfVirtualization {
  try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($cs.HypervisorPresent) { return $true }
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    if ($null -ne $cpu.VirtualizationFirmwareEnabled) { return [bool]$cpu.VirtualizationFirmwareEnabled }
    return $null
  } catch { return $null }
}

function Test-Preflight {
  if ($env:TRACEBLOC_SKIP_PREFLIGHT) { Info "Preflight checks skipped (TRACEBLOC_SKIP_PREFLIGHT set)."; return }

  $minDiskGb  = if ($env:PF_MIN_DISK_GB)  { [int]$env:PF_MIN_DISK_GB }  else { 10 }
  $warnDiskGb = if ($env:PF_WARN_DISK_GB) { [int]$env:PF_WARN_DISK_GB } else { 20 }
  $minMemGb   = if ($env:PF_MIN_MEM_GB)   { [int]$env:PF_MIN_MEM_GB }   else { 5 }
  $warnMemGb  = if ($env:PF_WARN_MEM_GB)  { [int]$env:PF_WARN_MEM_GB }  else { 8 }
  $recMemGb   = if ($env:PF_REC_MEM_GB)   { [int]$env:PF_REC_MEM_GB }   else { 16 }
  $minCpu     = if ($env:PF_MIN_CPU)      { [int]$env:PF_MIN_CPU }      else { 2 }
  $recCpu     = if ($env:PF_REC_CPU)      { [int]$env:PF_REC_CPU }      else { 4 }
  $hardFail   = 0

  # Architecture — the tracebloc client images (e.g. mysql-client) are amd64-only.
  $arch = Get-WindowsArch
  if ($arch -eq "amd64") {
    Ok "Architecture: amd64"
  } elseif ($env:TRACEBLOC_ALLOW_ARM64) {
    Warn "Architecture: $arch - proceeding (TRACEBLOC_ALLOW_ARM64 set); amd64-only images may crash if emulation is unavailable."
  } else {
    Info "Architecture: $arch - Docker Desktop runs the amd64 client images under emulation (slower, but works)."
  }

  # Hardware virtualization -- without it Docker Desktop's VM cannot start, and
  # its own failure ("Virtualization support not detected") only appears AFTER
  # this installer has installed and launched it, with no guidance (#387).
  # Fail fast here instead, with the firmware fix.
  $virt = Get-PfVirtualization
  if ($null -eq $virt) {
    Info "Virtualization: couldn't determine (skipping)."
  } elseif ($virt) {
    Ok "Virtualization enabled"
  } else {
    Write-PfFail "Virtualization is disabled in firmware - Docker Desktop cannot run."
    $hardFail++
    Hint "Enable Intel VT-x / AMD SVM in your BIOS/UEFI setup (usually under Advanced -> CPU), then re-run."
    Hint "Confirm afterwards in Task Manager -> Performance -> CPU: 'Virtualization: Enabled'."
    Hint "On a company device this setting may be locked by IT policy."
  }

  $cpu = Get-PfCpu
  if      ($null -eq $cpu)   { Warn "CPU: couldn't determine core count (skipping)." }
  elseif  ($cpu -lt $minCpu) { Warn "CPU: $cpu core(s) - below the $minCpu-core minimum; mysql may hit lock-wait timeouts. $recCpu+ recommended to train." }
  elseif  ($cpu -lt $recCpu) { Warn "CPU: $cpu cores - fine to run; $recCpu+ recommended to train locally." }
  else                       { Ok "CPU: $cpu cores" }

  # Memory is warn-only on Windows: at preflight the Docker Desktop / WSL2 daemon may
  # be down (so this is host RAM); the post-Docker re-check sees the real VM budget.
  $mem = Get-PfMemGb
  if      ($null -eq $mem)      { Warn "Memory: couldn't determine total RAM (skipping)." }
  elseif  ($mem -lt $minMemGb)  {
    Warn "Memory: $mem GB - below the $minMemGb GB the client needs; it will OOM."
    Hint "Give Docker more memory (>= $warnMemGb GB; $recMemGb GB to train), then re-run:"
    Hint "  WSL2 backend (the default): set [wsl2] memory=${warnMemGb}GB in %UserProfile%\.wslconfig, run 'wsl --shutdown', restart Docker Desktop."
    Hint "  Hyper-V backend: Docker Desktop -> Settings -> Resources -> Advanced."
  }
  elseif  ($mem -lt $warnMemGb) {
    Warn "Memory: $mem GB - enough to run, but training (~8 GB/job) may OOM; $recMemGb GB recommended to train locally."
    Hint "To train locally give Docker >= $recMemGb GB: WSL2 backend - [wsl2] memory=${recMemGb}GB in %UserProfile%\.wslconfig + 'wsl --shutdown'; Hyper-V backend - Docker Desktop -> Settings -> Resources -> Advanced."
  }
  else                          { Ok "Memory: $mem GB" }

  $disk = Get-PfFreeGb
  if      ($null -eq $disk)        { Warn "Disk: couldn't determine free space (skipping)." }
  elseif  ($disk -lt $minDiskGb)   { Write-PfFail "Disk: only $disk GB free - need >= $minDiskGb GB."; $hardFail++; Hint "Free up space or attach a larger disk, then re-run." }
  elseif  ($disk -lt $warnDiskGb)  { Warn "Disk: $disk GB free - recommended >= $warnDiskGb GB; images + data may fill it." }
  else                             { Ok "Disk: $disk GB free" }

  # Network-FS guard: MySQL/InnoDB corrupts or crash-loops on NFS/CIFS/SMB. Fail
  # fast instead of a cryptic CrashLoopBackOff ~20 min in. (Mirrors preflight.sh.)
  $fs = Get-PfFsType
  if     ($null -eq $fs)      { Info "Storage: filesystem type undetermined; assuming local." }
  elseif ($fs -eq "network") {
    if ($env:TRACEBLOC_ALLOW_NETWORK_FS) {
      Warn "Storage: $HOST_DATA_DIR is on a network filesystem - proceeding (TRACEBLOC_ALLOW_NETWORK_FS set); the client database may corrupt or crash-loop."
    } else {
      Write-PfFail "Storage: $HOST_DATA_DIR is on a network filesystem - the tracebloc client database (MySQL/InnoDB) corrupts or crash-loops on network storage."
      $hardFail++
      Hint "Fix: point HOST_DATA_DIR at a LOCAL disk (the default $env:USERPROFILE\.tracebloc is local)."
      Hint "  (or set `$env:TRACEBLOC_ALLOW_NETWORK_FS=1 to proceed anyway - not recommended for the database.)"
    }
  }
  else                       { Ok "Storage: $HOST_DATA_DIR local disk" }

  Info "Checking outbound connectivity to required services..."
  $backendHost = (Get-BackendUrl) -replace '^https?://','' -replace '/$',''
  $criticals = @(
    @{ label = "Docker Hub (registry-1.docker.io)";           url = "https://registry-1.docker.io/v2/" },
    @{ label = "GitHub Container Registry (ghcr.io)";         url = "https://ghcr.io/" },
    @{ label = "tracebloc API ($backendHost)";                url = "https://$backendHost/" },
    # The chart repo is probed at its index.yaml, strictly: the site ROOT 404s by
    # design (so "any response = reachable" proves nothing), while the index must
    # actually exist for `helm repo add` to succeed (#385).
    @{ label = "tracebloc Helm charts (tracebloc.github.io)"; url = "$TRACEBLOC_HELM_REPO_URL/index.yaml"; strict = $true }
  )
  $tlsSeen = $false; $cfail = 0
  foreach ($c in $criticals) {
    $status = Test-PfUrl $c.url -RequireSuccess:([bool]$c.strict)
    if ($status -ne "ok") { $status = Test-PfUrl $c.url -RequireSuccess:([bool]$c.strict) }   # one retry for transient blips
    if ($status -eq "ok") { Ok "$($c.label) reachable" }
    else {
      Write-PfFail "$($c.label) unreachable ($status)"
      $hardFail++; $cfail++
      if ($status -eq "tls") { $tlsSeen = $true }
    }
  }
  if ($tlsSeen)    { Hint "A TLS/certificate error usually means a break-and-inspect (TLS-inspecting) proxy whose corporate CA isn't trusted here - see the proxy notes." }
  if ($cfail -gt 0){ Hint "Allow HTTPS (443) egress to: registry-1.docker.io, ghcr.io, $backendHost, tracebloc.github.io - or configure your corporate proxy." }

  if ($hardFail -gt 0) {
    Write-Host ""
    Err "Preflight failed - resolve the items above and re-run. (Override at your own risk with `$env:TRACEBLOC_SKIP_PREFLIGHT=1.)"
  }
}

# Re-evaluate memory once Docker is confirmed up. Test-Preflight runs before Docker
# Desktop starts, so its read may have been host RAM, not the (smaller) Docker VM
# budget. Called from New-K3dCluster. WARN-only — the user has already waited for
# Docker, so aborting here would be jarring.
function Test-PreflightRuntimeMem {
  if ($env:TRACEBLOC_SKIP_PREFLIGHT) { return }
  $mem = Get-PfRuntimeMemGb
  if ($null -eq $mem) { return }
  $warnMemGb = if ($env:PF_WARN_MEM_GB) { [int]$env:PF_WARN_MEM_GB } else { 8 }
  $recMemGb  = if ($env:PF_REC_MEM_GB)  { [int]$env:PF_REC_MEM_GB }  else { 16 }
  if ($mem -lt $warnMemGb) {
    Warn "Docker is running with $mem GB - recommended >= $warnMemGb GB ($recMemGb GB to train); the client may OOM under load."
    Hint "Give Docker >= $warnMemGb GB, then re-install: WSL2 backend - [wsl2] memory=${warnMemGb}GB in %UserProfile%\.wslconfig + 'wsl --shutdown'; Hyper-V backend - Docker Desktop -> Settings -> Resources -> Advanced."
  }
}

# =============================================================================
#  DIAGNOSE — `-Diagnose` support bundle (mirrors scripts/lib/diagnose.sh)
# =============================================================================

# Redact secrets from a file IN PLACE. Applied to every collected file before
# archiving. Single-quoted replacement strings keep $1 literal for the regex.
# Written UTF-8 without BOM.
function Edit-Redaction([string]$Path) {
  if (-not (Test-Path $Path)) { return }
  try {
    $t = Get-Content -Path $Path -Raw -ErrorAction Stop
    # First rule redacts ANY *password key (clientPassword, dockerRegistry
    # password, HTTP_PROXY_PASSWORD, ...) in : or = form, not just clientPassword.
    $t = $t -replace '(?i)([A-Za-z0-9_.-]*password\s*[:=]\s*).*', '$1[REDACTED]'
    $t = $t -replace '([a-zA-Z][a-zA-Z0-9+.-]*://)[^:/@\s]+:[^@/\s]+@', '$1[REDACTED]@'
    $t = $t -replace '(?i)((token|secret|authorization|api[_-]?key)\s*[:=]\s*).*', '$1[REDACTED]'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $t, $utf8NoBom)
  } catch {}
}

function Invoke-DiagnoseBundle {
  $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
  $base = if ($HOST_DATA_DIR) { $HOST_DATA_DIR } else { "$env:USERPROFILE\.tracebloc" }
  $cn = if ($CLUSTER_NAME) { $CLUSTER_NAME } else { "tracebloc" }
  New-Item -ItemType Directory -Path $base -Force -ErrorAction SilentlyContinue | Out-Null
  $work = Join-Path ([System.IO.Path]::GetTempPath()) ("tracebloc-diag-" + [System.IO.Path]::GetRandomFileName())
  $d = Join-Path $work "tracebloc-diagnose-$ts"
  New-Item -ItemType Directory -Path (Join-Path $d "logs") -Force | Out-Null

  # Namespace discovery (TB_NAMESPACE isn't set on a standalone diagnose run).
  $ns = $TB_NAMESPACE
  if (-not $ns) {
    $jm = kubectl get pods -A 2>$null | Select-String '\-jobs-manager' | Select-Object -First 1
    if ($jm) { $ns = ($jm.ToString().Trim() -split '\s+')[0] }
  }
  if (-not $ns) { $ns = "default" }

  # Surface the client version first -- the #1 thing support needs to know.
  $cver = Get-ChartVersion -Namespace $ns; if (-not $cver) { $cver = "unknown" }
  Info "tracebloc client version: $cver   (namespace: $ns)"
  Info "Collecting diagnostics -- this is safe; credentials are redacted before the file is written."

  # host / versions
  $h = @("# tracebloc diagnose ($ts)", "OS: Windows  ARCH: $(Get-WindowsArch)",
         "CLIENT_ENV: $($env:CLIENT_ENV)  CLUSTER_NAME: $cn  NAMESPACE: $ns", "CLIENT VERSION: $cver", "## versions",
         (k3d version 2>&1 | Out-String), (kubectl version --client 2>&1 | Out-String),
         (helm version --short 2>&1 | Out-String), (docker version 2>&1 | Out-String))
  try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop; $h += "CPUs=$($cs.NumberOfLogicalProcessors)  MemBytes=$($cs.TotalPhysicalMemory)" } catch {}
  ($h -join "`n") | Out-File (Join-Path $d "00-host.txt") -Encoding utf8

  ((docker ps -a --filter "name=k3d-$cn-" 2>&1 | Out-String) + "`n" + (k3d cluster list 2>&1 | Out-String)) | Out-File (Join-Path $d "01-docker.txt") -Encoding utf8

  if (Get-Command kubectl -ErrorAction SilentlyContinue) {
    (@("## nodes", (kubectl get nodes -o wide 2>&1 | Out-String),
       "## pods", (kubectl get pods -A -o wide 2>&1 | Out-String),
       "## events", (kubectl get events -A 2>&1 | Out-String)) -join "`n") | Out-File (Join-Path $d "02-kubectl.txt") -Encoding utf8
    foreach ($w in @("mysql-client", "$ns-jobs-manager", "$ns-requests-proxy")) {
      kubectl logs -n $ns "deploy/$w" --all-containers --tail=500 2>&1 | Out-File (Join-Path $d "logs/$w.log") -Encoding utf8
    }
  }
  if (Get-Command helm -ErrorAction SilentlyContinue) {
    (@("## helm list", (helm list -A 2>&1 | Out-String), "## values", (helm get values $ns -n $ns 2>&1 | Out-String)) -join "`n") | Out-File (Join-Path $d "04-helm.txt") -Encoding utf8
  }

  Get-ChildItem -Path $base -Filter "install-*.log" -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item $_.FullName (Join-Path $d $_.Name) -ErrorAction SilentlyContinue }
  if (Test-Path "$base\values.yaml") { Copy-Item "$base\values.yaml" (Join-Path $d "values.yaml") -ErrorAction SilentlyContinue }

  (("## proxy env`n") + ((@("HTTP_PROXY","HTTPS_PROXY","NO_PROXY") | ForEach-Object { "$_=" + [Environment]::GetEnvironmentVariable($_) }) -join "`n")) | Out-File (Join-Path $d "05-proxy.txt") -Encoding utf8

  # REDACT every collected file, THEN archive.
  Get-ChildItem -Path $d -Recurse -File | ForEach-Object { Edit-Redaction $_.FullName }
  $bundle = Join-Path $base "tracebloc-diagnose-$ts.zip"
  if (Test-Path $bundle) { Remove-Item $bundle -Force -ErrorAction SilentlyContinue }
  Compress-Archive -Path $d -DestinationPath $bundle -Force -ErrorAction SilentlyContinue
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

  Write-Host ""
  if (Test-Path $bundle) {
    Ok "Diagnostics saved (credentials redacted):"
    Write-Host "    $bundle"
    Hint "Send this file to tracebloc support -- it has logs + status with passwords removed."
  } else {
    Write-Host "  Could not create the diagnostics archive." -ForegroundColor Red
  }
}

# =============================================================================
#  INSTALL TRACEBLOC CLI (Step 5)
# =============================================================================
# Installs the `tracebloc` CLI via its own released installer (tracebloc/cli),
# which downloads the right build for this OS/arch and verifies it (SHA256 +
# cosign signature). Lets the user push datasets to the client they just set
# up:  tracebloc data ingest ./data
#
# NON-FATAL: runs after the client is connected, so a CLI-install hiccup warns
# and moves on. The CLI's own installer sets $ErrorActionPreference='Stop' and
# exits on failure, so we run it in a CHILD powershell process — its exit can
# never abort THIS installer.
$TRACEBLOC_CLI_INSTALL_URL = "https://github.com/tracebloc/cli/releases/latest/download/install.ps1"

# Where the CLI's own Windows installer drops the binary + adds to the *user*
# PATH (see cli's install.ps1) — the dir we point at if a fresh shell can't
# find it yet. Guard the Join-Path: $env:LOCALAPPDATA is null when the Pester
# suite dot-sources this script on Linux CI, and Join-Path throws on a null
# -Path (aborting the whole test container). The value is only ever USED on
# Windows (in Test-TraceblocCli), so "" is a fine non-Windows load-time placeholder.
$TRACEBLOC_CLI_INSTALL_DIR = if ($env:LOCALAPPDATA) {
  Join-Path $env:LOCALAPPDATA "Programs\tracebloc"
} else { "" }

# Post-install self-verification (#738). Proves the CLI is usable from a FRESH
# terminal and prints a VERIFIED next command — or, if a new shell wouldn't
# find it yet, the exact Windows-correct fix (the install dir + open a new
# window) rather than a vague "open a new terminal". The CLI installer edits the
# user-scope PATH in the registry, so RefreshPath (re-reading Machine+User PATH)
# is the faithful "fresh terminal" probe here — there is no `source ~/.rc`
# analogue on Windows. ALWAYS non-fatal: a missing CLI degrades Step 4 to the
# legacy manual-credential fallback (#388).
function Test-TraceblocCli {
  # Pull the persisted (registry) PATH into THIS process — same env a brand-new
  # PowerShell window would start with.
  try { RefreshPath } catch { Log "RefreshPath failed during CLI verify: $_" }

  if (Has "tracebloc") {
    # `tracebloc version` is the real proof; cosmetic, never fatal. The canonical
    # "tracebloc data ingest ./data" next step lives in Print-Summary's "What to
    # do next" — don't duplicate it; just confirm the verdict.
    $ver = ""
    try { $ver = (& tracebloc version 2>$null | Select-Object -First 1) } catch { $ver = "" }
    $short = if ($ver -match '\s(\S+)') { "v" + $Matches[1] } else { "" }
    # Prefer the short 'tb' alias; fall back to 'tracebloc' if it isn't on PATH
    # (the alias wasn't created), so the copy never names a missing command (Bugbot).
    $cli = if (Has "tb") { "tb" } else { "tracebloc" }
    if ($short) { Ok "tracebloc CLI ready ($short) -- run '$cli' to use it." }
    else        { Ok "tracebloc CLI ready -- run '$cli' to use it." }
    return
  }

  # Installed, but not resolvable from a fresh shell yet. The installer added it
  # to the user PATH, so a NEW window will have it; tell the user exactly where
  # it is and how to use it now (so the summary's command works from a new window).
  Ok "tracebloc CLI installed -- open a new PowerShell window to use it."
  Hint "  Installed to: $TRACEBLOC_CLI_INSTALL_DIR"
  Hint "  Or use it now via:  & `"$TRACEBLOC_CLI_INSTALL_DIR\tracebloc.exe`" data ingest .\data"
}

function Install-TraceblocCli {
  # -- Step 3/5 (#388): BEFORE connect, as bash does — the CLI mints the machine
  # credential in Step 4 (browser sign-in + `client create`). A failed CLI
  # install is still non-fatal: Step 4 falls back to the legacy manual-
  # credential flow, so the machine can always be connected.
  Step 3 5 "Install the tracebloc CLI"

  Info "Installing the tracebloc CLI..."

  # [System.IO.Path]::GetTempPath() is cross-platform (%TEMP% on Windows, /tmp
  # on Linux); $env:TEMP is null under Linux pwsh, which the ubuntu Pester run
  # exercises.
  $cliOut = Join-Path ([System.IO.Path]::GetTempPath()) "tracebloc-cli-install-$(Get-Random).log"
  $cliErr = "$cliOut.err"
  try {
    $p = Start-Process -FilePath "powershell.exe" `
      -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-Command","irm '$TRACEBLOC_CLI_INSTALL_URL' | iex") `
      -NoNewWindow -PassThru `
      -RedirectStandardOutput $cliOut -RedirectStandardError $cliErr
    # Caching .Handle before the process exits, then WaitForExit(), makes
    # .ExitCode reliable. (The -Wait -PassThru form can leave .ExitCode $null
    # with redirected output; -PassThru + Handle + WaitForExit does not.)
    $null = $p.Handle
    $p.WaitForExit()
    foreach ($f in @($cliOut, $cliErr)) {
      if (Test-Path $f) { Get-Content $f -ErrorAction SilentlyContinue | ForEach-Object { Log $_ } }
    }
    # Installer exit status is the SOLE source of truth, mirroring the bash step
    # (`if sh installer; then …`). Do NOT also accept "tracebloc already on PATH"
    # as success — a failed re-install on a machine that already had the CLI
    # would then be misreported as a success.
    if ($p.ExitCode -eq 0) {
      # Self-verify usability from a fresh terminal and print a verified next
      # command (or the Windows-correct fix). Non-fatal.
      Test-TraceblocCli
    } else {
      Warn "Couldn't install the tracebloc CLI automatically -- you can still connect with existing client credentials."
      Hint "Install it later:  irm $TRACEBLOC_CLI_INSTALL_URL | iex"
    }
  } catch {
    Warn "Couldn't install the tracebloc CLI automatically -- you can still connect with existing client credentials."
    Hint "Install it later:  irm $TRACEBLOC_CLI_INSTALL_URL | iex"
    Log "CLI install failed: $_"
  } finally {
    Remove-Item $cliOut, $cliErr -Force -ErrorAction SilentlyContinue
  }
}

# =============================================================================
#  MAIN
# =============================================================================

if (-not $env:TB_PESTER) {

if ($Help) { Print-Help }
if ($Diagnose) { Invoke-DiagnoseBundle; exit 0 }

Confirm-Config
Initialize-ToolDir
Start-InstallLog
Print-Banner
Print-Roadmap

# -- Step 1/5: Check system requirements --
Step 1 5 "Checking system requirements"
Test-Preflight
Find-Gpu
Enable-VirtualisationFeatures
Install-Winget
Install-DockerDesktop
Install-NvidiaContainerToolkit
Install-Kubectl
Install-K3dAndHelm

# -- Step 2/5: Set up secure compute environment --
Step 2 5 "Setting up secure compute environment"
New-K3dCluster
Install-GpuDevicePlugin
Confirm-GpuNode

# -- Step 3/5: install the tracebloc CLI FIRST (#388) — it mints the machine
# credential in Step 4; a CLI-install hiccup degrades Step 4 to the legacy
# manual-credential fallback instead of aborting.
Install-TraceblocCli

# -- Step 4/5: register this machine (browser sign-in + `client create`;
# env-var credentials skip it; missing/old CLI falls back to manual prompts) --
Invoke-ProvisionClient

# -- Step 5/5 handled inside Install-ClientHelm --
Install-ClientHelm

# Verify the client actually came up before reporting anything
Wait-ForClientReady

Print-Summary

try { Stop-Transcript | Out-Null } catch {}

# Exit code reflects reality: connected/starting are OK; failures are non-zero.
if ($script:ClientState -ne "connected" -and $script:ClientState -ne "starting") { exit 1 }

}  # end TB_PESTER guard (skipped when the test suite dot-sources this file)
