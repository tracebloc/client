# =============================================================================
#  install-wsl.ps1 -- the Windows distro path (RFC-0175 D2, D7; client-dev#1810)
#
#  install.ps1 runs this as a child process (powershell.exe -File) when
#  TRACEBLOC_SUBSTRATE=k3s, where it would otherwise run install-k8s.ps1. It is
#  in install.ps1's $Files and in the signed manifest, so on the customer path it
#  runs only after install.ps1 has verified it.
#
#  -CoreDir is the one tree it may use:
#    - on the customer path, ONLY the temp dir install.ps1 has just verified
#      against the signed manifest (the sub-scripts plus manifest.sha256, laid
#      out as under scripts/);
#    - for e2e, a commit's own scripts/ directory, with a manifest.sha256
#      generated from that commit by scripts/gen-manifest.sh (it is never
#      committed, backend#2868).
#  Either way, every file this script uses from the tree is checked again against
#  the tree's manifest.sha256, and a tree that fails is refused by name. Nothing
#  here or in install.ps1 skips that check. The signature over the manifest is
#  install.ps1's to check, before it hands the tree over.
#
#  It fetches nothing unverified: the distro image is checked against its pinned
#  length and sha256 before `wsl --import`.
#
#  Exit codes, which install.ps1 passes through unchanged:
#    0  done
#    1  a named refusal or a failure, already explained on screen
#    2  a restart is needed first, then the same install command again
#       (install-k8s.ps1's declared "restart, then re-run" code)
#
#  The path stays behind TRACEBLOC_SUBSTRATE=k3s until 3.3's cell is green on it
#  (D14 item 9). Its steps land in the numbered sections below, one PR each
#  (client-dev#1810 part 1).
# =============================================================================
#Requires -Version 5.1
param([string]$CoreDir)

# Byte-identical to install.ps1's helpers; a Pester test holds them so.
function Info($m) { Write-Host "  " -NoNewline; Write-Host ([char]0x00B7) -ForegroundColor DarkGray -NoNewline; Write-Host " $m" -ForegroundColor DarkGray }
function Ok($m)   { Write-Host "  " -NoNewline; Write-Host ([char]0x2714) -ForegroundColor Green    -NoNewline; Write-Host " $m" }
function Warn($m) { Write-Host "  " -NoNewline; Write-Host ([char]0x26A0) -ForegroundColor Yellow   -NoNewline; Write-Host "  $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red      -NoNewline; Write-Host " $m" -ForegroundColor Red }

# Byte-identical to install.ps1's; a Pester test holds them so.
function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

function Find-ManifestDigest {
  param([string]$ManifestPath, [string]$Key)
  foreach ($line in Get-Content -LiteralPath $ManifestPath) {
    $parts = @($line -split '\s+' | Where-Object { $_ -ne '' })
    if ($parts.Count -ge 2 -and $parts[-1] -eq $Key) {
      return $parts[0].ToLower()
    }
  }
  return $null
}

# Byte-identical to install.ps1's: the bash core's scripts in a manifest, every
# scripts/*.sh key. The manifest is their list, so nothing here restates it.
function Get-CoreScriptKeys {
  param([string]$ManifestPath)
  $keys = @()
  foreach ($line in Get-Content -LiteralPath $ManifestPath) {
    $parts = @($line -split '\s+' | Where-Object { $_ -ne '' })
    if ($parts.Count -ge 2 -and $parts[-1] -cmatch '^scripts/[A-Za-z0-9._/-]+\.sh$' -and $parts[-1] -notmatch '\.\.') {
      $keys += $parts[-1]
    }
  }
  return $keys
}

# Byte-identical to install.ps1's: someone at this console can answer a prompt.
function Test-BootstrapCanPrompt {
  try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) }
  catch { return $false }
}

# What this script uses from -CoreDir, as manifest keys, beside the core's scripts
# (Get-CoreScriptKeys). This script is one of them: the tree it is handed must
# hold the same verified copy of it.
$CoreFiles = @('scripts/install-wsl.ps1')

# Refuses, by name, a -CoreDir it cannot verify against the manifest.sha256 in it:
# FILES and every core script that manifest lists.
function Confirm-CoreDir {
  param([string]$CoreDir, [string[]]$Files = $CoreFiles)
  if (-not $CoreDir) {
    throw "No installer tree was given (-CoreDir), so there is nothing verified to run."
  }
  if (-not (Test-Path -LiteralPath $CoreDir -PathType Container)) {
    throw "The installer tree $CoreDir does not exist."
  }
  $manifest = Join-Path $CoreDir 'manifest.sha256'
  if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw "$CoreDir is not a verified installer tree: it has no manifest.sha256, so nothing in it can be checked."
  }
  # The core this path runs in the distro, by the manifest's own list. A manifest
  # that lists none of it cannot vouch for what section 5 would run.
  $core = @(Get-CoreScriptKeys -ManifestPath $manifest)
  if ($core.Count -eq 0) {
    throw "$CoreDir is not a verified installer tree: its manifest.sha256 lists none of the installer's core scripts."
  }
  foreach ($f in @($Files) + $core) {
    $expected = Find-ManifestDigest -ManifestPath $manifest -Key $f
    if (-not $expected) {
      throw "$CoreDir is not a verified installer tree: its manifest.sha256 lists no $f."
    }
    $local = Join-Path $CoreDir ($f -replace '^scripts/', '')
    if (-not (Test-Path -LiteralPath $local -PathType Leaf)) {
      throw "$CoreDir is not a verified installer tree: $f is missing from it."
    }
    if ((Get-Sha256 -Path $local) -ne $expected) {
      throw "$CoreDir is not a verified installer tree: $f does not match its manifest.sha256 entry."
    }
  }
}

# =============================================================================
#  1. WSL ready (RFC-0175 D7)
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

# TODO(S-W row 1, backend#5416): the floor is RFC-0175 D7's, WSL 2.5 (cgroup v2
# by default). Row 1 records `wsl --version` on the managed laptop; set it here.
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
# restarting" codes (install-k8s.ps1's INSTALLER_REBOOT_OK_CODES has them too),
# not a measurement of wsl.exe. Any other non-zero code is a failure. A restart
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
# bounded by the 30 s a `wsl --version` gets. 300 s is the bound S-W's kit gives
# the distro to be running after a logon (backend#5416 rows 5c and 8), not a
# measured worst case: the VM measured 10 s, and the first start right after the
# import is unmeasured.
$WslDistroStartTimeoutSec = 300
# `wsl --manage --set-sparse` and `--resize` rewrite the distro's VHDX, and that
# work grows with the disk, so it is not bounded by the 30 s a `wsl --version`
# gets either: on a probe budget a slow disk timed out while wsl.exe kept going.
# 600 s is a bound, not a measured worst case (client-dev#2036).
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
# read as UTF-8, as WSL_UTF8=1 asks of both. -FilePath is a seam for the test suite.
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
  $r.Output = [string]$out.Result
  $r.ErrorOutput = [string]$err.Result
  return $r
}

# TODO(S-W row 2, backend#5470): the hook for an organisation's policy refusing
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
# Administrator). The same test as install-k8s.ps1's admin gate.
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
# entry should also re-run the installer after the restart, as install-k8s.ps1
# does; one would not carry TRACEBLOC_SUBSTRATE, so it waits for part 5's default.
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
    Ok "WSL $($w.Version) is ready ($MinVersion or newer)."
    return 'ready'
  }
  $enableArgs = if ($w.State -eq 'old') { $WslUpdateArgs } else { $WslInstallArgs }
  $cmd = 'wsl ' + ($enableArgs -join ' ')
  if ($w.State -eq 'blocked') {
    Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
    throw "Your organisation's device policy blocks WSL (wsl.exe) on this computer, so tracebloc cannot set up its Linux environment here. Ask your IT team to allow wsl.exe for your account, and to run this once in an administrator PowerShell: $cmd"
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
      Warn "Windows still needs the restart that finishes turning on WSL. $restartWords"
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
      throw "WSL is still not ready after $restarts restart(s): $($w.Why). $itLead $cmd"
    }
  }

  # WSL answers, but the platform under it waits for a restart: nothing to run, and
  # not ready until Windows has restarted. Stopped here, before anything is imported.
  if ($w.State -eq 'pending') {
    Write-WslResumeMarker -Path $MarkerPath -Restarts $restarts -EnableRan $enableRan
    Warn "Windows needs a restart to finish turning on WSL. $restartWords"
    return 'restart'
  }

  $elevated = Test-BootstrapElevated
  if (-not $elevated) {
    if (-not ((Test-BootstrapUserIsAdmin) -and (Test-BootstrapCanPrompt))) {
      throw "This computer needs WSL $MinVersion or newer, and only an administrator can turn it on ($($w.Why)). $itLead $cmd -- then run this installer again as yourself."
    }
    Info "Turning on WSL needs administrator rights once. Windows will ask you to allow it."
  }
  $r = Invoke-WslEnable -ArgumentList $enableArgs -Elevate:(-not $elevated)
  if ($r.State -eq 'declined') {
    throw "The administrator step that turns on WSL did not start ($($r.Detail)). Run this installer again and allow the Windows prompt, or ask your IT team to run this once in an administrator PowerShell: $cmd"
  }
  if ($r.State -eq 'timeout') {
    throw "The administrator step that turns on WSL did not finish within $([int]($WslEnableTimeoutSec / 60)) minutes. $itLead $cmd"
  }
  if ($WslEnableOkCodes -notcontains $r.ExitCode) {
    throw "Turning on WSL failed: $cmd exited $($r.ExitCode). $itLead $cmd"
  }

  if ($WslEnableRestartCodes -notcontains $r.ExitCode) {
    $w = Get-WslReadiness -MinVersion $MinVersion
    if ($w.State -eq 'ready') {
      Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
      Ok "WSL $($w.Version) is ready ($MinVersion or newer)."
      return 'ready'
    }
  }
  Write-WslResumeMarker -Path $MarkerPath -Restarts $restarts -EnableRan $true
  Warn "Windows needs a restart to finish turning on WSL. $restartWords"
  return 'restart'
}

# WSL's networking mode, read from the user's own .wslconfig (client-dev#1810, S-W's
# run of record, row 10; rfcs#241 decision 2): the distro runs on WSL's default NAT
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
    throw "The installer could not read your WSL settings file $Path ($($_.Exception.Message)), so it cannot tell whether WSL uses NAT networking, which the tracebloc WSL distro needs. Make sure your account can read the file, then run the install again. The installer does not change it."
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
      throw "Your WSL settings file $Path sets networkingMode=$value in its [wsl2] section. The tracebloc WSL distro needs WSL's NAT networking: with $value its cluster cannot download what it needs or start. This setting applies to all your WSL distros, so the installer does not change it. Set networkingMode=nat there, or remove the line, then run wsl --shutdown (it stops every running WSL distro) and run the install again."
    }
  }
}

# =============================================================================
#  2. The distro image: the WSL distro's root filesystem.
#
#  On Windows the core is to run inside our own WSL distro, imported from a root
#  filesystem that 3.1 (client-dev#1809) publishes to ghcr.io. Get-WslDistroImage
#  fetches it by its layer digest, and Confirm-WslDistroImage refuses it unless it is
#  exactly the bytes the release pins: the length first, which is cheap and names
#  a truncated or padded download, then the sha256. A refused file is deleted at
#  once, so no later step can import it by mistake.
#
#  NOTHING CALLS THESE YET. The pins are facts.env's WSL_ROOTFS_*, stamped below,
#  and Get-WslDistroImage takes them unless told otherwise. The distro path stays
#  behind the switch until 3.3 is green on it. Still to come, each waiting on the row of spike S-W
#  (backend#5416) that decides it:
#    TODO(S-W row 3): `wsl --import tracebloc "$env:LOCALAPPDATA\tracebloc\wsl"
#      <rootfs> --version 2` as the daily user, unelevated, after Confirm-WslDistroImage.
#    The per-user logon task that keeps the distro running is section 3's.
#    TODO(S-W rows 9 and 10): the proxy and the host's CA roots inside the distro.
#      The host-side fetch below honours HTTPS_PROXY like every bootstrap download.
#    TODO(S-W row 13): the GPU device the distro advertises.
#    TODO(part 5, after 3.3 is green): the PowerShell core's removal.
# =============================================================================

# The rootfs this release pins: facts.env's WSL_ROOTFS_*, stamped here by
# check-facts.sh (--write stamps them, --check holds them to facts.env). The sha256
# and the length are the one layer an install fetches and Confirm-WslDistroImage
# holds the file to; the digest is the manifest that lists that layer, the one cosign
# signed; the version is that manifest's tag. scripts/wsl-rootfs-pin.sh bump moves
# them, through facts.env, never here by hand.
$WSL_ROOTFS_IMAGE = "ghcr.io/tracebloc/wsl-distro"
$WSL_ROOTFS_SHA256 = "d064df6c5a12fc51e7403a3373b699b96ea79a6dc1edd5f6afeae0b020e91484"
$WSL_ROOTFS_BYTES = "126331555"
$WSL_ROOTFS_DIGEST = "sha256:1dc346742be2f798e99130c2bd85ef57a466e03b8561a3a204c38533c4d0826a"
$WSL_ROOTFS_VERSION = "ubuntu-24.04.5-20261001-v1.36.5-k3s1"

# The repository an image on ghcr.io names, or $null. Only ghcr.io: the anonymous
# token below is ghcr.io's. No tag or digest on the name (the digest is pinned on
# its own), and no '..'.
function ConvertTo-GhcrRepo {
  param([string]$Image)
  $m = [regex]::Match($Image, '^ghcr\.io/([a-z0-9][a-z0-9._-]*(?:/[a-z0-9][a-z0-9._-]*)+)$')
  if (-not $m.Success -or $m.Groups[1].Value -match '\.\.') { return $null }
  return $m.Groups[1].Value
}

# An anonymous pull token for ghcr.io/REPO, or $null. ghcr.io answers a blob
# request that carries none with 401, even for a public image. On $null,
# $script:GhcrTokenFailure says why, for the refusal: the HTTP status where there
# was an answer, or "no answer", then the error's own words. The installer asks
# the user to share its output with support, so a 429, a proxy's 407, a TLS
# failure and a name that does not resolve each read as themselves.
$script:GhcrTokenFailure = ''
function Get-GhcrPullToken {
  param([string]$Repo)
  $script:GhcrTokenFailure = ''
  $ProgressPreference = 'SilentlyContinue'
  $proxyArgs = @{}
  if ($env:HTTPS_PROXY) { $proxyArgs['Proxy'] = $env:HTTPS_PROXY }
  try {
    $answer = Invoke-RestMethod -Uri "https://ghcr.io/token?scope=repository:${Repo}:pull" -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop @proxyArgs
  } catch {
    # PS 5.1 (WebException) and 7 (HttpResponseException) both carry the
    # response's StatusCode; a network error carries no response at all.
    $code = 0
    try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
    $status = 'no answer'
    if ($code -gt 0) { $status = "HTTP $code" }
    $script:GhcrTokenFailure = "$status -- $($_.Exception.Message)"
    return $null
  }
  if ($answer -and $answer.token) { return [string]$answer.token }
  $script:GhcrTokenFailure = 'its answer held no token'
  return $null
}

# Receive-WslDistroImage's clock, one step: a liveness dot every $Clock.TickSeconds,
# and the stall bound. $false when under $Clock.StallBytes arrived in the last
# $Clock.StallSeconds (curl's --speed-limit 1024 --speed-time 60, the Mac kernel
# fetch's bound). A slow download that is still moving is never stopped (#468).
function Test-WslDownloadMoving {
  param([hashtable]$Clock)
  $now = Get-Date
  if (($now - $Clock.LastDot).TotalSeconds -ge $Clock.TickSeconds) {
    if (-not $Clock.Dotted) { Write-Host -NoNewline "  " }
    Write-Host -NoNewline "." -ForegroundColor DarkGray
    $Clock.Dotted = $true
    $Clock.LastDot = $now
  }
  if (($now - $Clock.WindowStart).TotalSeconds -ge $Clock.StallSeconds) {
    if ($Clock.Have - $Clock.WindowBytes -lt $Clock.StallBytes) { return $false }
    $Clock.WindowStart = $now
    $Clock.WindowBytes = $Clock.Have
  }
  return $true
}

# Wait for TASK, an HTTP answer or a read, under the clock. $false when the
# download stalled first. A task that failed throws here.
function Wait-WslDownloadTask {
  param($Task, [hashtable]$Clock)
  while (-not $Task.Wait(250)) {
    if (-not (Test-WslDownloadMoving -Clock $Clock)) { return $false }
  }
  return $true
}

# DEST, opened for writing only if it is not there yet. A function of its own so the
# tests can stand in a file whose close fails, as a full disk's does.
function Open-WslDownloadFile {
  param([string]$Path)
  return [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
}

# End one answer without reading what is left of its body: the request is aborted
# first, then the answer is closed, each guarded on its own. On Windows PowerShell
# 5.1 a Close() alone first reads the rest of the body, outside every bound here,
# so a redirect whose body never ends would never close. PowerShell 7 does not
# read it either way, so only the cases on this function can see the order.
function Close-WslDownloadAnswer {
  param($Request, $Answer)
  if ($Request) { try { $Request.Abort() } catch { } }
  if ($Answer) { try { $Answer.Close() } catch { } }
}

# Download URL to DEST with the pull token. It streams: each read goes to disk as
# it arrives, so both bounds are checked inside the read loop, on every read and on
# every wait, the same on Windows PowerShell 5.1 and on PowerShell 7. (5.1's
# Invoke-WebRequest -OutFile can hold the whole answer in memory until it ends,
# and a bound read off the file's length cannot see a download that is not on
# disk yet.)
#  - a stall, Test-WslDownloadMoving's bound, also while waiting for the answer;
#  - the length: DEST never holds more than the pin plus one byte, so an answer
#    that never ends cannot fill the disk or the memory, and the length refusal
#    names it.
# Returns $true when there is a file for Confirm-WslDistroImage to judge: the
# answer ended, or it passed the pin, which Confirm-WslDistroImage then refuses by
# its length. $false when the download failed or stalled, each named by Err.
# REDIRECTS ARE FOLLOWED HERE, NOT BY .NET: ghcr.io answers with a redirect to its
# blob storage, and the token goes on the first request only, so no redirect
# target ever sees it. At most $MaxRedirects of them. The TLS 1.2 floor is the
# process's own (Main sets it), and HTTPS_PROXY is honoured like every bootstrap
# download.
function Receive-WslDistroImage {
  param(
    [string]$Url,
    [string]$Token,
    [string]$Dest,
    [long]$MaxBytes,
    [int]$StallSeconds = 60,
    [long]$StallBytes = 61440,
    [int]$TickSeconds = 3,
    [int]$MaxRedirects = 5
  )
  $now = Get-Date
  $clock = @{
    Have = [long]0; WindowStart = $now; WindowBytes = [long]0; LastDot = $now; Dotted = $false
    StallSeconds = $StallSeconds; StallBytes = $StallBytes; TickSeconds = $TickSeconds
  }
  $outcome = 'failed'
  $why = ''
  $req = $null; $answer = $null; $body = $null; $file = $null
  try {
    $uri = [Uri]$Url
    for ($hop = 0; ; $hop++) {
      $req = [Net.HttpWebRequest]::Create($uri)
      $req.AllowAutoRedirect = $false
      $req.KeepAlive = $false
      if ($env:HTTPS_PROXY) { $req.Proxy = [Net.WebProxy]::new([string]$env:HTTPS_PROXY) }
      if ($hop -eq 0) { $req.Headers.Add('Authorization', "Bearer $Token") }
      $pending = $req.GetResponseAsync()
      if (-not (Wait-WslDownloadTask -Task $pending -Clock $clock)) { $outcome = 'stalled'; break }
      $answer = $pending.Result
      $code = [int]$answer.StatusCode
      if ($code -lt 300) { break }
      $location = $answer.Headers['Location']
      Close-WslDownloadAnswer -Request $req -Answer $answer
      $answer = $null
      if ($hop -ge $MaxRedirects) { $why = "more than $MaxRedirects redirects"; break }
      if (-not $location) { $why = "HTTP $code with no Location"; break }
      $uri = [Uri]::new($uri, $location)
    }
    if ($answer) {
      $body = $answer.GetResponseStream()
      $file = Open-WslDownloadFile -Path $Dest
      $buf = [byte[]]::new(65536)
      while ($true) {
        $pending = $body.ReadAsync($buf, 0, $buf.Length)
        if (-not (Wait-WslDownloadTask -Task $pending -Clock $clock)) { $outcome = 'stalled'; break }
        $n = [long]$pending.Result
        if ($n -le 0) { $outcome = 'finished'; break }
        $n = [Math]::Min($n, $MaxBytes + 1 - $clock.Have)
        $file.Write($buf, 0, [int]$n)
        $clock.Have += $n
        if ($clock.Have -gt $MaxBytes) { $outcome = 'past the pin'; break }
        if (-not (Test-WslDownloadMoving -Clock $clock)) { $outcome = 'stalled'; break }
      }
    }
  } catch {
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    $why = $e.Message
  } finally {
    # Each cleanup is guarded on its own: a throw from one would skip the rest and
    # replace the outcome, and the caller would never delete the partial DEST, so
    # the next run would refuse it as already there.
    # Abort ends the transfer outright, on both runtimes. Closing alone may first
    # read what is left of an answer that has not ended, and one that never ends
    # would then never close. PowerShell 7 does not wait either way, so no test
    # here sees this line fail; it is for 5.1.
    if ($outcome -ne 'finished' -and $req) { try { $req.Abort() } catch { } }
    # Closing DEST writes its last buffered bytes, so a full disk fails here. What
    # is on disk is then not the answer, so a download that ended is now a failed
    # one; any earlier failure keeps its own reason.
    if ($file) {
      try { $file.Dispose() } catch {
        if ($outcome -eq 'finished' -or $outcome -eq 'past the pin') {
          $e = $_.Exception
          while ($e.InnerException) { $e = $e.InnerException }
          $outcome = 'failed'
          $why = $e.Message
        }
      }
    }
    if ($body) { try { $body.Dispose() } catch { } }
    if ($answer) { try { $answer.Close() } catch { } }
  }
  if ($clock.Dotted) { Write-Host "" }
  if ($outcome -eq 'finished' -or $outcome -eq 'past the pin') { return $true }
  if ($outcome -eq 'stalled') {
    Err "The WSL distro image download stalled (under $StallBytes bytes in ${StallSeconds}s) -- giving up: $Url"
  } else {
    Err "The WSL distro image download failed ($why): $Url"
  }
  return $false
}

# Refuse a WSL distro image that is not exactly the pinned bytes, each by name: no
# file, a length other than the pin, a sha256 other than the pin. The length is
# read first, so a truncated or padded file is named as such and never hashed. A
# file refused for either is deleted before the refusal is thrown.
function Confirm-WslDistroImage {
  param(
    [string]$Path,
    [string]$Sha256,
    [long]$Bytes
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "The WSL distro image did not download, so there is nothing to import. Check that this machine can reach ghcr.io and pkg-containers.githubusercontent.com, then re-run."
  }
  $have = (Get-Item -LiteralPath $Path).Length
  $why = ''
  if ($have -ne $Bytes) {
    $why = "The WSL distro image is $have bytes, but this release pins $Bytes"
  } elseif ((Get-Sha256 -Path $Path) -ne $Sha256) {
    $why = "The WSL distro image does not match its pinned sha256 ($Sha256)"
  }
  if ($why) {
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $fate = 'it was deleted'
    if (Test-Path -LiteralPath $Path) { $fate = "it could not be deleted: delete $Path yourself" }
    throw "$why, so it was not imported and $fate. Something between this machine and ghcr.io changed the download; re-run on a network that does not rewrite downloads."
  }
}

# THE DISTRO'S DISK (S-W row 11, backend#5416). An imported distro's VHDX gets
# WSL's default virtual size, about 1 TiB, and the node's capacity is that, not
# what the host has. On S-W's machine the node reported 1,055,762,868 KiB while C:
# had 110 GB free, so kubelet's eviction (at 5 % of capacity free) could never
# fire before C: filled. The VHDX also grew by the 5 GiB written and did not
# shrink after the delete. So, right after `wsl --import` and BEFORE the distro
# first starts, Set-WslDistroDisk:
#   1. makes the VHDX sparse, so that blocks the distro frees go back to the host;
#   2. caps its virtual size at Get-WslDistroDiskCap's answer, so that the node's
#      capacity is what the host can give it, and eviction fires first.
# Both come before the first start: once the VHD is attached, --set-sparse fails
# with ERROR_SHARING_VIOLATION until `wsl --shutdown`, which would stop every
# distro the user has (row 11). Measured on S-W's STOCK ubuntu-noble-wsl 20240423
# image; the VHDX is WSL's, not the image's, so ours is the same.
# NOT MEASURED YET: `--resize` itself (row 11 never ran it), and a sparse VHDX
# giving space back. 3.3's distro cell runs both.
# SPARSE IS BEST EFFORT, AND ONLY FOR ONE REFUSAL (client-dev#1810, S-W's run of
# record, 13 Oct, row 11): WSL 2.7.11 refused --set-sparse by policy ("Sparse VHD
# support is currently disabled due to potential data corruption", exit -1,
# Wsl/Service/E_INVALIDARG). For those words alone the install says so and goes on
# to the cap: the cap is what keeps the node off a full drive; sparse only gives
# freed space back. --allow-unsafe, which those words offer, is never passed. Every
# other sparse failure still stops the install, and the cap stays mandatory.
# THE ORDER: the import step calls Set-WslDistroDisk between `wsl --import` and the
# logon task's first run (S-W row 5), because the task starts the distro and
# --set-sparse is refused from then on. Set-WslDistroDisk holds that itself: a
# distro `wsl --list --running` names is refused by name before any --manage step,
# and a sparse step WSL refuses for a disk still attached (ERROR_SHARING_VIOLATION,
# after a start and a --terminate) is refused too, never retried: only
# `wsl --shutdown` frees it, and that stops every distro the user has. On either
# refusal the import step unregisters the distro it just imported, so a re-run
# imports it afresh instead of taking the re-run path over a disk never capped.
# A RE-RUN over a distro that is already there calls Update-WslDistroDisk instead:
# it re-derives the cap and only GROWS the disk to it. The distro's own growth
# takes the host's free space, so a re-run often derives a smaller cap, and
# --resize is never asked to shrink a disk below the size it has. A re-run never
# fails on the disk: a size it cannot read, a smaller cap, or a growth wsl.exe
# refuses (the VHD stays attached while the distro runs, row 11) each leave the
# cap the import set, and say so.
# NOT MEASURED YET either: whether WSL's "GB" in --resize is 1024^3 bytes, as
# PowerShell's 1GB is (a re-run compares the two).
# NOTHING CALLS THESE YET: they follow the import, TODO(S-W row 3) above.

# The free space the cap leaves on the host's drive, and the smallest cap worth
# installing on, in GB: preflight.sh's PF_WARN_DISK_GB and PF_MIN_DISK_GB, the
# floors the core already holds a node's disk to. install-wsl.Tests.ps1 reads both
# defaults from preflight.sh and holds these to them.
$WslDiskReserveGb = 20
$WslDiskMinGb = 10

# WSL's refusal of --set-sparse by policy, as wsl.exe 2.7.11 printed it on the
# managed laptop (S-W's log, row 11), its four lines joined by one space as
# Set-WslDistroDisk joins what wsl.exe said. Only these exact words make the
# sparse step best effort.
$WslSparsePolicyRefusal = 'Sparse VHD support is currently disabled due to potential data corruption. To force a distribution to use a sparse VHD, please run: wsl.exe --manage <DistributionName> --set-sparse true --allow-unsafe Error code: Wsl/Service/E_INVALIDARG'

# The drive that holds PATH (its root, C:\ on Windows), or PATH itself when that
# cannot be told. What the refusals name.
function Get-WslDiskDrive {
  param([string]$Path)
  try {
    return [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
  } catch {
    return $Path
  }
}

# The bytes free to this user on the drive that holds PATH, or $null when that
# cannot be read. The tests' seam.
function Get-WslDiskFreeSpace {
  param([string]$Path)
  try {
    return [long]([System.IO.DriveInfo]::new((Get-WslDiskDrive -Path $Path)).AvailableFreeSpace)
  } catch {
    return $null
  }
}

# FREE bytes as a cap in whole GB: rounded down, less the reserve. The one sum
# both the import's cap and a re-run's growth make.
function ConvertTo-WslDiskCapGb {
  param([long]$Free, [int]$ReserveGb = $WslDiskReserveGb)
  $freeGb = [long][math]::Floor($Free / 1GB)
  $cap = $freeGb - $ReserveGb
  return $cap
}

# The distro VHDX's cap in whole GB: what is free on the drive that holds PATH,
# rounded down, less the reserve. Throws, by name, when the free space cannot be
# read, or when what is left is under the smallest cap worth installing on. The
# refusal is preflight.sh's disk refusal, in ASCII, for that drive and this floor
# (the reserve plus the smallest cap); install-wsl.Tests.ps1 holds it to those words.
function Get-WslDistroDiskCap {
  param(
    [string]$Path,
    [int]$ReserveGb = $WslDiskReserveGb,
    [int]$MinGb = $WslDiskMinGb
  )
  $drive = Get-WslDiskDrive -Path $Path
  $free = Get-WslDiskFreeSpace -Path $Path
  if ($null -eq $free) {
    throw "Disk: could not read how much space is free on $drive, so the WSL distro's disk cannot be sized. Check that the drive is there and readable, then re-run."
  }
  $cap = ConvertTo-WslDiskCapGb -Free $free -ReserveGb $ReserveGb
  if ($cap -lt $MinGb) {
    throw "Disk: only $($cap + $ReserveGb) GB free on $drive - need >= $($ReserveGb + $MinGb) GB ($ReserveGb GB left to Windows, and at least $MinGb GB for tracebloc's WSL distro). Free up space or attach a larger disk, then re-run."
  }
  return $cap
}

# Whether `wsl --list --running` names DISTRO: $true only when a line of its answer
# is exactly the name. Anything else, a list that cannot be read included, is
# $false here: Set-WslDistroDisk's sparse step is then the check that decides, as
# WSL refuses it for a disk that is attached.
function Test-WslDistroRunning {
  param([string]$Distro = $WslDistroName, [string]$FilePath = 'wsl.exe')
  $l = Invoke-WslProbe -FilePath $FilePath -ArgumentList @('--list', '--running', '--quiet')
  if (-not $l.Started -or $l.TimedOut) { return $false }
  foreach ($line in ($l.Output -replace "`0", '') -split "`r?`n") {
    if ($line.Trim() -ceq $Distro) { return $true }
  }
  return $false
}

# Make DISTRO's VHDX sparse, then cap its virtual size at CAPGB, through wsl.exe.
# Runs right after `wsl --import`, before the distro first starts (THE ORDER,
# above): a distro that already runs is refused by name before any step. A step
# that does not run cleanly throws, by name, with what wsl.exe said, and the cap
# never runs after a failed sparse step: an uncapped distro is the 1 TiB one row
# 11 measured. The one exception is WSL's policy refusal of sparse disks
# ($WslSparsePolicyRefusal): that is said, and the cap still runs.
function Set-WslDistroDisk {
  param(
    [long]$CapGb,
    [string]$Distro = $WslDistroName,
    [string]$FilePath = 'wsl.exe'
  )
  if ($CapGb -le 0) {
    throw "The WSL distro's disk cap ($CapGb GB) is not a positive size, so the disk was not set. Tell tracebloc support."
  }
  if (Test-WslDistroRunning -Distro $Distro -FilePath $FilePath) {
    throw "The WSL distro $Distro is already running, so its disk can no longer be made sparse and capped: that has to happen after its import and before its first start. Nothing was changed, and nothing is retried. Re-run the install; if it says this again, tell tracebloc support."
  }
  $steps = @(
    @{ What = 'made sparse'; Sparse = $true; Arguments = @('--manage', $Distro, '--set-sparse', 'true') },
    @{ What = "capped at $CapGb GB"; Sparse = $false; Arguments = @('--manage', $Distro, '--resize', "$($CapGb)GB") }
  )
  $sparse = $true
  foreach ($s in $steps) {
    $cmd = "wsl $($s.Arguments -join ' ')"
    $r = Invoke-WslProbe -FilePath $FilePath -ArgumentList $s.Arguments -TimeoutSec $WslDiskTimeoutSec
    if (-not $r.Started) {
      throw "$cmd did not start ($($r.StartError)), so the WSL distro's disk was not $($s.What). Re-run; if it says this again, tell tracebloc support."
    }
    if ($r.TimedOut) {
      throw "$cmd did not finish within $WslDiskTimeoutSec s, so the WSL distro's disk was not $($s.What). Re-run; if it says this again, tell tracebloc support."
    }
    if ($r.ExitCode -ne 0) {
      $said = ("$($r.Output) $($r.ErrorOutput)" -replace "`0", '' -replace '\s+', ' ').Trim()
      if ($s.Sparse -and $said.Contains($WslSparsePolicyRefusal)) {
        # Its words are not echoed: they offer --allow-unsafe, which nothing here runs.
        Warn "WSL has turned sparse disks off on this computer ($cmd exited $($r.ExitCode)), so the tracebloc WSL distro's disk will not give the space it frees back to Windows. Its size is still capped."
        $sparse = $false
        continue
      }
      $order = ''
      if ($said -match 'ERROR_SHARING_VIOLATION') { $order = " Its disk is attached: the distro has started since its import, and only a first start may follow the disk steps." }
      throw "$cmd failed (exit $($r.ExitCode)): $said The WSL distro's disk was not $($s.What), and an uncapped distro can fill this drive.$order Re-run; if it says this again, tell tracebloc support."
    }
  }
  if ($sparse) { Ok "WSL distro disk: sparse, and capped at $CapGb GB" } else { Ok "WSL distro disk: capped at $CapGb GB" }
}

# The virtual size in bytes of the VHDX at PATH, read from the file's own metadata,
# or $null when it cannot be read: no file, not a VHDX, or one WSL holds open.
# Never a guess. The VHDX format: the file identifier at 0, the region table at
# 192 KiB names the metadata region, and the metadata table there names the
# Virtual Disk Size item, a UINT64.
function Get-WslVhdxVirtualSize {
  param([string]$Path)
  $metadataRegion = [guid]'8b7ca206-4790-4b9a-b8fe-575f050f886e'
  $virtualDiskSize = [guid]'2fa54224-cd1b-4876-b211-5dbed83bf4b8'
  $fs = $null
  try {
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $r = [System.IO.BinaryReader]::new($fs)
    $ascii = [System.Text.Encoding]::ASCII
    if ($ascii.GetString($r.ReadBytes(8)) -ne 'vhdxfile') { return $null }
    $fs.Position = 192KB
    if ($ascii.GetString($r.ReadBytes(4)) -ne 'regi') { return $null }
    [void]$r.ReadUInt32()
    $regions = $r.ReadUInt32()
    [void]$r.ReadUInt32()
    if ($regions -gt 2047) { return $null }
    $at = $null
    for ($i = 0; $i -lt $regions; $i++) {
      $id = [guid]::new($r.ReadBytes(16))
      $offset = $r.ReadUInt64()
      [void]$r.ReadBytes(8)
      if ($id -eq $metadataRegion) { $at = [long]$offset }
    }
    if ($null -eq $at) { return $null }
    $fs.Position = $at
    if ($ascii.GetString($r.ReadBytes(8)) -ne 'metadata') { return $null }
    [void]$r.ReadUInt16()
    $items = $r.ReadUInt16()
    [void]$r.ReadBytes(20)
    for ($i = 0; $i -lt $items; $i++) {
      $id = [guid]::new($r.ReadBytes(16))
      $offset = $r.ReadUInt32()
      [void]$r.ReadBytes(12)
      if ($id -eq $virtualDiskSize) {
        $fs.Position = $at + $offset
        $size = $r.ReadUInt64()
        if ($size -gt 0) { return [long]$size }
        return $null
      }
    }
    return $null
  } catch {
    return $null
  } finally {
    if ($fs) { $fs.Dispose() }
  }
}

# A re-run over a distro that is already there: re-derive the cap from the host's
# free space and only GROW the disk to it (see THE DISTRO'S DISK above). PATH is
# the import directory, VHDX the disk WSL made there. Never throws: what it cannot
# do leaves the disk at the cap it has, and says so.
function Update-WslDistroDisk {
  param(
    [string]$Path,
    [string]$Vhdx = [System.IO.Path]::Combine($Path, 'ext4.vhdx'),
    [int]$ReserveGb = $WslDiskReserveGb,
    [string]$Distro = $WslDistroName,
    [string]$FilePath = 'wsl.exe'
  )
  $size = Get-WslVhdxVirtualSize -Path $Vhdx
  if ($null -eq $size) {
    Warn "Could not read the WSL distro's disk size from $Vhdx, so its cap is left as it is."
    return
  }
  $nowGb = [long][math]::Floor($size / 1GB)
  $hostFree = Get-WslDiskFreeSpace -Path $Path
  if ($null -eq $hostFree) {
    Warn "Disk: could not read how much space is free on $(Get-WslDiskDrive -Path $Path), so the WSL distro's disk stays capped at $nowGb GB."
    return
  }
  $want = ConvertTo-WslDiskCapGb -Free $hostFree -ReserveGb $ReserveGb
  if ($want -le $nowGb) {
    Ok "WSL distro disk: kept at $nowGb GB (the host's free space now gives $want GB, and a cap is never shrunk)"
    return
  }
  $grow = @('--manage', $Distro, '--resize', "$($want)GB")
  $g = Invoke-WslProbe -FilePath $FilePath -ArgumentList $grow -TimeoutSec $WslDiskTimeoutSec
  if ($g.Started -and -not $g.TimedOut -and $g.ExitCode -eq 0) {
    Ok "WSL distro disk: grown from $nowGb GB to $want GB"
    return
  }
  $why = "exit $($g.ExitCode): $(("$($g.Output) $($g.ErrorOutput)" -replace "`0", '' -replace '\s+', ' ').Trim())"
  if (-not $g.Started) { $why = "did not start: $($g.StartError)" }
  elseif ($g.TimedOut) { $why = "did not finish within $WslDiskTimeoutSec s" }
  Warn "wsl $($grow -join ' ') did not grow the WSL distro's disk ($why), so it stays capped at $nowGb GB."
}

# Fetch the WSL distro's root filesystem from ghcr.io into DEST by its pinned
# layer digest, and confirm it. Returns DEST, or throws a refusal that names what
# was wrong. The pins are the release's stamped WSL_ROOTFS_* unless passed. They
# are checked for shape first: a pin this cannot use is a broken release, refused
# before anything is downloaded. A download that failed part way leaves no file
# behind, so it is refused as missing, not as tampered.
function Get-WslDistroImage {
  param(
    [string]$Image = $WSL_ROOTFS_IMAGE,
    [string]$Sha256 = $WSL_ROOTFS_SHA256,
    [long]$Bytes = $WSL_ROOTFS_BYTES,
    [string]$Version = $WSL_ROOTFS_VERSION,
    [string]$Digest = $WSL_ROOTFS_DIGEST,
    [string]$Dest
  )
  $repo = ConvertTo-GhcrRepo -Image $Image
  if (-not $repo) {
    throw "This installer's WSL distro image '$Image' is not an image on ghcr.io, so nothing was downloaded. The release itself is broken: tell tracebloc support."
  }
  if ($Sha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw "This installer's WSL distro sha256 '$Sha256' is not 64 lowercase hex digits, so nothing was downloaded. The release itself is broken: tell tracebloc support."
  }
  if ($Bytes -le 0) {
    throw "This installer's WSL distro length ($Bytes bytes) is not a positive number, so nothing was downloaded. The release itself is broken: tell tracebloc support."
  }
  if (Test-Path -LiteralPath $Dest) {
    throw "$Dest already exists -- refusing to download the WSL distro image over it."
  }
  $token = Get-GhcrPullToken -Repo $repo
  if (-not $token) {
    throw "ghcr.io gave no pull token for $Image ($($script:GhcrTokenFailure)). Check that this machine can reach ghcr.io, then re-run."
  }
  Info "Downloading the WSL distro image $Version ($([math]::Round($Bytes / 1MB)) MB) from $Image..."
  $fetched = Receive-WslDistroImage -Url "https://ghcr.io/v2/$repo/blobs/sha256:$Sha256" -Token $token -Dest $Dest -MaxBytes $Bytes
  if (-not $fetched) { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue }
  Confirm-WslDistroImage -Path $Dest -Sha256 $Sha256 -Bytes $Bytes
  Ok "WSL distro image $Version verified against its pinned length and sha256 (the layer of $Image@$Digest)"
  return $Dest
}

# =============================================================================
#  3. The logon task: what keeps the distro running.
#
#  WSL stops a distro seconds after its last wsl.exe exits, and k3s with it (S-W
#  row 5a). A task of the daily user's own, at their logon, holds one wsl.exe open
#  in the distro for the session: `sleep infinity`, started by a launcher that
#  shows no window. It is S-W row 5b's block (backend#5416's kit), the launcher
#  that row chose, registered unelevated at the Task Scheduler root as
#  tracebloc-keepalive, which the install record names \tracebloc-keepalive.
#
#  It waits only for the distro to run. k3s Ready is the core's own wait, in its
#  cluster run: a distro restart has measured 191 s to Ready (backend#5471), so no
#  wait here may stand in for that one.
#
#  PROVISIONAL until rows 6-8 (idle, sleep, restart) hold on both S-W machines,
#  Windows 11 and Server 2025. NOTHING CALLS THIS YET: it follows the import
#  (section 2, S-W row 3).
#    TODO(part 4): the install record's logon-task artefact, once cli-dev's
#      `delete` knows the kind.
#    TODO(part 5): the task's removal.
# =============================================================================

$KeepaliveTaskName = 'tracebloc-keepalive'
$KeepaliveTaskId = "\$KeepaliveTaskName"
$KeepaliveStartTimeoutSec = 60

# THE LAUNCHER, named here and nowhere else: a program under %WINDIR% and its
# arguments, put in front of wsl.exe. conhost --headless runs it with no console
# window (S-W row 5b, backend#5471, Windows 11); wsl.exe started directly showed
# one. @() starts wsl.exe directly.
$KeepaliveLauncher = @('System32\conhost.exe', '--headless')

# What the logon task runs: the launcher, then wsl.exe holding the distro open.
function Get-KeepaliveAction {
  $wsl = "$env:WINDIR\System32\wsl.exe"
  $hold = "-d $WslDistroName --exec /bin/sleep infinity"
  if (@($KeepaliveLauncher).Count -eq 0) { return [pscustomobject]@{ Execute = $wsl; Argument = $hold } }
  return [pscustomobject]@{ Execute = "$env:WINDIR\$($KeepaliveLauncher[0])"; Argument = "$($KeepaliveLauncher[1]) $wsl $hold" }
}

# The account the task runs as, as Windows names it: a seam, since the test
# suite's .NET has no Windows identity.
function Get-BootstrapIdentityName { return [Security.Principal.WindowsIdentity]::GetCurrent().Name }

# The task's state and last result, for a refusal.
function Get-KeepaliveTaskState {
  $t = Get-ScheduledTask -TaskName $KeepaliveTaskName -ErrorAction SilentlyContinue
  if (-not $t) { return 'not registered' }
  $i = $t | Get-ScheduledTaskInfo
  return ('{0}, last result 0x{1:X8}' -f $t.State, [int64]$i.LastTaskResult)
}

# Registers the logon task for the user running this bootstrap, unelevated, and
# starts it now, so the distro runs before the core does. Re-registering replaces
# it. Refuses when the task cannot be registered or started, or when the distro
# has not started from it within TIMEOUTSEC.
function Register-KeepaliveTask {
  param([int]$TimeoutSec = $KeepaliveStartTimeoutSec)
  $act = Get-KeepaliveAction
  $a = New-ScheduledTaskAction -Execute $act.Execute -Argument $act.Argument
  $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0 -Hidden
  try {
    # The issue's form first, then the account as Windows names it (the kit's order).
    # A trigger only stores the name: Register-ScheduledTask resolves it, so a name
    # the scheduler refuses throws there, and the next one is tried. The last one's
    # refusal is the one named.
    $users = @("$env:USERDOMAIN\$env:USERNAME", (Get-BootstrapIdentityName))
    for ($i = 0; $i -lt $users.Count; $i++) {
      $t = New-ScheduledTaskTrigger -AtLogOn -User $users[$i]
      try {
        Register-ScheduledTask -TaskName $KeepaliveTaskName -Action $a -Trigger $t -Settings $s -Force -ErrorAction Stop | Out-Null
        break
      } catch {
        if ($i -eq $users.Count - 1) { throw }
      }
    }
    Start-ScheduledTask -TaskName $KeepaliveTaskName -ErrorAction Stop
  } catch {
    throw "The logon task that keeps the tracebloc WSL distro running could not be set up for this user ($($_.Exception.Message)). Run this installer again."
  }
  # Two clocks, as the core's waits keep them: the seconds slept, so a stubbed
  # sleep still ends it, and the wall clock, since each probe takes time too.
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $slept = 0
  while (-not (Test-WslDistroRunning)) {
    if ($slept -ge $TimeoutSec -or (Get-Date) -ge $deadline) {
      throw "The tracebloc WSL distro did not start from its logon task within $TimeoutSec seconds (the task: $(Get-KeepaliveTaskState)). Run this installer again."
    }
    Start-Sleep -Seconds 1
    $slept++
  }
  Ok "The tracebloc WSL distro runs, and starts again at each sign-in."
}

# =============================================================================
#  4. The host GPU check.
#
#  On the distro path the core runs inside WSL, but nvidia-smi.exe, the driver and
#  the GPUs Windows lists live on the Windows host, so the GPU check stays here
#  (RFC-0175 D2, W21). These are install-k8s.ps1's Find-Gpu, Confirm-NvidiaDriver
#  and Get-NvidiaFloorVerdict with everything they call, COPIED UNCHANGED:
#  install-k8s.ps1 runs as a separate process and calls its own copies, so the
#  originals stay until part 5 deletes the PowerShell core. Until then
#  install-wsl.Tests.ps1 holds every copied function, and every top-level variable
#  they read, byte-for-byte equal to install-k8s.ps1's (the set is derived from
#  install-k8s.ps1, never listed). Info, Ok and Warn are this file's own output
#  helpers, which print the same lines without the log.
#
#  Invoke-WslCore calls Find-Gpu before the core's first run, so both runs carry its
#  answer. The distro path itself stays behind the switch until 3.3 is green on it.
#  The floors: check-facts.sh stamps them from facts.env, here as in
#  install-k8s.ps1, and the parity test holds the two copies equal.
#  The words (W17, W21): below the floor it warns and keeps the GPU; below the hard
#  floor or compute capability 7.5 it runs CPU-only. Every line those branches say
#  is the core's own (detect-gpu.sh's _nvidia_gpu_floor_gate), a Pester case holds
#  them so, with the dash written " -- " in these ASCII files.
#    TODO(S-W row 14): the driver floor stays 570.65 until row 14 measures it.
#  The handover: inside the distro nvidia-smi answers for this Windows driver, whose
#  number the Linux floors must never judge. So Confirm-NvidiaDriver records its
#  verdict ($GPU_FLOOR_VERDICT), and both core runs carry it and the GPU_UNSUPPORTED_*
#  values on their line (New-CoreRunArguments). The core takes them as given
#  (detect-gpu.sh, _nvidia_gpu_wsl_verdict), and reads an empty or unknown verdict as
#  cannot tell: CPU-only. The words a verdict can be are declared once, as
#  detect-gpu.sh's _NVIDIA_GPU_FLOOR_VERDICTS, and a Pester case holds
#  Get-NvidiaFloorVerdict's returns to them.
#  Find-Gpu's own reports, a GPU that is not NVIDIA (not_nvidia) and an NVIDIA GPU on
#  arm64 (arch_unsupported), go on the same line as GPU_UNSUPPORTED_*, with no
#  verdict. In the distro, where WSL shows no PCI device, the core takes them from
#  there (detect-gpu.sh, _gpu_wsl_host_report).
#    TODO(S-W row 13): the device half, the capacity patch or the plugin's WSL
#      mode, is the core's (detect-gpu.sh, part 3), and takes only that verdict
#      from here: the host never advertises a GPU itself.
# =============================================================================

# The verdict's state, as Confirm-NvidiaDriver leaves it.
$NVIDIA_DRIVER_OK = $false
$GPU_SKIP_REASON  = ""
$GPU_UNSUPPORTED_REASON = ""
$GPU_UNSUPPORTED_NAME   = ""
$GPU_UNSUPPORTED_CODE   = ""
$GPU_FLOOR_VERDICT      = ""
$NVIDIA_GPU_NAMES       = ""
$NVIDIA_DRIVER_VERSION = ""

# The NVIDIA GPU floors (scripts/spec/facts.env NVIDIA_DRIVER_FLOOR_WINDOWS /
# NVIDIA_COMPUTE_CAP_FLOOR / NVIDIA_DRIVER_HARD_FLOOR_WINDOWS), and the pre-Turing
# families by name. Policy, so no TRACEBLOC_* override.
$NVIDIA_DRIVER_FLOOR = "570.65"
$NVIDIA_COMPUTE_CAP_FLOOR = "7.5"
$NVIDIA_DRIVER_HARD_FLOOR = "528.33"
$NVIDIA_PRE_TURING_NAME_RE = ' (GT|GTS) [0-9]{3,4}[A-Z]* | GTX [4-9][0-9]{2}[A-Z]* | GTX 10[0-9]{2}[A-Z]* | GTX TITAN | TITAN (X|XP|V|Z|BLACK) | MX[1-3][0-9]{2} | GEFORCE [6-9][0-9]{2}(M|MX|A) | QUADRO (K|M|G?P|GV)[0-9]+[A-Z]* | NVS [0-9]{3} | (TESLA|GRID) [KMPV][0-9]+[A-Z]* | (K80|K40M?|K20X?M?|M60|M40|M10|P100|P40|P6|P4|V100S?) '

# The vendor Find-Gpu found: none, nvidia, amd, or nvidia_unsupported and
# amd_unsupported for a GPU it leaves off.
$GPU_VENDOR       = "none"
# The vendors whose GPU counts as "a GPU, but not NVIDIA", matched against the NORMALISED name
# (ConvertTo-GpuNormalisedName). An allowlist, so a virtual or BMC display adapter (Hyper-V,
# VMware SVGA, ASPEED, Matrox, Parsec, Citrix) still reads as "no GPU". Intel counts, the
# integrated GPU included. detect-gpu.sh carries the SAME strings (detect-gpu.bats holds them equal).
$GPU_NOT_NVIDIA_VENDOR_RE   = ' (AMD|ATI|RADEON|ADVANCED MICRO DEVICES|INTEL|APPLE) '
$GPU_NOT_NVIDIA_DISCRETE_RE = ' (AMD|ATI|RADEON|ADVANCED MICRO DEVICES|APPLE) '

# The log line (no-op here: this script keeps no log file) and the dim hint line.
function Log($m)           { if ($script:LOG_FILE) { Add-Content -Path $script:LOG_FILE -Value "[$(Get-Date -Format 'HH:mm:ss')] $m" -Encoding UTF8 -ErrorAction SilentlyContinue } }
function Hint($m)          { Write-Host "  $m" -ForegroundColor DarkGray; Log $m }

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
  if ($drv -lt $df) { return "below-driver" }
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
    # -StdoutOnly on BOTH queries (Bugbot on client-dev#1447): the verdict reads every line
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
    $script:NVIDIA_DRIVER_VERSION = $driverVer   # quoted back in a GPU-skip reason (#616)
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
    # compute_cap (client-dev#1631). A failed query is no name, never a guess.
    $nr = Invoke-BoundedProcess -FileName $nvSmi -Arguments @("--query-gpu=name","--format=csv,noheader") -TimeoutSec 15 -StdoutOnly
    $nameOut = if ($nr.Code -eq 0) { [string]$nr.Output } else { "" }
    $verdict = Get-NvidiaFloorVerdict -DriverOutput ([string]$dr.Output) -CapOutput $capOut -DriverFloor $NVIDIA_DRIVER_FLOOR -CapFloor $NVIDIA_COMPUTE_CAP_FLOOR -HardFloor $NVIDIA_DRIVER_HARD_FLOOR -NameOutput $nameOut
    $script:GPU_UNSUPPORTED_REASON = ""; $script:GPU_UNSUPPORTED_NAME = ""
    $script:GPU_UNSUPPORTED_CODE = ""
    # The bash twin's TB_GPU_FLOOR_VERDICT. install-wsl.ps1 hands it to the core in WSL.
    $script:GPU_FLOOR_VERDICT = $verdict
    $script:NVIDIA_GPU_NAMES = $nameOut
    Log "GPU floor: $verdict (driver $driverVer, floor $NVIDIA_DRIVER_FLOOR, hard floor $NVIDIA_DRIVER_HARD_FLOOR; compute capability $capVer, floor $NVIDIA_COMPUTE_CAP_FLOOR)"
    if ($verdict -eq "ok" -or $verdict -eq "below-driver") {
      if ($verdict -eq "below-driver") {
        # A warning, not a skip (Lukas, 2026-09-30, client-dev#1355): the images admit
        # older drivers on datacenter cards, so the GPU stays on. Confirm-DockerGpu still
        # probes it, and a driver too old for the image fails there, with a reason.
        # A driver too old to answer compute_cap: the card itself could not be checked either.
        if ($capVer -eq "unknown") {
          Warn "NVIDIA driver $driverVer is older than $NVIDIA_DRIVER_FLOOR, the driver tracebloc recommends for GPU training, and it cannot report this GPU's compute capability -- continuing with the GPU, but it may not work until the driver is upgraded."
        } else {
          Warn "NVIDIA driver $driverVer is older than $NVIDIA_DRIVER_FLOOR, the driver tracebloc recommends for GPU training -- continuing with the GPU; if GPU training fails on this machine, upgrade the driver."
        }
        Hint "To upgrade: install NVIDIA driver $NVIDIA_DRIVER_FLOOR or newer (https://www.nvidia.com/Download/index.aspx), reboot, then re-run the installer."
      }
      $script:NVIDIA_DRIVER_OK = $true
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
    } elseif ($verdict -eq "below-compute") {
      $oldName = Get-NvidiaPreTuringName $nameOut
      if ($capVer -eq "unknown" -and $oldName) {
        # Classified by name: the driver could not report the compute capability
        # (client-dev#1631), so the card is named instead of a number.
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
      # Below the CUDA 12 minimum the images' torch cannot initialise CUDA at all, so the
      # GPU would be advertised and unusable (client-dev#1632).
      $script:GPU_SKIP_REASON = "NVIDIA driver $driverVer is older than $NVIDIA_DRIVER_HARD_FLOOR, the oldest driver tracebloc's GPU images can use (CUDA 12) -- running CPU-only"
      Warn "NVIDIA driver $driverVer is older than $NVIDIA_DRIVER_HARD_FLOOR, the oldest driver tracebloc's GPU images can use (CUDA 12) -- this machine will run in CPU mode."
      $script:GPU_UNSUPPORTED_REASON = "The NVIDIA driver on this machine ($driverVer) is older than $NVIDIA_DRIVER_HARD_FLOOR, the oldest driver tracebloc's GPU training images can use, so this machine runs on CPU until the driver is updated."
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

# Get-GpuNotNvidiaName -- pure twin of detect-gpu.sh's _gpu_not_nvidia_name (backend#5296):
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
# linux/amd64 only (client-dev#1698). Reads the environment, never Err: an unknown value is
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
    # is an NVIDIA machine (backend#5296), never judged by whichever adapter came first.
    $nv = @($gpus | Where-Object { $_.Name -match "NVIDIA" })
    $amd = @($gpus | Where-Object { $_.Name -match "AMD|Radeon" })
    if ($nv.Count -gt 0) {
      $script:GPU_VENDOR = "nvidia"; Ok "NVIDIA GPU detected: $($nv[0].Name)"
    } elseif ($amd.Count -gt 0) {
      $script:GPU_VENDOR = "amd"; Ok "AMD GPU detected: $($amd[0].Name)"
    }
    # A GPU that is not NVIDIA (AMD, or Intel -- the integrated one included) is a GPU this
    # machine cannot train on: named to the platform as not_nvidia, not "no GPU".
    $notNvidia = Get-GpuNotNvidiaName -Names @($gpus | ForEach-Object { [string]$_.Name })
    if ($notNvidia) { Set-GpuNotNvidia $notNvidia }
    if ($script:GPU_VENDOR -eq "none") {
      if ($notNvidia) { Info "This machine's GPU ($notNvidia) is not an NVIDIA GPU. Your environment will run in CPU mode." }
      else { Info "No GPU detected. Your environment will run in CPU mode." }
    }
  } catch {
    Info "No GPU detected. Your environment will run in CPU mode."
    Log "GPU detection failed: $_"
  }

  if ($script:GPU_VENDOR -eq "nvidia" -and -not (Test-GpuArchSupported)) { Set-GpuArchUnsupported $nv[0].Name }
  if ($script:GPU_VENDOR -eq "nvidia") { Confirm-NvidiaDriver }

  # No ROCm training image exists, on any platform (client-dev#1697): CPU mode, never
  # "use Linux for AMD".
  if ($script:GPU_VENDOR -eq "amd") {
    Warn "tracebloc's GPU training images need an NVIDIA GPU, so the AMD GPU is not set up -- this machine will run in CPU mode."
    Hint "Everything else works on CPU. GPU training needs an NVIDIA GPU (Turing or later) on an x86_64 machine."
    $script:GPU_VENDOR = "amd_unsupported"
  }
}

# Run a child process with a hard timeout, its arguments quoted for Win32
# (install-k8s.ps1's comments above its copies give the rules).
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

# =============================================================================
#  5. The core: install-k8s.sh, run twice inside the distro.
#
#  The caller contract is client-dev#1810's (issue comment 6141263609), and part 2
#  builds the core's side to it. RFC-0175 D2 puts the account steps on the HOST
#  CLI, and `client create` is keyed on the cluster's kube-system UID, so:
#    0. the host CLI, installed for this user by its own installer;
#    1. the core's cluster run: checks, step b without the CLI, the cluster, and
#       its kubeconfig merged into the host's kubeconfig;
#    2. the account steps here, provision.sh's on the host CLI: `tracebloc login`;
#       `client create --plan`, which reads the client running in the cluster and
#       the account, so a client of another account is refused before anything is
#       minted and one of this account is reused by its name; then `client create
#       --credential-file` into a folder only this user can read;
#    3. the core's client run: the credential's bytes on its stdin, then Helm.
#  With TRACEBLOC_CLIENT_ID and TRACEBLOC_CLIENT_PASSWORD both set (provision.sh's
#  preset, for unattended installs), step 2 is skipped and that pair is the client
#  run's stdin. Nothing then needs the CLI, so a failed CLI install only warns.
#  The credential is never on wsl.exe's command line, which other processes can
#  read, and never in a line this script prints.
#
#  NOTHING CALLS THESE YET: they wait on the import and the logon task (sections 2
#  and 3, S-W rows 3 and 5) and on part 2's phases in the core, which also reads
#  the preset pair from stdin.
#  The cluster run hands the account steps what its stop-and-check gate found
#  (2c): this script names a file on that run's line, TRACEBLOC_WSL_HANDOVER, in a
#  folder only this user can open and deletes after the install, and reads it only
#  when the run exits 0. A file or line that is missing stops the install: the run
#  did not reach its end. On credential-rejected the account steps ask `client
#  create` for a new credential (--reissue, provision.sh's repair) and the client
#  run's line says so (TRACEBLOC_CREDENTIAL_REISSUED=1). A preset pair is never
#  reissued: provision.sh's preset path returns before its repair.
#    TODO(S-W): measure that /dev/tty answers in the distro while stdin is a pipe.
#    TODO(part 5): the refusal for another account's client names no removal
#      command yet: how the distro path removes a client is part 5's.
# =============================================================================

# The distro the core runs in, the substrate named on its command line (a Pester
# test holds it to install.ps1's $WslSubstrate), and the core's two runs (a Pester
# case holds the two phases to lib/common.sh's TB_WSL_PHASES).
$WslDistroName = 'tracebloc'
$CoreSubstrate = 'k3s'
$CorePhaseCluster = 'cluster'
$CorePhaseClient = 'client'

# What the core reads from this process's environment, carried onto its line,
# because no Windows variable crosses into the distro: the release the bootstrap
# resolved (lib/common.sh's TB_VERSION reads it), and every telemetry opt-out the
# core honours (lib/telemetry.sh's TB_TELEMETRY_OPT_OUT_VARS, which a Pester test
# holds this list to), so an opt-out set on Windows still opts out. Each goes on
# the line only when it is set, with the value as it was set.
$CorePassThroughVars = @('TRACEBLOC_INSTALL_REF', 'TRACEBLOC_SKIP_TELEMETRY', 'TRACEBLOC_NO_TELEMETRY', 'DO_NOT_TRACK')

# The tracebloc CLI's own Windows installer, as install-k8s.ps1 names it.
$TRACEBLOC_CLI_INSTALL_URL = "https://github.com/tracebloc/cli/releases/latest/download/install.ps1"

# The cluster run's handover (2c): the variable that names the file, the file's
# name in its folder, the one line the core writes (lib/common.sh's
# tb_wsl_handover_write), the reason that asks for a new credential, and the flag
# the client run gets then (provision.sh's). Pester holds each to the core's.
$CoreHandoverVar = 'TRACEBLOC_WSL_HANDOVER'
$CoreHandoverFile = 'handover.env'
$CoreHandoverKey = 'INSTALL_STATE_REASON'
$CredentialRejectedReason = 'credential-rejected'
$CredentialReissuedVar = 'TRACEBLOC_CREDENTIAL_REISSUED'

# One Windows command-line argument, quoted so that CommandLineToArgvW, and the
# .NET runtime on any OS, reads back exactly VALUE. wsl.exe --exec hands the
# words it reads to the command as they are, with no shell between.
function ConvertTo-WindowsArgument {
  param([string]$Value)
  if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $slashes = 0
  foreach ($c in $Value.ToCharArray()) {
    if ($c -eq [char]92) { $slashes++; continue }
    if ($c -eq [char]34) {
      [void]$sb.Append([char]92, 2 * $slashes + 1)
      [void]$sb.Append([char]34)
    } else {
      if ($slashes) { [void]$sb.Append([char]92, $slashes) }
      [void]$sb.Append($c)
    }
    $slashes = 0
  }
  if ($slashes) { [void]$sb.Append([char]92, 2 * $slashes) }
  [void]$sb.Append('"')
  return $sb.ToString()
}

# The host kubeconfig the core merges into: the first file of KUBECONFIG, else
# %USERPROFILE%\.kube\config. That is the core's own rule on Linux
# (_native_k3s_kubeconfig_target), applied on the host. Its folder is created.
function Get-HostKubeconfigTarget {
  $first = $null
  if ($env:KUBECONFIG) { $first = @($env:KUBECONFIG -split ';' | Where-Object { $_.Trim() })[0] }
  if (-not $first) { $first = Join-Path (Join-Path $env:USERPROFILE '.kube') 'config' }
  $dir = Split-Path -Parent $first
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $first
}

# PATH as the distro sees it (wslpath -u, run inside the distro), or a refusal by
# name: the core reads every host path through this, never a path computed here.
# The first call starts the distro, so each gets the start's budget.
function ConvertTo-DistroPath {
  param([string]$Path)
  $r = Invoke-WslProbe -ArgumentList @('-d', $WslDistroName, '-u', 'root', '--exec', 'wslpath', '-u', (ConvertTo-WindowsArgument $Path)) -TimeoutSec $WslDistroStartTimeoutSec
  if ($r.TimedOut) {
    throw "The tracebloc WSL distro did not start within $WslDistroStartTimeoutSec seconds, so the core cannot be started. Run this installer again; if it keeps failing, share this output with tracebloc support."
  }
  $out = ''
  if ($r.Output) { $out = @($r.Output -split "`r?`n" | Where-Object { $_ })[0] }
  if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or $out -notmatch '^/') {
    throw "The tracebloc WSL distro could not translate $Path into its own path, so the core cannot be started. Run this installer again; if it keeps failing, share this output with tracebloc support."
  }
  return $out.Trim()
}

# wsl.exe's words for one run of the core. Every path is the distro's own. The
# host GPU check's verdict and its three platform values go on every run's line
# (section 4), empty when this host judged no NVIDIA GPU. -Handover names the
# cluster run's handover file. -CredentialStdin tells the core to read the
# credential from its stdin first, and -CredentialReissued that the account steps
# asked for a new one.
function New-CoreRunArguments {
  param(
    [string]$Phase,
    [string]$Core,
    [string]$Kubeconfig,
    [string]$LogDir,
    [string]$Handover,
    [switch]$CredentialStdin,
    [switch]$CredentialReissued
  )
  $a = @('-d', $WslDistroName, '-u', 'root', '--exec', 'env',
    "TRACEBLOC_SUBSTRATE=$CoreSubstrate",
    "TRACEBLOC_WSL_PHASE=$Phase",
    "KUBECONFIG=$Kubeconfig",
    "TRACEBLOC_LOG_DIR=$LogDir",
    "TRACEBLOC_WSL_GPU_VERDICT=$script:GPU_FLOOR_VERDICT",
    "TRACEBLOC_WSL_GPU_UNSUPPORTED_CODE=$script:GPU_UNSUPPORTED_CODE",
    "TRACEBLOC_WSL_GPU_UNSUPPORTED_NAME=$script:GPU_UNSUPPORTED_NAME",
    "TRACEBLOC_WSL_GPU_UNSUPPORTED_REASON=$script:GPU_UNSUPPORTED_REASON")
  foreach ($name in $CorePassThroughVars) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) { $a += "$name=$value" }
  }
  if ($Handover) { $a += "$CoreHandoverVar=$Handover" }
  if ($CredentialStdin) { $a += 'TRACEBLOC_CREDENTIAL_STDIN=1' }
  if ($CredentialReissued) { $a += "$CredentialReissuedVar=1" }
  $a += @('bash', "$Core/install-k8s.sh")
  return $a
}

# The console's input encoding, read and set: seams for Invoke-CoreRun, since the
# test suite's .NET Core console never has a preamble to take out.
function Get-ConsoleInputEncoding { return [Console]::InputEncoding }
function Set-ConsoleInputEncoding {
  param([System.Text.Encoding]$Encoding)
  [Console]::InputEncoding = $Encoding
}

# Runs the core once: FILEPATH (wsl.exe; a seam for the test suite) with
# ARGUMENTLIST, each word quoted for the command line. The console stays the
# core's: its output is not redirected, and stdin is redirected only to hand in
# STDIN, which is written and then closed. Returns the core's exit code.
function Invoke-CoreRun {
  param(
    [string[]]$ArgumentList,
    [byte[]]$Stdin,
    [string]$FilePath = 'wsl.exe'
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = ($null -ne $Stdin)
  # .NET Framework's Process.Start (Windows PowerShell 5.1) wraps a redirected stdin
  # in a writer on the console's input encoding and flushes it at once, which puts
  # that encoding's preamble in the pipe before a byte of STDIN: on a console set to
  # UTF-8 (code page 65001, the only console code page with one), a BOM in front of
  # the credential. 5.1's ProcessStartInfo has no StandardInputEncoding, so for the
  # start only, the console's input encoding is UTF-8 without a BOM. .NET Core drops
  # the preamble itself.
  $restore = $null
  if ($null -ne $Stdin) {
    $enc = Get-ConsoleInputEncoding
    if ($enc.GetPreamble().Length -gt 0) {
      try {
        Set-ConsoleInputEncoding -Encoding (New-Object System.Text.UTF8Encoding $false)
      } catch {
        throw "The credential could not be handed to the tracebloc WSL distro without a byte-order mark in front of it: this console's input encoding could not be changed ($($_.Exception.Message)). Run this installer again in a new PowerShell window."
      }
      $restore = $enc
    }
  }
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
  } finally {
    if ($null -ne $restore) { Set-ConsoleInputEncoding -Encoding $restore }
  }
  try {
    if ($null -ne $Stdin) {
      # A child that exits before it has read its stdin (a refusal, a crash) has
      # closed the pipe, so the write fails as a broken pipe. Its exit code is
      # what says why, so that failure is not thrown here; the stream is closed
      # whatever happened.
      try {
        $p.StandardInput.BaseStream.Write($Stdin, 0, $Stdin.Length)
        $p.StandardInput.BaseStream.Flush()
      } catch [System.IO.IOException] {
        $null = $_
      } finally {
        try { $p.StandardInput.Close() } catch [System.IO.IOException] { $null = $_ }
      }
    }
    $p.WaitForExit()
    return $p.ExitCode
  } finally {
    $p.Dispose()
  }
}

# A new folder at PATH that only the current user can open: inheritance cut, one
# full-control rule for this user. Off Windows (the test suite), a plain folder.
function New-PrivateDirectory {
  param([string]$Path)
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
  }
}

# The CLI installer's launch: install-k8s.ps1's Start-TraceblocCliInstaller and the
# functions it calls, COPIED UNCHANGED (backend#4405: four ways to start the child,
# each refusal logged with its cause). install-wsl.Tests.ps1 holds them, and every
# top-level variable they or Install-HostCli read, byte-for-byte equal to
# install-k8s.ps1's, the set derived from install-k8s.ps1, until part 5 deletes the
# PowerShell core.
function Format-CliLaunchError($err) {
  $ex = $err.Exception
  $types = @()
  while ($ex) {
    $types += "$($ex.GetType().FullName) (0x$('{0:X8}' -f $ex.HResult))"
    if ($ex -is [System.ComponentModel.Win32Exception]) {
      return "$err [Win32 error $($ex.NativeErrorCode); $($types -join ' <- ')]"
    }
    $ex = $ex.InnerException
  }
  return "$err [no Win32 code surfaced; $($types -join ' <- ')]"
}

function Get-CliRedirectProbe([string]$Path) {
  $dir = Split-Path -Parent $Path
  try {
    $probe = Join-Path $dir "tracebloc-probe-$(Get-Random).tmp"
    [System.IO.File]::WriteAllText($probe, "")
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    $w = "writable"
  } catch { $w = "NOT writable ($($_.Exception.Message))" }
  "redirect dir $dir is $w; TEMP=$env:TEMP; user=$([Environment]::UserName)"
}

function Get-CliLaunchContext {
  $session = $(try { [System.Diagnostics.Process]::GetCurrentProcess().SessionId } catch { "unknown" })
  $elevated = $(try {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { "unknown" })
  "launch context: session=$session; interactive=$([Environment]::UserInteractive); elevated=$elevated; ps=$($PSVersionTable.PSVersion)"
}

function Start-CliInstallerDirect([string[]]$ArgumentList) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "powershell.exe"
  $psi.Arguments = $ArgumentList -join ' '
  $psi.UseShellExecute = $false
  [System.Diagnostics.Process]::Start($psi)
}

function Start-TraceblocCliInstaller {
  param([string[]]$ArgumentList, [string]$OutFile, [string]$ErrFile, [int]$RetryDelaySec = 5)
  $plans = @(
    @{ Mode = "redirect"; Label = "1/4 (redirected)" },
    @{ Mode = "redirect"; Label = "2/4 (redirected, after ${RetryDelaySec}s)" },
    @{ Mode = "plain";    Label = "3/4 (no redirection)" },
    @{ Mode = "direct";   Label = "4/4 (Process.Start, no redirection)" }
  )
  $last = $null
  for ($i = 0; $i -lt $plans.Count; $i++) {
    $plan = $plans[$i]
    if ($i -gt 0 -and $RetryDelaySec -gt 0) { Start-Sleep -Seconds $RetryDelaySec }
    try {
      if ($plan.Mode -eq "redirect") {
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $ArgumentList -NoNewWindow -PassThru `
          -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile -ErrorAction Stop
      } elseif ($plan.Mode -eq "plain") {
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $ArgumentList -NoNewWindow -PassThru -ErrorAction Stop
      } else {
        $p = Start-CliInstallerDirect -ArgumentList $ArgumentList
        if (-not $p) { throw "Process.Start returned no process" }
      }
      if ($i -gt 0) { Log "tracebloc CLI installer launched on attempt $($plan.Label)." }
      return $p
    } catch {
      $last = $_
      Log "tracebloc CLI installer launch $($plan.Label) refused: $(Format-CliLaunchError $_)"
      if ($i -eq 0) { Log "  $(Get-CliLaunchContext)" }
      if ($plan.Mode -eq "redirect") { Log "  $(Get-CliRedirectProbe $OutFile)" }
    }
  }
  throw $last
}

# Where tracebloc.exe is for this user: where the CLI's own installer puts it (the
# cli repo's scripts/install.ps1: TRACEBLOC_INSTALL_PREFIX, else the legacy
# INSTALL_PREFIX, else %LOCALAPPDATA%\Programs\tracebloc), else the first one on
# this process's PATH, else $null. The bootstrap calls it by this path: the User
# PATH entry that installer adds reaches only windows opened after it. PREFIXONLY
# skips PATH: that installer cannot change this process's PATH, so a hit there is
# never the CLI it just installed (client-dev#2088).
function Find-HostCli {
  param([switch]$PrefixOnly)
  $prefix = $env:TRACEBLOC_INSTALL_PREFIX
  if (-not $prefix) { $prefix = $env:INSTALL_PREFIX }
  if (-not $prefix -and $env:LOCALAPPDATA) { $prefix = Join-Path $env:LOCALAPPDATA 'Programs\tracebloc' }
  if ($prefix) {
    $exe = Join-Path $prefix 'tracebloc.exe'
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
  }
  if ($PrefixOnly) { return $null }
  $cmd = Get-Command tracebloc -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { return $cmd.Source }
  return $null
}

# Installs the tracebloc CLI for the user running this bootstrap: the CLI's own
# installer in a child Windows PowerShell (its `exit` closes nothing here), started
# as install-k8s.ps1 starts it and given the same 10 minutes. Not install-k8s.ps1's
# Install-TraceblocCli, which also copies the exe into the machine-wide tools
# folder: that needs an administrator, and the distro path runs as the daily user.
# The installer's exit code is the verdict. Returns the CLI's path. A failed
# install keeps a CLI that was already here, with a warning; with none, it refuses,
# because the CLI is what registers this machine. OPTIONAL is for an install that
# registers nothing (the preset pair): there, no CLI is a warning and $null.
function Install-HostCli {
  param([int]$TimeoutSec = 600, [switch]$Optional)
  Info "Installing the tracebloc CLI for this user..."
  $out = Join-Path ([System.IO.Path]::GetTempPath()) ("tracebloc-cli-install-" + [guid]::NewGuid().ToString('N') + ".log")
  $err = "$out.err"
  $why = $null
  try {
    $p = Start-TraceblocCliInstaller -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "irm '$TRACEBLOC_CLI_INSTALL_URL' | iex") -OutFile $out -ErrFile $err
    $null = $p.Handle
    if ($p.WaitForExit($TimeoutSec * 1000)) {
      # Only the overload with no deadline waits for the redirected streams, and
      # until they drain ExitCode can read $null (install-k8s.ps1, backend#2849).
      try { $p.WaitForExit() } catch { }
      if ($p.ExitCode -ne 0) { $why = "its installer exited $(Format-ExitCode $p.ExitCode)" }
    } else {
      try { $p.Kill() } catch { }
      try { $null = $p.WaitForExit(30000) } catch { }
      $why = "its installer did not finish within $TimeoutSec seconds, so it was stopped"
    }
  } catch {
    $why = "its installer could not be started ($($_.Exception.Message))"
  }
  if ($why) {
    # The installer's own last words, from whichever stream has some.
    foreach ($f in @($err, $out)) {
      $tail = @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue | Where-Object { "$_".Trim() } | Select-Object -Last 5)
      if ($tail.Count) { foreach ($l in $tail) { Hint "$l".Trim() }; break }
    }
  }
  Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
  # A clean exit is proven only by the exe where that installer puts it: a
  # tracebloc on this process's PATH predates it, and is kept below only as the
  # CLI already here, with a warning (client-dev#2088).
  if (-not $why) {
    $cli = Find-HostCli -PrefixOnly
    if ($cli) {
      Ok "tracebloc CLI installed for this user."
      return $cli
    }
    $why = "its installer finished, but tracebloc.exe is not where it installs"
  }
  $cli = Find-HostCli
  if ($cli) {
    Warn "The tracebloc CLI could not be updated: $why. Using the one already here: $cli"
    return $cli
  }
  if ($Optional) {
    Warn "The tracebloc CLI could not be installed: $why. The credentials you supplied don't need it. To use tracebloc from this machine, install it later in a new PowerShell window with:  irm $TRACEBLOC_CLI_INSTALL_URL | iex"
    return $null
  }
  throw "The tracebloc CLI could not be installed: $why. It is what registers this machine. Install it in a new PowerShell window with:  irm $TRACEBLOC_CLI_INSTALL_URL | iex  then run this installer again."
}

# A typed value with the terminal's residue taken out: arrow keys, bracketed-paste
# markers and control characters, which would otherwise become part of a permanent
# client name. install-k8s.ps1's ConvertTo-SanitizedInput, COPIED UNCHANGED (its
# comment names the bash and Go twins); install-wsl.Tests.ps1 holds it byte-for-byte
# equal, the set derived from what Get-ClientName calls.
function ConvertTo-SanitizedInput {
  param([string]$Value)
  if (-not $Value) { return "" }
  $esc = [char]27
  $s = $Value -replace "$esc(\[[0-9;]*|O)[A-Za-z~]", ""
  $s = $s.Replace("[200~", "").Replace("[201~", "")
  # The floor. The strip above knows CSI, SS3 and the paste markers; it cannot
  # know the escape family nobody has reported yet -- and that is exactly how SS3
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
  # keyboard-input escape family fits in that. The probe is a yes/no only -- it is
  # never returned. Nothing but residue => return empty, which callers already
  # treat as "no answer" (re-prompt, or auto-name).
  if ($s.Contains($esc)) {
    $probe = $s -replace "$esc[^A-Za-z0-9~]*[A-Za-z~]{1,2}", ""
    if ($probe -notmatch '[\p{L}\p{Nd}]') { return "" }
  }
  return (($s.ToCharArray() | Where-Object { [int]$_ -ge 32 -and [int]$_ -ne 127 }) -join "")
}

# The name the client is registered under: TRACEBLOC_CLIENT_NAME, else asked for
# here, else a refusal that names the variable. Either one is sanitized first; an
# answer that was only residue counts as no answer.
function Get-ClientName {
  $name = (ConvertTo-SanitizedInput -Value "$env:TRACEBLOC_CLIENT_NAME").Trim()
  if ($name) { return $name }
  if (-not (Test-BootstrapCanPrompt)) {
    throw "A name for this machine is needed to register it, and nobody at this console can be asked. Set TRACEBLOC_CLIENT_NAME, then run this installer again."
  }
  for ($i = 0; $i -lt 3; $i++) {
    $name = (ConvertTo-SanitizedInput -Value "$(Read-Host '  Name this machine (as it will show in tracebloc)')").Trim()
    if ($name) { return $name }
  }
  throw "No name was given for this machine, so it was not registered. Run this installer again, or set TRACEBLOC_CLIENT_NAME."
}

# How long one probe of the host CLI may take. `client create --plan` reads the
# account over HTTPS and the cluster through the host kubeconfig, and either can
# wedge. No other host-CLI call here has a bound to share.
$HostCliProbeTimeoutSec = 60

# What the CLI wrote to stderr, as one line to say: its lines joined, without
# colour codes or control characters.
function Format-HostCliStderr {
  param([string]$Text)
  $said = (@($Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' ') -replace "$([char]27)\[[0-9;?]*[ -/]*[@-~]", ''
  return (($said.ToCharArray() | Where-Object { [int]$_ -ge 32 -and [int]$_ -ne 127 }) -join '')
}

# One answer from the host CLI, bounded, captured, with its stdin closed: a probe
# never reads input (install-k8s.ps1, client-dev#1784). Returns its exit code, its
# stdout lines, ErrorText (what it wrote to stderr, kept apart: the reason a probe
# failed, and this script keeps no log to put it in) and TimedOut (it did not
# answer within TimeoutSec, so it was stopped, with what it had said by then). A
# CLI that could not be started, or was stopped, has no exit code. Not
# Invoke-BoundedProcess, which is install-k8s.ps1's and leaves stdin attached
# when there is nothing to write.
function Invoke-HostCliProbe {
  param([string]$Cli, [string[]]$ArgumentList, [int]$TimeoutSec = $HostCliProbeTimeoutSec)
  $r = [pscustomobject]@{ ExitCode = $null; Lines = @(); ErrorText = ''; TimedOut = $false; TimeoutSec = $TimeoutSec }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Cli
  $psi.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' ')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  try { $p = [System.Diagnostics.Process]::Start($psi) } catch { return $r }
  # The readers start before stdin is closed, in Invoke-BoundedProcess's order.
  $out = $p.StandardOutput.ReadToEndAsync()
  $err = $p.StandardError.ReadToEndAsync()
  try { $p.StandardInput.Close() } catch { }
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    try { $p.Kill() } catch { }
    $r.TimedOut = $true
    # Its stderr closes with it, so the read ends; bounded all the same.
    try { if ($err.Wait(5000)) { $r.ErrorText = Format-HostCliStderr ([string]$err.Result) } } catch { }
    return $r
  }
  # Only the overload with no deadline waits for the redirected streams.
  $p.WaitForExit()
  $r.ExitCode = $p.ExitCode
  $text = ([string]$out.Result) -replace '\r?\n\z', ''
  if ($text) { $r.Lines = @($text -split '\r?\n') }
  $r.ErrorText = Format-HostCliStderr ([string]$err.Result)
  return $r
}

# What `client create` would do here (`--plan`, which changes nothing): the CLI's
# own reads of the account and of the client running in the cluster the host
# kubeconfig makes current. Action is adopt, reconnect, mint, refuse (a client of
# another account runs here) or unknown, with the Namespace and Name. It is asked
# with the --credential-file the create gets, so it answers as the create will; an
# answer that can't be read is unknown, and Why says what the CLI did instead.
# Bash parity: provision.sh's _create_plan, which logs the CLI's stderr; here it
# is said.
function Get-HostCreatePlan {
  param([string]$Cli, [string]$CredentialFile)
  $probe = Invoke-HostCliProbe -Cli $Cli -ArgumentList @('client', 'create', '--plan', '--credential-file', $CredentialFile)
  $said = ''
  if ($probe.ErrorText) { $said = ": $($probe.ErrorText)" }
  $unknown = [pscustomobject]@{ Action = 'unknown'; Namespace = ''; Name = ''; Why = '' }
  if ($probe.TimedOut) {
    $unknown.Why = "timed out after $($probe.TimeoutSec) s, so it was stopped$said"
    return $unknown
  }
  if ($null -eq $probe.ExitCode) {
    $unknown.Why = 'could not be run'
    return $unknown
  }
  if ($probe.ExitCode -ne 0) {
    $unknown.Why = "exited $(Format-ExitCode $probe.ExitCode)$said"
    return $unknown
  }
  $f = @()
  if ($probe.Lines.Count -gt 0) { $f = @($probe.Lines[0].Split("`t")) }
  if ($f.Count -lt 4) {
    $unknown.Why = "gave no answer this installer can read$said"
    return $unknown
  }
  $name = ($f[3..($f.Count - 1)] -join "`t")
  if (-not $name) { $name = $f[2] }
  return [pscustomobject]@{ Action = $f[0]; Namespace = $f[2]; Name = $name; Why = '' }
}

# What the cluster run handed over: the reason on its one line, which may be empty
# (the gate did not assess). PATH is the file as Windows names it. A file that is
# not there, or that holds anything but that one line, stops the install.
function Read-CoreHandover {
  param([string]$Path)
  $lines = @()
  if (Test-Path -LiteralPath $Path -PathType Leaf) { $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) }
  $prefix = "$CoreHandoverKey="
  if ($lines.Count -ne 1 -or -not ([string]$lines[0]).StartsWith($prefix, [StringComparison]::Ordinal)) {
    throw "The cluster setup in the tracebloc WSL distro ended without saying what it found, so this machine was not registered. Run this installer again; if it keeps failing, share this output with tracebloc support."
  }
  return ([string]$lines[0]).Substring($prefix.Length)
}

# The account steps on the host CLI, provision.sh's: sign in (the device flow), ask
# `client create --plan` what it would do, then mint into a folder only this user
# can read. Another account's client running here, or an answer that can't tell,
# is refused before anything is minted (the one-client-per-machine pre-flight). A
# client of this account is reused by its name, with no prompt. -Reissue (the
# cluster run found the credential rejected) asks the create for a new credential,
# and stops before it when this CLI cannot issue one: without --reissue it would
# hand back the credential tracebloc refuses. Returns the bytes `client create
# --credential-file` wrote. The folder is deleted before this returns, whatever
# happened. CLI is the tracebloc CLI's path.
function Get-HostClientCredential {
  param([string]$Cli, [switch]$Reissue)
  $dir = Join-Path (Join-Path $env:LOCALAPPDATA 'tracebloc') ('credential-' + [guid]::NewGuid().ToString('N'))
  New-PrivateDirectory -Path $dir
  try {
    & $Cli login
    if ($LASTEXITCODE -ne 0) {
      throw "Signing in with the tracebloc CLI did not finish (it exited $LASTEXITCODE), so this machine was not registered. Run this installer again to sign in."
    }
    $h = Invoke-HostCliProbe -Cli $Cli -ArgumentList @('client', 'create', '--help')
    if ($h.TimedOut) {
      $said = ''
      if ($h.ErrorText) { $said = " (it said: $($h.ErrorText.TrimEnd('.')))" }
      throw "The tracebloc CLI timed out after $($h.TimeoutSec) s when asked for its options$said, so this machine was not registered. Run this installer again; if it keeps failing, share this output with tracebloc support."
    }
    $help = $h.Lines -join "`n"
    if ($help -notmatch '--plan') {
      throw "This tracebloc CLI is too old to register this machine from the installer. Update it in a new PowerShell window with:  irm $TRACEBLOC_CLI_INSTALL_URL | iex  then run this installer again."
    }

    $file = Join-Path $dir 'client-credential.env'
    $plan = Get-HostCreatePlan -Cli $Cli -CredentialFile $file
    if ($plan.Action -eq 'refuse') {
      Write-Host ""
      Warn "This machine already runs a tracebloc client that isn't in the account you just signed in as."
      Hint "tracebloc runs one client per machine. Registering this machine now would make a"
      Hint "second client and strand it (it could never install here). Pick one:"
      Hint "  - Repair / update it     -> sign in as the account that owns it, then run this installer again"
      Hint "  - Switch to this account -> remove the current client from this machine first"
      Hint "  - Run both               -> install on a separate machine"
      Write-Host ""
      throw "Refusing to register a second client on this machine. See the options above."
    }
    if ($plan.Action -notin @('adopt', 'reconnect', 'mint')) {
      Write-Host ""
      Warn "Couldn't determine whether a tracebloc client is already installed here."
      if ($plan.Why) { Hint "tracebloc client create --plan $($plan.Why.TrimEnd('.'))." }
      Hint "tracebloc runs one client per machine. Registering a new client now could strand"
      Hint "a second one if an existing client just couldn't be seen - usually the cluster in"
      Hint "the tracebloc WSL distro, or tracebloc itself, is briefly unreachable."
      Write-Host ""
      throw "Refusing to register this machine without verifying what's already on it. Run this installer again."
    }
    $name = (ConvertTo-SanitizedInput -Value "$env:TRACEBLOC_CLIENT_NAME").Trim()
    if ($plan.Action -ne 'mint' -and $plan.Namespace) {
      if ($plan.Action -eq 'adopt') {
        Info "Found your secure environment '$($plan.Name)' - it's already registered for this machine."
      } else {
        Info "Found your secure environment '$($plan.Name)' - reconnecting it to this machine's new cluster."
      }
      # The name only satisfies the required --name: a reuse keeps the registered one.
      if (-not $name) { $name = $plan.Namespace }
    }
    if (-not $name) { $name = Get-ClientName }

    $create = @('client', 'create', '--yes', '--name', $name, '--credential-file', $file)
    if ($Reissue) {
      if ($help -notmatch '--reissue') {
        throw "This tracebloc CLI can't issue a new credential to a running client yet. Update it in a new PowerShell window with:  irm $TRACEBLOC_CLI_INSTALL_URL | iex  then run this installer again."
      }
      $create += '--reissue'
    }
    $location = "$env:TRACEBLOC_CLIENT_LOCATION".Trim()
    if ($location) { $create += @('--location', $location) }
    & $Cli @create
    if ($LASTEXITCODE -ne 0) {
      throw "The tracebloc CLI could not register this machine (client create exited $LASTEXITCODE). Its own message is above."
    }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) {
      throw "The tracebloc CLI reported this machine registered but wrote no credential, so the client cannot be installed. Run this installer again."
    }
    return ,[System.IO.File]::ReadAllBytes($file)
  } finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# The credentials the operator supplied (provision.sh's preset: TRACEBLOC_CLIENT_ID
# and TRACEBLOC_CLIENT_PASSWORD, both set), as the bytes the client run reads on its
# stdin: one KEY=value line each, LF-ended, UTF-8 with no BOM, values as given.
# $null when neither is set. Half a pair is refused, as is a value with a line
# break, which would end its line early; neither refusal repeats the value.
function Get-HostPresetCredential {
  $pair = [ordered]@{ TRACEBLOC_CLIENT_ID = "$env:TRACEBLOC_CLIENT_ID"; TRACEBLOC_CLIENT_PASSWORD = "$env:TRACEBLOC_CLIENT_PASSWORD" }
  $set = @($pair.Keys | Where-Object { $pair[$_] })
  if ($set.Count -eq 0) { return $null }
  if ($set.Count -eq 1) {
    $unset = @($pair.Keys | Where-Object { -not $pair[$_] })[0]
    throw "$($set[0]) is set but $unset is not. Set both to install with your client's credentials, or neither to sign in in the browser."
  }
  $text = ''
  foreach ($k in $pair.Keys) {
    if ($pair[$k] -match "[`r`n]") { throw "$k has a line break in it, so it can't be your client's credential. Set it again without one." }
    $text += "$k=$($pair[$k])`n"
  }
  return ,[System.Text.Encoding]::UTF8.GetBytes($text)
}

# The CLI installed, then the core run twice in the distro with the account steps
# between, or the operator's preset pair in their place. CORE is the verified
# -CoreDir. Returns the exit code of the run that ended it: the cluster run's when
# it failed, else the client run's. The credential's bytes are wiped whatever
# happened.
function Invoke-WslCore {
  param([string]$CoreDir)
  $credential = Get-HostPresetCredential
  try {
    $cli = Install-HostCli -Optional:($null -ne $credential)
    $core = ConvertTo-DistroPath -Path $CoreDir
    $kubeconfig = ConvertTo-DistroPath -Path (Get-HostKubeconfigTarget)
    $logHost = Join-Path $env:USERPROFILE '.tracebloc'
    if (-not (Test-Path -LiteralPath $logHost)) { New-Item -ItemType Directory -Path $logHost -Force | Out-Null }
    $logDir = ConvertTo-DistroPath -Path $logHost
    # The host GPU check (section 4), before the first run: both runs carry its answer.
    Find-Gpu

    # The cluster run's handover, in a folder only this user can open, deleted after
    # the install whatever happened.
    $handDir = Join-Path (Join-Path $env:LOCALAPPDATA 'tracebloc') ('handover-' + [guid]::NewGuid().ToString('N'))
    New-PrivateDirectory -Path $handDir
    try {
      $handover = (ConvertTo-DistroPath -Path $handDir) + '/' + $CoreHandoverFile
      Info "Setting up the cluster in the tracebloc WSL distro..."
      $rc = Invoke-CoreRun -ArgumentList (New-CoreRunArguments -Phase $CorePhaseCluster -Core $core -Kubeconfig $kubeconfig -LogDir $logDir -Handover $handover)
      if ($rc -ne 0) { return $rc }
      $reason = Read-CoreHandover -Path (Join-Path $handDir $CoreHandoverFile)

      if ($null -ne $credential) {
        # As provision.sh's preset path, which returns before its credential-rejected
        # repair: a supplied pair is never reissued.
        $reissue = $false
        Info "Using the credentials you supplied - skipping browser sign-in."
      } else {
        $reissue = $reason -ceq $CredentialRejectedReason
        Info "Registering this machine with tracebloc..."
        $credential = Get-HostClientCredential -Cli $cli -Reissue:$reissue
      }
      Info "Installing tracebloc in the tracebloc WSL distro..."
      return (Invoke-CoreRun -ArgumentList (New-CoreRunArguments -Phase $CorePhaseClient -Core $core -Kubeconfig $kubeconfig -LogDir $logDir -CredentialStdin -CredentialReissued:$reissue) -Stdin $credential)
    } finally {
      Remove-Item -LiteralPath $handDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  } finally {
    if ($null -ne $credential) { [Array]::Clear($credential, 0, $credential.Length) }
  }
}

# =============================================================================
#  6. The install record: what `tracebloc delete` removes on Windows.
#
#  `tracebloc delete` on Windows reads the daily user's record, the schema's
#  x-tracebloc-record.user-path under %USERPROFILE%. The core keeps its own record
#  inside the distro, as root and with the distro's paths, and `wsl --unregister`
#  deletes it with everything it names. So the host record carries the core's
#  top-level fields, read back from the core's own record and never restated here,
#  and the artefacts the Windows path creates on the host, in the order it creates
#  them (RFC-0175 D12; the kinds and their ids are install-record.schema.json's):
#    wsl-distro    tracebloc, path its import folder, %LOCALAPPDATA%\tracebloc\wsl
#    logon-task    \tracebloc-keepalive, no path
#    kube-context  the context the core merged into the host kubeconfig, path that
#                  file as Windows names it
#  A re-run keeps an artefact the record already names, with its created_at, as
#  the core's writer does. Best-effort, like the core's: a record that cannot be
#  read or written is said, never fatal.
#
#  NOTHING CALLS THIS YET: it follows the import (section 2, S-W row 3) and the
#  client run (section 5).
# =============================================================================

# The record's place, as the schema's x-tracebloc-record.user-path names it: under
# %USERPROFILE% on the host, under root's home in the distro, where the core runs.
# Pester holds both to the schema.
$HostRecordRelPath = '.tracebloc\install-record.json'
$CoreRecordPath = '/root/.tracebloc/install-record.json'
# The top-level fields the host record takes from the core's. The rest are the
# host's own (user, updated_at, artefacts) or have no meaning on the host.
$CoreRecordFields = @('schema_version', 'substrate', 'cluster_name', 'kube_context', 'data_dir', 'namespace', 'installer_version')

# The folder the distro is imported into, which holds its virtual disk.
function Get-WslImportDir {
  return (Join-Path $env:LOCALAPPDATA 'tracebloc\wsl')
}

function Get-HostRecordPath {
  return (Join-Path $env:USERPROFILE $HostRecordRelPath)
}

function Get-RecordTimestamp {
  return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
}

# The core's record, read from the distro, or $null when it cannot be read. cat is
# named by its path: WSL did not find /usr/sbin's update-ca-certificates by name
# for `wsl -u root --exec` (S-W row 9), though the command's own PATH holds
# /usr/sbin (S-W's home row). So no program there is looked up by name.
$DistroCat = '/usr/bin/cat'
function Read-CoreInstallRecord {
  $r = Invoke-WslProbe -ArgumentList @('-d', $WslDistroName, '-u', 'root', '--exec', $DistroCat, $CoreRecordPath) -TimeoutSec $WslDistroStartTimeoutSec
  if (-not $r.Started -or $r.TimedOut -or $r.ExitCode -ne 0 -or -not $r.Output) { return $null }
  try { return ($r.Output | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

# The record already on the host, or $null when there is none or it cannot be read.
function Read-HostInstallRecord {
  $path = Get-HostRecordPath
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return (Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

# The host record: CORE's top-level fields, this user, and the host's artefacts.
# PRIOR's artefacts come first and are kept as they are; one already there (the
# same kind, id and path) is not added again. KUBECONFIG is the host file the core
# merged its context into.
function New-HostInstallRecord {
  param([object]$Core, [object]$Prior, [string]$Kubeconfig, [string]$Now)
  $arts = New-Object System.Collections.ArrayList
  if ($Prior -and $Prior.artefacts) { foreach ($a in @($Prior.artefacts | ForEach-Object { $_ })) { [void]$arts.Add($a) } }
  $want = @(
    [ordered]@{ kind = 'wsl-distro'; id = $WslDistroName; path = (Get-WslImportDir) }
    [ordered]@{ kind = 'logon-task'; id = $KeepaliveTaskId; path = $null }
  )
  if ($Core.kube_context) { $want += [ordered]@{ kind = 'kube-context'; id = [string]$Core.kube_context; path = $Kubeconfig } }
  foreach ($w in $want) {
    $have = @($arts | Where-Object { $_.kind -ceq $w.kind -and $_.id -ceq $w.id -and $_.path -ceq $w.path })
    if ($have.Count -eq 0) { $w.created_at = $Now; [void]$arts.Add([pscustomobject]$w) }
  }
  $rec = [ordered]@{}
  foreach ($f in $CoreRecordFields) {
    $rec[$f] = $Core.$f
    if ($f -eq 'substrate') { $rec['user'] = $env:USERNAME }
  }
  $rec['updated_at'] = $Now
  $rec['artefacts'] = @($arts)
  return $rec
}

# Writes RECORD to the host record path: UTF-8 with no BOM, through a temporary
# file in the same folder, so a reader never sees half a record.
function Write-HostInstallRecord {
  param([System.Collections.IDictionary]$Record)
  $path = Get-HostRecordPath
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = Join-Path $dir ('.install-record.' + [guid]::NewGuid().ToString('N'))
  try {
    [IO.File]::WriteAllText($tmp, ($Record | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
}

# Records this install on the host, after the client run. Never fatal.
function Save-HostInstallRecord {
  param([string]$Kubeconfig)
  $core = Read-CoreInstallRecord
  if (-not $core) {
    Warn "The tracebloc WSL distro's install record could not be read, so this install was not recorded on Windows. tracebloc delete will not find it; share this output with tracebloc support."
    return
  }
  try {
    Write-HostInstallRecord -Record (New-HostInstallRecord -Core $core -Prior (Read-HostInstallRecord) -Kubeconfig $Kubeconfig -Now (Get-RecordTimestamp))
  } catch {
    Warn "This install could not be recorded in $(Get-HostRecordPath) ($($_.Exception.Message)). tracebloc delete will not find it; share this output with tracebloc support."
  }
}

# =============================================================================
#  7. The reinstall path (RFC-0175 D10, W20): a Windows machine on Docker Desktop
#     and k3d moves to the tracebloc WSL distro only through the offboard, and the
#     distro is never set up beside a live k3d. client-dev#1810 part 6, the Windows
#     twin of lib/reinstall.sh (client-dev#1470).
#
#  A k3d machine is reinstalled, not migrated: this detects it read-only, says what
#  the move means, and refuses unless the user consents. The consented offboard is
#  behind the release switch, $K3dReinstall: the schema's x-tracebloc-reinstall
#  block, which lib/common.sh stamps as TB_K3D_REINSTALL and which ships at
#  `offboard`. Under `refuse` the consent variable is never read and no console is
#  asked, so nothing in the environment can reach an offboard.
#
#  The words are reinstall.sh's. install-wsl.Tests.ps1 holds every string here to
#  one of reinstall.sh's (and of the k3d.sh and common.sh reads it mirrors), where
#  the one difference is that reinstall.sh says native k3s and this says
#  $ReinstallTarget. It also renders every outcome in 1.4's copy catalog
#  (testdata/golden/02-reinstall.golden) and compares it line by line. A string
#  only Windows says carries `# Windows only:` and why, on its line.
#
#  Invoke-WslInstall calls Assert-NoLiveK3d once the tree is verified and before WSL
#  is touched, so nothing is turned on, written or started before it answers.
#  NOTHING CALLS Invoke-K3dOffboard YET: it runs after the distro image is fetched
#  and verified (section 2) and right before the import, TODO(S-W row 3), so a run
#  that could not import never offboards a working client.
#  What reinstall.sh does that this does not, and why:
#    - it reads the install record for the cluster's name. The Docker path never
#      wrote one, so the cluster looked for is install-k8s.ps1's own name;
#    - the adopt-blind exception: no administrator prepares this host for another
#      user;
#    - the leftover-data guard (TB_LEFTOVER_ACTION): the distro keeps its data in
#      its own disk, never in the Docker path's TRACEBLOC_HOST_DATA_DIR.
#    TODO(part 1, 5b): install the host CLI first, per user, as reinstall.sh's
#      install_tracebloc_cli does. Until then the offboard uses the CLI the Docker
#      path installed, or stops by name.
# =============================================================================

# The release switch and the consent's variable, as lib/common.sh stamps them from
# the schema (TB_K3D_REINSTALL, TB_REINSTALL_CONSENT_VAR). A Pester case holds both
# to the schema.
$K3dReinstall = 'offboard'
$ReinstallConsentVar = 'TRACEBLOC_REINSTALL_CONSENT'

# What this path moves a k3d machine to, where reinstall.sh's words say native k3s.
$ReinstallTarget = 'the tracebloc WSL distro'  # Windows only: the one difference from reinstall.sh's words
$ReinstallTargetStart = 'The tracebloc WSL distro'  # Windows only: the same, starting a sentence

# The cluster-name rule, lib/common.sh's _valid_cluster_name (a Pester case holds it
# so), which install-k8s.ps1's validation also applies.
$ClusterNameRule = '^[a-zA-Z][a-zA-Z0-9._-]{0,62}$'

# Each deadline's default, by the name the core reads it under: a Pester case holds
# each to every `${NAME:-default}` in lib/. Each is settable as its TRACEBLOC_
# spelling, as common.sh's naming rule gives it (TB_ replaced by TRACEBLOC_).
$ReinstallTimeouts = [ordered]@{
  TB_K3D_LIST_TIMEOUT     = '15'
  TB_DOCKER_PROBE_TIMEOUT = '10'
  TB_CLI_PROBE_TIMEOUT    = '30s'
  TB_OFFBOARD_TIMEOUT     = '15m'
}

# The deadline NAME as this run reads it: its TRACEBLOC_ spelling, else the TB_ one,
# else the default above. The text as given, for the words that name it.
function Get-ReinstallTimeout {
  param([string]$Name)
  foreach ($n in @(($Name -creplace '^TB_', 'TRACEBLOC_'), $Name)) {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($v) { return $v }
  }
  return $ReinstallTimeouts[$Name]
}

# The longest wait a .NET WaitForExit takes, in seconds: what 0 (no deadline, as
# timeout(1) reads it) becomes.
$NoDeadlineSec = [int][Math]::Floor([int]::MaxValue / 1000)

# NAME's deadline in seconds, read as timeout(1) reads it: a whole number, then s,
# m, h or d, or nothing for seconds. A value it cannot read is refused by name.
function Get-ReinstallTimeoutSeconds {
  param([string]$Name)
  $text = Get-ReinstallTimeout -Name $Name
  if ($text -cmatch '^([0-9]{1,9})([smhd]?)$') {
    $mult = switch -CaseSensitive ($Matches[2]) { 'm' { 60 } 'h' { 3600 } 'd' { 86400 } default { 1 } }
    $sec = [long]$Matches[1] * $mult
    if ($sec -eq 0 -or $sec -gt $NoDeadlineSec) { return $NoDeadlineSec }
    return [int]$sec
  }
  throw "$($Name -creplace '^TB_', 'TRACEBLOC_') is not a deadline this installer can read (got '$text'). Set it to a whole number of seconds, or one ending in s, m, h or d."  # Windows only: timeout(1) reads it on the core's side
}

# The program NAME on PATH, or $null: bash's `has`, the one way this section asks,
# so a test can stand in for it.
function Get-HostCommand {
  param([string]$Name)
  $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  return $null
}

# The last non-empty line of TEXT, as reinstall.sh's awk 'NF { l = $0 } END { print l }'.
function Get-LastLine {
  param([string]$Text)
  $lines = @(($Text -split "`r?`n") | Where-Object { $_.Trim() })
  if ($lines.Count) { return $lines[-1].Trim() }
  return ''
}

# The cluster the Docker path creates: install-k8s.ps1's own $CLUSTER_NAME, the same
# expression (a Pester case holds it so).
function Get-K3dClusterName {
  $name = if ($env:TRACEBLOC_CLUSTER_NAME) { $env:TRACEBLOC_CLUSTER_NAME } elseif ($env:CLUSTER_NAME) { $env:CLUSTER_NAME } else { "tracebloc" }
  return $name
}

# Every k3d cluster on this machine, as lib/k3d.sh's _k3d_live_clusters reads it:
# Code 0 and the Names; 1 when k3d lists none; 2 when the listing did not answer
# within TB_K3D_LIST_TIMEOUT; 3 when it failed fast, with k3d's last line in
# Message. A fast failure of --no-headers is retried once without it (an older
# k3d); a timeout is not, since a wedged engine would cost a second deadline.
function Get-K3dLiveClusters {
  param([string]$K3d)
  $t = Get-ReinstallTimeoutSeconds -Name 'TB_K3D_LIST_TIMEOUT'
  $r = Invoke-BoundedProcess -FileName $K3d -Arguments @('cluster', 'list', '--no-headers') -TimeoutSec $t -StdoutOnly
  $lines = @()
  if ($r.Code -ne 0 -and $r.Code -ne 124) {
    $r = Invoke-BoundedProcess -FileName $K3d -Arguments @('cluster', 'list') -TimeoutSec $t -StdoutOnly
    # The header-ful table's first row is its column header, not a cluster.
    if ($r.Code -eq 0) {
      $lines = @($r.Output -split "`r?`n")
      if ($lines.Count -and (@($lines[0] -split '\s+' | Where-Object { $_ })[0]) -ceq 'NAME') { $lines = @($lines | Select-Object -Skip 1) }
    }
  } elseif ($r.Code -eq 0) {
    $lines = @($r.Output -split "`r?`n")
  }
  if ($r.Code -eq 124) { return [pscustomobject]@{ Code = 2; Names = @(); Message = '' } }
  if ($r.Code -ne 0) {
    $msg = Get-LastLine -Text $r.Output
    if (-not $msg) { $msg = "k3d cluster list exited $($r.Code) with no message" }
    return [pscustomobject]@{ Code = 3; Names = @(); Message = $msg }
  }
  $names = @($lines | ForEach-Object { @($_ -split '\s+' | Where-Object { $_ })[0] } | Where-Object { $_ })
  if (-not $names.Count) { return [pscustomobject]@{ Code = 1; Names = @(); Message = '' } }
  return [pscustomobject]@{ Code = 0; Names = $names; Message = '' }
}

# What Docker says, as _reinstall_detect reads it: `docker info` first
# (_docker_answers), then the k3d cluster of every container with k3d's node label,
# stopped ones too (tb_k3d_cluster_names), each within TB_DOCKER_PROBE_TIMEOUT.
# What names the read that decided; Code is 0, 124 (the deadline) or Docker's own
# failure, whose words are in Output.
function Get-DockerK3dNames {
  param([string]$Docker)
  $t = Get-ReinstallTimeoutSeconds -Name 'TB_DOCKER_PROBE_TIMEOUT'
  $r = Invoke-BoundedProcess -FileName $Docker -Arguments @('info') -TimeoutSec $t
  if ($r.Code -ne 0) { return [pscustomobject]@{ What = "Docker ('docker info')"; Code = $r.Code; Output = $r.Output; Names = @() } }
  $r = Invoke-BoundedProcess -FileName $Docker -Arguments @('ps', '-a', '--filter', 'label=app=k3d', '--format', '{{.Label "k3d.cluster"}}') -TimeoutSec $t -StdoutOnly
  # What a read printed before it failed is no answer. A container with no cluster
  # label (a k3d registry) gives an empty line: it names no cluster.
  $names = @()
  if ($r.Code -eq 0) { $names = @(($r.Output -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
  return [pscustomobject]@{ What = "Docker's container list ('docker ps')"; Code = $r.Code; Output = $r.Output; Names = $names }
}

# How a bounded read that ended with CODE went, as reinstall.sh's
# _reinstall_read_how says it: answered, did not answer (the deadline), or failed,
# quoting the last line it wrote.
function Get-ReinstallReadHow {
  param([int]$Code, [string]$Output)
  if ($Code -eq 0) { return 'answered' }
  if ($Code -eq 124) { return 'did not answer' }
  $msg = Get-LastLine -Text $Output
  if (-not $msg) { $msg = "exited $Code with no message" }
  return "failed ($msg)"
}

# What k3d this machine holds, read-only, as reinstall.sh's _reinstall_detect reads
# it. Found is none | tracebloc | other | cannot-tell; Cluster is tracebloc's k3d
# cluster when one was found; Others every other one; and for cannot-tell, Probe
# (what could not answer), How and Remedy.
#   1. With neither k3d nor docker on PATH no k3d cluster can run here: none, with
#      nothing read.
#   2. The cluster to look for, held to the name rule first, and refused in the
#      Docker path's own words when it breaks it.
#   3. k3d's listing, first. One that answered is the answer: no later read that
#      failed overrules it.
#   4. Docker: what it lists by k3d's label is merged into what k3d listed. Docker
#      not answering is cannot tell only when k3d gave no answer of its own.
function Get-ReinstallState {
  $s = [pscustomobject]@{ Found = 'none'; Cluster = ''; Others = @(); Probe = ''; How = ''; Remedy = '' }
  $k3d = Get-HostCommand -Name 'k3d'
  $docker = Get-HostCommand -Name 'docker'
  if (-not $k3d -and -not $docker) { return $s }
  $name = Get-K3dClusterName
  if ($name -cnotmatch $ClusterNameRule) {
    throw "CLUSTER_NAME must start with a letter, contain only [a-zA-Z0-9._-], max 63 chars (got '$name')"
  }
  $tracebloc = $false
  $listed = $false
  $others = New-Object System.Collections.Generic.List[string]
  $seen = @()
  if ($k3d) {
    $l = Get-K3dLiveClusters -K3d $k3d
    if ($l.Code -eq 3) {
      return (Set-ReinstallCannotTell -State $s -Probe "the k3d cluster listing ('k3d cluster list')" -Remedy "Fix what k3d reports (start Docker if it is not running), then re-run." -How "failed ($($l.Message))")
    }
    if ($l.Code -eq 2) {
      return (Set-ReinstallCannotTell -State $s -Probe "the k3d cluster listing ('k3d cluster list')" -Remedy "Start Docker so k3d can answer, then re-run.")
    }
    $listed = $true
    $seen += @($l.Names)
  }
  if ($docker) {
    $d = Get-DockerK3dNames -Docker $docker
    if ($d.Code -ne 0) {
      $how = Get-ReinstallReadHow -Code $d.Code -Output $d.Output
      if ($listed) {
        Info "$($d.What) $how; k3d's own cluster listing did, and it decides."
      } elseif ($d.Code -eq 124) {
        return (Set-ReinstallCannotTell -State $s -Probe $d.What -Remedy "Start Docker, or run as a user Docker answers, then re-run.")
      } else {
        return (Set-ReinstallCannotTell -State $s -Probe $d.What -Remedy "Fix what Docker reports (start Docker if it is not running, or run as a user Docker answers), then re-run." -How $how)
      }
    }
    $seen += @($d.Names)
  }
  foreach ($n in $seen) {
    if ($n -ceq $name) { $tracebloc = $true }
    elseif (-not $others.Contains($n)) { $others.Add($n) }
  }
  if ($others.Count) { $s.Found = 'other' } elseif ($tracebloc) { $s.Found = 'tracebloc' }
  if ($tracebloc) { $s.Cluster = $name }
  $s.Others = @($others)
  return $s
}

function Set-ReinstallCannotTell {
  param([object]$State, [string]$Probe, [string]$Remedy, [string]$How = 'did not answer')
  $State.Found = 'cannot-tell'; $State.Probe = $Probe; $State.Remedy = $Remedy; $State.How = $How
  return $State
}

# The consent this run carries: the variable the schema names, and ONLY under
# `offboard`. Under `refuse` it is never read.
function Get-ReinstallConsent {
  if ($K3dReinstall -cne 'offboard') { return '' }
  return [string][Environment]::GetEnvironmentVariable($ReinstallConsentVar)
}

# Whether this run can consent, and ONLY under `offboard`: the consent variable is
# set (passed to the CLI as --confirm-name), or someone at this console can answer
# the CLI's own typed-name prompt.
function Test-ReinstallConsented {
  if (Get-ReinstallConsent) { return $true }
  return ($K3dReinstall -ceq 'offboard' -and (Test-BootstrapCanPrompt))
}

# refuse | offboard | proceed, from what was found and the consent. proceed only
# where no k3d cluster can be here; offboard only for tracebloc's own k3d when this
# run can consent. Whether the consent names the right secure environment is the
# CLI's check (--confirm-name, or its prompt).
function Get-ReinstallDecision {
  param([string]$Found)
  switch -CaseSensitive ($Found) {
    'none' { return 'proceed' }
    'tracebloc' { if (Test-ReinstallConsented) { return 'offboard' } return 'refuse' }
  }
  return 'refuse'
}

# What moving this machine means (D10), before a refusal and before an offboard
# alike.
function Write-ReinstallExplanation {
  param([string]$Cluster)
  Warn "This machine runs tracebloc on k3d (cluster '$Cluster')."
  Hint "Moving it to $ReinstallTarget is a reinstall: this machine's secure environment and its data are deleted, its datasets must be ingested again, and it comes back as a new secure environment. Your use cases and models stay on tracebloc."
  Hint "To keep today's environment, unset TRACEBLOC_SUBSTRATE and re-run."
}

# Never the distro beside a live k3d. Returns Decision (proceed, or a consented
# offboard) and the Cluster it found; otherwise refuses by name, with what the move
# means (D10).
function Assert-NoLiveK3d {
  $s = Get-ReinstallState
  $decision = Get-ReinstallDecision -Found $s.Found
  if ($decision -cne 'refuse') { return [pscustomobject]@{ Decision = $decision; Cluster = $s.Cluster } }
  if ($s.Found -ceq 'cannot-tell') {
    throw "This run cannot tell whether a k3d cluster is live on this machine: $($s.Probe) $($s.How), and $ReinstallTarget is never set up beside a live k3d. $($s.Remedy)"
  }
  if ($s.Found -ceq 'other') {
    $others = $s.Others -join ' '
    Warn "A k3d cluster that is not tracebloc's is on this machine: $others."
    Hint "This installer never removes it. To keep tracebloc on k3d, unset TRACEBLOC_SUBSTRATE and re-run."
    throw "$ReinstallTargetStart is never set up beside a live k3d."
  }
  Write-ReinstallExplanation -Cluster $s.Cluster
  if ($K3dReinstall -ceq 'offboard') {
    Hint "To move it, re-run on a terminal and type the secure environment's name when asked, or re-run with $ReinstallConsentVar=<the secure environment's name>."
    throw "$ReinstallTargetStart is never set up beside a live k3d, and no consent was given, so nothing was changed."
  }
  throw "$ReinstallTargetStart is never set up beside a live k3d, and this installer cannot move a k3d machine to $ReinstallTarget yet."
}

# 0 when k3d cluster CLUSTER is on this machine, 1 when it is not, 2 when that
# cannot be told: k3d's listing when k3d is here, else Docker's, read as
# Get-ReinstallState reads them.
function Get-ReinstallPresence {
  param([string]$Cluster)
  $k3d = Get-HostCommand -Name 'k3d'
  if ($k3d) {
    $l = Get-K3dLiveClusters -K3d $k3d
    if ($l.Code -eq 0) { if (@($l.Names) -ccontains $Cluster) { return 0 } return 1 }
    if ($l.Code -eq 1) { return 1 } else { return 2 }
  }
  $docker = Get-HostCommand -Name 'docker'
  if (-not $docker) { return 1 }
  $d = Get-DockerK3dNames -Docker $docker
  if ($d.Code -ne 0) { return 2 }
  if (@($d.Names) -ccontains $Cluster) { return 0 }
  return 1
}

# The offboard did not finish: say what is left, read again, and install nothing.
function Stop-Reinstall {
  param([string]$Cluster, [string]$Why)
  switch (Get-ReinstallPresence -Cluster $Cluster) {
    0 { Hint "k3d cluster '$Cluster' is still on this machine." }
    1 { Hint "k3d cluster '$Cluster' is gone." }
    default { Hint "Whether k3d cluster '$Cluster' is still on this machine cannot be told." }
  }
  throw "$Why Nothing was installed."
}

# The one way this section runs the tracebloc CLI for the offboard (reinstall.sh's
# _tb_cli), on this console, so its own summary is the user's to read. TIMEOUTSEC 0
# runs it with this console's stdin and no deadline, for its typed-name prompt (a
# person is there to stop it). Otherwise its stdin is closed, as </dev/null closes
# it, and it is stopped at the deadline, with every process it started: 124, which
# never confirms the cluster is gone. -Quiet reads its output and drops it, as
# >/dev/null 2>&1 drops it (the probe). Returns the exit code.
function Invoke-OffboardCli {
  param([string]$Cli, [string[]]$Arguments, [int]$TimeoutSec, [switch]$Quiet)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Cli
  $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' ')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = ($TimeoutSec -gt 0)
  $psi.RedirectStandardOutput = [bool]$Quiet
  $psi.RedirectStandardError = [bool]$Quiet
  # A redirected stdin is wrapped, on Windows PowerShell 5.1's .NET Framework, in a
  # writer on the console's input encoding, whose preamble (a BOM on code page 65001)
  # reaches the pipe when it is closed. The CLI is to see end of input and nothing
  # else, so for the start only that encoding is UTF-8 without a BOM, as Invoke-CoreRun does.
  $restore = $null
  if ($psi.RedirectStandardInput) {
    $enc = Get-ConsoleInputEncoding
    if ($enc.GetPreamble().Length -gt 0) {
      try { Set-ConsoleInputEncoding -Encoding (New-Object System.Text.UTF8Encoding $false) } catch { return 127 }
      $restore = $enc
    }
  }
  try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { return 127 } finally {
    if ($null -ne $restore) { Set-ConsoleInputEncoding -Encoding $restore }
  }
  # Drained as it is written, so a CLI that writes more than a pipe holds still ends.
  if ($Quiet) { $null = $proc.StandardOutput.ReadToEndAsync(); $null = $proc.StandardError.ReadToEndAsync() }
  if ($TimeoutSec -le 0) { $proc.WaitForExit(); return $proc.ExitCode }
  try { $proc.StandardInput.Close() } catch { }
  if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    Stop-ProcessTree -Process $proc
    return 124
  }
  # The untimed wait after the timed one is what fills ExitCode in for every caller.
  $proc.WaitForExit()
  return $proc.ExitCode
}

# Ends PROCESS and every process it started: `tracebloc delete` runs k3d and docker,
# and a delete still running past its deadline would race the presence read and a
# re-run. .NET's Kill(true) ends the tree; Windows PowerShell 5.1's .NET Framework has
# only Kill(), which ends PROCESS alone, so there taskkill /T ends the tree.
function Stop-ProcessTree {
  param([System.Diagnostics.Process]$Process)
  $ended = $false
  if (Test-ProcessTreeKill) { try { Invoke-TreeKill -Process $Process; $ended = $true } catch { } }
  # Where Kill(true) is absent, or threw (a child it could not end), taskkill /T tries the tree.
  if (-not $ended) { Invoke-Taskkill -Arguments @('/T', '/F', '/PID', "$($Process.Id)") }
  try { $null = $Process.WaitForExit(10000) } catch { }
}

# Process.Kill(entireProcessTree) on PROCESS, where this .NET has it: a seam.
function Invoke-TreeKill { param([System.Diagnostics.Process]$Process) $Process.Kill($true) }

# Whether this .NET's Process.Kill takes entireProcessTree (.NET Core 3.0 on): a seam.
function Test-ProcessTreeKill { return [bool]([System.Diagnostics.Process].GetMethod('Kill', [type[]]@([bool]))) }

# taskkill under %WINDIR% with ARGUMENTS, its output dropped: a seam.
function Invoke-Taskkill {
  param([string[]]$Arguments)
  try { $null = & "$env:WINDIR\System32\taskkill.exe" @Arguments 2>&1 } catch { }
}

# The consented offboard (D10), as reinstall.sh's reinstall_offboard_k3d runs it:
# `tracebloc delete --for-reinstall` revokes the old client and removes its k3d, and
# only then is the distro set up. It does nothing unless Assert-NoLiveK3d decided
# offboard and the release switch reads offboard.
#
# The consent is the variable, passed as --confirm-name, or else the CLI's own
# typed-name prompt on this console. --yes and --force are never passed: a running
# training blocks the offboard, and the CLI's refusal is what the user reads. The
# CLI's exit code and k3d's own answer decide together: 0 and 10 (revoked, local
# teardown incomplete) go on only when the cluster is definitely gone, because the
# CLI also exits 0, with nothing removed, when its prompt is declined. The probe and
# the headless offboard each have a deadline (TRACEBLOC_CLI_PROBE_TIMEOUT,
# TRACEBLOC_OFFBOARD_TIMEOUT).
function Invoke-K3dOffboard {
  param([string]$Decision, [string]$Cluster)
  if ($Decision -cne 'offboard' -or $K3dReinstall -cne 'offboard') { return }
  $name = $Cluster
  $consent = Get-ReinstallConsent
  Write-ReinstallExplanation -Cluster $name
  Info "Offboarding it first: tracebloc revokes this secure environment, then its k3d cluster '$name' and its data are removed."
  $cli = Get-HostCommand -Name 'tracebloc'
  if ($null -eq $cli) {
    throw "The tracebloc CLI is not on this computer, and it is what offboards the old secure environment, so nothing was changed and k3d cluster '$name' still runs. Install it, open a new PowerShell window, and run this installer again."  # Windows only: the bootstrap does not install the host CLI yet (part 1, 5b)
  }
  $probeAfter = Get-ReinstallTimeout -Name 'TB_CLI_PROBE_TIMEOUT'
  $probe = Invoke-OffboardCli -Cli $cli -Arguments @('delete', '--for-reinstall', '--help') -TimeoutSec (Get-ReinstallTimeoutSeconds -Name 'TB_CLI_PROBE_TIMEOUT') -Quiet
  if ($probe -eq 124) {
    throw "The tracebloc CLI on this machine did not answer within $probeAfter when asked whether it can offboard, so nothing was changed and k3d cluster '$name' still runs. Check it with 'tracebloc --help' and re-run."
  }
  if ($probe -ne 0) {
    throw "The tracebloc CLI on this machine cannot offboard a secure environment for a reinstall, so nothing was changed and k3d cluster '$name' still runs. Update it with 'tracebloc upgrade' and re-run, or unset TRACEBLOC_SUBSTRATE to keep today's environment."
  }
  # The context the old client runs in: k3d's own name for the cluster, as the CLI
  # names it when the machine has no install record.
  $ctx = "k3d-$name"
  $offboardAfter = Get-ReinstallTimeout -Name 'TB_OFFBOARD_TIMEOUT'
  if ($consent) {
    $rc = Invoke-OffboardCli -Cli $cli -Arguments @('delete', '--for-reinstall', '--context', $ctx, '--confirm-name', $consent) -TimeoutSec (Get-ReinstallTimeoutSeconds -Name 'TB_OFFBOARD_TIMEOUT')
  } else {
    $rc = Invoke-OffboardCli -Cli $cli -Arguments @('delete', '--for-reinstall', '--context', $ctx) -TimeoutSec 0
  }
  switch ($rc) {
    0 {
      if ((Get-ReinstallPresence -Cluster $name) -ne 1) {
        Stop-Reinstall -Cluster $name -Why "The offboard did not finish: 'tracebloc delete' exited 0, but its k3d cluster is not gone, and $ReinstallTarget is never set up beside a live k3d. A confirmation that was declined, left blank or cancelled ends this way. Re-run and type the secure environment's name to move this machine, or unset TRACEBLOC_SUBSTRATE to keep today's environment."
      }
    }
    10 {
      if ((Get-ReinstallPresence -Cluster $name) -ne 1) {
        Stop-Reinstall -Cluster $name -Why "'tracebloc delete' revoked the old secure environment, but $ReinstallTarget is never set up beside a live k3d. Check it with 'k3d cluster list', remove it with 'k3d cluster delete $name', then re-run."
      }
      Warn "The old secure environment is revoked and its k3d cluster is gone, but the CLI could not remove everything it left on this machine."
    }
    124 { Stop-Reinstall -Cluster $name -Why "The offboard did not finish within $offboardAfter ('tracebloc delete' was stopped), so how much of the secure environment it removed cannot be told. Re-run to finish it, with a longer TRACEBLOC_OFFBOARD_TIMEOUT if it needs more time." }
    1 { Stop-Reinstall -Cluster $name -Why "The offboard did not run ('tracebloc delete' exited 1), so the secure environment is untouched; the CLI's message above says why." }
    default { Stop-Reinstall -Cluster $name -Why "The offboard stopped ('tracebloc delete' exited $rc); the CLI's message above says what it removed." }
  }
  Ok "Offboarded the old secure environment and removed k3d cluster '$name'."
}

# =============================================================================
#  The distro path, as far as it is built. Returns the exit code.
# =============================================================================

# LocalSystem's SID. WSL refuses that account for anything that touches a distro
# ("Running WSL as local system is not supported", WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED:
# S-W row 2 on Windows Server 2025, WSL 3.0.3), and the distro, its logon task and
# its credential are the signed-in user's, so a deployment tool's SYSTEM run could
# set up nothing that user could use. The check reads the account, not WSL:
# `wsl --version` still answers as SYSTEM, so WSL would read as ready. A
# Windows-only Pester case holds it to .NET's own WellKnownSidType.LocalSystemSid.
$LocalSystemSid = 'S-1-5-18'

# The SID of the account running this bootstrap, or $null where Windows cannot
# say (off Windows, the test suite).
function Get-BootstrapUserSid {
  try { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { return $null }
}

function Invoke-WslInstall {
  param([string]$CoreDir)
  if ((Get-BootstrapUserSid) -eq $LocalSystemSid) {
    throw "This installer is running as the Windows SYSTEM account, which WSL does not support. tracebloc runs in the signed-in user's own WSL distro, so run the install command as that user. A deployment tool (Intune, Configuration Manager) has to run it in the user's context, not as SYSTEM."
  }
  Confirm-CoreDir -CoreDir $CoreDir
  # NAT only: a user's mirrored .wslconfig is refused before anything is written.
  Assert-WslNetworkingNat
  # Never the distro beside a live k3d (section 7): a refusal, or a consented
  # offboard decided, before WSL is touched. The offboard itself runs right before
  # the import (Invoke-K3dOffboard, TODO(S-W row 3)).
  $script:Reinstall = Assert-NoLiveK3d
  # A restart stops with 2, install-k8s.ps1's declared "restart, then re-run"
  # code, which install.ps1 passes through and the e2e harness reads.
  if ((Confirm-WslReady) -eq 'restart') {
    Info "If you set TRACEBLOC_SUBSTRATE=k3s in this window only, set it again after the restart."
    return 2
  }
  throw "WSL is ready, but the rest of the TRACEBLOC_SUBSTRATE=k3s path is not available on Windows yet. Unset TRACEBLOC_SUBSTRATE to install with the current Windows path."
}

# =============================================================================
#  Main. $env:TRACEBLOC_PESTER lets the test suite dot-source this file to load the
#  functions without running them. A child process: `exit` here closes no window.
# =============================================================================
if (-not $env:TRACEBLOC_PESTER) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  try {
    exit (Invoke-WslInstall -CoreDir $CoreDir)
  } catch {
    Write-Host ""
    Err "Installation stopped: $_"
    Write-Host "  It's safe to re-run this installer. If it keeps failing, share the output above with tracebloc support." -ForegroundColor DarkGray
    exit 1
  }
}
