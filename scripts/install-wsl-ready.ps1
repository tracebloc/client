# =============================================================================
#  install-wsl-ready.ps1 -- section 1 of install-wsl.ps1: WSL ready, and the
#  host's networking mode and memory.
#
#  install-wsl.ps1 dot-sources this file from beside itself, at the place the
#  section stands in its order, and checks it through $CoreFiles; install.ps1
#  fetches and verifies it with the rest ($Files).
# =============================================================================

# =============================================================================
#  1. WSL ready
# =============================================================================
# The first step of the WSL path: WSL at or above the floor, or a plain stop.
# Enabling WSL needs an administrator once per machine, and no option avoids it
# (D7). So:
#   - WSL already at the floor: nothing to do.
#   - The daily user is not an administrator (or no one can answer the Windows
#     prompt): print the one IT command and stop. Nothing is elevated.
#   - The user is an administrator: Windows asks once (UAC), and ONLY the IT
#     command runs elevated. The installer itself never relaunches elevated, so
#     everything after this step runs as the user (D7), and an `irm | iex` run
#     needs no file to relaunch.
#   - Turning WSL on wants a restart: a resume marker is written, and the same
#     install command run again after the restart continues from here.
# Every answer this cannot read is "cannot tell", and "cannot tell" is never
# "ready": it takes the same branch as a missing WSL.
#
# The values S-W measures are named here, so its rows change values, not code.

# TODO: the floor is WSL 2.5 (cgroup v2
# by default). Record `wsl --version` on the managed laptop; set it here.
$WslMinVersion = '2.5'

# The one IT command D7 names. The refusal prints it, and the elevated step
# runs it, from this one list.
$WslInstallArgs = @('--install', '--no-distribution')
# TODO(S-W row 1): whether that command lifts an installed WSL that is below the
# floor, or IT needs `wsl --update` for that case. Until row 1 says, both cases
# get the one command.
$WslUpdateArgs = $WslInstallArgs

# TODO(S-W row 2): how many restarts turning WSL on takes. Row 2 records the
# boots and restarts after the IT step; one until it says.
$WslEnableMaxRestarts = 1
# TODO(S-W row 2): the exit code `wsl --install --no-distribution` returns when it
# needs a restart. 3010 and 1641 are Windows' "succeeded, restart needed /
# restarting" codes, not a measurement of wsl.exe. Any other non-zero code is a failure. A restart
# code is never probed into "ready": Windows has said it must restart first.
$WslEnableRestartCodes = @(3010, 1641)
$WslEnableOkCodes = @(0) + $WslEnableRestartCodes

# The Windows feature WSL 2 runs on. `wsl --version` answers without it: on a fresh
# Windows Server 2025 host (3.3's EC2 cell) the IT step enabled it pending a
# restart, and `wsl --version` already answered 3.0.3. So WSL is ready only on an
# enabled platform.
$WslPlatformFeature = 'VirtualMachinePlatform'
# DISM's feature states, as Get-WindowsOptionalFeature names them, and what each
# means here: a restart pending either way is "pending", never ready; a feature
# partly installed is not enabled, so the IT step finishes it; one superseded by a
# newer package says nothing about the platform, so cannot tell. A state not
# listed is cannot tell too. A Windows-only Pester case holds the keys to exactly
# the names DISM's FeatureState declares.
$WslPlatformStates = @{
  'Enabled'                    = 'enabled'
  'EnablePending'              = 'pending'
  'DisablePending'             = 'pending'
  'Disabled'                   = 'disabled'
  'DisabledWithPayloadRemoved' = 'disabled'
  'PartiallyInstalled'         = 'disabled'
  'Superseded'                 = 'cannot-tell'
}
# Which signal shows the IT step's restart, measured on Windows Server 2025 (S-W
# row 2): after DISM enables the platform with /norestart (exit 3010), DISM already
# reads Enabled and WMI's install state 1 (1 enabled, 2 disabled, 3 absent;
# anything else, cannot tell), while the restart is still owed. Only Windows' own
# pending-restart flag shows it, set then and cleared by the restart, and a
# standard user can read it. So the flag is read first, elevated or not. It is
# machine-wide: a restart any servicing owes reads as pending too.
# The flag: this key under HKLM, there while a restart is pending.
$WslRestartPendingKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$WslPlatformWmiStates = @{ 1 = 'enabled'; 2 = 'disabled'; 3 = 'disabled' }

$WslProbeTimeoutSec  = 30
$WslEnableTimeoutSec = 1200
# The first command that enters the distro STARTS it, and a cold start is not
# bounded by the 30 s a `wsl --version` gets. 300 s is the bound the spike kit gives
# the distro to be running after a logon, not a
# measured worst case: the VM measured 10 s, and the first start right after the
# import is unmeasured.
$WslDistroStartTimeoutSec = 300
# `wsl --manage --set-sparse` and `--resize` rewrite the distro's VHDX, and that
# work grows with the disk, so it is not bounded by the 30 s a `wsl --version`
# gets either: on a probe budget a slow disk timed out while wsl.exe kept going.
# 600 s is a bound, not a measured worst case.
$WslDiskTimeoutSec = 600

# "2.5" or "2.5.10.0" as a four-part [version], so 2.5.0 and 2.5.0.0 compare equal
# ([version] ranks a missing part below 0). $null for anything else.
function ConvertTo-WslVersion {
  param([AllowNull()][string]$Text)
  if ($Text -notmatch '^\d+(\.\d+){1,3}$') { return $null }
  $p = @($Text.Split('.') | ForEach-Object { $_ })
  while ($p.Count -lt 4) { $p += '0' }
  try { return [version]($p -join '.') } catch { return $null }
}

# The WSL version from `wsl --version`'s output, or $null when this cannot tell.
# The labels are localized ("WSL version", "WSL-Version", "Version de WSL"), but
# every one keeps the word WSL, a colon and the number; the lines after it
# (Kernel, WSLg, MSRDC, ...) carry other words or other shapes. So: the first line
# of that shape, whole. Read defensively:
#   - wsl.exe writes UTF-16LE unless WSL_UTF8=1 reaches it, and an old wsl.exe
#     ignores the variable, so NULs are stripped (and a BOM) before matching.
#   - An old inbox wsl.exe answers --version with its usage text, which has no
#     such line: $null, never a guess.
function ConvertFrom-WslVersionText {
  param([AllowNull()][string]$Text)
  if (-not $Text) { return $null }
  $clean = ($Text -replace "`0", '') -replace ([string][char]0xFEFF), ''
  foreach ($line in ($clean -split "`r?`n")) {
    $m = [regex]::Match($line, '^[^:\uFF1A]*\bWSL\b[^:\uFF1A]*[:\uFF1A]\s*(\d+(?:\.\d+){2,3})\s*$')
    if ($m.Success) { return (ConvertTo-WslVersion $m.Groups[1].Value) }
  }
  return $null
}

# Runs one wsl.exe command, bounded, with WSL_UTF8=1, and reports what happened
# without judging it. The only function here that starts wsl.exe to read it.
# Output is what it wrote to stdout; ErrorOutput, kept apart, what it wrote to
# stderr, where WSL's service errors (ERROR_SHARING_VIOLATION) can go. Both are
# read as UTF-8, as WSL_UTF8=1 asks of both, and both come back with their NULs
# stripped: an old wsl.exe ignores WSL_UTF8 and writes UTF-16LE, which reads as a
# NUL between every letter, and a reader that matches the raw text (k3s's state,
# the trust bundle's certificates) then misses. Stripped here, once, so no reader
# has to remember to. -FilePath is a seam for the test suite.
function Invoke-WslProbe {
  param([string]$FilePath = 'wsl.exe', [string[]]$ArgumentList = @('--version'), [int]$TimeoutSec = $WslProbeTimeoutSec)
  $r = [pscustomobject]@{ Started = $false; TimedOut = $false; ExitCode = $null; Output = ''; ErrorOutput = ''; StartError = ''; NativeErrorCode = $null }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = ($ArgumentList -join ' ')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $psi.EnvironmentVariables['WSL_UTF8'] = '1'
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  try {
    [void]$p.Start()
  } catch {
    # A start failure is kept whole for Test-WslBlockedByPolicy: the message and,
    # for a Win32 refusal, its code.
    $e = $_.Exception
    while ($e.InnerException -and -not ($e -is [System.ComponentModel.Win32Exception])) { $e = $e.InnerException }
    $r.StartError = $e.Message
    if ($e -is [System.ComponentModel.Win32Exception]) { $r.NativeErrorCode = $e.NativeErrorCode }
    return $r
  }
  $r.Started = $true
  $out = $p.StandardOutput.ReadToEndAsync()
  $err = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    $r.TimedOut = $true
    try { $p.Kill() } catch { $r.StartError = "could not stop it: $($_.Exception.Message)" }
    return $r
  }
  $p.WaitForExit()
  $r.ExitCode = $p.ExitCode
  $r.Output = ([string]$out.Result) -replace "`0", ''
  $r.ErrorOutput = ([string]$err.Result) -replace "`0", ''
  return $r
}

# TODO (S-W row 2): the hook for an organisation's policy refusing
# wsl.exe (AppLocker or WDAC). How such a refusal looks on a managed laptop -- the
# start error, its code, an event-log entry -- is what row 2 records, so this does
# not guess: it answers "not blocked", and a blocked wsl.exe reads as "cannot tell",
# which stops with the IT command all the same. When row 2 says, this answers from
# the probe (Invoke-WslProbe's StartError, NativeErrorCode, ExitCode, Output), and
# the named refusal in Confirm-WslReady is already wired to it.
function Test-WslBlockedByPolicy {
  param([object]$Probe)
  $null = $Probe
  return $false
}

# Where WSL stands: ready, old (below the floor), blocked (by policy), or
# cannot-tell, with the reason in words. Only a version read whole from a clean
# exit can be ready.
function Get-WslState {
  param([string]$MinVersion = $WslMinVersion)
  $min = ConvertTo-WslVersion $MinVersion
  if (-not $min) { throw "The WSL floor '$MinVersion' is not a version." }
  $p = Invoke-WslProbe -ArgumentList @('--version')
  $v = $null
  if (-not $p.Started) {
    $why = "wsl.exe did not start ($($p.StartError))"
  } elseif ($p.TimedOut) {
    $why = "wsl --version did not answer within $WslProbeTimeoutSec seconds"
  } elseif ($p.ExitCode -ne 0) {
    $why = "wsl --version exited $($p.ExitCode)"
  } else {
    $v = ConvertFrom-WslVersionText -Text $p.Output
    if (-not $v) { $why = 'wsl --version printed no WSL version this installer can read' }
  }
  if ($v -and $v -ge $min) { return [pscustomobject]@{ State = 'ready'; Version = $v; Why = '' } }
  if (Test-WslBlockedByPolicy -Probe $p) { return [pscustomobject]@{ State = 'blocked'; Version = $v; Why = 'policy' } }
  if ($v) { return [pscustomobject]@{ State = 'old'; Version = $v; Why = "WSL $v is installed" } }
  return [pscustomobject]@{ State = 'cannot-tell'; Version = $null; Why = $why }
}

# The Virtual Machine Platform's state: enabled, pending (a restart first),
# disabled, or cannot-tell, with the reason in words. Windows' pending-restart flag
# first, elevated or not, since DISM reads Enabled while the restart is owed; then
# DISM; then, for an unelevated run, which DISM refuses, WMI.
function Get-WslPlatformState {
  try {
    $pending = Test-WslRestartPending
  } catch {
    return [pscustomobject]@{ State = 'cannot-tell'; Why = "Windows' pending-restart flag could not be read ($($_.Exception.Message))" }
  }
  if ($pending) {
    return [pscustomobject]@{ State = 'pending'; Why = 'Windows has a restart pending' }
  }
  try {
    $s = "$((Get-WindowsOptionalFeature -Online -FeatureName $WslPlatformFeature -ErrorAction Stop).State)"
    if (@($WslPlatformStates.Keys) -ccontains $s) {
      return [pscustomobject]@{ State = $WslPlatformStates[$s]; Why = "the Virtual Machine Platform is $s" }
    }
    return [pscustomobject]@{ State = 'cannot-tell'; Why = "the Virtual Machine Platform reads '$s', which this installer does not know" }
  } catch {
    $dism = $_.Exception.Message
  }
  try {
    $f = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='$WslPlatformFeature'" -ErrorAction Stop
  } catch {
    return [pscustomobject]@{ State = 'cannot-tell'; Why = "the Virtual Machine Platform's state could not be read ($($_.Exception.Message))" }
  }
  $n = if ($f) { $f.InstallState } else { $null }
  $k = $n -as [int]
  if ($null -ne $k -and $WslPlatformWmiStates.ContainsKey($k)) {
    $st = $WslPlatformWmiStates[$k]
    return [pscustomobject]@{ State = $st; Why = "the Virtual Machine Platform is $st" }
  }
  return [pscustomobject]@{ State = 'cannot-tell'; Why = "the Virtual Machine Platform's state could not be read (DISM: $dism; WMI install state '$n')" }
}

# Whether Windows has a restart pending: its flag key is there. Test-Path answers
# false for a key this account cannot open, which would read a pending restart as
# none, so the key is opened instead: no key is $false, and a key this account
# cannot open throws ("Requested registry access is not allowed.", measured in CI
# on Windows PowerShell 5.1 and pwsh 7.6.6), which the caller reads as cannot
# tell. -Hive (a property of [Microsoft.Win32.Registry]) and -Key are a seam for
# the test suite.
function Test-WslRestartPending {
  param([string]$Hive = 'LocalMachine', [string]$Key = $WslRestartPendingKey)
  $k = [Microsoft.Win32.Registry]::$Hive.OpenSubKey($Key)
  if ($null -eq $k) { return $false }
  $k.Dispose()
  return $true
}

# Get-WslState, and under a WSL at the floor the platform it runs on: ready only on
# an enabled platform. A restart the platform waits for is pending; a platform
# turned off, or one this cannot read, is cannot-tell, which the IT step enables.
function Get-WslReadiness {
  param([string]$MinVersion = $WslMinVersion)
  $w = Get-WslState -MinVersion $MinVersion
  if ($w.State -ne 'ready') { return $w }
  $p = Get-WslPlatformState
  if ($p.State -eq 'enabled') { return $w }
  $st = if ($p.State -eq 'pending') { 'pending' } else { 'cannot-tell' }
  return [pscustomobject]@{ State = $st; Version = $w.Version; Why = $p.Why }
}

# The process token is elevated (an administrator who ran PowerShell as
# Administrator).
function Test-BootstrapElevated {
  try {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

# whoami /groups /fo csv names BUILTIN\Administrators (S-1-5-32-544) for an
# administrator even when UAC has filtered it to "deny only", which the process's
# own group list leaves out. The headers and names are localized; the SID is not.
function Test-AdminSidListed {
  param([AllowNull()][string]$Text)
  return [bool]($Text -match '"S-1-5-32-544"')
}

# The user is an administrator, elevated or not. Anything unreadable is "no":
# that only means the IT command is printed instead of a prompt.
function Test-BootstrapUserIsAdmin {
  try { $g = (& whoami.exe /groups /fo csv 2>$null) -join "`n" } catch { return $false }
  return (Test-AdminSidListed -Text $g)
}

# Seconds since the epoch of the last boot, or $null when unreadable.
function Get-HostBootUnixTime {
  try {
    $b = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    return ([DateTimeOffset]::new($b.ToUniversalTime())).ToUnixTimeSeconds()
  } catch { return $null }
}

# TODO(S-W row 2): the resume marker. A JSON note in the user's own
# %LOCALAPPDATA%\tracebloc, written when turning WSL on wants a restart: when it
# was written (epoch seconds), how many restarts the step has taken, and whether
# the IT step has run yet (a restart for Windows' own pending flag can come
# first). A run that finds WSL ready deletes it. Row 2 says whether a RunOnce
# entry should also re-run the installer after the restart.
function Get-WslResumeMarkerPath {
  return (Join-Path $env:LOCALAPPDATA 'tracebloc\wsl-resume.json')
}

function Write-WslResumeMarker {
  param([string]$Path, [int]$Restarts, [bool]$EnableRan)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $note = [ordered]@{ step = 'wsl-enable'; written = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); restarts = $Restarts; enableRan = $EnableRan }
  [System.IO.File]::WriteAllText($Path, ($note | ConvertTo-Json -Compress))
}

# The marker, or $null. One that cannot be read is deleted and not trusted: the
# probe still decides readiness, so starting over only costs a prompt.
function Read-WslResumeMarker {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $n = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    if ($n.step -ne 'wsl-enable') { throw "step '$($n.step)'" }
    $written = [long]$n.written
    $restarts = [int]$n.restarts
    if ($written -le 0 -or $restarts -lt 0) { throw 'out of range' }
    if ($n.enableRan -isnot [bool]) { throw 'no enableRan' }
    return [pscustomobject]@{ Written = $written; Restarts = $restarts; EnableRan = $n.enableRan }
  } catch {
    Warn "Ignoring an unreadable resume note ($Path) and starting this step over."
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return $null
  }
}

# Runs the IT command: through UAC when -Elevate, else in this (already elevated)
# console. Bounded; an elevated process cannot be stopped from here, so a timeout
# only stops the wait. Returns @{ State = ok | declined | timeout; ExitCode; Detail }.
function Invoke-WslEnable {
  param([string[]]$ArgumentList, [switch]$Elevate, [int]$TimeoutSec = $WslEnableTimeoutSec)
  $sp = @{ FilePath = 'wsl.exe'; ArgumentList = ($ArgumentList -join ' '); PassThru = $true; ErrorAction = 'Stop' }
  if ($Elevate) { $sp.Verb = 'RunAs' } else { $sp.NoNewWindow = $true }
  try {
    $p = Start-Process @sp
  } catch {
    # Start-Process -Verb RunAs throws when the prompt is declined, and so does a
    # launch that cannot start at all. Either way nothing ran.
    return @{ State = 'declined'; ExitCode = $null; Detail = $_.Exception.Message }
  }
  $null = $p.Handle   # cache the handle now, or ExitCode can read empty after the exit
  if (-not $p.WaitForExit($TimeoutSec * 1000)) { return @{ State = 'timeout'; ExitCode = $null; Detail = '' } }
  return @{ State = 'ok'; ExitCode = $p.ExitCode; Detail = '' }
}

# 'ready', or 'restart' (a restart is needed first: the caller stops with the
# reboot handoff code). Every other outcome throws its own named refusal.
function Confirm-WslReady {
  param([string]$MarkerPath, [string]$MinVersion = $WslMinVersion, [int]$MaxRestarts = $WslEnableMaxRestarts)
  if (-not $MarkerPath) { $MarkerPath = Get-WslResumeMarkerPath }
  $itLead = 'Ask your IT team to run this once in an administrator PowerShell, then restart Windows if it asks:'
  $restartWords = 'Restart Windows, then run the same install command again: it continues from here.'

  $w = Get-WslReadiness -MinVersion $MinVersion
  if ($w.State -eq 'ready') {
    Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
    Ok "WSL $($w.Version) ready"
    return 'ready'
  }
  $enableArgs = if ($w.State -eq 'old') { $WslUpdateArgs } else { $WslInstallArgs }
  $cmd = 'wsl ' + ($enableArgs -join ' ')
  if ($w.State -eq 'blocked') {
    Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
    Stop-Setup -What "Your organisation's policy blocks WSL on this machine" -Next 'Ask your IT team to allow WSL and run this once as an administrator, then run the installer again:' -Command $cmd -Reason "Your organisation's device policy blocks WSL (wsl.exe) on this computer, so tracebloc cannot set up its Linux environment here. Ask your IT team to allow wsl.exe for your account, and to run this once in an administrator PowerShell: $cmd"
  }

  # A second run: did the restart the last run asked for happen?
  $restarts = 0
  $enableRan = $false
  $marker = Read-WslResumeMarker -Path $MarkerPath
  if ($marker) {
    $boot = Get-HostBootUnixTime
    # An unreadable boot time counts as a restart, so the limit below still ends
    # the loop; never counting it would ask for restarts forever.
    if ($null -ne $boot -and $boot -le $marker.Written) {
      Log "Windows still needs the restart that finishes turning on WSL. $restartWords"
      Write-RestartNeeded
      return 'restart'
    }
    $restarts = $marker.Restarts + 1
    $enableRan = $marker.EnableRan
    # A restart taken only for Windows' pending flag, before the IT step ever ran,
    # spends none of the limit once the flag is gone: the IT step runs now, with
    # the limit whole for its own restart. One still pending after it counts, so
    # a flag that never clears still ends.
    if (-not $enableRan -and $w.State -ne 'pending') {
      $restarts = 0
    } elseif ($restarts -ge $MaxRestarts) {
      Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
      Stop-Setup -What "WSL still isn't ready after restarting Windows" -Next 'Ask an administrator to run this once, then run the installer again:' -Command $cmd -Reason "WSL is still not ready after $restarts restart(s): $($w.Why). $itLead $cmd"
    }
  }

  # WSL answers, but the platform under it waits for a restart: nothing to run, and
  # not ready until Windows has restarted. Stopped here, before anything is imported.
  if ($w.State -eq 'pending') {
    Write-WslResumeMarker -Path $MarkerPath -Restarts $restarts -EnableRan $enableRan
    Log "Windows needs a restart to finish turning on WSL. $restartWords"
    Write-RestartNeeded
    return 'restart'
  }

  $elevated = Test-BootstrapElevated
  if (-not $elevated) {
    if (-not ((Test-BootstrapUserIsAdmin) -and (Test-BootstrapCanPrompt))) {
      Stop-Setup -What "Turning on WSL needs administrator rights" -Next 'Ask an administrator to run this once, then run the installer again:' -Command $cmd -Reason "This computer needs WSL $MinVersion or newer, and only an administrator can turn it on ($($w.Why)). $itLead $cmd -- then run this installer again as yourself."
    }
    Log "Turning on WSL needs administrator rights once. Windows will ask you to allow it."
    Info 'Windows will ask whether Windows Subsystem for Linux may'
    Write-Host '    make changes. Select Yes to continue.' -ForegroundColor DarkGray
  }
  $r = Invoke-WslEnable -ArgumentList $enableArgs -Elevate:(-not $elevated)
  if ($r.State -eq 'declined') {
    Stop-Setup -What "Windows didn't get permission to turn on WSL" -Next 'Run the installer again, and select Yes when Windows asks:' -Reason "The administrator step that turns on WSL did not start ($($r.Detail)). Run this installer again and allow the Windows prompt, or ask your IT team to run this once in an administrator PowerShell: $cmd"
  }
  if ($r.State -eq 'timeout') {
    Stop-Setup -What "Turning on WSL didn't finish" -Next 'Ask an administrator to run this once, then run the installer again:' -Command $cmd -Reason "The administrator step that turns on WSL did not finish within $([int]($WslEnableTimeoutSec / 60)) minutes. $itLead $cmd"
  }
  if ($WslEnableOkCodes -notcontains $r.ExitCode) {
    Stop-Setup -What "Turning on WSL failed" -Next 'Ask an administrator to run this once, then run the installer again:' -Command $cmd -Reason "Turning on WSL failed: $cmd exited $($r.ExitCode). $itLead $cmd"
  }

  if ($WslEnableRestartCodes -notcontains $r.ExitCode) {
    $w = Get-WslReadiness -MinVersion $MinVersion
    if ($w.State -eq 'ready') {
      Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
      Ok "WSL $($w.Version) ready"
      return 'ready'
    }
  }
  Write-WslResumeMarker -Path $MarkerPath -Restarts $restarts -EnableRan $true
  Log "Windows needs a restart to finish turning on WSL. $restartWords"
  Write-RestartNeeded
  return 'restart'
}

# WSL's networking mode, read from the user's own .wslconfig: the distro runs on WSL's default NAT
# only. networkingMode is a global [wsl2] key, so a user's mirrored setting reaches
# our distro too, and on the laptop (WSL 2.7.11) a mirrored distro's node never came
# up: containerd's pull timed out and autoProxy gave k3s no proxy. NAT pulled on both
# hosts. So any value but nat is refused by name before anything is written; a
# missing key, or no file, is WSL's default, NAT. The file is never edited: the key
# changes every distro the user has. A file that cannot be read is cannot tell, and
# is refused with the reason. Section and key names are read case-insensitively, as
# the value is; a key outside [wsl2] is not this one. A header with a trailing # or ;
# comment still names its section: read as no header, it would let the key under it
# through.
function Assert-WslNetworkingNat {
  param([string]$Path = (Join-Path $env:USERPROFILE '.wslconfig'))
  if (-not (Test-Path -LiteralPath $Path)) { return }
  try {
    $text = [System.IO.File]::ReadAllText($Path)
  } catch {
    Stop-Setup -What "Couldn't read your WSL settings in ~\.wslconfig" -Next 'Make sure your account can read that file, then run the installer again:' -Reason "The installer could not read your WSL settings file $Path ($($_.Exception.Message)), so it cannot tell whether WSL uses NAT networking, which the tracebloc WSL distro needs. Make sure your account can read the file, then run the install again. The installer does not change it."
  }
  $section = ''
  foreach ($raw in ($text -split "`r?`n")) {
    $line = $raw.Trim()
    if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
    if ($line -match '^\[([^\]]*)\]\s*([#;].*)?$') { $section = $Matches[1].Trim(); continue }
    $eq = $line.IndexOf('=')
    if ($section -ine 'wsl2' -or $eq -lt 0) { continue }
    if ($line.Substring(0, $eq).Trim() -ine 'networkingMode') { continue }
    $value = $line.Substring($eq + 1).Trim().Trim('"')
    if ($value -ine 'nat') {
      Stop-Setup -What "WSL uses $value networking $Dot tracebloc needs NAT" -Next 'Set networkingMode=nat in ~\.wslconfig, run wsl --shutdown (it stops every WSL distro), then run the installer again:' -Reason "Your WSL settings file $Path sets networkingMode=$value in its [wsl2] section. The tracebloc WSL distro needs WSL's NAT networking: with $value its cluster cannot download what it needs or start. This setting applies to all your WSL distros, so the installer does not change it. Set networkingMode=nat there, or remove the line, then run wsl --shutdown (it stops every running WSL distro) and run the install again."
    }
  }
}

# WSL's memory cap, from memory= in the [wsl2] section of the user's own .wslconfig,
# read as Assert-WslNetworkingNat reads networkingMode. Bytes, or $null: no file, no
# key, or a value this cannot read (logged), all of which leave WSL's default, half
# the machine's memory, which leaves Windows the other half.
function Get-WslMemoryCap {
  param([string]$Path = (Join-Path $env:USERPROFILE '.wslconfig'))
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { $text = [System.IO.File]::ReadAllText($Path) } catch { Log "Memory: could not read $Path ($($_.Exception.Message))."; return $null }
  $section = ''
  $cap = $null
  foreach ($raw in ($text -split "`r?`n")) {
    $line = $raw.Trim()
    if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
    if ($line -match '^\[([^\]]*)\]\s*([#;].*)?$') { $section = $Matches[1].Trim(); continue }
    $eq = $line.IndexOf('=')
    if ($section -ine 'wsl2' -or $eq -lt 0) { continue }
    if ($line.Substring(0, $eq).Trim() -ine 'memory') { continue }
    $value = $line.Substring($eq + 1).Trim().Trim('"')
    # WSL reads a bare number as bytes.
    if ($value -notmatch '^(\d+(\.\d+)?)\s*(([KMGT])B?|B)?$') { Log "Memory: memory=$value in $Path is not a size this reads."; $cap = $null; continue }
    $unit = switch ("$($Matches[4])") { 'K' { 1KB } 'M' { 1MB } 'G' { 1GB } 'T' { 1TB } default { 1 } }
    try { $cap = [long]([double]$Matches[1] * $unit) } catch { Log "Memory: memory=$value in $Path is too large to read."; $cap = $null; continue }
  }
  return $cap
}

# This machine's memory, in bytes: its total and what is available now. $null when
# Windows will not say.
function Get-HostMemory {
  try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    return [pscustomobject]@{ TotalBytes = [long]$os.TotalVisibleMemorySize * 1KB; AvailableBytes = [long]$os.FreePhysicalMemory * 1KB }
  } catch {
    Log "Memory: could not read this computer's memory ($($_.Exception.Message))."
    return $null
  }
}

# A warning, never a stop, when the user's own memory= leaves Windows less than
# $HostMemoryFloorBytes: of the total, or, for a cap over WSL's default half, of what
# is available now with the platform running. At or under half, low available memory
# is other programs', not the cap's, as it is without memory=, and nothing is said.
$HostMemoryFloorBytes = 2GB
function Format-MemorySize([long]$Bytes) {
  if ($Bytes -lt 1GB) { return "$([math]::Round($Bytes / 1MB)) MB" }
  return "$([math]::Round($Bytes / 1GB, 1)) GB"
}
function Write-WslMemoryCapWarning {
  $cap = Get-WslMemoryCap
  if ($null -eq $cap) { return }
  $mem = Get-HostMemory
  if ($null -eq $mem -or $mem.TotalBytes -le 0) { return }
  $headroom = [long]($mem.TotalBytes - $cap)
  Log "Memory: WSL capped at $cap bytes by memory=; this computer has $($mem.TotalBytes) bytes, $($mem.AvailableBytes) available."
  $capOverHalf = $cap -gt [long]($mem.TotalBytes / 2)
  if ($headroom -ge $HostMemoryFloorBytes -and -not ($capOverHalf -and $mem.AvailableBytes -lt $HostMemoryFloorBytes)) { return }
  # A cap at or over the total lets WSL take all of it; what is left is then what is free now.
  $left = [long]$mem.AvailableBytes
  if ($headroom -gt 0) { $left = [math]::Min($left, $headroom) }
  Write-SectionEnd
  Warn "$(Format-MemorySize $left) of memory left for Windows $Dot WSL is capped at $(Format-MemorySize ([math]::Min($cap, $mem.TotalBytes)))"
  Hint 'Lower memory= under [wsl2] in ~\.wslconfig, then run'
  Hint 'this (it stops every WSL distro):'
  Hint '  wsl --shutdown'
}
