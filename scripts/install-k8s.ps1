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
#    $env:K8S_VERSION   = "v1.36.3-k3s1"  default: v1.36.3-k3s1 (pinned + validated; "latest" is UNSUPPORTED — see #547)
#    $env:HOST_DATA_DIR = "C:\data"        default: $env:USERPROFILE\.tracebloc (LOCAL disk; no NFS/UNC)
#    $env:CLIENT_ENV    = "dev"            optional; if not set, CLIENT_ENV is not added to env in values
#    $env:TRACEBLOC_TRAINING_RESOURCES = "cpu=4,memory=16Gi"   optional; overrides the machine-sized training default
# =============================================================================

#Requires -Version 5.1
param([switch]$Help, [switch]$NoReboot, [switch]$Diagnose, [string]$DailyUser, [switch]$Resume)

# --- TRACEBLOC_SKIP_REBOOT_PROMPT: the env-var twin of -NoReboot (backend#2675)
# The documented Windows entry point is `irm https://tracebloc.io/i.ps1 | iex`,
# and `iex` has nowhere to put a switch: install.ps1 forwards `$args` to this
# script, and an `irm | iex` launch has no `$args`. So an unattended Windows
# install -- CI, a scheduled task, an auto-logon session -- had NO way to say
# "don't ask me about the reboot", while the bash twin has had one for as long
# as the GPU path has existed (lib/gpu-nvidia.sh:53). This closes that asymmetry
# with the SAME variable name, so one contract covers both platforms.
#
# Folded into $NoReboot rather than read at the prompt site so it also reaches
# the elevated relaunch and the registered resume, both of which pass the SWITCH
# on ($NoReboot is forwarded by Get-ElevationCommand / Register-ResumeAfterReboot
# while TRACEBLOC_* env vars deliberately are not -- ShellExecute/RunAs does not
# inherit the caller's environment). A run that opted out of the prompt must stay
# opted out after it elevates, or the hang simply moves one process along.
if ($env:TRACEBLOC_SKIP_REBOOT_PROMPT) { $NoReboot = $true }

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
  # Same, for a hand-raised failure: $MyInvocation describes the CALL to Err, so
  # ScriptLineNumber is the line that failed rather than a line inside Err.
  try {
    if ($MyInvocation.ScriptName) {
      $script:TbErrLoc = "$($MyInvocation.ScriptName):$($MyInvocation.ScriptLineNumber)"
    }
  } catch { }
  $script:OutcomeReported = $true   # Err IS a reported outcome (guards the finally)
  # AND the status it exits with, for the same reason (backend#2268). `finally`
  # cannot read an exit's code, so without this line the installer's PRIMARY
  # failure helper reached the emitter as 0 and recorded `install.run.succeeded`
  # for a failed install. A feature whose whole job is to report the truth of a
  # run, reporting the opposite, on the most common failure path there is.
  # (@saqlainsyed007 on #782.)
  $script:TbExitCode = 1
  exit 1
}
# The phase letter mirrors install-k8s.sh's `step_header a|b|c|d|e|f` so both
# twins report the SAME closed phase vocabulary. It is a letter rather than the
# step number because the numbers differ between the platforms while the phases
# do not — Windows has six numbered steps, bash six lettered ones, and they are
# not a 1:1 sequence (see the call sites).
function Step($n, $t, $l, $phase)  {
  Write-Host ""; Write-Host "Step $n/$t" -ForegroundColor Cyan -NoNewline
  Write-Host "  $l" -ForegroundColor White
  Log "== Step $n/$t : $l =="
  if ($phase -and (Get-Command -Name 'Start-TelemetryPhase' -CommandType Function -ErrorAction SilentlyContinue)) {
    Start-TelemetryPhase -Letter $phase
  }
}
function Log($m)           { if ($script:LOG_FILE) { Add-Content -Path $script:LOG_FILE -Value "[$(Get-Date -Format 'HH:mm:ss')] $m" -Encoding UTF8 -ErrorAction SilentlyContinue } }
function PromptHeader($m)  { Write-Host ""; Write-Host "  $m" -ForegroundColor White; Log $m }
function Hint($m)          { Write-Host "  $m" -ForegroundColor DarkGray; Log $m }
function Has($cmd)         { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# ── Telemetry (backend#2268) ─────────────────────────────────────────────────
# Sourced right after the logging helpers, mirroring install-k8s.sh:67, so the
# emitter is available to every step below and can hand its record to `Log`.
#
# OPTIONAL BY CONSTRUCTION. A local run from a checkout that predates the lib, or
# a bootstrap that could not fetch it, must still install: the guard below is why
# every call site tests for the function before using it. An installer that
# refused to run because its telemetry was missing would be a strictly worse
# installer, and that is the whole posture of this feature.
# The version the bootstrap pinned, mirroring common.sh:1128
# (`TB_VERSION="${TB_VERSION:-${TRACEBLOC_INSTALL_REF:-}}"`). An explicit
# TB_VERSION wins; otherwise it comes from the ref install.ps1 exported. A local
# run from a checkout has neither, and `0.0.0-unknown` is the right answer there —
# §4 makes unknown a VALUE rather than an omission, because it is queryable.
if (-not $env:TB_VERSION -and $env:TRACEBLOC_INSTALL_REF) {
  $env:TB_VERSION = $env:TRACEBLOC_INSTALL_REF
}

$script:TbTelemetryLib = Join-Path $PSScriptRoot 'lib/telemetry.ps1'
if (Test-Path -LiteralPath $script:TbTelemetryLib) {
  try { . $script:TbTelemetryLib } catch { }
}

# The exit status this run will end with, as the telemetry emitter sees it.
# PowerShell gives `finally` no access to the code an `exit` is carrying, so the
# classifying sites record it here. 0 unless something says otherwise — and the
# interrupted case is derived in the `finally` from $script:OutcomeReported,
# which the installer already maintains for exactly that purpose.
$script:TbExitCode = 0

# `<file>:<line>` of the failure, set by Err and Show-FatalError. Empty on a
# successful run, and the emitter only reads it for `install.run.failed`.
$script:TbErrLoc = ''

# Declare the "complete this step and re-run" handoff AND the status it exits
# with, in one call, so the two can never disagree.
function Set-TbRerunHandoff {
  $script:TbExitCode = 2
  if (Get-Command -Name 'Set-TelemetryRerunHandoff' -CommandType Function -ErrorAction SilentlyContinue) {
    Set-TelemetryRerunHandoff
  }
}

# Top-level fatal handler (#577): convert ANY unhandled terminating error into a
# clean, branded message — never PowerShell's raw source line + stack trace — then
# the caller exits non-zero. The reason shown is the exception MESSAGE (curated at
# the throw sites, #576); the stack trace is deliberately NOT shown or logged, so
# no tracebloc internals leak. The user always sees what happened + what to do.
function Show-FatalError($err) {
  $script:OutcomeReported = $true   # this IS the reported outcome (guards the finally)
  # WHERE the run died, for telemetry (backend#2268). The emitter carried a
  # location parser — colon-splitting careful enough for Windows drive letters —
  # and nothing ever set the value, so every real Windows failure omitted source
  # attribution while the parser and its tests sat there looking finished.
  # (Bugbot on #782.) The ErrorRecord knows precisely where it came from; only the
  # file NAME survives, never the path that reached it, and the emitter closes the
  # basename against its own source vocabulary besides.
  try {
    $inv = $err.InvocationInfo
    if ($inv -and $inv.ScriptName) {
      $script:TbErrLoc = "$($inv.ScriptName):$($inv.ScriptLineNumber)"
    }
  } catch { }
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
# The LIMITS half of a training envelope: memory only, never cpu (backend#2418,
# Utilization Ladder L0.2). Twin of `_training_limits` in
# scripts/lib/install-client-helm.sh -- the two are pinned to agree by
# scripts/tests/fixtures/installer_parity.json.
#
# WHY THE TWO HALVES DIFFER. CPU is time-shared: `requests` with NO `limits`
# becomes a cgroup `cpu.weight`, a share under contention and the whole machine
# when nobody else wants it, whereas `requests == limits` becomes a `cpu.max`
# QUOTA that throttles at its ceiling even on a completely idle box. Memory is
# NOT time-shared -- exceeding the limit is an OOM kill, not a slowdown -- so
# `requests == limits` remains the load-bearing safety property and does not
# move. Guaranteed QoS is given up deliberately; the memory guarantee is what
# mattered, and CPU burstability is what lets a second job exist at all.
#
# ORDERING CONSTRAINT: needs a jobs-manager that treats RESOURCE_LIMITS as the
# COMPLETE limits envelope (client-runtime#388). An older image MERGES onto its
# built-in cpu=2,memory=8Gi literal, so an omitted `cpu` returns as a 2-core
# LIMIT under a 7-core REQUEST -- rejected by Kubernetes, pod never schedules.
function Get-TrainingLimits {
  param([string]$Size)
  $kept = @()
  foreach ($pair in ($Size -split ',')) {
    $trimmed = $pair.Trim()
    if ($trimmed -eq '') { continue }
    if ($trimmed -like 'cpu=*') { continue }
    $kept += $trimmed
  }
  # Nothing survived -- a cpu-only envelope, which is not something to guess at.
  # Return the INPUT UNCHANGED rather than an empty string: an empty
  # RESOURCE_LIMITS reads to jobs-manager as "unset", which since
  # client-runtime#388 mirrors the requests side back and resurrects the very
  # cpu limit this function exists to drop. `$Size` is never empty on a
  # reachable path -- Get-TrainingResources' fallback chain always yields one.
  if ($kept.Count -eq 0) { return $Size }
  return ($kept -join ',')
}

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
  # HasExited can flip true before the process's redirected stdout/stderr streams
  # are fully drained, and in that window Start-Process -RedirectStandardOutput
  # leaves $Process.ExitCode $null. Callers then read a null code and `$null -ne 0`
  # misreads a SUCCESSFUL run as a failure -- the #611 field case: k3d printed
  # "Cluster created successfully!" with empty stderr, yet the install aborted with
  # the cluster actually up. WaitForExit() (bounded: the process has already exited)
  # flushes the streams and guarantees ExitCode is populated for every caller.
  try { $Process.WaitForExit() } catch {}
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

# Is the file at $Path a COMPLETE download (#607)? Returns $null when it is, else a
# short reason. A proxy/AV that truncates or rewrites a binary mid-transfer leaves a
# short error page or partial file that Invoke-WebRequest reports as "success"; the
# only old signal was the downstream checksum, so a user dead-ended at the cryptic
# "System tool checksum verification failed". Validate the payload is present, at
# least $MinBytes, and (when given) starts with the expected magic bytes -- "MZ" for
# a Windows .exe, "PK" for a .zip -- so a bad TRANSFER is caught distinctly from a
# checksum mismatch on a complete file. Pure (file in, reason out) so Pester can
# exercise every branch without a network.
function Test-DownloadComplete {
  param(
    [Parameter(Mandatory)][string]$Path,
    [int]$MinBytes = 1MB,
    [string]$Magic = ''
  )
  if (-not (Test-Path -LiteralPath $Path)) { return "no file was written" }
  $len = (Get-Item -LiteralPath $Path).Length
  if ($len -lt $MinBytes) { return "got $len bytes (expected at least $MinBytes) -- the transfer was truncated or blocked" }
  if ($Magic) {
    $fs = [System.IO.File]::OpenRead($Path)
    try {
      $buf = New-Object byte[] ($Magic.Length)
      $n = $fs.Read($buf, 0, $Magic.Length)
    } finally { $fs.Close() }
    $got = -join (@($buf)[0..([Math]::Max(0, $n - 1))] | ForEach-Object { [char][int]$_ })
    if ($got -ne $Magic) { return "the file is not a valid '$Magic' file (starts with '$got') -- likely an error page or an altered binary" }
  }
  return $null
}

# Resilient tool download (#607): fetch $Url to $Dest and only return once a
# COMPLETE file has landed. The transfer runs under the heartbeat spinner
# (Invoke-WithHeartbeat) as before, but is now tried over several transports in
# turn -- Invoke-WebRequest, then curl.exe, then BITS. Each uses a different HTTP
# stack, so when a proxy/AV blocks or truncates one, another commonly succeeds.
# After each transport Test-DownloadComplete gates the result, so an incomplete
# transfer moves on to the next method instead of poisoning the downstream
# checksum. Every transport failing throws one specific, actionable message.
function Get-VerifiedDownload {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Dest,
    [int]$MinBytes = 1MB,
    [string]$Magic = '',
    # When set, the CHECKSUM is the authoritative completeness test (#609): after a
    # transport lands a size/magic-valid file, its SHA-256 must equal $Sha256 or the
    # transport is treated as failed and the NEXT one is tried. A size floor alone
    # lets a mid-transfer truncation (>MinBytes, still starts with the magic bytes)
    # slip through and dead-end at a downstream checksum with no retry -- the real
    # field failure. With $Sha256, a truncated/corrupt copy just triggers curl.exe/
    # BITS until a byte-correct copy lands.
    [string]$Sha256 = '',
    # When set, the downloaded TEXT must MATCH this regex or the transport is treated
    # as failed and the next one (curl.exe/BITS) is tried (#611). Used to gate the
    # checksum-LIST files on the actual hash STRUCTURE, not a weak substring: an
    # asset-name substring also appears in the request URL, so a proxy error page
    # echoing the URL would satisfy a substring gate, "succeed" on the first
    # transport, skip the retry, and then abort at the later hex parse (Bugbot). The
    # call sites therefore require a 64-hex hash adjacent to the asset (k3d/helm) or
    # anchored at the start of the body (kubectl's bare-hash .sha256) -- structure a
    # proxy/HTML error page can't accidentally satisfy.
    [string]$MatchPattern = '',
    [string]$Label = 'download',
    [string]$Message = 'Downloading'
  )
  $iwr  = { param($u, $d); $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest $u -OutFile $d -UseBasicParsing -MaximumRedirection 5 }
  # style-guard: allow -- curl.exe is a deliberate FALLBACK transport here; curl_secure() is a bash helper and cannot exist in PowerShell. --tlsv1.2 mirrors its TLS floor (Bugbot).
  $curl = { param($u, $d); & curl.exe --tlsv1.2 -fSL --retry 2 --retry-delay 2 --connect-timeout 30 --max-time 900 -o $d $u 2>$null; if ($LASTEXITCODE -ne 0) { throw "curl.exe exited $LASTEXITCODE" } }  # style-guard: allow
  $bits = { param($u, $d); Import-Module BitsTransfer -ErrorAction SilentlyContinue; Start-BitsTransfer -Source $u -Destination $d -ErrorAction Stop }

  $transports = @( ,@('Invoke-WebRequest', $iwr) )
  if (Get-Command curl.exe -ErrorAction SilentlyContinue) { $transports += ,@('curl.exe', $curl) }  # style-guard: allow -- presence check + fallback registration, not a bare fetch
  $transports += ,@('BITS', $bits)

  $problems = @()
  foreach ($t in $transports) {
    $name = $t[0]; $block = $t[1]
    Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
    try {
      Invoke-WithHeartbeat -Message $Message -ArgumentList @($Url, $Dest) -Script $block
    } catch {
      $problems += "${name}: $($_.Exception.Message)"
      continue
    }
    # Validation must not escape the loop: Get-Item/OpenRead can throw if AV locks
    # or quarantines the just-written file, and that is exactly a case where the
    # NEXT transport should be tried, not the whole download aborted (Bugbot).
    try {
      $bad = Test-DownloadComplete -Path $Dest -MinBytes $MinBytes -Magic $Magic
      if (-not $bad -and $Sha256) {
        $got = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $Sha256.ToLower()) {
          $bad = "checksum mismatch (got $got) -- the download is truncated or altered"
        }
      }
      if (-not $bad -and $MatchPattern) {
        $text = Get-Content -LiteralPath $Dest -Raw -ErrorAction Stop
        if ($text -notmatch $MatchPattern) {
          $bad = "the file did not match the expected checksum pattern -- likely a proxy error page; trying another method"
        }
      }
    } catch {
      $bad = "could not read the downloaded file ($($_.Exception.Message)) -- it may be locked or quarantined by antivirus"
    }
    if (-not $bad) { return }        # complete + (checksum/content) valid -- done
    $problems += "${name}: $bad"
    Warn "$Label via $name looked incomplete ($bad); trying another method..."
  }
  Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
  throw ("Couldn't download a complete file from $Url (tried: $(($transports | ForEach-Object { $_[0] }) -join ', ')). " +
         ($problems -join ' | ') + ". On a filtered network a proxy or antivirus may be blocking or " +
         "rewriting the binary -- allowlist github.com, objects.githubusercontent.com, dl.k8s.io and " +
         "get.helm.sh (or exclude the tools folder from AV scanning), then re-run.")
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
$K8S_VERSION   = if ($env:K8S_VERSION)   { $env:K8S_VERSION }   else { "v1.36.3-k3s1" }
$HOST_DATA_DIR = if ($env:HOST_DATA_DIR) { $env:HOST_DATA_DIR } else { "$env:USERPROFILE\.tracebloc" }
# backend#743: optional separate dir for the big dataset volume. Empty (default)
# keeps datasets under HOST_DATA_DIR. When set, it is bind-mounted at
# /tracebloc-data and the chart's dataset PV points there (mysql + logs stay
# local). The host-uid ingestion mechanism for root_squash NFS is Linux-only; on
# Windows k3d runs in a Linux VM where Docker Desktop handles mount ownership.
$HOST_DATASET_DIR = if ($env:HOST_DATASET_DIR) { $env:HOST_DATASET_DIR } else { "" }

# Kubelet image-GC thresholds (backend#2634). The bash twin holds the identical
# three values in scripts/lib/cluster.sh and
# scripts/tests/kubelet-config-agreement.sh derives both sides and fails the build
# on divergence -- so these are one contract in two files, not two sources.
# NOT env-overridable, deliberately: an operator who lowers `high` to 95 to "get
# more disk" re-creates the unbounded image store, and the value that matters is
# the RELATIONSHIP between the two (the band must exceed one task image), which a
# single env var cannot express safely.
$TB_KUBELET_IMAGE_GC_HIGH_PERCENT = 75
$TB_KUBELET_IMAGE_GC_LOW_PERCENT  = 60
$TB_KUBELET_IMAGE_MIN_GC_AGE      = "2m"
# Path the config is mounted to INSIDE every k3d node. Named once so the volume
# mount and the --kubelet-arg cannot disagree about it.
$TB_KUBELET_CONFIG_NODE_PATH      = "/etc/tracebloc/kubelet.yaml"

# Pre-create the per-release hostPath dirs the chart's PVs bind to (logs, mysql,
# data), mirroring bash _ensure_release_dirs (scripts/lib/cluster.sh). Without
# these the mount target does not exist yet and the first dataset ingest fails
# with "Permission denied" on Windows (#653). Datasets go under HOST_DATASET_DIR
# when set, else stay on HOST_DATA_DIR (backend#743). Idempotent.
function Ensure-ReleaseDirs($release) {
  if (-not $release) { return }
  $base = Join-Path $script:HOST_DATA_DIR $release
  $dataBase = if ($script:HOST_DATASET_DIR) { Join-Path $script:HOST_DATASET_DIR $release } else { $base }
  foreach ($d in @((Join-Path $base 'logs'), (Join-Path $base 'mysql'), (Join-Path $dataBase 'data'))) {
    # Fail closed: -Force already makes this idempotent, so the only thing
    # SilentlyContinue bought was swallowing a real create failure (ACL, AV lock,
    # path conflict) — which then surfaces as the very Windows "Permission denied"
    # this pre-create is meant to prevent, after the installer already printed
    # "connected". Stop matches bash's `mkdir -p` under `set -e` (Bugbot, #653).
    New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null
  }
}

# Prove the k3d nodes can actually SEE the host tree, before helm writes anything.
# Mirrors bash _verify_nodes_see_host_data (scripts/lib/cluster.sh) -- keep the two
# in lockstep.
#
# /tracebloc is the k3d bind mount of HOST_DATA_DIR. When it is not in effect
# NOTHING fails: kubelet's DirectoryOrCreate fabricates the dirs inside the node,
# the PVC Binds, the pod Runs, MySQL initialises an empty datadir and the dataset
# dir reads as zero rows -- no event, no warning, and the data goes with the node
# on the next `cluster delete`. This is the Windows/Docker-Desktop path's problem
# specifically: a HOST_DATA_DIR outside the shared drives yields exactly that.
#
# The chart-side fix is NOT available: setting the PVs to `type: Directory` so
# kubelet refuses is rejected by the API server on any existing release
# ("spec.persistentvolumesource is immutable after creation"), failing the helm
# upgrade of every install that already has PVs. Measured on k3s v1.36.3.
#
# Fails CLOSED -- an unreadable marker, a node that cannot be exec'd, or an
# unobtainable node list all stop the install. "Cannot tell" is a finding.
function Assert-NodesSeeHostData {
  $marker = ".tracebloc-mount-probe"
  # Content, not presence: a mount pointed at the WRONG directory still shows a
  # file of this name from an earlier run. Only a token minted now proves it.
  # NEVER [double]::Parse a `Get-Date -UFormat %s` string: that string uses a
  # PERIOD decimal separator while Parse uses the CURRENT CULTURE, so on de-DE /
  # fr-FR and friends it throws FormatException before the probe even runs -- the
  # cluster is already up and the operator gets a cryptic .NET parse error instead
  # of a mount check (Bugbot, High). ToUnixTimeSeconds returns an integer, so
  # nothing is parsed and no culture is involved. Same shape as the bash twin's
  # $$-$RANDOM-$(date +%s).
  $token  = "$PID-$(Get-Random)-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
  $hostMarker = Join-Path $script:HOST_DATA_DIR $marker
  try { Set-Content -Path $hostMarker -Value $token -NoNewline -ErrorAction Stop }
  catch { throw "Can't write to $($script:HOST_DATA_DIR) -- check the directory exists and you own it, then re-run." }

  try {
    # Selected by k3d's own LABELS, not by node name.
    #
    #   * `label=k3d.cluster=<name>` is an EXACT value match, so a same-prefixed
    #     sibling cluster cannot leak in. `name=k3d-<name>-` is an unanchored
    #     SUBSTRING match and would also list `k3d-<name>-dev-server-0`; if that
    #     sibling was created against a different HOST_DATA_DIR its nodes cannot
    #     see this token, and the probe would refuse THIS install while naming a
    #     node that is not ours -- a false refusal, the one failure mode a
    #     fail-closed guard most has to avoid (@saqlainsyed007 on #817).
    #   * `k3d.role` says what each container IS, so the load balancer is excluded
    #     because it is a `loadbalancer`, not because its name ends in `-serverlb`.
    #
    # Invoke-DockerCli, not a bare `docker`: a WEDGED (not stopped) daemon never
    # returns, which would freeze a headless install right here with no further
    # output -- the exact failure this guard exists to replace with a clear
    # refusal (Bugbot). `docker ps` lists RUNNING containers only, so a
    # created-but-stopped node cannot be mistaken for one that passed.
    # ONE QUERY PER ROLE, and NO ARGUMENT CONTAINS A SPACE OR A QUOTE. That is a
    # hard requirement on this platform, not a style choice: $psi.Arguments joins
    # the args into a single command line and quotes any whitespace-bearing value as
    # '"' + $_ + '"' with NO escaping of inner quotes (see its note). The obvious
    # single query -- `--format "{{.Names}} {{.Label `"k3d.role`"}}"` -- has both a
    # space AND quotes, so it went out as
    #     --format "{{.Names}} {{.Label "k3d.role"}}"
    # and CommandLineToArgvW toggles in and out of quoting to yield ONE token with
    # the inner quotes CONSUMED: `{{.Names}} {{.Label k3d.role}}`. docker then gets
    # an intact --format whose Go template has lost the quoting on its string
    # literal, text/template cannot parse k3d.role as an identifier, docker exits
    # non-zero, $nodes stays empty and the probe throws "Couldn't list the nodes" --
    # a FALSE REFUSAL on every Windows hostpath install, after the cluster is up.
    # (@saadqbal / Bugbot on #817; the bash twin passes an array and never re-joins,
    # so it was never exposed.)
    #
    # Asking docker to AND two label filters removes the need for a quoted format
    # entirely: `{{.Names}}` alone has no space, and `label=k3d.role=server` has
    # neither. It also drops the role parsing, and the load balancer is excluded by
    # construction -- its role is `loadbalancer`, which is simply never queried.
    #
    # -StdoutOnly for the same reason as the exec call below.
    $nodes = @()
    foreach ($role in @("server", "agent")) {
      $psr = Invoke-DockerCli -DockerArgs @(
        "ps", "--filter", "label=k3d.cluster=$($script:CLUSTER_NAME)",
        "--filter", "label=k3d.role=$role",
        "--format", "{{.Names}}") -TimeoutSec 10 -StdoutOnly
      # Fail closed per role: an empty list is legitimate (AGENTS=0 has no agent),
      # but a docker that ERRORED tells us nothing and must not read as "none".
      if ($psr.Code -ne 0) {
        throw "Couldn't list the nodes of cluster '$($script:CLUSTER_NAME)' to check your data directory is visible inside it. Check 'docker ps' works, then re-run."
      }
      $nodes += @($psr.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if ($nodes.Count -eq 0) {
      throw "Couldn't list the nodes of cluster '$($script:CLUSTER_NAME)' to check your data directory is visible inside it. Check 'docker ps' works, then re-run."
    }

    foreach ($node in $nodes) {
      # AGENTS defaults to 1 and agents run kubelets, so a training pod can land on
      # an agent -- every node is checked, not just the server (the same @all-vs-
      # @server trap as the cgroup v1 flag, #806).
      # -StdoutOnly is REQUIRED here, not tidiness: the marker is written -NoNewline,
      # so `cat` emits the token with no trailing newline and any docker stderr
      # chatter glues onto the token INSIDE THE SAME LINE. That is why "take the first
      # non-empty line" does not fix this -- the first line is already
      # "<token>WARNING: ..." (@saadqbal on #817). Isolating stdout removes the
      # possibility rather than trying to parse around it, and matches the bash twin's
      # 2>/dev/null. A false refusal here is the single worst outcome for this guard:
      # it would abort a perfectly good install after the cluster is up.
      $r = Invoke-DockerCli -DockerArgs @("exec", $node, "cat", "/tracebloc/$marker") -TimeoutSec 10 -StdoutOnly
      $seen = if ($r.Code -eq 0) { ($r.Output -join "").Trim() } else { "" }
      if ($seen -ne $token) {
        throw @"
Node '$node' cannot see your data directory ($($script:HOST_DATA_DIR)).

  Everything would appear to install, but the secure environment would store your
  data INSIDE the node instead of on this machine -- and lose it when the cluster is
  recreated. Refusing to continue.

  Most likely causes:
    * Docker Desktop is not sharing this path. Add it under
      Settings -> Resources -> File sharing, then re-run.
    * The cluster was created without the data mount. Recreate it:
      'k3d cluster delete $($script:CLUSTER_NAME)' then re-run this installer.
    * HOST_DATA_DIR changed since the cluster was created.
"@
      }
    }
  }
  finally { Remove-Item -Path $hostMarker -Force -ErrorAction SilentlyContinue }
}
$CLIENT_ENV    = $env:CLIENT_ENV

$GPU_VENDOR       = "none"
$NVIDIA_DRIVER_OK = $false
$K3D_GPU_FLAG     = ""
# #616: when a GPU + driver are present but the GPU can't be wired into the cluster, this
# holds the human-readable reason so Print-Summary + the doctor can say WHY we fell back to
# CPU instead of silently running CPU-only. Empty = GPU enabled, or no GPU to begin with.
$GPU_SKIP_REASON  = ""
# #616: CDI device selector for GPU training pods, set ONLY on the Docker Desktop/WSL2 path
# (where the NVML device plugin can't work and pods get the GPU via a CDI spec). Written to the
# chart as env.GPU_VISIBLE_DEVICES, which jobs-manager threads into GPU pods as
# NVIDIA_VISIBLE_DEVICES (client-runtime#291). Deliberately EMPTY on a normal device-plugin
# (Linux) node: there the plugin owns NVIDIA_VISIBLE_DEVICES and sets concrete GPU UUIDs, so
# forcing a CDI selector would break device resolution. Empty => the chart passes nothing.
$GPU_DEVICE_SELECTOR = ""
# Detected NVIDIA driver version, quoted back in a GPU-skip reason so the operator can tell at a
# glance whether theirs is new enough for WSL2 CUDA (#616). Empty until Confirm-NvidiaDriver runs.
$NVIDIA_DRIVER_VERSION = ""
# Set by preflight when a GPU download host (nvcr.io / nvidia.github.io / the configured GPU
# registry) is unreachable. The GPU gate short-circuits on it so we fail fast to CPU with that
# reason instead of burning minutes on probes/pulls that cannot succeed (#616 Bugbot).
$GPU_HOSTS_UNREACHABLE = ""
# #616: the CUDA base + custom k3s-CUDA node image used when the GPU is enabled. The k3s-CUDA
# tag encodes both the k3s pin ($K8S_VERSION) and the CUDA base, matching docker/k3s-cuda/build.sh.
# The installer PULLS this image automatically at cluster-create — the user never builds or pulls
# anything by hand. TRACEBLOC_K3S_CUDA_IMAGE overrides the whole ref; TRACEBLOC_CUDA_BASE_TAG
# overrides just the CUDA base used for the capability probe and the default tag. When a private
# mirror is configured (TRACEBLOC_IMAGE_REGISTRY, #585) the default re-homes onto it so the one
# installer command works air-gapped, same as every other image.
$CUDA_BASE_TAG  = if ($env:TRACEBLOC_CUDA_BASE_TAG) { $env:TRACEBLOC_CUDA_BASE_TAG } else { "12.4.1-base-ubuntu22.04" }
$K3S_CUDA_IMAGE = if ($env:TRACEBLOC_K3S_CUDA_IMAGE) {
  $env:TRACEBLOC_K3S_CUDA_IMAGE
} else {
  $cudaRepo = "tracebloc/k3s-cuda:$K8S_VERSION-cuda-$CUDA_BASE_TAG"
  if ($env:TRACEBLOC_IMAGE_REGISTRY) {
    $mirrorHost = ($env:TRACEBLOC_IMAGE_REGISTRY -replace '^[a-zA-Z][a-zA-Z0-9+.\-]*://', '') -replace '/+$', ''
    "$mirrorHost/$cudaRepo"
  } else {
    "ghcr.io/$cudaRepo"
  }
}
# The GPU-passthrough probe (Confirm-DockerGpu) runs nvidia-smi in a CUDA container. Re-home
# that image onto the mirror too when one is set (#585 / Bugbot), so a mirrored/air-gapped
# GPU install doesn't fall back to CPU just because Docker Hub's nvidia/cuda is blocked.
$CUDA_PROBE_IMAGE = if ($env:TRACEBLOC_IMAGE_REGISTRY) {
  $mp = ($env:TRACEBLOC_IMAGE_REGISTRY -replace '^[a-zA-Z][a-zA-Z0-9+.\-]*://', '') -replace '/+$', ''
  "$mp/nvidia/cuda:$CUDA_BASE_TAG"
} else {
  "nvidia/cuda:$CUDA_BASE_TAG"
}
$ReadyTimeout     = if ($env:READY_TIMEOUT) { $env:READY_TIMEOUT } else { "600" }   # #562: raised 300 -> 600 for slow/proxied machines; kept in sync with facts.env (check-facts.sh)
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
  K8S_VERSION    k3s image tag                   (default: v1.36.3-k3s1)
  -NoReboot      Skip reboot prompt after enabling Windows features
  TRACEBLOC_SKIP_REBOOT_PROMPT=1
                 Same as -NoReboot, for the `irm ... | iex` entry point, which
                 has no way to pass a switch (bash twin: same variable name)
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
    # UTF-8 without BOM, matching the file's other writers (UTF8Encoding($false) at
    # L1780/L1829/L4226): Set-Content -Encoding UTF8 prepends a BOM on PS 5.1, so the
    # log would start with EF BB BF (Saqlain, #591). WriteAllText throws into the catch
    # on failure like -ErrorAction Stop; the trailing CRLF keeps Set-Content's newline.
    [System.IO.File]::WriteAllText($LOG_FILE, "tracebloc client installer log - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n", (New-Object System.Text.UTF8Encoding($false)))
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

# The CLI floor the installer actively repairs (client#707). 0.10.0 is the release
# where the CLI gained its own update nudge: at or above it a user can keep
# themselves current, below it NOTHING on the machine can tell them they are
# behind. A floor, not a "must be latest" — so this needs no network call and
# never needs raising.
$script:TB_CLI_MIN_VERSION = "0.10.0"

# Is the tracebloc CLI present AND new enough to maintain itself?
#
# The fast path must not shortcut past Install-TraceblocCli when it isn't, for
# TWO reasons on Windows:
#   * Test-ToolsPresent covers docker/kubectl/k3d/helm — the CLI is not in it at
#     all, so a stale CLI was invisible; and
#   * `completed` is set purely from ClientState -eq "connected", which says
#     nothing about the CLI, while Install-TraceblocCli is deliberately
#     non-fatal. A machine whose CLI install FAILED was therefore marked complete
#     and never retried — permanently CLI-less, not merely stale.
#
# Fails OPEN on an unreadable version: that is not evidence of staleness, and
# re-running the CLI install on every invocation would be worse than the problem.
function Test-TraceblocCliCurrent {
  if (-not (Has "tracebloc")) { return $false }
  $ver = ""
  try { $ver = (& tracebloc version 2>$null | Select-Object -First 1) } catch { $ver = "" }
  if ($ver -notmatch '(\d+(?:\.\d+)+)') { return $true }
  try { return ([version]$Matches[1] -ge [version]$script:TB_CLI_MIN_VERSION) } catch { return $true }
}

# Pure TRI-STATE classifier from a FULL `k3d cluster list -o json` (no name filter)
# output. Distinguishes "confidently not ours" from "can't tell" so callers never
# conflate an indeterminate read with a definitive answer (#557 Bugbot 3728340365,
# 3728714531). Keyed on a SUCCESSFUL full listing (which always emits at least `[]`),
# so an ABSENT cluster is a definite answer, not an error:
#   'running' — <Name> is present with >=1 server node up
#   'down'    — the list parsed OK but does NOT contain a running <Name> (absent,
#               stopped, or an empty `[]` = no clusters at all) -> confidently not ours
#   'unknown' — empty/whitespace or unparseable output; the list itself FAILED (k3d
#               errored / produced no JSON), so nothing can be concluded
function Get-ClusterRunStateFromList {
  param([string]$Json, [string]$Name)
  if ([string]::IsNullOrWhiteSpace($Json)) { return 'unknown' }
  try { $clusters = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return 'unknown' }
  foreach ($c in @($clusters)) {
    if ($c.name -ne $Name) { continue }
    if ($c.PSObject.Properties.Name -contains 'serversRunning') {
      if ([int]$c.serversRunning -ge 1) { return 'running' }
      return 'down'   # present but 0 servers -> stopped
    }
    return 'down'     # shape without a running count can't prove the cluster is up
  }
  return 'down'       # enumerated fine; our cluster simply isn't in the list
}

# Pure: from `k3d cluster list -o json` output, is <Name> present AND running (>=1
# server node up)? A present-but-STOPPED cluster returns $false so the fast path
# doesn't skip New-K3dCluster's start/repair. Unknown/corrupt shape -> false (#420 Bugbot).
function Test-ClusterRunningInList {
  param([string]$Json, [string]$Name)
  return ((Get-ClusterRunStateFromList -Json $Json -Name $Name) -eq 'running')
}

# Is our k3d cluster present AND running? Boolean fast-path gate; delegates to the
# BOUNDED Get-ClusterRunState below (job+deadline) so a wedged Docker engine can't
# hang the fast path at the start of every re-run (#420 Bugbot). Never-fatal: a
# timeout / parse failure classifies as not-running -> $false (fall through).
function Test-ClusterRunning {
  return ((Get-ClusterRunState) -eq 'running')
}

# TRI-STATE, BOUNDED run-state of our k3d cluster, for the port-6550 ownership
# decision (#557 Bugbot 3728340365, 3728714531). Lists ALL clusters (no name
# filter) inside a job+deadline (~15s) so a wedged Docker can't hang preflight,
# then classifies:
#   'running' — our cluster is up (it legitimately owns port 6550 -> reuse)
#   'down'    — the full list came back and $CLUSTER_NAME isn't running in it
#               (absent/stopped, or no clusters at all) -> listener is foreign
#   'unknown' — the list TIMED OUT, or completed but emitted no/garbage JSON
#               (k3d itself failed): can't tell; do NOT treat as foreign -- warn
#               and let New-K3dCluster settle it.
# A NAMED list (`k3d cluster list <name>`) fatals with empty stdout when the name
# is absent, which the classifier would read as 'unknown' and wrongly let a
# genuinely-foreign listener proceed (Bugbot 3728714531). The full list always
# emits at least `[]` on success, so absent-vs-error stays separable.
function Get-ClusterRunState {
  $job = Start-Job -InitializationScript $JobInit -ScriptBlock {
    (k3d cluster list -o json 2>$null | Out-String)
  }
  $out = ""; $timedOut = $false
  if (Wait-JobWithProgress -Job $job -TimeoutSec 15 -Message "Checking cluster") {
    $out = (Receive-Job $job -ErrorAction SilentlyContinue | Out-String)
  } else {
    $timedOut = $true
    Log "k3d cluster list timed out; cluster run-state indeterminate."
  }
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  if ($timedOut) { return 'unknown' }
  return (Get-ClusterRunStateFromList -Json $out -Name $CLUSTER_NAME)
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

    # Bounded (installer external-call timeout rule / Bugbot): a wedged driver must not hang the
    # install -- and Find-Gpu now runs before the fast path, so an unbounded nvidia-smi would hang
    # every "nothing to do" re-run too.
    $dr = Invoke-BoundedProcess -FileName $nvSmi -Arguments @("--query-gpu=driver_version","--format=csv,noheader") -TimeoutSec 15
    if ($dr.Code -ne 0) { Warn "Couldn't query the NVIDIA driver (nvidia-smi failed or timed out) -- GPU checks skipped."; return }
    $driverVer = ($dr.Output -split "`n" | Select-Object -First 1).Trim()
    $majorVer  = [int]($driverVer -replace '\..*', '')
    if ($majorVer -ge 460) {
      $script:NVIDIA_DRIVER_OK = $true
      $script:NVIDIA_DRIVER_VERSION = $driverVer   # quoted back in a GPU-skip reason (#616)
      Ok "NVIDIA GPU ready (driver $driverVer)"
      # Expectation-setting only, never a gate (#387): entry-level cards pass
      # every check but are too small for real training (field: a 2 GB GT 710
      # installed fine and could never fit a model).
      try {
        $vr = Invoke-BoundedProcess -FileName $nvSmi -Arguments @("--query-gpu=memory.total","--format=csv,noheader,nounits") -TimeoutSec 15
        $vramMiB = if ($vr.Code -eq 0) { [int](($vr.Output -split "`n" | Select-Object -First 1).Trim()) } else { 0 }
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

# ASK ONLY IF SOMEONE CAN ANSWER (backend#2675). "Reboot now?" was the one
# unguarded Read-Host on the install path -- the daily-user and leftover-data
# prompts both sit behind Test-CanPrompt already -- and it is the one EVERY
# fresh Windows install reaches, because a fresh host always has WSL2 / Virtual
# Machine Platform / Hyper-V still to enable.
#
# An unanswerable prompt does not fail, it HANGS: Read-Host blocks on a console
# nobody is typing into, so the `exit 2` that follows it -- this installer's
# declared "reboot, then re-run" handoff -- is never reached, and whatever is
# driving the install sees a process that is alive and doing nothing. The e2e
# Windows journey sat here for 22 minutes and reported a timeout with no cause
# (backend#2675); a customer's scheduled or auto-logon install looks identical.
#
# "Nobody to ask" is answered the way the bash twin answers it -- gpu-nvidia.sh:
# "No tty (unattended) => treat as 'no reboot'" -- so an empty choice falls
# through to the same Set-TbRerunHandoff + exit 2 that -NoReboot takes. The
# resume RunOnce is armed before either path, so the install still continues by
# itself at the next sign-in.
#
# A FUNCTION, not an inline `if`, so the guard is reachable by the test suite:
# the caller ends in `exit 2`, which no Pester mock can intercept.
function Read-RebootChoice {
  if (-not (Test-CanPrompt)) { return "" }
  try { return (Read-Host "  Reboot now? [y/N]") } catch { return "" }
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
      # A DECLARED exit 2: "complete this step and re-run", not a failure. The
      # handoff is announced at the exit SITE so an exit 2 nobody claimed — grep
      # on a missing file, curl on a failed init — still books as a failure with
      # its own error.type instead of being filed as a cancel with none.
      Set-TbRerunHandoff
      exit 2
    }
    $choice = Read-RebootChoice
    if ($choice -match "^[Yy]$") { Restart-Computer -Force }
    if (-not $resumeArmed) { Hint "After the reboot, re-run this installer to continue." }
    Set-TbRerunHandoff   # declared: reboot then re-run (see above)
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

  # #616: a GPU + valid driver are present, so from here we WANT to enable the GPU. Assume the
  # enable won't complete and record a reason; each early-return below refines it, and the success
  # path clears it. Print-Summary + the doctor surface $GPU_SKIP_REASON so a GPU box that silently
  # falls back to CPU tells the user WHY, instead of looking like it "just uses CPU".
  $script:GPU_SKIP_REASON = "the NVIDIA container-toolkit / WSL2 GPU setup did not complete (see the install log for the specific step)"

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
    $script:GPU_SKIP_REASON = "WSL did not respond (run 'wsl --update', then re-run the installer)"
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
      $script:GPU_SKIP_REASON = "WSL2 Ubuntu install timed out (install it manually: wsl --install -d Ubuntu, then re-run)"
      return
    }
    Receive-Job $ubuntuJob | Out-Null
    Remove-Job $ubuntuJob -Force
    Warn "Ubuntu WSL2 installed but needs first-run setup."
    Hint "Open Ubuntu from the Start Menu and set a username/password."
    Hint "Then re-run this script for GPU support."
    $script:GPU_SKIP_REASON = "WSL2 Ubuntu needs first-run setup (open Ubuntu once, set a username/password, then re-run)"
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
    $script:GPU_SKIP_REASON = "NVIDIA Container Toolkit install timed out (often a blocked apt repo / proxy on restricted networks)"
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
      # Report only what this step actually established -- the toolkit is present in the WSL
      # distro. It is NOT "GPU acceleration ready" (Bugbot): Confirm-DockerGpu is the
      # authoritative gate and runs later, so a green ready line here could be followed by a
      # CPU fallback. For the same reason this must NOT set K3D_GPU_FLAG (the gate owns it,
      # and setting it early made a skipped/failed gate look enabled) and must NOT clear
      # GPU_SKIP_REASON (that would drop the real cause recorded by whatever failed).
      Info "NVIDIA Container Toolkit present in ${wslDistro}: $nctVer"
      Log "NVIDIA Container Toolkit in WSL2: $nctVer -- GPU still gated on the Docker GPU probe"
    } else {
      Warn "GPU toolkit installed but could not be verified."
      $script:GPU_SKIP_REASON = "NVIDIA Container Toolkit installed but could not be verified"
      Show-GpuManualRemedy -Distro $wslDistro
    }
  } else {
    Remove-Job $verJob -Force
    Warn "GPU toolkit verification timed out."
    $script:GPU_SKIP_REASON = "NVIDIA Container Toolkit verification timed out"
    Show-GpuManualRemedy -Distro $wslDistro
  }
}

# Quote ONE argument for a native Windows command line so CommandLineToArgvW (what the CRT and
# every well-behaved Windows program use to re-split $psi.Arguments) recovers it byte-for-byte as a
# SINGLE token. $psi.Arguments is one flat string, so each arg has to survive that re-parse.
#
# The naive "wrap anything with a space in quotes" is WRONG the moment an arg contains BOTH a space
# and a `"`: `'"' + $_ + '"'` leaves the inner quote unescaped, CommandLineToArgvW toggles in and
# out of quoting on it, and the arg comes back as ONE token with the inner quotes SILENTLY CONSUMED
# -- e.g. `--format "{{.Names}} {{.Label "k3d.role"}}"` reaches the program as
# `--format {{.Names}} {{.Label k3d.role}}` and its Go template no longer parses (backend#2455;
# #817 dodged this by never passing a quoted arg, this fixes the general helper). It also mangles a
# quote WITHOUT a space -- `a"b` has no whitespace, so the old code passed it through raw and the
# bare `"` was read as a quoting toggle.
#
# So this follows the actual CommandLineToArgvW / MSVCRT rules exactly:
#   * a non-empty arg with no whitespace and no `"` needs no quoting -- pass it through untouched
#   * otherwise wrap in `"`, and inside the quotes:
#       - `"`               -> `\"`
#       - a run of N `\` immediately before a `"`  -> 2N+1 `\` then `"`  (backslashes escape each
#         other, and the last one escapes the quote)
#       - a run of N `\` at the very END of the arg -> 2N `\`  (doubled so the CLOSING quote we add
#         is not itself escaped; a raw trailing `\` before the close would eat it)
#       - `\` anywhere else is literal and left as-is
#   * the empty string becomes `""` so it survives as a present-but-empty argument
# Callers therefore pass RAW args and never pre-quote (the old code left `^".*"$` alone; that
# self-quoting contract is gone -- see Set-NodeGpuCapacity, which now passes $patchFile unquoted).
function ConvertTo-Win32Arg {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Arg)
  if ($Arg -ne "" -and $Arg -notmatch '[\s"]') { return $Arg }
  $sb = [System.Text.StringBuilder]::new()
  [void]$sb.Append('"')
  $i = 0
  while ($i -lt $Arg.Length) {
    $nBackslash = 0
    while ($i -lt $Arg.Length -and $Arg[$i] -eq '\') { $i++; $nBackslash++ }
    if ($i -eq $Arg.Length) {
      [void]$sb.Append('\' * ($nBackslash * 2))   # trailing run: double so the close quote survives
      break
    } elseif ($Arg[$i] -eq '"') {
      [void]$sb.Append('\' * ($nBackslash * 2 + 1)); [void]$sb.Append('"')
      $i++
    } else {
      # [string] cast, not the bare [char] from string indexing: under Windows
      # PowerShell 5.1 (the installer's relaunch host) the StringBuilder.Append
      # binder can bind a [char] to a numeric overload and write the code point
      # instead of the character; Append([string]) is unambiguous (Bugbot #845).
      [void]$sb.Append('\' * $nBackslash); [void]$sb.Append([string]$Arg[$i])
      $i++
    }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

# #616: the AUTHORITATIVE GPU gate. Install-NvidiaContainerToolkit configures the user's own
# WSL distro, but k3d talks to Docker Desktop's OWN daemon (the `docker-desktop` distro), so
# toolkit-in-Ubuntu success is not a reliable signal that a GPU can reach a container. The only
# reliable test is to actually run one: `docker run --gpus all ... nvidia-smi`. With the custom
# k3s-CUDA node image providing the in-cluster runtime, this Docker-Desktop passthrough is the
# real prerequisite. Gating on it means we enable GPU only when the cluster will really get one,
# and never create a `--gpus` cluster that would fail. Best-effort + bounded; failure => CPU.
# #616/Bugbot: run a docker CLI command with a HARD timeout so a wedged daemon, registry, or proxy
# can't hang the installer forever (installer external-call timeout rule). Runs docker in a bounded
# background job; on timeout the job is killed and Code=124 is returned so callers fall back to CPU
# cleanly. Returns @{ Code = <int>; Output = <string> }. Any stdin (e.g. a login token) is passed
# in-memory via the arg hashtable — never written to disk, never placed in argv or logged.
# Run ANY external command as a real child PROCESS with a HARD timeout (installer external-call
# timeout rule). NOT a Start-Job: Stop-Job stops the PS job but can orphan the native child it
# spawned (Bugbot), so a timed-out call would keep running; a direct Process handle lets us Kill()
# the child on timeout. Args are quoted+escaped per ConvertTo-Win32Arg so a value carrying spaces
# and/or quotes survives the join into $psi.Arguments intact; any stdin (e.g. a login token) is
# written in-memory, never to disk/argv/logs. 5.1-safe. Returns
# @{ Code = <int>; Output = <string> } with Code=124 on timeout.
function Invoke-BoundedProcess {
  # -StdoutOnly: return ONLY stdout in .Output on the success path, instead of the
  # usual stdout+stderr concatenation.
  #
  # OPT-IN on purpose. The merged .Output is load-bearing for most callers -- e.g.
  # Get-GpuBuildFailureReason classifies a docker build by matching stderr text -- so
  # isolating it globally would break the diagnosis those callers exist to produce.
  # But a caller that COMPARES output to an expected value cannot tolerate the merge:
  # any client-side docker warning lands in the same string and the comparison fails.
  # Assert-NodesSeeHostData is exactly that, and there the failure is a FALSE REFUSAL
  # after the cluster is already up (@saadqbal / Bugbot on #817).
  #
  # Only the success path is isolated. The failure/timeout paths keep their merged or
  # synthetic text, which is pure diagnostics -- and every caller checks .Code before
  # reading .Output for a value.
  param(
    [Parameter(Mandatory)][string]$FileName,
    [Parameter(Mandatory)][string[]]$Arguments,
    [int]$TimeoutSec = 120,
    [string]$Stdin = "",
    [switch]$StdoutOnly
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  # Quote+escape each arg (Bugbot): the args are joined into a single command line, so a value with
  # a space -- a registry username, a temp path under a profile like "C:\Users\First Last\..." --
  # would be split into two, and a value with a `"` would corrupt the parse. ConvertTo-Win32Arg
  # applies the exact CommandLineToArgvW rules so both survive as one token; callers pass raw args.
  $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' ')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  if ($Stdin) { $psi.RedirectStandardInput = $true }
  try { $proc = [System.Diagnostics.Process]::Start($psi) }
  catch { return [pscustomobject]@{ Code = 1; Output = "could not start ${FileName}: $($_.Exception.Message)" } }
  # THE WRITE CAN LOSE A RACE WITH THE CHILD, and losing it must not throw. If the
  # process exits before or during the write -- `docker login` refusing instantly
  # because the daemon is down, a binary that rejects its args and returns, a stub in
  # the suite -- the pipe is already closed and .Write() raises "Broken pipe". That
  # escaped this function as a raw MethodInvocationException, which breaks the
  # contract three lines below it: every other arm RETURNS @{Code; Output}, and
  # Start() and Kill() are both guarded for exactly this reason. Only the stdin write
  # was bare.
  #
  # Swallowing is right here, and it is not a fail-open: a child that closed stdin has
  # already decided something, and its exit code and output are read below and
  # returned unchanged. The error we would raise is about OUR pipe, not about the
  # command -- reporting it would replace the child's real verdict with plumbing.
  #
  # Found on 2026-08-16: it took down `Pester (ubuntu-latest)` on client's `main` tip
  # right after a prod promotion, on a test whose assertion never ran.
  #
  # DRAIN BEFORE YOU WRITE. The readers start ahead of the stdin write, not after it.
  # With the order reversed, a child that BOTH reads stdin and writes output deadlocks
  # whenever the payload exceeds the OS pipe buffer (~64 KiB): the child fills its
  # stdout pipe, blocks because nobody is draining it yet, therefore stops reading
  # stdin, therefore our Write() blocks -- and WaitForExit() below is never reached, so
  # the HARD timeout this function exists to provide does not fire at all. Not 124:
  # no return, ever. Measured on backend#2246 -- `/bin/cat` with a 200 KB payload and
  # -TimeoutSec 20 ran past a 60s outer watchdog, while the same call with the readers
  # started first returns the child's real verdict. Starting a ReadToEndAsync() before
  # the write costs nothing and is the documented way out of the classic redirect
  # deadlock, so the ordering is load-bearing: do not "tidy" the readers back down.
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  if ($Stdin) {
    # Close() in `finally`, NOT chained after Write() in the same try. Chained, a throw
    # from Write() skipped the Close(), so the child never got its EOF and our write
    # handle stayed open -- and the ONE exception we actually observe here (broken pipe)
    # is swallowed, which means the skip was silent. The swallow itself stays: see the
    # paragraphs above for why a pipe error must not replace the child's verdict. The
    # inner try is because Close() flushes, so it can raise the same broken pipe.
    try { $proc.StandardInput.Write($Stdin) } catch { }
    finally { try { $proc.StandardInput.Close() } catch { } }
  }
  if ($proc.WaitForExit($TimeoutSec * 1000)) {
    # -StdoutOnly isolates stdout ONLY when the child SUCCEEDED (exit 0), per the
    # contract documented above. On a NON-ZERO exit the merged stdout+stderr is
    # returned regardless of -StdoutOnly, so a failing caller keeps the child's
    # stderr diagnostics -- gating on $StdoutOnly alone silently discarded them,
    # and the child then looked like it produced nothing rather than like we threw
    # its stderr away (client#828). The timeout arm below is the other failure path
    # and keeps its synthetic text for the same reason.
    $isolate = $StdoutOnly -and $proc.ExitCode -eq 0
    return [pscustomobject]@{ Code = $proc.ExitCode; Output = $(if ($isolate) { $outTask.Result } else { $outTask.Result + $errTask.Result }) }
  }
  # timed out -> kill the child so it can't keep running after we've moved on
  try { $proc.Kill() } catch {}
  return [pscustomobject]@{ Code = 124; Output = ($FileName + " " + $Arguments[0] + " timed out after " + $TimeoutSec + "s") }
}

# Thin docker wrapper over Invoke-BoundedProcess (keeps every docker call bounded + killable).
function Invoke-DockerCli {
  param(
    [Parameter(Mandatory)][string[]]$DockerArgs,
    [int]$TimeoutSec = 120,
    [string]$Stdin = "",
    [switch]$StdoutOnly
  )
  return Invoke-BoundedProcess -FileName "docker" -Arguments $DockerArgs -TimeoutSec $TimeoutSec -Stdin $Stdin -StdoutOnly:$StdoutOnly
}

function Confirm-DockerGpu {
  if ($GPU_VENDOR -ne "nvidia" -or -not $NVIDIA_DRIVER_OK) { return $false }
  $probeImg = $CUDA_PROBE_IMAGE   # mirror-homed when TRACEBLOC_IMAGE_REGISTRY is set (#585)
  # -e NVIDIA_DISABLE_REQUIRE=1: the CUDA base image bakes in NVIDIA_REQUIRE_CUDA (e.g. cuda>=12.4),
  # and the container runtime REFUSES to start the container when the driver is older than that
  # ("unsatisfied condition: cuda>=12.4") -- so a perfectly good GPU on a slightly older driver
  # (e.g. 532.x = CUDA 12.1) reads as "can't expose the GPU" and drops to CPU. We only want to know
  # whether Docker can pass the GPU through (nvidia-smi is driver-level, version-agnostic); the real
  # CUDA-vs-driver compatibility for TRAINING is enforced per-pod by the training image. So disable
  # the requirement gate for the probe -- and the node image does the same (#616).
  Log "Probing Docker GPU passthrough: docker run --rm --gpus all -e NVIDIA_DISABLE_REQUIRE=1 $probeImg nvidia-smi (bounded)"
  $r = Invoke-DockerCli -DockerArgs @("run", "--rm", "--gpus", "all", "-e", "NVIDIA_DISABLE_REQUIRE=1", $probeImg, "nvidia-smi") -TimeoutSec 180
  if ($r.Code -eq 0 -and $r.Output -match 'NVIDIA-SMI|CUDA Version|Driver Version') {
    Log "Docker GPU passthrough OK"
    return $true
  }
  Log "Docker GPU probe failed (exit $($r.Code)): $($r.Output)"
  # Set the reason from what ACTUALLY failed (Bugbot): a timeout is not a GPU-unavailable error.
  if ($r.Code -eq 124) {
    $script:GPU_SKIP_REASON = "the Docker GPU probe (docker run --gpus all) timed out -- Docker Desktop may be busy, or the CUDA base image pull is blocked"
  } else {
    # Name the DETECTED driver and a concrete minimum: our install gate accepts 460+, but CUDA
    # on WSL2 realistically needs a much newer driver, so "update the driver" alone left people
    # guessing whether theirs qualified (#616).
    $drv = if ($script:NVIDIA_DRIVER_VERSION) { " (this machine reports driver $($script:NVIDIA_DRIVER_VERSION))" } else { "" }
    $script:GPU_SKIP_REASON = "Docker Desktop can't expose the GPU to a container$drv -- enable GPU support in Docker Desktop, and update the NVIDIA Windows driver to 525 or newer (WSL2 CUDA needs a recent driver)"
  }
  return $false
}

# #616: the custom GPU node image is kept PRIVATE (not published public), so the installer must
# authenticate to pull it — the end user still runs ONE command; the creds come from env, not a
# separate `docker login`. Log Docker in to the image's registry with the provided registry creds
# (TRACEBLOC_REGISTRY_USERNAME/PASSWORD — the same vars the mirror uses, #585) and verify the image
# is actually pullable BEFORE committing to a --gpus cluster. On failure we fall back to CPU
# cleanly instead of a cluster-create that dies pulling an unauthorized image. The pull here also
# pre-loads the image, so k3d cluster-create reuses the local copy (no second pull). Every docker
# call is bounded via Invoke-DockerCli, so a wedged daemon/registry/proxy can't hang the install.
# Pure: which host does `docker login` target for an image ref? Docker treats the first path
# segment as a REGISTRY only when it has a '.'/':' or is 'localhost'; otherwise the ref is a
# Docker Hub repo (owner/name) and login must target Docker Hub, NOT the owner segment -- else
# creds for a private Docker Hub image go to the wrong endpoint and the pull fails (Bugbot).
function Get-RegistryHost {
  param([string]$ImageRef)
  $first = ($ImageRef -split '/')[0]
  if ($first -match '[.:]' -or $first -eq 'localhost') { return $first }
  return 'docker.io'
}

# docker login to the GPU image's registry with the supplied creds. Called BEFORE both the GPU
# probe (which may pull a mirror-hosted CUDA image) and the node-image pull, so an authenticated
# mirror/private registry is never hit unauthenticated first -- which would short-circuit a
# credentialed install to CPU (Bugbot). No-op without creds; idempotent (safe to call twice).
function Connect-GpuRegistry {
  $regUser = $env:TRACEBLOC_REGISTRY_USERNAME
  $regPass = $env:TRACEBLOC_REGISTRY_PASSWORD
  if (-not ($regUser -and $regPass)) { return }
  # Log into EVERY distinct registry an auth-requiring GPU image is pulled from: the node image
  # ($K3S_CUDA_IMAGE) AND the probe image ($CUDA_PROBE_IMAGE). With TRACEBLOC_K3S_CUDA_IMAGE and
  # TRACEBLOC_IMAGE_REGISTRY set to DIFFERENT hosts these differ, and logging into only one leaves
  # the other's pull unauthenticated -> the probe is rejected and GPU is needlessly disabled (Bugbot).
  $hosts = @((Get-RegistryHost $K3S_CUDA_IMAGE), (Get-RegistryHost $CUDA_PROBE_IMAGE)) | Select-Object -Unique
  foreach ($regHost in $hosts) {
    Log "Authenticating Docker to $regHost for the GPU image(s)"
    $lr = Invoke-DockerCli -DockerArgs @("login", $regHost, "-u", $regUser, "--password-stdin") -TimeoutSec 60 -Stdin $regPass
    if ($lr.Code -ne 0) { Log "docker login to $regHost did not succeed (exit $($lr.Code))" }
  }
}

function Confirm-GpuImagePullable {
  $regUser = $env:TRACEBLOC_REGISTRY_USERNAME
  $regPass = $env:TRACEBLOC_REGISTRY_PASSWORD
  Connect-GpuRegistry   # logs into the correct host (Get-RegistryHost); no-op without creds
  Log "Pulling the GPU node image (verifies access + pre-loads for cluster-create): $K3S_CUDA_IMAGE"
  $pr = Invoke-DockerCli -DockerArgs @("pull", $K3S_CUDA_IMAGE) -TimeoutSec 900
  if ($pr.Code -eq 0) {
    # Sanity-check the PULLED image runs k3s, exactly as the local build path does -- a mis-tagged
    # or broken mirror/custom image would otherwise enable GPU and then abort k3d cluster-create
    # instead of taking the CPU fallback (Bugbot).
    if (Test-GpuImageRunsK3s) { Log "GPU node image pulled + verified OK"; return $true }
    $script:GPU_SKIP_REASON = "the pulled GPU node image ($K3S_CUDA_IMAGE) doesn't run k3s (mis-tagged or broken image) -- running CPU-only"
    Log "Pulled GPU node image failed its k3s sanity check"
    return $false
  }
  Log "GPU node image pull failed (exit $($pr.Code)): $($pr.Output)"
  # Reason reflects the ACTUAL failure (Bugbot): a pull timeout is not an auth error.
  if ($pr.Code -eq 124) {
    $script:GPU_SKIP_REASON = "pulling the GPU node image ($K3S_CUDA_IMAGE) timed out -- slow or blocked network/registry"
  } elseif ($regUser -and $regPass) {
    $script:GPU_SKIP_REASON = "the GPU node image ($K3S_CUDA_IMAGE) couldn't be pulled even with the provided registry credentials -- check they have read access"
  } else {
    $script:GPU_SKIP_REASON = "the GPU node image ($K3S_CUDA_IMAGE) is on a private registry -- set TRACEBLOC_REGISTRY_USERNAME and TRACEBLOC_REGISTRY_PASSWORD (a read:packages token) to enable GPU"
  }
  return $false
}

# Build inputs for the LOCAL GPU node-image build (#616), base64-encoded copies of
# docker/k3s-cuda/* (the CI build source of truth). Base64 (not raw here-strings) so the
# installer stays self-contained AND ASCII-only with no bare-curl token; a Pester drift
# test decodes each and fails if it diverges from docker/k3s-cuda/*. Decode to read.
$script:K3S_CUDA_DOCKERFILE_B64 = 'IyBzeW50YXg9ZG9ja2VyL2RvY2tlcmZpbGU6MS43LWxhYnMKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQojICBDdXN0b20gazNzIG5vZGUgaW1hZ2Ugd2l0aCBOVklESUEgR1BVIHN1cHBvcnQgICh0cmFjZWJsb2MvY2xpZW50ICM2MTYpCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KIyBXSFkgdGhpcyBleGlzdHM6IHRoZSBzdG9jayBgcmFuY2hlci9rM3NgIGltYWdlIGlzIEFscGluZS1iYXNlZCBhbmQgc2hpcHMgTk8KIyBOVklESUEgY29udGFpbmVyIHJ1bnRpbWUsIHNvIEdQVSBwb2RzIGNhbiBuZXZlciBzY2hlZHVsZSBvbiBpdCDigJQgdGhlIG5vZGUKIyBhZHZlcnRpc2VzIDAgbnZpZGlhLmNvbS9ncHUuIFRoaXMgaW1hZ2UgcmVidWlsZHMgdGhlIFNBTUUgcGlubmVkIGszcyBvbiBhbgojIE5WSURJQSBDVURBIFVidW50dSBiYXNlLCBpbnN0YWxscyB0aGUgTlZJRElBIENvbnRhaW5lciBUb29sa2l0LCBjb25maWd1cmVzCiMgY29udGFpbmVyZCBmb3IgdGhlIGBudmlkaWFgIHJ1bnRpbWUgKGluIENESSBtb2RlKSwgYW5kIGJha2VzIGluIHRoZSBgbnZpZGlhYAojIFJ1bnRpbWVDbGFzcyBwbHVzIGEgazNkIGVudHJ5cG9pbnQgZHJvcC1pbiB0aGF0IGdlbmVyYXRlcyB0aGUgV1NMIENESSBzcGVjIG9uCiMgZXZlcnkgbm9kZSBzdGFydC4gR1BVIGNhcGFjaXR5IGlzIGFkdmVydGlzZWQgYnkgdGhlIGluc3RhbGxlciArIHRoYXQgZHJvcC1pbiAtLQojIE5PVCBieSB0aGUgTlZNTCBkZXZpY2UgcGx1Z2luLCB3aGljaCBjYW5ub3Qgd29yayBvbiBXU0wyIChzZWUgUkVBRE1FKS4KIyBCYXNlZCBvbiB0aGUgb2ZmaWNpYWwgazNkIENVREEgcmVjaXBlIChodHRwczovL2szZC5pby8uLi4vdXNhZ2UvYWR2YW5jZWQvY3VkYS8pLgojCiMgSU1QT1JUQU5UOiBLM1NfVEFHIE1VU1QgbWF0Y2ggdGhlIGluc3RhbGxlcidzIEs4U19WRVJTSU9OIHBpbgojIChzY3JpcHRzL3NwZWMvZmFjdHMuZW52IC8gc2NyaXB0cy9saWIvY29tbW9uLnNoKSBzbyBhIEdQVSBub2RlIHJ1bnMgdGhlIGV4YWN0CiMgc2FtZSB2YWxpZGF0ZWQgazNzIGFzIGEgbm9ybWFsIENQVSBub2RlLiBzY3JpcHRzL2NoZWNrLWZhY3RzLnNoIGVuZm9yY2VzIHRoaXM6CiMgdGhpcyBBUkcsIGJ1aWxkLnNoLCBhbmQgdGhlIHdvcmtmbG93IGlucHV0IGRlZmF1bHQgYXJlIGFsbCBjaGVja2VkIGFnYWluc3QKIyBmYWN0cy5lbnYncyBLOFNfVkVSU0lPTiwgc28gYSBidW1wIGNhbid0IGxlYXZlIHRoZSBHUFUgaW1hZ2UgdGFnIHN0YWxlICgjNTQ3KS4KQVJHIEszU19UQUc9InYxLjM2LjMtazNzMSIKQVJHIENVREFfVEFHPSIxMi40LjEtYmFzZS11YnVudHUyMi4wNCIKIyBOVklESUEgQ29udGFpbmVyIFRvb2xraXQgdmVyc2lvbi4gUElOTkVEIHRvIHRoZSBidWlsZCB2YWxpZGF0ZWQgb24gcmVhbCBoYXJkd2FyZSAoYW4gUlRYIDQwNTAKIyBsYXB0b3AsIGRyaXZlciA1MzIuMTApIGJlY2F1c2UgdGhlIHdob2xlIFdTTDIgR1BVIHBhdGggZGVwZW5kcyBvbiB2ZXJzaW9uLXNlbnNpdGl2ZSBzdXJmYWNlczoKIyBgY2RpIGdlbmVyYXRlIC0tbW9kZT13c2xgLCBgY29uZmlnIC0tc2V0IG52aWRpYS1jb250YWluZXItcnVudGltZS5tb2RlPWNkaWAsIGFuZCB0aGUgZXhhY3QgWUFNTAojIHRoZSBnZW5lcmF0b3IgZW1pdHMgKG91ciBsaWJkeGNvcmUgaW5qZWN0aW9uIHBhcnNlcyBpdCkuIFVucGlubmVkLCB0d28gbWFjaGluZXMgYnVpbHQgd2Vla3MKIyBhcGFydCBjb3VsZCBnZXQgZGlmZmVyZW50IHRvb2xraXQgYnVpbGRzIGFuZCBiZWhhdmUgZGlmZmVyZW50bHkgLS0gYW5kIGEgZnV0dXJlIHJlbGVhc2UgY2hhbmdpbmcKIyB0aGUgc3BlYyBzaGFwZSB3b3VsZCBicmVhayBHUFUgb24gbmV3IGluc3RhbGxzIHdoaWxlIGV4aXN0aW5nIG9uZXMga2VwdCB3b3JraW5nLgojIFRoZSBpbnN0YWxsIGJlbG93IEZBTExTIEJBQ0sgdG8gdGhlIGxhdGVzdCBpZiB0aGlzIHZlcnNpb24gaGFzIGFnZWQgb3V0IG9mIHRoZSBhcHQgcmVwbywgc28gYQojIHN0YWxlIHBpbiBkZWdyYWRlcyB0byAidW5waW5uZWQiIHJhdGhlciB0aGFuIGZhaWxpbmcgdGhlIGJ1aWxkICh3aGljaCB3b3VsZCBjb3N0IEdQVSBlbnRpcmVseSkuCkFSRyBOQ1RfVkVSU0lPTj0iMS4xOS4xLTEiCgpGUk9NIHJhbmNoZXIvazNzOiR7SzNTX1RBR30gQVMgazNzCgpGUk9NIG52Y3IuaW8vbnZpZGlhL2N1ZGE6JHtDVURBX1RBR30KCiMgVGhlIENVREEgYmFzZSBiYWtlcyBpbiBOVklESUFfUkVRVUlSRV9DVURBIChlLmcuIGN1ZGE+PTEyLjQpOyB3aXRoIC0tZ3B1cyB0aGUgY29udGFpbmVyIHJ1bnRpbWUKIyB0aGVuIFJFRlVTRVMgdG8gc3RhcnQgdGhpcyBub2RlIG9uIGFueSBkcml2ZXIgb2xkZXIgdGhhbiB0aGF0IGJhc2UgKCJ1bnNhdGlzZmllZCBjb25kaXRpb246CiMgY3VkYT49MTIuNCIpLCBzbyBhIHZhbGlkIEdQVSBvbiBhIHNsaWdodGx5IG9sZGVyIGRyaXZlciAoZS5nLiA1MzIueCA9IENVREEgMTIuMSkgY2FuJ3QgcnVuIHRoZQojIGNsdXN0ZXIgYXQgYWxsLiBUaGlzIG5vZGUgcnVucyBrM3MsIG5vdCBDVURBIHdvcmtsb2FkcyAtLSB0aGUgcmVhbCBDVURBL2RyaXZlciBjb21wYXRpYmlsaXR5IGlzCiMgZW5mb3JjZWQgcGVyLXBvZCBieSBlYWNoIFRSQUlOSU5HIGltYWdlIC0tIHNvIGRpc2FibGUgdGhlIHJlcXVpcmVtZW50IGdhdGUgaGVyZSAoIzYxNikuCkVOViBOVklESUFfRElTQUJMRV9SRVFVSVJFPTEKCiMgTlZJRElBIENvbnRhaW5lciBUb29sa2l0LCB0aGVuIHBvaW50IGNvbnRhaW5lcmQgYXQgdGhlIGBudmlkaWFgIHJ1bnRpbWUuIFRoZQojIGdwZyBrZXkgKyBhcHQgbGlzdCBhcmUgcGlubmVkIHZpYSB0aGUga2V5cmluZyB0aGUgc2FtZSB3YXkgdGhlIGluLVdTTCB0b29sa2l0CiMgaW5zdGFsbCBkb2VzIChzY3JpcHRzL2luc3RhbGwtazhzLnBzMSkgc28gYSByZXN0cmljdGVkLW5ldHdvcmsgbWlycm9yIGNhbgojIHJlLWhvbWUgdGhlbSBjb25zaXN0ZW50bHkuIGN1cmwgY2FycmllcyB0aGUgVExTIGZsb29yICsgYm91bmRlZCB0aW1lb3V0cyBpbmxpbmUKIyAoYSBEb2NrZXJmaWxlIGNhbid0IHNvdXJjZSBjb21tb24uc2gncyBjdXJsX3NlY3VyZSgpKSBzbyBhIHN0YWxsZWQgb3IgZG93bmdyYWRlZAojIGNvbm5lY3Rpb24gdG8gbnZpZGlhLmdpdGh1Yi5pbyBmYWlscyBmYXN0IGluc3RlYWQgb2YgaGFuZ2luZyB0aGUgYnVpbGQgKGhvdXNlIHJ1bGUpLgpSVU4gZXhwb3J0IERFQklBTl9GUk9OVEVORD1ub25pbnRlcmFjdGl2ZSBcCiAgICAmJiBhcHQtZ2V0IHVwZGF0ZSBcCiAgICAmJiBhcHQtZ2V0IGluc3RhbGwgLXkgLS1uby1pbnN0YWxsLXJlY29tbWVuZHMgY3VybCBjYS1jZXJ0aWZpY2F0ZXMgZ251cGcgXAogICAgJiYgY3VybCAtZnNTTCAtLXRsc3YxLjIgLS1jb25uZWN0LXRpbWVvdXQgMzAgLS1tYXgtdGltZSA2MCBodHRwczovL252aWRpYS5naXRodWIuaW8vbGlibnZpZGlhLWNvbnRhaW5lci9ncGdrZXkgXAogICAgICAgICB8IGdwZyAtLWRlYXJtb3IgLW8gL3Vzci9zaGFyZS9rZXlyaW5ncy9udmlkaWEtY29udGFpbmVyLXRvb2xraXQta2V5cmluZy5ncGcgXAogICAgJiYgY3VybCAtZnNTTCAtLXRsc3YxLjIgLS1jb25uZWN0LXRpbWVvdXQgMzAgLS1tYXgtdGltZSA2MCBodHRwczovL252aWRpYS5naXRodWIuaW8vbGlibnZpZGlhLWNvbnRhaW5lci9zdGFibGUvZGViL252aWRpYS1jb250YWluZXItdG9vbGtpdC5saXN0IFwKICAgICAgICAgfCBzZWQgJ3MjZGViIGh0dHBzOi8vI2RlYiBbc2lnbmVkLWJ5PS91c3Ivc2hhcmUva2V5cmluZ3MvbnZpZGlhLWNvbnRhaW5lci10b29sa2l0LWtleXJpbmcuZ3BnXSBodHRwczovLyNnJyBcCiAgICAgICAgIHwgdGVlIC9ldGMvYXB0L3NvdXJjZXMubGlzdC5kL252aWRpYS1jb250YWluZXItdG9vbGtpdC5saXN0IFwKICAgICYmIGFwdC1nZXQgdXBkYXRlIFwKICAgICYmICggYXB0LWdldCBpbnN0YWxsIC15IC0tbm8taW5zdGFsbC1yZWNvbW1lbmRzICJudmlkaWEtY29udGFpbmVyLXRvb2xraXQ9JHtOQ1RfVkVSU0lPTn0iIFwKICAgICAgICAgfHwgeyBlY2hvICJOQ1QgJHtOQ1RfVkVSU0lPTn0gdW5hdmFpbGFibGUgaW4gdGhlIHJlcG8gLS0gZmFsbGluZyBiYWNrIHRvIGxhdGVzdCI7IFwKICAgICAgICAgICAgICBhcHQtZ2V0IGluc3RhbGwgLXkgLS1uby1pbnN0YWxsLXJlY29tbWVuZHMgbnZpZGlhLWNvbnRhaW5lci10b29sa2l0OyB9ICkgXAogICAgJiYgbnZpZGlhLWN0ayAtLXZlcnNpb24gXAogICAgJiYgbnZpZGlhLWN0ayBydW50aW1lIGNvbmZpZ3VyZSAtLXJ1bnRpbWU9Y29udGFpbmVyZCBcCiAgICAmJiBudmlkaWEtY3RrIGNvbmZpZyAtLWluLXBsYWNlIC0tc2V0IG52aWRpYS1jb250YWluZXItcnVudGltZS5tb2RlPWNkaSBcCiAgICAmJiBhcHQtZ2V0IGNsZWFuIFwKICAgICYmIHJtIC1yZiAvdmFyL2xpYi9hcHQvbGlzdHMvKgoKIyBDb3B5IHRoZSBwaW5uZWQgazNzIHJvb3RmcyBvdmVyIHRoZSBDVURBIGJhc2UsIHRoZW4gYnJpbmcgaW4gazNzJ3Mgb3duIC9iaW4gZXhwbGljaXRseS4KIyAtLWV4Y2x1ZGUgTVVTVCBjb21lIEJFRk9SRSB0aGUgc3JjL2Rlc3Q6IGEgVFJBSUxJTkcgYC0tZXhjbHVkZWAgaXMgcGFyc2VkIGFzIHRoZQojIGRlc3RpbmF0aW9uLCBzbyB0aGUgcm9vdGZzIHNpbGVudGx5IGNvcGllcyB0byAvLS1leGNsdWRlPS4uLiBpbnN0ZWFkIG9mIC8g4oCUIHRoZSBidWlsZAojICJwYXNzZXMiIGJ1dCB0aGUgaW1hZ2UgaXMgYnJva2VuIChCdWdib3QpLiBQYXRocyBhcmUgUkVMQVRJVkUgdG8gdGhlIHNvdXJjZSAoYGJpbmAsIG5vdAojIGAvYmluYCkuIFVidW50dSAyMi4wNCBpcyBtZXJnZWQtL3Vzciwgc28gL2JpbiAvc2JpbiAvbGliIC9saWI2NCBhcmUgU1lNTElOS1MgdG8gL3Vzci8qLAojIHdoaWxlIHRoZSBBbHBpbmUgazNzIGltYWdlIHNoaXBzIHRoZW0gYXMgcmVhbCBkaXJzIOKAlCBjb3B5aW5nIHRob3NlIG92ZXIgdGhlIHN5bWxpbmtzIGVycm9ycwojICJjYW5ub3QgY29weSB0byBub24tZGlyZWN0b3J5Ii4gazNzIGlzIGEgU1RBVElDIGJpbmFyeSAobmVlZHMgbm8gc2hhcmVkIGxpYnMpLCBzbyB3ZSBleGNsdWRlCiMgYWxsIGZvdXIgKGtlZXBpbmcgVWJ1bnR1J3MgZ2xpYmMgdXNlcmxhbmQ6IGN1cmwvYXB0L252aWRpYS1jdGspIGFuZCBvdmVybGF5IG9ubHkgazNzJ3Mgb3duCiMgL2JpbiAodGhlIHN0YXRpYyBrM3MgKyAvYmluL2F1eCkgaW50byAvdXNyL2JpbiB2aWEgdGhlIGtlcHQgL2JpbiBzeW1saW5rLiBidWlsZC5zaCB2ZXJpZmllcwojIHRoZSBvdmVybGF5IGxhbmRlZCBjb3JyZWN0bHkgYWZ0ZXIgdGhlIGJ1aWxkLCBzbyBhIG1pcy1wYXJzZSBjYW4gbmV2ZXIgcHVibGlzaCBhIGJyb2tlbiBpbWFnZS4KQ09QWSAtLWZyb209azNzIFwKICAgICAtLWV4Y2x1ZGU9YmluIC0tZXhjbHVkZT1zYmluIC0tZXhjbHVkZT1saWIgLS1leGNsdWRlPWxpYjMyIC0tZXhjbHVkZT1saWI2NCAtLWV4Y2x1ZGU9bGlieDMyIFwKICAgICAtLWV4Y2x1ZGU9dmFyL3J1biAtLWV4Y2x1ZGU9dmFyL2xvY2sgXAogICAgIC8gLwpDT1BZIC0tZnJvbT1rM3MgL2JpbiAvYmluCgojIEF1dG8tZGVwbG95IE9OTFkgdGhlIGBudmlkaWFgIFJ1bnRpbWVDbGFzcyBvbiBmaXJzdCBzZXJ2ZXIgYm9vdCAoazNzIGF1dG8tYXBwbGllcwojIG1hbmlmZXN0cyBkcm9wcGVkIGhlcmUpLiBXZSBkZWxpYmVyYXRlbHkgZG8gTk9UIHNoaXAgdGhlIE5WTUwgZGV2aWNlLXBsdWdpbiBEYWVtb25TZXQ6CiMgb24gRG9ja2VyIERlc2t0b3AvV1NMMiBpdCBjYW4ndCBpbml0IE5WTUwsIHdvdWxkIHJlZ2lzdGVyIDAgR1BVcywgYW5kIChvd25pbmcgdGhlCiMgbnZpZGlhLmNvbS9ncHUgZXh0ZW5kZWQgcmVzb3VyY2UpIHdvdWxkIG92ZXJ3cml0ZSB0aGUgaW5zdGFsbGVyJ3Mgbm9kZS1yZXNvdXJjZSBwYXRjaAojIHdpdGggMCAtLSBzdHJhbmRpbmcgam9icy4gR1BVIGNhcGFjaXR5IGlzIGFkdmVydGlzZWQgYnkgdGhlIGluc3RhbGxlciB2aWEgYSBub2RlIHBhdGNoLAojIGFuZCBwb2RzIGdldCB0aGUgcmVhbCBHUFUgdGhyb3VnaCB0aGUgQ0RJIHNwZWMgZ2VuZXJhdGVkIGF0IGJvb3QgKHNlZSBrM2QtZW50cnlwb2ludC10cmFjZWJsb2MtY2RpLnNoKS4KQ09QWSBudmlkaWEtcnVudGltZWNsYXNzLnlhbWwgL3Zhci9saWIvcmFuY2hlci9rM3Mvc2VydmVyL21hbmlmZXN0cy9udmlkaWEtcnVudGltZWNsYXNzLnlhbWwKCiMgTm9kZSBHUFUgc2V0dXA6IGdlbmVyYXRlIHRoZSBXU0wgQ0RJIHNwZWMgKCsgbGliZHhjb3JlKSBhbmQga2VlcCBudmlkaWEuY29tL2dwdQojIGFkdmVydGlzZWQsIHNvIHBvZHMgY2FuIHVzZSB0aGUgR1BVIG9uIERvY2tlciBEZXNrdG9wL1dTTDIuIE5vLW9wIG9uIG5vbi1XU0wyIG5vZGVzLgojCiMgSXQgTVVTVCBiZSBpbnN0YWxsZWQgYXMgYSAvYmluL2szZC1lbnRyeXBvaW50LSouc2ggRFJPUC1JTiwgbm90IGFzIHRoZSBpbWFnZSBFTlRSWVBPSU5UOgojIGszZCByZXBsYWNlcyB0aGUgaW1hZ2UgZW50cnlwb2ludCB3aXRoIGl0cyBvd24gL2Jpbi9rM2QtZW50cnlwb2ludC5zaCwgd2hpY2ggcnVucyB0aGVzZQojIGRyb3AtaW5zIGFuZCB0aGVuIGV4ZWNzIGszcy4gQW4gRU5UUllQT0lOVCB3cmFwcGVyIGhlcmUgaXMgc2lsZW50bHkgbmV2ZXIgcnVuICgjNjE2KS4KQ09QWSBrM2QtZW50cnlwb2ludC10cmFjZWJsb2MtY2RpLnNoIC9iaW4vazNkLWVudHJ5cG9pbnQtdHJhY2VibG9jLWNkaS5zaApSVU4gY2htb2QgK3ggL2Jpbi9rM2QtZW50cnlwb2ludC10cmFjZWJsb2MtY2RpLnNoCgpWT0xVTUUgL3Zhci9saWIva3ViZWxldApWT0xVTUUgL3Zhci9saWIvcmFuY2hlci9rM3MKVk9MVU1FIC92YXIvbGliL2NuaQpWT0xVTUUgL3Zhci9sb2cKCkVOViBQQVRIPSIkUEFUSDovYmluL2F1eCIKCiMgU3RvY2sgazNzIGVudHJ5cG9pbnQgKHNhbWUgYXMgcmFuY2hlci9rM3MpLiBrM2Qgb3ZlcnJpZGVzIGl0IHdpdGggaXRzIG93bgojIC9iaW4vazNkLWVudHJ5cG9pbnQuc2gsIHdoaWNoIHJ1bnMgb3VyIGRyb3AtaW4gYWJvdmUgYmVmb3JlIGV4ZWMnaW5nIGszczsga2VlcGluZyB0aGUKIyBzdG9jayB2YWx1ZSBtZWFucyB0aGUgaW1hZ2UgYWxzbyBiZWhhdmVzIG5vcm1hbGx5IG91dHNpZGUgazNkLgpFTlRSWVBPSU5UIFsiL2Jpbi9rM3MiXQpDTUQgWyJhZ2VudCJdCg=='

$script:K3S_CUDA_RUNTIMECLASS_B64 = 'IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQojICBgbnZpZGlhYCBSdW50aW1lQ2xhc3MgICh0cmFjZWJsb2MvY2xpZW50ICM2MTYpCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KIyBCYWtlZCBpbnRvIHRoZSBjdXN0b20gazNzLUNVREEgaW1hZ2UgYXQgL3Zhci9saWIvcmFuY2hlci9rM3Mvc2VydmVyL21hbmlmZXN0cy8KIyBzbyBrM3MgYXV0by1hcHBsaWVzIGl0IG9uIGZpcnN0IHNlcnZlciBib290LiBUcmFpbmluZyBwb2RzIHJlZmVyZW5jZSBpdCB2aWEKIyBydW50aW1lQ2xhc3NOYW1lOiBudmlkaWEgKHRoZSBpbnN0YWxsZXIgc2V0cyBSVU5USU1FX0NMQVNTX05BTUU9bnZpZGlhIHdoZW4gR1BVCiMgaXMgZW5hYmxlZCwgd2hpY2ggam9icy1tYW5hZ2VyIHRocmVhZHMgaW50byBldmVyeSBzcGF3bmVkIHBvZCksIHNvIHRoZSBub2RlJ3MKIyBjb250YWluZXJkIGludm9rZXMgdGhlIG52aWRpYSBjb250YWluZXIgcnVudGltZSAtLSB3aGljaCwgaW4gQ0RJIG1vZGUgKHNlZQojIGszZC1lbnRyeXBvaW50LXRyYWNlYmxvYy1jZGkuc2gpLCBpbmplY3RzIHRoZSBHUFUgaW50byB0aGUgcG9kIGZyb20gdGhlIFdTTCBDREkgc3BlYy4KIwojIE5PVEU6IHdlIGludGVudGlvbmFsbHkgZG8gTk9UIHNoaXAgdGhlIE5WTUwgZGV2aWNlLXBsdWdpbiBEYWVtb25TZXQgaGVyZS4gT24KIyBEb2NrZXIgRGVza3RvcC9XU0wyIGl0IGNhbid0IGluaXRpYWxpc2UgTlZNTCAoRVJST1JfTk9UX1NVUFBPUlRFRCksIHdvdWxkCiMgcmVnaXN0ZXIgMCBHUFVzLCBhbmQgLS0gb3duaW5nIHRoZSBudmlkaWEuY29tL2dwdSBleHRlbmRlZCByZXNvdXJjZSAtLSB3b3VsZAojIG92ZXJ3cml0ZSB0aGUgaW5zdGFsbGVyJ3Mgbm9kZS1yZXNvdXJjZSBwYXRjaCB3aXRoIDAsIHN0cmFuZGluZyBqb2JzLiBHUFUKIyBjYXBhY2l0eSBpcyBhZHZlcnRpc2VkIGJ5IHRoZSBpbnN0YWxsZXIgdmlhIGEgbm9kZS1zdGF0dXMgcGF0Y2ggaW5zdGVhZC4KLS0tCmFwaVZlcnNpb246IG5vZGUuazhzLmlvL3YxCmtpbmQ6IFJ1bnRpbWVDbGFzcwptZXRhZGF0YToKICBuYW1lOiBudmlkaWEKaGFuZGxlcjogbnZpZGlhCg=='

$script:K3S_CUDA_BOOT_B64 = 'IyEvYmluL3NoCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KIyAgdHJhY2VibG9jIEdQVS1vbi1XU0wyIG5vZGUgc2V0dXAg4oCUIGszZCBlbnRyeXBvaW50IERST1AtSU4gKCM2MTYpCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KIyBXSFkgVEhFIEZJTEVOQU1FIE1BVFRFUlM6IGszZCBkb2VzIE5PVCB1c2UgdGhlIGltYWdlJ3MgRU5UUllQT0lOVC4gSXQgcmVwbGFjZXMgaXQKIyB3aXRoIGl0cyBvd24gL2Jpbi9rM2QtZW50cnlwb2ludC5zaCwgd2hpY2ggcnVucyBldmVyeSAvYmluL2szZC1lbnRyeXBvaW50LSouc2gKIyBkcm9wLWluIGFuZCB0aGVuIGV4ZWNzIGszcy4gQW4gaW1hZ2UgRU5UUllQT0lOVCB3cmFwcGVyIGlzIHRoZXJlZm9yZSBzaWxlbnRseQojIG5ldmVyIGV4ZWN1dGVkICh0aGF0J3MgZXhhY3RseSBob3cgdGhpcyBzaGlwcGVkIGJyb2tlbiB0aGUgZmlyc3QgdGltZTogdGhlIENESSBzcGVjCiMgd2FzIG5ldmVyIGdlbmVyYXRlZCwgYW5kIHRoZSBpbnN0YWxsZXIgY29ycmVjdGx5IGZlbGwgYmFjayB0byBDUFUpLiBTbyB0aGlzIHNoaXBzIGFzCiMgL2Jpbi9rM2QtZW50cnlwb2ludC10cmFjZWJsb2MtY2RpLnNoIGFuZCBtdXN0OgojICAgKiBSRVRVUk4gKG5ldmVyIGV4ZWMgazNzIOKAlCBrM2QncyBlbnRyeXBvaW50IGRvZXMgdGhhdCBhZnRlcndhcmRzKSwgYW5kCiMgICAqIGFsd2F5cyBgZXhpdCAwYCDigJQgazNkIHJ1bnMgZHJvcC1pbnMgd2l0aCBgfHwgZXhpdCAxYCwgc28gYSBub24temVybyBleGl0IGhlcmUKIyAgICAgd291bGQgYWJvcnQgdGhlIHdob2xlIG5vZGUuIEdQVSBpcyBvcHRpb25hbDsgaXQgbXVzdCBuZXZlciBicmVhayB0aGUgY2x1c3Rlci4KIwojIE9uIERvY2tlciBEZXNrdG9wIC8gV1NMMiB0aGUgTlZJRElBIGs4cyBkZXZpY2UgcGx1Z2luIGNhbid0IHdvcmsgKE5WTUwgcmV0dXJucwojIEVSUk9SX05PVF9TVVBQT1JURUQgdGhyb3VnaCB0aGUgcGFyYXZpcnR1YWxpemVkIEdQVSksIHNvIHdlIHdpcmUgdGhlIEdQVSBpbnRvCiMgcG9kcyB2aWEgQ0RJIGluc3RlYWQuIFRoaXMgTVVTVCBydW4gYXQgbm9kZSBzdGFydDogdGhlIFdTTCBkcml2ZXItc3RvcmUgcGF0aCBpcyBhCiMgZHluYW1pYyBwZXItbWFjaGluZSBoYXNoLCBzbyB0aGUgQ0RJIHNwZWMgaGFzIHRvIGJlIGdlbmVyYXRlZCBsaXZlIG9uIHRoaXMgbm9kZS4KIyBFbnRpcmVseSBuby1vcCBvbiBhIG5vbi1XU0wyIG5vZGUgKG5vIC9kZXYvZHhnKSAtPiBhIG5vcm1hbCAoTGludXgvQ1BVKSBub2RlIGlzCiMgdW5hZmZlY3RlZCBhbmQgazNzIHN0YXJ0cyBleGFjdGx5IGFzIGJlZm9yZS4KIwojIFByb3ZlbiByZWNpcGUgKHZhbGlkYXRlZCBsaXZlIG9uIGFuIFJUWCA0MDUwIGxhcHRvcCwgZHJpdmVyIDUzMi4xMCk6CiMgICAxLiBudmlkaWEtY29udGFpbmVyLXJ1bnRpbWUgaW4gQ0RJIG1vZGUgKGJha2VkIGF0IGltYWdlIGJ1aWxkKS4KIyAgIDIuIGBudmlkaWEtY3RrIGNkaSBnZW5lcmF0ZSAtLW1vZGU9d3NsYCAtPiAvZXRjL2NkaS9udmlkaWEueWFtbC4KIyAgIDMuIGluamVjdCBsaWJkeGNvcmUuc28sIHdoaWNoIHRoZSBXU0wgZ2VuZXJhdG9yIG9taXRzIChpdCBsaXZlcyBpbiB0aGUgc3RhbmRhcmQKIyAgICAgIGxpYiBwYXRoLCBub3QgdGhlIGRyaXZlciBzdG9yZSkgLS0gd2l0aG91dCBpdCBsaWJjdWRhIGxvYWRzIGJ1dCBjYW4ndCByZWFjaAojICAgICAgL2Rldi9keGcgYW5kIENVREEgZmFpbHMgd2l0aCBhIG1pc2xlYWRpbmcgImRyaXZlciBpbnN1ZmZpY2llbnQiIGVycm9yLgojIEdQVSBpcyBPUFRJT05BTDogZXZlcnkgc3RlcCBpcyBndWFyZGVkIHNvIGEgZmFpbHVyZSBuZXZlciBibG9ja3MgazNzIGZyb20gc3RhcnRpbmcuCgppZiBbIC1lIC9kZXYvZHhnIF07IHRoZW4KICBta2RpciAtcCAvZXRjL2NkaSAyPi9kZXYvbnVsbCB8fCB0cnVlCiAgbnZpZGlhLWN0ayBjZGkgZ2VuZXJhdGUgLS1tb2RlPXdzbCAtLW91dHB1dD0vZXRjL2NkaS9udmlkaWEueWFtbCAyPi9kZXYvbnVsbCB8fCB0cnVlCgogICMgQWRkIGxpYmR4Y29yZS5zbyB0byB0aGUgc3BlYydzIG1vdW50cyBsaXN0LiBgbnZpZGlhLWN0ayBjZGkgZ2VuZXJhdGUgLS1tb2RlPXdzbGAgT01JVFMgaXQKICAjIChpdCBzZWFyY2hlcyB0aGUgV1NMIGRyaXZlciBzdG9yZTsgbGliZHhjb3JlIGxpdmVzIGluIHRoZSBzdGFuZGFyZCBsaWIgcGF0aCksIGFuZCBXSVRIT1VUIGl0CiAgIyBsaWJjdWRhIGxvYWRzIGJ1dCBjYW4ndCByZWFjaCAvZGV2L2R4ZyAtLSBDVURBIHRoZW4gZmFpbHMgd2l0aCB0aGUgbWlzbGVhZGluZyAiQ1VEQSBkcml2ZXIKICAjIHZlcnNpb24gaXMgaW5zdWZmaWNpZW50IGZvciBDVURBIHJ1bnRpbWUgdmVyc2lvbiIuCiAgIwogICMgSW5kZW50YXRpb24gaXMgTUlSUk9SRUQgZnJvbSB0aGUgZ2VuZXJhdG9yJ3Mgb3duIGZpcnN0IG1vdW50IGl0ZW0sIG5ldmVyIGhhcmRjb2RlZDogWUFNTAogICMgZm9yYmlkcyBtaXhpbmcgaW5kZW50IGxldmVscyB3aXRoaW4gb25lIGxpc3QsIHNvIGEgZml4ZWQgNC1zcGFjZSBpdGVtIG5leHQgdG8gdGhlIGdlbmVyYXRvcidzCiAgIyAoZGlmZmVyZW50bHkgaW5kZW50ZWQpIGl0ZW1zIG1ha2VzIHRoZSBXSE9MRSBzcGVjIHVucGFyc2VhYmxlIC0tIENESSB0aGVuIHNpbGVudGx5IGluamVjdHMKICAjIG5vdGhpbmcgYW5kIENVREEgZmFpbHMgZXhhY3RseSBhcyBpZiB0aGUgbW91bnQgd2VyZSBtaXNzaW5nLiBBbmNob3IgaXMgYWxzbyBpbmRlbnQtYWdub3N0aWMuCiAgIyBsaWJkeGNvcmUncyBsb2NhdGlvbiBpcyBOT1QgZml4ZWQgYWNyb3NzIERvY2tlciBEZXNrdG9wIC8gV1NMMiB2ZXJzaW9ucyAoQnVnYm90KTogaXQgbWF5IHNpdAogICMgaW4gdGhlIHN0YW5kYXJkIGxpYiBwYXRoLCB1bmRlciAvdXNyL2xpYi93c2wvbGliLCBvciBpbnNpZGUgdGhlIFdTTCBkcml2ZXIgc3RvcmUuIEhhcmRjb2RpbmcKICAjIG9uZSBwYXRoIG1lYW50IGEgbWlzcyBzaWxlbnRseSBza2lwcGVkIHRoZSBpbmplY3Rpb24gd2hpbGUgdGhlIHNwZWMgc3RpbGwgbG9va2VkIGZpbmUsIHNvIEdQVQogICMgd2FzIGFkdmVydGlzZWQgYW5kIHBvZHMgdGhlbiBmYWlsZWQgQ1VEQSB3aXRoIHRoZSBtaXNsZWFkaW5nIGRyaXZlciBlcnJvci4gUHJvYmUgdGhlIGtub3duCiAgIyBsb2NhdGlvbnMsIHRoZW4gZmFsbCBiYWNrIHRvIHRoZSBsaW5rZXIgY2FjaGUuIE1vdW50ZWQgYXQgdGhlIHBhdGggd2hlcmUgaXQgd2FzIGZvdW5kLCBzbyB0aGUKICAjIGluLXBvZCBsb2FkZXIgcmVzb2x2ZXMgaXQgdGhlIHNhbWUgd2F5IHRoZSBub2RlIGRvZXMuCiAgRFhDT1JFPSIiCiAgZm9yIF9jIGluIC91c3IvbGliL3g4Nl82NC1saW51eC1nbnUvbGliZHhjb3JlLnNvIC91c3IvbGliL3dzbC9saWIvbGliZHhjb3JlLnNvIFwKICAgICAgICAgICAgL3Vzci9saWIvd3NsL2RyaXZlcnMvKi9saWJkeGNvcmUuc28gL3Vzci9saWIvbGliZHhjb3JlLnNvOyBkbwogICAgaWYgWyAtZiAiJF9jIiBdOyB0aGVuIERYQ09SRT0iJF9jIjsgYnJlYWs7IGZpCiAgZG9uZQogIGlmIFsgLXogIiREWENPUkUiIF07IHRoZW4KICAgIF9jPSIkKGxkY29uZmlnIC1wIDI+L2Rldi9udWxsIHwgYXdrICcvbGliZHhjb3JlXC5zby8geyBwcmludCAkTkY7IGV4aXQgfScpIgogICAgaWYgWyAtbiAiJF9jIiBdICYmIFsgLWYgIiRfYyIgXTsgdGhlbiBEWENPUkU9IiRfYyI7IGZpCiAgZmkKCiAgaWYgWyAtZiAvZXRjL2NkaS9udmlkaWEueWFtbCBdICYmIFsgLW4gIiREWENPUkUiIF0gXAogICAgICAgJiYgISBncmVwIC1xICdsaWJkeGNvcmVcLnNvJyAvZXRjL2NkaS9udmlkaWEueWFtbDsgdGhlbgogICAgYXdrIC12IGR4PSIkRFhDT1JFIiAnCiAgICAgICMgcmVtZW1iZXIgdGhlIGluZGVudCBvZiB0aGUgZmlyc3QgbGlzdCBpdGVtIHRoYXQgZm9sbG93cyBhIGBtb3VudHM6YCBrZXkKICAgICAgIWRvbmUgJiYgJDAgfiAvXltbOnNwYWNlOl1dKm1vdW50czpbWzpzcGFjZTpdXSokLyB7IGlubW91bnRzID0gMTsgcHJpbnQ7IG5leHQgfQogICAgICBpbm1vdW50cyAmJiAhZG9uZSAmJiBtYXRjaCgkMCwgL15bWzpzcGFjZTpdXSotW1s6c3BhY2U6XV0vKSB7CiAgICAgICAgaXRlbSA9IHN1YnN0cigkMCwgMSwgUkxFTkdUSCAtIDIpICAgICAgICAgICMgbGVhZGluZyB3aGl0ZXNwYWNlIGJlZm9yZSB0aGUgZGFzaAogICAgICAgIGtleXMgPSBpdGVtICIgICIgICAgICAgICAgICAgICAgICAgICAgICAgICAgIyBtYXBwaW5nIGtleXMgc2l0IG9uZSBsZXZlbCBkZWVwZXIKICAgICAgICBwcmludCBpdGVtICItIGhvc3RQYXRoOiAiIGR4CiAgICAgICAgcHJpbnQga2V5cyAiY29udGFpbmVyUGF0aDogIiBkeAogICAgICAgIHByaW50IGtleXMgIm9wdGlvbnM6IgogICAgICAgIHByaW50IGtleXMgIi0gcm8iCiAgICAgICAgcHJpbnQga2V5cyAiLSBub3N1aWQiCiAgICAgICAgcHJpbnQga2V5cyAiLSBub2RldiIKICAgICAgICBwcmludCBrZXlzICItIHJiaW5kIgogICAgICAgIGRvbmUgPSAxCiAgICAgICAgcHJpbnQgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAjIHRoZW4gdGhlIGdlbmVyYXRvciBpdGVtIHdlIG1hdGNoZWQKICAgICAgICBuZXh0CiAgICAgIH0KICAgICAgeyBwcmludCB9CiAgICAnIC9ldGMvY2RpL252aWRpYS55YW1sID4gL2V0Yy9jZGkvbnZpZGlhLnlhbWwubmV3IDI+L2Rldi9udWxsIHx8IHRydWUKICAgICMgT25seSBhZG9wdCB0aGUgZWRpdCBpZiB0aGUgcmVzdWx0IHN0aWxsIFBBUlNFUyBhcyBhIENESSBzcGVjIC0tIG90aGVyd2lzZSBrZWVwIHRoZSBvcmlnaW5hbAogICAgIyAoR1BVIHdpdGhvdXQgbGliZHhjb3JlIGJlYXRzIGEgYnJva2VuIHNwZWMgdGhhdCBkaXNhYmxlcyB0aGUgR1BVIGVudGlyZWx5IGFuZCBzaWxlbnRseSkuCiAgICAjCiAgICAjIFRoZSByZXZlcnQgaXMgZ2F0ZWQgb24gYGNkaSBsaXN0YCBFWElTVElORywgZXhhY3RseSBsaWtlIHRoZSBjZGlfb2sgY2hlY2sgYmVsb3cgKEJ1Z2JvdCk6CiAgICAjIHRoYXQgc3ViY29tbWFuZCBpcyB2ZXJzaW9uLWRlcGVuZGVudCwgc28gY2FsbGluZyBpdCB1bmNvbmRpdGlvbmFsbHkgbWVhbnQgYSB0b29sa2l0IHdpdGhvdXQKICAgICMgaXQgcmV2ZXJ0ZWQgYSBQRVJGRUNUTFkgR09PRCBpbmplY3Rpb24gLS0gYW5kIHRoZSBpbnN0YWxsZXIgdGhlbiByZXBvcnRlZCAic3BlYyBpcyBtaXNzaW5nCiAgICAjIGxpYmR4Y29yZSIsIHdoaWNoIGlzIGZhbHNlIGFuZCB1bmFjdGlvbmFibGUuIFJldmVydCBvbmx5IHdoZW4gdGhlIHBhcnNlciBpcyBhdmFpbGFibGUgQU5ECiAgICAjIGFjdGl2ZWx5IHJlamVjdHMgdGhlIHJlc3VsdC4KICAgIGlmIFsgLXMgL2V0Yy9jZGkvbnZpZGlhLnlhbWwubmV3IF0gJiYgZ3JlcCAtcSAnbGliZHhjb3JlXC5zbycgL2V0Yy9jZGkvbnZpZGlhLnlhbWwubmV3OyB0aGVuCiAgICAgIGNwIC9ldGMvY2RpL252aWRpYS55YW1sIC9ldGMvY2RpL252aWRpYS55YW1sLm9yaWcgMj4vZGV2L251bGwgfHwgdHJ1ZQogICAgICBtdiAvZXRjL2NkaS9udmlkaWEueWFtbC5uZXcgL2V0Yy9jZGkvbnZpZGlhLnlhbWwgMj4vZGV2L251bGwgfHwgdHJ1ZQogICAgICBpZiBudmlkaWEtY3RrIGNkaSBsaXN0IC0taGVscCA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICAgICAgICBpZiAhIG52aWRpYS1jdGsgY2RpIGxpc3QgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgICAgICAgICBtdiAvZXRjL2NkaS9udmlkaWEueWFtbC5vcmlnIC9ldGMvY2RpL252aWRpYS55YW1sIDI+L2Rldi9udWxsIHx8IHRydWUKICAgICAgICBmaQogICAgICBmaQogICAgZmkKICAgIHJtIC1mIC9ldGMvY2RpL252aWRpYS55YW1sLm5ldyAvZXRjL2NkaS9udmlkaWEueWFtbC5vcmlnIDI+L2Rldi9udWxsIHx8IHRydWUKICBmaQoKICAjIElzIENESSBpbmplY3Rpb24gYWN0dWFsbHkgVVNBQkxFPyBBZHZlcnRpc2luZyBudmlkaWEuY29tL2dwdSB3aXRob3V0IGl0IGlzIHdvcnNlIHRoYW4gbm90CiAgIyBhZHZlcnRpc2luZyBhdCBhbGw6IHBvZHMgc2NoZWR1bGUgb250byBhIGRldmljZSB0aGV5IGNhbid0IHVzZSBhbmQgZmFpbCBDVURBIHdpdGggYQogICMgbWlzbGVhZGluZyBkcml2ZXIgZXJyb3IsIGFuZCBubyBjbHVzdGVyLWxldmVsIHNpZ25hbCBzYXlzIHdoeSAoQnVnYm90LCBISUdIKS4gVGhlIGluc3RhbGxlcgogICMgYWxyZWFkeSByZWZ1c2VzIGluIHRoYXQgY2FzZSwgYnV0IHRoaXMgcmVjb25jaWxlciBydW5zIGFnYWluIG9uIGV2ZXJ5IHJlc3RhcnQgLS0gc28gaXQgbXVzdAogICMgYXBwbHkgdGhlIFNBTUUgc3RhbmRhcmQgcmF0aGVyIHRoYW4gcmUtYXNzZXJ0aW5nIGNhcGFjaXR5IG9udG8gYSBicm9rZW4gbm9kZS4KICAjIFN0cnVjdHVyYWwgY2hlY2tzIGZpcnN0LCBhbmQgTk9UIGdhdGVkIG9uIGBudmlkaWEtY3RrIGNkaSBsaXN0YCBleGlzdGluZzogdGhhdCBzdWJjb21tYW5kIGlzCiAgIyB2ZXJzaW9uLWRlcGVuZGVudCwgc28ga2V5aW5nIHRoZSBkZWNpc2lvbiBvbiBpdCB3b3VsZCBkaXNhYmxlIGEgcGVyZmVjdGx5IHdvcmtpbmcgR1BVIG9uIGEKICAjIHRvb2xraXQgYnVpbGQgdGhhdCBsYWNrcyBpdCAoYSBmYWxzZSBuZWdhdGl2ZSBvbiBzb21lb25lIGVsc2UncyBtYWNoaW5lKS4gV2UgcmVxdWlyZSB0aGUgc3BlYwogICMgdG8gYmUgbm9uLWVtcHR5LCB0byBkZWNsYXJlIHRoZSBudmlkaWEuY29tL2dwdSBraW5kLCB0byBleHBvc2UgL2Rldi9keGcsIGFuZCB0byBjYXJyeSBvdXIKICAjIGxpYmR4Y29yZSBtb3VudCAtLSBhbGwgZm9ybWF0LXN0YWJsZSBmYWN0cy4gYGNkaSBsaXN0YCBpcyB0aGVuIHVzZWQgb25seSBhcyBhbiBFWFRSQSB2ZXRvIHdoZW4KICAjIGl0IGlzIGF2YWlsYWJsZSwgc28gYSBzcGVjIGl0IGFjdGl2ZWx5IHJlamVjdHMgc3RpbGwgY2FuJ3QgYWR2ZXJ0aXNlIGEgR1BVLgogIGNkaV9vaz0wCiAgaWYgWyAtcyAvZXRjL2NkaS9udmlkaWEueWFtbCBdIFwKICAgICAgICYmIGdyZXAgLXEgJ252aWRpYVwuY29tL2dwdScgL2V0Yy9jZGkvbnZpZGlhLnlhbWwgXAogICAgICAgJiYgZ3JlcCAtcSAnL2Rldi9keGcnIC9ldGMvY2RpL252aWRpYS55YW1sIFwKICAgICAgICYmIGdyZXAgLXEgJ2xpYmR4Y29yZVwuc28nIC9ldGMvY2RpL252aWRpYS55YW1sOyB0aGVuCiAgICBjZGlfb2s9MQogICAgaWYgbnZpZGlhLWN0ayBjZGkgbGlzdCAtLWhlbHAgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgICAgIG52aWRpYS1jdGsgY2RpIGxpc3QgPi9kZXYvbnVsbCAyPiYxIHx8IGNkaV9vaz0wCiAgICBmaQogIGZpCgogICMgS2VlcCBudmlkaWEuY29tL2dwdSBhZHZlcnRpc2VkIGFjcm9zcyByZXN0YXJ0cyAoQnVnYm90LCBISUdIKS4gQSBtYW51YWxseSBwYXRjaGVkCiAgIyBleHRlbmRlZCByZXNvdXJjZSBpcyBOT1QgZHVyYWJsZTogdGhlIGt1YmVsZXQgcmUtcmVwb3J0cyBub2RlIHN0YXR1cyBvbiBldmVyeQogICMgc3RhcnQsIHplcm9pbmcgaXQgLS0gc28gYWZ0ZXIgYSBEb2NrZXIgRGVza3RvcCBvciBXaW5kb3dzIHJlc3RhcnQgdGhlIGluc3RhbGxlcidzCiAgIyBvbmUtc2hvdCBwYXRjaCBpcyBnb25lLCB0aGUgY2hhcnQgc3RpbGwgcmVxdWVzdHMgYSBHUFUsIGFuZCBldmVyeSBqb2Igd291bGQgc2l0CiAgIyBQZW5kaW5nIHdpdGggIkluc3VmZmljaWVudCBudmlkaWEuY29tL2dwdSIgdW50aWwgc29tZW9uZSByZS1yYW4gdGhlIGluc3RhbGxlci4KICAjIFRoZXJlJ3Mgbm8gZGV2aWNlIHBsdWdpbiB0byBvd24gdGhlIHJlc291cmNlIGhlcmUsIHNvIHRoaXMgbm9kZSByZS1hc3NlcnRzIGl0CiAgIyBpdHNlbGY6IGEgYmFja2dyb3VuZCByZWNvbmNpbGVyIHdhaXRzIGZvciB0aGUgbG9jYWwgQVBJLCB0aGVuIHJlLXBhdGNoZXMgd2hlbmV2ZXIKICAjIHRoZSBjYXBhY2l0eSBpcyBtaXNzaW5nLiBSdW5zIG9uIEVWRVJZIG5vZGUgc3RhcnQgKGszZCBydW5zIHRoaXMgZHJvcC1pbiBlYWNoIHRpbWUpLAogICMgc28gYSByZWJvb3Qgc2VsZi1oZWFscyB3aXRoIG5vIHVzZXIgYWN0aW9uLiBGdWxseSBndWFyZGVkICsgYmFja2dyb3VuZGVkOiBpdCBjYW4KICAjIG5ldmVyIGRlbGF5IG9yIGJsb2NrIGszcy4gSW50ZXJ2YWwgb3ZlcnJpZGU6IFRSQUNFQkxPQ19HUFVfUkVDT05DSUxFX1NFQ1MuCiAgIyBHYXRlZCBvbiBjZGlfb2sgc28gYSBicm9rZW4vaW5jb21wbGV0ZSBDREkgc3BlYyBuZXZlciBnZXRzIGEgR1BVIGFkdmVydGlzZWQgb250byBpdC4KICAjCiAgIyBGdWxseSBERVRBQ0hFRCAoPC9kZXYvbnVsbCwgb3V0cHV0IHRvIC9kZXYvbnVsbCk6IHRoaXMgZHJvcC1pbiBleGl0cyBpbW1lZGlhdGVseSBhZnRlcgogICMgZm9ya2luZywgc28gdGhlIGxvb3AgaXMgb3JwaGFuZWQgYW5kIHJlcGFyZW50ZWQgdG8gUElEIDEgKGszcywgd2hpY2ggazNkJ3MgZW50cnlwb2ludAogICMgZXhlY3MpLiBIb2xkaW5nIHRoZSBpbmhlcml0ZWQgc3RkaW8gd291bGQgcmlzayBibG9ja2luZyBvbiBhIGNsb3NlZCBwaXBlLgogIGlmIFsgIiRjZGlfb2siID0gIjEiIF07IHRoZW4KICAoCiAgICBpbnRlcnZhbD0iJHtUUkFDRUJMT0NfR1BVX1JFQ09OQ0lMRV9TRUNTOi02MH0iCiAgICBrdWJlPSIvZXRjL3JhbmNoZXIvazNzL2szcy55YW1sIgogICAgd2hpbGUgOjsgZG8KICAgICAgaWYgWyAtcyAiJGt1YmUiIF07IHRoZW4KICAgICAgICBjdXJyZW50PSIkKC9iaW4vazNzIGt1YmVjdGwgLS1rdWJlY29uZmlnICIka3ViZSIgZ2V0IG5vZGUgIiQoaG9zdG5hbWUpIiBcCiAgICAgICAgICAtbyAianNvbnBhdGg9ey5zdGF0dXMuY2FwYWNpdHkubnZpZGlhXFwuY29tL2dwdX0iIFwKICAgICAgICAgIC0tcmVxdWVzdC10aW1lb3V0PTEwcyAyPi9kZXYvbnVsbCB8fCB0cnVlKSIKICAgICAgICBjYXNlICIkY3VycmVudCIgaW4KICAgICAgICAgICcnfDApCiAgICAgICAgICAgIC9iaW4vazNzIGt1YmVjdGwgLS1rdWJlY29uZmlnICIka3ViZSIgcGF0Y2ggbm9kZSAiJChob3N0bmFtZSkiIFwKICAgICAgICAgICAgICAtLXN1YnJlc291cmNlPXN0YXR1cyAtLXR5cGU9anNvbiAtLXJlcXVlc3QtdGltZW91dD0xNXMgXAogICAgICAgICAgICAgIC1wICdbeyJvcCI6ImFkZCIsInBhdGgiOiIvc3RhdHVzL2NhcGFjaXR5L252aWRpYS5jb21+MWdwdSIsInZhbHVlIjoiMSJ9XScgXAogICAgICAgICAgICAgID4vZGV2L251bGwgMj4mMSB8fCB0cnVlCiAgICAgICAgICAgIDs7CiAgICAgICAgZXNhYwogICAgICBmaQogICAgICBzbGVlcCAiJGludGVydmFsIgogICAgZG9uZQogICkgPC9kZXYvbnVsbCA+L2Rldi9udWxsIDI+JjEgJgogIGZpCmZpCgojIFJldHVybiBjb250cm9sIHRvIGszZCdzIGVudHJ5cG9pbnQsIHdoaWNoIHJ1bnMgdGhlIHJlbWFpbmluZyBkcm9wLWlucyBhbmQgdGhlbiBleGVjcwojIGszcy4gQUxXQVlTIDA6IGszZCBhYm9ydHMgdGhlIG5vZGUgb24gYSBub24temVybyBkcm9wLWluIGV4aXQsIGFuZCBHUFUgaXMgb3B0aW9uYWwuCmV4aXQgMAo='

# Build the custom k3s-CUDA node image LOCALLY, from PUBLIC bases only (rancher/k3s on
# Docker Hub + NVIDIA's public nvcr.io CUDA base + the public NVIDIA container toolkit).
# This is why a GPU install needs no registry login and no private package: the one
# installer command builds the node image on the user's own machine (#616). Idempotent
# (reuses an already-built image), bounded with a visible progress bar (installer rule),
# and any failure falls back to CPU with a clear reason rather than stranding the install.
# Sanity-check that the GPU node image actually runs k3s (the ENTRYPOINT is /bin/k3s, so
# `docker run --rm <img> --version` prints "k3s version ..."). Catches a broken rootfs -- e.g.
# the COPY --exclude mis-parse that once shipped a non-working /bin/k3s. Bounded.
function Test-GpuImageRunsK3s {
  # Run WITH --gpus (no -e NVIDIA_DISABLE_REQUIRE) so this exercises the EXACT container-create path
  # k3d cluster-create will take: a stale image lacking the baked NVIDIA_DISABLE_REQUIRE would fail
  # the CUDA-requirement gate here on an older driver and drop us to CPU, instead of passing a
  # no-gpus check and then aborting cluster-create (Bugbot). Our own images bake the bypass, so they
  # pass on any driver. Callers only reach here after Confirm-DockerGpu, so --gpus is available.
  $ver = Invoke-DockerCli -DockerArgs @("run", "--rm", "--gpus", "all", $K3S_CUDA_IMAGE, "--version") -TimeoutSec 60
  return ($ver.Code -eq 0 -and $ver.Output -match 'k3s version')
}

# Short content hash of the build inputs (embedded Dockerfile + device-plugin manifest). Stamped
# as a label on the built image and checked on reuse, so ANY change to the build inputs (e.g.
# adding NVIDIA_DISABLE_REQUIRE) invalidates a cached image built from OLDER content -- the image
# TAG alone doesn't change when the Dockerfile does, so a stale cached image would otherwise be
# reused and then fail cluster-create on an older driver (Bugbot).
function Get-GpuBuildContentHash {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes("$($script:K3S_CUDA_DOCKERFILE_B64)|$($script:K3S_CUDA_RUNTIMECLASS_B64)|$($script:K3S_CUDA_BOOT_B64)")
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return (([System.BitConverter]::ToString($sha.ComputeHash($bytes))) -replace '-','').Substring(0,12).ToLower() }
  finally { $sha.Dispose() }
}

# Turn a failed `docker build` of the GPU node image into a reason the operator can ACT on.
# PURE (output + exit code in, string out) so every branch is unit-tested. Ordered most- to
# least-specific; the fallback still names the log. These are exactly the cases that vary
# between machines, which is why a bare "exit 1" was not good enough (#616).
function Get-GpuBuildFailureReason {
  param([string]$BuildOutput, [int]$ExitCode)
  $o = "$BuildOutput"
  if ($o -match 'dockerfile:1\.7-labs|unknown flag: --exclude|failed to solve with frontend|frontend dockerfile\.v0|unsupported frontend|Dockerfile syntax') {
    return "your Docker Desktop is too old to build the GPU node image (it needs BuildKit with the dockerfile 1.7-labs frontend) -- update Docker Desktop and re-run, or point TRACEBLOC_K3S_CUDA_IMAGE at a prebuilt image; running CPU-only"
  }
  if ($o -match 'no space left on device|disk quota exceeded') {
    return "the machine ran out of disk while building the GPU node image -- free up space and re-run; running CPU-only"
  }
  if ($o -match 'manifest unknown|manifest for .* not found|not found: manifest|unknown tag') {
    return "the CUDA base image tag ($CUDA_BASE_TAG) no longer exists upstream -- set TRACEBLOC_CUDA_BASE_TAG to an available tag and re-run; running CPU-only"
  }
  if ($o -match 'TLS handshake|x509|certificate') {
    return "the GPU node image build hit a TLS/certificate error reaching the base images (usually a TLS-inspecting proxy) -- set TRACEBLOC_CA_BUNDLE to your corporate CA and re-run; running CPU-only"
  }
  if ($o -match 'i/o timeout|connection refused|temporary failure in name resolution|dial tcp|could not resolve|failed to fetch|Could not connect') {
    return "the GPU node image build couldn't download its base images (nvcr.io / Docker Hub blocked or offline) -- on a restricted network set TRACEBLOC_IMAGE_REGISTRY to your mirror and re-run; running CPU-only"
  }
  if ($o -match 'toomanyrequests|rate limit') {
    return "the GPU node image build was rate-limited by the registry -- retry later, or set TRACEBLOC_IMAGE_REGISTRY to your mirror; running CPU-only"
  }
  return "the GPU node image build failed (docker build exit $ExitCode) -- see the install log for the build output; running CPU-only"
}

function Build-GpuNodeImage {
  $contentHash = Get-GpuBuildContentHash
  # Idempotent: a prior run already built it -> reuse WITHOUT rebuilding, but ONLY if (a) it was
  # built from the CURRENT build inputs (its stamped content-hash label matches) AND (b) it still
  # passes the k3s sanity check. A cached image built from OLDER content (e.g. before the
  # NVIDIA_DISABLE_REQUIRE fix) has a different/absent label -> we rebuild instead of reusing a
  # stale image that would fail cluster-create on an older driver (Bugbot). {{.Config.Labels}} is
  # a single space-free arg; we regex the label out of the rendered map.
  $have = Invoke-DockerCli -DockerArgs @("image","inspect",$K3S_CUDA_IMAGE,"--format","{{.Config.Labels}}") -TimeoutSec 30
  if ($have.Code -eq 0) {
    if (($have.Output -match "tracebloc\.k3s-cuda-content:$contentHash") -and (Test-GpuImageRunsK3s)) {
      Log "GPU node image already built from current inputs + verified ($K3S_CUDA_IMAGE) -- reusing"
      return $true
    }
    Log "An existing GPU node image ($K3S_CUDA_IMAGE) is stale (built from older inputs) or failed its sanity check -- rebuilding it."
  }

  # BuildKit is required for the Dockerfile's `# syntax=...:1.7-labs` + `COPY --exclude`.
  # Docker Desktop defaults to BuildKit; set it explicitly so the child build inherits it
  # (PS 5.1 Start-Process has no -Environment, so we set the process env, which children inherit).
  $env:DOCKER_BUILDKIT = "1"

  # Write the build context (embedded Dockerfile + device-plugin manifest) to a fresh temp dir.
  # Everything that can throw -- the dir creation AND the writes -- lives INSIDE the try so a
  # temp-dir permission / antivirus / disk error degrades to CPU instead of reaching the
  # top-level fatal trap and aborting an otherwise-fine install (Bugbot).
  $ctx = Join-Path $env:TEMP ("tracebloc-k3s-cuda-" + [guid]::NewGuid().ToString('N'))
  $outLog = Join-Path $env:TEMP "k3s-cuda-build-$(Get-Random).log"
  $errLog = Join-Path $env:TEMP "k3s-cuda-build-err-$(Get-Random).log"
  try {
    New-Item -ItemType Directory -Path $ctx -ErrorAction Stop | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $ctx "Dockerfile"), [System.Convert]::FromBase64String($script:K3S_CUDA_DOCKERFILE_B64))
    [System.IO.File]::WriteAllBytes((Join-Path $ctx "nvidia-runtimeclass.yaml"), [System.Convert]::FromBase64String($script:K3S_CUDA_RUNTIMECLASS_B64))
    [System.IO.File]::WriteAllBytes((Join-Path $ctx "k3d-entrypoint-tracebloc-cdi.sh"), [System.Convert]::FromBase64String($script:K3S_CUDA_BOOT_B64))

    Log "Building the GPU node image locally from public bases (k3s=$K8S_VERSION cuda=$CUDA_BASE_TAG): $K3S_CUDA_IMAGE"
    Info "Building GPU support -- one-time, ~2-4 min (downloads the public NVIDIA CUDA + k3s bases)."

    $buildArgs = @(
      "build",
      "--build-arg", "K3S_TAG=$K8S_VERSION",
      "--build-arg", "CUDA_TAG=$CUDA_BASE_TAG",
      "--label", "tracebloc.k3s-cuda-content=$contentHash",   # stamps the content hash for reuse detection
      "-t", $K3S_CUDA_IMAGE,
      $ctx
    )
    $dExe = (Get-Command docker -ErrorAction SilentlyContinue).Source
    if (-not $dExe) { $dExe = "docker" }
    # Escape+escape-quote each arg per the exact CommandLineToArgvW rules (ConvertTo-Win32Arg,
    # backend#2545), NOT the naive wrap-if-it-has-a-space: -ArgumentList <one string> is handed to
    # the child's command line verbatim, just like $psi.Arguments, so an arg carrying BOTH a space
    # and a `"` (e.g. a `--label`/`--build-arg` value) had its inner quotes silently consumed by
    # the re-split. The helper leaves a safe arg untouched and quotes the rest correctly.
    $argStr = ($buildArgs | ForEach-Object { ConvertTo-Win32Arg $_ }) -join " "

    $proc = $null
    try {
      $proc = Start-Process -FilePath $dExe -ArgumentList $argStr -NoNewWindow -PassThru -ErrorAction Stop `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    } catch {
      Log "Couldn't start docker build: $($_.Exception.Message)"
      $script:GPU_SKIP_REASON = "couldn't start 'docker build' to create the GPU node image -- is Docker running? (running CPU-only)"
      return $false
    }

    # Bounded with a heartbeat (progress bar), same pattern as cluster-create. Generous
    # deadline: the first build downloads a multi-hundred-MB CUDA base + installs packages.
    $buildMin = 20
    if ("$env:TB_GPU_BUILD_TIMEOUT_MIN" -match '^\d+$') { $buildMin = [int]$env:TB_GPU_BUILD_TIMEOUT_MIN }
    if (-not (Wait-ProcessWithDeadline -Process $proc -Deadline (Get-Date).AddMinutes($buildMin) -Message "Building GPU support (one-time, a few minutes)...")) {
      $tail = @()
      if (Test-Path $errLog) { $tail = @(Get-Content $errLog -ErrorAction SilentlyContinue | Select-Object -Last 5) }
      foreach ($line in $tail) { Log "docker build: $line" }
      $script:GPU_SKIP_REASON = "building the GPU node image timed out -- slow or blocked network reaching the public CUDA/k3s bases (running CPU-only)"
      return $false
    }
    $buildOut = (("$(Get-Content $errLog -Raw -ErrorAction SilentlyContinue)`n$(Get-Content $outLog -Raw -ErrorAction SilentlyContinue)")).Trim()
    if ($buildOut) { Log "docker build output (tail): $(( $buildOut -split "`n" | Select-Object -Last 8) -join "`n")" }
    # Defense-in-depth (#611 idiom / Bugbot): with redirected stdout/stderr, $proc.ExitCode can
    # stay $null after the process exits even though Wait-ProcessWithDeadline called WaitForExit().
    # `$null -ne 0` would then misclassify a SUCCESSFUL build as failed and silently drop GPU. So
    # fail only on a CONFIRMED non-zero exit; a null code defers to the k3s sanity check below,
    # which is the authoritative "did the build produce a working image" success marker.
    $buildExit = $proc.ExitCode
    if ($null -eq $buildExit) {
      Log "docker build exit code unreadable after WaitForExit; relying on the image sanity check as the success marker."
    } elseif ($buildExit -ne 0) {
      # Classify the failure instead of emitting a bare exit code (the operator can't act on
      # "exit 1"). These are the drift/environment cases that differ machine to machine:
      # an older Docker Desktop without the BuildKit labs frontend, a blocked/offline base
      # image, a retired CUDA tag, or a full disk. Each gets the concrete next step.
      $script:GPU_SKIP_REASON = Get-GpuBuildFailureReason -BuildOutput $buildOut -ExitCode $buildExit
      Warn ("GPU couldn't be enabled: " + $script:GPU_SKIP_REASON)
      return $false
    }

    # Sanity-check the freshly built image actually runs k3s (same check reused on the
    # idempotent-reuse path above, so a broken image is never trusted from either direction).
    # This is ALSO the authoritative success marker when the exit code was unreadable.
    if (-not (Test-GpuImageRunsK3s)) {
      $script:GPU_SKIP_REASON = "the freshly built GPU node image didn't run k3s correctly -- running CPU-only (see the install log)"
      Log "GPU node image sanity check failed after build"
      return $false
    }
    Ok "GPU node image built locally -- no registry login required."
    Log "GPU node image built + verified: $K3S_CUDA_IMAGE"
    return $true
  } catch {
    # GPU is OPTIONAL: a temp-dir permission/AV/disk error while staging the build
    # context (or any unexpected build error) must degrade to CPU, never reach the
    # top-level fatal trap and abort the whole install (Bugbot). CPU fallback stays safe.
    Log "GPU node image build errored: $($_.Exception.Message)"
    $script:GPU_SKIP_REASON = "the GPU node image couldn't be built ($($_.Exception.Message)) -- running CPU-only"
    return $false
  } finally {
    Remove-Item $ctx -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $outLog, $errLog -Force -ErrorAction SilentlyContinue
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
  # Fetch the .sha256 FIRST, then make it the download gate (#609): with -Sha256 the
  # binary download retries transports (Invoke-WebRequest -> curl.exe -> BITS) until a
  # byte-correct copy lands, so a mid-transfer truncation self-heals instead of
  # dead-ending at a post-hoc checksum. dl.k8s.io publishes the bare 64-hex hash.
  $kSums = "$env:TEMP\kubectl-sha-$([System.IO.Path]::GetRandomFileName()).txt"
  try {
    Get-VerifiedDownload -Url "https://dl.k8s.io/release/$kVer/bin/windows/$arch/kubectl.exe.sha256" `
      -Dest $kSums -MinBytes 1 -MatchPattern '^\s*[0-9a-fA-F]{64}' `
      -Label "kubectl checksum" -Message "Fetching kubectl checksum"
  } catch {
    Remove-Item $kSums -Force -ErrorAction SilentlyContinue
    Err "Couldn't fetch the kubectl checksum ($_). Check egress to dl.k8s.io and re-run."
  }
  $expectedHash = ((Get-Content $kSums -Raw).Trim())
  Remove-Item $kSums -Force -ErrorAction SilentlyContinue
  if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
    Err "Couldn't read a valid kubectl checksum (got an error page?). Check egress to dl.k8s.io and re-run."
  }
  Get-VerifiedDownload -Url $kUrl -Dest $kubectlDest -MinBytes 20MB -Magic 'MZ' -Sha256 $expectedHash `
    -Label "kubectl download" -Message "Downloading kubectl $kVer (~60 MB)"
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
  # No winget path: k3d has no manifest in the winget community repo (verified
  # #607 — `Rancher.k3d` and every id variant 404), so `winget install` only ever
  # returned "No package found", burning ~4s and muddying diagnosis before the
  # direct download ran anyway. The direct download below is now resilient
  # (Get-VerifiedDownload: multi-transport + completeness validation), so it is the
  # single, reliable path. Re-add a winget branch here only if k3d is ever
  # published to winget.
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
      # Fetch the checksum list FIRST, then make the SHA the download gate (#609).
      # The release's checksum asset is checksums.txt ("<sha256>  _dist/<asset>"
      # lines). Fetching it resiliently (multi-transport + must contain the asset
      # line) means a proxy error page is retried, and passing the extracted hash to
      # Get-VerifiedDownload makes the binary download retry transports until a
      # byte-correct copy lands -- the fix for a mid-transfer truncation that used to
      # slip past the size floor and dead-end at the checksum (the #607 field case).
      $k3dSums = "$env:TEMP\k3d-checksums-$([System.IO.Path]::GetRandomFileName()).txt"
      try {
        Get-VerifiedDownload -Url "https://github.com/k3d-io/k3d/releases/download/$k3dVer/checksums.txt" `
          -Dest $k3dSums -MinBytes 1 -MatchPattern "[0-9a-fA-F]{64}\s+\S*k3d-windows-$arch\.exe" `
          -Label "k3d checksums" -Message "Fetching k3d checksums"
      } catch {
        Remove-Item $k3dSums -Force -ErrorAction SilentlyContinue
        Err "Couldn't fetch the k3d checksums ($_). Check egress to github.com and re-run."
      }
      $expectedHash = (((Get-Content $k3dSums) |
        Where-Object { $_ -match "k3d-windows-$arch\.exe" }) -replace '\s+.*', '' |
        Select-Object -First 1)
      Remove-Item $k3dSums -Force -ErrorAction SilentlyContinue
      if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
        Err "Couldn't read a valid k3d checksum from checksums.txt. Check egress to github.com and re-run."
      }
      Get-VerifiedDownload -Url $k3dUrl -Dest $k3dDest -MinBytes 10MB -Magic 'MZ' -Sha256 $expectedHash.Trim() `
        -Label "k3d download" -Message "Downloading k3d $k3dVer (~25 MB)"
      Log "k3d checksum verified."
      RefreshPath
      # Compute the summary now (correct elapsed) but print it only AFTER the
      # execute-gate passes — a corrupt/wrong-arch binary must not show a green
      # "ready" line before Assert-ToolRuns (#422 Bugbot; kubectl gates first too).
      $k3dSummary = Get-ToolSummaryLine -Name "k3d" -Version $k3dVer -Size "~25 MB" -ElapsedSec ([int]((Get-Date) - $t0k3d).TotalSeconds)
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
      # Checksum-gated like k3d/kubectl (#609): get.helm.sh publishes
      # <zip>.sha256sum ("<hash>  <zip-name>"). Fetch it first so the zip download
      # retries transports until byte-correct -- a truncated zip that used to pass
      # size+magic and then fail at Expand-Archive now self-heals. (The PS path had
      # no helm checksum at all before; this also brings it to parity with the
      # bash path, which already verifies helm.)
      $helmSums = "$env:TEMP\helm-sha-$([System.IO.Path]::GetRandomFileName()).txt"
      try {
        Get-VerifiedDownload -Url "$helmUrl.sha256sum" -Dest $helmSums -MinBytes 1 `
          -MatchPattern "[0-9a-fA-F]{64}\s+\S*helm-\S*windows-$arch\.zip" -Label "helm checksum" -Message "Fetching Helm checksum"
      } catch {
        Remove-Item $helmSums -Force -ErrorAction SilentlyContinue
        Err "Couldn't fetch the Helm checksum ($_). Check egress to get.helm.sh and re-run."
      }
      $helmHash = (((Get-Content $helmSums) -split '\s+' | Select-Object -First 1))
      Remove-Item $helmSums -Force -ErrorAction SilentlyContinue
      if ($helmHash -notmatch '^[0-9a-fA-F]{64}$') {
        Err "Couldn't read a valid Helm checksum from get.helm.sh. Check egress and re-run."
      }
      Get-VerifiedDownload -Url $helmUrl -Dest $helmZip -MinBytes 5MB -Magic 'PK' -Sha256 $helmHash `
        -Label "helm download" -Message "Downloading Helm $helmVer (~20 MB)"
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

# Wire the resolved corporate CA into git (Git-for-Windows is OpenSSL-backed and honors
# GIT_SSL_CAINFO) (#583). cosign & helm are Go, and Go on Windows reads the certificate
# store and IGNORES SSL_CERT_FILE (Bugbot) — so we do NOT set it (it would be inert and
# misleading); those trust the CA only when it's in the Windows store. curl/
# Invoke-WebRequest already use the Windows store, and we never re-export CURL_CA_BUNDLE
# (replace-not-augment). The k3d nodes are trusted at cluster-create (#424). No-op when
# unconfigured; Resolve-CaBundle fails fast on an unreadable bundle.
function Set-ToolTrust {
  $ca = Resolve-CaBundle
  if (-not $ca) { return }
  # Don't clobber a fuller pre-set GIT_SSL_CAINFO (replace-not-augment): only set it
  # when the user hasn't already (Bugbot). And say only what actually happened: a
  # green "Trusting..." while the export was skipped reported wiring that did not
  # happen - masking a pre-set bundle that may still lack the corporate CA (Bugbot).
  if (-not $env:GIT_SSL_CAINFO) {
    $env:GIT_SSL_CAINFO = $ca
    Ok "Trusting your company's certificate for git."
  } else {
    Hint "Keeping your pre-set GIT_SSL_CAINFO - make sure that bundle includes your company's CA, or git will still fail x509."
  }
  Hint "On Windows, cosign, helm and the installer's downloads read the certificate store, not a PEM file - import your corporate CA into Cert:\LocalMachine\Root (or use the offline installer) so they trust it too."
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

  # 2) Docker Desktop autostart. On the WSL2 backend, dockerd runs INSIDE the
  # docker-desktop distro that the Docker Desktop GUI boots; without the GUI
  # autostarting on the daily user's login, the engine isn't up after a reboot,
  # so the k3d containers (which carry --restart unless-stopped) have no daemon
  # to restart into and the client is down until someone opens Docker Desktop
  # manually (#558). For the CURRENT user the per-user Run key is simplest. For
  # a PROVISIONED DIFFERENT user (the hospital IT-installs-elevated case), their
  # registry hive isn't loaded, so the Run key can't be written for them; drop a
  # shortcut into THEIR Startup folder instead — the same "launch at this user's
  # logon" mechanism, no hive needed. --always-run-service (#419) is kept as a
  # backstop, but its headless-engine behaviour is Docker-Desktop-version
  # dependent, so autostart is no longer left to it alone for the second user.
  try {
    $ddExe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
    if (-not (Test-Path $ddExe)) {
      Log "autostart skipped: Docker Desktop not found at $ddExe"
    } elseif ($user -eq $env:USERNAME) {
      New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'Docker Desktop' -Value "`"$ddExe`"" -PropertyType String -Force -ErrorAction Stop | Out-Null
      $did += "autostart enabled"
    } else {
      $profileDir = Get-UserProfileDir -User $user
      if ($null -eq $profileDir) {
        # Never signed in -> no profile/Startup folder to write into. Name the
        # one-click GUI setting they can flip after first sign-in.
        $did += "no profile for '$user' yet -- have them enable Docker Desktop's 'Start Docker Desktop when you sign in' (Settings > General) after first sign-in"
      } else {
        $startupDir = Join-Path $profileDir 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        if (-not (Test-Path $startupDir)) { New-Item -ItemType Directory -Path $startupDir -Force -ErrorAction Stop | Out-Null }
        $lnkPath = Join-Path $startupDir 'Docker Desktop.lnk'
        $wsh = New-Object -ComObject WScript.Shell
        try {
          $sc = $wsh.CreateShortcut($lnkPath)
          $sc.TargetPath       = $ddExe
          $sc.WorkingDirectory = (Split-Path $ddExe)
          $sc.Save()
        } finally {
          [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
        }
        $did += "autostart enabled (Startup shortcut in '$user's profile)"
      }
    }
  } catch {
    # A thrown COM/dir/permission failure here (creating the Startup folder, the
    # WScript.Shell COM object, or saving the .lnk) must surface in the summary too
    # -- otherwise docker-users succeeding prints a green "Configured for" with no
    # autostart note, and IT leaves the elevated window thinking the daily user is
    # ready while Docker Desktop won't launch on their login and the client is down
    # after every reboot (#558 Bugbot). Mirror the .wslconfig catch below: log AND
    # append a manual-step note to $did so the summary is honest about what's left.
    Log "autostart set failed: $_"
    $did += "couldn't set Docker Desktop autostart -- have '$user' enable Docker Desktop's 'Start Docker Desktop when you sign in' (Settings > General)"
  }

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
#  node-local (RFC-0003 Option C) is the Linux/k3s default since the D15 flip
#  (client#456) but still has no Windows path, so this is intentionally scoped to
#  hostpath. Non-interactive knobs mirror the
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

# The recreate remedy, printed from ONE place -- peer of cluster.sh::_recreate_cluster_hint
# (backend#2077).
#
# Why it can't just be `k3d cluster delete`: this machine's backend record is anchored to
# the identity of the CLUSTER (the kube-system namespace UID), which is born with the k3d
# cluster and dies with it. `k3d cluster delete` never calls the API, so the record keeps a
# cluster_id that will never exist again -- the next run correctly registers a NEW secure
# environment and the old one is stranded on the dashboard for good.
#
# `tracebloc delete` is the offboard that releases it: it revokes this machine's credential
# server-side (the record is kept as history, never hard-destroyed), uninstalls the Helm
# release and tears down its own local cluster. The revoke is an API call, so it still works
# when the cluster itself is broken -- the state at most of these call sites.
#
# --keep-data is not optional: the plain form wipes the local data + config directory, which
# is exactly what these call sites promise a recreate keeps. The k3d line stays because
# `tracebloc delete` only tears down a cluster literally named `tracebloc`, so a custom
# CLUSTER_NAME still needs it (and on the default name it is a harmless no-op).
#
# -RerunPrefix: env assignments to prefix the re-run with, for the call sites that need one.
# Pure: the current kubectl context out of a BOUNDED kubectl's merged output.
#
# Invoke-BoundedProcess returns stdout and stderr concatenated in that order, and
# `kubectl config current-context` prints exactly one line on stdout — so the first
# non-empty line is the context and everything after it is noise. Comparing the whole
# blob would hard-stop a correctly switched install the moment kubectl emitted a
# deprecation or plugin warning on stderr; the bash peer sidesteps it with `2>/dev/null`,
# which this helper is the Windows equivalent of (Bugbot).
#
# Empty in, empty out — "we couldn't tell" stays a failure at the call site, never a pass.
function Get-CurrentContextFromOutput {
  param([string]$Output)
  foreach ($line in ($Output -split "`r?`n")) {
    $trimmed = $line.Trim()
    if ($trimmed -ne "") { return $trimmed }
  }
  return ""
}

function Write-RecreateClusterHint {
  param([string]$RerunPrefix = "")
  Hint "Release this machine's secure environment BEFORE deleting the cluster - it is anchored to the"
  Hint "cluster's identity, so deleting the cluster first strands it on your dashboard for good:"
  Hint "  tracebloc delete --keep-data      (releases this secure environment; keeps your local data)"
  Hint "  k3d cluster delete $CLUSTER_NAME  (then ${RerunPrefix}re-run this installer)."
  Hint "  (nothing installed on this machine yet? then just the k3d line.)"
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
  # Extract the running k3s pin from EITHER the stock image (rancher/k3s:<ver>) or the GPU
  # node image (…/k3s-cuda:<ver>-cuda-<base>) — else a GPU cluster silently escapes the
  # drift check and stays on an old, unvalidated k3s after a pin bump (Bugbot).
  $runningK3s = ""
  if ($k3sImage -match 'rancher/k3s:([^@\s]+)') {
    $runningK3s = $Matches[1]
  } elseif ($k3sImage -match 'k3s-cuda:([^@\s]+)') {
    $cudaTag = $Matches[1]
    if ($cudaTag -match '^(.+?)-cuda-') { $runningK3s = $Matches[1] } else { $runningK3s = $cudaTag }
  }
  # The wording below names "predates the current pin" FIRST on purpose. backend#2448
  # made drift the COMMON case rather than the exception: moving the pin 1.29.4 ->
  # 1.36.3 marks every pre-existing cluster as drifted, and for those operators
  # neither original cause -- an unpinned installer, or K8S_VERSION=latest -- is what
  # happened. Keep in step with the bash twin.
  #
  # Comments stay OUT of the Warn..Write-RecreateClusterHint run: the backend#2077
  # source guard asserts the remedy follows "not the validated pin" within 600
  # characters, and a comment block wedged between them pushed it past that and
  # reddened a guard this change never touched.
  if ($runningK3s -ne "" -and $runningK3s -ne $K8S_VERSION) {
    Warn "The existing '$CLUSTER_NAME' cluster runs k3s '$runningK3s', not the validated pin '$K8S_VERSION'."
    Hint "k3s version is fixed when the cluster is created -- it can't be changed on a running cluster."
    Hint "Either this cluster predates the current pin, or it was created by an unpinned installer / with K8S_VERSION=latest (#547). To move"
    Hint "onto the validated version, recreate it:"
    Write-RecreateClusterHint
    Hint "  (data under HOST_DATA_DIR is kept; recreate rebinds it.)"
  }
}

# Reconcile the GPU decision against a REUSED cluster (Bugbot). The GPU gate in main
# enables --gpus=all + GPU chart values BEFORE New-K3dCluster runs, but a re-install
# reuses an existing cluster in place rather than recreating it. A cluster first built
# in CPU mode has a stock rancher/k3s node (no NVIDIA runtime, advertises 0 GPUs, no
# `nvidia` RuntimeClass) -- and the k3s node image is fixed at create time, so GPU
# can't be bolted onto a running node. Writing GPU values against it would strand every
# experiment Pending: exactly the #616 failure this PR removes. So when GPU was
# requested but the reused node isn't the CUDA image, DISABLE GPU for this run (CPU
# fallback stays safe) and tell the user to recreate the cluster to get GPU. Bounded
# docker inspect (installer rule) mirrors Test-K3sVersionDrift's job+deadline pattern.
# Pure: can a reused cluster's server-node image schedule GPU pods? The default GPU image
# name carries `k3s-cuda:`, BUT an operator can override it (TRACEBLOC_K3S_CUDA_IMAGE) to a
# renamed or digest-only mirror ref that doesn't -- so we ALSO accept an exact match against
# the image this run is configured to use ($Configured). A stock rancher/k3s image -- or an
# unreadable/empty one -- is not GPU-capable and must fail safe to CPU. Kept pure (strings in,
# bool out) so the decision is unit-testable without a background job.
function Test-NodeImageGpuCapable {
  param([string]$Image, [string]$Configured)
  if (-not $Image) { return $false }
  if ($Image -match 'k3s-cuda:') { return $true }
  if ($Configured -and ($Image -eq $Configured)) { return $true }
  return $false
}

function Confirm-ReusedClusterGpuCapable {
  # Read + write via $script: so the flag the top-level GPU gate set is the same one we
  # clear here (and that Install-ClientHelm later reads) regardless of call depth.
  if ($script:K3D_GPU_FLAG -eq "") { return }   # GPU not requested -> nothing to reconcile
  $img = ""
  $job = Start-Job -InitializationScript $JobInit -ScriptBlock {
    param($n) (docker inspect "k3d-$n-server-0" --format '{{.Config.Image}}' 2>$null | Out-String)
  } -ArgumentList $CLUSTER_NAME
  if (Wait-JobWithProgress -Job $job -TimeoutSec 15 -Message "Checking the existing cluster's GPU capability") {
    $img = (Receive-Job $job -ErrorAction SilentlyContinue | Out-String).Trim()
  } else {
    Log "docker inspect (GPU capability) timed out; treating the reused cluster as CPU-only to stay safe."
  }
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  # A CUDA node image (or the exact image this run is configured to use, for renamed/digest
  # mirror overrides) can schedule GPU pods; a stock or unreadable one fails safe to CPU
  # rather than stranding jobs Pending against a node that advertises 0 GPUs.
  if (Test-NodeImageGpuCapable -Image $img -Configured $K3S_CUDA_IMAGE) { return }
  $script:K3D_GPU_FLAG = ""
  $script:GPU_SKIP_REASON = "the existing '$CLUSTER_NAME' cluster runs a CPU-only node (GPU capability is fixed when the cluster is created); release it with 'tracebloc delete --keep-data', delete it (k3d cluster delete $CLUSTER_NAME) and re-run to rebuild it with GPU support"
  Warn "GPU detected, but the existing '$CLUSTER_NAME' cluster is CPU-only -- running CPU mode so jobs aren't stranded Pending."
  Hint "k3s node image (and thus GPU capability) is fixed when the cluster is created; it can't be added to a running cluster."
  Hint "To enable GPU on this machine, recreate the cluster:"
  Write-RecreateClusterHint
  Hint "  (data under HOST_DATA_DIR is kept; recreate rebinds it.)"
}

# Fast-path GPU consistency (Bugbot): the completed+healthy fast path exits BEFORE the GPU
# gate + cluster reconciliation, so a cluster whose values.yaml requests GPU while its node is
# CPU-only (a half-finished GPU attempt, or the k3s-CUDA image was removed) would keep every
# GPU experiment Pending while the control plane still looks healthy. Detect that mismatch and
# WARN with the recreate remedy -- non-fatal (the client is up), shared with the fast path so a
# healthy-but-inconsistent cluster is flagged, not silently exited. Bounded inspect.
# Fast-path helper: is the GPU actually LIVE on the running cluster -- i.e. does the node ADVERTISE
# nvidia.com/gpu? The node IMAGE being CUDA is NOT proof (the device plugin can fail, leaving a
# CUDA node with 0 GPUs -- the real failure mode), so we check allocatable GPU directly, the same
# authoritative signal Confirm-GpuNode uses (Bugbot). Lets the fast path fall through to retry GPU
# when a GPU is present but not live. Bounded via --request-timeout; unreadable/0 -> not live.
function Test-RunningClusterGpuCapable {
  $alloc = kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' --request-timeout=5s 2>$null
  return ("$alloc" -match '[1-9]\d*')
}

# Does the LIVE Helm release request a GPU (non-empty env.GPU_REQUESTS)? Read from Helm, not local
# values.yaml -- on the adopted-reuse path only clientId is healed locally (GPU is reconciled via
# helm --set-string), so the local file goes stale (Bugbot). Bounded; unreadable -> $false.
function Test-LiveReleaseRequestsGpu {
  $requested = $false
  $vjob = Start-Job -InitializationScript $JobInit -ScriptBlock {
    try {
      $releases = helm list -A -o json 2>$null | ConvertFrom-Json
      foreach ($r in $releases) {
        $v = helm get values $r.name -n $r.namespace -a -o json 2>$null | ConvertFrom-Json
        if ($v.env.GPU_REQUESTS) { return $true }
      }
    } catch {}
    return $false
  }
  if (Wait-JobWithProgress -Job $vjob -TimeoutSec 20 -Message "Checking the live GPU request") {
    $requested = [bool](Receive-Job $vjob -ErrorAction SilentlyContinue)
  }
  Remove-Job $vjob -Force -ErrorAction SilentlyContinue
  return $requested
}

function Test-HealthyClusterGpuConsistent {
  if (-not (Test-LiveReleaseRequestsGpu)) { return }   # live release doesn't request GPU -> nothing to reconcile
  $img = ""
  $job = Start-Job -InitializationScript $JobInit -ScriptBlock {
    param($n) (docker inspect "k3d-$n-server-0" --format '{{.Config.Image}}' 2>$null | Out-String)
  } -ArgumentList $CLUSTER_NAME
  if (Wait-JobWithProgress -Job $job -TimeoutSec 15 -Message "Checking GPU consistency") {
    $img = (Receive-Job $job -ErrorAction SilentlyContinue | Out-String).Trim()
  }
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  if (-not $img) { return }                                                    # couldn't read -> don't false-warn
  if (Test-NodeImageGpuCapable -Image $img -Configured $K3S_CUDA_IMAGE) { return }  # consistent (GPU node) -> fine
  Warn "This cluster's values request GPU but it runs a CPU-only node -- GPU experiments will stay Pending."
  Hint "GPU capability is fixed when the cluster is created; it can't be added to a running cluster."
  Hint "Recreate the cluster to fix (data under HOST_DATA_DIR is kept):"
  Write-RecreateClusterHint
}

# Build the sh -c body that pre-creates the chart's hostPath PV directories and
# makes them writable by the container user. Pure (string in, string out) so the
# quoting and the dir list are unit-testable without Docker or a cluster.
#
# Why this is needed at all. The chart's hostPath PVs bind /tracebloc/<release>/data
# and /tracebloc/<release>/logs (mounted in the pod as /data/shared and /data/logs).
# kubelet's DirectoryOrCreate creates a missing path as root:root 0755, and it
# IGNORES fsGroup on hostPath volumes (kubernetes#138411) -- so the container user
# (uid 1000) cannot create anything inside, and the very first `data ingest` dies
# with "mkdir: can't create directory '/data/shared/.tracebloc-staging/': Permission
# denied". The bash installer has always pre-created these (lib/cluster.sh
# _ensure_release_dirs); this script never did, which is why the failure was
# Windows-only.
#
# Scope: data + logs only -- the two the chart's own init-writable-data container
# targets. mysql's PV is deliberately left alone: it gets its own init container in
# the chart, its datadir permissions are the database's business, and installs
# reaching a healthy cluster prove it is already fine.
#
# The two dirs get DIFFERENT modes, mirroring the chart's init-writable-data (#667):
#
#   /data/shared -> 2777  setgid + world-write, NO sticky. Sticky permits an unlink only by
#                   the entry's owner, the dir's owner, or root; `data delete` removes a tree
#                   the INGEST wrote (uid 65534) from a pod running as 65532, so sticky here
#                   makes the delete impossible -- table dropped, files stranded. Setting 3777
#                   from the installer would re-create exactly the bug #667 removes, and on the
#                   currently-published chart (no init-writable-data) or the fast path that
#                   returns before Helm, nothing runs afterwards to correct it.
#   /data/logs   -> 3777  setgid + sticky. Nothing has to delete another writer's logs, so the
#                   /tmp-style protection costs nothing there.
#
# Keeping these in step with the chart is the point: the installer prepares the same dirs the
# chart's init container would, so the two must not disagree about the mode. Both the chown and the chmod are
# best-effort: on a bind-mounted host path that cannot represent POSIX ownership,
# the mkdir alone is often enough, and a failure to adjust must not abort anything.
# DataBase is the in-node root the chart binds DATA under. It is NOT always /tracebloc:
# with HOST_DATASET_DIR set, the installer writes hostPath.datasetPath: /tracebloc-data
# and tracebloc.clientDataHostPath (_helpers.tpl) resolves data to
# <datasetPath>/<release>/data on the dataset bind mount. Preparing /tracebloc/<release>/data
# in that setup would touch a path nothing mounts, while kubelet still created the REAL
# one root:root 0755 -- the bug would look fixed and not be. Logs always stay on the local
# /tracebloc tree (logs-pvc.yaml hardcodes it), which is why only data is parameterised.
# Bash splits the same way (lib/cluster.sh _ensure_release_dirs).
# The dirs this release needs prepared. Shared by the command builder and the caller that
# verifies the result, so "what we prepared" and "what we demand proof for" cannot drift.
# Modes the shared hostPath dirs must end up with. Kept as named constants so the installer
# and the chart's init-writable-data can be diffed against each other by eye (#667).
$TB_SHARED_DIR_MODE = "2777"   # setgid + world-write, NO sticky: `data delete` runs as another uid
$TB_LOGS_DIR_MODE   = "3777"   # setgid + sticky: nothing deletes another writer's logs

function Get-ReleaseDirsSpec {
  param(
    [Parameter(Mandatory)][string]$Release,
    [string]$DataBase = "/tracebloc"
  )
  return @(
    [pscustomobject]@{ Path = "$DataBase/$Release/data"; Mode = $TB_SHARED_DIR_MODE }
    [pscustomobject]@{ Path = "/tracebloc/$Release/logs"; Mode = $TB_LOGS_DIR_MODE }
  )
}

function Get-ReleaseDirsList {
  param(
    [Parameter(Mandatory)][string]$Release,
    [string]$DataBase = "/tracebloc"
  )
  return @((Get-ReleaseDirsSpec -Release $Release -DataBase $DataBase).Path)
}

# The copy-pasteable repair for a dir the installer could not fix itself. Built from the SAME
# spec as the prep, because a hint that names the wrong MODE is worse than no hint: `chmod -R
# 3777` on both dirs -- what this printed before -- puts the sticky bit back on /data/shared and
# breaks `data delete` across uids, so following the installer's own advice would leave delete
# broken while ingest looked fixed (Bugbot). No -R: the dir's own mode is what governs unlink,
# and recursing would stamp setgid/sticky onto every data FILE.
function Get-ReleaseDirsRepairHint {
  param(
    [Parameter(Mandatory)][string]$Release,
    [Parameter(Mandatory)][string]$Node,
    [string]$DataBase = "/tracebloc"
  )
  $parts = (Get-ReleaseDirsSpec -Release $Release -DataBase $DataBase | ForEach-Object {
    "chmod $($_.Mode) $($_.Path)"
  }) -join "; "
  return "  docker exec $Node sh -c `"$parts`""
}

function Get-ReleaseDirsPrepCommand {
  param(
    [Parameter(Mandatory)][string]$Release,
    [string]$DataBase = "/tracebloc"
  )
  # path:mode pairs, the same shape the chart's init-writable-data uses (#667), so the installer
  # and the chart cannot disagree about a dir's mode. Release names can't contain a colon (they
  # are k8s names), so ${e%:*} / ${e#*:} split cleanly.
  $dirs = ((Get-ReleaseDirsSpec -Release $Release -DataBase $DataBase | ForEach-Object {
    "$($_.Path):$($_.Mode)"
  }) -join " ")
  # Reports OK/FAIL per dir so the caller can tell the user something true rather
  # than assuming success. Writable = OTHER-writable, full stop.
  #
  # Ownership is deliberately not a pass condition. An earlier version also passed a
  # dir owned by uid 1000, which contradicts the whole reason this function exists:
  # the processes that must write here are the ingestion Job (uid 65534, or HOST_UID)
  # and the CLI staging pod (uid 65532), and they share no group with 1000. So a
  # chown that succeeds while the chmod fails leaves a 0755 dir that none of them can
  # write -- and the owner check would have called that OK, skipped the warning, and
  # left the first ingest to die on Permission denied. The uid is still printed, for
  # diagnosis only.
  #
  # Reads the mode with `ls -ldn`, NOT `stat -c`: -c is a GNU/coreutils flag that
  # BSD stat rejects, and the failure mode is silent -- stat writes nothing, the
  # mode string comes back empty, and a correctly-chmodded directory gets reported
  # FAIL. That would emit a scary "couldn't confirm" warning on a perfectly good
  # install. `ls -ldn` is POSIX and behaves the same on busybox (rancher/k3s), on
  # coreutils (the CUDA node image), and on BSD, so the same string parses
  # everywhere -- including in the test suite on a developer's Mac.
  #
  # In `ls -ldn` output the mode is field 1 and the numeric owner is field 3;
  # character 9 of the mode is the other-write bit ("drwxrwsrwt" -> 'w'), which the
  # ????????w* glob tests without arithmetic. A trailing sticky/setgid character is
  # absorbed by the *.
  return @"
for e in $dirs; do d=`${e%:*}; want=`${e#*:}; mkdir -p "`$d" 2>/dev/null; chown 1000:1000 "`$d" 2>/dev/null; chmod "`$want" "`$d" 2>/dev/null; set -- `$(ls -ldn "`$d" 2>/dev/null); m=`$1; o=`$3; case "`$m" in ????????w*) w=1;; *) w=0;; esac; if [ "`$w" = 1 ]; then echo "OK `$d `$o `$m"; else echo "FAIL `$d `$o `$m"; fi; done
"@.Trim()
}

# Which in-node root does the chart bind DATA under, for the cluster that exists right now?
#
# Ground truth is the node's mount table, not $HOST_DATASET_DIR: k3d bakes bind mounts in at
# cluster-create and cannot add or drop one on a running cluster, whereas the env var is not
# persisted in install state and is absent on any re-run that didn't re-export it. Deciding from
# the env var would prepare /tracebloc/<release>/data on such a re-run while the live release
# still mounts /tracebloc-data/<release>/data -- the silent-success shape this whole function is
# meant to remove.
#
# Degrades in order: node mount table -> the env var -> the local tree. A docker that can't be
# reached tells us nothing about the mounts, so it must not be read as "no dataset mount".
function Get-NodeDataBase {
  # DatasetDirHint defaults to the resolved $HOST_DATASET_DIR and exists so the fallback
  # branch is reachable from a test without reaching into script scope.
  param(
    [Parameter(Mandatory)][string]$Node,
    [string]$DatasetDirHint = $HOST_DATASET_DIR
  )
  $res = Invoke-DockerCli -DockerArgs @("inspect", $Node, "--format", "{{range .Mounts}}{{println .Destination}}{{end}}") -TimeoutSec 20
  if ($res.Code -eq 0 -and "$($res.Output)" -match '(?m)^/tracebloc-data\s*$') {
    return "/tracebloc-data"
  }
  if ($res.Code -ne 0) {
    # Couldn't read the mounts: fall back to the env var rather than assuming either layout.
    Log "Get-NodeDataBase: docker inspect failed (exit $($res.Code)); falling back to HOST_DATASET_DIR"
    if ($DatasetDirHint) { return "/tracebloc-data" }
  }
  return "/tracebloc"
}

# Make this release's hostPath PV dirs writable before Helm runs, so the first
# ingest can't fail on a permission the installer was in a position to fix.
#
# Complements Ensure-ReleaseDirs (#659), it does not duplicate it -- keep both.
# Ensure-ReleaseDirs creates the dirs from the WINDOWS side (New-Item), which is the
# only place that can create them before the bind mount exists but cannot set POSIX
# ownership or mode: Windows has no concept of either. This function fixes the half
# that matters once a container looks at them -- kubelet ignores fsGroup on hostPath
# (kubernetes#138411), so unless data/logs are world-writable IN-NODE, the ingestion
# Job (uid 65534) and the CLI's staging pod (uid 65532) cannot write to a tree the
# chart chowns to 1000. Creation without mode is not enough; mode without creation
# would race kubelet's DirectoryOrCreate. Deleting either one re-opens #653.
#
# Never fatal. A cluster that isn't k3d-shaped, a docker exec that times out, or a
# mount that refuses chown all end in a warning plus the exact command to run by
# hand -- the install itself still completes, and on a current chart
# init-writable-data fixes the same dirs at pod start anyway.
function Initialize-ReleaseDataDirs {
  param([Parameter(Mandatory)][string]$Release)
  if (-not $Release) { return }
  $node = "k3d-$CLUSTER_NAME-server-0"
  # Follow the chart: data moves to the dataset bind mount when one exists. Ask the NODE,
  # not $HOST_DATASET_DIR -- that env var is not persisted in install state, so a re-run or
  # a fast-path repair started without it would prepare /tracebloc/<rel>/data while the live
  # release still mounts /tracebloc-data/<rel>/data: successful-looking, fixing nothing
  # (Bugbot). The bind mount is baked in at cluster-create and cannot change on a running
  # cluster, so the node's own mount table is ground truth and survives a missing env var.
  # Falls back to the env var, then to the local tree, if docker can't be asked.
  $dataBase = Get-NodeDataBase -Node $node
  $cmd = Get-ReleaseDirsPrepCommand -Release $Release -DataBase $dataBase
  Log "Preparing hostPath dirs for release '$Release' in $node (data base $dataBase)"

  # The script goes in on STDIN, never as an argv token. Invoke-BoundedProcess joins
  # arguments into one command line and quotes any that contain whitespace WITHOUT
  # escaping inner quotes -- its contract is "callers pass space-free tokens". This
  # script has both spaces and embedded "$d", so as an argument Windows' command-line
  # parser would end the quoted string at the first inner quote and hand `sh` a
  # truncated script: the prep would silently do nothing and the Permission denied
  # this function exists to prevent would survive. Same failure family as the kubectl
  # patch that had to move to --patch-file. `sh` with no -c reads its program from
  # stdin, and every argv token here is space-free. Trailing newline so the last
  # command runs even on a shell that wants one.
  $res = Invoke-DockerCli -DockerArgs @("exec", "-i", $node, "sh") -Stdin ($cmd + "`n") -TimeoutSec 60
  $out = "$($res.Output)".Trim()
  Log "Release dir prep: exit=$($res.Code) out=$out"

  # Demand POSITIVE proof for every dir. Exit 0 with no "FAIL " line is not evidence the
  # script did anything: if the program never reaches `sh` -- stdin not attached, an empty
  # here-doc, a docker exec that starts and immediately ends -- sh exits 0 having printed
  # nothing, and treating that as success would skip the warning and leave the first ingest on
  # Permission denied while the install reports fine (Bugbot). That is the same fail-open shape
  # as the argv-quoting bug earlier in this PR, which is exactly why absence of failure cannot
  # stand in for success here.
  $expected = Get-ReleaseDirsList -Release $Release -DataBase $dataBase
  $unconfirmed = @($expected | Where-Object { $out -notmatch ("(?m)^OK " + [regex]::Escape($_) + "(\s|$)") })
  if ($unconfirmed.Count -gt 0) {
    Log "Release dir prep: no OK line for $($unconfirmed -join ', ')"
  }
  # Code 124 is Invoke-BoundedProcess's timeout; treat any non-zero the same way --
  # report, hint, continue.
  if ($res.Code -ne 0 -or $out -match "FAIL " -or $unconfirmed.Count -gt 0) {
    Warn "Couldn't confirm the data directories are writable for this release."
    Hint "Ingests can fail with 'Permission denied' on /data/shared until they are. Fix with:"
    Hint (Get-ReleaseDirsRepairHint -Release $Release -Node $node -DataBase $dataBase)
    return
  }
  Log "Release dirs writable for '$Release'"
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
        Write-RecreateClusterHint
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
        Write-RecreateClusterHint
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
        Write-RecreateClusterHint
        Err "Existing cluster is missing the dataset bind mount - refusing to install datasets onto ephemeral storage."
      }
    }

    # k3s version drift: a cluster born unpinned/old/latest keeps its k3s across
    # pinned re-runs (#547). Shared with the completed+healthy fast-path in main so
    # a healthy-but-drifted cluster is warned too (Bugbot #565).
    Test-K3sVersionDrift

    # GPU capability is baked into the node image at create time. If GPU was enabled
    # for this run but we're reusing a cluster whose node is stock CPU k3s, drop back
    # to CPU here (before the chart values are written) so we never request GPUs the
    # reused node can't provide -- which would strand every job Pending (Bugbot).
    Confirm-ReusedClusterGpuCapable
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
    # out to the platform, and every in-cluster Service is ClusterIP --
    # mysql-client, jobs-manager, requests-proxy-service and egress-proxy-service.
    # (This claimed "the only in-cluster Service (mysql-client)" until the chart
    # was counted: there are four, three explicitly `type: ClusterIP` and
    # mysql-client's by omission. The conclusion still holds -- not one is a
    # LoadBalancer and the chart renders no Ingress -- but the premise was wrong.)
    # Disable k3s components that exist solely to handle inbound traffic or
    # duplicate chart-provided resources.
    #
    # metrics-server is KEPT, and deliberately so -- do not add it here as a
    # footprint saving. client/templates/resource-monitor-daemonset.yaml `lookup`s
    # the v1beta1.metrics.k8s.io APIService and `fail`s the release without it,
    # which aborts the install and every later auto-upgrade tick. And if the API
    # disappears after install the failure is SILENT: resource_monitor.py builds
    # NodeUtilisation as the first statement of its poll loop, the loop handler
    # logs and sleeps 5 s, and the DaemonSet declares no probes -- so the pod
    # stays Running while node telemetry quietly stops. See the fuller note in
    # scripts/lib/cluster.sh's _create_new_cluster.
    #
    # Distinct from the RACE on the same APIService: Wait-MetricsApiService (#757)
    # waits out the window where k3s has not yet applied its bundled
    # metrics-server. That wait is non-fatal by design, so it does not rescue a
    # DISABLED metrics-server -- it would spend its whole METRICS_WAIT_TIMEOUT
    # budget and then hand the install to the chart's `fail`.
    #
    # local-storage is disabled UNCONDITIONALLY here, where cluster.sh gates it on
    # TB_STORAGE_MODE. That is correct only because Windows is hostpath-only:
    # node-local (RFC-0003 Option C) is the Linux/k3s default since the D15 flip
    # (client#456) but has no Windows path, the same reason Invoke-LeftoverDataGuard
    # above is hostpath-scoped -- and the same reason Assert-NodesSeeHostData runs
    # unconditionally at the end of New-K3dCluster, where the bash twin gates it on
    # TB_STORAGE_MODE (a node-local cluster has NO host mount, so probing one there
    # would refuse every install). If
    # you add a Windows node-local path, this flag has to become conditional too
    # or every dataset PVC stays Pending against a StorageClass that does not
    # exist. scripts/tests/k3s-components-agreement.sh trips the moment this file
    # USES that variable in code -- it reads the installer with comment lines
    # stripped, so naming it here to explain the rule does not fire it -- which
    # means the Windows node-local change cannot land quietly.
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

    # cgroup v1 hosts (backend#2422). Kubernetes 1.35 flipped the kubelet's
    # failCgroupV1 default to TRUE, so from k3s 1.35 the kubelet REFUSES TO START
    # on a cgroup v1 or hybrid host. WSL2 defaults to HYBRID cgroups, which makes
    # this the Windows path's problem specifically -- and k3s documents none of it,
    # so the operator would see only a bare upstream kubelet message. Set it
    # proactively; on a cgroup v2 host it is a no-op.
    #
    # GATED, and the gate is load-bearing: --fail-cgroupv1 was ADDED in kubelet
    # 1.31, so passing it to a pre-1.31 kubelet would be an unknown
    # flag and the kubelet would fail to start. Keep this in lockstep with the
    # bash twin in scripts/lib/cluster.sh.
    # NEVER cast an unvalidated string with [version] -- it THROWS, and this runs
    # BEFORE the `latest` branch below that exists to honour that value (#806
    # review, confirmed under pwsh). "" and "latest" are handled explicitly, the
    # same way Test-K3sVersionDrift and the GPU gate in this file already do; a
    # digest-only pin (:3105) is not dotted-numeric either, so the cast is guarded
    # by a shape check rather than a try/catch.
    #
    # `latest` DOES emit. It is the unsupported opt-out (#547) where k3d picks the
    # k3s version and we cannot read it, so the choice is between a flag that is
    # harmless from 1.31 and a refusal that is fatal from 1.35. k3d is pinned at
    # v5.9.0, whose default k3s is 1.32 -- above the flag's introduction, below the
    # refusal -- so emitting is safe today and correct the moment k3d's default
    # crosses 1.35. Empty stays skip: common.sh defaults K8S_VERSION to the pin, so
    # empty only occurs in tests.
    # `@all`, NOT `@server:*`: $AGENTS defaults to 1 and an agent runs a kubelet too
    # (#806 Bugbot, High). Scoping to the server leaves the agent kubelet refusing on
    # a cgroup v1 host -- WSL2's hybrid mode is exactly this path.
    $k8sSemver = ($K8S_VERSION -replace '^v', '') -replace '[-+].*$', ''
    if ($K8S_VERSION -eq "latest") {
      $k3dArgs += @("--k3s-arg", "--kubelet-arg=fail-cgroupv1=false@all")
    } elseif ($k8sSemver -match '^\d+\.\d+') {
      if ([version]$k8sSemver -ge [version]'1.31.0') {
        $k3dArgs += @("--k3s-arg", "--kubelet-arg=fail-cgroupv1=false@all")
      }
    }

    # --- kubelet config drop-in (backend#2634; mechanism shared with #2460) ---
    #
    # The bash twin's `_write_kubelet_config` in scripts/lib/cluster.sh carries the
    # full rationale; `scripts/tests/kubelet-config-agreement.sh` derives the three
    # values from BOTH files and fails the build if they diverge, so this is not a
    # second source of truth -- it is the second half of one, held together by a
    # guard in a required job.
    #
    # Short version: EvictionHard / KubeReserved / SystemReserved are maps the
    # kubelet replaces WHOLESALE, so they cannot travel as `--kubelet-arg` without
    # silently dropping k3s's disk thresholds. Image GC is scalar and would survive
    # the CLI, but belongs beside the eviction thresholds it interacts with. One
    # file, authored whole. Stock 85/80 leaves a 5-point band, which on a real disk
    # can be smaller than ONE 2.7-11 GB task image.
    $kubeletCfgDir  = Join-Path ([System.IO.Path]::GetTempPath()) ("tracebloc-kubelet-" + [System.Guid]::NewGuid().ToString('N').Substring(0,8))
    $kubeletCfgPath = Join-Path $kubeletCfgDir "kubelet.yaml"
    # HARD-FAIL, not a warning: a silent skip leaves the node on the stock 85%
    # threshold -- the unbounded image store #2634 is about -- while the install
    # reports success and nothing downstream can tell.
    try {
      New-Item -ItemType Directory -Path $kubeletCfgDir -Force | Out-Null
      # LF and no BOM: this file is read by the kubelet inside a Linux container.
      # Set-Content on Windows PowerShell would write CRLF and a UTF-8 BOM, and the
      # YAML parser rejects the BOM -- so the node would fail to start with a
      # message about the file, not about us.
      $kubeletYaml = @(
        "apiVersion: kubelet.config.k8s.io/v1beta1",
        "kind: KubeletConfiguration",
        "imageGCHighThresholdPercent: $TB_KUBELET_IMAGE_GC_HIGH_PERCENT",
        "imageGCLowThresholdPercent: $TB_KUBELET_IMAGE_GC_LOW_PERCENT",
        "imageMinimumGCAge: $TB_KUBELET_IMAGE_MIN_GC_AGE"
      ) -join "`n"
      [System.IO.File]::WriteAllText($kubeletCfgPath, $kubeletYaml + "`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {
      throw "Couldn't write the kubelet config to $kubeletCfgPath ($($_.Exception.Message)). Re-run; without it the node would keep the stock 85% image-GC threshold and fill up during training."
    }
    # `@all` for the same reason as the cgroupv1 arg above: an agent runs a kubelet
    # and pulls the same task images, so a server-only drop-in leaves it unbounded.
    $k3dArgs += @("-v", "${kubeletCfgPath}:${TB_KUBELET_CONFIG_NODE_PATH}@all")
    $k3dArgs += @("--k3s-arg", "--kubelet-arg=config=${TB_KUBELET_CONFIG_NODE_PATH}@all")

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
      # #616: a GPU-enabled cluster needs the custom k3s-CUDA node image (NVIDIA runtime +
      # nvidia runtime in CDI mode + the `nvidia` RuntimeClass baked in); a normal cluster uses
      # the stock k3s. Both are the SAME pinned
      # k3s ($K8S_VERSION) -- the CUDA image just rebuilds it on a GPU-capable base.
      if ($K3D_GPU_FLAG -ne "") {
        $k3dArgs += @("--image", $K3S_CUDA_IMAGE)
        Log "GPU node image: $K3S_CUDA_IMAGE"
      } else {
        $k3dArgs += @("--image", "rancher/k3s:$K8S_VERSION")
      }
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
    # Escape+escape-quote each arg per the exact CommandLineToArgvW rules (ConvertTo-Win32Arg,
    # backend#2545), NOT the naive wrap-if-it-has-a-space-or-`@`: -ArgumentList <one string> reaches
    # the child's command line verbatim like $psi.Arguments, so an arg with BOTH a space and a `"`
    # had its inner quotes silently consumed. `@` is not special to CommandLineToArgvW -- a bare
    # `-v host:node@all` needs no quoting and re-splits to the identical single token either way, so
    # dropping its quote branch is a no-op; the fix is escaping the quote the old branch ignored.
    $k3dArgString = ($k3dArgs | ForEach-Object { ConvertTo-Win32Arg $_ }) -join " "
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

    $k3dStdout = if (Test-Path $k3dOutLog) { Get-Content $k3dOutLog -Raw -ErrorAction SilentlyContinue } else { "" }
    $k3dStderr = if (Test-Path $k3dErrLog) { Get-Content $k3dErrLog -Raw -ErrorAction SilentlyContinue } else { "" }
    $k3dExitCode = $k3dProc.ExitCode
    # Defense-in-depth (#611): if the exit code is STILL unreadable after
    # WaitForExit (Wait-ProcessWithDeadline), do not fail a cluster that k3d itself
    # reported up -- trust its authoritative success marker over a null code. k3d
    # logs via logrus to STDERR, so its "Cluster created successfully!" line lands in
    # $k3dStderr, not $k3dStdout -- check BOTH streams or a real success is misread
    # as failure (Bugbot).
    if ($null -eq $k3dExitCode) {
      $k3dExitCode = if ("$k3dStdout`n$k3dStderr" -match 'created successfully') { 0 } else { 1 }
    }
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

  # Peer of cluster.sh::_merge_kubeconfig (client#732). This merge is load-bearing:
  # the installer passes no --kubeconfig/--context to `tracebloc client create`, so
  # the secure environment is registered against whatever context is CURRENT. The
  # old form piped the output to Out-Null and never looked at $LASTEXITCODE, so a
  # failed merge left the previous current-context selected and the install carried
  # on -- anchoring this machine to some other cluster (a corporate EKS, say).
  #
  # --kubeconfig-merge-default is required and was MISSING (Bugbot): without it k3d
  # writes a standalone ~/.k3d/kubeconfig-<cluster>.yaml and never touches the file
  # kubectl actually reads -- so a zero exit here proved nothing about the anchor,
  # and the remedy printed below couldn't have repaired it either.
  #
  # Bounded like the bash peer: k3d reads the kubeconfig out of the node through the
  # Docker daemon, so a wedged daemon would otherwise stall a headless install here
  # with no output at all.
  $mergeCmd = "k3d kubeconfig merge $CLUSTER_NAME --kubeconfig-merge-default --kubeconfig-switch-context"
  $merge = Invoke-BoundedProcess -FileName "k3d" -TimeoutSec 60 `
    -Arguments @("kubeconfig", "merge", $CLUSTER_NAME, "--kubeconfig-merge-default", "--kubeconfig-switch-context")
  if ($merge.Code -ne 0) {
    if ($merge.Code -eq 124) {
      Warn "Pointing kubectl at the '$CLUSTER_NAME' cluster timed out after 60s (k3d couldn't read the cluster's kubeconfig)."
      Hint "That usually means the Docker daemon is wedged -- check 'docker ps' answers, then re-run."
    } else {
      Warn "Couldn't point kubectl at the '$CLUSTER_NAME' cluster (k3d kubeconfig merge exited $($merge.Code))."
    }
    Hint "Stopping here on purpose: this machine's secure environment is registered against whichever"
    Hint "cluster kubectl currently points at, so continuing would connect it to the wrong cluster."
    Hint "Fix that (or merge it yourself with the command below), then re-run this installer:"
    Hint "  $mergeCmd"
    Err "kubectl was not pointed at '$CLUSTER_NAME' - refusing to continue against an unknown cluster." $merge.Output
  }
  if ($merge.Output) { Log "k3d kubeconfig merge: $($merge.Output)" }

  # Normalize the file k3d just wrote, not a guess at it: with --kubeconfig-merge-default
  # k3d honours $KUBECONFIG (first entry of the ';'-separated list) and only falls back to
  # %USERPROFILE%\.kube\config. Mirrors the bash peer's `${KUBECONFIG%%:*}`.
  $kubeConfigPath = if ($env:KUBECONFIG) { ($env:KUBECONFIG -split ';')[0] } else { "$env:USERPROFILE\.kube\config" }
  if (Test-Path $kubeConfigPath) {
    (Get-Content $kubeConfigPath) `
      -replace 'host\.docker\.internal', '127.0.0.1' `
      -replace 'https://0\.0\.0\.0:', 'https://127.0.0.1:' | Set-Content $kubeConfigPath -Encoding UTF8
  }

  # Confirm the ANCHOR rather than infer it from an exit code (peer of the bash
  # check). What everything downstream depends on is that kubectl's current context
  # IS this cluster; k3d v5 names the context it writes `k3d-<cluster>`. Fail closed:
  # a context we cannot read is not one we can vouch for. Bounded, like every other
  # kubectl call in this installer.
  $wantCtx = "k3d-$CLUSTER_NAME"
  $ctx = Invoke-BoundedProcess -FileName "kubectl" -Arguments @("config", "current-context") -TimeoutSec 10
  $haveCtx = Get-CurrentContextFromOutput -Output "$($ctx.Output)"
  if ($ctx.Code -ne 0 -or $haveCtx -ne $wantCtx) {
    if ($ctx.Code -ne 0) {
      Warn "k3d merged the '$CLUSTER_NAME' kubeconfig, but kubectl can't tell us which context is current."
    } else {
      Warn "k3d merged the '$CLUSTER_NAME' kubeconfig, but kubectl's current context is '$haveCtx', not '$wantCtx'."
    }
    Hint "This machine's secure environment is registered against the CURRENT context, so continuing"
    Hint "would connect it to that other cluster instead of the one this installer just prepared."
    Hint "Select this cluster, then re-run this installer:"
    Hint "  kubectl config use-context $wantCtx"
    Err "kubectl is not pointed at '$CLUSTER_NAME' - refusing to continue against an unknown cluster."
  }

  # Ensure THIS installer's own kubectl bypasses the proxy for the cluster API
  # (127.0.0.1) + in-cluster ranges (mirrors cluster.sh::_export_host_no_proxy).
  if ($env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:http_proxy -or $env:https_proxy) {
    $env:NO_PROXY = Get-EffectiveNoProxy
    $env:no_proxy = $env:NO_PROXY
  }

  Log "kubeconfig updated -- kubectl now points to '$CLUSTER_NAME'."

  Set-ClusterAutostart

  # Last thing cluster setup does, and the first point where the question can be
  # answered: the nodes are up and the bind mount (if any) is in effect, and it is
  # still before helm writes anything (backend#2422). Mirrors the bash twin, which
  # calls _verify_nodes_see_host_data at the end of its own cluster path -- NOT
  # from the helm install function, which is a different layer.
  Assert-NodesSeeHostData
}

# =============================================================================
#  GPU DEVICE PLUGIN AND VERIFICATION
# =============================================================================

# Advertise GPU capacity on the node WITHOUT the NVML device plugin (#616). Proven live on
# Docker Desktop/WSL2 (RTX 4050): the NVIDIA k8s device plugin CANNOT work there -- NVML returns
# ERROR_NOT_SUPPORTED through WSL2's paravirtualized GPU, so it registers 0 GPUs and (owning the
# nvidia.com/gpu extended resource) keeps the node at 0, stranding every job. But the GPU itself
# reaches pods fine via CDI (the node image generates a WSL CDI spec at boot). So we advertise
# nvidia.com/gpu as a node EXTENDED RESOURCE ourselves; pods then schedule against it and the
# nvidia runtime (CDI mode) injects the real GPU. Idempotent: re-patching the same value is a
# no-op, and a re-run re-asserts it (the value doesn't survive a node re-create). Bounded.
# Returns $true when the capacity is advertised. GPU is optional -> failure returns $false and
# the caller falls back to CPU.
function Set-NodeGpuCapacity {
  if ($GPU_VENDOR -ne "nvidia" -or -not $NVIDIA_DRIVER_OK -or $K3D_GPU_FLAG -eq "") { return $false }
  # One GPU per node: k3d maps the SAME host GPU into every node container, and GPU mode already
  # forces a single node (see the gate), so 1 is correct and never double-counts (Bugbot).
  $nodeName = "k3d-$CLUSTER_NAME-server-0"
  # Pass the JSON patch via --patch-file, NEVER as an inline -p argument. Windows PowerShell 5.1
  # does not preserve embedded double quotes when it builds a native command line, so
  # `-p '[{"op":...}]'` reaches kubectl as `[{op:...}]` -> "invalid character 'o'" and the patch
  # always fails (the real cause of "Couldn't advertise GPU capacity" on a live box; the same
  # command works by hand only when each quote is escaped as \"). A file sidesteps the shell
  # entirely. UTF8 WITHOUT BOM: a BOM makes kubectl's JSON parse fail.
  $patchFile = Join-Path $env:TEMP ("tb-gpu-capacity-" + [guid]::NewGuid().ToString('N') + ".json")
  $patchJson = '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"1"}]'
  Log "Advertising nvidia.com/gpu=1 on $nodeName (node extended resource; the NVML device plugin can't work on WSL2)"
  try {
    [System.IO.File]::WriteAllText($patchFile, $patchJson, (New-Object System.Text.UTF8Encoding($false)))
  } catch {
    Log "Couldn't stage the GPU capacity patch file: $($_.Exception.Message)"
    return $false
  }
  try {
    # Retry: right after cluster-create the API server / node object can still be settling, and a
    # 404 on the node here would drop an otherwise-working GPU to CPU for the whole run.
    for ($i = 1; $i -le 6; $i++) {
      $r = Invoke-BoundedProcess -FileName "kubectl" -Arguments @(
        "patch", "node", $nodeName, "--subresource=status", "--type=json",
        "--patch-file", $patchFile, "--request-timeout=15s") -TimeoutSec 30
      Log "kubectl patch node (gpu capacity, attempt ${i}): exit=$($r.Code) $($r.Output)"
      if ($r.Code -eq 0) { return $true }
      Start-Sleep -Seconds 5
    }
  } finally {
    Remove-Item $patchFile -Force -ErrorAction SilentlyContinue
  }
  Log "Advertising GPU capacity failed after retries"
  return $false
}

function Install-GpuDevicePlugin {
  # Returns $true when the GPU plugin is (believed) deployed, $false otherwise, so
  # the caller can skip Confirm-GpuNode's ~90s wait for a plugin never applied
  # (Bugbot). Every message helper uses Write-Host, so the only pipeline output is
  # the boolean below (the Invoke-WithRetry result is sunk to $null to be safe).
  if ($GPU_VENDOR -ne "nvidia" -or -not $NVIDIA_DRIVER_OK -or $K3D_GPU_FLAG -eq "") { return $false }

  # On Docker Desktop/WSL2 the NVML device plugin is a dead end (see Set-NodeGpuCapacity), and the
  # node image no longer ships it. Advertise the capacity ourselves instead; pods get the GPU via
  # the CDI spec the node generated at boot. Detected by /dev/dxg inside the node (bounded).
  $dxg = Invoke-DockerCli -DockerArgs @("exec", "k3d-$CLUSTER_NAME-server-0", "test", "-e", "/dev/dxg") -TimeoutSec 20
  if ($dxg.Code -eq 0) {
    Log "WSL2 GPU detected in the node (/dev/dxg) -- using CDI + node-advertised capacity instead of the NVML device plugin."
    # Verify the node's boot script actually produced the CDI spec before claiming GPU is
    # ready (Bugbot): the boot script guards every step with `|| true`, so a failed
    # `nvidia-ctk cdi generate` would otherwise leave us advertising a GPU that pods can't
    # use -- jobs would schedule and then fail CUDA with no cluster-level signal. -s also
    # rejects a zero-byte spec from a half-written generate.
    $spec = Invoke-DockerCli -DockerArgs @("exec", "k3d-$CLUSTER_NAME-server-0", "test", "-s", "/etc/cdi/nvidia.yaml") -TimeoutSec 20
    if ($spec.Code -ne 0) {
      $script:GPU_SKIP_REASON = "the node couldn't generate its WSL GPU (CDI) spec, so pods wouldn't be able to use the GPU -- running CPU-only (see the install log)"
      Log "CDI spec /etc/cdi/nvidia.yaml missing or empty in the node (exit $($spec.Code)): $($spec.Output)"
      Warn "GPU couldn't be wired into the cluster (CDI spec missing) - continuing in CPU mode."
      return $false
    }
    # A spec that EXISTS is not enough: it must also carry libdxcore.so. `nvidia-ctk cdi generate
    # --mode=wsl` omits that library, and without it libcuda loads but can't reach /dev/dxg, so
    # every GPU pod dies with the misleading "CUDA driver version is insufficient for CUDA runtime
    # version" -- while the node happily advertises a GPU. That exact silent miss happened on a
    # live box (the injection's anchor didn't match the generator's indentation), so verify the
    # OUTCOME here rather than trusting the node script.
    $dxc = Invoke-DockerCli -DockerArgs @("exec", "k3d-$CLUSTER_NAME-server-0", "grep", "-q", "libdxcore", "/etc/cdi/nvidia.yaml") -TimeoutSec 20
    if ($dxc.Code -ne 0) {
      $script:GPU_SKIP_REASON = "the node's WSL GPU (CDI) spec is missing libdxcore, so CUDA would fail inside pods with a misleading 'driver insufficient' error -- running CPU-only (see the install log)"
      Log "CDI spec is present but has no libdxcore mount (exit $($dxc.Code)): $($dxc.Output)"
      Warn "GPU couldn't be fully wired into the cluster (CDI spec incomplete) - continuing in CPU mode."
      return $false
    }
    # Remove a LEFTOVER NVML device plugin before advertising capacity ourselves (Bugbot, HIGH).
    # A device plugin OWNS the nvidia.com/gpu extended resource: on WSL2 it registers 0 GPUs and
    # re-reports that on every sync, overwriting our patch -- so a DaemonSet left behind by an
    # older install (or by a run where the /dev/dxg probe transiently missed and we took the
    # plugin path) would keep GPU permanently disabled, even across re-runs. Idempotent:
    # --ignore-not-found makes the normal "nothing there" case a clean no-op.
    $dpGone = Invoke-BoundedProcess -FileName "kubectl" -Arguments @(
      "delete", "daemonset", "-n", "kube-system", "nvidia-device-plugin-daemonset",
      "--ignore-not-found", "--request-timeout=20s") -TimeoutSec 30
    if ($dpGone.Code -eq 0) {
      if ($dpGone.Output -match 'deleted') { Log "Removed a leftover NVML device plugin (it would pin nvidia.com/gpu at 0 on WSL2): $($dpGone.Output)" }
    } else {
      # Not fatal on its own -- but say so, because it's the one thing that can silently
      # re-zero the capacity we're about to set.
      Log "Couldn't check/remove a leftover NVML device plugin (exit $($dpGone.Code)): $($dpGone.Output)"
    }

    if (Set-NodeGpuCapacity) {
      # Tell the chart to thread the CDI selector into GPU training pods; without it a pod
      # schedules but CUDA fails (client-runtime#291). Only set on this WSL2/CDI path.
      $script:GPU_DEVICE_SELECTOR = "nvidia.com/gpu=all"
      # Deliberately NOT an Ok/green line (Bugbot): the authoritative confirmation is
      # Confirm-GpuNode's "GPU verified and available", which runs next and can still clear
      # K3D_GPU_FLAG if the node never advertises the GPU. Claiming success here produced a
      # green "GPU acceleration enabled" immediately followed by a CPU fallback.
      Info "GPU wired up (WSL2/CDI) -- verifying the node advertises it..."
      return $true
    }
    # Set the reason HERE: this path never uses the device plugin, so letting the caller's
    # generic fallback fill in a device-plugin failure would name the wrong cause (Bugbot).
    $script:GPU_SKIP_REASON = "the installer couldn't advertise nvidia.com/gpu on the cluster node (this machine uses the WSL2/CDI path, where the installer advertises the GPU itself) -- re-run to retry"
    Warn "Couldn't advertise GPU capacity on the node - continuing in CPU mode. Re-run the installer later to retry."
    return $false
  }

  Log "Deploying NVIDIA k8s device plugin"

  # --request-timeout bounds the existence probe so a wedged API server can't hang
  # here before the bounded apply is reached (reviewer; parity with bash + verify).
  $dpExists = kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset --request-timeout=5s 2>&1
  if ($LASTEXITCODE -eq 0) {
    # Same rule as the CDI path: report what happened, don't claim GPU is enabled -- Confirm-GpuNode
    # runs next and can still clear K3D_GPU_FLAG if the node advertises 0 GPUs (Bugbot).
    Info "NVIDIA device plugin already present -- verifying the node advertises a GPU..."
    return $true
  } else {
    $dpUrl = "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml"
    $dpTmp = [System.IO.Path]::GetTempFileName()
    try {
      $null = Invoke-WithRetry -Label "GPU plugin download" -ScriptBlock {
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
        Info "NVIDIA device plugin deployed -- verifying the node advertises a GPU..."
      } else {
        Warn "Couldn't enable GPU acceleration - continuing in CPU mode. Re-run the installer later to retry."
      }
      return $gpuOk
    } catch {
      # GPU is OPTIONAL: a plugin download/apply failure must NOT abort the install
      # (#577 fatal-vs-recoverable) — otherwise the throw would reach the top-level
      # boundary and stop everything. Warn and continue in CPU mode.
      Warn "Couldn't enable GPU acceleration - continuing in CPU mode. Re-run the installer later to retry."
      Log "GPU device-plugin setup error: $($_.Exception.Message)"
      return $false
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
    # Target the GPU field DIRECTLY. `jsonpath='{...allocatable}'` on the whole map renders Go's
    # `map[nvidia.com/gpu:1 ...]` (no JSON quotes), so a regex expecting "nvidia.com/gpu":"1" NEVER
    # matched -> every healthy GPU read as 0 -> (with the 0-count fallback below) reverted ALL GPU
    # installs to CPU (Bugbot). Selecting the scalar field returns just its value ("1" or empty),
    # independent of map-vs-JSON rendering. The key's dot is escaped; the '/' is literal.
    $alloc = kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' --request-timeout=5s 2>$null
    if ("$alloc" -match '([1-9]\d*)') { $gpuCount = [int]$Matches[1]; break }
  }

  if ($gpuCount -gt 0) {
    Ok "GPU verified and available."
    Log "Allocatable GPU count: $gpuCount"
  } else {
    # The node advertises 0 nvidia.com/gpu after the wait. Leaving GPU requests active here would
    # strand every job Pending against a 0-GPU node, so make the node the AUTHORITATIVE signal:
    # disable GPU for this run (clear the flag BEFORE Install-ClientHelm writes values) -> CPU
    # fallback (Bugbot). The cluster stays GPU-capable; only this run's chart values go CPU.
    $script:K3D_GPU_FLAG = ""
    # The CAUSE differs per path, and pointing at the wrong one sends operators down a dead end
    # (Bugbot): on WSL2/CDI there IS no device plugin -- capacity comes from Set-NodeGpuCapacity --
    # so blaming a blocked nvcr.io device-plugin image would be actively misleading.
    if ($GPU_DEVICE_SELECTOR) {
      $script:GPU_SKIP_REASON = "the cluster node never advertised a GPU (this machine uses the WSL2/CDI path, where the installer advertises the GPU itself -- the node may still have been starting, or the capacity patch didn't take)"
      Warn "GPU didn't come up on the node -- running CPU-only so jobs aren't stranded Pending."
      Hint "Re-run the installer to retry; the node also re-asserts GPU capacity itself shortly after it starts."
    } else {
      $script:GPU_SKIP_REASON = "the cluster node never advertised a GPU (the NVIDIA device plugin didn't become ready -- on a mirror/air-gap network its image nvcr.io/nvidia/k8s-device-plugin may be blocked)"
      Warn "GPU didn't come up on the node -- running CPU-only so jobs aren't stranded Pending."
      Hint "If this is a restricted network, ensure the NVIDIA device-plugin image is reachable (mirror it), then re-run."
    }
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
# case, and a default Docker Desktop VM — nothing could ever schedule,
# backend#2254) and ~12% of a 64 GiB box. Precedence:
#   1. TRACEBLOC_TRAINING_RESOURCES (explicit install-time override)
#   2. the installed release's current value (a `tracebloc resources set` choice
#      must survive re-install, never be clobbered back to a default)
#   3. sized to this machine: LARGEST node allocatable - ~1 CPU / 3 GiB platform
#      overhead (a pod schedules onto ONE node; k3d's server+agent are the same
#      machine, so summing would double-count)
#   4. the contract FLOOR (tiny or undeterminable machines) — the fallback,
#      cpu=1,memory=2Gi, from the embedded floor constants. Was the 8Gi literal,
#      which exceeded a default Docker Desktop and sat Pending forever (#2254).
# Get-ImageMirrorYaml — top-level chart values that re-home every image the chart
# pulls onto a private registry mirror (#585 / restricted-network + air-gapped
# installs). Bash parity: lib/install-client-helm.sh::_image_mirror_yaml.
# TRACEBLOC_IMAGE_REGISTRY sets global.imageRegistry (the chart's convention that
# re-homes tracebloc/*, the spawned ingestor + training-job images, and the
# alpine/* + ubuntu/squid utility images). When the mirror needs auth,
# TRACEBLOC_REGISTRY_USERNAME / TRACEBLOC_REGISTRY_PASSWORD also mint the chart's
# imagePullSecret (dockerRegistry), whose server defaults to https://<mirror>.
# Returns "" when nothing is configured, so a default install's values are byte-
# identical. Pure (env in, string out) so it is unit-testable under Pester.
function Get-ImageMirrorYaml {
  $mirrorRaw = $env:TRACEBLOC_IMAGE_REGISTRY
  $regUser   = $env:TRACEBLOC_REGISTRY_USERNAME
  $regPass   = $env:TRACEBLOC_REGISTRY_PASSWORD
  if (-not ($mirrorRaw -or $regUser -or $regPass)) { return "" }

  $block = ""
  # global.imageRegistry is a BARE host (mirror.corp.example[:port]); strip a
  # pasted scheme so the image ref (<host>/repo) stays well-formed.
  $mirrorHost = $mirrorRaw -replace '^[a-zA-Z][a-zA-Z0-9+.\-]*://', ''
  if ($mirrorHost) {
    $mh = $mirrorHost -replace "'", "''"
    $block += "global:`n  imageRegistry: '$mh'`n"
  }
  if ($regUser -or $regPass) {
    # dockerRegistry.server is the imagePullSecret auths key and the chart schema
    # REQUIRES it whenever create is true (format:uri), so it must ALWAYS be
    # emitted. Precedence: an explicit TRACEBLOC_REGISTRY_SERVER wins; else derive
    # https://<mirror-host> when a mirror is set; else fall back to Docker Hub so
    # creds-only (authenticate to docker.io, no mirror) still renders a valid
    # secret instead of a schema error.
    $server = $env:TRACEBLOC_REGISTRY_SERVER
    if (-not $server) {
      if ($mirrorHost) { $server = "https://$mirrorHost" } else { $server = "https://index.docker.io/v1/" }
    }
    $userE  = $regUser -replace "'", "''"
    $passE  = $regPass -replace "'", "''"
    $emailE = ($env:TRACEBLOC_REGISTRY_EMAIL) -replace "'", "''"
    $srvE   = $server -replace "'", "''"
    $block += "`ndockerRegistry:`n  create: true`n"
    $block += "  server: '$srvE'`n"
    $block += "  username: '$userE'`n"
    $block += "  password: '$passE'`n"
    $block += "  email: '$emailE'`n"
  }
  return $block
}

# ── envelope contract (GENERATED — do not hand-edit) ─────────────────────────
#
# backend#2220 / RFC-BACKEND-664 §P0. The bash twin
# (lib/install-client-helm.sh::_machine_training_resources) carries the same
# five values, and cli's set.go used to carry them a third time. One source of
# truth now: client-runtime/envelope_contract.json, arithmetic in
# node_sizing.envelope_from_allocatable.
#
# Embedded rather than read: this bootstrap is SIGNED and must not fetch
# anything unsigned at install time, the same reason the GPU node-image build
# inputs are embedded as base64 here (#616/#633). The embed is kept honest by
# the drift guard, not by this comment — install-k8s.Tests.ps1 replays the
# contract's golden vectors through Get-TrainingResources, and
# scripts/gen-envelope-embed.sh --check verifies the constants in CI.
#
# Regenerate with: scripts/gen-envelope-embed.sh
$script:TbEnvelopeContractVersion  = 2
$script:TbEnvelopeOverheadCpuMilli = 1000
$script:TbEnvelopeOverheadMemBytes = 3221225472
$script:TbEnvelopeFloorCpuMilli    = 1000
$script:TbEnvelopeFloorMemBytes    = 2147483648
$script:TbEnvelopeVmReserveMemBytes = 1073741824
$script:TbEnvelopeNodeMinCpuMilli   = 2000
$script:TbEnvelopeNodeMinMemBytes   = 5368709120
# ── end generated ───────────────────────────────────────────────────────────

# Set by Get-TrainingResources when the machine is readable but below the
# training floor. The WARNING lives in the caller, so Get-TrainingResources keeps
# returning nothing but the size -- its Pester suite compares the whole return.
$script:TbTrainingUndersized    = $false
$script:TbTrainingUnschedulable = $false

# Who chose the training size Get-TrainingResources reports: installer | user |
# unknown (backend#2220). Bash twin: _resolve_training_size / _training_provenance.
#
# The marker exists because RESOURCE_* has no unset state once helm's
# --reset-then-reuse-values has seen it, so an installer-written value and a
# deliberate `tracebloc resources set` are indistinguishable once the value
# differs from the historic literal. Without it, a future ladder re-deriving
# sizes would silently overrule human choices.
#
# Deliberately mirrors Get-TrainingResources' precedence rather than calling it:
# these two answers come from the same branch decision, and the PowerShell
# bootstrap has no cheap way to return a pair. The Pester suite pins that the two
# functions agree on every branch, which is what keeps the mirror honest.
# ONE lookup of the installed release's carried training values, shared by
# Get-TrainingResources and Get-TrainingProvenance (backend#2220, review on #768).
#
# Returns @{ Size; Provenance } when the release carries a real operator choice,
# or $null when it does not -- including when the read FAILS. That $null is the
# whole point. The two resolvers used to perform their own separate
# `helm get values`, each wrapped in its own bare `catch {}`, so if the size read
# succeeded and carried a live RESOURCE_LIMITS while the provenance read then
# threw -- a wedged API, a ConvertFrom-Json hiccup, anything the catch eats --
# the generated values pinned that carried envelope as `installer`. A future
# ladder trusting that label would re-derive and overrule what may well have been
# a deliberate human choice.
#
# Sharing the lookup makes that structurally impossible: either it succeeds and
# both resolvers read the same carried pair, or it fails and NEITHER takes the
# carry path, so the size is machine-derived and `installer` is then the correct
# answer. Size and provenance can no longer disagree.
#
# This is also the shape the bash twin already had -- _training_provenance calls
# _resolve_training_size and reads $_TB_TRAINING_PROVENANCE -- so the two
# installers stop diverging by construction, which is the class client#766
# exists to remove. And it drops a redundant `helm get values` per install.
function Get-CarriedTrainingValues {
  if (-not $TB_NAMESPACE) { return $null }
  try {
    # helm get has no request timeout -- gate it behind a bounded probe so a
    # wedged API degrades instead of hanging values generation (Bugbot). A
    # missing namespace also means there is no release to carry.
    $null = (kubectl get namespace $TB_NAMESPACE --request-timeout=5s 2>$null) | Out-String
    if ($LASTEXITCODE -ne 0) { return $null }
    $valsJson = (helm get values $TB_NAMESPACE -n $TB_NAMESPACE -o json 2>$null) | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $valsJson.Trim()) { return $null }
    $vals = $valsJson | ConvertFrom-Json
    # READ RESOURCE_REQUESTS, FALL BACK TO RESOURCE_LIMITS (backend#2418, Bugbot
    # High on client#820). This read RESOURCE_LIMITS only, which was fine while
    # both fields held the same string. Since L0.2 the limits half is
    # memory-only, so reading it here breaks a REINSTALL two ways: the carried
    # "size" comes back as `memory=29Gi` and is written into RESOURCE_REQUESTS,
    # DROPPING the cpu request; and the historic-literal gate below no longer
    # matches, so the post-filter default is mistaken for a deliberate choice
    # and the machine is never re-sized. RESOURCE_REQUESTS still carries the
    # whole envelope; LIMITS stays the fallback for a release installed before
    # requests was written, or a chart-direct install that set only that key.
    $prev = $vals.env.RESOURCE_REQUESTS
    if (-not $prev) { $prev = $vals.env.RESOURCE_LIMITS }
    # The historic static default was the ABSENCE of a choice -- carrying it
    # would keep the unschedulable 8Gi on exactly the machines this sizing
    # exists to fix (Bugbot). Only a differing value survives re-install.
    # This is the FROZEN historic literal, NOT the current fallback: since
    # backend#2254 the fallback is the contract floor (cpu=1,memory=2Gi), which
    # a human may deliberately pin, so precedence rule 2 says it must survive and
    # the gate must not re-derive it. A field install predating #2254 still
    # carries the 8Gi literal; that is the non-choice this recognises. Bash twin:
    # _TRAINING_DEFAULT_HISTORIC in lib/install-client-helm.sh.
    if (-not $prev -or $prev -eq "cpu=2,memory=8Gi") { return $null }
    # A marker already on the release is authoritative -- preserve it, or a
    # re-install would quietly downgrade a `user` choice to `unknown`. Anything
    # unrecognised, including absent, is `unknown`: we genuinely cannot tell who
    # set it, and consumers treat `unknown` as `user`.
    $prevProv = $vals.env.RESOURCE_PROVENANCE
    $prov = if ($prevProv -eq "installer" -or $prevProv -eq "user") { $prevProv } else { "unknown" }
    return @{ Size = $prev; Provenance = $prov }
  } catch {
    # UNEXPECTED failure only. EXPECTED absence -- no namespace, no release, no
    # carried value -- returns $null through the explicit branches above and
    # never lands here; whatever does land here is a defect surfacing (a
    # ConvertFrom-Json choke, a shape change in helm's output). Degrading to
    # $null is still right -- a wedged read must not block values generation,
    # and a failed read means "carry nothing" so the machine gets re-sized --
    # but degrading SILENTLY is how client#766 and client#768 stayed invisible
    # (client#771). Log so the install log names the probe and the exception.
    Log "WARN: Get-CarriedTrainingValues: unexpected failure reading the installed release's training values; carrying nothing: $($_.Exception.Message)"
    return $null
  }
}

# Who chose the training size Get-TrainingResources reports: installer | user |
# unknown. Bash twin: _resolve_training_size / _training_provenance.
#
# Pass -Carried/-CarriedResolved to reuse a lookup the caller already did; with
# no arguments it does its own, so existing callers and tests are unaffected.
function Get-TrainingProvenance {
  param([hashtable]$Carried, [switch]$CarriedResolved)
  # 1. An explicit install-time override IS a human choice, same as the CLI's.
  if ($env:TRACEBLOC_TRAINING_RESOURCES) { return "user" }
  $c = if ($CarriedResolved) { $Carried } else { Get-CarriedTrainingValues }
  if ($c) { return $c.Provenance }
  # 2. Sized to this machine, or 3. the static default -- both are OUR choice.
  return "installer"
}

function Get-TrainingResources {
  param([hashtable]$Carried, [switch]$CarriedResolved)
  if ($env:TRACEBLOC_TRAINING_RESOURCES) { return $env:TRACEBLOC_TRAINING_RESOURCES }
  # The carry branch, via the ONE shared lookup (see Get-CarriedTrainingValues):
  # a failed read yields $null here, so we fall through to machine sizing and
  # Get-TrainingProvenance independently answers `installer` -- consistent by
  # construction rather than by two functions happening to agree.
  $c = if ($CarriedResolved) { $Carried } else { Get-CarriedTrainingValues }
  if ($c) { return $c.Size }
  try {
    # Bounded: a wedged API server must degrade to the static default, never
    # hang values generation (Bugbot). jsonpath extracts ONLY cpu/memory — no
    # full-JSON ConvertFrom-Json, mirroring the bash twin, so a parse hiccup on
    # unrelated node fields can never silently reinstate the static default
    # (Bugbot r5).
    # THREE fields per node since backend#2237: allocatable cpu, allocatable
    # memory, and .spec.unschedulable. The bash twin carries the same jsonpath in
    # lib/install-client-helm.sh::_TB_NODE_JSONPATH; the two are pinned to agree
    # by the shared cluster-state fixture, tests/fixtures/installer_parity.json.
    $lines = kubectl get nodes --request-timeout=10s -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{" "}{.status.allocatable.memory}{" "}{.spec.unschedulable}{"\n"}{end}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $lines) {
      $bestMemB = [long]0; $bestCpuM = [long]0; $seen = $false
      foreach ($ln in @($lines)) {
        $parts = "$ln".Trim() -split '\s+'
        if ($parts.Count -lt 2) { continue }
        $cpuRaw = $parts[0]
        $memRaw = $parts[1]
        # Cordoned nodes are SKIPPED, before any ranking (contract
        # skipped_nodes: "spec.unschedulable (cordoned)"). A cordoned node
        # accepts no new pods, so anchoring on one writes an envelope that
        # cannot schedule -- and on a heterogeneous cluster a cordoned LARGE
        # node wins the anchor outright, leaving every training pod Pending
        # with no obvious cause (backend#2237).
        #
        # Kubernetes declares Unschedulable with `omitempty`, so a schedulable
        # node emits an EMPTY third field and .Trim() drops it entirely --
        # hence Count -lt 3 is the normal case, and only the literal 'true'
        # means cordoned. Testing for 'true' rather than for non-emptiness is
        # what keeps a future explicit `unschedulable: false` from being read
        # as cordoned.
        if ($parts.Count -ge 3 -and $parts[2] -eq 'true') { continue }
        # $null, NOT 0, for a quantity we cannot parse. The contract's
        # skipped_nodes says unparseable allocatable is SKIPPED, and the bash
        # twin does exactly that with an explicit `|| continue`. Coercing to 0
        # and ranking the node anyway was a real bug the old memory-first order
        # happened to hide -- a memB of 0 could never win. Ranking cpu-first
        # exposes it: a node with a good core count and a memory unit we do not
        # speak would take the anchor, fail the memory floor, and drop the whole
        # machine to the literal while a sibling node was perfectly sizeable
        # (Bugbot #766).
        $cpuM = if ($cpuRaw -match '^(\d+)m$') { [long]$Matches[1] }
                elseif ($cpuRaw -match '^\d+$') { [long]$cpuRaw * 1000 }
                else { $null }
        $memB = if ($memRaw -match '^(\d+)Ki$') { [long]$Matches[1] * 1KB }
                elseif ($memRaw -match '^(\d+)Mi$') { [long]$Matches[1] * 1MB }
                elseif ($memRaw -match '^(\d+)Gi$') { [long]$Matches[1] * 1GB }
                elseif ($memRaw -match '^\d+$') { [long]$memRaw }
                else { $null }
        if ($null -eq $cpuM -or $null -eq $memB) { continue }
        # Contract ANCHOR_LARGEST, tie-break (cpu, memory). This used to rank
        # (memory, cpu) while cli's nodeLarger ranked (cpu, memory), so the two
        # anchored on DIFFERENT nodes on a heterogeneous cluster. One order now.
        # NOT a field no-op because clusters are single-node -- they are not
        # (backend#2221: SERVERS=1 AGENTS=1 is the default, so two nodes). It is
        # a no-op only because both k3d node containers report IDENTICAL
        # figures, each reporting the whole Docker VM -- the #2221 bug itself.
        if (-not $seen -or $cpuM -gt $bestCpuM -or ($cpuM -eq $bestCpuM -and $memB -gt $bestMemB)) {
          $bestMemB = $memB; $bestCpuM = $cpuM
        }
        $seen = $true
      }
      # No usable node: bestCpuM stays 0, so the floor check below fails and we
      # fall through to the single literal return at the end of the function --
      # deliberately NOT an early return with its own copy of that literal.
      # [long]0, not 0: a bare 0 binds [math]::Max's (Int32, Int32) overload and
      # then fails to convert a byte count over 2^31 ("Value was either too large
      # or too small for an Int32"). The enclosing `catch {}` swallows that into
      # a silent fall-through to the literal, so the machine sizing would just
      # quietly stop working on every box with more than ~2 GiB of headroom.
      $runCpuM = [long][math]::Max([long]0, $bestCpuM - $script:TbEnvelopeOverheadCpuMilli)
      $runMemB = [long][math]::Max([long]0, $bestMemB - $script:TbEnvelopeOverheadMemBytes)
      # Below the contract floor the machine is NOT VIABLE — fall through to the
      # fallback literal. That literal used to be the 8Gi default, a known bug on
      # such machines (backend#2220); since backend#2254 it is the contract floor,
      # which fits. The fallback structure is kept revertable — only its value
      # changed.
      if ($runCpuM -ge $script:TbEnvelopeFloorCpuMilli -and $runMemB -ge $script:TbEnvelopeFloorMemBytes) {
        return "cpu=$([math]::Floor($runCpuM / 1000)),memory=$([math]::Floor($runMemB / 1GB))Gi"
      }
      # Below the contract floor. This used to fall straight through to the
      # cpu=2,memory=8Gi literal, which on a ~4 GiB machine is LARGER THAN THE
      # MACHINE — so every training pod stayed Pending forever. And this
      # installer reaches exactly those machines: the memory preflight only WARNS
      # on Windows (it hard-fails on Linux), while its own note says a job's
      # limit is ~8 GiB+. So write the honest remainder when it is a requestable
      # shape: it FITS, so a run can be scheduled and fail for a reason instead
      # of hanging (backend#2220).
      #
      # $seen guards this: with no parseable node, bestCpuM is 0 and the
      # remainder is meaningless — that is the unreadable case, which keeps the
      # literal because we genuinely cannot do better.
      if ($seen) {
        $cores = [long][math]::Floor($runCpuM / 1000)
        $gib   = [long][math]::Floor($runMemB / 1GB)
        if ($cores -ge 1 -and $gib -ge 1) {
          $script:TbTrainingUndersized = $true
          return "cpu=$cores,memory=${gib}Gi"
        }
        # Not even a requestable shape (cpu=0 is not a training request), so
        # there is no honest number to write. Keep the fallback; the caller warns.
        $script:TbTrainingUnschedulable = $true
      }
    }
  } catch {
    # UNEXPECTED failure only. EXPECTED absence -- an unreachable API, no
    # nodes, unparseable quantities -- degrades through the non-throwing
    # branches above ($LASTEXITCODE gates, `continue` skips) and never lands
    # here. What does land here is a defect surfacing: this exact catch
    # swallowed the Int32 [math]::Max overload throw, so every machine with
    # more than ~2 GiB of headroom silently got the literal below and machine
    # sizing simply wasn't working, with no diagnostic anywhere (client#766).
    # The bounded fall-through to the static default is deliberate and stays --
    # a wedged probe must not hang values generation -- but it must leave a
    # trace (client#771). Log so support can tell degraded from sized.
    Log "WARN: Get-TrainingResources: unexpected failure while sizing to the cluster; falling back to the static default: $($_.Exception.Message)"
  }
  # The fallback envelope: the contract FLOOR, from the embedded floor constants
  # (mirrors _TRAINING_DEFAULT in lib/install-client-helm.sh). Was
  # cpu=2,memory=8Gi, which exceeded a default Docker Desktop and sat Pending
  # forever, so backend#2254 floored it. Rendered the same way as the sized
  # branch above so the two cannot drift.
  return "cpu=$([math]::Floor($script:TbEnvelopeFloorCpuMilli / 1000)),memory=$([math]::Floor($script:TbEnvelopeFloorMemBytes / 1GB))Gi"
}

# ── the VM beneath the node containers (backend#2221) ────────────────────────
#
# Get-TrainingResources above answers "how much may one run have, given a
# NODE". On a k3d install that premise is false: the node containers are
# created with `NanoCpus=0 CpuQuota=0 Memory=0`, so each one honestly reports
# the WHOLE Docker VM and the default topology (SERVERS=1 AGENTS=1) tells
# Kubernetes the machine is twice its size. Measured on k3d v5.9.0 / k3s
# v1.35.5 / Docker 29.5.2: a 7.75 GiB VM presented as 15.50 GiB, byte-exactly
# 2.000x, and two pods at this installer's OWN derived envelope
# (cpu=9,memory=4Gi) both went Running on a 10 cpu / 7.75 GiB machine.
#
# Two asymmetries decide the shape of the fix, and both are measured:
#
#   MEMORY IS CAPPABLE, AT CREATE TIME ONLY. `k3d --servers-memory/
#   --agents-memory` works by bind-mounting a SYNTHETIC /proc/meminfo into the
#   node container -- not via the cgroup, which kubelet never reads for
#   capacity. `docker update --memory` on a running node moves the cgroup and
#   leaves /proc/meminfo alone, so capacity does not budge even across a
#   restart: an existing cluster cannot be capped in place.
#
#   CPU IS NOT CAPPABLE AT ALL. k3d 5.9.0 has no CPU flag, and neither
#   `--cpus` (a CFS quota) nor `--cpuset-cpus` reaches kubelet, because cadvisor
#   counts /sys/devices/system/cpu/present and /proc/cpuinfo and no cgroup
#   namespaces either. So the only lever that makes cpu honest is FEWER NODE
#   CONTAINERS -- the remedy the GPU path already chose for --gpus=all.
#
# Returns "nodes=N,cap=BYTES,cpu_honest=0|1,viable=0|1", or $null when the VM is
# unreadable. $null means "I cannot answer" and a caller must not read it as one
# node: collapsing a cluster on a failed probe is worse than leaving the
# topology alone. A STRING rather than a hashtable so the bash twin and this one
# are compared byte-for-byte by the same fixture rows.
#
# The arithmetic is client-runtime/node_sizing.py::honest_topology, the
# constants are embedded above, and the vectors are replayed by
# install-k8s.Tests.ps1. -RequestedNodes below 1 is a caller bug, not a machine
# state: it returns $null rather than inventing a topology, matching the bash
# twin's non-zero exit with no output.
function Get-HonestTopology {
  param(
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$VmCpu,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$VmMemory,
    [Parameter(Mandatory=$true)][int]$RequestedNodes
  )
  if ($RequestedNodes -lt 1) { return $null }

  # Same unit spellings the bash twin accepts. [long] throughout: a byte count
  # over 2^31 must not touch an Int32 path -- the #2220 lesson, where a bare 0
  # bound [math]::Max's (Int32, Int32) overload and silently disabled machine
  # sizing on every box with more than ~2 GiB of headroom.
  $vmCpuM = if ($VmCpu -match '^(\d+)m$') { [long]$Matches[1] }
            elseif ($VmCpu -match '^\d+$') { [long]$VmCpu * 1000 }
            else { $null }
  $vmMemB = if ($VmMemory -match '^(\d+)Ki$') { [long]$Matches[1] * 1KB }
            elseif ($VmMemory -match '^(\d+)Mi$') { [long]$Matches[1] * 1MB }
            elseif ($VmMemory -match '^(\d+)Gi$') { [long]$Matches[1] * 1GB }
            elseif ($VmMemory -match '^\d+$') { [long]$VmMemory }
            else { $null }
  if ($null -eq $vmCpuM -or $null -eq $vmMemB) { return $null }

  # The VM cannot give the node containers everything it has: the k3d serverlb
  # and tools containers, dockerd/containerd and the guest page cache all live
  # outside them. Capping to the last byte starves the runtime that runs them.
  $usable = [long][math]::Max([long]0, $vmMemB - $script:TbEnvelopeVmReserveMemBytes)

  $fits = [long][math]::Floor($usable / $script:TbEnvelopeNodeMinMemBytes)
  $nodes = [long]$RequestedNodes
  if ($fits -lt $nodes) { $nodes = $fits }
  # Never zero: "no cluster at all" is not this function's call to make. The
  # caller refuses on viable=0.
  if ($nodes -lt 1) { $nodes = [long]1 }

  # Floored -- a cap that rounds UP is not a cap.
  $cap = [long][math]::Floor($usable / $nodes)

  # cpu_honest is measured, not chosen: no cap makes capacity.cpu true on more
  # than one node container.
  $cpuHonest = if ($nodes -eq 1) { 1 } else { 0 }

  # One honest node needs the platform overhead AND the training floor. Below
  # that the VM cannot host a run whatever it is capped to.
  $viable = if ($fits -ge 1 -and $vmCpuM -ge $script:TbEnvelopeNodeMinCpuMilli) { 1 } else { 0 }

  return "nodes=$nodes,cap=$cap,cpu_honest=$cpuHonest,viable=$viable"
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

# CLIENT_ENV reduced to the canonical dev|stg|prod (backend#1745).
#
# The PowerShell twin of common.sh::tb_client_env. values.schema.json documents
# development|staging|production as accepted aliases, and a switch that knows
# only dev|stg sends every one of them to the `default` (prod) branch.
#
# Not hypothetical: Get-BackendUrl feeds Test-Credentials, so a Windows install
# with CLIENT_ENV=staging validated the customer's STAGING credentials against
# PRODUCTION and told them their correct credentials were wrong.
#
# Unknown values pass through unchanged -- this normalises spellings, it does
# not validate -- so the default branch below still catches genuine garbage.
function Get-TraceblocClientEnv {
  param([string]$Value = "$env:CLIENT_ENV")
  switch ($Value) {
    "development" { return "dev"  }
    "staging"     { return "stg"  }
    "production"  { return "prod" }
    default       { return $Value }
  }
}

# Resolve the backend base URL the same way jobs-manager does
# (client-runtime/controller.py: CLIENT_ENV -> backend), defaulting to prod.
function Get-BackendUrl {
  # Quote the value so a truly-unset CLIENT_ENV ($null) coerces to "" and the
  # default (prod) branch reliably fires across PowerShell versions.
  switch ("$(Get-TraceblocClientEnv)") {
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

# Strip ANSI escape sequences (arrow keys, cursor moves, function keys),
# bracketed-paste markers, and C0 control characters from interactive input —
# they otherwise corrupt the name passed to `client create` into a garbage slug
# (mirrors common.sh's _strip_paste_garbage and cli/internal/cli/sanitize.go;
# customer-reported 2026-07-20 on the bash flow). Two shapes carry all of it:
#   CSI  ESC '[' <params in [0-9;]> <final in [A-Za-z~]>
#   SS3  ESC 'O' <final in [A-Za-z~]>   — ESC OA/OB/OC/OD, ESC OH/OF, ESC OP..OS
# SS3 is what the SAME keys emit in DECCKM application-cursor mode, the state
# vim/less/tmux leave behind on an unclean exit (cli#516) — the hole left by the
# CSI-only fix of 2026-07-21 (client#362 / cli#364). ESC is dropped as a control
# byte but 'O' and the final byte are printable, so ESC OD ESC OA survived as
# the plausible name "ODOA" and minted a permanent namespace, where CSI residue
# cleans to empty and re-prompts. UTF-8 letters survive (only < 0x20 and DEL are
# dropped). Change this, common.sh and sanitize.go together.
function ConvertTo-SanitizedInput {
  param([string]$Value)
  if (-not $Value) { return "" }
  $esc = [char]27
  $s = $Value -replace "$esc(\[[0-9;]*|O)[A-Za-z~]", ""
  $s = $s.Replace("[200~", "").Replace("[201~", "")
  # The floor. The strip above knows CSI, SS3 and the paste markers; it cannot
  # know the escape family nobody has reported yet — and that is exactly how SS3
  # got here, one rule hand-copied into three languages with only CSI ever
  # tested. So if an ESC SURVIVED the strip, this value carries a shape we do not
  # recognise and its printable bytes are not trustworthy content. Require one
  # alphanumeric that did not come from an escape final byte, probing with ESC +
  # intermediates + AT MOST TWO final-class bytes. Two, not one and not
  # unbounded: one leaves the 'D' of an unrecognised SS3-shaped pair behind and
  # the floor stops firing on the very shape this is about, while unbounded
  # swallows a whole ASCII name (ESC N C h e l l o) yet spares a non-Latin one,
  # making keep-vs-reject depend on the script the name is written in (Bugbot,
  # #736). An escape final is one byte, an intro plus a final is two, and every
  # keyboard-input escape family fits in that. The probe is a yes/no only — it is
  # never returned. Nothing but residue => return empty, which callers already
  # treat as "no answer" (re-prompt, or auto-name).
  if ($s.Contains($esc)) {
    $probe = $s -replace "$esc[^A-Za-z0-9~]*[A-Za-z~]{1,2}", ""
    if ($probe -notmatch '[\p{L}\p{Nd}]') { return "" }
  }
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

# The APIService the resource-monitor DaemonSet template `lookup`s at render time
# (client/templates/resource-monitor-daemonset.yaml). One constant, read by the
# wait below and asserted against the template by the suite, so a chart-side
# rename can't leave this installer politely waiting on a name nobody uses.
$script:MetricsApiServiceName = "v1beta1.metrics.k8s.io"

# Stamped from scripts/spec/facts.env by scripts/check-facts.sh -- do not hand-edit.
# bash waits for the same APIService behind the same TB_METRICS_WAIT_S knob (#553), so
# the two defaults are ONE fact: a value raised here and not there would make one
# documented knob mean two different things. CI gates the pair (#435).
$script:MetricsWaitTimeout = 120

# Get-MetricsWaitSeconds -- the metrics-wait budget, parsed in exactly one place
# so the poll loop and anything else that bounds it cannot disagree.
#
# TB_METRICS_WAIT_S is deliberately the SAME knob name the bash installer reads
# (lib/install-client-helm.sh::_wait_for_metrics_apiservice): one support
# instruction -- "set TB_METRICS_WAIT_S=300 and re-run" -- has to work on either
# host. It keeps the local knob shape (a TB_-prefixed, unit-suffixed integer
# validated with the same `-match '^\d+$'` idiom as TB_CREATE_TIMEOUT_MIN) but in
# seconds, because the budget is 120s and minutes cannot express it. The default
# is the facts.env fact above, not a second copy of the number.
#
# Anything that is not a plain non-negative integer -- empty, "abc", "-5", "12.5"
# -- falls back to the default rather than silently becoming 0 and disabling the
# wait. The digit cap is not cosmetic: `[int]` on a 20-digit string THROWS, and a
# typo'd knob must not take the install down.
function Get-MetricsWaitSeconds {
  param([string]$Value = $env:TB_METRICS_WAIT_S, [int]$Default = $script:MetricsWaitTimeout)
  if ("$Value" -match '^\d{1,6}$') { return [int]$Value }
  return $Default
}

# client#553, ported from lib/install-client-helm.sh::_wait_for_metrics_apiservice.
#
# On a freshly created k3d cluster, k3s applies its bundled metrics-server -- and
# the metrics.k8s.io APIService with it -- shortly AFTER the API server reports
# ready; `k3d cluster create --wait` gates on node/serverlb readiness, not on
# bundled addons. The resource-monitor DaemonSet template `lookup`s that
# APIService at RENDER time and calls `fail` when it is absent, which aborts the
# ENTIRE helm release, not just the DaemonSet. So helm must not render inside
# that window. Windows/WSL2 is the slowest host this installer supports and so
# the likeliest to land in it -- and it had no wait at all.
#
# Best-effort by construction: when the APIService never registers this returns
# $false and the caller carries on, so a genuinely missing metrics-server still
# reaches the chart's render-time guard and gets ITS actionable error (install
# metrics-server, or set resourceMonitor: false) instead of a vague stall here.
function Wait-MetricsApiService {
  param(
    # -1 = "not specified" -> take the budget from TB_METRICS_WAIT_S/the default.
    [int]$TimeoutSec = -1,
    [int]$IntervalSec = 3
  )
  if ($TimeoutSec -lt 0) { $TimeoutSec = Get-MetricsWaitSeconds }
  # A native command that isn't on PATH throws instead of setting $LASTEXITCODE,
  # so probe for it rather than polling an exception to the deadline. Not a
  # failure of the install: we simply cannot tell, and the chart still guards.
  if (-not (Has kubectl)) {
    Log "kubectl is not on PATH -- skipping the metrics API wait; the chart still guards at render time."
    return $false
  }
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $announced = $false
  while ((Get-Date) -lt $deadline) {
    $null = (kubectl get apiservice $script:MetricsApiServiceName --request-timeout=10s 2>$null) | Out-String
    if ($LASTEXITCODE -eq 0) {
      # Registered. Give it a moment to also report Available -- but never fail on
      # merely-slow: the template only needs the APIService to EXIST at render
      # time, so a non-zero here changes nothing about what happens next.
      $null = (kubectl wait --for=condition=Available "apiservice/$script:MetricsApiServiceName" --timeout=30s 2>$null) | Out-String
      Log "metrics.k8s.io APIService registered -- proceeding with helm install."
      return $true
    }
    # RFC-0002 §2, progress on every wait: bash runs this whole loop behind
    # spin_cmd_bounded. Announce ONCE, and only after a probe has actually missed,
    # so the common fast path (already registered) stays silent while the slow
    # WSL2 box this exists for is told why it is sitting here for two minutes.
    if (-not $announced) {
      Info "Waiting for the cluster metrics API to register..."
      $announced = $true
    }
    if ($IntervalSec -gt 0) { Start-Sleep -Seconds $IntervalSec }
  }
  Log "metrics.k8s.io APIService not registered after ${TimeoutSec}s -- proceeding; the chart guards if metrics-server is genuinely absent."
  return $false
}

# Get-ClientIdFromSecret — CLIENT_ID out of a release's chart-managed Secret, or
# "". THE SECOND PLACE THE ID CAN LIVE: backend#2571 lets clientId resolve from
# the Secret instead of release values, and the chart now recommends dropping it
# from values once it is there — so "no clientId in values" stopped meaning "not
# a client". Returns "" on any failure; the caller treats a client it cannot name
# as unidentifiable (fail closed), never as absent. Bash peer:
# _client_id_from_secret in scripts/lib/install-client-helm.sh.
function Get-ClientIdFromSecret {
  param([string]$Release, [string]$Namespace)
  if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { return "" }
  # BOUNDED, because this call is now on the COMMON path (Bugbot, #859). Once
  # clientId is dropped from release values — which this chart recommends — every
  # scanned release reaches here, so an unbounded read against a wedged API would
  # hang a headless install with no further output. kubectl's default is no
  # timeout at all; 5s matches this file's other existence probes. A timeout
  # exits non-zero and falls into the same `return ""` as any unreadable Secret,
  # which the caller turns into an unidentifiable client (fail closed), never an
  # absent one. Bash peer: _client_id_from_secret.
  $b64 = (kubectl -n $Namespace get secret "$Release-secrets" -o "jsonpath={.data.CLIENT_ID}" --request-timeout=5s 2>$null) | Out-String
  if ($LASTEXITCODE -ne 0) { return "" }
  $b64 = $b64.Trim()
  if (-not $b64) { return "" }
  try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)).Trim() } catch { return "" }
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
          # NO clientId IN VALUES IS NO LONGER "not a client" (backend#2571,
          # Bugbot #859). clientId stopped being `required` and the chart now
          # tells operators to drop it from release values once the Secret
          # carries it, so a live client legitimately has none here. Fall back
          # to the Secret; a client-chart release naming an id in NEITHER place
          # is a client we cannot NAME -> unidentifiable, so the guard fails
          # closed rather than waving through an install that re-points the
          # machine. Bash parity: detect_installed_client / _client_id_from_secret.
          $id = ""
          if ($null -ne $vals -and $null -ne $vals.clientId) { $id = "$($vals.clientId)".Trim() }
          if (-not $id) { $id = Get-ClientIdFromSecret -Release $rel.name -Namespace $rel.namespace }
          if ($id) { $existingId = $id; $existingNs = $rel.namespace; $existingName = $rel.name; break }
          # No trailing `continue` here. It is the last statement of the loop
          # body, so it buys nothing -- and PowerShell reported it escaping as an
          # unmatched loop label under Pester (pester/Pester#2669), which aborts
          # the run rather than failing one test. The two `continue`s above are
          # real: they skip the rest of the body.
          if (-not $unreadableNs) { $unreadableNs = $rel.namespace }
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
  Step 5 $script:INSTALL_STEPS.Count "Registering this machine" "d"
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

# The message the fallback branch refuses with when there is no terminal to ask
# for credentials (backend#2675). A PURE FUNCTION for the same reason the reboot
# decision became Read-RebootChoice: the call site ends in a throw (Err never
# returns), and asserting the message THROUGH a throwing mock turned out to bind
# differently on every Pester/PowerShell pairing the CI matrix runs -- three
# capture strategies, three version-specific failures. Returning the string lets
# the test read it directly, no mock involved. The pair it names is the one
# Get-ProvisioningPreset reads: the documented unattended contract.
function Get-UnattendedCredentialRefusal {
  return ("This machine is not registered yet and there is no terminal to ask for credentials.`n" +
          "  Run the installer in a terminal, or set both of these first for an unattended install:`n" +
          "    `$env:TRACEBLOC_CLIENT_ID='<client id>'`n" +
          "    `$env:TRACEBLOC_CLIENT_PASSWORD='<client password>'`n" +
          "  Find them at https://ai.tracebloc.io/clients")
}

function Install-ClientHelm {
  # -- Step 5/5: Install tracebloc client --
  Step 6 $script:INSTALL_STEPS.Count "Installing tracebloc client" "e"

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

      # NO TERMINAL -> REFUSE, DON'T SPIN (backend#2675) -- and FIRST, before the
      # "Use previous settings?" prompt below, which is itself a Read-Host that
      # would hang an unattended run on any machine that still holds a
      # values.yaml (Bugbot on the first placement, which sat after it). Every
      # prompt in this branch is unanswerable with nobody at the console, and
      # the credential loop further down is worse than a hang: it `continue`s on
      # an empty answer WITHOUT charging an attempt, printing "Client ID cannot
      # be empty." forever. Fail closed at the branch door, naming the two
      # variables that make this path unnecessary -- the same pair
      # Get-ProvisioningPreset reads, and the documented automation contract.
      if (-not (Test-CanPrompt)) { Err (Get-UnattendedCredentialRefusal) }

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

  # #616: decide the GPU chart values for THIS run BEFORE the adopted/fresh split, so BOTH paths
  # reconcile GPU the same way. Request a GPU for training jobs ONLY when the GPU was actually
  # wired into the cluster ($K3D_GPU_FLAG). Requesting nvidia.com/gpu while the node advertises 0
  # GPUs strands every job Pending -- so gate on the SAME condition that PROVISIONS the GPU, not
  # merely on detection. Empty gpuVal = no GPU request = CPU (the safe fallback).
  $gpuVal = ""
  $runtimeClass = ""
  if ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK -and $K3D_GPU_FLAG -ne "") {
    $gpuVal = "nvidia.com/gpu=1"
    # spawned training pods must run under the `nvidia` RuntimeClass (baked into the k3s-CUDA
    # image); jobs-manager threads RUNTIME_CLASS_NAME into every pod.
    $runtimeClass = "nvidia"
    Log "NVIDIA GPU enabled -- GPU_LIMITS/GPU_REQUESTS=nvidia.com/gpu=1, RUNTIME_CLASS_NAME=nvidia"
  } elseif ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK) {
    Log "NVIDIA GPU detected but NOT enabled in the cluster -- GPU_LIMITS/GPU_REQUESTS left empty (CPU mode)"
    if ($GPU_SKIP_REASON) { Warn ("GPU detected but not enabled -- running CPU-only: " + $GPU_SKIP_REASON) }
    else { Warn "GPU detected but not enabled -- running CPU-only (see the install log for details)." }
  } else {
    Log "No NVIDIA GPU -- GPU_LIMITS and GPU_REQUESTS left empty"
  }
  # CDI device selector rides the SAME gate as gpuVal: only meaningful when a GPU is actually
  # wired in, and only non-empty on the WSL2/CDI path ($GPU_DEVICE_SELECTOR). Empty everywhere
  # else so a device-plugin (Linux) node keeps owning NVIDIA_VISIBLE_DEVICES itself (#616).
  $gpuSelector = if ($gpuVal) { $GPU_DEVICE_SELECTOR } else { "" }
  if ($gpuSelector) { Log "GPU device selector for training pods: GPU_VISIBLE_DEVICES=$gpuSelector" }

  if (-not $adoptedReuse) {
  $passwordEscaped = $TB_CLIENT_PASSWORD -replace "'", "''"

  # Private registry mirror (#585): re-home every image the chart pulls onto a
  # private mirror for restricted-network / air-gapped installs. Bash parity:
  # lib/install-client-helm.sh::_image_mirror_yaml. TRACEBLOC_IMAGE_REGISTRY sets
  # global.imageRegistry (the chart's convention that re-homes tracebloc/*, the
  # spawned ingestor + training-job images, and the alpine/* + ubuntu/squid
  # utility images). When the mirror needs auth, TRACEBLOC_REGISTRY_USERNAME /
  # TRACEBLOC_REGISTRY_PASSWORD also mint the chart's imagePullSecret
  # (dockerRegistry). Empty when no mirror is configured, so default installs are
  # unchanged.
  # Private registry mirror (#585): re-home every image onto the mirror for
  # restricted-network / air-gapped installs. Empty when no mirror is configured.
  $imageMirrorBlock = Get-ImageMirrorYaml
  if ($env:TRACEBLOC_IMAGE_REGISTRY) {
    $mirrorHostLog = $env:TRACEBLOC_IMAGE_REGISTRY -replace '^[a-zA-Z][a-zA-Z0-9+.\-]*://', ''
    Log "Image registry mirror configured -- pulling all images from $mirrorHostLog."
  }
  if ($env:TRACEBLOC_REGISTRY_USERNAME -or $env:TRACEBLOC_REGISTRY_PASSWORD) {
    Log "Mirror credentials provided -- minting an imagePullSecret for the mirror."
  }

  # ($gpuVal / $runtimeClass were decided before the adopted/fresh split above.)
  Log "Writing values to $valuesFile"
  $envBlock = "env:`n"
  if ($CLIENT_ENV) {
    # Write the RESOLVED value, matching the bash installer: the chart
    # normalises too, but the two must not disagree about what was installed.
    $envBlock += "  CLIENT_ENV: $(Get-TraceblocClientEnv $CLIENT_ENV)`n"
  }
  # backend#743: relocate the dataset PV onto the network mount when HOST_DATASET_DIR is set.
  $datasetPathLine = if ($HOST_DATASET_DIR) { "`n  datasetPath: /tracebloc-data" } else { "" }
  # backend#1236 (option A): size the default training budget to this machine.
  # One lookup, both answers -- mirrors the bash twin's single _resolve_training_size
  # pass and removes the second `helm get values` per install (review on #768).
  $carried = Get-CarriedTrainingValues
  $trainingSize = Get-TrainingResources -Carried $carried -CarriedResolved
  $trainingProvenance = Get-TrainingProvenance -Carried $carried -CarriedResolved
  # Mirrors the bash twin's warning, and lives HERE for the same reason: the
  # sizing functions' returns are compared whole by their tests.
  if ($script:TbTrainingUndersized) {
    Warn "This machine is below the size a training run wants: $trainingSize is all that is left after the platform's reservation."
    Hint "The client will install and run, but training jobs may be killed for memory. ~16 GB of RAM is the recommendation for training locally."
  } elseif ($script:TbTrainingUnschedulable) {
    Warn "This machine is too small to host a training run at all; keeping the default $trainingSize."
    Hint "Training jobs will stay Pending until this edge has more memory -- the client itself will still run, ingest and report."
  }
  Log "Training size: $trainingSize"
  $envBlock += @"
  RESOURCE_LIMITS: "$(Get-TrainingLimits $trainingSize)"
  RESOURCE_REQUESTS: "$trainingSize"
  # Who chose the pair above (backend#2220). Bookkeeping only -- it never changes
  # the envelope. "unknown" means the value was carried forward from before this
  # key existed and is genuinely unattributable, so consumers treat it as "user".
  RESOURCE_PROVENANCE: "$trainingProvenance"
  GPU_LIMITS: "$gpuVal"
  GPU_REQUESTS: "$gpuVal"
  RUNTIME_CLASS_NAME: "$runtimeClass"
  GPU_VISIBLE_DEVICES: "$gpuSelector"

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
$imageMirrorBlock
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
  # Chart source: $env:TRACEBLOC_CHART_PATH points at a LOCAL chart directory for
  # dev/testing an unreleased chart (parity with the bash installer's
  # _resolve_chart_ref, lib/install-client-helm.sh) -- without it, Windows could only
  # ever install the published chart, so branch-only chart fixes were untestable here.
  # A local path skips `helm repo add` entirely; otherwise use the published repo.
  if ($env:TRACEBLOC_CHART_PATH) {
    if (-not (Test-Path -LiteralPath $env:TRACEBLOC_CHART_PATH -PathType Container)) {
      Err "TRACEBLOC_CHART_PATH is set but is not a directory: $($env:TRACEBLOC_CHART_PATH)"
    }
    $chartRef = $env:TRACEBLOC_CHART_PATH
    Info "Dev mode: installing the chart from local path $chartRef (skipping the Helm repo)."
    Log "Using local chart: $chartRef"
  } else {
    $chartRef = "$TRACEBLOC_HELM_REPO_NAME/$TRACEBLOC_CHART_NAME"
    Log "Adding Helm repo: $TRACEBLOC_HELM_REPO_URL"
    $addOutput = (helm repo add $TRACEBLOC_HELM_REPO_NAME $TRACEBLOC_HELM_REPO_URL --force-update 2>&1) | Out-String
    Log "helm repo add: $addOutput"
    if ($LASTEXITCODE -ne 0) { Err "Couldn't add the tracebloc chart repo ($TRACEBLOC_HELM_REPO_URL)." $addOutput }
  }

  # Pre-create this release's hostPath dirs BEFORE Helm, so kubelet never gets to
  # create them root:root 0755 and strand the first ingest on "Permission denied".
  # The release name is what the PV paths are keyed on (/tracebloc/<release>/...),
  # so it must match whichever release Helm is about to touch: the adopted one when
  # reconciling, otherwise the namespace-named release this script installs.
  # Two statements, not a one-line inline branch on $adoptedReuse alone: an existing
  # test locates the adopted helm-upgrade block by splitting this file on that exact
  # opening-brace form, so a second occurrence up here silently steals the split and
  # fails a test that has nothing to do with this change. Keep the compound
  # condition. It is also stricter -- an adopt with no resolved release name falls
  # back to the namespace instead of preparing /tracebloc//data.
  $pvRelease = $TB_NAMESPACE
  if ($adoptedReuse -and $existingName) { $pvRelease = $existingName }
  Initialize-ReleaseDataDirs -Release $pvRelease

  # client#553: wait out the metrics-server APIService registration race before
  # helm renders. Above BOTH helm paths on purpose -- the adopted reconcile
  # re-renders the chart too, so it hits the same render-time `fail`. The return
  # value is discarded deliberately: a wait that runs out must NOT stop the
  # install, because the chart's own guard is the thing that produces the
  # actionable error when metrics-server is genuinely absent.
  $null = Wait-MetricsApiService

  Write-Host ""
  if ($adoptedReuse) {
    # Surgical reconcile of the LIVE release: preserve the deployed configuration +
    # secret; only clientId is healed (#397 r2). Prefer --reset-then-reuse-values
    # (Helm >= 3.14: reset to chart defaults, then re-apply the user's overrides, so
    # NEW chart defaults reach adopted edges on auto-upgrade) over --reuse-values
    # (keeps only stored values, so new chart defaults never land); feature-detect via
    # --help and fall back on older Helm (bash parity: install-client-helm.sh).
    $reuseFlag = "--reuse-values"
    if ((helm upgrade --help 2>$null | Out-String) -match '--reset-then-reuse-values') {
      $reuseFlag = "--reset-then-reuse-values"
    }
    # Reconcile the GPU request to THIS run's decision even under --reuse-values (Bugbot): an
    # older release's GPU_REQUESTS/GPU_LIMITS would otherwise survive after cluster reconciliation
    # cleared $K3D_GPU_FLAG, stranding every job Pending on a CPU-only node. --set-string wins over
    # the reused values, so we force the three GPU keys to match $gpuVal/$runtimeClass (empty = CPU).
    Log "Reconciling release '$existingName' in namespace '$existingNs' (adopted; $reuseFlag; healing clientId + GPU request)..."
    Ensure-ReleaseDirs $existingName
    $helmOutput = (helm upgrade $existingName $chartRef `
      --namespace $existingNs `
      $reuseFlag `
      --set-string "clientId=$TB_CLIENT_ID" `
      --set-string "env.GPU_REQUESTS=$gpuVal" `
      --set-string "env.GPU_LIMITS=$gpuVal" `
      --set-string "env.RUNTIME_CLASS_NAME=$runtimeClass" `
      --set-string "env.GPU_VISIBLE_DEVICES=$gpuSelector" 2>&1) | Out-String
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
    Log "Installing $TB_NAMESPACE from $chartRef in namespace '$TB_NAMESPACE'..."
    Ensure-ReleaseDirs $TB_NAMESPACE
    $helmOutput = (helm upgrade --install $TB_NAMESPACE $chartRef `
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
  # PHASE `f` — connect (backend#2268). Without this the readiness wait was timed
  # inside `helm`, so a client that never became Ready classified as
  # `helm_install_failed` when helm had in fact succeeded — a fabricated helm
  # failure in exactly the rate this feature exists to produce, and the whole
  # `connect` phase invisible. The bash twin gets it from step_header f.
  # (@saqlainsyed007 on #782.)
  if (Get-Command -Name 'Start-TelemetryPhase' -CommandType Function -ErrorAction SilentlyContinue) {
    Start-TelemetryPhase -Letter 'f'
  }
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
  # #616: only claim "NVIDIA GPU" when the GPU was actually wired into the cluster
  # ($K3D_GPU_FLAG). A GPU detected but not enabled runs CPU-only, and the summary says so
  # (with the reason) rather than implying acceleration that isn't there.
  $mode = "CPU"
  if ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK -and $K3D_GPU_FLAG -ne "") { $mode = "NVIDIA GPU" }
  elseif ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK) { $mode = "CPU (GPU detected but not enabled)" }
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
      # A GPU that was DETECTED but not enabled is the case operators most need to act on, and
      # burying the cause inside the Mode line made it easy to miss and hard to read. Give it its
      # own block: what happened, and the one thing to do about it (#616).
      if ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK -and $K3D_GPU_FLAG -eq "") {
        Write-Host ""
        Write-Host "  " -NoNewline
        Write-Host "$([char]0x26A0)  GPU found but not enabled -- training will run on CPU." -ForegroundColor Yellow
        if ($GPU_SKIP_REASON) {
          Write-Host "     Why: $GPU_SKIP_REASON" -ForegroundColor Yellow
        } else {
          Write-Host "     Why: see the install log for details." -ForegroundColor Yellow
        }
        Write-Host "     Fix the item above, then re-run this installer to enable GPU." -ForegroundColor DarkGray
        Write-Host "     Full detail: $script:LOG_FILE" -ForegroundColor DarkGray
      }
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
  if ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK -and $K3D_GPU_FLAG -ne "") {
    # The smoke test MUST match how this cluster actually delivers the GPU, or an operator
    # testing a WORKING cluster sees a failure and concludes GPU is broken (Bugbot). Two
    # differences that matter: (a) pods only get the GPU under the `nvidia` RuntimeClass, so
    # --overrides is required; (b) on WSL2/CDI `nvidia-smi` inside a pod FAILS (NVML is not
    # supported through the paravirtualized GPU) even when CUDA compute works perfectly --
    # verified on real hardware -- so there we suggest a CUDA workload, not nvidia-smi.
    # (c) EVERY double quote in an --overrides JSON must be printed ESCAPED as \" : Windows
    # PowerShell strips unescaped quotes when building a native command line, so a copy-pasted
    # command dies with "error: Invalid JSON Patch". (Same class of bug that broke the capacity
    # patch itself -- verified on a live box.) A suggested command that can't be pasted is worse
    # than none, so the escapes are part of the guidance.
    Log ("  " + (Get-GpuSmokeTestCommand -Selector $GPU_DEVICE_SELECTOR))
  }
  Log "=== End Advanced Info ==="
}

# Build the GPU smoke-test command we print in the diagnostics bundle. PURE (selector in,
# string out) so a test can render it and assert the --overrides payload is VALID JSON --
# a scanner flagged a "stray brace" here (it was correct: the `}}}` closes limits, resources
# and the container in turn), and a genuine brace slip would hand operators a command that
# errors on a healthy cluster. Now it's machine-checked rather than eyeballed.
#
# Three properties the command must keep:
#   (a) runtimeClassName: nvidia -- pods only receive the GPU under it, so --overrides is
#       required (kubectl run has no flag for it);
#   (b) on WSL2/CDI suggest a CUDA workload, NOT nvidia-smi: NVML is unsupported through the
#       paravirtualized GPU, so nvidia-smi fails in a pod even when CUDA works (verified on
#       real hardware) -- suggesting it would make a working cluster look broken;
#   (c) every double quote ESCAPED as \" -- Windows PowerShell strips unescaped quotes when
#       building a native command line, so a pasted command would die with "Invalid JSON
#       Patch" (the same quoting class that broke the node capacity patch).
function Get-GpuSmokeTestCommand {
  param([string]$Selector)
  $q = '\"'
  if ($Selector) {
    return ('GPU test (WSL2/CDI -- runs CUDA; note nvidia-smi does NOT work in a pod here): ' +
      'kubectl run gpu-test --rm -it --restart=Never --image=nvidia/samples:vectoradd-cuda11.2.1 ' +
      "--overrides='{${q}spec${q}:{${q}runtimeClassName${q}:${q}nvidia${q},${q}containers${q}:" +
      "[{${q}name${q}:${q}gpu-test${q},${q}image${q}:${q}nvidia/samples:vectoradd-cuda11.2.1${q}," +
      "${q}env${q}:[{${q}name${q}:${q}NVIDIA_VISIBLE_DEVICES${q},${q}value${q}:${q}$Selector${q}}]," +
      "${q}resources${q}:{${q}limits${q}:{${q}nvidia.com/gpu${q}:${q}1${q}}}}]}}'")
  }
  return ('GPU test: kubectl run gpu-test --rm -it --restart=Never --image=nvidia/cuda:12.3.1-base-ubuntu22.04 ' +
    "--overrides='{${q}spec${q}:{${q}runtimeClassName${q}:${q}nvidia${q}}}' " +
    '--limits="nvidia.com/gpu=1" -- nvidia-smi')
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

# $true when a local TCP listener is bound to $Port, $false when the port is free,
# $null when we can't tell (Get-NetTCPConnection unavailable, e.g. non-Windows
# under Pester; or a genuine CIM/access probe error). Used by Test-Preflight's
# port-6550 conflict check (#557).
#
# Must NOT fail open: -ErrorAction SilentlyContinue swallowed real CIM/access
# errors into the same empty result as a free port, so a busy port we couldn't
# read green-OK'd (Bugbot). With -ErrorAction Stop every failure reaches the
# catch. Get-NetTCPConnection THROWS an ObjectNotFound error when no connection
# matches the filter -- that specific error is a genuine "port free" ($false);
# any OTHER error means we truly can't tell ($null), so a busy port is never
# green-OK'd on a swallowed error.
function Get-PfPortListening {
  param([int]$Port)
  if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return $null }
  try {
    $conns = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
    return ($conns.Count -gt 0)
  } catch {
    if ($_.CategoryInfo.Category -eq 'ObjectNotFound' -or
        $_.FullyQualifiedErrorId -match 'NotFound') { return $false }  # no listener -> port free
    return $null                                                        # real probe error -> unknown
  }
}

# ── Network profile (#582) ───────────────────────────────────────────────────
# A plain-language read of the network BEFORE the endpoint probes, so a user on a
# restricted/corporate network sees what's happening up front instead of a cryptic
# failure minutes in. Detects an explicit proxy, a configured corporate CA bundle,
# and (best-effort) TLS inspection. Never fatal, PII-free (proxy credentials are
# stripped and never printed/logged). One-to-one with preflight.sh's _pf_network_*.

# Strip scheme:// and any user:pass@ credentials from a proxy URL; return bare
# host:port. Credentials must NEVER reach the screen or log (#576).
function Get-EnvProxyHostPort {
  param([string]$Url)
  $u = $Url
  $u = $u -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', ''   # drop scheme://
  $u = $u -replace '^[^@/]*@', ''                       # drop user:pass@ (PII)
  $u = $u -replace '/.*$', ''                           # drop any /path
  return $u
}

# First explicit proxy from the environment as bare host:port (creds stripped), or
# $null when none is set. HTTPS takes precedence (our egress is all HTTPS).
function Get-EnvProxy {
  foreach ($name in @('HTTPS_PROXY','https_proxy','HTTP_PROXY','http_proxy')) {
    $val = [Environment]::GetEnvironmentVariable($name)
    if ($val) { return (Get-EnvProxyHostPort $val) }
  }
  return $null
}

# First explicit proxy from the environment VERBATIM (scheme + any user:pass intact),
# or $null. For the probe CONNECTION only — an authenticated proxy needs the
# credentials to answer the CONNECT, or it 407s and the inspection probe silently
# returns 'unknown' (Bugbot). NEVER print/log this; display uses Get-EnvProxy.
function Get-EnvProxyRaw {
  foreach ($name in @('HTTPS_PROXY','https_proxy','HTTP_PROXY','http_proxy')) {
    $val = [Environment]::GetEnvironmentVariable($name)
    if ($val) { return $val }
  }
  return $null
}

# Configured corporate CA bundle path when TRACEBLOC_CA_BUNDLE/CURL_CA_BUNDLE points
# at a readable file; $null otherwise. SOFT (never errors) — Resolve-CaBundle does
# the hard validation at cluster-create.
function Get-EnvCaBundle {
  foreach ($name in @('TRACEBLOC_CA_BUNDLE','CURL_CA_BUNDLE')) {
    $val = [Environment]::GetEnvironmentVariable($name)
    if ($val -and (Test-Path -LiteralPath $val -PathType Leaf)) { return $val }
  }
  return $null
}

# $true if an X.509 issuer string names a well-known PUBLIC CA (a normal direct
# chain); $false otherwise (a corporate re-signer — i.e. TLS inspection).
function Test-IssuerIsPublic {
  param([string]$Issuer)
  return ($Issuer -imatch "DigiCert|Sectigo|Comodo|Let'?s Encrypt|ISRG|Google Trust|GTS |GlobalSign|Amazon|Entrust|GeoTrust|Baltimore|USERTrust|Actalis|Buypass|SSL\.com|Certum|IdenTrust|Microsoft (Azure|RSA|ECC)")
}

# Best-effort affirmative TLS-inspection probe. Returns 'yes'|'no'|'unknown'. Reads
# the issuer of the cert served for a well-known public host (through the proxy when
# one is set); a non-public issuer means a corporate CA is re-signing TLS. Bounded
# (8s) and non-throwing; 'unknown' on any error.
function Get-TlsInspectionState {
  $prev = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
  $script:TbProbeIssuer = $null
  try {
    # Accept the cert for THIS probe only, capturing its issuer, so we can name the
    # inspection even when the corporate CA isn't trusted here.
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
      param($theSender, $cert, $chain, $errors)
      if ($cert) { $script:TbProbeIssuer = $cert.Issuer }
      return $true
    }
    $req = [System.Net.HttpWebRequest]::Create("https://github.com/")
    $req.Method = "HEAD"
    $req.Timeout = 8000
    $req.AllowAutoRedirect = $false
    # Connect THROUGH the proxy using the raw value: an authenticated proxy needs
    # its credentials on the CONNECT or it 407s and issuer capture fails → a false
    # 'unknown' on the exact TLS-inspecting networks this exists to detect (Bugbot).
    # Credentials go to the WebProxy only; display still uses the stripped Get-EnvProxy.
    $raw = Get-EnvProxyRaw
    if ($raw) {
      try {
        # [System.Uri] rejects schemeless curl-style values (proxy.corp:8080); prepend a
        # scheme so the probe matches the display path (which already strips schemeless
        # URLs) -- otherwise corporate proxies get a false 'unknown' (Bugbot, client#589).
        $rawUri = if ($raw -match '^[A-Za-z][A-Za-z0-9+.\-]*://') { $raw } else { "http://$raw" }
        $u  = [System.Uri]$rawUri
        $wp = New-Object System.Net.WebProxy(("{0}://{1}:{2}" -f $u.Scheme, $u.Host, $u.Port))
        if ($u.UserInfo) {
          $ui    = $u.UserInfo.Split(":", 2)
          $puser = [System.Uri]::UnescapeDataString($ui[0])
          $ppass = if ($ui.Count -gt 1) { [System.Uri]::UnescapeDataString($ui[1]) } else { "" }
          $wp.Credentials = New-Object System.Net.NetworkCredential($puser, $ppass)
        }
        $req.Proxy = $wp
      } catch { }
    }
    try { $resp = $req.GetResponse(); $resp.Close() } catch { }   # issuer captured in the callback regardless
    if (-not $script:TbProbeIssuer) { return "unknown" }
    if (Test-IssuerIsPublic $script:TbProbeIssuer) { return "no" } else { return "yes" }
  } catch {
    return "unknown"
  } finally {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prev
    $script:TbProbeIssuer = $null
  }
}

# Print the plain-language network profile line (only when noteworthy — a plain
# direct connection stays silent; the reachability lines already confirm egress).
# Sets $script:NetProxy / $script:NetCa / $script:NetInspect for reuse.
function Show-NetworkProfile {
  $script:NetProxy   = Get-EnvProxy
  $script:NetCa      = Get-EnvCaBundle
  $script:NetInspect = Get-TlsInspectionState

  if (-not $script:NetProxy -and $script:NetInspect -ne "yes") { return }

  $parts = @()
  if ($script:NetProxy)             { $parts += "corporate proxy detected ($script:NetProxy)" }
  if ($script:NetInspect -eq "yes") { $parts += "TLS inspection detected" }
  if ($script:NetCa)                { $parts += "your company's certificate is configured" }
  Info ("Network: " + ($parts -join "; ") + ".")
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

  # API port 6550 (#557): New-K3dCluster binds the cluster's API server to
  # 127.0.0.1:6550. If that port is already bound by something else — a
  # leftover/other k3d cluster, or an unrelated service — `k3d cluster create`
  # fails and the installer surfaces k3d's raw stderr instead of a clear cause.
  # Catch it here with an actionable message. A port bound by OUR OWN
  # already-RUNNING cluster is fine (that run reuses it), so a busy port only
  # hard-fails when the listener is NOT this installer's running cluster.
  $portBusy = Get-PfPortListening 6550
  if ($null -eq $portBusy)      { Info "API port 6550: couldn't determine listener state (skipping)." }
  elseif (-not $portBusy)       { Ok "API port 6550 free" }
  else {
    # Ownership is TRI-STATE, via the bounded Get-ClusterRunState helper, so we
    # only HARD-FAIL when CONFIDENT the listener is not ours (#557 Bugbot Med
    # 3728340365):
    #  - It wraps `k3d cluster list` in the same ~15s job deadline used
    #    elsewhere, so a wedged Docker engine can't hang preflight here.
    #  - 'running' (serversRunning >= 1) -> our cluster owns 6550 -> reuse.
    #  - 'down' -> we enumerated clusters and ours is absent/STOPPED (a stopped
    #    cluster doesn't bind 6550), so the listener is confidently foreign ->
    #    hard fail (Bugbot Med, #557). No k3d installed at all is likewise a
    #    confident "not ours".
    #  - 'unknown' -> the list timed out / was unreadable: "can't tell", NOT
    #    "foreign". A slow Docker on a normal re-run must not be blocked with
    #    stop/delete hints, so downgrade to a warning and proceed; New-K3dCluster
    #    starts/repairs the existing cluster (or surfaces a real conflict) itself.
    $state = if (Has "k3d") { Get-ClusterRunState } else { 'down' }
    if ($state -eq 'running') {
      Ok "API port 6550 in use by the existing tracebloc cluster (will be reused)"
    } elseif ($state -eq 'unknown') {
      Warn "API port 6550 is in use but the cluster's run-state couldn't be determined ('k3d cluster list' timed out or was unreadable) - proceeding; New-K3dCluster will start/repair the existing cluster or surface a genuine conflict."
    } else {
      Write-PfFail "API port 6550 is already in use by another process or cluster - k3d needs it for the tracebloc cluster's API server."
      $hardFail++
      Hint "Find and stop whatever is listening on 6550, then re-run:"
      Hint "  Get-NetTCPConnection -LocalPort 6550 -State Listen | Select-Object OwningProcess"
      Hint "  then: Get-Process -Id <pid> to identify it and stop it - or 'k3d cluster delete <name>' if it's a leftover k3d cluster."
    }
  }

  Show-NetworkProfile   # #582: announce the network profile before the probes
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
  # GPU download chain (#616): whichever way we obtain the GPU node image, probe its hosts here
  # so a restricted network is flagged BEFORE a green check, not after (Bugbot). All SOFT (warn,
  # not $hardFail): GPU is optional and degrades to CPU, so a block here must not stop a
  # CPU-capable install -- it just warns that GPU will fall back.
  if ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK) {
    # nvcr.io is part of the GPU download chain on BOTH paths: the CUDA base the node image is
    # built from comes from there, and on a device-plugin (Linux) node so does the plugin image.
    # (This node image no longer BAKES the plugin -- WSL2 uses CDI -- but the host still needs
    # nvcr.io to build/pull the node image, so probe it whenever GPU is enabled.) Bugbot.
    # gpuBlocking marks the hosts this path ACTUALLY needs. Only those may skip GPU setup: on a
    # mirror/air-gap install nvcr.io is blocked BY DESIGN (images come from the mirror), so
    # treating every soft GPU probe as blocking disabled GPU for exactly the case the mirror
    # exists to serve -- and told the operator to configure the mirror they had configured
    # (Bugbot). nvcr.io stays probed on the mirror path, but warn-only.
    $nvcrBlocking = -not ($env:TRACEBLOC_K3S_CUDA_IMAGE -or $env:TRACEBLOC_IMAGE_REGISTRY)
    $criticals += @{ label = "NVIDIA device plugin / CUDA (nvcr.io)"; url = "https://nvcr.io/"; gpuSoft = $true; gpuBlocking = $nvcrBlocking }
    if (-not ($env:TRACEBLOC_K3S_CUDA_IMAGE -or $env:TRACEBLOC_IMAGE_REGISTRY)) {
      # DEFAULT: we BUILD locally, which also fetches the toolkit apt repo (nvidia.github.io); the
      # probe's nvidia/cuda comes from Docker Hub, already probed above.
      $criticals += @{ label = "NVIDIA toolkit repo (nvidia.github.io)"; url = "https://nvidia.github.io/"; gpuSoft = $true; gpuBlocking = $true }
    } else {
      # PREBUILT/MIRROR: we PULL the node image ($K3S_CUDA_IMAGE) AND the probe's CUDA image
      # ($CUDA_PROBE_IMAGE) -- which can be on DIFFERENT hosts when both overrides are set. Probe
      # EVERY distinct real registry host so an unreachable one is surfaced at preflight (Bugbot).
      $gpuHosts = @((Get-RegistryHost $K3S_CUDA_IMAGE), (Get-RegistryHost $CUDA_PROBE_IMAGE)) | Select-Object -Unique
      foreach ($gpuHost in $gpuHosts) {
        # Skip bare Docker Hub (already covered by the registry-1.docker.io probe) and nvcr.io
        # (added above). Only probe a real registry host.
        if ($gpuHost -match '[.:]' -and $gpuHost -ne 'docker.io' -and $gpuHost -ne 'nvcr.io') {
          # The mirror/custom registry IS required on this path, so a failure here does block.
          $criticals += @{ label = "GPU image registry ($gpuHost)"; url = "https://$gpuHost/"; gpuSoft = $true; gpuBlocking = $true }
        }
      }
    }
  }
  $tlsSeen = $false; $cfail = 0; $regBlocked = $false
  foreach ($c in $criticals) {
    $status = Test-PfUrl $c.url -RequireSuccess:([bool]$c.strict)
    if ($status -ne "ok") { $status = Test-PfUrl $c.url -RequireSuccess:([bool]$c.strict) }   # one retry for transient blips
    if ($status -eq "ok") { Ok "$($c.label) reachable" }
    elseif ($c.gpuSoft) {
      # GPU build host blocked: warn only. GPU is optional and degrades to CPU, so this must
      # not hard-fail an otherwise-fine CPU-capable install (#616).
      # Remember it ONLY if this path actually needs the host: the GPU gate then skips the
      # probe/build/pull instead of spending ~3-15 minutes timing out on hosts we already know
      # are unreachable, which made a re-run (the very thing our CPU-fallback advice tells
      # operators to do) look hung. A non-required host (e.g. nvcr.io on a mirror install) warns
      # and nothing more -- otherwise we would disable GPU on air-gapped mirrors (Bugbot).
      if ($c.gpuBlocking) { $script:GPU_HOSTS_UNREACHABLE = "$($c.label) is unreachable from this machine" }

      # Wording must match the path actually in use (Bugbot): on the pull/mirror path nothing is
      # built locally, so "can't be built" named the wrong failure.
      if ($env:TRACEBLOC_K3S_CUDA_IMAGE -or $env:TRACEBLOC_IMAGE_REGISTRY) {
        Warn "$($c.label) unreachable ($status) -- the GPU node image can't be pulled here, so the install will run CPU-only."
      } else {
        Warn "$($c.label) unreachable ($status) -- the GPU node image can't be built here, so the install will run CPU-only."
      }
    }
    else {
      Write-PfFail "$($c.label) unreachable ($status)"
      $hardFail++; $cfail++
      if ($status -eq "tls") { $tlsSeen = $true }
      # #585: was it a CONTAINER REGISTRY that's blocked (images can't be pulled)?
      if ($c.url -match 'registry-1\.docker\.io|auth\.docker\.io|ghcr\.io') { $regBlocked = $true }
    }
  }
  if ($tlsSeen)    {
    Hint "A TLS/certificate error usually means a break-and-inspect (TLS-inspecting) proxy whose corporate CA isn't trusted here."
    Hint "Fix THESE host checks by importing the CA into the Windows certificate store (Cert:\LocalMachine\Root) - Invoke-WebRequest uses the system store, not an env var. The k3d nodes are trusted separately via `$env:TRACEBLOC_CA_BUNDLE='C:\path\to\corporate-ca.pem' (CURL_CA_BUNDLE also honored) at cluster-create. Ask IT for the bundle if unsure."
  }
  if ($cfail -gt 0){ Hint "Allow HTTPS (443) egress to the host(s) named above - the always-needed set is registry-1.docker.io, auth.docker.io, ghcr.io, $backendHost, tracebloc.github.io, plus any tool-download host listed (desktop.docker.com / dl.k8s.io / get.helm.sh / github.com / objects.githubusercontent.com) - or configure your corporate proxy." }
  # #585: when the CONTAINER REGISTRIES themselves are blocked, images can't be pulled
  # directly at all - surface the mirror / offline options in plain language.
  if ($regBlocked) { Hint "The container registries (Docker Hub / GHCR) look blocked here, so the images can't be pulled directly. If your site runs a mirror you CAN reach, point the install at it; for a fully offline site, an air-gapped image bundle is the alternative. See the 'Blocked container registry' section of docs/INSTALL.md." }

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
    # -Encoding UTF8 so the read matches how these files were written. The curated
    # install log is now UTF-8 WITHOUT a BOM (Start-InstallLog), and on PS 5.1 a
    # bare Get-Content -Raw would decode a BOM-less file as ANSI and mojibake every
    # non-ASCII host path/message in the -Diagnose bundle -- the exact corruption
    # this change set out to fix (Bugbot, #591). UTF8 also reads the BOM'd Out-File
    # outputs here correctly (the BOM is detected and stripped).
    $t = Get-Content -Path $Path -Raw -Encoding UTF8 -ErrorAction Stop
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
  Step 4 $script:INSTALL_STEPS.Count "Install the tracebloc CLI" "b"

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
# Sets TbExitCode for the same reason Err does: this is the last-resort net for a
# terminating error OUTSIDE the try, and without it those crashes reported
# `succeeded` too (@saqlainsyed007 on #782).
trap { Show-FatalError $_; $script:TbExitCode = 1; exit 1 }
try {

if ($Help) { $script:OutcomeReported = $true; Print-Help }
if ($Diagnose) { Invoke-DiagnoseBundle; $script:OutcomeReported = $true; exit 0 }  # flag AFTER the long collection: an interrupt mid-diagnose must still hit Show-Interrupted (Bugbot)

# THE RUN-STARTED LATCH (backend#2268). AFTER the terminal flags have dispatched
# and BEFORE Confirm-Config — both halves matter, and the first one was wrong:
#   * -Help and -Diagnose install nothing. Latched before them, this emitted
#     `install.run.succeeded` for a run that never touched the machine — the exact
#     client#747 bug the comment here claimed to prevent while the code did the
#     opposite, with the wiring test asserting the inverted order and so pinning
#     it. (@saqlainsyed007 on #782.) Print-Help and the -Diagnose branch both exit
#     inside those lines, so nothing below can be reached by them.
#   * a genuine failure in Confirm-Config IS an install attempt and must still be
#     reported, which is why the latch is not pushed further down.
if (Get-Command -Name 'Set-TelemetryRunStarted' -CommandType Function -ErrorAction SilentlyContinue) {
  Set-TelemetryRunStarted
}

Confirm-Config
Initialize-ToolDir
Start-InstallLog
# Load the install state up front (#420): drives the fast nothing-to-do path.
# Missing/corrupt -> a fresh state (never fatal).
$script:InstallState = Read-InstallState
Print-Banner
if ($Resume) { Ok "Resuming the tracebloc install after a reboot..." }
Print-Roadmap

# Detect the GPU BEFORE the fast path so it can tell whether a "healthy" CPU-only install should
# still be re-evaluated for GPU (and so preflight's nvcr.io probe is gated on GPU presence). Cheap
# + pure detection (Get-CimInstance + driver check); sets $GPU_VENDOR / $NVIDIA_DRIVER_OK (#616).
Find-Gpu

# Fast path (#420): a prior run completed successfully AND the tools + a RUNNING
# cluster + Ready client workloads are all still here -> nothing to do. Honest: it
# verifies live health (not just the checkpoint), so a stopped cluster or a down
# client falls through to the repairing walk. Skipped on -Resume (a resume must
# finish the interrupted walk).
if ((-not $Resume) -and $script:InstallState.completed -and (Test-ToolsPresent) -and (Test-TraceblocCliCurrent) -and (Test-ClusterRunning) -and (Test-ClientHealthy)) {
  # GPU is "fully enabled" only when the node ACTUALLY advertises a GPU AND the live release
  # requests one. If an NVIDIA GPU is present but EITHER is missing, do NOT shortcut -- the state is
  # inconsistent in one of two ways (Bugbot), both of which a re-run should fix:
  #   * node not advertising (device-plugin/driver just fixed) -> enable GPU, or
  #   * node advertising but the release still requests CPU (a delayed GPU recovery) -> reconcile
  #     GPU_REQUESTS so training stops silently running on CPU.
  # The CPU-fallback guidance explicitly tells operators to re-run, so honour that by falling through.
  $gpuPresent = ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK)
  $gpuFullyEnabled = $false
  if ($gpuPresent) { $gpuFullyEnabled = ((Test-RunningClusterGpuCapable) -and (Test-LiveReleaseRequestsGpu)) }
  if ($gpuPresent -and -not $gpuFullyEnabled) {
    Info "An NVIDIA GPU is present but not fully enabled here -- re-checking to reconcile GPU (node advertisement + chart request)."
    Log "Fast-path skipped: GPU present but not fully enabled; re-evaluating GPU."
  } else {
    Ok "tracebloc is already installed and the client is healthy -- nothing to do."
    # A healthy cluster can still be running a DRIFTED k3s (the #547 steady state);
    # this fast-path exits before New-K3dCluster's reuse check, so warn here too
    # (Bugbot #565). Non-fatal: the client is healthy, we just flag the version.
    Test-K3sVersionDrift
    # Same reasoning for GPU: a healthy cluster whose values request GPU but whose node is
    # CPU-only would strand GPU experiments; flag it here since the fast path skips the gate (Bugbot).
    Test-HealthyClusterGpuConsistent
    # This path exits before Helm, so a cluster installed BEFORE this fix would never
    # get its PV dirs repaired -- the client is healthy, so every re-run shortcuts
    # here and the first ingest keeps failing with "Permission denied". Repair it now:
    # idempotent, bounded, and it makes "re-run the installer" a real remedy instead
    # of advice that quietly does nothing. Get-InstalledClientInfo is the same bounded
    # enumerator the health gate above already used; the release NAME (not the
    # namespace) is what the PV paths embed.
    $fpRelease = (Get-InstalledClientInfo).Name
    if ($fpRelease) { Initialize-ReleaseDataDirs -Release $fpRelease }
    Hint "Delete $(Get-InstallStatePath) (or set a fresh HOST_DATA_DIR) to force a full reinstall."
    Unregister-ResumeAfterReboot
    Log "Already installed and healthy - nothing to do."
    $script:OutcomeReported = $true
    # A real invocation, but NOT a successful install: folding it into succeeded
    # makes the success count grow with re-runs on machines nothing happened to.
    # `skipped` is a registered outcome verb, so this needs no new vocabulary —
    # and the bash twin already reports it from assess.sh's gate, so without this
    # the two platforms answered "how often is there nothing to do" differently.
    if (Get-Command -Name 'Set-TelemetryRunSkipped' -CommandType Function -ErrorAction SilentlyContinue) {
      Set-TelemetryRunSkipped
    }
    exit 0
  }
}

# Trust an explicit corporate CA across every host tool (cosign/helm/git) BEFORE the
# preflight probes and any tool download, so a TLS-inspecting proxy is handled
# end-to-end (#583). Invoke-WebRequest already uses the Windows store; the k3d nodes
# are trusted at cluster-create (#424).
Set-ToolTrust

# -- Step 1/6: Check system requirements (honest split from tool install, #422) --
Step 1 $script:INSTALL_STEPS.Count "Checking system requirements" "a"
# ($GPU_VENDOR / driver were detected before the fast-path so it could decide whether to retry GPU.)
Test-Preflight
Enable-VirtualisationFeatures

# -- Step 2/6: Install system tools (~700 MB — Docker Desktop, kubectl, k3d, helm;
# each names its wait + shows a heartbeat + prints a summary line, #422) --
Step 2 $script:INSTALL_STEPS.Count "Installing system tools" "b"
Install-Winget
Install-DockerDesktop
Install-NvidiaContainerToolkit
# #616: the docker-run probe is the AUTHORITATIVE GPU gate. Docker Desktop uses its own WSL
# distro, so the toolkit-in-Ubuntu step above isn't a reliable signal; and with the custom
# k3s-CUDA node image providing the in-cluster runtime, what actually matters is whether Docker
# can expose the GPU to a container. Enable GPU iff the probe passes -- else CPU fallback
# (Layer 1) with a clear reason, and never create a --gpus cluster that would fail.
if ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK -and ($K8S_VERSION -eq "latest" -or $K8S_VERSION -eq "")) {
  # GPU needs the pinned k3s-CUDA node image, whose tag is derived from $K8S_VERSION. With
  # K8S_VERSION=latest (the unsupported opt-out, #547) cluster-create adds NO --image, so k3d
  # would make a STOCK node (no NVIDIA runtime) while the chart requests nvidia.com/gpu +
  # runtimeClassName=nvidia -- stranding every job (Bugbot). GPU + 'latest' is incompatible, so
  # fall back to CPU here (never build/enable) with a reason that points at the fix.
  # Install-NvidiaContainerToolkit (above) may ALREADY have set K3D_GPU_FLAG=--gpus=all, so CLEAR
  # it here -- otherwise a fresh 'latest' cluster gets --gpus=all with a stock (non-CUDA) node.
  $K3D_GPU_FLAG = ""
  $GPU_SKIP_REASON = "GPU requires the validated pinned k3s (K8S_VERSION), but K8S_VERSION=latest is set -- unset it (use the pinned default) to enable GPU"
  Warn "GPU detected but not enabled: K8S_VERSION=latest is unsupported for GPU (the GPU node image is tied to the validated pin). Running CPU-only."
} elseif ($GPU_VENDOR -eq "nvidia" -and $NVIDIA_DRIVER_OK) {
  # How we obtain the GPU node image: by DEFAULT we BUILD it locally from public bases so a
  # GPU install needs no registry login and no private package -- one command, like a CPU
  # install (#616). If an explicit prebuilt image / mirror is configured (air-gap tenants),
  # PULL that instead of building (a mirror implies no egress to the public CUDA base, and
  # they ship a prebuilt image). Either way it's a single function that leaves a specific
  # $GPU_SKIP_REASON on failure. Guarded by the docker-run probe first (-and short-circuits),
  # so we never build/pull if the GPU can't be exposed anyway.
  # Authenticate to the GPU image's registry FIRST when a mirror/private image is configured,
  # so the GPU probe's mirror-hosted CUDA pull (and the node-image pull) are already logged in.
  # No-op without creds / on the default public build path (Bugbot). Runs before the probe.
  if ($env:TRACEBLOC_K3S_CUDA_IMAGE -or $env:TRACEBLOC_IMAGE_REGISTRY) { Connect-GpuRegistry }
  $gpuImageReady = { if ($env:TRACEBLOC_K3S_CUDA_IMAGE -or $env:TRACEBLOC_IMAGE_REGISTRY) { Confirm-GpuImagePullable } else { Build-GpuNodeImage } }
  if ($GPU_HOSTS_UNREACHABLE) {
    # Preflight already established the GPU download chain is blocked, so the probe (180s) and the
    # build/pull (up to 15/20 min) would only time out. Fail fast with the known reason (Bugbot).
    # Remedy has to match the path: telling someone who already configured a mirror to configure
    # a mirror is noise -- point at the mirror's reachability instead (Bugbot).
    if ($env:TRACEBLOC_K3S_CUDA_IMAGE -or $env:TRACEBLOC_IMAGE_REGISTRY) {
      $GPU_SKIP_REASON = "$GPU_HOSTS_UNREACHABLE, so the GPU node image can't be pulled -- check that your configured GPU image registry is reachable from this machine (and that it holds the k3s-CUDA image), then re-run; running CPU-only"
    } else {
      $GPU_SKIP_REASON = "$GPU_HOSTS_UNREACHABLE, so the GPU node image can't be built -- on a restricted network set TRACEBLOC_IMAGE_REGISTRY to your mirror (or TRACEBLOC_K3S_CUDA_IMAGE to a prebuilt image) and re-run; running CPU-only"
    }
    Warn "Skipping GPU setup -- $GPU_HOSTS_UNREACHABLE. Running CPU-only (no long timeouts)."
  }
  elseif ((Confirm-DockerGpu) -and (& $gpuImageReady)) {
    $K3D_GPU_FLAG = "--gpus=all"
    $GPU_SKIP_REASON = ""
    # Single physical GPU vs multi-node cluster (Bugbot): k3d's --gpus=all exposes the
    # SAME host GPU to EVERY node container, and whatever advertises the resource (a device
    # plugin on Linux, the node reconciler on WSL2) does so once per node -- so a default
    # server+agent cluster advertises
    # nvidia.com/gpu=1 on BOTH nodes (2 allocatable for 1 physical card) and can schedule
    # two jobs onto the same device. Extra k3d nodes live on the same Docker host and all
    # see the same card, so multi-node can NEVER add real GPUs -- it only double-counts.
    # Collapse to a single node whenever GPU is on: one node -> the card is advertised once.
    if ($AGENTS -ne "0") {
      if ($env:AGENTS) {
        Warn ("GPU mode forces a single node (agents=0) so the one physical GPU isn't double-counted; overriding your AGENTS=$AGENTS. Extra k3d nodes share the same host GPU and only re-advertise it.")
      } else {
        Log "GPU mode: using a single node (agents=0) so the one physical GPU is advertised exactly once."
      }
      $AGENTS = "0"
    }
    # SERVERS needs the same collapse (Bugbot): agents=0 alone still leaves SERVERS>1 possible,
    # and EVERY server node runs the boot reconciler and advertises nvidia.com/gpu=1 for the SAME
    # physical card -- so a 3-server cluster would offer 3 GPUs and schedule 3 jobs onto one
    # device. One server => the card is advertised exactly once.
    if ($SERVERS -ne "1") {
      if ($env:SERVERS) {
        Warn ("GPU mode forces a single server (servers=1) so the one physical GPU isn't double-counted; overriding your SERVERS=$SERVERS. Every k3d node shares the same host GPU and would re-advertise it.")
      } else {
        Log "GPU mode: using a single server (servers=1) so the one physical GPU is advertised exactly once."
      }
      $SERVERS = "1"
    }
    # Intent, not accomplishment (Bugbot -- third instance of this class): cluster-create, the
    # node's CDI wiring, and Confirm-GpuNode all still run after this and can each clear
    # K3D_GPU_FLAG. Only Confirm-GpuNode's "GPU verified and available" may claim success, so a
    # green line here would be followed by a CPU-only summary.
    Info "GPU support prepared -- the cluster will be created with GPU; verified once the node is up."
  } else {
    $K3D_GPU_FLAG = ""
    if (-not $GPU_SKIP_REASON) {
      $GPU_SKIP_REASON = "Docker Desktop can't expose the GPU to containers (enable GPU support in Docker Desktop, and update the WSL2 NVIDIA driver)"
    }
    Warn ("GPU detected but not enabled -- running CPU-only: " + $GPU_SKIP_REASON)
  }
}
Install-Kubectl
Install-K3dAndHelm

# -- Step 3/6: Set up secure compute environment --
Step 3 $script:INSTALL_STEPS.Count "Setting up secure compute environment" "c"
New-K3dCluster
# Only verify the GPU on the node when the plugin actually deployed; a failed/
# CPU-mode deploy returns $false, so skipping verify avoids a ~90s wait and a
# contradictory "still initializing" warning for a plugin never applied (Bugbot).
if (Install-GpuDevicePlugin) {
  Confirm-GpuNode
} elseif ($K3D_GPU_FLAG -ne "") {
  # GPU was requested (flag still set) but the device-plugin setup FAILED -- returning $false here
  # is a real failure, not the "GPU not requested" early return. Leaving the flag set would make
  # Install-ClientHelm request nvidia.com/gpu the node can't provide, stranding jobs. Fall back to
  # CPU (Bugbot). (When GPU wasn't requested the flag is already empty, so this branch no-ops.)
  $K3D_GPU_FLAG = ""
  if (-not $GPU_SKIP_REASON) { $GPU_SKIP_REASON = "the NVIDIA device plugin couldn't be set up on the cluster -- running CPU-only" }
  Warn "GPU device-plugin setup failed -- running CPU-only so jobs aren't stranded Pending."
}

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
if (-not (Test-InstallSucceeded)) { $script:TbExitCode = 1; exit 1 }

} catch {
  # Any crash the run didn't handle itself lands here as a clean message, not a
  # raw stack (#577). Show-FatalError sets $script:OutcomeReported.
  Show-FatalError $_
  $script:TbExitCode = 1
  exit 1
} finally {
  # Guaranteed closer: this runs on EVERY exit above. Every reported path (normal
  # finish, Err, caught crash, fast-path, help/diagnose) set OutcomeReported; if it
  # is still false we were interrupted (Ctrl-C / abnormal), so surface a clean line
  # rather than letting the window vanish silently (#577).
  if (-not $script:OutcomeReported) {
    Show-Interrupted
    # DERIVED, not detected separately. OutcomeReported being false at this point
    # is already the installer's own definition of "interrupted", so the
    # telemetry status comes from it rather than from a second Ctrl-C mechanism
    # that could disagree. 130 is SIGINT's conventional status and is what the
    # bash twin's `trap 'exit 130' INT` reports, so both twins render the same
    # `install.run.cancelled`.
    if ($script:TbExitCode -eq 0) { $script:TbExitCode = 130 }
  }

  # THE ONE EVENT THIS INSTALL PRODUCES (backend#2268). This `finally` is the
  # Windows analogue of install_cleanup — the comment above already says it
  # "mirrors bash's install_cleanup" — so it is the right and only place for it:
  # it runs on the normal finish, the caught crash, the fast path, the declared
  # re-run handoff and the interrupt.
  #
  # LAST, and it cannot throw: Send-TelemetryOutcome swallows everything
  # internally, and this guard means a missing lib is not an error either. An
  # installer that failed at the finish line because telemetry was unhappy would
  # be a strictly worse installer.
  if (Get-Command -Name 'Send-TelemetryOutcome' -CommandType Function -ErrorAction SilentlyContinue) {
    Send-TelemetryOutcome -Code $script:TbExitCode
  }
}

}  # end TB_PESTER guard (skipped when the test suite dot-sources this file)
