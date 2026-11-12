# =============================================================================
#  install-wsl-account.ps1 -- part of section 5 of install-wsl.ps1: the host CLI
#  and the account steps between the core's two runs.
#
#  install-wsl.ps1 dot-sources this file from beside itself, at the place the
#  part stands in its order, and checks it through $CoreFiles; install.ps1
#  fetches and verifies it with the rest ($Files).
# =============================================================================

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

# The CLI installer's launch: Start-TraceblocCliInstaller and the functions it
# calls, which came over unchanged from the retired PowerShell core (four ways to start the child, each refusal logged with its cause).
# install-wsl-host.Tests.ps1 holds their behaviour.
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
# cli repo's scripts/install.ps1: TRACEBLOC_INSTALL_PREFIX, else
# %LOCALAPPDATA%\Programs\tracebloc), else the first one on
# this process's PATH, else $null. The bootstrap calls it by this path: the User
# PATH entry that installer adds reaches only windows opened after it. PREFIXONLY
# skips PATH: that installer cannot change this process's PATH, so a hit there is
# never the CLI it just installed.
function Find-HostCli {
  param([switch]$PrefixOnly)
  $prefix = $env:TRACEBLOC_INSTALL_PREFIX
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

# The retired PowerShell core  kept its tools in
# %ProgramFiles%\tracebloc\bin and put that folder on the MACHINE PATH. Nothing
# since removes the entry: `tracebloc delete` cleans the user-scope CLI folder and
# its user PATH entry only, so a machine that ever ran the old core keeps a system
# PATH entry naming a folder that is gone. Clear-RetiredToolPath
# removes exactly that entry, and only while the folder is gone: a folder still
# there is left alone with its entry. The Machine PATH is an administrator's to
# write. Elevated, the entry goes; not, one hint says so and the install goes on.
# Nothing here can stop an install.
#
# The Machine PATH is read and written through its registry value, not
# [Environment]::Get/SetEnvironmentVariable(..., 'Machine'): Windows ships it as
# REG_EXPAND_SZ, and that pair returns it expanded and writes it back as REG_SZ,
# baking every %VAR% entry into its value (the retired core's
# lesson). Seams for the suite: Get-MachinePath and Set-MachinePath.
$MachineEnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
function Get-MachinePath {
  $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($MachineEnvironmentKey, $false)
  if ($null -eq $key) { return $null }
  try { return $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
  finally { $key.Close() }
}
function Set-MachinePath {
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
  $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($MachineEnvironmentKey, $true)
  if ($null -eq $key) { throw "HKLM\$MachineEnvironmentKey could not be opened for writing" }
  try { $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
  finally { $key.Close() }
  # Tell Explorer the environment changed, so windows opened from it see the new
  # PATH: WM_SETTINGCHANGE "Environment", SMTO_ABORTIFHUNG, 1 s per window. Best
  # effort: the registry already holds the value.
  try {
    if (-not ('TbInstallWsl.EnvironmentBroadcast' -as [type])) {
      Add-Type -Namespace TbInstallWsl -Name EnvironmentBroadcast -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    $null = [TbInstallWsl.EnvironmentBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 1000, [ref]$result)
  } catch { }
}

# PATHVALUE without every entry that names DIR: compared whole, case-insensitively,
# with %VARS% expanded and a trailing separator ignored -- never as a substring, so
# a longer folder that starts with DIR is kept. Every other entry is kept as it was,
# in its order. Pure, so the suite drives it directly.
function Remove-PathEntry {
  param([AllowNull()][AllowEmptyString()][string]$PathValue, [Parameter(Mandatory)][string]$Dir)
  if (-not $PathValue) { return $PathValue }
  $target = $Dir.Trim().TrimEnd('\', '/')
  $kept = @($PathValue -split ';' | Where-Object {
    [Environment]::ExpandEnvironmentVariables($_).Trim().TrimEnd('\', '/') -ine $target
  })
  return ($kept -join ';')
}

function Clear-RetiredToolPath {
  if (-not $env:ProgramFiles) { return }
  # Spelled as the retired core spelled it ("$env:ProgramFiles\tracebloc\bin").
  $dir = $env:ProgramFiles.TrimEnd('\') + '\tracebloc\bin'
  try {
    if (Test-Path -LiteralPath $dir) { return }
    $raw = Get-MachinePath
    $new = Remove-PathEntry -PathValue $raw -Dir $dir
    if ($new -ceq $raw) { return }
    if (-not (Test-BootstrapElevated)) {
      Hint "The system PATH still lists $dir, left by an older tracebloc installer; that folder is gone. An administrator can remove the entry: System Properties > Environment Variables > System variables > Path."
      return
    }
    Set-MachinePath -Value $new
    Ok "Removed $dir, left by an older tracebloc installer, from the system PATH."
  } catch {
    Warn "Could not remove $dir, left by an older tracebloc installer, from the system PATH ($($_.Exception.Message)). An administrator can remove it: System Properties > Environment Variables > System variables > Path."
  }
}

# Installs the tracebloc CLI for the user running this bootstrap: the CLI's own
# installer in a child Windows PowerShell (its `exit` closes nothing here), started
# by Start-TraceblocCliInstaller and given 10 minutes. For this user only: the
# retired PowerShell core also copied the exe into the machine-wide tools folder,
# which needs an administrator, and the distro path runs as the daily user.
# The installer's exit code is the verdict. Returns the CLI's path. A failed
# install keeps a CLI that was already here, with a warning; with none, it refuses,
# because the CLI is what registers this machine. OPTIONAL is for an install that
# registers nothing (the preset pair): there, no CLI is a warning and $null.
function Install-HostCli {
  param([int]$TimeoutSec = 600, [switch]$Optional)
  Show-Live 'Installing the tracebloc CLI...'
  $out = Join-Path ([System.IO.Path]::GetTempPath()) ("tracebloc-cli-install-" + [guid]::NewGuid().ToString('N') + ".log")
  $err = "$out.err"
  $why = $null
  try {
    $p = Start-TraceblocCliInstaller -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "irm '$TRACEBLOC_CLI_INSTALL_URL' | iex") -OutFile $out -ErrFile $err
    $null = $p.Handle
    if ($p.WaitForExit($TimeoutSec * 1000)) {
      # Only the overload with no deadline waits for the redirected streams, and
      # until they drain ExitCode can read $null.
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
      if ($tail.Count) { foreach ($l in $tail) { Log "$l".Trim() }; break }
    }
  }
  Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
  # A clean exit is proven only by the exe where that installer puts it: a
  # tracebloc on this process's PATH predates it, and is kept below only as the
  # CLI already here, with a warning.
  if (-not $why) {
    $cli = Find-HostCli -PrefixOnly
    if ($cli) {
      Ok 'tracebloc CLI installed'
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
  Stop-Setup -What "Couldn't install the tracebloc CLI" -Next 'Install it in a new PowerShell window, then run the installer again:' -Command "irm $TRACEBLOC_CLI_INSTALL_URL | iex" -Reason "The tracebloc CLI could not be installed: $why. It is what registers this machine. Install it in a new PowerShell window with:  irm $TRACEBLOC_CLI_INSTALL_URL | iex  then run this installer again."
}

# A typed value with the terminal's residue taken out: arrow keys, bracketed-paste
# markers and control characters, which would otherwise become part of a permanent
# client name. The twin of settings.sh's _strip_paste_garbage and the CLI's
# sanitize.go: change the three together. It came over unchanged from the retired
# PowerShell core; install-wsl-host.Tests.ps1 holds its cases.
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
  # making keep-vs-reject depend on the script the name is written in (An escape final is one byte, an intro plus a final is two, and every
  # keyboard-input escape family fits in that. The probe is a yes/no only -- it is
  # never returned. Nothing but residue => return empty, which callers already
  # treat as "no answer" (re-prompt, or auto-name).
  if ($s.Contains($esc)) {
    $probe = $s -replace "$esc[^A-Za-z0-9~]*[A-Za-z~]{1,2}", ""
    if ($probe -notmatch '[\p{L}\p{Nd}]') { return "" }
  }
  return (($s.ToCharArray() | Where-Object { [int]$_ -ge 32 -and [int]$_ -ne 127 }) -join "")
}

# What a name may hold, said under every name Get-ClientName can't use: the CLI makes a
# namespace of it as ConvertTo-ClientNameSlug does.
$ClientNameRule = 'Use letters, digits and hyphens, up to 63 characters; spaces and other signs become hyphens.'

# The name the client is registered under: TRACEBLOC_CLIENT_NAME, else asked for here.
# Either one is sanitized first; an answer that was only residue counts as no answer.
# A name it can't use is asked for again, with no cap (Ctrl-C stops): the run stops
# only when nobody at this console can be asked (Stop-ClientNameUnasked).
function Get-ClientName {
  $name = (ConvertTo-SanitizedInput -Value "$env:TRACEBLOC_CLIENT_NAME").Trim()
  $why = $null
  if ($name) {
    if (Test-NameHasLetter $name) { return $name }
    $why = "TRACEBLOC_CLIENT_NAME `"$name`" can't be used: a name needs at least one letter"
  }
  if (-not (Test-BootstrapCanPrompt)) { Stop-ClientNameUnasked -Why $why }
  # provision.sh's `?` prompt, as `tracebloc delete` asks: Enter takes the default in
  # brackets (Get-DefaultClientName).
  $default = Get-DefaultClientName
  $ask = '  ? Name your secure environment '
  if ($default) { $ask = "$ask[$default] " }
  $setWhy = $why
  Write-Host ""
  while ($true) {
    if ($why) { Err "$why."; Hint "  $ClientNameRule" }
    Write-Host $ask -NoNewline
    $typed = $null
    try { $typed = Read-Host } catch { $typed = $null }
    # No answer at all: this console can't be asked after all.
    if ($null -eq $typed) { Stop-ClientNameUnasked -Why $setWhy }
    $name = (ConvertTo-SanitizedInput -Value "$typed").Trim()
    if (-not $name) { $name = $default }
    if (-not $name) { $why = 'A name is required'; continue }
    if (Test-NameHasLetter $name) { return $name }
    $why = "`"$name`" can't be used: a name needs at least one letter"
  }
}

# Get-ClientName's stop when nobody at this console can be asked, naming the setting
# to fix. WHY is why TRACEBLOC_CLIENT_NAME can't be used; none when it is not set.
function Stop-ClientNameUnasked {
  param([string]$Why)
  if ($Why) {
    Stop-Setup -What $Why -Next 'Set TRACEBLOC_CLIENT_NAME to a name with a letter in it, then run the installer again:' -Reason "$Why. Set TRACEBLOC_CLIENT_NAME to a name that has one, then run this installer again."
  }
  Stop-Setup -What 'No name was set in TRACEBLOC_CLIENT_NAME' -Next "Run the installer in a PowerShell window, or set TRACEBLOC_CLIENT_NAME`nfor an unattended install." -Command '' -Reason "A name for this machine is needed to register it, and nobody at this console can be asked. Set TRACEBLOC_CLIENT_NAME, then run this installer again."
}

# This computer's name, the machine name a new client gets when none is given.
function Get-HostComputerName { [Environment]::MachineName }

# The name Enter gives at the name prompt: this computer's name as its namespace will
# read, the CLI's slug.Slugify (NFKD to ASCII, lowercase, every run of other characters
# one '-', none at either end, 63 at most); provision.sh's _client_name_default.
function Get-DefaultClientName {
  $n = ConvertTo-ClientNameSlug "$(Get-HostComputerName)"
  if ($n -and -not (Test-NameHasLetter $n)) { $n = ConvertTo-ClientNameSlug "machine-$n" }
  return $n
}

# The CLI's slug.Slugify of a name, as provision.sh's _name_slug.
function ConvertTo-ClientNameSlug {
  param([string]$Name)
  $n = $Name.Normalize([Text.NormalizationForm]::FormKD)
  $n = -join @($n.ToCharArray() | Where-Object { [int]$_ -lt 128 })
  $n = ($n.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
  if ($n.Length -gt 63) { $n = $n.Substring(0, 63).TrimEnd('-') }
  return $n
}

# True when the name's slug has a letter, or the name is only signs outside ASCII, which
# the slug drops and the CLI names itself. A slug with no letter is a number, which the
# chart's labels render unquoted and Kubernetes refuses, or nothing the name said ("!!!",
# "---"). An empty name has none. provision.sh's _name_has_letter.
function Test-NameHasLetter {
  param([string]$Name)
  $s = ConvertTo-ClientNameSlug $Name
  if ($s -cmatch '[a-z]') { return $true }
  return ((-not $s) -and ($Name -match '[^\x00-\x7F]'))
}

# provision.sh's _machine_labels: TRACEBLOC_MACHINE_NAME / TRACEBLOC_CLIENT_PROVIDER,
# else this computer's name and no provider, never asked (`tracebloc machine set`
# changes them later), keyed by $MachineLabelKeys. Only a run whose plan ACTION is a
# mint defaults: a reused client keeps what `tracebloc machine set` stored and gets
# only what the caller set.
function Get-MachineLabels {
  param([string]$Action)
  $name = (ConvertTo-SanitizedInput -Value "$env:TRACEBLOC_MACHINE_NAME").Trim()
  $provider = (ConvertTo-SanitizedInput -Value "$env:TRACEBLOC_CLIENT_PROVIDER").Trim()
  if ($Action -eq 'mint' -and -not $name) {
    $name = (ConvertTo-SanitizedInput -Value "$(Get-HostComputerName)").Trim()
  }
  $labels = [ordered]@{}
  $labels[$MachineLabelKeys[0]] = $name
  $labels[$MachineLabelKeys[1]] = $provider
  return $labels
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
# never reads input. Returns its exit code, its
# stdout lines, ErrorText (what it wrote to stderr, kept apart: the reason a probe
# failed, and this script keeps no log to put it in) and TimedOut (it did not
# answer within TimeoutSec, so it was stopped, with what it had said by then). A
# CLI that could not be started, or was stopped, has no exit code. Not
# Invoke-BoundedProcess, which leaves stdin attached when there is nothing to
# write.
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

# The tracebloc CLI's floor, as the verified core declares it: lib/assess.sh's
# TB_CLI_MIN_VERSION default, the floor the bash installer holds its CLI to.
# Read from that file, never restated here. A core it cannot be
# read from cannot be checked against, so that is refused by name. $CoreDir is
# the flattened tree Confirm-CoreDir verifies: lib/ sits directly under it.
function Get-CoreCliFloor {
  param([string]$CoreDir)
  $assess = Join-Path (Join-Path $CoreDir 'lib') 'assess.sh'
  $found = @(Get-Content -LiteralPath $assess -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_ -match '^: "\$\{TB_CLI_MIN_VERSION:=([0-9]+(\.[0-9]+)*)\}"') { $Matches[1] }
  })
  if ($found.Count -ne 1 -or -not (ConvertTo-FloorVersion $found[0])) {
    Stop-Setup -What "Couldn't read the tracebloc CLI's minimum version" -Reason "This installer can't read the tracebloc CLI's minimum version from $assess, so it can't check the CLI. Run the installer again from its release."
  }
  return $found[0]
}

# Stops the install when the CLI Install-HostCli left is below the core's floor.
# Install-HostCli keeps the CLI already here when its update fails;
# below the floor that CLI cannot find the client this chart installs and the
# platform refuses it, so going on would register this machine with a CLI that
# cannot use it. A version the CLI does not report, or reports as anything but
# dotted numbers, passes, as at the bash gate. Bash twin: lib/install-cli.sh's
# require_tracebloc_cli_floor.
function Assert-HostCliFloor {
  param([string]$Cli, [string]$CoreDir)
  $floor = Get-CoreCliFloor -CoreDir $CoreDir
  $probe = Invoke-HostCliProbe -Cli $Cli -ArgumentList @('version')
  $first = "$(@($probe.Lines)[0])".Trim()
  if (-not $first) { return }
  # "tracebloc 0.10.5 (windows/amd64)" -> "0.10.5", as assess.sh's _assess_cli_version.
  $words = @($first -split '\s+')
  $ver = $(if ($words.Count -ge 2) { $words[1] } else { $words[0] }) -replace '^v', ''
  if ($ver -notmatch '^\d+(\.\d+)*$') { return }
  $have = ConvertTo-FloorVersion $ver
  if (-not $have -or $have -ge (ConvertTo-FloorVersion $floor)) { return }
  Stop-Setup -What "This tracebloc CLI is too old (v$ver) $Dot tracebloc needs v$floor" -Next 'Update it in a new PowerShell window, then run the installer again:' -Command "irm $TRACEBLOC_CLI_INSTALL_URL | iex" -Reason "The tracebloc CLI on this machine (v$ver, $Cli) is older than v$floor, the oldest version tracebloc accepts, and it could not be updated. Install it in a new PowerShell window with:  irm $TRACEBLOC_CLI_INSTALL_URL | iex  then run this installer again."
}

# What `client create` would do here (`--plan`, which changes nothing): the CLI's
# own reads of the account and of the client running in the cluster KUBECONTEXT
# names (Get-HostKubeContextArgs). Action is adopt, reconnect, mint, refuse (a client of
# another account runs here) or unknown, with the Namespace and Name. It is asked
# with the --credential-file and context the create gets, so it answers as the create
# will; an answer that can't be read is unknown, and Why says what the CLI did instead.
# Bash parity: provision.sh's _create_plan, which logs the CLI's stderr; here it
# is said.
function Get-HostCreatePlan {
  param([string]$Cli, [string]$CredentialFile, [string]$KubeContext)
  $probe = Invoke-HostCliProbe -Cli $Cli -ArgumentList (@('client', 'create', '--plan', '--credential-file', $CredentialFile) + (Get-HostKubeContextArgs $KubeContext))
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

# What the cluster run handed over, on its five lines: Reason, which may be empty
# (the gate did not assess); KubeContext, tracebloc's kube context, which that run
# added to the kubeconfig; and Facts, where this machine runs, by the names the CLI
# reads, each empty when the core could not read it. PATH is the file as Windows names
# it. A file that is not there, that holds anything but those five lines in that
# order, or that names no context, stops the install.
function Read-CoreHandover {
  param([string]$Path)
  $lines = @()
  if (Test-Path -LiteralPath $Path -PathType Leaf) { $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) }
  $keys = @($CoreHandoverKey, $CoreHandoverContextKey) + $CoreHandoverFactKeys
  $ok = $lines.Count -eq $keys.Count
  for ($i = 0; $ok -and $i -lt $keys.Count; $i++) { $ok = ([string]$lines[$i]).StartsWith("$($keys[$i])=", [StringComparison]::Ordinal) }
  if ($ok) { $ok = ([string]$lines[1]).Length -gt ($CoreHandoverContextKey.Length + 1) }
  if (-not $ok) {
    throw "The cluster setup in the tracebloc WSL distro ended without saying what it found, so this machine was not registered. Run this installer again; if it keeps failing, share this output with tracebloc support."
  }
  $values = @(for ($i = 0; $i -lt $keys.Count; $i++) { ([string]$lines[$i]).Substring($keys[$i].Length + 1) })
  $facts = [ordered]@{}
  for ($i = 0; $i -lt $CoreHandoverFactKeys.Count; $i++) { $facts[$CoreHandoverFactKeys[$i]] = $values[2 + $i] }
  return [pscustomobject]@{ Reason = $values[0]; KubeContext = $values[1]; Facts = $facts }
}

# The host CLI's words naming tracebloc's kube context CONTEXT, or none when it is ''.
# Until the host record names that context for the CLI, a command that reads the
# cluster without them would read the kubeconfig's current context: the user's.
function Get-HostKubeContextArgs {
  param([string]$Context)
  if ($Context) { return @('--context', $Context) }
  return @()
}

# The client state the client run handed over, or '' when its file is not there or
# holds anything but its one line. Never throws: '' only means the example is skipped.
function Read-CoreClientState {
  param([string]$Path)
  $lines = @()
  if (Test-Path -LiteralPath $Path -PathType Leaf) { $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) }
  if ($lines.Count -ne 1 -or -not ([string]$lines[0]).StartsWith("$CoreClientStateKey=", [StringComparison]::Ordinal)) { return '' }
  return ([string]$lines[0]).Substring($CoreClientStateKey.Length + 1)
}

# Set-ProcessEnv -- set the process variable $Name to $Value, or UNSET it when $Value
# is $null. Never $null through [Environment]::SetEnvironmentVariable: on .NET 9 and
# later (pwsh 7.5+) its string parameter takes $null as "", so the variable stays,
# empty. An empty string is set as given, so a restore puts back exactly what it
# found. $Value is untyped on purpose: a [string] parameter would turn $null into ""
# before this could see it.
function Set-ProcessEnv {
  param([Parameter(Mandatory)][string]$Name, $Value)
  if ($null -eq $Value) {
    Remove-Item "Env:$Name" -ErrorAction SilentlyContinue
  } else {
    [Environment]::SetEnvironmentVariable($Name, [string]$Value, 'Process')
  }
}

# The console's output encoding, read and set: seams for Invoke-HostCliShown, as
# Get-ConsoleInputEncoding and Set-ConsoleInputEncoding are for Invoke-CoreRun.
function Get-ConsoleOutputEncoding { return [Console]::OutputEncoding }
function Set-ConsoleOutputEncoding {
  param([System.Text.Encoding]$Encoding)
  [Console]::OutputEncoding = $Encoding
}

# Runs the host CLI with ARGUMENTLIST, its stdout piped to Out-Host so none of it is
# this function's output. Windows PowerShell 5.1 decodes a native command's piped
# stdout by [Console]::OutputEncoding (the OEM code page), but the CLI writes UTF-8:
# for the call only that encoding is UTF-8 without a BOM, put back as found even when
# the CLI throws. A console that refuses the change still runs the CLI.
function Invoke-HostCliShown {
  param([string]$Cli, [string[]]$ArgumentList)
  $restore = $null
  try {
    $enc = Get-ConsoleOutputEncoding
    Set-ConsoleOutputEncoding -Encoding (New-Object System.Text.UTF8Encoding $false)
    $restore = $enc
  } catch {
    $null = $_
  }
  try {
    & $Cli @ArgumentList | Out-Host
  } finally {
    if ($null -ne $restore) {
      try { Set-ConsoleOutputEncoding -Encoding $restore } catch { $null = $_ }
    }
  }
}

# Runs the host CLI with ARGUMENTLIST, its output straight to this console and its
# stdin closed, as lib/install-cli.sh's </dev/null closes it: a CLI that asks for
# input sees the end of it and never waits on this console. Past TIMEOUTSEC (0: no
# deadline) it is stopped with every process it started, and that is 124. Returns its
# exit code; a CLI that cannot be started throws. The preamble: see Invoke-CoreRun.
function Invoke-HostCliNoInput {
  param([string]$Cli, [string[]]$ArgumentList, [int]$TimeoutSec = 0)
  $start = New-Object System.Diagnostics.ProcessStartInfo
  $start.FileName = $Cli
  $start.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' ')
  $start.UseShellExecute = $false
  $start.RedirectStandardInput = $true
  $inEnc = $null
  $was = Get-ConsoleInputEncoding
  if ($was.GetPreamble().Length -gt 0) {
    try { Set-ConsoleInputEncoding -Encoding (New-Object System.Text.UTF8Encoding $false); $inEnc = $was } catch { $null = $_ }
  }
  try { $run = [System.Diagnostics.Process]::Start($start) } finally {
    if ($null -ne $inEnc) { Set-ConsoleInputEncoding -Encoding $inEnc }
  }
  try { $run.StandardInput.Close() } catch { $null = $_ }
  if ($TimeoutSec -gt 0 -and -not $run.WaitForExit($TimeoutSec * 1000)) {
    Stop-ProcessTree -Process $run
    return 124
  }
  # The untimed wait is what fills ExitCode in, after a timed one too.
  $run.WaitForExit()
  return $run.ExitCode
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
#
# The login and the create are piped to Out-Host (Invoke-HostCliShown). What a
# command run here writes to stdout is this function's output, and the caller keeps
# that as the credential: so the login's URL and code never reached the screen (the
# user waited ten minutes for a code they were not shown), and a CLI line would sit
# in front of the credential bytes, which the client run's [byte[]] -Stdin cannot
# take.
function Get-HostClientCredential {
  param([string]$Cli, [switch]$Reissue, [System.Collections.IDictionary]$Facts, [string]$KubeContext)
  $dir = Join-Path (Join-Path $env:LOCALAPPDATA 'tracebloc') ('credential-' + [guid]::NewGuid().ToString('N'))
  New-PrivateDirectory -Path $dir
  try {
    # The login is handed the stage the core reads, prod when TRACEBLOC_ENV is unset:
    # its session is the backend the create mints on, and the CLI reads stage names
    # the core is not handed. Put back as found.
    $stageWas = [Environment]::GetEnvironmentVariable('TRACEBLOC_ENV')
    if (-not $stageWas) { Set-ProcessEnv -Name 'TRACEBLOC_ENV' -Value 'prod' }
    try {
      Invoke-HostCliShown -Cli $Cli -ArgumentList @('login')
    } finally {
      Set-ProcessEnv -Name 'TRACEBLOC_ENV' -Value $stageWas
    }
    if ($LASTEXITCODE -ne 0) {
      Stop-Setup -What "Signing in didn't finish" -Next 'Run the installer again to sign in:' -Reason "Signing in with the tracebloc CLI did not finish (it exited $LASTEXITCODE), so this machine was not registered. Run this installer again to sign in."
    }
    $h = Invoke-HostCliProbe -Cli $Cli -ArgumentList @('client', 'create', '--help')
    if ($h.TimedOut) {
      $said = ''
      if ($h.ErrorText) { $said = " (it said: $($h.ErrorText.TrimEnd('.')))" }
      throw "The tracebloc CLI timed out after $($h.TimeoutSec) s when asked for its options$said, so this machine was not registered. Run this installer again; if it keeps failing, share this output with tracebloc support."
    }
    $help = $h.Lines -join "`n"
    if ($help -notmatch '--plan') {
      Stop-Setup -What 'This tracebloc CLI is too old to register this machine' -Next 'Update it in a new PowerShell window, then run the installer again:' -Command "irm $TRACEBLOC_CLI_INSTALL_URL | iex" -Reason "This tracebloc CLI is too old to register this machine from the installer. Update it in a new PowerShell window with:  irm $TRACEBLOC_CLI_INSTALL_URL | iex  then run this installer again."
    }

    $file = Join-Path $dir 'client-credential.env'
    $plan = Get-HostCreatePlan -Cli $Cli -CredentialFile $file -KubeContext $KubeContext
    if ($plan.Action -eq 'refuse') {
      Log "This machine already runs a secure environment that isn't in the account you just signed in as."
      Log "tracebloc runs one secure environment per machine. Registering this machine now would make a"
      Log "second secure environment and strand it (it could never install here). Pick one:"
      Log "  - Repair / update it     -> sign in as the account that owns it, then run this installer again"
      Log "  - Switch to this account -> delete the current secure environment from this machine first"
      Log "  - Run both               -> install on a separate machine"
      Stop-Setup -What "This machine's secure environment is in another account" -Next 'Sign in with the account it is in, or delete it with tracebloc delete, then run the installer again:' -Reason "Refusing to register a second secure environment on this machine. See the options above."
    }
    if ($plan.Action -notin @('adopt', 'reconnect', 'mint')) {
      Log "Couldn't determine whether a secure environment is already installed here."
      if ($plan.Why) { Log "tracebloc client create --plan $($plan.Why.TrimEnd('.'))." }
      Log "tracebloc runs one secure environment per machine. Registering a new secure environment now could strand"
      Log "a second one if an existing secure environment just couldn't be seen - usually the cluster in"
      Log "the tracebloc WSL distro, or tracebloc itself, is briefly unreachable."
      Stop-Setup -What "Couldn't tell whether this machine runs a secure environment already" -Reason "Refusing to register this machine without verifying what's already on it. Run this installer again."
    }
    $name = ''
    if ($plan.Action -ne 'mint' -and $plan.Namespace) {
      if ($plan.Action -eq 'adopt') {
        Info "Your secure environment '$($plan.Name)' is already registered for this machine."
      } else {
        Info "Reconnecting your secure environment '$($plan.Name)' to this machine's new cluster."
      }
      # The name only satisfies the required --name: a reuse keeps the registered one.
      $name = (ConvertTo-SanitizedInput -Value "$env:TRACEBLOC_CLIENT_NAME").Trim()
      if (-not $name) { $name = $plan.Namespace }
    }
    # A name a client is minted under meets Get-ClientName's refusals, TRACEBLOC_CLIENT_NAME too.
    if (-not $name) { $name = Get-ClientName }
    $labels = Get-MachineLabels -Action $plan.Action

    $create = @('client', 'create', '--yes', '--name', $name, '--credential-file', $file)
    if ($Reissue) {
      if ($help -notmatch '--reissue') {
        Stop-Setup -What 'This tracebloc CLI is too old to register this machine' -Next 'Update it in a new PowerShell window, then run the installer again:' -Command "irm $TRACEBLOC_CLI_INSTALL_URL | iex" -Reason "This tracebloc CLI can't issue a new credential to a running secure environment yet. Update it in a new PowerShell window with:  irm $TRACEBLOC_CLI_INSTALL_URL | iex  then run this installer again."
      }
      $create += '--reissue'
    }
    $location = "$env:TRACEBLOC_CLIENT_LOCATION".Trim()
    if ($location) { $create += @('--location', $location) }
    $create += Get-HostKubeContextArgs $KubeContext
    # Where this machine runs, as the cluster run read it (FACTS), and what it is
    # called (Get-MachineLabels), in the CLI's environment for the create only, as
    # provision.sh hands them to its own; a CLI that predates the names ignores them.
    # A blank value is left unset, so the CLI does not send it. Put back as found,
    # whatever the create did.
    $savedFacts = [ordered]@{}
    foreach ($k in $CoreHandoverFactKeys + $MachineLabelKeys) {
      $savedFacts[$k] = [Environment]::GetEnvironmentVariable($k)
      $v = $null; if ($Facts -and $Facts[$k]) { $v = [string]$Facts[$k] }
      if ($labels[$k]) { $v = [string]$labels[$k] }
      Set-ProcessEnv -Name $k -Value $v
    }
    try {
      Invoke-HostCliShown -Cli $Cli -ArgumentList $create
    } finally {
      foreach ($k in @($savedFacts.Keys)) { Set-ProcessEnv -Name $k -Value $savedFacts[$k] }
    }
    if ($LASTEXITCODE -ne 0) {
      Stop-Setup -What "Couldn't register this machine" -Reason "The tracebloc CLI could not register this machine (client create exited $LASTEXITCODE). Its own message is above."
    }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) {
      Stop-Setup -What "Couldn't register this machine" -Reason "The tracebloc CLI reported this machine registered but wrote no credential, so the secure environment cannot be installed. Run this installer again."
    }
    return ,[System.IO.File]::ReadAllBytes($file)
  } finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# The backend a Client ID belongs to, read from the verified installer tree, so it is
# the one the distro's install asks: TRACEBLOC_ENV, reduced by
# lib/settings.sh's tb_client_env and named by lib/credentials.sh's _backend_url,
# each matched case for case as bash matches. $null when either table can't be read or
# the address is not HTTPS: the pair is then left to the distro's check.
function Get-HostBackendUrl {
  param([string]$CoreDir)
  try {
    $settings = [IO.File]::ReadAllText((Join-Path $CoreDir 'lib/settings.sh'))
    $helm = [IO.File]::ReadAllText((Join-Path $CoreDir 'lib/credentials.sh'))
  } catch { return $null }
  $envFn = [regex]::Match($settings, '(?ms)^tb_client_env\(\) \{\r?\n.*?^\}').Value
  $urlFn = [regex]::Match($helm, '(?ms)^_backend_url\(\) \{\r?\n.*?^\}').Value
  $aliases = [regex]::Matches($envFn, "(?m)^    ([a-z]+)\) +printf '([a-z]+)' +;;")
  $stages = [regex]::Matches($urlFn, "(?m)^    ([a-z]+)\) +printf '([^']*)' +;;")
  $otherwise = [regex]::Matches($urlFn, "(?m)^    \*\) +printf '([^']*)' +;;")
  if ($aliases.Count -eq 0 -or $stages.Count -eq 0 -or $otherwise.Count -ne 1) { return $null }
  $raw = "$env:TRACEBLOC_ENV"
  $stage = $raw
  foreach ($m in $aliases) { if ($m.Groups[1].Value -ceq $raw) { $stage = $m.Groups[2].Value } }
  $url = $otherwise[0].Groups[1].Value
  foreach ($m in $stages) { if ($m.Groups[1].Value -ceq $stage) { $url = $m.Groups[2].Value } }
  if (-not $url.StartsWith('https://', [StringComparison]::Ordinal)) { return $null }
  return $url
}

# Whether a Client ID and password are a pair, asked as lib/credentials.sh's
# verify_credentials asks it (POST api-token-auth/): valid (200), invalid (400),
# inactive (401), else unverified -- no answer, a throttle, a server error. HTTPS with
# the runtime's own certificate checks and a bounded wait. The password goes in the
# request body alone: never in the URL, a line said or logged, or a refusal.
$HostCredentialCheckTimeoutSec = 30
function Test-HostPresetCredential {
  param([string]$ClientId, [string]$Password, [string]$CoreDir)
  $backend = Get-HostBackendUrl -CoreDir $CoreDir
  if (-not $backend) { return 'unverified' }
  $ProgressPreference = 'SilentlyContinue'
  $proxyArgs = @{}
  if ($env:HTTPS_PROXY) { $proxyArgs['Proxy'] = $env:HTTPS_PROXY }
  $code = 0
  try {
    $answer = Invoke-WebRequest -Uri "${backend}api-token-auth/" -Method Post -Body @{ username = $ClientId; password = $Password } -UseBasicParsing -TimeoutSec $HostCredentialCheckTimeoutSec -ErrorAction Stop @proxyArgs
    $code = [int]$answer.StatusCode
  } catch {
    # PS 5.1 (WebException) and 7 (HttpResponseException) both carry the
    # response's StatusCode; a network error carries no response at all.
    try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
  }
  switch ($code) {
    200     { return 'valid' }
    400     { return 'invalid' }
    401     { return 'inactive' }
    default { return 'unverified' }
  }
}

# provision.sh's _provision_prompt_preset_password, in its words (a Pester case reads
# them from it): a client ID with no password asks for it, hidden, at a console that
# can answer, and checks the pair before anything is written (Test-HostPresetCredential).
# An empty answer is asked again, and a rejected pair both, the Client ID defaulting to
# the last one, with no cap (Ctrl-C stops). A check that got no answer keeps the password:
# the distro's install checks it again. The password is kept here, never in $env:, so no
# child process inherits it.
$script:HostPresetPassword = $null
function Read-HostPresetPassword {
  param([string]$CoreDir)
  $id = "$env:TRACEBLOC_CLIENT_ID"
  if (-not $id -or "$env:TRACEBLOC_CLIENT_PASSWORD" -or -not (Test-BootstrapCanPrompt)) { return }
  $hint = 'Enter the password shown when that Client ID was created (typing is hidden).'
  Info "Installing your secure environment with Client ID $id."
  Hint $hint
  while ($true) {
    $secret = $null
    try { $secret = Read-Host '  Password' -AsSecureString } catch { $secret = $null }
    # No answer at all: asking again won't help.
    if ($null -eq $secret) { break }
    # NetworkCredential reads a SecureString on every platform; Marshal's PtrToStringAuto
    # keeps one character off Windows. Cleaned as _strip_paste_garbage cleans it, untrimmed.
    $typed = ConvertTo-SanitizedInput -Value ([System.Net.NetworkCredential]::new('', $secret).Password)
    $secret.Dispose()
    if (-not $typed) {
      Err 'A password is required.'
      Hint $hint
      continue
    }
    $status = Test-HostPresetCredential -ClientId $id -Password $typed -CoreDir $CoreDir
    if ($status -eq 'inactive') { throw 'This tracebloc account is not active yet. Check your email for the activation link, then re-run.' }
    if ($status -ne 'invalid') {
      Set-ProcessEnv -Name 'TRACEBLOC_CLIENT_ID' -Value $id
      $script:HostPresetPassword = $typed
      return
    }
    $typed = $null
    Err "Couldn't connect $([char]0x2014) your Client ID or password was rejected."
    $answer = $null
    try { $answer = Read-Host "  Client ID [$id]" } catch { $answer = $null }
    if ($null -eq $answer) { break }
    $answer = (ConvertTo-SanitizedInput -Value "$answer").Trim()
    if ($answer) { $id = $answer }
  }
  throw (Format-PresetPasswordRefusal -ClientId $id)
}

# provision.sh's refusal of a client ID with no password it could take.
function Format-PresetPasswordRefusal {
  param([string]$ClientId)
  return "No valid password for Client ID $ClientId. Copy it from the page where the Client ID was created, or set TRACEBLOC_CLIENT_PASSWORD, then re-run."
}

# The credentials the operator supplied (provision.sh's preset: TRACEBLOC_CLIENT_ID
# and TRACEBLOC_CLIENT_PASSWORD, both set, the password possibly the one asked for by
# Read-HostPresetPassword), as the bytes the client run reads on its stdin: one
# KEY=value line each, LF-ended, UTF-8 with no BOM, values as given. $null when
# neither is set. Half a pair is refused, as is a value with a line break, which
# would end its line early; neither refusal repeats the password.
function Get-HostPresetCredential {
  $password = "$env:TRACEBLOC_CLIENT_PASSWORD"
  if (-not $password -and $env:TRACEBLOC_CLIENT_ID) { $password = "$script:HostPresetPassword" }
  $pair = [ordered]@{ TRACEBLOC_CLIENT_ID = "$env:TRACEBLOC_CLIENT_ID"; TRACEBLOC_CLIENT_PASSWORD = $password }
  $set = @($pair.Keys | Where-Object { $pair[$_] })
  if ($set.Count -eq 0) { return $null }
  if ($set.Count -eq 1) {
    if ($set[0] -eq 'TRACEBLOC_CLIENT_ID') { throw (Format-PresetPasswordRefusal -ClientId $pair.TRACEBLOC_CLIENT_ID) }
    $unset = @($pair.Keys | Where-Object { -not $pair[$_] })[0]
    throw "$($set[0]) is set but $unset is not. Set both to install with your secure environment's credentials, or neither to sign in in the browser."
  }
  $text = ''
  foreach ($k in $pair.Keys) {
    if ($pair[$k] -match "[`r`n]") { throw "$k has a line break in it, so it can't be your secure environment's credential. Set it again without one." }
    $text += "$k=$($pair[$k])`n"
  }
  return ,[System.Text.Encoding]::UTF8.GetBytes($text)
}

# The preset pair's refusals, before anything is written: the
# clients page's Windows "+" command sets TRACEBLOC_CLIENT_ID alone, and a refusal
# raised only in the core run came after the distro import and the keepalive task.
# The environment does not change in between, so Invoke-WslCore reads the same pair
# again; the bytes read here are wiped at once.
function Assert-HostPresetCredential {
  $credential = Get-HostPresetCredential
  if ($null -ne $credential) { [Array]::Clear($credential, 0, $credential.Length) }
}
