# =============================================================================
#  install-wsl-gpu.ps1 -- sections 4 and 4b of install-wsl.ps1: the host GPU
#  check, and the GPU WSL can give the distro.
#
#  install-wsl.ps1 dot-sources this file from beside itself, at the place the
#  section stands in its order, and checks it through $CoreFiles; install.ps1
#  fetches and verifies it with the rest ($Files). The GPU state and the floors
#  it reads, $NVIDIA_*_FLOOR and the name patterns, stay in install-wsl.ps1, where
#  check-facts.sh stamps them.
# =============================================================================

# The log line (no-op here: this script keeps no log file) and the dim hint line.
function Hint($m)          { Close-Live; Write-Host "  $m" -ForegroundColor DarkGray; Log $m }

# A process exit code for a failure line, never blank.
function Format-ExitCode {
  param($Code)
  if ($null -eq $Code -or "$Code".Trim() -eq '') { return 'with no code reported' }
  return "$Code"
}

# The pure verdict and its helpers: the bash twins are detect-gpu.sh's _nvidia_* functions.
function ConvertTo-FloorVersion([string]$Text) {
  $t = ($Text -replace '\s', '')
  if ($t -notmatch '^\d+(\.\d+){0,3}$') { return $null }
  $parts = @($t.Split('.'))
  while ($parts.Count -lt 4) { $parts += '0' }
  try { return [version]($parts -join '.') } catch { return $null }
}

function ConvertTo-NvidiaNameNormalised([string]$Name) {
  $n = ($Name.ToUpperInvariant() -replace '[^A-Z0-9]+', ' ').Trim()
  return " $n "
}

function Get-NvidiaPreTuringName([string]$NameOutput) {
  foreach ($line in ([string]$NameOutput) -split "\r?\n") {
    if ((ConvertTo-NvidiaNameNormalised $line) -cmatch $NVIDIA_PRE_TURING_NAME_RE) { return $line.Trim() }
  }
  return $null
}

function Get-NvidiaFloorVerdict {
  param([string]$DriverOutput, [string]$CapOutput, [string]$DriverFloor, [string]$CapFloor, [string]$HardFloor, [string]$NameOutput)
  $df = ConvertTo-FloorVersion $DriverFloor
  $cf = ConvertTo-FloorVersion $CapFloor
  $hf = ConvertTo-FloorVersion $HardFloor
  if ($null -eq $df -or $null -eq $cf -or $null -eq $hf) { return "unreadable" }
  $lowest = {
    param([string]$Out)
    $low = $null
    foreach ($line in ([string]$Out).Trim() -split "\r?\n") {
      $v = ConvertTo-FloorVersion $line
      if ($null -eq $v) { return $null }
      if ($null -eq $low -or $v -lt $low) { $low = $v }
    }
    return $low
  }
  $drv = & $lowest $DriverOutput
  if ($null -eq $drv) { return "unreadable" }
  $cap = & $lowest $CapOutput
  if ($null -ne $cap -and $cap -lt $cf) { return "below-compute" }
  if ($null -eq $cap -and $null -ne (Get-NvidiaPreTuringName $NameOutput)) { return "below-compute" }
  if ($drv -lt $hf) { return "below-hard-floor" }
  if ($null -eq $cap) { return "unreadable" }
  return "ok"
}

function Get-NvidiaUnsupportedName {
  param([string]$NameOutput, [string]$CapOutput, [string]$CapFloor)
  $names = @(([string]$NameOutput) -split "\r?\n")
  $caps = @(([string]$CapOutput) -split "\r?\n")
  $cf = ConvertTo-FloorVersion $CapFloor
  $first = ""
  $capsReadable = $true
  foreach ($c in $caps) { if ($null -eq (ConvertTo-FloorVersion $c)) { $capsReadable = $false } }
  for ($i = 0; $i -lt $names.Count; $i++) {
    $n = $names[$i].Trim()
    if (-not $n) { continue }
    if (-not $first) { $first = $n }
    $c = if ($i -lt $caps.Count) { ConvertTo-FloorVersion $caps[$i] } else { $null }
    if ($null -ne $c -and $null -ne $cf -and $c -lt $cf) { return $n }
  }
  if (-not $capsReadable) { $old = Get-NvidiaPreTuringName $NameOutput; if ($old) { return $old } }
  return $first
}

# Reads the driver, the compute capability and the card names with nvidia-smi.exe
# (bounded), judges them, and leaves the verdict in the state above.
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

    # Bounded (installer external-call timeout rule / Bugbot): a wedged driver must not hang the
    # install -- and Find-Gpu now runs before the fast path, so an unbounded nvidia-smi would hang
    # every "nothing to do" re-run too.
    # -StdoutOnly on BOTH queries: the verdict reads every line
    # as a version and calls any other line unreadable, so a successful nvidia-smi that also
    # printed a warning to stderr would lose a working GPU. The bash twin reads stdout only
    # too (a command substitution, with 2>/dev/null). A failing query keeps its stderr.
    $dr = Invoke-BoundedProcess -FileName $nvSmi -Arguments @("--query-gpu=driver_version","--format=csv,noheader") -TimeoutSec 15 -StdoutOnly
    # 124 IS THE TIMEOUT, so the code is what separates the two causes this
    # message names -- "failed or timed out" made the operator guess which.
    if ($dr.Code -ne 0) {
      Warn "Couldn't query the NVIDIA driver (nvidia-smi exited $(Format-ExitCode $dr.Code); 124 means it timed out) -- GPU checks skipped."
      $script:GPU_SKIP_REASON = "the NVIDIA driver version could not be read (nvidia-smi exited $(Format-ExitCode $dr.Code)) -- running CPU-only"
      return
    }
    $driverVer = ([string]$dr.Output -split "`n" | Select-Object -First 1).Trim()
    $script:NVIDIA_DRIVER_VERSION = $driverVer   # quoted back in a GPU-skip reason
    # compute_cap is its own query: a driver too old to know it fails that query alone,
    # and the floor still reads the driver version.
    $cr = Invoke-BoundedProcess -FileName $nvSmi -Arguments @("--query-gpu=compute_cap","--format=csv,noheader") -TimeoutSec 15 -StdoutOnly
    $capOut = if ($cr.Code -eq 0) { [string]$cr.Output } else { "" }
    # The LOWEST compute capability, as the verdict judges it: on a mixed host the
    # message names the card that is too old, not whichever GPU nvidia-smi lists first.
    $capVer = @($capOut -split "\r?\n" | ForEach-Object { $_.Trim() } |
      Where-Object { $null -ne (ConvertTo-FloorVersion $_) } |
      Sort-Object { ConvertTo-FloorVersion $_ } | Select-Object -First 1)
    $capVer = if ($capVer.Count -gt 0) { [string]$capVer[0] } else { "unknown" }
    # The card's name: the verdict classifies it by name when the driver cannot report
    # compute_cap. A failed query is no name, never a guess.
    $nr = Invoke-BoundedProcess -FileName $nvSmi -Arguments @("--query-gpu=name","--format=csv,noheader") -TimeoutSec 15 -StdoutOnly
    $nameOut = if ($nr.Code -eq 0) { [string]$nr.Output } else { "" }
    $verdict = Get-NvidiaFloorVerdict -DriverOutput ([string]$dr.Output) -CapOutput $capOut -DriverFloor $NVIDIA_DRIVER_FLOOR -CapFloor $NVIDIA_COMPUTE_CAP_FLOOR -HardFloor $NVIDIA_DRIVER_HARD_FLOOR -NameOutput $nameOut
    $script:GPU_UNSUPPORTED_REASON = ""; $script:GPU_UNSUPPORTED_NAME = ""
    $script:GPU_UNSUPPORTED_CODE = ""
    # The bash twin's TB_GPU_FLOOR_VERDICT. install-wsl.ps1 hands it to the core in WSL.
    $script:GPU_FLOOR_VERDICT = $verdict
    $script:NVIDIA_GPU_NAMES = $nameOut
    Log "GPU floor: $verdict (driver $driverVer, floor $NVIDIA_DRIVER_FLOOR, hard floor $NVIDIA_DRIVER_HARD_FLOOR; compute capability $capVer, floor $NVIDIA_COMPUTE_CAP_FLOOR)"
    if ($verdict -eq "ok") {
      $script:NVIDIA_DRIVER_OK = $true
      Ok "NVIDIA GPU ready (driver $driverVer)"
      # Expectation-setting only, never a gate: entry-level cards pass
      # every check but are too small for real training (field: a 2 GB GT 710
      # installed fine and could never fit a model).
      try {
        $vr = Invoke-BoundedProcess -FileName $nvSmi -Arguments @("--query-gpu=memory.total","--format=csv,noheader,nounits") -TimeoutSec 15
        $vramMiB = if ($vr.Code -eq 0) { [int](($vr.Output -split "`n" | Select-Object -First 1).Trim()) } else { 0 }
        if ($vramMiB -gt 0 -and $vramMiB -lt 8192) {
          Hint "This GPU has $([math]::Round($vramMiB / 1024, 1)) GB VRAM - fine for setup; real training typically needs 8 GB+."
        }
      } catch {}
    } elseif ($verdict -eq "below-compute") {
      $oldName = Get-NvidiaPreTuringName $nameOut
      if ($capVer -eq "unknown" -and $oldName) {
        # Classified by name: the driver could not report the compute capability,
        # so the card is named instead of a number.
        $script:GPU_SKIP_REASON = "this NVIDIA GPU ($oldName) is too old for tracebloc's GPU images, which need compute capability $NVIDIA_COMPUTE_CAP_FLOOR or newer -- running CPU-only"
        Warn "This NVIDIA GPU ($oldName) is too old for tracebloc's GPU images, which need compute capability $NVIDIA_COMPUTE_CAP_FLOOR or newer -- this machine will run in CPU mode."
        $script:GPU_UNSUPPORTED_REASON = "This GPU is too old for tracebloc's GPU training images, which need compute capability $NVIDIA_COMPUTE_CAP_FLOOR or newer (NVIDIA Turing or later), so this machine runs on CPU."
      } else {
        $script:GPU_SKIP_REASON = "this NVIDIA GPU (compute capability $capVer) is too old for tracebloc's GPU images, which need $NVIDIA_COMPUTE_CAP_FLOOR or newer -- running CPU-only"
        Warn "This NVIDIA GPU (compute capability $capVer) is too old for tracebloc's GPU images, which need $NVIDIA_COMPUTE_CAP_FLOOR or newer -- this machine will run in CPU mode."
        $script:GPU_UNSUPPORTED_REASON = "This GPU (compute capability $capVer) is too old for tracebloc's GPU training images, which need $NVIDIA_COMPUTE_CAP_FLOOR or newer (NVIDIA Turing or later), so this machine runs on CPU."
      }
      $script:GPU_UNSUPPORTED_CODE = "compute_too_old"
      $script:GPU_UNSUPPORTED_NAME = Get-NvidiaUnsupportedName -NameOutput $nameOut -CapOutput $capOut -CapFloor $NVIDIA_COMPUTE_CAP_FLOOR
      Hint "GPU training needs a newer card (NVIDIA Turing or later). Everything else works on CPU."
    } elseif ($verdict -eq "below-hard-floor") {
      # Below the CUDA 13 minimum tracebloc's GPU images need (torch 2.14.1+cu130) the
      # GPU would be advertised and unusable, so it is left off: there
      # is no warning band (2026-10-18). The update is to the driver floor, and the GPU
      # is set up only by a run on the new driver, so the hint says to re-run the installer.
      $script:GPU_SKIP_REASON = "NVIDIA driver $driverVer is older than $NVIDIA_DRIVER_HARD_FLOOR, the driver tracebloc's GPU training images need (CUDA 13) -- running CPU-only"
      Warn "NVIDIA driver $driverVer is older than $NVIDIA_DRIVER_HARD_FLOOR, the driver tracebloc's GPU training images need (CUDA 13) -- this machine will run in CPU mode."
      $script:GPU_UNSUPPORTED_REASON = "The NVIDIA driver on this machine ($driverVer) is older than $NVIDIA_DRIVER_HARD_FLOOR, the driver tracebloc's GPU training images need (CUDA 13), so this machine runs on CPU until the driver is updated to $NVIDIA_DRIVER_FLOOR or newer and the installer is run again."
      $script:GPU_UNSUPPORTED_CODE = "driver_too_old"
      $script:GPU_UNSUPPORTED_NAME = Get-NvidiaUnsupportedName -NameOutput $nameOut -CapOutput $capOut -CapFloor $NVIDIA_COMPUTE_CAP_FLOOR
      Hint "To use the GPU: install NVIDIA driver $NVIDIA_DRIVER_FLOOR or newer (https://www.nvidia.com/Download/index.aspx), reboot, then re-run the installer."
    } else {
      $script:GPU_SKIP_REASON = "the NVIDIA driver version and compute capability could not be read -- running CPU-only"
      Warn "Couldn't read this NVIDIA GPU's driver version and compute capability -- this machine will run in CPU mode to be safe."
      Hint "Check that 'nvidia-smi --query-gpu=driver_version,compute_cap --format=csv' works, then re-run the installer."
    }
  } catch {
    Warn "Could not verify NVIDIA driver: $_"
  }
}

# Find-Gpu and the helpers it calls, copied unchanged: the GPUs Windows lists, an
# NVIDIA one first, then Confirm-NvidiaDriver; a GPU that is not NVIDIA, or an NVIDIA
# GPU on arm64, is reported (not_nvidia, arch_unsupported) and goes on the core
# runs' line with the rest (New-CoreRunArguments).

# ConvertTo-GpuNormalisedName -- twin of detect-gpu.sh's _nvidia_name_normalised: upper case,
# every run of characters that are not a letter or digit one space, one space either side.
function ConvertTo-GpuNormalisedName([string]$Name) {
  $n = ([string]$Name).ToUpperInvariant() -replace '[^A-Z0-9]+', ' '
  return " $($n.Trim()) "
}

# Get-GpuNotNvidiaName -- pure twin of detect-gpu.sh's _gpu_not_nvidia_name:
# $Names are GPU names (Win32_VideoController.Name). Returns the GPU to report as not_nvidia
# when there is a GPU of a $GPU_NOT_NVIDIA_VENDOR_RE vendor and NO NVIDIA one; "" otherwise.
# Any NVIDIA GPU wins: NVIDIA plus an iGPU is an NVIDIA machine. A discrete AMD card is named
# before an Intel iGPU.
function Get-GpuNotNvidiaName {
  param([string[]]$Names)
  $first = ""; $discrete = ""
  foreach ($raw in @($Names)) {
    $n = ([string]$raw).Trim()
    if (-not $n) { continue }
    $norm = ConvertTo-GpuNormalisedName $n
    if ($norm -clike '* NVIDIA *') { return "" }
    if ($norm -cnotmatch $GPU_NOT_NVIDIA_VENDOR_RE) { continue }
    if (-not $first) { $first = $n }
    if (-not $discrete -and $norm -cmatch $GPU_NOT_NVIDIA_DISCRETE_RE) { $discrete = $n }
  }
  if ($discrete) { return $discrete }
  return $first
}

# Set-GpuNotNvidia -- the machine has a GPU and it is not NVIDIA: tell the platform (not_nvidia).
# The sentence is detect-gpu.sh's _gpu_not_nvidia_report's, byte for byte.
function Set-GpuNotNvidia([string]$Name) {
  $script:GPU_UNSUPPORTED_CODE = "not_nvidia"
  $script:GPU_UNSUPPORTED_REASON = "This machine's GPU is not an NVIDIA GPU, and tracebloc's GPU training images need one (NVIDIA Turing or later), so this machine runs on CPU."
  $script:GPU_UNSUPPORTED_NAME = $Name
}

# Test-GpuArchSupported -- $true unless Windows runs on arm64: the GPU training images are
# linux/amd64 only. Reads the environment, never Err: an unknown value is
# not arm64. PROCESSOR_ARCHITEW6432 is the machine's own answer in an x64-emulated shell.
function Test-GpuArchSupported {
  return -not ($env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or $env:PROCESSOR_ARCHITEW6432 -eq "ARM64")
}

# Set-GpuArchUnsupported -- an NVIDIA GPU on a machine that is not x86_64: leave it off
# (nvidia_unsupported, so no driver check and no GPU wiring) and tell the platform
# (arch_unsupported). The sentence is detect-gpu.sh's _gpu_arch_unsupported_report's.
function Set-GpuArchUnsupported([string]$Name) {
  $script:GPU_VENDOR = "nvidia_unsupported"; $script:NVIDIA_DRIVER_OK = $false
  $script:GPU_UNSUPPORTED_CODE = "arch_unsupported"
  $script:GPU_UNSUPPORTED_REASON = "This machine is arm64, and tracebloc's GPU training images are built for x86_64 machines only, so this machine runs on CPU."
  $script:GPU_UNSUPPORTED_NAME = $Name
  Warn "tracebloc's GPU training images are built for x86_64 machines only, and this machine is arm64 -- the NVIDIA GPU is not set up, and this machine will run in CPU mode."
  Hint "Everything else works on CPU. GPU training needs an x86_64 machine with an NVIDIA GPU."
}

function Find-Gpu {
  Log "GPU detection starting"
  $script:GPU_UNSUPPORTED_REASON = ""; $script:GPU_UNSUPPORTED_NAME = ""; $script:GPU_UNSUPPORTED_CODE = ""

  try {
    $gpus = @(Get-CimInstance Win32_VideoController |
            Where-Object { $_.Name -notmatch "Microsoft|Basic|VirtualBox" })
    # NVIDIA first, wherever WMI lists it: an NVIDIA card beside an Intel iGPU or an AMD card
    # is an NVIDIA machine, never judged by whichever adapter came first.
    $nv = @($gpus | Where-Object { $_.Name -match "NVIDIA" })
    $amd = @($gpus | Where-Object { $_.Name -match "AMD|Radeon" })
    if ($nv.Count -gt 0) {
      $script:GPU_VENDOR = "nvidia"; Ok "NVIDIA GPU found $Dot $($nv[0].Name)"
    } elseif ($amd.Count -gt 0) {
      $script:GPU_VENDOR = "amd"; Ok "AMD GPU found $Dot $($amd[0].Name)"
    }
    # A GPU that is not NVIDIA (AMD, or Intel -- the integrated one included) is a GPU this
    # machine cannot train on: named to the platform as not_nvidia, not "no GPU".
    $notNvidia = Get-GpuNotNvidiaName -Names @($gpus | ForEach-Object { [string]$_.Name })
    if ($notNvidia) { Set-GpuNotNvidia $notNvidia }
    if ($script:GPU_VENDOR -eq "none") {
      if ($notNvidia) { Info "$notNvidia is not an NVIDIA GPU $Dot training will use the CPU" }
      else { Info "No GPU found $Dot training will use the CPU" }
    }
  } catch {
    Info "No GPU found $Dot training will use the CPU"
    Log "GPU detection failed: $_"
  }

  if ($script:GPU_VENDOR -eq "nvidia" -and -not (Test-GpuArchSupported)) { Set-GpuArchUnsupported $nv[0].Name }
  if ($script:GPU_VENDOR -eq "nvidia") { Confirm-NvidiaDriver }

  # No ROCm training image exists, on any platform: CPU mode, never
  # "use Linux for AMD".
  if ($script:GPU_VENDOR -eq "amd") {
    Warn "tracebloc's GPU training images need an NVIDIA GPU, so the AMD GPU is not set up -- this machine will run in CPU mode."
    Hint "Everything else works on CPU. GPU training needs an NVIDIA GPU (Turing or later) on an x86_64 machine."
    $script:GPU_VENDOR = "amd_unsupported"
  }
}

# =============================================================================
#  4b. The GPU WSL can give the distro (S-W row 13).
#
#  Find-Gpu and Confirm-NvidiaDriver judge the card and its driver against the
#  floors, as on every platform. WSL adds two rules of its own, NVIDIA's CUDA on WSL
#  guide's: it hands a distro a GPU (/dev/dxg) only in the WDDM driver model, never
#  in TCC, and Tesla parts are left out whatever their mode. e2e-test-agent's Windows
#  GPU box holds its runner to the same two (harness/windows_gpu_box.py, unfit).
#  Confirm-NvidiaWslGpu reads each NVIDIA GPU's name and driver model and, only for a
#  GPU the floors let through (ok):
#    - every GPU fit: nothing changes;
#    - some fit, some not: the GPU stays, and the ones WSL leaves out are named;
#    - none fit: the GPU is left out, said, and the platform told
#      (wsl_cannot_see_gpu), as Find-Gpu's own reports are: GPU_VENDOR is
#      nvidia_unsupported and no verdict goes on the core runs' line, so the core
#      takes the host's report (detect-gpu.sh, _gpu_wsl_cannot_see_report);
#    - the driver model cannot be read: cannot tell here, so the GPU stays and the
#      core's own check in the distro decides (nvidia-smi answers there, or the
#      core runs CPU-only, said).
#  The device half is the core's, in the distro: the spec tracebloc-cdi writes at
#  each start, k3s's NVIDIA runtime, and the chart's device plugin (k3s-gpu.sh,
#  _native_k3s_gpu_wsl_prepare).
# =============================================================================

# The one driver model WSL's GPU path supports, and the family it leaves out by name.
$NVIDIA_WSL_DRIVER_MODEL = 'WDDM'
$NVIDIA_WSL_EXCLUDED_FAMILY = 'Tesla'

# Get-NvidiaWslFit -- pure: OUTPUT is nvidia-smi's `--query-gpu=name,driver_model.current
# --format=csv,noheader` answer, one GPU per line. Returns Fit (the names WSL can give
# the distro), Unfit (one @{ Name; Why } per card it cannot) and Read (the lines it
# could parse). Why is a sentence's subject clause, said and told as it is.
function Get-NvidiaWslFit {
  param([string]$Output)
  $fit = @(); $unfit = @(); $read = 0
  foreach ($line in @([string]$Output -split "\r?\n")) {
    $cells = @($line -split ',' | ForEach-Object { $_.Trim() })
    if ($cells.Count -ne 2 -or -not $cells[0]) { continue }
    $read++
    $name = $cells[0]; $model = $cells[1]
    if ($name -cmatch "(^| )$NVIDIA_WSL_EXCLUDED_FAMILY( |$)") {
      $unfit += @{ Name = $name; Why = "it is a $NVIDIA_WSL_EXCLUDED_FAMILY part, which CUDA on WSL does not support" }
    } elseif ($model -cne $NVIDIA_WSL_DRIVER_MODEL) {
      $shown = if ($model) { $model } else { 'unreported' }
      $unfit += @{ Name = $name; Why = "it runs in the $shown driver model, and WSL gives a distro a GPU only in $NVIDIA_WSL_DRIVER_MODEL" }
    } else {
      $fit += $name
    }
  }
  return @{ Fit = $fit; Unfit = $unfit; Read = $read }
}

# Confirm-NvidiaWslGpu -- the rules above, after Find-Gpu (Invoke-WslCore).
function Confirm-NvidiaWslGpu {
  if ($script:GPU_VENDOR -ne 'nvidia' -or $script:GPU_FLOOR_VERDICT -cne 'ok') { return }
  $cmd = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
  $nvSmi = if ($cmd) { $cmd.Source } else { $null }
  if (-not $nvSmi) {
    $found = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Recurse -Filter 'nvidia-smi.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    $nvSmi = if ($found) { $found.FullName } else { $null }
  }
  $r = if ($nvSmi) { Invoke-BoundedProcess -FileName $nvSmi -Arguments @('--query-gpu=name,driver_model.current', '--format=csv,noheader') -TimeoutSec 15 -StdoutOnly } else { $null }
  $fit = if ($r -and $r.Code -eq 0) { Get-NvidiaWslFit -Output ([string]$r.Output) } else { $null }
  if (-not $fit -or $fit.Read -eq 0) {
    $how = if (-not $nvSmi) { 'nvidia-smi.exe was not found' } elseif ($r.Code -ne 0) { "nvidia-smi exited $(Format-ExitCode $r.Code)" } else { 'nvidia-smi named no GPU' }
    Log "WSL GPU check: the driver model could not be read ($how); the distro's own check decides"
    Warn "Couldn't read this NVIDIA GPU's driver model ($how), so it is not known whether WSL can give the tracebloc WSL distro the GPU -- the distro checks for itself, and runs in CPU mode if it cannot see it."
    return
  }
  Log "WSL GPU check: fit '$($fit.Fit -join ', ')'; left out: $(@($fit.Unfit | ForEach-Object { "$($_.Name) ($($_.Why))" }) -join '; ')"
  if (@($fit.Fit).Count -gt 0) {
    foreach ($u in @($fit.Unfit)) { Warn "WSL leaves this NVIDIA GPU out of the tracebloc WSL distro ($($u.Name)): $($u.Why). Training uses the others." }
    return
  }
  $first = @($fit.Unfit)[0]
  $script:GPU_VENDOR = 'nvidia_unsupported'; $script:NVIDIA_DRIVER_OK = $false
  $script:GPU_FLOOR_VERDICT = ''
  $script:GPU_UNSUPPORTED_CODE = "wsl_cannot_see_gpu"
  $script:GPU_UNSUPPORTED_NAME = $first.Name
  $script:GPU_UNSUPPORTED_REASON = "This NVIDIA GPU cannot be used for training on Windows: $($first.Why). So this machine runs on CPU."
  $script:GPU_SKIP_REASON = "WSL cannot give the tracebloc WSL distro this NVIDIA GPU ($($first.Name)): $($first.Why) -- running CPU-only"
  Warn "WSL cannot give the tracebloc WSL distro this NVIDIA GPU ($($first.Name)): $($first.Why) -- this machine will run in CPU mode."
  Hint "GPU training on Windows needs a GeForce or an RTX (Quadro) card in the $NVIDIA_WSL_DRIVER_MODEL driver model. Everything else works on CPU."
}
