# =============================================================================
#  install-base.ps1 -- the helpers both Windows installer scripts use: the
#  output lines, the run's log, the stop block, and the manifest checks.
#
#  ONE DEFINITION, TWO WAYS IN:
#    * install-wsl.ps1 dot-sources this file from beside itself: the tree
#      install.ps1 verified against the signed manifest (WINDOWS_FILES), which
#      install-wsl.ps1's Confirm-CoreDir checks again.
#    * install.ps1 needs these before it has fetched or verified anything, so
#      the release pastes this file into install.ps1 between its
#      "install-base.ps1" markers before it is signed
#      (tooling/splice-install-base.sh, from release-helm-chart.yaml's stamp
#      step). The signed install.ps1 a customer runs is whole.
#  An unstamped install.ps1 (Pester, the developer path) loads it at the
#  markers instead.
#
#  Glyphs are [char] codes: Windows PowerShell 5.1 reads a file without a
#  byte-order mark as Latin-1. Dot-sourced: defines functions, runs nothing.
# =============================================================================

$Dot = [string][char]0x00B7
$InstallCommand = 'irm https://tracebloc.io/i.ps1 | iex'
# The run's log, which install.ps1 creates (New-HostLog) and its child inherits.
$script:LOG_FILE = $env:TRACEBLOC_HOST_LOG
$script:LiveLine = ''
# A person's console, not a pipe or a file; and one that animates, with colour on.
function Test-HostTerminal { try { return (-not [Console]::IsOutputRedirected) } catch { return $false } }
function Test-HostAnimate { return ((Test-HostTerminal) -and -not $env:NO_COLOR -and $env:TERM -ne 'dumb') }
# Show-Live MSG: "· MSG" while a wait runs, on a console that animates; the next line
# printed takes its place. Elsewhere nothing, as the outcome's own line says it, unless
# -Keep: a wait long enough to look frozen prints its line once.
function Show-Live {
  param([string]$m, [switch]$Keep)
  Close-Live
  if (-not (Test-HostAnimate)) { if ($Keep) { Info $m }; return }
  $script:LiveLine = "  $Dot $m"
  Write-Host $script:LiveLine -ForegroundColor DarkGray -NoNewline
}
function Close-Live {
  if (-not $script:LiveLine) { return }
  Write-Host ("`r" + (' ' * $script:LiveLine.Length) + "`r") -NoNewline
  $script:LiveLine = ''
}
function Info($m) { Close-Live; Write-Host "  " -NoNewline; Write-Host ([char]0x00B7) -ForegroundColor DarkGray -NoNewline; Write-Host " $m" -ForegroundColor DarkGray }
function Ok($m)   { Close-Live; Write-Host "  " -NoNewline; Write-Host ([char]0x2714) -ForegroundColor Green    -NoNewline; Write-Host " $m" }
function Warn($m) { Close-Live; Write-Host "  " -NoNewline; Write-Host ([char]0x26A0) -ForegroundColor Yellow   -NoNewline; Write-Host "  $m" -ForegroundColor Yellow }
function Err($m)  { Close-Live; Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red      -NoNewline; Write-Host " $m" -ForegroundColor Red }
function Log($m)  { if ($script:LOG_FILE) { Add-Content -Path $script:LOG_FILE -Value "[$(Get-Date -Format 'HH:mm:ss')] $m" -Encoding UTF8 -ErrorAction SilentlyContinue } }
# A line only a machine reads: to the log, and to a console that is not a person's.
function Write-MachineLine($m) { Log $m; if (-not (Test-HostTerminal)) { Write-Host "  $m" } }
function Write-Rule { Write-Host ('  ' + ([string][char]0x2500) * 45) -ForegroundColor DarkGray }
# A section: its heading and the blank line under it, and the two blank lines it ends with.
function Write-Section($t) { Close-Live; Write-Host "  $t"; Write-Host "" }
function Write-SectionEnd { Close-Live; Write-Host ""; Write-Host "" }
function Get-HostLogDir { return (Join-Path $env:USERPROFILE '.tracebloc') }
function Format-HostLogPath {
  $leaf = Split-Path -Leaf $script:LOG_FILE
  if ($script:LOG_FILE -ceq (Join-Path (Get-HostLogDir) $leaf)) { return "~\.tracebloc\$leaf" }
  return $script:LOG_FILE
}

# Stop-Setup: ends the run with what a person reads. -What is the ✖ line, -Next what to
# do, -Command the command under it (the install command unless given; none when '').
# The message, -Reason, is the whole of it, which the log and a machine read.
function Stop-Setup {
  param([Parameter(Mandatory)][string]$Reason, [string]$What, [string]$Next, [AllowEmptyString()][string]$Command)
  $e = New-Object System.Management.Automation.RuntimeException $Reason
  if ($What) { $e.Data['TbWhat'] = $What }
  if ($Next) { $e.Data['TbNext'] = $Next }
  if ($PSBoundParameters.ContainsKey('Command')) { $e.Data['TbCommand'] = $Command }
  throw $e
}

# Write-SetupEnd: the block a run that stops ends with, between two rules: the head,
# what to do with its command under it, and where the log is.
function Write-SetupEnd {
  param([string]$Head = "Setup didn't finish", [string]$Next = "It's safe to run the installer again:",
        [AllowEmptyString()][string]$Command = $InstallCommand, [char]$Glyph = [char]0x2716,
        [ConsoleColor]$Color = 'Red', [switch]$NoLog)
  Write-SectionEnd
  Write-Rule
  Write-Host ""
  Write-Host "  " -NoNewline; Write-Host $Glyph -ForegroundColor $Color -NoNewline; Write-Host " $Head"
  Write-Host ""
  foreach ($l in ($Next -split "`n")) { Write-Host "  $l" }
  if ($Command) { Write-Host "    $Command" -ForegroundColor Cyan }
  if (-not $NoLog -and $script:LOG_FILE -and (Test-Path -LiteralPath $script:LOG_FILE)) {
    Write-Host ""
    Write-Host "  Log: $(Format-HostLogPath)"
  }
  Write-Host ""
  Write-Rule
}

# Write-SetupStopped ERROR: the end of a run a throw stopped: the reason to the log,
# the ✖ line, then the block. A throw that is no Stop-Setup has its reason as the line.
function Write-SetupStopped {
  param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
  $reason = "$ErrorRecord"
  $data = $ErrorRecord.Exception.Data
  Write-MachineLine "Installation stopped: $reason"
  $what = if ($data.Contains('TbWhat')) { [string]$data['TbWhat'] } else { $reason }
  $end = @{}
  if ($data.Contains('TbNext')) { $end.Next = [string]$data['TbNext'] }
  if ($data.Contains('TbCommand')) { $end.Command = [string]$data['TbCommand'] }
  Err $what
  Write-SetupEnd @end
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

# Pull the expected digest for a repo-relative key out of a manifest.sha256 whose
# lines are "<sha256>␠␠scripts/<path>". Matches the line whose LAST whitespace
# field equals the key (independent of how many spaces separate the columns),
# mirroring install.sh's `awk '$NF == p'`. Returns $null if absent.
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

# The bash core's scripts in a manifest: every scripts/*.sh key, in the manifest's
# order. The bootstrap fetches and checks exactly these for the distro path, so
# the signed manifest is their list and nothing restates it. install-wsl.ps1
# checks the same set in the tree it is given.
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

# Can someone at this console answer a prompt? False under CI, a service, or
# piped/redirected stdin. install.ps1's Complete-Bootstrap and install-wsl.ps1's
# prompts both ask it.
function Test-BootstrapCanPrompt {
  try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) }
  catch { return $false }
}
