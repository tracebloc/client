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
#    $env:K8S_VERSION   = "v1.29.4-k3s1"  default: v1.29.4-k3s1 (pinned + validated; "latest" is UNSUPPORTED — see #547)
#    $env:HOST_DATA_DIR = "C:\data"        default: $env:USERPROFILE\.tracebloc (LOCAL disk; no NFS/UNC)
#    $env:CLIENT_ENV    = "dev"            optional; if not set, CLIENT_ENV is not added to env in values
#    $env:TRACEBLOC_TRAINING_RESOURCES = "cpu=4,memory=16Gi"   optional; overrides the machine-sized training default
# =============================================================================

#Requires -Version 5.1
param([switch]$Help, [switch]$NoReboot, [switch]$Diagnose, [string]$DailyUser, [switch]$Resume)

# --- Self-elevation (#421) ---------------------------------------------------
# Build the powershell.exe argument list to relaunch this installer ELEVATED.
# Run from a .ps1 on disk -> re-run that file; run via the documented one-liner
# (`irm ... | iex`, so there's no file on disk) -> re-fetch and re-run the
# one-liner. Forwards the pass-through switches. Pure (no side effects) so it's
# unit-testable. Env-var config (TRACEBLOC_*) is intentionally NOT forwarded --
# ShellExecute/RunAs doesn't inherit the caller's process env, and putting secrets
# on a command line is unsafe; an env-driven run should be launched elevated.
function Get-ElevationCommand {
  param([string]$ScriptPath, [switch]$NoReboot, [switch]$Diagnose, [string]$DailyUser, [switch]$Resume)
  $switches = @()
  if ($NoReboot)  { $switches += '-NoReboot' }
  if ($Diagnose)  { $switches += '-Diagnose' }
  if ($DailyUser) { $switches += @('-DailyUser', "`"$DailyUser`"") }   # forward the daily user (#418 Bugbot)
  if ($Resume)    { $switches += '-Resume' }                          # forward a resume so a re-elevation stays a continuation (#420)
  # Return a single command-line STRING, not an array: PS 5.1 Start-Process
  # -ArgumentList doesn't quote array elements, so a script path with spaces (or
  # the quoted -Command value) would be split (#421 Bugbot; same class as #419).
  $temp = [System.IO.Path]::GetTempPath()
  if ($ScriptPath -and (Test-Path $ScriptPath) -and ($ScriptPath -notlike "$temp*")) {
    # Durable path: re-run the file (quoted for spaces), forwarding switches. The
    # documented irm|iex flow runs from a bootstrap TEMP dir the un-elevated process
    # deletes on exit, so -File is used ONLY for a non-temp path (#421 Bugbot).
    return (@('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$ScriptPath`"") + $switches) -join ' '
  }
  # Re-fetch the one-liner. Switches are NOT forwarded here: the shim (i.ps1) has no
  # param block to bind them (& ([scriptblock]) -Diagnose would fail on an unknown
  # named parameter), and an `irm | iex` launch can't have set a switch anyway
  # (#421 Bugbot). Keep the exact documented form.
  return '-NoProfile -ExecutionPolicy Bypass -Command "irm https://tracebloc.io/i.ps1 | iex"'
}

# Relaunch elevated through UAC, forwarding the switches. Returns $true when the
# elevated process was started (user accepted UAC), $false if they declined the
# prompt or the launch failed (Start-Process -Verb RunAs throws on cancel).
function Invoke-SelfElevate {
  param([string]$ScriptPath, [switch]$NoReboot, [switch]$Diagnose, [string]$DailyUser, [switch]$Resume)
  $argList = Get-ElevationCommand -ScriptPath $ScriptPath -NoReboot:$NoReboot -Diagnose:$Diagnose -DailyUser $DailyUser -Resume:$Resume
  try {
    Start-Process -FilePath 'powershell' -Verb RunAs -ArgumentList $argList -ErrorAction Stop | Out-Null
    return $true
  } catch { return $false }
}

# -- Admin check --------------------------------------------------------------
# $env:TB_PESTER lets the test suite dot-source this file to load the functions
# without triggering the admin gate (which throws off-Windows) or running main.
if (-not $env:TB_PESTER) {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    # Offer to self-elevate instead of only instructing (#421): a hospital user who
    # pasted into a normal PowerShell shouldn't have to know that "Terminal (Admin)"
    # is a separate thing to open. One consent -> one UAC prompt -> install proceeds.
    $canPrompt = try { [Environment]::UserInteractive -and -not [Console]::IsInputRedirected } catch { $false }
    $elevated  = $false
    if ($canPrompt) {
      Write-Host "  " -NoNewline; Write-Host ([char]0x26A0) -ForegroundColor Yellow -NoNewline; Write-Host "  Administrator rights are required to set up Docker + WSL." -ForegroundColor Yellow
      $ans = Read-Host "  Relaunch as Administrator now? A Windows UAC prompt will appear [Y/n]"
      if ($ans -notmatch '^\s*[Nn]') {
        $elevated = Invoke-SelfElevate -ScriptPath $PSCommandPath -NoReboot:$NoReboot -Diagnose:$Diagnose -DailyUser $DailyUser -Resume:$Resume
        if ($elevated) { Write-Host "  Continuing in the new elevated window -- you can close this one." -ForegroundColor DarkGray }
        else           { Write-Host "  Elevation was cancelled." -ForegroundColor DarkGray }
      }
    }
    if (-not $elevated) {
      # Non-interactive, declined, or the launch failed -> the followable steps (#386).
      # In the documented `irm ... | iex` flow there is no script file to right-click,
      # so "right-click > Run as Administrator" was impossible; give the actual steps.
      Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red -NoNewline; Write-Host " Administrator rights required." -ForegroundColor Red
      Write-Host "  Open an elevated PowerShell: press Win+X and choose 'Terminal (Admin)'" -ForegroundColor DarkGray
      Write-Host "  (or search 'PowerShell' in Start and press Ctrl+Shift+Enter)," -ForegroundColor DarkGray
      Write-Host "  accept the User Account Control prompt, then re-run:" -ForegroundColor DarkGray
      Write-Host "    irm https://tracebloc.io/i.ps1 | iex" -ForegroundColor Cyan
      exit 1
    }
    exit 0
  }

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# =============================================================================
#  HELPERS — logging functions matching bash UX
# =============================================================================

function Info($m)          { Write-Host "  " -NoNewline; Write-Host ([char]0x00B7) -ForegroundColor DarkGray -NoNewline; Write-Host " $m" -ForegroundColor DarkGray; Log $m }
function Ok($m)            { Write-Host "  " -NoNewline; Write-Host ([char]0x2714) -ForegroundColor Green -NoNewline; Write-Host " $m"; Log "OK: $m" }
function Warn($m)          { Write-Host "  " -NoNewline; Write-Host ([char]0x26A0) -ForegroundColor Yellow -NoNewline; Write-Host "  $m" -ForegroundColor Yellow; Log "WARN: $m" }
# Build the trailing lines every fatal error shows (#423): a short excerpt of the
# real tool output (last few non-empty lines — the actual reason, not a generic
# line), then the log path and the -Diagnose support-bundle hint as first-class
# next steps. Pure (no host writes / no exit) so it is unit-testable.
function Get-ErrDetailLines([string]$Detail) {
  $out = @()
  if ($Detail) {
    # Drop PowerShell 5.1 ErrorRecord "chrome" that `native 2>&1 | Out-String`
    # wraps around stderr (the `At <file>:<n> char:<n>` position line and the
    # `+ ...` / `+ CategoryInfo` / `+ FullyQualifiedErrorId` block). Otherwise a
    # helm failure's last 5 lines are all chrome and the real `Error:` line is
    # crowded out of the excerpt (#423 Bugbot).
    $lines = @($Detail -split "`r?`n" |
      ForEach-Object { $_.TrimEnd() } |
      Where-Object {
        $_ -ne "" -and
        $_ -notmatch '^\s*At [^ ]+:\d+ char:\d+' -and
        $_ -notmatch '^\s*\+ '
      } |
      Select-Object -Last 5)
    if ($lines.Count) { $out += "--- details ---"; $out += $lines }
  }
  if ($script:LOG_FILE) { $out += "Full log: $script:LOG_FILE" }
  $out += "Support bundle: re-run with -Diagnose"
  return $out
}

# $Detail (optional) is captured tool output (e.g. k3d/helm stderr); its last few
# non-empty lines are surfaced on screen so the real reason isn't buried in the
# log (#423). Every failure names the log path + -Diagnose regardless.
function Err($m, $Detail)  {
  Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red -NoNewline; Write-Host " $m" -ForegroundColor Red
  # @(...) forces array enumeration: a single-line result unwraps to a scalar
  # string, and enumerating that explicitly keeps each line intact (defensive —
  # the `foreach` statement already iterates a scalar once, not per-char).
  $det = @(Get-ErrDetailLines $Detail)
  foreach ($l in $det) { Write-Host "  $l" -ForegroundColor DarkGray }
  # Mirror to the curated log too (#576) — Get-ErrDetailLines already strips the
  # `At <file>:<line> char:` / `+ …` source-dump lines, so nothing internal leaks.
  Log "ERROR: $m"; foreach ($l in $det) { Log $l }
  $script:OutcomeReported = $true   # Err IS a reported outcome (guards the finally)
  exit 1
}
function Step($n, $t, $l)  { Write-Host ""; Write-Host "Step $n/$t" -ForegroundColor Cyan -NoNewline; Write-Host "  $l" -ForegroundColor White; Log "== Step $n/$t : $l ==" }
function Log($m)           { if ($script:LOG_FILE) { Add-Content -Path $script:LOG_FILE -Value "[$(Get-Date -Format 'HH:mm:ss')] $m" -ErrorAction SilentlyContinue } }
function PromptHeader($m)  { Write-Host ""; Write-Host "  $m" -ForegroundColor White; Log $m }
function Hint($m)          { Write-Host "  $m" -ForegroundColor DarkGray; Log $m }
function Has($cmd)         { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# Top-level fatal handler (#577): convert ANY unhandled terminating error into a
# clean, branded message — never PowerShell's raw source line + stack trace — then
# the caller exits non-zero. The reason shown is the exception MESSAGE (curated at
# the throw sites, #576); the stack trace is deliberately NOT shown or logged, so
# no tracebloc internals leak. The user always sees what happened + what to do.
function Show-FatalError($err) {
  $script:OutcomeReported = $true   # this IS the reported outcome (guards the finally)
  $reason = ""
  try { $reason = [string]$err.Exception.Message } catch {}
  if (-not $reason) { $reason = [string]$err }
  Log "FATAL: $reason"
  Write-Host ""
  Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red -NoNewline; Write-Host " Installation stopped." -ForegroundColor Red
  if ($reason) { Write-Host "  $reason" -ForegroundColor DarkGray }
  if ($script:LOG_FILE) { Hint "Details saved to: $script:LOG_FILE" }
  Hint "It's safe to re-run this installer. If it keeps failing, send that log to tracebloc support."
}

# The guaranteed finally's closer (#577): fires ONLY when the run ended without
# reporting an outcome — i.e. an interruption (Ctrl-C) or an abnormal termination
# that wasn't a handled Err, a caught crash, or a normal finish — so the window
# never just vanishes. Mirrors bash's exit-code-guarded install_cleanup.
function Show-Interrupted {
  Log "Installation interrupted before completion."
  Write-Host ""
  Write-Host "  " -NoNewline; Write-Host ([char]0x26A0) -ForegroundColor Yellow -NoNewline; Write-Host "  Installation was interrupted before it finished." -ForegroundColor Yellow
  if ($script:LOG_FILE) { Hint "Log: $script:LOG_FILE" }
  Hint "It's safe to re-run this installer."
}

function RefreshPath {
  $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
              [System.Environment]::GetEnvironmentVariable("PATH","User")
}

# Shared braille spinner frames for the progress helpers below.
$script:SpinnerFrames = @([char]0x2807, [char]0x2819, [char]0x2839, [char]0x2838, [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827, [char]0x2847, [char]0x280F)

# Spin a braille spinner while a process runs, bounded by a deadline (#426):
# `k3d cluster create --wait` has no timeout of its own, so a stalled image
# pull would otherwise spin forever. Returns $true when the process exited on
# its own, $false on deadline expiry (the process is killed best-effort).
# Extracted as a function so the deadline/kill path is unit-testable (#412).
function Wait-ProcessWithDeadline {
  param([object]$Process, [datetime]$Deadline, [string]$Message)
  $frames = $script:SpinnerFrames
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

# Run a tracked install PROCESS with its stdout+stderr captured to temp files, wait
# with a KILLING deadline (spinner via Wait-ProcessWithDeadline), fold any captured
# output into the install log, and return the outcome. Mirrors the WSL / k3d-cluster-
# start redirect pattern so a failed install leaves the real winget/installer output
# in the log + -Diagnose bundle instead of only a bare exit code (#500). Never throws;
# each caller applies its own policy (best-effort fall-through vs fatal Err).
# Returns @{ State = 'ok'|'spawn-failed'|'timeout'|'failed'; ExitCode; Output }.
function Invoke-TrackedInstall {
  param(
    [string]$FilePath,
    $ArgumentList,                 # string (PS 5.1 verbatim) or array
    [string]$Label,
    [int]$TimeoutMinutes = 40,
    [string]$Tag = 'install'
  )
  $tmp  = [System.IO.Path]::GetTempPath()   # portable (== %TEMP% on Windows); testable off-Windows
  $outF = Join-Path $tmp "$Tag-$(Get-Random).out.log"
  $errF = Join-Path $tmp "$Tag-$(Get-Random).err.log"
  $p = $null
  try {
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru -ErrorAction Stop `
      -RedirectStandardOutput $outF -RedirectStandardError $errF
  } catch {
    Remove-Item $outF, $errF -Force -ErrorAction SilentlyContinue
    Log "$Label wouldn't start: $_"
    return @{ State = 'spawn-failed'; ExitCode = $null; Output = "$_" }
  }
  $timedOut = -not (Wait-ProcessWithDeadline -Process $p -Deadline (Get-Date).AddMinutes($TimeoutMinutes) -Message $Label)
  # stderr first, then stdout (matches the #423 failure-output ordering).
  $log = ("$(Get-Content $errF -Raw -ErrorAction SilentlyContinue)`n$(Get-Content $outF -Raw -ErrorAction SilentlyContinue)").Trim()
  Remove-Item $outF, $errF -Force -ErrorAction SilentlyContinue
  if ($log) { Log "${Label}: $log" }
  if ($timedOut)          { return @{ State = 'timeout';  ExitCode = $null;        Output = $log } }
  if ($p.ExitCode -eq 0)  { return @{ State = 'ok';       ExitCode = 0;            Output = $log } }
  return @{ State = 'failed'; ExitCode = $p.ExitCode; Output = $log }
}

# Wait on a background job with a visible heartbeat so a long step never leaves
# the console silent for more than a couple of seconds (#415). Prints a spinner +
# elapsed/timeout line while the job runs; returns $true if the job finished
# before the deadline, $false on timeout (the job is stopped best-effort; the
# caller still owns Remove-Job). Extracted so the progress/timeout contract is
# unit-testable without a real slow job.
function Wait-JobWithProgress {
  param(
    [Parameter(Mandatory)] $Job,
    [int]$TimeoutSec = 180,
    [string]$Message = "Working",
    [int]$PollSeconds = 2
  )
  $frames = $script:SpinnerFrames
  $f = 0; $elapsed = 0
  while ($Job.State -eq "Running" -and $elapsed -lt $TimeoutSec) {
    Write-Host "`r  " -NoNewline
    Write-Host $frames[$f] -ForegroundColor Cyan -NoNewline
    Write-Host " $Message ... ${elapsed}s / ${TimeoutSec}s" -NoNewline
    $f = ($f + 1) % $frames.Count
    Start-Sleep -Seconds $PollSeconds
    $elapsed += $PollSeconds
  }
  Write-Host "`r                                                                      `r" -NoNewline
  if ($Job.State -eq "Running") {
    Stop-Job $Job -ErrorAction SilentlyContinue
    return $false
  }
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
$script:JobInit = {
  if ($env:SystemRoot) { Set-Location $env:SystemRoot }
  # Job runspaces don't inherit the parent's TLS floor (set once at script top).
  # Windows PowerShell 5.1 still defaults to TLS 1.0/1.1, which many corporate
  # proxies and CDNs reject — so in-job HTTPS downloads (kubectl/k3d/helm/winget/
  # Docker Desktop via Invoke-WithHeartbeat) would fail SSL/TLS without this
  # (#422 Bugbot). Re-apply TLS 1.2 (OR-in, don't clobber a higher floor).
  try {
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  } catch {}
  # Same story for the progress overlay: a fresh runspace resets
  # $ProgressPreference to 'Continue', so the parent's silence (Invoke-WithRetry,
  # the bootstrap's fetch helpers) is NOT inherited. On Windows PowerShell 5.1
  # that overlay's render loop dominates an Invoke-WebRequest transfer -- the
  # #468/#471 throttle -- and every in-job download goes through
  # Invoke-WithHeartbeat, so silencing it belongs HERE, once, rather than in
  # each caller's scriptblock where a new call site can forget it (Bugbot,
  # client#515). Callers may still set it locally; this is the floor.
  $ProgressPreference = 'SilentlyContinue'
}

# One honest line per system tool once it's ready (#422): name, version, and
# whatever of {size, elapsed} is known — so "Installing system tools" shows
# concrete per-tool progress instead of a silent ~700 MB. Pure/formatting-only
# so it is unit-testable. e.g. "kubectl v1.31.0 (~60 MB, 12s)".
function Get-ToolSummaryLine {
  param([string]$Name, [string]$Version = "", [string]$Size = "", [int]$ElapsedSec = -1)
  $head = if ($Version) { "$Name $Version" } else { "$Name" }
  $meta = @()
  if ($Size)          { $meta += $Size }
  if ($ElapsedSec -ge 0) { $meta += ("{0}s" -f $ElapsedSec) }
  if ($meta.Count)    { return "$head (" + ($meta -join ", ") + ")" }
  return $head
}

# Run a blocking operation with a live spinner heartbeat so Steps 1-2 never sit
# console-silent for more than a couple of seconds (#422): downloads (progress
# overlay is off for speed, #471), winget installs, and the Docker Desktop
# installer are otherwise dead air. The scriptblock runs in a background job
# (jobs don't inherit functions/vars — pass inputs via -ArgumentList) driven by
# Wait-JobWithProgress. Returns the job's output; throws on timeout or job
# failure so callers keep their existing Invoke-WithRetry / try-catch flow.
function Invoke-WithHeartbeat {
  param(
    [Parameter(Mandatory)][scriptblock]$Script,
    [object[]]$ArgumentList = @(),
    [string]$Message = "Working",
    [int]$TimeoutSec = 1800,
    [int]$PollSeconds = 2
  )
  $job = Start-Job -ScriptBlock $Script -ArgumentList $ArgumentList -InitializationScript $script:JobInit
  $finished = Wait-JobWithProgress -Job $job -TimeoutSec $TimeoutSec -Message $Message -PollSeconds $PollSeconds
  # Capture BOTH output and error records (2>&1) so a failure's real detail
  # (e.g. the k3d/installer error the scriptblock threw) can be surfaced, not
  # swallowed (#422 Bugbot). The job's terminating exception is the most reliable
  # source of the reason.
  $out    = @(Receive-Job $job -ErrorAction SilentlyContinue 2>&1)
  $state  = $job.State
  $reason = $null
  try { $reason = $job.ChildJobs[0].JobStateInfo.Reason.Message } catch {}
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  if (-not $finished) { throw "Timed out after ${TimeoutSec}s while: ${Message}" }
  if ($state -eq 'Failed') {
    $detail = if ($reason) { "$reason" } else { ("$($out -join "`n")").Trim() }
    throw ("Failed while: ${Message}" + $(if ($detail) { " -- $detail" } else { "" }))
  }
  return $out
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
  # PS 5.1's progress overlay throttles Invoke-WebRequest massively (its render
  # loop dominates the transfer) and its "Writing request stream" banner reads
  # like a hang (#468; same fix as the bootstrap's fetch helpers). Function-local
  # assignment -- PowerShell's dynamic scoping makes every fetch $ScriptBlock
  # invoked below see it, and the preference reverts when this function returns.
  $ProgressPreference = 'SilentlyContinue'
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

# Execute-gate a freshly-installed tool (#411). The old post-install "check" was a
# Log interpolation whose failure is non-terminating, so a corrupt or wrong-arch
# binary (winget shims / partial installs skip the direct path's checksum verify)
# still reached "System tools" and only died at cluster-create. Actually RUN the
# tool's self-check; on failure Err with an arch-aware remedy so Step 1 fails
# loudly. NOTE: kubectl uses `version --client` (NOT --short — removed in 1.28+);
# helm uses bare `version` (--short may go the same way).
#
# -BinPath is our own install location. On failure we remove it ONLY when the
# binary that actually ran resolves to it — so a broken copy WE placed (fresh or
# left by a prior run) self-heals on re-run, while a winget/choco/pre-existing copy
# elsewhere on PATH is never deleted (reviewer + Bugbot). Callers may pass -BinPath
# on every path; the resolved-source guard sorts out ownership.
function Assert-ToolRuns {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string[]]$VersionArgs,
    [string]$BinPath
  )
  $ok = $false; $out = $null
  try {
    $out = (& $Name @VersionArgs 2>&1)
    $ok  = ($LASTEXITCODE -eq 0)
  } catch { $ok = $false }
  if (-not $ok) {
    if ($BinPath -and (Test-Path $BinPath)) {
      $resolved = (Get-Command $Name -ErrorAction SilentlyContinue).Source
      if ($resolved -and ($resolved -eq $BinPath)) { Remove-Item $BinPath -Force -ErrorAction SilentlyContinue }
    }
    $arch = Get-WindowsArch
    Err "$Name was installed but won't run -- a corrupt or wrong-architecture binary (this machine is $arch). Re-run this script to re-download it; if it recurs, remove any $Name installed via a package manager (winget/choco) first, then re-run."
  }
  Log "$Name OK: $(($out | Select-Object -First 1))"
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
  .\install-k8s.ps1 [-Help] [-NoReboot] [-Resume]

Advanced configuration (environment variables):
  CLUSTER_NAME   Cluster name                   (default: tracebloc)
  SERVERS        Control-plane nodes             (default: 1)
  AGENTS         Worker nodes                    (default: 1)
  K8S_VERSION    k3s image tag                   (default: v1.29.4-k3s1)
  -NoReboot      Skip reboot prompt after enabling Windows features
  -Resume        Continue an install interrupted by a reboot (set automatically
                 by the registered RunOnce continuation; rarely needed by hand)
  HOST_DATA_DIR  Persistent data directory       (default: ~\.tracebloc)
  TRACEBLOC_CA_BUNDLE  Corporate CA bundle (PEM) to trust on a TLS-inspecting
                 network, so in-cluster image pulls don't fail x509 (#424).
                 CURL_CA_BUNDLE is also honored.

Reinstalling on a machine that still holds data:
  A new install won't silently adopt data left under HOST_DATA_DIR (both the
  flat and per-release layouts) -- it stops and asks reuse / wipe / different dir.
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
  # Curated, PII-free log (#576). We deliberately DO NOT use Start-Transcript: its
  # fixed header records Username / RunAs / Machine / PID (a real client's shared
  # log leaked their Windows identity), and it also captures PowerShell's raw error
  # rendering — source lines, internal identifiers. Instead the message helpers
  # (Info/Ok/Warn/Err/Step/…) route through Log(), so the log mirrors the curated
  # on-screen output: no user PII, no tracebloc internals. Best-effort — if the
  # file can't be created, logging silently no-ops and the install continues.
  try {
    Set-Content -Path $LOG_FILE -Value "tracebloc client installer log - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ErrorAction Stop
    Log "Install log: $LOG_FILE"
  } catch {
    $script:LOG_FILE = $null
  }
}

# =============================================================================
#  INSTALL STATE + RESUME-AFTER-REBOOT (#420)
#  Two legitimate reboots (Windows feature enablement; Docker/WSL first boot) can
#  interrupt the install. Instead of "re-find and re-paste the one-liner", we:
#   - record a schema-versioned `completed` flag in a JSON state file under
#     %USERPROFILE%\.tracebloc\ (set only when the client is actually connected), and
#   - on a reboot, register a RunOnce continuation that resumes automatically at
#     next sign-in (-Resume).
#  The state is ADVISORY: the fast path still verifies the tools + a RUNNING cluster
#  before it claims "nothing to do", so a stale flag can never skip real work.
# =============================================================================

$script:STATE_SCHEMA = 1
$script:RESUME_ROOT   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$script:RESUME_NAME   = 'TraceblocInstallerResume'

# --- Pure state helpers (no I/O; unit-testable) ------------------------------
# The state records only `completed` -- what actually drives behavior. Per-stage
# checkpoints were dropped (reviewer): the six steps set shared $script: state that
# downstream steps need, so a resume must re-walk them; speed on re-run comes from
# each step's own self-skip (tools present, WSL current, cluster running), not from
# skipping the call. `completed` alone arms the nothing-to-do fast path.

# A fresh state at the current schema.
function New-InstallState {
  return [pscustomobject]@{ schema = $script:STATE_SCHEMA; completed = $false }
}

# Is a parsed state usable by THIS installer (schema matches)? A future/older or
# malformed schema is treated as absent so we never act on an incompatible file.
function Test-InstallStateCurrent {
  param($State)
  return ($null -ne $State -and
          ($State.PSObject.Properties.Name -contains 'schema') -and
          ([int]$State.schema -eq $script:STATE_SCHEMA))
}

# Parse a state JSON string -> normalised state object. Corrupt/incompatible/empty
# -> a fresh state, NEVER a throw (a broken checkpoint must not break the install).
function ConvertTo-InstallState {
  param([string]$Json)
  if ([string]::IsNullOrWhiteSpace($Json)) { return (New-InstallState) }
  try { $obj = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return (New-InstallState) }
  if (-not (Test-InstallStateCurrent -State $obj)) { return (New-InstallState) }
  $completed = $false
  if ($obj.PSObject.Properties.Name -contains 'completed') { $completed = [bool]$obj.completed }
  return [pscustomobject]@{ schema = [int]$obj.schema; completed = $completed }
}

# --- State-file I/O (thin wrappers over the pure helpers) --------------------

function Get-InstallStatePath { return (Join-Path $HOST_DATA_DIR 'install-state.json') }

# Read + parse the on-disk state; missing/unreadable/corrupt -> fresh state.
function Read-InstallState {
  $path = Get-InstallStatePath
  if (-not (Test-Path -LiteralPath $path)) { return (New-InstallState) }
  try { return (ConvertTo-InstallState -Json (Get-Content -LiteralPath $path -Raw -ErrorAction Stop)) }
  catch { return (New-InstallState) }
}

# Persist state. Warn-only: a failed write must never fail the install.
function Save-InstallState {
  param($State)
  try {
    if (-not (Test-Path $HOST_DATA_DIR)) { New-Item -ItemType Directory -Path $HOST_DATA_DIR -Force | Out-Null }
    ($State | ConvertTo-Json -Compress) | Set-Content -Path (Get-InstallStatePath) -Encoding ASCII -ErrorAction Stop
  } catch { Log "install-state write failed: $_" }
}

# Mark the whole install completed + persist (so a later re-run detects nothing-to-do).
function Set-InstallComplete {
  Save-InstallState -State ([pscustomobject]@{ schema = $script:STATE_SCHEMA; completed = $true })
}

# Clear the completed flag (persist not-completed) -- called when a walk ends without
# a connected client, so a stale `completed` from an earlier success can't keep the
# fast path armed over a now-broken install (#420 reviewer).
function Clear-InstallCompleted {
  Save-InstallState -State (New-InstallState)
}

# Did the client actually come UP? Only `connected` (all workloads Ready) proves the
# install is done. `starting` is Get-NotReadyState's catch-all for a client that
# isn't Ready yet (Pending pods / a slow pull) -- treating it as done would arm the
# fast path for a client that never came up, skipping the remediation (reviewer).
# This gates the completion checkpoint; the exit code is deliberately more lenient.
function Test-InstallConnected {
  return ($script:ClientState -eq "connected")
}

# Is the exit code a success? connected (up) or starting (on its way) both avoid a
# hard error exit; anything else (bad_creds/crash/image_pull/...) is a non-zero
# failure. Deliberately more lenient than Test-InstallConnected: a still-starting
# client shouldn't hard-fail the run, but it also must not be marked complete.
function Test-InstallSucceeded {
  return ($script:ClientState -eq "connected" -or $script:ClientState -eq "starting")
}

# --- Fast-path health probes (honest "nothing to do", not just a checkpoint) --

# Are all four client tools on PATH? Cheap; used to gate the nothing-to-do path.
function Test-ToolsPresent {
  foreach ($t in @('docker','kubectl','k3d','helm')) { if (-not (Has $t)) { return $false } }
  return $true
}

# Pure: from `k3d cluster list -o json` output, is <Name> present AND running (>=1
# server node up)? A present-but-STOPPED cluster returns $false so the fast path
# doesn't skip New-K3dCluster's start/repair. Unknown/corrupt shape -> false (#420 Bugbot).
function Test-ClusterRunningInList {
  param([string]$Json, [string]$Name)
  if ([string]::IsNullOrWhiteSpace($Json)) { return $false }
  try { $clusters = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
  foreach ($c in @($clusters)) {
    if ($c.name -ne $Name) { continue }
    if ($c.PSObject.Properties.Name -contains 'serversRunning') { return ([int]$c.serversRunning -ge 1) }
    return $false   # shape without a running count can't prove the cluster is up
  }
  return $false
}

# Is our k3d cluster present AND running? STATE query, BOUNDED via a job+deadline so a
# wedged Docker engine can't hang the fast path at the start of every re-run (#420
# Bugbot). Never-fatal: a timeout / parse failure -> $false (fall through to the walk).
function Test-ClusterRunning {
  $job = Start-Job -InitializationScript $JobInit -ScriptBlock {
    param($n) (k3d cluster list $n -o json 2>$null | Out-String)
  } -ArgumentList $CLUSTER_NAME
  $out = ""
  if (Wait-JobWithProgress -Job $job -TimeoutSec 15 -Message "Checking cluster") {
    $out = (Receive-Job $job -ErrorAction SilentlyContinue | Out-String)
  } else {
    Log "k3d cluster list timed out; treating cluster as not running."
  }
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  return (Test-ClusterRunningInList -Json $out -Name $CLUSTER_NAME)
}

# The client's three workload deployments in a namespace. Single source of truth for
# both the readiness gate and the fast-path health check (#420).
function Get-ClientDeploymentNames {
  param([string]$Namespace)
  return @("mysql-client", "$Namespace-jobs-manager", "$Namespace-requests-proxy")
}

# Is a previously-installed client actually HEALTHY right now? The fast path must not
# claim "nothing to do" over a running cluster whose client workloads are down (the
# bash assess path requires Ready workloads too). Finds the installed release's
# namespace via Get-InstalledClientInfo (bounded), then checks each client deployment
# with a SHORT rollout deadline -- if any isn't Ready (or the release can't be found),
# return $false so the run falls through to the repairing walk (#420 Bugbot).
function Test-ClientHealthy {
  $info = Get-InstalledClientInfo
  if ($info.ListUnknown -or -not $info.Ns) { return $false }
  foreach ($d in (Get-ClientDeploymentNames -Namespace $info.Ns)) {
    & kubectl rollout status "deployment/$d" -n $info.Ns --timeout=5s 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
  }
  return $true
}

# --- Resume-after-reboot (RunOnce) -------------------------------------------

# Pure: the RunOnce command line that resumes the install after a reboot. Reuses
# the elevation arg-builder (#421) and adds -Resume so the resumed run auto-continues
# past the reboot prompt. Prefixed with the powershell.exe host that RunOnce needs.
function Get-ResumeCommand {
  param([string]$ScriptPath, [switch]$NoReboot, [switch]$Diagnose, [string]$DailyUser)
  $inner = Get-ElevationCommand -ScriptPath $ScriptPath -NoReboot:$NoReboot -Diagnose:$Diagnose -DailyUser $DailyUser
  # Only the durable -File form can carry -Resume; the irm|iex shim has no param
  # block to bind it (#421), and appending it would sit past -Command's value. The
  # state file (completed/stages) drives the resume for the one-liner path anyway (#420).
  if ($inner -match '(^|\s)-File\s') { $inner = "$inner -Resume" }
  return "powershell.exe $inner"
}

# Register the RunOnce continuation. Warn-only. Returns $true on success.
function Register-ResumeAfterReboot {
  param([string]$ScriptPath, [switch]$NoReboot, [switch]$Diagnose, [string]$DailyUser)
  try {
    if (-not (Test-Path $script:RESUME_ROOT)) { New-Item -Path $script:RESUME_ROOT -Force | Out-Null }
    $cmd = Get-ResumeCommand -ScriptPath $ScriptPath -NoReboot:$NoReboot -Diagnose:$Diagnose -DailyUser $DailyUser
    New-ItemProperty -Path $script:RESUME_ROOT -Name $script:RESUME_NAME -Value $cmd -PropertyType String -Force -ErrorAction Stop | Out-Null
    Log "Registered resume-after-reboot: $cmd"
    return $true
  } catch { Log "resume registration failed: $_"; return $false }
}

# Remove the RunOnce continuation. RunOnce self-deletes once it fires, but clear it
# explicitly on the success path (no reboot happened) and after a manual re-run so a
# stale entry can never relaunch the installer unexpectedly.
function Unregister-ResumeAfterReboot {
  try {
    if (Test-Path $script:RESUME_ROOT) {
      Remove-ItemProperty -Path $script:RESUME_ROOT -Name $script:RESUME_NAME -ErrorAction SilentlyContinue
    }
  } catch { Log "resume unregister failed: $_" }
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
  # Announce the log path up front (#423) — if anything fails, the user already
  # knows where the full transcript is instead of hunting for a file support can't
  # name. Was previously written only inside the log itself.
  if ($script:LOG_FILE) { Hint "Install log: $script:LOG_FILE" }
  Write-Host ""
  Log "Cluster='$CLUSTER_NAME'  Servers=$SERVERS  Agents=$AGENTS"
  Log "Host data dir: $HOST_DATA_DIR"
}

# Single source of truth for the install's top-level steps (#500): the up-front
# roadmap AND every "Step N/total" header derive their total from this list, so the
# roadmap can't silently fall out of sync with the runtime step count again (the
# earlier roadmap listed 5 while the runtime ran 6, mis-numbering every later step).
$script:INSTALL_STEPS = @(
  'Check system requirements'
  'Install system tools'
  'Set up secure compute environment'
  'Install the tracebloc CLI'
  'Register this machine'
  'Install tracebloc client'
)

function Print-Roadmap {
  Write-Host "  Steps" -ForegroundColor White
  Hint ([string]([char]0x2500) * 5)
  for ($i = 0; $i -lt $script:INSTALL_STEPS.Count; $i++) {
    Hint ("{0}. {1}" -f ($i + 1), $script:INSTALL_STEPS[$i])
  }
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

# Enable ONE Windows optional feature; returns $true only when the feature was
# newly enabled (i.e. a reboot is now pending for it). DISM splashes a raw
# COMException when a feature package simply doesn't exist on the running
# edition (Server SKUs have no Microsoft-Hyper-V-All package) -- alarming red
# noise on an otherwise honest flow, and the old code ALSO demanded a reboot
# for a feature that never got enabled, sending those users into a reboot ->
# re-run -> same-error loop (#468). Translate instead: name the real situation,
# and only report reboot-pending on an actual state change.
function Enable-OneVirtFeature {
  param(
    [string]$Key,           # DISM feature name, e.g. Microsoft-Hyper-V-All
    [string]$Label,          # human name for messages, e.g. Hyper-V
    $CurrentState,           # .State from Get-WindowsOptionalFeature ($null = package absent)
    [string]$Edition         # OS caption, for the not-available message
  )
  if ($CurrentState -eq "Enabled") {
    Log "$Label already enabled."
    return $false
  }
  Log "Enabling $Label..."
  try {
    Enable-WindowsOptionalFeature -Online -FeatureName $Key -NoRestart -ErrorAction Stop | Out-Null
    return $true
  } catch {
    if ($null -eq $CurrentState) {
      Warn "$Label is not available on this Windows edition ($Edition) -- skipping."
    } else {
      Warn "Could not enable ${Label}: $($_.Exception.Message)"
      Hint "Enable '$Key' manually (Windows Features / optionalfeatures.exe), then re-run this script."
    }
    return $false
  }
}

# Modern (Store or standalone) WSL prints a version block from `wsl --version`;
# legacy/absent WSL errors or prints nothing. Returns $true when WSL is already
# installed and current enough that no update is needed (#414). Takes the command
# output as a parameter so it's unit-testable without WSL present.
#
# True only when WSL is present AND at least $MinVersion -- not merely present.
# `wsl --version` localizes its labels (Japanese "WSL バージョン:"), so match the
# version NUMBER, not the "WSL version:" label. The FIRST dotted version in the
# block is the WSL version (kernel/WSLg follow); require it to meet a floor so a
# STALE modern WSL (e.g. 2.0.x) still updates instead of being green-OK'd forever
# (#414 reviewer -- matching any dotted number was effectively Test-WslPresent).
# The floor is Docker Desktop's documented WSL minimum (2.1.5): below it, Docker
# Desktop prompts to update WSL, the exact symptom this avoids (#414 Bugbot).
# TB_WSL_MIN_VERSION overrides it.
function Test-WslCurrent {
  param(
    [string]$VersionOutput,
    [string]$MinVersion = $(if ($env:TB_WSL_MIN_VERSION) { $env:TB_WSL_MIN_VERSION } else { "2.1.5" })
  )
  $m = [regex]::Match($VersionOutput, '\d+\.\d+\.\d+(\.\d+)?')
  if (-not $m.Success) { return $false }
  try { return ([version]$m.Value -ge [version]$MinVersion) } catch { return $false }
}

# `wsl --version` can hang on a wedged LxssManager (plausible on the same corporate
# boxes this targets), so run it BOUNDED as a job (like the wsl --list reader) and
# return "" on timeout so skip-when-current treats WSL as not-current and the update
# still runs (#414 reviewer). Encoding is set to Unicode inside the job (wsl.exe
# writes UTF-16LE); the restore is wrapped so a throw there can't kill the install.
function Get-WslVersionOutput {
  $job = Start-Job -InitializationScript $JobInit -ScriptBlock {
    $prev = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.Encoding]::Unicode; (wsl --version 2>$null | Out-String) }
    finally { try { [Console]::OutputEncoding = $prev } catch {} }
  }
  $out = ""
  if (Wait-JobWithProgress -Job $job -TimeoutSec 20 -Message "Checking WSL") {
    $out = (Receive-Job $job -ErrorAction SilentlyContinue | Out-String)
  } else {
    Log "wsl --version timed out; treating WSL as not current."
  }
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  return $out
}

# Run `wsl --update [ExtraArgs]` as a tracked process with a deadline, redirecting
# its output to temp files (logged -- so a failure leaves real WSL evidence in the
# log and the -Diagnose bundle, and wsl's \r progress doesn't fight the spinner),
# and classify the outcome: ok / not-found (spawn failed) / timeout / failed (#414
# reviewer). Returns @{ State; ExitCode }.
function Invoke-WslUpdate {
  param([string[]]$ExtraArgs = @())
  $wslArgs = @("--update") + $ExtraArgs
  $label   = if ($ExtraArgs -contains "--web-download") { "Updating WSL (web download, bypassing the Store)" } else { "Updating WSL" }
  $outF = Join-Path $env:TEMP "wsl-update-$(Get-Random).out.log"
  $errF = Join-Path $env:TEMP "wsl-update-$(Get-Random).err.log"
  Info "$label..."
  $p = $null
  try {
    $p = Start-Process -FilePath "wsl" -ArgumentList $wslArgs -NoNewWindow -PassThru -ErrorAction Stop `
      -RedirectStandardOutput $outF -RedirectStandardError $errF
  } catch {
    Remove-Item $outF, $errF -Force -ErrorAction SilentlyContinue
    Log "wsl $($wslArgs -join ' ') wouldn't start: $_"
    return @{ State = 'not-found'; ExitCode = $null }
  }
  $timedOut = -not (Wait-ProcessWithDeadline -Process $p -Deadline (Get-Date).AddMinutes(5) -Message $label)
  $log = ("$(Get-Content $errF -Raw -ErrorAction SilentlyContinue)`n$(Get-Content $outF -Raw -ErrorAction SilentlyContinue)").Trim()
  Remove-Item $outF, $errF -Force -ErrorAction SilentlyContinue
  if ($log) { Log "wsl $($wslArgs -join ' '): $log" }
  if ($timedOut) { return @{ State = 'timeout'; ExitCode = $null } }
  if ($p.ExitCode -eq 0) { return @{ State = 'ok'; ExitCode = 0 } }
  return @{ State = 'failed'; ExitCode = $p.ExitCode }
}

# Update WSL in a way that survives Store-blocked corporate networks (#414):
#  1. Skip when already current (bounded probe + version floor; fast <2s re-runs).
#  2. Prefer `wsl --update --web-download` (Microsoft's servers, not the Store).
#  3. If that exits non-zero (e.g. an unpatched wsl.exe that rejects --web-download),
#     retry plain `wsl --update` (Store path) once before giving up.
#  4. On failure, name the specific cause + the exact manual MSI step ON SCREEN.
# We deliberately do NOT auto-download the GitHub-releases MSI: that needs
# api.github.com (asset name unresolvable API-free), which #410 forbids.
function Update-Wsl {
  if (Test-WslCurrent -VersionOutput (Get-WslVersionOutput)) {
    Ok "WSL is current"
    return
  }

  $r = Invoke-WslUpdate -ExtraArgs @("--web-download")
  if ($r.State -eq 'ok') { Ok "WSL updated"; return }
  # Two-rung ladder: --web-download is only understood by a serviced wsl.exe; an
  # unpatched box rejects it and exits non-zero fast, where plain --update works
  # (#414 reviewer). Only retry on a real exit (not timeout / missing wsl.exe).
  if ($r.State -eq 'failed') {
    $r2 = Invoke-WslUpdate -ExtraArgs @()
    if ($r2.State -eq 'ok') { Ok "WSL updated"; return }
    $r = $r2
  }

  # Differentiated failure -- "the Store may be blocked" is the one cause
  # --web-download rules out, so don't say it (#414 reviewer).
  switch ($r.State) {
    'not-found' { Warn "Couldn't update WSL: wsl.exe wasn't found." }
    'timeout'   { Warn "Updating WSL timed out and was stopped." }
    default     { Warn "Couldn't update WSL automatically (wsl exited $($r.ExitCode))." }
  }
  $msiArch = if ((Get-WindowsArch) -eq 'arm64') { 'arm64' } else { 'x64' }
  Hint "Download the latest WSL MSI (wsl.<version>.$msiArch.msi) from https://github.com/microsoft/WSL/releases, run it, then re-run this installer -- otherwise Docker Desktop will prompt you to install WSL."
}

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
    if (Enable-OneVirtFeature -Key $_.Key -Label $_.Value -CurrentState $state -Edition $edition) {
      $rebootNeeded = $true
    }
  }

  if ($rebootNeeded) {
    Warn "A reboot is required to finish enabling system features."
    # A reboot-pending stop IS a reported outcome (Bugbot): the guidance below tells
    # the user exactly what happens next. Set the flag so the top-level finally does
    # not then append a contradictory "interrupted" line. Covers every exit from this
    # block (both `exit 2` paths and the Restart-Computer path).
    $script:OutcomeReported = $true
    # Arm the RunOnce continuation so the install resumes at next sign-in with no
    # re-pasting -- both for auto-reboot and manual -NoReboot (#420). RunOnce is
    # written to the CURRENT (elevating) account's hive: the reboot happens here in
    # Step 1, during that account's session, so that same account signs back in and
    # continues -- the -DailyUser handoff (#418) only runs at the very end.
    $resumeArmed = Register-ResumeAfterReboot -ScriptPath $PSCommandPath -NoReboot:$NoReboot -Diagnose:$Diagnose -DailyUser $DailyUser
    if ($resumeArmed) { Ok "The install will resume automatically the next time you sign in." }
    # Split-account caveat (reviewer): resume is tied to THIS account. If a different
    # user will sign in after the reboot, they must re-run the installer to continue.
    if ($resumeArmed -and $DailyUser -and ($DailyUser -ne $env:USERNAME)) {
      Hint "Resume is registered for '$env:USERNAME'. Sign back in as '$env:USERNAME' to continue; if '$DailyUser' signs in instead, re-run the installer."
    }
    if ($NoReboot) {
      if ($resumeArmed) { Hint "Reboot when ready; the install resumes at your next sign-in." }
      else              { Hint "Reboot manually, then re-run this installer to continue." }
      exit 2
    }
    $choice = Read-Host "  Reboot now? [y/N]"
    if ($choice -match "^[Yy]$") { Restart-Computer -Force }
    if (-not $resumeArmed) { Hint "After the reboot, re-run this installer to continue." }
    exit 2
  }

  Ok "System features"

  Update-Wsl

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
  # Honest progress (#468): with the overlay silenced this fetch is quiet, so
  # name the wait before it starts. Size measured 2026-07-29 (207 MB).
  Info "Downloading winget (~200 MB) -- one-time; a few minutes on a slow network is normal."
  $url  = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
  $dest = "$env:TEMP\winget-installer.msixbundle"
  Invoke-WithRetry -Label "winget download" -ScriptBlock {
    Invoke-WithHeartbeat -Message "Downloading winget (~200 MB)" `
      -ArgumentList @($url, $dest) -Script {
        param($u, $d); $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $u -OutFile $d -UseBasicParsing
      }
  }
  # Add-AppxPackage on a ~200 MB bundle is console-silent for a while (#422).
  Invoke-WithHeartbeat -Message "Installing winget" -ArgumentList @($dest) -Script {
    param($d); Add-AppxPackage -Path $d
  } | Out-Null
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
    # Try winget first (if present), then fall back to the direct download when
    # winget is absent OR its install didn't land the exe — parity with k3d/helm,
    # so a swallowed winget failure doesn't leave Step 2 to die in the long
    # Docker-wait later (#422 Bugbot).
    if (Has "winget") {
      # winget install is console-silent for minutes on a 600 MB package (#422).
      # Run it as a tracked PROCESS (not a background job): Wait-ProcessWithDeadline
      # shows a spinner AND kills the process on timeout, so a stuck install can't
      # orphan past the step and fall through to a second concurrent install —
      # Stop-Job would leave the job's child process running (#422 Bugbot).
      Info "Installing Docker Desktop (~600 MB via winget) -- several minutes is normal."
      # Pass Docker Desktop's OWN installer flags through winget (--override
      # replaces winget's manifest defaults) so a fresh machine reaches a running
      # WSL2 engine with no license/onboarding GUI prompt (#419). Use a single
      # command-line STRING, not an array: PS 5.1's Start-Process joins array
      # elements without quoting, which would split the --override value into
      # stray tokens; a string is passed verbatim so the quoted value survives
      # as one argument (#419 Bugbot).
      $wingetArgs = 'install -e --id Docker.DockerDesktop ' +
        '--accept-package-agreements --accept-source-agreements --silent ' +
        '--override "install --quiet --accept-license --backend=wsl-2 --always-run-service"'
      # Best-effort: on any non-ok outcome the direct download below takes over. Output
      # is captured to the log so a winget failure is diagnosable, not a bare code (#500).
      $r = Invoke-TrackedInstall -FilePath "winget" -ArgumentList $wingetArgs `
        -Label "Installing Docker Desktop (winget)" -TimeoutMinutes 40 -Tag "docker-winget"
      if ($r.State -ne 'ok') { Log "Docker Desktop winget install failed (will try direct download): state=$($r.State) exit=$($r.ExitCode)" }
      RefreshPath
    }

    if (-not (Test-Path $dockerExe)) {
      $ddArch = Get-WindowsArch
      # Honest progress (#468): the single biggest download of the install.
      # Size measured 2026-07-29 (613 MB).
      Info "Downloading Docker Desktop (~600 MB) -- the biggest download of this install; several minutes is normal."
      $installer = "$env:TEMP\DockerDesktopInstaller.exe"
      $ddUrl = "https://desktop.docker.com/win/main/$ddArch/Docker%20Desktop%20Installer.exe"
      Invoke-WithRetry -Label "Docker download" -ScriptBlock {
        Invoke-WithHeartbeat -Message "Downloading Docker Desktop (~600 MB)" -TimeoutSec 2400 `
          -ArgumentList @($ddUrl, $installer) -Script {
            param($u, $d); $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $u -OutFile $d -UseBasicParsing
          }
      }
      # Run the installer as a tracked PROCESS with a deadline that KILLS it on
      # timeout (a background job would orphan the installer, #422 Bugbot) and with
      # its output captured, so a failed install shows the installer's own message in
      # the log + -Diagnose bundle, not just an exit code (#500). Same flags as the
      # winget --override path: WSL2 backend + no GUI/license prompt + the engine
      # service running unattended, so a fresh machine reaches a running engine with
      # zero Docker Desktop interaction (#419). Any non-ok outcome fails loudly.
      $r = Invoke-TrackedInstall -FilePath $installer `
        -ArgumentList "install --quiet --accept-license --backend=wsl-2 --always-run-service" `
        -Label "Installing Docker Desktop" -TimeoutMinutes 40 -Tag "docker-direct"
      Remove-Item $installer -Force -ErrorAction SilentlyContinue
      switch ($r.State) {
        'spawn-failed' { Err "Docker Desktop installer wouldn't start. Install it manually from https://www.docker.com/products/docker-desktop/ and re-run." "$($r.Output)" }
        'timeout'      { Err "Docker Desktop installation timed out (installer stopped). Install it manually from https://www.docker.com/products/docker-desktop/ and re-run." }
        'failed'       { Err "Docker Desktop installation failed (installer exited $($r.ExitCode)). Install it manually from https://www.docker.com/products/docker-desktop/ and re-run." }
      }
      RefreshPath
    }

    # Neither winget nor the direct installer produced the exe — fail loudly now
    # rather than in the 10-minute Docker-wait below (#422 Bugbot).
    if (-not (Test-Path $dockerExe)) {
      Err "Docker Desktop installation didn't complete. Install it manually from https://www.docker.com/products/docker-desktop/ and re-run."
    }
  }

  $dockerRunning = $false
  try {
    $dkOut = (docker info --format '{{.ID}}' 2>$null) | Out-String
    if (-not [string]::IsNullOrWhiteSpace($dkOut)) { $dockerRunning = $true }
  } catch {}

  if (-not $dockerRunning) {
    Start-Process $dockerExe -ErrorAction SilentlyContinue

    # A first-ever Docker Desktop start on AV-heavy corporate machines
    # routinely needs 5-10 minutes (WSL bootstrap, image unpack). The old
    # 3-minute cap turned a normal cold start into a failed install plus a
    # manual re-run (#413). Default 10 minutes; TB_DOCKER_WAIT_MIN overrides.
    $waitMin = 10
    if ("$env:TB_DOCKER_WAIT_MIN" -match '^\d+$') { $waitMin = [int]$env:TB_DOCKER_WAIT_MIN }
    $maxWait = $waitMin * 20                     # 3s per iteration
    Write-Host -NoNewline "  "
    $frames = @([char]0x2807, [char]0x2819, [char]0x2839, [char]0x2838, [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827, [char]0x2847, [char]0x280F)
    $f = 0
    for ($i = 1; $i -le $maxWait; $i++) {
      Start-Sleep -Seconds 3
      try {
        $dkOut = (docker info --format '{{.ID}}' 2>$null) | Out-String
        if (-not [string]::IsNullOrWhiteSpace($dkOut)) { $dockerRunning = $true; break }
      } catch {}
      # Honest elapsed status after the first minute — silent dead air on a
      # slow first start reads as a hang.
      $label = " Waiting for Docker..."
      if ($i -ge 20) { $label = " Waiting for Docker... ($([math]::Floor($i / 20)) min elapsed; a first start can take up to $waitMin)" }
      Write-Host "`r  " -NoNewline
      Write-Host $frames[$f] -ForegroundColor Cyan -NoNewline
      Write-Host $label -NoNewline
      $f = ($f + 1) % $frames.Count
    }
    Write-Host ("`r" + (" " * 78) + "`r") -NoNewline

    if (-not $dockerRunning) {
      Write-Host ""
      # Name the observed state instead of a generic retry request (#413).
      $ddProc = Get-Process "Docker Desktop" -ErrorAction SilentlyContinue
      if (-not $ddProc) {
        # Exited = crashed/blocked, not slow — the slow-start reassurance and
        # the wait-override hint would point operators at the wrong fix
        # (Bugbot #440): raising the wait can't help a dead process.
        Warn "Docker Desktop is not running (its process exited)."
        Hint "Start Docker Desktop from the Start menu. If it shows an error window"
        Hint "(virtualization support, a WSL update prompt), fix that first - it may need a reboot."
        Write-Host ""
        Err "Docker Desktop exited before its engine came up. Start it, fix anything it reports, then re-run this script."
      } else {
        Warn "Docker Desktop is running, but its engine didn't come up within $waitMin minutes."
        Hint "1. Look for the Docker whale icon in your system tray"
        Hint "2. If Docker is open, wait until it says 'Docker Desktop is running'"
        Hint "3. If Docker shows an error window instead (e.g. 'Virtualization support not detected' or a WSL update prompt), fix that first - it may need a reboot"
        Write-Host ""
        Hint "Nothing is broken -- a first start can be slow. Re-run this script once Docker is ready."
        Hint "(TB_DOCKER_WAIT_MIN overrides the wait, e.g. `$env:TB_DOCKER_WAIT_MIN = '20'.)"
        Write-Host ""
        Err "Docker did not start within $waitMin minutes. Re-run this script once Docker is ready."
      }
    }
  }

  Ok "Docker"
}

# =============================================================================
#  NVIDIA CONTAINER TOOLKIT (inside WSL2)
# =============================================================================

# Copy-pastable manual remedy printed whenever GPU setup can't finish on its own
# (#415). Mirrors the steps in the $nctScript heredoc below so a user can run them
# by hand inside WSL; ends with the `tracebloc doctor` follow-up so "later" is an
# actual next action rather than a vague pointer.
function Show-GpuManualRemedy {
  param([string]$Distro = "Ubuntu")
  Warn "GPU acceleration isn't set up -- your environment will run in CPU mode."
  Hint "To enable it later, open '$Distro' from the Start Menu and run:"
  Hint "    curl -fsSL --tlsv1.2 --connect-timeout 30 --max-time 30 https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
  Hint "    curl -fsSL --tlsv1.2 --connect-timeout 30 --max-time 30 https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
  Hint "    sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit"
  Hint "    sudo nvidia-ctk runtime configure --runtime=docker --set-as-default"
  Hint "Then check status and re-run tracebloc:  tracebloc doctor"
}

# GPU setup is best-effort and never fatal: on any failure it prints a runnable
# manual remedy (#415) and returns, leaving K3D_GPU_FLAG empty so the cluster is
# created in CPU mode. It runs in Step 1 (before New-K3dCluster) because the
# --gpus flag is decided here; moving it to a post-install step would mean
# recreating the cluster to add the flag -- the exact churn #431 warns against --
# so instead every long sub-step below shows a heartbeat and CPU mode always wins.
function Install-NvidiaContainerToolkit {
  if ($GPU_VENDOR -ne "nvidia" -or -not $NVIDIA_DRIVER_OK) { return }

  Info "Setting up GPU acceleration (NVIDIA container toolkit) in WSL2 -- optional; CPU mode works either way."
  Log "Setting up NVIDIA container toolkit in WSL2"

  $wslListJob = Start-Job -InitializationScript $JobInit -ScriptBlock {
    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    $raw = wsl --list --quiet 2>$null
    [Console]::OutputEncoding = $prevEncoding
    return $raw
  }
  if (-not (Wait-JobWithProgress -Job $wslListJob -TimeoutSec 30 -Message "Checking for a WSL2 distro")) {
    Remove-Job $wslListJob -Force
    Warn "WSL did not respond in time. Skipping GPU container toolkit."
    Hint "Run 'wsl --update' manually, then re-run this script for GPU support."
    Show-GpuManualRemedy
    return
  }
  $distroRaw = Receive-Job $wslListJob
  Remove-Job $wslListJob -Force

  $distros = @($distroRaw | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' -and $_ -match '^\w' })
  $wslDistro = ($distros | Where-Object { $_ -match 'Ubuntu' } | Select-Object -First 1)
  if (-not $wslDistro -and $distros.Count -gt 0) { $wslDistro = $distros[0] }

  if (-not $wslDistro) {
    Info "No WSL2 distro found -- installing Ubuntu (a few hundred MB; this can take several minutes)..."
    Log "No WSL2 distro found -- installing Ubuntu..."
    $ubuntuJob = Start-Job -InitializationScript $JobInit -ScriptBlock {
      cmd /c "wsl --install -d Ubuntu --no-launch 2>&1"
      cmd /c "wsl --setdefault Ubuntu 2>&1"
    }
    if (-not (Wait-JobWithProgress -Job $ubuntuJob -TimeoutSec 600 -Message "Downloading and installing Ubuntu")) {
      Remove-Job $ubuntuJob -Force
      Warn "Ubuntu WSL2 install timed out."
      Hint "Install it manually, then re-run this script for GPU support:"
      Hint "    wsl --install -d Ubuntu"
      Hint "Then check status and re-run tracebloc:  tracebloc doctor"
      return
    }
    Receive-Job $ubuntuJob | Out-Null
    Remove-Job $ubuntuJob -Force
    Warn "Ubuntu WSL2 installed but needs first-run setup."
    Hint "Open Ubuntu from the Start Menu and set a username/password."
    Hint "Then re-run this script for GPU support."
    return
  }

  Info "Using WSL2 distro: $wslDistro"
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

  if (-not (Wait-JobWithProgress -Job $nctInstallJob -TimeoutSec 180 -Message "Installing NVIDIA container toolkit in $wslDistro")) {
    Remove-Job $nctInstallJob -Force
    Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
    Warn "GPU container toolkit installation timed out."
    Show-GpuManualRemedy -Distro $wslDistro
    return
  }
  Receive-Job $nctInstallJob | Out-Null
  Remove-Job $nctInstallJob -Force
  Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue

  $verJob = Start-Job -InitializationScript $JobInit -ScriptBlock {
    param($d)
    cmd /c "wsl -d $d -- nvidia-ctk --version 2>&1"
  } -ArgumentList $wslDistro

  if (Wait-JobWithProgress -Job $verJob -TimeoutSec 15 -Message "Verifying GPU toolkit") {
    $nctVer = (Receive-Job $verJob | Out-String).Trim()
    Remove-Job $verJob -Force
    if ($nctVer -and $nctVer -notmatch 'error|not found') {
      Ok "GPU acceleration ready -- NVIDIA Container Toolkit in ${wslDistro}: $nctVer"
      Log "NVIDIA Container Toolkit in WSL2: $nctVer"
      $script:K3D_GPU_FLAG = "--gpus=all"
    } else {
      Warn "GPU toolkit installed but could not be verified."
      Show-GpuManualRemedy -Distro $wslDistro
    }
  } else {
    Remove-Job $verJob -Force
    Warn "GPU toolkit verification timed out."
    Show-GpuManualRemedy -Distro $wslDistro
  }
}

# =============================================================================
#  SYSTEM TOOLS (kubectl, k3d, helm)
# =============================================================================

function Install-Kubectl {
  # Execute-gate on both paths (#411): a present-but-broken kubectl is as fatal as
  # a bad fresh install, and this runs in Step 1, before the cluster step.
  if (Has "kubectl") { Assert-ToolRuns -Name "kubectl" -VersionArgs @("version","--client") -BinPath "$TOOL_DIR\kubectl.exe"; return }

  $arch = Get-WindowsArch
  $kVer = Invoke-WithRetry -Label "version check" -ScriptBlock {
    (Invoke-WebRequest "https://dl.k8s.io/release/stable.txt" -UseBasicParsing).Content.Trim()
  }
  Log "Downloading kubectl $kVer ($arch)..."
  $kubectlDest = "$TOOL_DIR\kubectl.exe"
  $kUrl = "https://dl.k8s.io/release/$kVer/bin/windows/$arch/kubectl.exe"
  $t0 = Get-Date
  # Heartbeat during the otherwise-silent transfer (#422); retry wraps it.
  Invoke-WithRetry -Label "download" -ScriptBlock {
    Invoke-WithHeartbeat -Message "Downloading kubectl $kVer (~60 MB)" `
      -ArgumentList @($kUrl, $kubectlDest) -Script {
        param($u, $d); $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest $u -OutFile $d -UseBasicParsing
      }
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
  Assert-ToolRuns -Name "kubectl" -VersionArgs @("version","--client") -BinPath $kubectlDest
  Ok (Get-ToolSummaryLine -Name "kubectl" -Version $kVer -Size "~60 MB" -ElapsedSec ([int]((Get-Date) - $t0).TotalSeconds))
}

# ── Pinned tool versions (#382 / #410) ──────────────────────────────────────
# Defaults are single-sourced from scripts/spec/facts.env and stamped here by
# scripts/check-facts.sh (#435); CI's `check-facts.sh --check` fails the PR if this drifts
# from the spec or from scripts/lib/common.sh (K3D_VERSION / HELM_VERSION). Pinned
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
    # -TimeoutSec: a host that accepts the connect but never answers must not
    # hang the install (parity with the bash lookups' --max-time 30).
    $resp = Invoke-WebRequest -Uri "https://github.com/$Repo/releases/latest" `
      -Method Head -MaximumRedirection 0 -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
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
    # Retry parity with the old lookups and lib/setup-linux.sh (`retry 3 5`):
    # a single network blip must not abort the install (Bugbot #438). The
    # resolver THROWS on failure so Invoke-WithRetry can drive the attempts.
    try {
      $v = Invoke-WithRetry -Label "$Name version lookup" -ScriptBlock $LatestResolver
    } catch {
      $v = $null
    }
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
      # winget install is console-silent; run it as a killable tracked process
      # (not a job — Stop-Job would orphan the child on timeout) with a spinner +
      # deadline, capturing output so a failure is diagnosable (#500). Best-effort:
      # on any non-ok outcome the direct download below takes over (#422).
      $r = Invoke-TrackedInstall -FilePath "winget" -Label "Installing k3d (winget)" -TimeoutMinutes 10 -Tag "k3d-winget" `
        -ArgumentList @("install","-e","--id","Rancher.k3d","--accept-package-agreements","--accept-source-agreements","--silent")
      if ($r.State -ne 'ok') { Log "k3d winget install: state=$($r.State) exit=$($r.ExitCode)" }
    }
    RefreshPath

    if (-not (Has "k3d")) {
      $arch = Get-WindowsArch
      $t0k3d = Get-Date
      Log "Downloading k3d binary directly ($arch)..."
      # Pinned by default (#382 / #410) — no api.github.com on the default path.
      $k3dVer = Resolve-ToolVersion -Name "k3d" -Value $K3dVersion `
        -LatestResolver {
          $tag = Get-LatestGitHubTag -Repo "k3d-io/k3d"
          if (-not $tag) { throw "no Location header on the /releases/latest redirect" }
          $tag
        }
      $k3dDest = "$TOOL_DIR\k3d.exe"
      $k3dUrl = "https://github.com/k3d-io/k3d/releases/download/$k3dVer/k3d-windows-$arch.exe"
      Invoke-WithRetry -Label "k3d download" -ScriptBlock {
        Invoke-WithHeartbeat -Message "Downloading k3d $k3dVer (~25 MB)" `
          -ArgumentList @($k3dUrl, $k3dDest) -Script {
            param($u, $d); $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest $u -OutFile $d -UseBasicParsing
          }
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
      # Compute the summary now (correct elapsed) but print it only AFTER the
      # execute-gate passes — a corrupt/wrong-arch binary must not show a green
      # "ready" line before Assert-ToolRuns (#422 Bugbot; kubectl gates first too).
      $k3dSummary = Get-ToolSummaryLine -Name "k3d" -Version $k3dVer -Size "~25 MB" -ElapsedSec ([int]((Get-Date) - $t0k3d).TotalSeconds)
    }
  }
  Assert-ToolRuns -Name "k3d" -VersionArgs @("version") -BinPath "$TOOL_DIR\k3d.exe"
  if ($k3dSummary) { Ok $k3dSummary }

  # -- Helm --
  if (-not (Has "helm")) {
    if (Has "winget") {
      Log "Installing Helm via winget..."
      # winget install is console-silent; killable tracked process + spinner/deadline
      # (a job would orphan the child on timeout), capturing output so a failure is
      # diagnosable (#500). Best-effort: the direct download below takes over (#422).
      $r = Invoke-TrackedInstall -FilePath "winget" -Label "Installing Helm (winget)" -TimeoutMinutes 10 -Tag "helm-winget" `
        -ArgumentList @("install","-e","--id","Helm.Helm","--accept-package-agreements","--accept-source-agreements","--silent")
      if ($r.State -ne 'ok') { Log "helm winget install: state=$($r.State) exit=$($r.ExitCode)" }
      RefreshPath
    }

    if (-not (Has "helm")) {
      $arch = Get-WindowsArch
      Log "Downloading Helm binary directly ($arch)..."
      # Pinned by default (#410); "latest" resolves via get.helm.sh (no API),
      # mirroring lib/setup-linux.sh.
      $helmVer = Resolve-ToolVersion -Name "helm" -Value $HelmVersion -LatestResolver {
        $c = (Invoke-WebRequest "https://get.helm.sh/helm-latest-version" -UseBasicParsing -TimeoutSec 30).Content.Trim()
        if (-not $c) { throw "empty helm-latest-version response" }
        $c
      }
      $t0helm = Get-Date
      $helmZip = "$env:TEMP\helm-$helmVer-windows-$arch.zip"
      $helmUrl = "https://get.helm.sh/helm-$helmVer-windows-$arch.zip"
      Invoke-WithRetry -Label "helm download" -ScriptBlock {
        Invoke-WithHeartbeat -Message "Downloading Helm $helmVer (~20 MB)" `
          -ArgumentList @($helmUrl, $helmZip) -Script {
            param($u, $d); $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest $u -OutFile $d -UseBasicParsing
          }
      }
      $helmExtract = "$env:TEMP\helm-extract"
      if (Test-Path $helmExtract) { Remove-Item $helmExtract -Recurse -Force }
      Expand-Archive -Path $helmZip -DestinationPath $helmExtract -Force
      Copy-Item "$helmExtract\windows-$arch\helm.exe" "$TOOL_DIR\helm.exe" -Force
      Remove-Item $helmZip -Force -ErrorAction SilentlyContinue
      Remove-Item $helmExtract -Recurse -Force -ErrorAction SilentlyContinue
      RefreshPath
      # Summary printed only after the execute-gate below (#422 Bugbot).
      $helmSummary = Get-ToolSummaryLine -Name "helm" -Version $helmVer -Size "~20 MB" -ElapsedSec ([int]((Get-Date) - $t0helm).TotalSeconds)
    }

    if (-not (Has "helm")) { Err "Helm could not be installed. Install manually from https://helm.sh/docs/intro/install/ and re-run." }
  }
  Assert-ToolRuns -Name "helm" -VersionArgs @("version") -BinPath "$TOOL_DIR\helm.exe"
  if ($helmSummary) { Ok $helmSummary }

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

# --- Corporate MITM CA trust for in-node containerd pulls (#424) --------------
# Proxy reachability reaches the nodes (above), but on a TLS-inspecting network
# the nodes still don't TRUST the corporate CA, so in-node image pulls fail x509
# and get masked into a generic "an image couldn't be pulled". When the operator
# supplies the CA bundle we mount it into every node and point containerd at it
# per-registry. Mirrors scripts/lib/cluster.sh (drift check: check-drift.sh).
$script:TbCaRegistries = @('docker.io','registry-1.docker.io','auth.docker.io','ghcr.io')

# Return the operator's CA bundle path (absolute) when TRACEBLOC_CA_BUNDLE or
# CURL_CA_BUNDLE is set and readable; $null when neither is set. Err (hard) when a
# var is set but its file is missing — a silent skip would drop the user straight
# back into the x509 failure they set the var to fix.
function Resolve-CaBundle {
  foreach ($name in @('TRACEBLOC_CA_BUNDLE','CURL_CA_BUNDLE')) {
    $val = [Environment]::GetEnvironmentVariable($name)
    if (-not $val) { continue }
    if (-not (Test-Path -LiteralPath $val -PathType Leaf)) {
      Err "$name is set to '$val' but no such file exists - point it at your corporate CA bundle (PEM) and re-run."
    }
    # Verify it's actually READABLE, not just present (matches bash's `-r`): a file
    # that exists but can't be opened must hard-fail here, not at k3d mount/pull time.
    try { [System.IO.File]::OpenRead($val).Dispose() }
    catch { Err "$name is set to '$val' but that file can't be read ($($_.Exception.Message)) - fix its permissions or point it at a readable CA bundle (PEM), then re-run." }
    return (Resolve-Path -LiteralPath $val).Path
  }
  return $null
}

# Build a k3d registries.yaml pointing containerd at the mounted CA for every
# registry in $TbCaRegistries, and return its path. $NodeCa = the CA path INSIDE
# the node (where the -v mount lands). Written UTF-8 without BOM. Caller removes
# the parent temp dir.
function Write-K3dRegistriesConfig {
  param([Parameter(Mandatory)][string]$NodeCa)
  $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("tracebloc-k3d-reg-" + [System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
  $cfg = Join-Path $tmpDir "registries.yaml"
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('configs:')
  foreach ($reg in $script:TbCaRegistries) {
    $lines.Add('  "' + $reg + '":')
    $lines.Add('    tls:')
    $lines.Add('      ca_file: "' + $NodeCa + '"')
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
#  DAILY-USER PROVISIONING (#418) — hospital reality: the researcher gets a
#  temporary admin window (or IT runs the install), then elevation is revoked. The
#  installer runs elevated, so provision Docker for the standard account NOW:
#  docker-users membership, Docker autostart, and a training-sized .wslconfig.
#  All warn-only -- a provisioning hiccup must never fail the install.
# =============================================================================

# WSL2 VM memory (GB) for .wslconfig -- the SAME budget the preflight advises for
# this machine, so training pods fit instead of the WSL2 default (~50% of RAM).
# It DELEGATES to Get-PfMemRecommendation (the recommended training budget, capped
# at physical RAM minus the shared OS reserve) instead of doing its own arithmetic.
# That delegation is the point: this path writes REAL config, so a private
# calculation makes the installer contradict its own advice in the same run. It did
# -- a private 4 GB reserve (vs the shared 2) told an 8 GB host "give Docker up to
# 6 GB" while writing memory=4GB, below the client's own PF_MIN_MEM_GB floor and so
# a guaranteed OOM crashloop; and it over-committed the other end, handing a 32 GB
# host 28 GB and leaving Windows 4.
#
# Returns 0 when the host cannot support the floor (physical - reserve < the floor):
# there is no budget worth writing, so the caller must skip the setting and say the
# machine is too small rather than persist one known to OOM. Pure (#418).
function Get-WslConfigMemoryGb {
  param([int]$HostGb, [int]$MinGb = 0)
  if ($MinGb -le 0) { $MinGb = Get-PfMinMemGb }
  # No ReserveGb param on purpose: the reserve is single-sourced, so no caller can
  # reintroduce the drift this function existed to demonstrate.
  if (($HostGb - (Get-PfOsReserveGb)) -lt $MinGb) { return 0 }
  return (Get-PfMemRecommendation -DesiredGb (Get-PfRecMemGb) -HostGb $HostGb)
}

# Merge a memory budget into EXISTING .wslconfig content without clobbering other
# settings (processors, swap, ...). Returns the new content, or $null when a
# memory= is already present (keep the operator's tuning) (#418 Bugbot).
function Add-WslMemorySetting {
  param([string]$Existing, [int]$MemoryGb)
  if ($Existing -match '(?im)^\s*memory\s*=') { return $null }              # already tuned -> keep
  $line = "memory=${MemoryGb}GB"
  if ([string]::IsNullOrWhiteSpace($Existing)) { return "[wsl2]`r`n$line`r`n" }
  if ($Existing -match '(?im)^\s*\[wsl2\]\s*$') {
    # Insert under the existing [wsl2] header, preserving everything else.
    return ($Existing -replace '(?im)^(\s*\[wsl2\]\s*)$', "`$1`r`n$line")
  }
  # No [wsl2] section -> append one, preserving the existing content.
  $sep = if ($Existing.EndsWith("`n")) { "" } else { "`r`n" }
  return "$Existing$sep[wsl2]`r`n$line`r`n"
}

# Which account to provision for: -DailyUser when given, else the caller-supplied
# name, else the account running the installer. Returns the bare username (#418).
function Resolve-DailyUser {
  param([string]$Param, [string]$CurrentUser = $env:USERNAME)
  if ($Param) { return ($Param -replace '^.*\\', '').Trim() }
  return $CurrentUser
}

# Profile directory for a user: the current user's $env:USERPROFILE, else
# <SystemDrive>\Users\<user> when it exists. $null when the user has no profile
# yet (never signed in) -- the caller then notes .wslconfig as a manual step (#418).
function Get-UserProfileDir {
  param([string]$User)
  if ($User -eq $env:USERNAME) { return $env:USERPROFILE }
  $p = Join-Path "$env:SystemDrive\Users" $User
  if (Test-Path -LiteralPath $p -PathType Container) { return $p }
  return $null
}

# Pure: does the bare (domain-stripped) <User> appear in local-group member output
# (either Get-LocalGroupMember .Name values or `net localgroup <group>` lines)?
# Case-insensitive name compare -> locale-independent, no stderr string-matching (#418 Bugbot).
function Test-NameInGroupOutput {
  param([string[]]$Output, [string]$User)
  $short = ($User -replace '^.*\\', '').Trim()
  if (-not $short) { return $false }
  foreach ($line in @($Output)) {
    if ((("$line".Trim() -replace '^.*\\', '')) -ieq $short) { return $true }
  }
  return $false
}

# Is <User> a member of local <Group>? STATE QUERY (not a parse of `net ... /add`
# output): prefer Get-LocalGroupMember, fall back to `net localgroup <group>`
# STDOUT (not 2>&1-merged). Used to verify docker-users idempotently (#418 Bugbot).
function Test-LocalGroupMember {
  param([string]$Group, [string]$User)
  try {
    $names = Get-LocalGroupMember -Group $Group -ErrorAction Stop | ForEach-Object { $_.Name }
    return (Test-NameInGroupOutput -Output $names -User $User)
  } catch {
    try { return (Test-NameInGroupOutput -Output (& net localgroup $Group 2>$null) -User $User) }
    catch { return $false }
  }
}

# Provision Docker for the daily user during the elevated run (#418). Warn-only;
# TRACEBLOC_SKIP_DAILY_USER opts out. The .wslconfig applies at the daily user's
# next sign-in (the acceptance scenario), so we do NOT `wsl --shutdown` and tear
# down the just-built cluster mid-install.
function Set-DailyUserProvisioning {
  if ($env:TRACEBLOC_SKIP_DAILY_USER) { return }
  $user = Resolve-DailyUser -Param $DailyUser
  if (-not $DailyUser -and (Test-CanPrompt)) {
    $other = Read-Host "  Configure Docker for the day-to-day user? Enter their username, or press Enter for '$user'"
    $other = ConvertTo-SanitizedInput $other   # strip paste/ANSI/control chars before it hits net localgroup + paths (#418 Bugbot)
    if ($other.Trim()) { $user = Resolve-DailyUser -Param $other }
  }
  Info "Configuring Docker for '$user' so no admin rights are needed later..."
  $did = @()

  # 1) docker-users membership -> the standard account can use Docker. This is the
  # CRITICAL step: without it the daily account can't use Docker at all. Verify by
  # STATE QUERY (Test-LocalGroupMember), never by string-matching the localized,
  # 2>&1-merged output of `net localgroup /add` (#418 Bugbot).
  $dockerUsersOk = $false
  try {
    if (Test-LocalGroupMember -Group 'docker-users' -User $user) {
      $dockerUsersOk = $true; $did += "already in docker-users"
    } else {
      $null = (& net localgroup docker-users "$user" /add 2>$null)   # idempotent; verify below, don't parse
      if (Test-LocalGroupMember -Group 'docker-users' -User $user) {
        $dockerUsersOk = $true; $did += "added to docker-users"
      } else {
        Log "docker-users add did not take for '$user' (net exit $LASTEXITCODE)"
      }
    }
  } catch { Log "docker-users add failed: $_" }

  # 2) Docker Desktop autostart via the per-user Run key (current user only -- a
  # different user's hive may not be loaded). The engine also runs as a service
  # (--always-run-service, #419), so Docker is usable on sign-in regardless.
  try {
    $ddExe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
    if ($user -eq $env:USERNAME -and (Test-Path $ddExe)) {
      New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'Docker Desktop' -Value "`"$ddExe`"" -PropertyType String -Force -ErrorAction Stop | Out-Null
      $did += "autostart enabled"
    }
  } catch { Log "autostart set failed: $_" }

  # 3) Training-sized .wslconfig in the daily user's profile. Merge the memory
  # budget in without clobbering any other tuning (processors/swap/...), and keep
  # an existing memory= as-is. Effective at next WSL start / sign-in.
  try {
    $hostGb     = Get-PfMemGb
    $profileDir = Get-UserProfileDir -User $user
    if ($null -eq $profileDir) {
      # User has never signed in -> no profile to write into. Note it as a manual step.
      $did += "no profile for '$user' yet -- set [wsl2] memory in their .wslconfig after first sign-in"
    } elseif ($null -eq $hostGb) {
      # Host RAM undetectable -> can't size the budget. Note it rather than skip silently (#418 Bugbot).
      $did += "couldn't detect host RAM -- set [wsl2] memory in '$user's .wslconfig manually"
    } else {
      $memGb = Get-WslConfigMemoryGb -HostGb $hostGb
      if ($memGb -le 0) {
        # 0 = this host can't give the VM the client's floor. The biggest budget it
        # COULD hold would still OOM-crashloop the client, and persisting it would
        # bake that in for every later run on the daily account. Leave memory unset
        # (WSL2's own default then applies) and say so plainly -- same honest framing
        # as the preflight's host-too-small line.
        $minGb   = Get-PfMinMemGb
        $reserve = Get-PfOsReserveGb
        Warn ("This machine has $hostGb GB RAM - too little for tracebloc: the client needs a $minGb GB WSL2 budget " +
              "and Windows needs ~$reserve GB, so about $($minGb + $reserve) GB physical is the practical minimum.")
        Hint "Left '$user's .wslconfig memory unset rather than write a budget that would OOM. Use a larger machine to run the client."
        $did += "machine too small for a $minGb GB WSL2 budget -- .wslconfig memory left unset"
      } else {
        $wslCfg   = Join-Path $profileDir ".wslconfig"
        $existing = if (Test-Path $wslCfg) { (Get-Content $wslCfg -Raw -ErrorAction SilentlyContinue) } else { "" }
        $merged   = Add-WslMemorySetting -Existing $existing -MemoryGb $memGb
        if ($null -eq $merged) {
          $did += "kept existing .wslconfig memory"
        } else {
          Set-Content -Path $wslCfg -Value $merged -Encoding ASCII -ErrorAction Stop
          $did += "set .wslconfig memory=${memGb}GB (applies next sign-in)"
        }
      }
    }
  } catch {
    # A thrown merge/write (permissions, disk) must surface in the summary too --
    # don't let a green "Configured for" imply the budget was set (#418 Bugbot).
    Log ".wslconfig write failed: $_"
    $did += "couldn't write .wslconfig -- set [wsl2] memory in '$user's profile manually"
  }

  # 4) Summary. docker-users membership is the make-or-break step: without it the
  # standard account can't use Docker at all. If it didn't take, WARN loudly even
  # when other steps succeeded -- never print a green "Configured" over a broken
  # setup, or IT leaves the elevated window thinking the researcher is ready (#418 Bugbot).
  if (-not $dockerUsersOk) {
    if ($did.Count) { Info ("Other steps done for '$user': " + ($did -join "; ") + ".") }
    Warn "Could NOT add '$user' to docker-users -- the standard account won't be able to use Docker. While you still have admin rights, run:  net localgroup docker-users $user /add"
  } elseif ($did.Count) {
    Ok ("Configured for '$user': " + ($did -join "; ") + ".")
  } else {
    Warn "Couldn't auto-configure Docker for '$user' -- see the log; add them to docker-users manually if needed."
  }
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

# When 'k3d cluster create' fails, one cause on a TLS-inspecting network is the
# HOST Docker daemon hitting x509 while pulling k3d's OWN runtime images
# (rancher/k3s, k3d-tools, k3d-proxy) -- a different surface than the in-node CA
# trust (#424), which only covers containerd inside the nodes. Docker Desktop runs
# the daemon in a VM the installer can't reach, so the node CA mount can't fix it,
# and this fails before any node boots so Get-NotReadyState never sees it. Detect
# x509 in the create output and name it with a Windows-specific remedy (#474).
# No-op unless the output shows a TLS-verification failure. Mirrors the bash
# _host_ca_create_hint.
function Write-HostCaCreateHint {
  param([string]$Output)
  if ($Output -notmatch '(?i)x509|certificate signed by unknown authority|tls: failed to verify') { return }
  Write-Host ""
  Warn "The Docker daemon couldn't pull k3d's runtime images -- TLS verification failed (x509)."
  Hint "k3d pulls rancher/k3s, k3d-tools and k3d-proxy with the HOST Docker daemon, which does"
  Hint "not use the in-node CA trust (TRACEBLOC_CA_BUNDLE) this installer configures. Docker"
  Hint "Desktop runs the daemon in a VM the installer can't reach, so the CA must be trusted by"
  Hint "the host:"
  Hint "  Import your corporate CA into the Windows certificate store (Trusted Root Certification"
  Hint "  Authorities -- 'certlm.msc' for the machine store), then restart Docker Desktop; it reads"
  Hint "  the Windows trust store on start."
  Hint "  Details: docs/INSTALL.md (`"TLS-inspecting network`") and https://docs.docker.com/."
  Write-Host ""
}

# Warn (never fatal) when the RUNNING cluster's k3s differs from the validated pin.
# k3s is baked in at create time; a cluster born unpinned, on an older installer, or
# with K8S_VERSION=latest keeps its version across later pinned re-runs -- the #547
# incident (a client ran k3s v1.35.5 while the pin was v1.29.4-k3s1). Called from
# BOTH the reuse path in New-K3dCluster AND the completed+healthy fast-path in main
# (Bugbot #565), so a healthy-but-drifted cluster still gets the recreate guidance.
# Silent no-op if the image can't be read or isn't a parseable rancher/k3s:<tag>
# (e.g. a digest-only pin) -- never false-warn.
function Test-K3sVersionDrift {
  if ($K8S_VERSION -eq "" -or $K8S_VERSION -eq "latest") { return }
  # Bounded (installer rule: every docker probe must have a deadline) so a wedged
  # Docker engine can't hang the "already healthy" fast-path after success prints
  # (#565 Bugbot). Mirrors Test-ClusterRunning's Start-Job + timeout pattern.
  $k3sImage = ""
  $job = Start-Job -InitializationScript $JobInit -ScriptBlock {
    param($n) (docker inspect "k3d-$n-server-0" --format '{{.Config.Image}}' 2>$null | Out-String)
  } -ArgumentList $CLUSTER_NAME
  if (Wait-JobWithProgress -Job $job -TimeoutSec 15 -Message "Checking k3s version") {
    $k3sImage = (Receive-Job $job -ErrorAction SilentlyContinue | Out-String).Trim()
  } else {
    Log "docker inspect (k3s version) timed out; skipping the version-drift check."
  }
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  if ($k3sImage -match 'rancher/k3s:([^@\s]+)') {
    $runningK3s = $Matches[1]
    if ($runningK3s -ne $K8S_VERSION) {
      Warn "The existing '$CLUSTER_NAME' cluster runs k3s '$runningK3s', not the validated pin '$K8S_VERSION'."
      Hint "k3s version is fixed when the cluster is created -- it can't be changed on a running cluster."
      Hint "This cluster was created by an older/unpinned installer or with K8S_VERSION=latest (#547). To move"
      Hint "onto the validated version, recreate it:"
      Hint "  k3d cluster delete $CLUSTER_NAME  (then re-run this installer)."
      Hint "  (data under HOST_DATA_DIR is kept; recreate rebinds it.)"
    }
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
      # Run k3d start as a killable tracked PROCESS with a deadline (a background
      # job would orphan the native k3d child on timeout, #422 Bugbot), capturing
      # its raw INFO[...] to temp files so it goes to the log, not streamed to the
      # console. Exit code + timeout are both checked so a failed start Errs with
      # the real reason instead of falsely reporting "started".
      $startOutFile = Join-Path $env:TEMP "k3d-start-$(Get-Random).log"
      $startErrFile = Join-Path $env:TEMP "k3d-start-err-$(Get-Random).log"
      $sp = $null
      try {
        $sp = Start-Process -FilePath "k3d" -ArgumentList @("cluster","start",$CLUSTER_NAME) `
          -NoNewWindow -PassThru -ErrorAction Stop `
          -RedirectStandardOutput $startOutFile -RedirectStandardError $startErrFile
      } catch {
        Remove-Item $startOutFile, $startErrFile -Force -ErrorAction SilentlyContinue
        Err "Couldn't start the existing '$CLUSTER_NAME' environment (k3d wouldn't start). Check Docker is running, then re-run." "$_"
      }
      $startTimedOut = -not (Wait-ProcessWithDeadline -Process $sp -Deadline (Get-Date).AddMinutes(5) -Message "Starting your secure environment")
      $startLog = (("$(Get-Content $startErrFile -Raw -ErrorAction SilentlyContinue)`n$(Get-Content $startOutFile -Raw -ErrorAction SilentlyContinue)")).Trim()
      Remove-Item $startOutFile, $startErrFile -Force -ErrorAction SilentlyContinue
      if ($startLog) { Log "k3d cluster start: $startLog" }
      if ($startTimedOut) {
        Err "Starting the existing '$CLUSTER_NAME' environment timed out (k3d stopped). Check Docker is running, then re-run." $startLog
      }
      if ($sp.ExitCode -ne 0) {
        Err "Couldn't start the existing '$CLUSTER_NAME' environment. Check Docker is running, then re-run." $startLog
      }
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

    # CA trust (like proxy / the dataset mount) is baked into the nodes at create
    # time (mount + --registry-config). If a CA bundle is set but the existing
    # cluster was created without it, reuse leaves in-node pulls failing x509 — so
    # the "set the CA and re-run" remedy does nothing. Warn + point at recreate
    # (Bugbot #424). Path mirrors New-K3dCluster's mount destination.
    if ($env:TRACEBLOC_CA_BUNDLE -or $env:CURL_CA_BUNDLE) {
      $caMounts = ""
      try { $caMounts = (docker inspect "k3d-$CLUSTER_NAME-server-0" --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>$null | Out-String) } catch {}
      if ($caMounts -and ($caMounts -notmatch '(?m)^/etc/ssl/certs/tracebloc-mitm-ca\.crt\s*$')) {
        Warn "A CA bundle is set, but the existing '$CLUSTER_NAME' cluster was created without it."
        Hint "k3d bakes CA trust into the nodes at create time -- it can't be added to a running cluster."
        Hint "If in-cluster image pulls fail x509, recreate the cluster so the CA is applied:"
        Hint "  k3d cluster delete $CLUSTER_NAME  (then re-run this installer)."
      }
    }

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

    # k3s version drift: a cluster born unpinned/old/latest keeps its k3s across
    # pinned re-runs (#547). Shared with the completed+healthy fast-path in main so
    # a healthy-but-drifted cluster is warned too (Bugbot #565).
    Test-K3sVersionDrift
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

    # Pin k3s at create time (#547). $K8S_VERSION defaults to the validated pin, so
    # a normal install ALWAYS passes --image; the version is baked into the node
    # image and can't change later. K8S_VERSION=latest is an unsupported opt-out
    # that floats to k3d's own bundled default (how a client landed on v1.35.5) —
    # honour it but warn loudly.
    if ($K8S_VERSION -eq "latest") {
      Warn "K8S_VERSION=latest runs an UNVALIDATED k3s (k3d's bundled default), not the tested pin."
      Hint "The chart is validated against a specific k3s release; 'latest' is unsupported and has stranded installs (#547)."
      Hint "Unset K8S_VERSION (or pin it to a validated tag) to use the tested version."
    } elseif ($K8S_VERSION -ne "") {
      $k3dArgs += @("--image", "rancher/k3s:$K8S_VERSION")
    }
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

    # In-node CA trust for TLS-inspecting networks (#424): mount the operator's CA
    # bundle into every node and point containerd at it per-registry, so in-node
    # image pulls validate the intercepted certs instead of failing x509.
    $caBundle = Resolve-CaBundle
    $registriesCfg = $null
    if ($caBundle) {
      $nodeCa = "/etc/ssl/certs/tracebloc-mitm-ca.crt"
      $k3dArgs += @("-v", "${caBundle}:${nodeCa}@all")
      $registriesCfg = Write-K3dRegistriesConfig -NodeCa $nodeCa
      $k3dArgs += @("--registry-config", $registriesCfg)
      Log "Trusting your network's TLS-inspection CA in the k3d nodes (from $caBundle)."
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
      if ($registriesCfg) { Remove-Item (Split-Path $registriesCfg -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
      # Err prints the log path + -Diagnose itself now (#423); no inline Hint here.
      Err "Couldn't start k3d ($k3dExe): $($_.Exception.Message). Reinstall it (re-run this script) or check that the binary runs: k3d version"
    }

    $timeoutMin = 15
    if ("$env:TB_CREATE_TIMEOUT_MIN" -match '^\d+$') { $timeoutMin = [int]$env:TB_CREATE_TIMEOUT_MIN }
    if (-not (Wait-ProcessWithDeadline -Process $k3dProc -Deadline (Get-Date).AddMinutes($timeoutMin) -Message "Creating compute environment...")) {
      # Capture the FULL create output before the logs are deleted, so the
      # host-CA x509 check below can see an x509 that scrolled past the last 5
      # lines (a hung TLS-inspected pull logs x509 then wedges until the deadline).
      $timeoutOut = ""
      if (Test-Path $k3dErrLog) { $timeoutOut += ([string](Get-Content $k3dErrLog -Raw -ErrorAction SilentlyContinue)) }
      if (Test-Path $k3dOutLog) { $timeoutOut += "`n" + ([string](Get-Content $k3dOutLog -Raw -ErrorAction SilentlyContinue)) }
      $tail = @()
      if (Test-Path $k3dErrLog) { $tail = @(Get-Content $k3dErrLog -ErrorAction SilentlyContinue | Select-Object -Last 5) }
      if (-not $tail -and (Test-Path $k3dOutLog)) { $tail = @(Get-Content $k3dOutLog -ErrorAction SilentlyContinue | Select-Object -Last 5) }
      foreach ($line in $tail) { Warn "k3d: $line" }
      # Err prints the log path + -Diagnose itself now (#423); no inline Hint here.
      Remove-Item $k3dOutLog, $k3dErrLog -Force -ErrorAction SilentlyContinue
      if ($proxyCfg) { Remove-Item (Split-Path $proxyCfg -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
      if ($registriesCfg) { Remove-Item (Split-Path $registriesCfg -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
      # Killing k3d mid --wait skips its own rollback; a leftover partial
      # cluster would be adopted as "already running" by the next run's
      # reuse path (Bugbot #439). Remove it — bounded — before failing.
      Info "Removing the partially created environment..."
      $partialDeleted = $false
      try {
        $delProc = Start-Process -FilePath $k3dExe -ArgumentList "cluster delete $CLUSTER_NAME" `
          -NoNewWindow -PassThru -ErrorAction Stop
        if (Wait-ProcessWithDeadline -Process $delProc -Deadline (Get-Date).AddMinutes(2) -Message "Removing partial environment...") {
          $partialDeleted = ($delProc.ExitCode -eq 0)
        }
      } catch {}
      if (-not $partialDeleted) {
        Warn "Couldn't remove the partial cluster automatically - run 'k3d cluster delete $CLUSTER_NAME' before re-running."
      }
      # A TLS-inspected host pull can log x509 and then hang until the deadline —
      # surface the CA remedy here too, matching bash's timeout fall-through (#474).
      Write-HostCaCreateHint -Output $timeoutOut
      Err "Compute environment creation timed out after $timeoutMin minutes. Check that Docker is healthy and this network can pull images, then re-run. (TB_CREATE_TIMEOUT_MIN overrides the bound.)"
    }

    $k3dExitCode = $k3dProc.ExitCode
    $k3dStdout = if (Test-Path $k3dOutLog) { Get-Content $k3dOutLog -Raw -ErrorAction SilentlyContinue } else { "" }
    $k3dStderr = if (Test-Path $k3dErrLog) { Get-Content $k3dErrLog -Raw -ErrorAction SilentlyContinue } else { "" }
    Remove-Item $k3dOutLog, $k3dErrLog -Force -ErrorAction SilentlyContinue
    if ($proxyCfg) { Remove-Item (Split-Path $proxyCfg -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    if ($registriesCfg) { Remove-Item (Split-Path $registriesCfg -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    if ($k3dStdout) { Log "k3d stdout: $k3dStdout" }
    if ($k3dStderr) { Log "k3d stderr: $k3dStderr" }

    if ($k3dExitCode -ne 0) {
      # Host-daemon x509 (k3d runtime image pull on a TLS-inspecting network,
      # #474) -- name the CA remedy before the generic failure.
      Write-HostCaCreateHint -Output ("$k3dStdout`n$k3dStderr")
      # Surface k3d's real reason (image pull / proxy / port / WSL) on screen via
      # Err's detail excerpt, not only in the log (#423). stderr LAST so its tail
      # (the FATA/x509/port reason) survives Get-ErrDetailLines' last-5-line window
      # even if k3d wrote to stdout; matches the Write-HostCaCreateHint order above
      # (reviewer).
      Err "Failed to create compute environment." "$k3dStdout`n$k3dStderr"
    }
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
      $gpuOk = $false
      if ((Get-Item $dpTmp).Length -gt 0) {
        # kubectl is a native command: a non-zero exit does NOT throw, so without an
        # explicit $LASTEXITCODE gate a failed apply/rollout would fall through to a
        # false "GPU acceleration enabled." Capture each call's output to the log and
        # gate the success message on the exit code (mirrors bash gpu-plugins.sh).
        # --request-timeout bounds the API call so a wedged API server fails into the
        # CPU-mode warn below instead of hanging silently (Bugbot; parity with bash).
        $applyOut = (kubectl apply -f $dpTmp --request-timeout=30s 2>&1 | Out-String)
        Log "GPU plugin apply: $applyOut"
        if ($LASTEXITCODE -eq 0) {
          $rollOut = (kubectl rollout status daemonset/nvidia-device-plugin-daemonset `
            -n kube-system --timeout=120s 2>&1 | Out-String)
          Log "GPU plugin rollout: $rollOut"
          $gpuOk = ($LASTEXITCODE -eq 0)
        }
      }
      if ($gpuOk) {
        Ok "GPU acceleration enabled."
      } else {
        Warn "Couldn't enable GPU acceleration - continuing in CPU mode. Re-run the installer later to retry."
      }
    } catch {
      # GPU is OPTIONAL: a plugin download/apply failure must NOT abort the install
      # (#577 fatal-vs-recoverable) — otherwise the throw would reach the top-level
      # boundary and stop everything. Warn and continue in CPU mode.
      Warn "Couldn't enable GPU acceleration - continuing in CPU mode. Re-run the installer later to retry."
      Log "GPU device-plugin setup error: $($_.Exception.Message)"
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
  Step 5 $script:INSTALL_STEPS.Count "Registering this machine"
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
      Err "Couldn't provision the client. Re-run to retry."
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
  Step 6 $script:INSTALL_STEPS.Count "Installing tracebloc client"

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
  if ($LASTEXITCODE -ne 0) { Err "Couldn't add the tracebloc chart repo ($TRACEBLOC_HELM_REPO_URL)." $addOutput }

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
    if ($LASTEXITCODE -ne 0) { Err "Client reconcile failed." $helmOutput }
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
    if ($LASTEXITCODE -ne 0) { Err "Client installation failed." $helmOutput }
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
  $deploys = Get-ClientDeploymentNames -Namespace $ns
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
  # The concrete pod/event text behind the failure, surfaced in the summary so the
  # failure copy contains the actual reason, not just a generic line (#425).
  $script:NotReadyDetail = ""
  # Wrong credentials: jobs-manager authenticates to the backend on startup and
  # crash-loops when rejected -- surfaced as an auth error in its logs.
  $jmLogs = (& kubectl logs -n $Namespace "deployment/$Namespace-jobs-manager" --all-containers --tail=50 2>$null | Out-String)
  if ($jmLogs -match '(?i)authentication failed|unable to log in') { return "bad_creds" }
  $pods = (& kubectl get pods -n $Namespace 2>$null | Out-String)
  if ($pods -match '(?i)ImagePullBackOff|ErrImagePull|InvalidImageName') {
    # On a TLS-inspecting network the pull fails x509 because the nodes don't trust
    # the corporate CA (#424). Distinguish it so the remedy can name the CA + env
    # var, not a vague retry. Mirrors scripts/lib/summary.sh::_diagnose_not_ready.
    # Scope the x509 test to the image-pull failure event itself, not any stray
    # x509 event elsewhere in the ns -- a stale/unrelated x509 event must not steer
    # the user into a delete+recreate for the wrong reason (reviewer). Mirrors the
    # bash _diagnose_not_ready pull_fail filter.
    $events = (& kubectl get events -n $Namespace --request-timeout=5s 2>$null | Out-String)
    $pullFail = (($events -split "`n") | Where-Object { $_ -match '(?i)failed to pull|ErrImagePull' }) -join "`n"
    # Surface the concrete event (or the failing pod lines when events are empty).
    $script:NotReadyDetail = ((($pullFail -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 3) -join "`n").Trim()
    if (-not $script:NotReadyDetail) {
      $script:NotReadyDetail = ((($pods -split "`n") | Where-Object { $_ -match '(?i)ImagePullBackOff|ErrImagePull|InvalidImageName' } | Select-Object -First 3) -join "`n").Trim()
    }
    if ($pullFail -match '(?i)x509|certificate signed by unknown authority|tls: failed to verify') { return "image_pull_ca" }
    return "image_pull"
  }
  if ($pods -match '(?i)CrashLoopBackOff') {
    $script:NotReadyDetail = ((($pods -split "`n") | Where-Object { $_ -match '(?i)CrashLoopBackOff' } | Select-Object -First 3) -join "`n").Trim()
    return "crash"
  }
  return "starting"
}

# =============================================================================
#  SUMMARY
# =============================================================================

# Print the concrete pod/event text behind a not-ready failure (#425), indented, so
# the failure summary carries the actual reason (the "failed to pull ..." event or
# the failing pod line) rather than only a generic sentence. No-op when empty.
function Write-NotReadyDetail {
  if (-not $script:NotReadyDetail) { return }
  Write-Host ""
  Write-Host "  What the cluster reported:" -ForegroundColor DarkGray
  foreach ($l in ($script:NotReadyDetail -split "`n")) {
    if ($l.Trim()) { Hint "  $($l.Trim())" }
  }
}

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
  # Central outcome log (#576 / Bugbot #579): record the classified final state
  # for EVERY branch, so no summary case can silently miss the log after the
  # Start-Transcript removal (connected / starting / bad_creds / image_pull_ca /
  # image_pull / crash / other).
  Log "Final client state: $script:ClientState"
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
      Write-Host "  " -NoNewline; Write-Host "$([char]0x2716) Couldn't connect - your Client ID or password was rejected." -ForegroundColor Red; Log "Couldn't connect - Client ID or password rejected by tracebloc."
      Write-Host ""
      Write-Host "  The environment installed, but tracebloc refused those credentials."
      Write-Host "    1. Re-check them at https://ai.tracebloc.io/clients" -ForegroundColor Cyan
      Write-Host "    2. Re-run this installer (safe to re-run)"
    }
    "image_pull_ca" {
      Write-Host "  " -NoNewline; Write-Host "$([char]0x2716) Setup didn't finish - the cluster does not trust your network's TLS-inspection CA." -ForegroundColor Red; Log "Setup did not finish - cluster does not trust the network's TLS-inspection CA (in-cluster image pulls fail x509)."
      Write-Host ""
      Write-Host "  Your network intercepts HTTPS (break-and-inspect), so the in-cluster image"
      Write-Host "  pulls fail certificate validation (x509). CA trust is baked in at"
      Write-Host "  cluster-create, so delete the existing cluster first, then re-run with the CA:"
      Write-Host "    k3d cluster delete $CLUSTER_NAME" -ForegroundColor Green
      Write-Host "    `$env:TRACEBLOC_CA_BUNDLE = 'C:\path\to\corporate-ca.pem'; irm https://tracebloc.io/i.ps1 | iex" -ForegroundColor Green
      Hint "(CURL_CA_BUNDLE is also honored.) Ask your IT team for the bundle if unsure."
      Write-Host "  Inspect:  " -NoNewline; Write-Host "kubectl get events -n $ns | Select-String x509" -ForegroundColor Green
      Write-NotReadyDetail
      Hint "Re-running this installer is safe."
    }
    default {
      $reason = "a component didn't start"
      if ($script:ClientState -eq "image_pull") { $reason = "an image couldn't be pulled" }
      if ($script:ClientState -eq "crash")      { $reason = "a container is restarting (crash loop)" }
      Write-Host "  " -NoNewline; Write-Host "$([char]0x2716) Setup didn't finish - $reason." -ForegroundColor Red; Log "Setup did not finish - $reason."
      Write-Host ""
      Write-Host "  Inspect:  " -NoNewline; Write-Host "kubectl get pods -n $ns" -ForegroundColor Green
      Write-Host "  Logs:     ~\.tracebloc\install-*.log"
      Write-NotReadyDetail
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
function Write-PfFail($m) { Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red -NoNewline; Write-Host " $m" -ForegroundColor Red; Log "PREFLIGHT FAIL: $m" }

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

# The same budget in MiB. The FLOOR CHECK needs sub-GB precision: Get-PfRuntimeMemGb
# floors to whole GB, and a VM configured at exactly the floor reports a few hundred
# MiB less than its configured size (guest kernel + reserved), so 5 GB configured ->
# ~4.8 GB reported -> floors to 4. Enforcing on that would hard-fail a correctly
# sized machine, so the gate compares MiB against the floor minus a grace band
# (mirrors bash's PF_VM_MEM_GRACE_MIB, preflight.sh #513). $null if undeterminable.
function Get-PfRuntimeMemMib {
  try {
    $v = ((docker info --format '{{.MemTotal}}' 2>$null) | Out-String).Trim()
    if ($v -match '^\d+$' -and [int64]$v -gt 0) { return [math]::Floor([int64]$v / 1MB) }
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

# Total physical HOST RAM in GB — the consistent memory figure we report, whether
# or not Docker is up (#417). The container runtime's smaller VM budget is read
# separately via Get-PfRuntimeMemGb and shown as its own labeled line, so the
# reported host RAM never flip-flops across re-runs. $null if undeterminable.
function Get-PfMemGb {
  try { return [math]::Floor((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB) }
  catch { return $null }
}

# Single source for the RAM we assume the host OS needs, so Docker is never
# advised to take all of it. Used to cap recommendations AND to reason about the
# achievable budget in one place, so the two can't drift (#417 reviewer).
$script:PfOsReserveGb = 2

# Accessors for the three memory numbers, so every path that PRINTS advice and every
# path that WRITES a real budget reads the same values (#418). Read through these
# rather than re-deriving: the drift they close is what let the daily-user
# .wslconfig be sized from a private 4 GB reserve while the preflight advised 2,
# producing a budget below the client's own floor on an 8 GB host.
# The reserve fails CLOSED -- never 0, which would hand WSL2 the entire host.
function Get-PfOsReserveGb { if ($script:PfOsReserveGb -gt 0) { return [int]$script:PfOsReserveGb } else { return 2 } }
function Get-PfMinMemGb    { if ($env:PF_MIN_MEM_GB)  { return [int]$env:PF_MIN_MEM_GB }  else { return 5 } }
function Get-PfWarnMemGb   { if ($env:PF_WARN_MEM_GB) { return [int]$env:PF_WARN_MEM_GB } else { return 8 } }
function Get-PfRecMemGb    { if ($env:PF_REC_MEM_GB)  { return [int]$env:PF_REC_MEM_GB }  else { return 16 } }
# How far below the floor a VM may REPORT before the runtime gate calls it sub-floor.
# A guest's MemTotal runs a few hundred MiB under its configured size, so a VM set to
# exactly the documented floor must still pass -- otherwise the effective floor is a
# GB higher than we tell people (bash PF_VM_MEM_GRACE_MIB, #513 reviewer).
function Get-PfVmMemGraceMib { if ($env:PF_VM_MEM_GRACE_MIB) { return [int]$env:PF_VM_MEM_GRACE_MIB } else { return 512 } }

# Cap a desired Docker-memory recommendation at what the host can actually give
# (physical RAM minus the OS reserve), so we never advise more than the machine
# physically has — e.g. "give Docker 16 GB" on a 15 GB laptop (#417).
#
# NEVER returns below the client's own minimum. A floor of 1 GB produced advice
# the user could not act on: on a 6 GB host the cap is 4, so the sub-floor branch
# printed "Give Docker at least 5 GB (up to 4 GB)" and a concrete
# "memory=4GB" — an empty range whose value is below the 5 GB the same sentence
# demands. Flooring at the minimum keeps every printed figure self-consistent;
# a host that genuinely cannot reach the floor is handled by the host-too-small
# branch in Show-MemoryStatus, not by a sub-floor number. This mirrors bash's
# _pf_clamp_mem_gb exactly (preflight.sh, #428/#513) so the two installers give
# the same advice on the same hardware.
function Get-PfMemRecommendation([int]$DesiredGb, [int]$HostGb) {
  $minMemGb = Get-PfMinMemGb
  $cap = $HostGb - (Get-PfOsReserveGb)
  if ($cap -lt $minMemGb) { $cap = $minMemGb }
  if ($DesiredGb -lt $cap) { return $DesiredGb }
  return $cap
}

# Assess memory and print the consistent warn/ok line(s) (#417). Grades the
# EFFECTIVE figure the client actually gets — Docker's VM budget when known, else
# host RAM — so a throttled budget is never green-OK'd (reviewer). ALWAYS reports
# host RAM as the label so the number doesn't flip-flop across re-runs; if host RAM
# is unreadable (locked-down machine) but the budget is, reports the budget,
# labelled as Docker's share. Warn-only. Shared by Step-1 preflight and the
# post-Docker re-check so their wording never diverges.
function Show-MemoryStatus {
  param($HostGb, $BudgetGb)   # either may be $null
  $minMemGb   = Get-PfMinMemGb
  $warnMemGb  = Get-PfWarnMemGb
  $recMemGb   = Get-PfRecMemGb
  $reserveGb  = Get-PfOsReserveGb

  # Effective = what the client actually gets; grade on this.
  $effective = if ($null -ne $BudgetGb) { $BudgetGb } elseif ($null -ne $HostGb) { $HostGb } else { $null }
  if ($null -eq $effective) { Warn "Memory: couldn't determine total RAM (skipping)."; return }

  # Label = host RAM (consistent). Host unreadable but budget known -> report the budget.
  if ($null -ne $HostGb) {
    $label = "$HostGb GB"
    $budgetNote = if ($null -ne $BudgetGb) { " (Docker's current share: $BudgetGb GB)" } else { "" }
  } else {
    $label = "$BudgetGb GB"
    $budgetNote = " (Docker's share; host RAM unreadable)"
  }
  # Cap recommendations at the host ceiling ONLY when host RAM is known. When it's
  # unreadable we have no ceiling (the budget is the current throttled value, not
  # the max), so advise the raw targets rather than capping at the budget -- which
  # produced backwards hints like "at least 5 GB (up to 2 GB)" (#483 Bugbot).
  if ($null -ne $HostGb) {
    $recTrain = Get-PfMemRecommendation -DesiredGb $recMemGb  -HostGb $HostGb
    $recRun   = Get-PfMemRecommendation -DesiredGb $warnMemGb -HostGb $HostGb
  } else {
    $recTrain = $recMemGb
    $recRun   = $warnMemGb
  }
  # A throttled Docker budget is fixed at the daemon; a small host needs more RAM.
  # A host that cannot reach the floor even with the OS reserve honoured is too
  # small for tracebloc no matter how Docker is configured, so it is NOT a budget
  # bottleneck — a resize hint there is a dead end that repeats an unachievable
  # size. Mirrors the bash recheck's host-too-small branch (preflight.sh, #428).
  $hostTooSmall = ($null -ne $HostGb) -and (($HostGb - $reserveGb) -lt $minMemGb)
  $budgetIsBottleneck = ($null -ne $BudgetGb) -and ($null -eq $HostGb -or $BudgetGb -lt $HostGb) -and (-not $hostTooSmall)

  if ($effective -lt $minMemGb) {
    Warn "Memory: $label$budgetNote - below the $minMemGb GB the client needs; it will OOM."
    if ($budgetIsBottleneck) {
      Hint "Give Docker at least $minMemGb GB (up to $recRun GB): WSL2 backend - [wsl2] memory=${recRun}GB in %UserProfile%\.wslconfig + 'wsl --shutdown'; Hyper-V - Docker Desktop -> Settings -> Resources -> Advanced."
    } elseif ($hostTooSmall) {
      # Name the OS reserve and the resulting practical minimum. Without it, a
      # 5-6 GB host reads "you have 6 GB, you need 5 GB, get a bigger machine",
      # which looks self-contradictory (Bugbot) — the shortfall only makes sense
      # once the ~2 GB the OS needs is stated. Mirrors bash's reserve-aware copy
      # in _pf_recheck_runtime_mem.
      Hint "This machine has $label of RAM total - too little for tracebloc: the client needs a $minMemGb GB Docker budget and the OS needs ~$reserveGb GB, so about $($minMemGb + $reserveGb) GB physical is the practical minimum. Use a larger machine."
    } else {
      Hint "This machine has $label of RAM total; the client needs at least $minMemGb GB. Free up memory or use a larger machine."
    }
  }
  elseif ($effective -lt $warnMemGb) {
    # hostTooSmall must be consulted HERE too, not only in the below-floor branch
    # (Bugbot). A 5-6 GB host with Docker down grades as "enough to run", and the
    # training hint would then print memory=5GB — a budget that leaves the OS 1 GB
    # and that this same function calls unachievable two branches up. Such a
    # machine cannot be tuned into a training box at all, so name that instead of
    # printing a number: no branch may emit a concrete memory= value for a host
    # that cannot reach the floor while keeping the OS reserve.
    if ($hostTooSmall) {
      Warn "Memory: $label$budgetNote - enough to run the client, but too little to train locally (~8 GB/job)."
      Hint "This machine has $label of RAM total and the OS needs ~$reserveGb GB, so it cannot give Docker a training-sized budget. Run the client here and train on a larger machine."
    } else {
      Warn "Memory: $label$budgetNote - enough to run the client, but training (~8 GB/job) may OOM; $recTrain GB recommended to train locally."
      Hint "For local training, give Docker up to $recTrain GB: WSL2 backend - [wsl2] memory=${recTrain}GB in %UserProfile%\.wslconfig + 'wsl --shutdown'; Hyper-V - Docker Desktop -> Settings -> Resources -> Advanced."
    }
  }
  else {
    Ok "Memory: $label$budgetNote"
  }
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
  # Memory thresholds live in Show-MemoryStatus (it reads the PF_*_MEM_GB env vars
  # itself), so they aren't declared here anymore (#417 reviewer).
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

  # Memory (warn-only on Windows). Report HOST RAM as the label so the number is
  # identical whether Docker is up or down (#417), but GRADE the effective figure
  # the client actually gets — Docker's VM budget when the daemon is already up at
  # preflight, else host RAM — so a throttled budget is never green-OK'd (reviewer).
  # At preflight Docker is usually down, so this grades host; Test-PreflightRuntimeMem
  # re-runs the same assessment once Docker is up and its budget is known.
  Show-MemoryStatus -HostGb (Get-PfMemGb) -BudgetGb (Get-PfRuntimeMemGb)

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
    # auth.docker.io is Docker Hub's token endpoint: a network that allows
    # registry-1 but blocks the token host fails only at in-cluster pull time (#416).
    @{ label = "Docker Hub auth (auth.docker.io)";            url = "https://auth.docker.io/token" },
    @{ label = "GitHub Container Registry (ghcr.io)";         url = "https://ghcr.io/" },
    @{ label = "tracebloc API ($backendHost)";                url = "https://$backendHost/" },
    # The chart repo is probed at its index.yaml, strictly: the site ROOT 404s by
    # design (so "any response = reachable" proves nothing), while the index must
    # actually exist for `helm repo add` to succeed (#385).
    @{ label = "tracebloc Helm charts (tracebloc.github.io)"; url = "$TRACEBLOC_HELM_REPO_URL/index.yaml"; strict = $true }
  )
  # Download hosts Step 1 fetches from — promoted to HARD (#416): a blocked one
  # used to pass preflight then fail the install ~30s later. Added only when the
  # fetch will actually happen (tool/app absent; a present tool is never
  # re-downloaded). k3d release assets 302 to objects.githubusercontent.com, so it
  # is probed explicitly. Kept in lockstep with preflight.sh (drift: check-drift.sh).
  if (-not (Test-Path "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe")) {
    $criticals += @{ label = "Docker Desktop (desktop.docker.com)"; url = "https://desktop.docker.com/" }
  }
  if (-not (Has "kubectl")) { $criticals += @{ label = "kubectl (dl.k8s.io)"; url = "https://dl.k8s.io/" } }
  if (-not (Has "helm"))    { $criticals += @{ label = "Helm (get.helm.sh)";  url = "https://get.helm.sh/" } }
  if (-not (Has "k3d")) {
    $criticals += @{ label = "k3d download (github.com)";                  url = "https://github.com/" }
    $criticals += @{ label = "k3d assets (objects.githubusercontent.com)"; url = "https://objects.githubusercontent.com/" }
  }
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
  if ($tlsSeen)    {
    Hint "A TLS/certificate error usually means a break-and-inspect (TLS-inspecting) proxy whose corporate CA isn't trusted here."
    Hint "Fix THESE host checks by importing the CA into the Windows certificate store (Cert:\LocalMachine\Root) - Invoke-WebRequest uses the system store, not an env var. The k3d nodes are trusted separately via `$env:TRACEBLOC_CA_BUNDLE='C:\path\to\corporate-ca.pem' (CURL_CA_BUNDLE also honored) at cluster-create. Ask IT for the bundle if unsure."
  }
  if ($cfail -gt 0){ Hint "Allow HTTPS (443) egress to the host(s) named above - the always-needed set is registry-1.docker.io, auth.docker.io, ghcr.io, $backendHost, tracebloc.github.io, plus any tool-download host listed (desktop.docker.com / dl.k8s.io / get.helm.sh / github.com / objects.githubusercontent.com) - or configure your corporate proxy." }

  if ($hardFail -gt 0) {
    Write-Host ""
    Err "Preflight failed - resolve the items above and re-run. (Override at your own risk with `$env:TRACEBLOC_SKIP_PREFLIGHT=1.)"
  }
}

# Re-evaluate memory once Docker is confirmed up. Test-Preflight runs before Docker
# Desktop starts, so its read may have been host RAM, not the (smaller) Docker VM
# budget. Called from New-K3dCluster, as its FIRST statement — nothing is built yet,
# so stopping here leaves no half-made cluster behind.
#
# A sub-FLOOR budget HARD-FAILS here. This is the one point the REAL VM budget is
# known, and a VM below the floor OOM-crashloops the client, so proceeding is worse
# than the jarring stop this used to prefer. bash reached the same conclusion and
# enforces it on every OS (_pf_recheck_runtime_mem -> error -> exit 1, #513); Windows
# only ever WARNED, so the platform this whole memory story is about was the one
# platform that still shipped the crash. A between-floor-and-warn budget still only
# warns (it can run, just tightly) — that grading stays in Show-MemoryStatus, which
# remains purely presentational; enforcement lives here, mirroring bash's split.
function Test-PreflightRuntimeMem {
  if ($env:TRACEBLOC_SKIP_PREFLIGHT) { return }
  # One `docker info` read, in MiB, so the number we PRINT and the number we ENFORCE
  # on cannot disagree; GB is derived from it rather than read separately.
  $mib = Get-PfRuntimeMemMib
  if ($null -eq $mib) { return }              # daemon not reporting — nothing to add
  $grace = Get-PfVmMemGraceMib
  # Grade/report the CONFIGURED size, not the flooring artifact. A guest reports a few
  # hundred MiB under its configured size, so a VM set to exactly the floor gives
  # floor(4800/1024) = 4 — and Show-MemoryStatus would then print hard-floor "it will
  # OOM" copy for a machine the gate below ACCEPTS, telling a correctly configured box
  # it will crash and then carrying on (Bugbot). Folding in the SAME grace before
  # flooring recovers the configured GB (4800 + 512 -> 5) and leaves a genuinely
  # sub-floor VM exactly where it was (4096 + 512 -> 4). Because both the grade and
  # the gate now pivot on the same grace, their boundaries coincide at
  # (floor * 1024 - grace) MiB: there is no band that warns "will OOM" yet proceeds,
  # and none that passes while being called sub-floor.
  $budget = [int][math]::Floor(($mib + $grace) / 1024)
  $hostGb = Get-PfMemGb

  # Re-run the SAME assessment now that Docker's budget is known, so both floors
  # (min "will OOM" + warn "training may OOM") apply to the budget and the wording
  # matches Step-1 (#417 reviewer). Host RAM stays the reported label.
  Show-MemoryStatus -HostGb $hostGb -BudgetGb $budget

  $minGb = Get-PfMinMemGb
  # Grace band, not a bare `-lt $minGb`: see Get-PfRuntimeMemMib. A VM at exactly the
  # documented floor passes; a genuinely sub-floor one (e.g. 4 GB) does not. Same
  # $grace as the grade above, so this boundary and that one are the same boundary.
  if ($mib -ge (($minGb * 1024) - $grace)) { return }

  $reserveGb = Get-PfOsReserveGb
  Write-Host ""
  if ($null -ne $hostGb -and ($hostGb - $reserveGb) -lt $minGb) {
    # No Docker setting can fix this one, so don't offer a resize that repeats an
    # unachievable size — name the practical minimum instead (matches the
    # host-too-small copy Show-MemoryStatus prints, and bash's #428 branch).
    Write-PfFail "This machine has $hostGb GB RAM - too little for tracebloc: the client needs a $minGb GB Docker budget and Windows needs ~$reserveGb GB, so about $($minGb + $reserveGb) GB physical is the practical minimum."
    Hint "No Docker setting fixes this - run the client on a larger machine."
  } else {
    # Achievable target: clamped to this host when we know its size, else the raw
    # run target (no ceiling is known, so don't cap at the throttled budget, #483).
    $target = if ($null -ne $hostGb) { Get-PfMemRecommendation -DesiredGb (Get-PfWarnMemGb) -HostGb $hostGb } else { Get-PfWarnMemGb }
    Write-PfFail "Docker's VM has only $budget GB - below the $minGb GB the tracebloc client needs; it will OOM-crashloop."
    Hint "Raise it to >= $target GB, then re-run: WSL2 backend - set [wsl2] memory=${target}GB in %UserProfile%\.wslconfig and run 'wsl --shutdown'; Hyper-V backend - Docker Desktop -> Settings -> Resources -> Advanced."
  }
  Err "Not enough memory for the tracebloc client. (Override at your own risk with `$env:TRACEBLOC_SKIP_PREFLIGHT=1.)"
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
    Write-Host "  Could not create the diagnostics archive." -ForegroundColor Red; Log "Could not create the diagnostics archive."
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
  Step 4 $script:INSTALL_STEPS.Count "Install the tracebloc CLI"

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
# Top-level error boundary (#577): any unhandled terminating error in the install
# run below is converted to a clean "Installation stopped" message + exit — never
# PowerShell's raw stack/source dump, and the session never just dies. Intentional
# `exit` calls (fast-path, Err, final) pass straight through; only real crashes are
# caught. $ErrorActionPreference is left as-is so existing non-terminating-error
# flows are unchanged — this catches the throw-based crashes that leaked/killed.
# The `finally` is the guaranteed closer (mirrors bash's install_cleanup): it fires
# on every exit, and shows the interrupted line only when no outcome was reported
# (Ctrl-C / abnormal termination). The `trap` is the last-resort net for anything
# that terminates OUTSIDE the try below (defined inside the guard so it never fires
# under the test dot-source).
$script:OutcomeReported = $false
trap { Show-FatalError $_; exit 1 }
try {

if ($Help) { $script:OutcomeReported = $true; Print-Help }
if ($Diagnose) { $script:OutcomeReported = $true; Invoke-DiagnoseBundle; exit 0 }

Confirm-Config
Initialize-ToolDir
Start-InstallLog
# Load the install state up front (#420): drives the fast nothing-to-do path.
# Missing/corrupt -> a fresh state (never fatal).
$script:InstallState = Read-InstallState
Print-Banner
if ($Resume) { Ok "Resuming the tracebloc install after a reboot..." }
Print-Roadmap

# Fast path (#420): a prior run completed successfully AND the tools + a RUNNING
# cluster + Ready client workloads are all still here -> nothing to do. Honest: it
# verifies live health (not just the checkpoint), so a stopped cluster or a down
# client falls through to the repairing walk. Skipped on -Resume (a resume must
# finish the interrupted walk).
if ((-not $Resume) -and $script:InstallState.completed -and (Test-ToolsPresent) -and (Test-ClusterRunning) -and (Test-ClientHealthy)) {
  Ok "tracebloc is already installed and the client is healthy -- nothing to do."
  # A healthy cluster can still be running a DRIFTED k3s (the #547 steady state);
  # this fast-path exits before New-K3dCluster's reuse check, so warn here too
  # (Bugbot #565). Non-fatal: the client is healthy, we just flag the version.
  Test-K3sVersionDrift
  Hint "Delete $(Get-InstallStatePath) (or set a fresh HOST_DATA_DIR) to force a full reinstall."
  Unregister-ResumeAfterReboot
  Log "Already installed and healthy - nothing to do."
  $script:OutcomeReported = $true
  exit 0
}

# -- Step 1/6: Check system requirements (honest split from tool install, #422) --
Step 1 $script:INSTALL_STEPS.Count "Checking system requirements"
Test-Preflight
Find-Gpu
Enable-VirtualisationFeatures

# -- Step 2/6: Install system tools (~700 MB — Docker Desktop, kubectl, k3d, helm;
# each names its wait + shows a heartbeat + prints a summary line, #422) --
Step 2 $script:INSTALL_STEPS.Count "Installing system tools"
Install-Winget
Install-DockerDesktop
Install-NvidiaContainerToolkit
Install-Kubectl
Install-K3dAndHelm

# -- Step 3/6: Set up secure compute environment --
Step 3 $script:INSTALL_STEPS.Count "Setting up secure compute environment"
New-K3dCluster
Install-GpuDevicePlugin
Confirm-GpuNode

# -- Step 4/6: install the tracebloc CLI FIRST (#388) — it mints the machine
# credential in Step 5; a CLI-install hiccup degrades Step 5 to the legacy
# manual-credential fallback instead of aborting.
Install-TraceblocCli

# -- Step 5/6: register this machine (browser sign-in + `client create`;
# env-var credentials skip it; missing/old CLI falls back to manual prompts) --
Invoke-ProvisionClient

# -- Step 6/6 handled inside Install-ClientHelm --
Install-ClientHelm

# Verify the client actually came up before reporting anything
Wait-ForClientReady

# Provision Docker for the day-to-day (standard) user during this elevated window
# (#418) so they need zero admin actions later. Warn-only -- never fail the install.
try { Set-DailyUserProvisioning } catch { Log "daily-user provisioning error: $_" }

# The install reached the end: no reboot is pending, so clear any RunOnce
# continuation. Record completion ONLY when the client is actually CONNECTED; on any
# other outcome CLEAR a stale completed flag from an earlier success, so a re-run
# (likely started because the client is down) can't hit the fast path and skip the
# documented remediation the summary just printed (#420 reviewer + Bugbot).
Unregister-ResumeAfterReboot
if (Test-InstallConnected) { Set-InstallComplete } else { Clear-InstallCompleted }

Print-Summary
$script:OutcomeReported = $true   # Print-Summary reported the outcome (guards the finally)

Log "Install finished."

# Exit code reflects reality: connected/starting are OK; failures are non-zero.
if (-not (Test-InstallSucceeded)) { exit 1 }

} catch {
  # Any crash the run didn't handle itself lands here as a clean message, not a
  # raw stack (#577). Show-FatalError sets $script:OutcomeReported.
  Show-FatalError $_
  exit 1
} finally {
  # Guaranteed closer: this runs on EVERY exit above. Every reported path (normal
  # finish, Err, caught crash, fast-path, help/diagnose) set OutcomeReported; if it
  # is still false we were interrupted (Ctrl-C / abnormal), so surface a clean line
  # rather than letting the window vanish silently (#577).
  if (-not $script:OutcomeReported) { Show-Interrupted }
}

}  # end TB_PESTER guard (skipped when the test suite dot-sources this file)
