# =============================================================================
#  Bootstrap installer (Windows) — the signed-installer trust root, Windows
#  side. This is the PowerShell peer of scripts/install.sh; the two implement
#  the SAME supply-chain guarantee:
#
#    1. Fetch every sub-script from an IMMUTABLE release tag (never a mutable
#       branch), so a moved ref can't change what runs as Administrator.
#    2. Verify each fetched sub-script against a signed manifest (sha256) before
#       it runs.
#    3. Anchor the manifest's authenticity with a cosign keyless signature (the
#       same Sigstore machinery the CLI binary + install.sh already use). On the
#       default path the signature is REQUIRED: if cosign is unavailable AND
#       cannot be bootstrapped, the install FAILS CLOSED rather than silently
#       degrading to a checksum fetched over the same channel an on-path attacker
#       controls.
#
#  Usage (PowerShell, as the signed-in user; an administrator is needed only once
#  per machine, to enable WSL, and the installer names that one step):
#    irm https://github.com/tracebloc/client/releases/latest/download/install.ps1 | iex
#  (Only the release asset is stamped with its pinned tag. The raw.githubusercontent
#   .../main/scripts/... copy is this file unstamped, so it refuses to run -- never
#   hand a customer that URL.)
#
#  Developer / unreleased-branch override (UNVERIFIED — not for customers). The
#  sub-scripts are fetched from the raw TREE of $env:TRACEBLOC_SOURCE_REPO (default
#  tracebloc/client, which carries no scripts/ tree), so point it at a source whose
#  tree is readable — a public fork with your branch pushed — and fetch install.ps1
#  itself from that same fork:
#    $env:TRACEBLOC_SOURCE_REPO = "<you>/client"; $env:TRACEBLOC_BRANCH = "<branch>"; $env:TRACEBLOC_ALLOW_UNVERIFIED = "1"
#  ($env:TRACEBLOC_REF = "<vX.Y.Z>" pins another release instead; the older
#  $env:REF / $env:BRANCH spellings still work.)
#    irm https://raw.githubusercontent.com/<you>/client/<branch>/scripts/install.ps1 | iex
#
#  macOS / Linux:
#    curl -fsSL https://github.com/tracebloc/client/releases/latest/download/install.sh | bash
#    bash <(curl -fsSL https://tracebloc.io/i.sh)
# =============================================================================
#Requires -Version 5.1

# ── Pinned, immutable release ref ──────────────────────────────────────────
# $DefaultRef is the immutable git tag this bootstrap fetches from. The release
# pipeline rewrites this line on every release so the published installer always
# pins itself to its own release (see .github/workflows/release-helm-chart.yaml
# "Stamp the published installer"). It MUST be a tag (vX.Y.Z), never a branch —
# a tag's bytes can't be moved. Un-stamped, the fail-closed guard below refuses.
$DefaultRef = "__TRACEBLOC_RELEASE_REF__"

# The sub-script(s) the Windows bootstrap fetches. This list is the integrity
# surface — every entry MUST have a digest in manifest.sha256. gen-manifest.sh
# hashes exactly this set (its WINDOWS_FILES array) and its --check mode fails CI
# if this array and that one drift. Keep them in lockstep.
$Files = @(
  # The distro path (RFC-0175 D2, D7), the one Windows install path since the
  # PowerShell core was retired (client-dev#1810 part 5). Its other input is the
  # bash core, whose scripts the signed manifest lists (Get-CoreScriptKeys).
  "scripts/install-wsl.ps1"
)

# The one runtime Windows sets up: k3s in the tracebloc WSL distro. An unset
# TRACEBLOC_SUBSTRATE takes it, and so does this value; any other is refused by
# name (Assert-WindowsSubstrate). The vocabulary is the install-record schema's
# (properties.substrate.enum); a Pester test holds this value, and the
# variable's name, to it.
$WslSubstrate = 'k3s'

# The Windows floor: Windows 11, whose first build is 22000 (RFC-0175 D7; Windows
# 10 was dropped, client-dev#1810). The floor is the build, not the name: from
# build 22000 on, ProductName still reads "Windows 10".
$WslMinWindowsBuild = 22000

# Keep in lockstep with install.sh COSIGN_VERSION and cli release.yml's
# cosign-installer pin.
$CosignVersion = "v2.4.1"

# Who may SIGN the manifest -- deliberately a DIFFERENT constant from where it is
# DOWNLOADED ($repoRaw / $repoRel in Invoke-Bootstrap). Customers fetch from the
# public mirror (tracebloc/client), but the release is built and cosign-signed in
# the private source repo (tracebloc/client-dev, renamed from tracebloc/client on
# 2026-09-17), and the keyless certificate's SAN names the repo that RAN the
# release workflow: releases cut before the rename carry the old name, every
# release after it the new one. Trust exactly those two -- anything else is
# rejected. A verifier pinned to the old name alone fails every post-rename
# release; the CLI shipped that live (backend#3985, backend#3601 F).
# SAME set as install.sh's SIGNER_REPOS -- a Pester test holds the two in lockstep.
$SignerRepos = 'client|client-dev'
# Derived from that set and narrowed to the exact release workflow on a tag ref
# (every signed release to date carries .../release-helm-chart.yaml@refs/tags/vX.Y.Z),
# anchored at the start so a look-alike host or org cannot prefix its way in.
$SignerIdRe  = "^https://github\.com/tracebloc/($SignerRepos)/\.github/workflows/release-helm-chart\.yaml@refs/tags/v.*"

# =============================================================================
#  Logging helpers — match install-wsl.ps1 / install.sh UX.
# =============================================================================
function Info($m) { Write-Host "  " -NoNewline; Write-Host ([char]0x00B7) -ForegroundColor DarkGray -NoNewline; Write-Host " $m" -ForegroundColor DarkGray }
function Ok($m)   { Write-Host "  " -NoNewline; Write-Host ([char]0x2714) -ForegroundColor Green    -NoNewline; Write-Host " $m" }
function Warn($m) { Write-Host "  " -NoNewline; Write-Host ([char]0x26A0) -ForegroundColor Yellow   -NoNewline; Write-Host "  $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red      -NoNewline; Write-Host " $m" -ForegroundColor Red }

# =============================================================================
#  Ref resolution + validation (mirrors install.sh). Functions THROW on failure
#  so the test suite can assert fail-closed behaviour without the whole process
#  exiting; the main block below turns a throw into a red error + exit 1.
# =============================================================================

# Resolve the ref to fetch from and enforce the immutable-tag guarantees. Precedence:
# explicit $env:REF (pin a different release tag) > legacy $env:BRANCH (dev only)
# > the stamped $DefaultRef. Returns the validated ref string, or throws.
function Resolve-InstallRef {
  param(
    [string]$DefaultRef,
    [string]$RefEnv,
    [string]$BranchEnv,
    [bool]$AllowUnverified
  )

  $usingBranch = $false
  if ($RefEnv) {
    $ref = $RefEnv                 # explicit pin — honored as-is (still validated)
  } elseif ($BranchEnv) {
    $ref = $BranchEnv
    $usingBranch = $true
  } else {
    $ref = $DefaultRef
  }

  # If the published installer wasn't stamped with a real tag (e.g. someone ran a
  # raw checkout of install.ps1 off a branch instead of the released artifact),
  # $DefaultRef is still the placeholder. Refuse rather than silently fetch from
  # an unpinned location.
  if ($ref -eq "__TRACEBLOC_RELEASE_REF__") {
    if ($AllowUnverified) {
      Warn "No pinned release ref baked into this installer; falling back to 'main' because TRACEBLOC_ALLOW_UNVERIFIED=1."
      $ref = "main"
      $usingBranch = $true
    } else {
      throw "This installer wasn't stamped with a pinned release tag, so it can't verify what it fetches. Install from a release URL (irm https://github.com/tracebloc/client/releases/latest/download/install.ps1 | iex), or for local development only set `$env:TRACEBLOC_ALLOW_UNVERIFIED = '1'`."
    }
  }

  # Validate the ref shape (defends the URL we build from it).
  if ($ref -notmatch '^[a-zA-Z0-9._/-]+$') {
    throw "Invalid ref: $ref"
  }

  # A ref that isn't a vX.Y.Z tag is a mutable branch — the exact thing this pin closes.
  # Allow it only under the explicit unverified opt-in, and say so loudly. The
  # version-suffix class is restricted to [A-Za-z0-9.] (e.g. -rc1, .4): a looser
  # trailer would admit '/' and '..', letting a ref like 'v1.2.3-../../heads/main'
  # slip past this gate and fetch off the MUTABLE 'main' branch.
  if ($usingBranch -or $ref -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$') {
    if ($AllowUnverified) {
      Warn "============================================================================"
      Warn "UNVERIFIED INSTALL: fetching from mutable ref '$ref', signature checks"
      Warn "relaxed. This is for tracebloc development only -- never for a customer or"
      Warn "production box. A moved ref here can run arbitrary privileged code."
      Warn "============================================================================"
    } else {
      throw "'$ref' is not an immutable release tag (expected vX.Y.Z). The bootstrap only trusts content-addressable release tags so a moved branch ref can't change what runs as Administrator on your box. Use a release tag, or for local dev set `$env:TRACEBLOC_ALLOW_UNVERIFIED = '1'`."
    }
  }

  # Belt-and-suspenders: even after the shape checks above, refuse a parent-dir
  # token before the ref is interpolated into a URL. '..' is the traversal lever
  # -- it is what could escape the pinned tag onto a mutable branch
  # -- and it is refused on EVERY path, opt-in or not.
  if ($ref -match '\.\.') {
    throw "Ref '$ref' contains '..' -- refusing to build a fetch URL from it (path-traversal guard)."
  }

  # '/' IS NOT THE LEVER, AND REFUSING IT OUTRIGHT BROKE THE ONLY FLOW IT EXISTS
  # FOR (client#917). Every real development branch is `fix/1234-thing` or
  # `feat/...`, so a blanket refusal meant the documented developer override
  # could fetch `develop`, `staging` and `main` and NOTHING ELSE -- while the
  # whole point of the escape hatch is testing unreleased code, which lives on
  # feature branches. Measured on a real Windows box: the install stopped at
  # "contains a path separator" before it did anything.
  #
  # The immutable-tag property is unchanged, because it never rested on '/': a TAG still
  # cannot carry one (the vX.Y.Z shape check above rejects it, so a ref like
  # 'v1.2.3-../../heads/main' is refused twice over -- by that check and by the
  # '..' guard). A '/' is accepted ONLY on the path that has already announced
  # itself as an unverified branch install and printed the four-line warning.
  if ($ref -match '/') {
    if (-not ($usingBranch -and $AllowUnverified)) {
      throw "Ref '$ref' contains a path separator -- only a branch ref under TRACEBLOC_ALLOW_UNVERIFIED may contain one (path-traversal guard)."
    }
    # SEGMENT BY SEGMENT, so a multi-segment ref is held to exactly the same
    # shape as a single-segment one: no empty segment (which is a leading,
    # trailing or doubled slash), and no bare '.'.
    foreach ($seg in $ref.Split('/')) {
      if ($seg -eq '' -or $seg -eq '.' -or $seg -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Ref '$ref' has an invalid path segment -- refusing to build a fetch URL from it (path-traversal guard)."
      }
    }
  }

  return $ref
}

# =============================================================================
#  Fetch + integrity helpers.
# =============================================================================

# ONE backoff schedule for every release download -- the sub-scripts
# Get-WithRetry fetches and the optional trust assets Get-Optional gets -- so the
# two can't drift apart (parity with install.sh's DL_DELAYS). Each entry is the
# wait before the next attempt: $DlDelays.Count + 1 attempts over ~75 s. It used
# to be three attempts 5 s apart, ~10 s in all, and a GitHub 500 on a release
# asset one minute after the release was published outlasted that and failed a
# fresh install (client-dev#2053). Only a failure a wait can cure is retried: no
# answer (a timeout, a reset, DNS), 408, 429, or a 5xx; any other 4xx is the
# server's answer and returns at once. Invoke-WebRequest throws on a status alone
# only at 400 and above, so a thrown error that carries a lower status failed in
# transport (the body cut after 200, a redirect whose target never answered) and
# is retried too -- parity with install.sh's _dl_retriable.
$script:DlDelays = @(5, 10, 20, 40)

function Test-DownloadRetriable {
  param([int]$Code)
  return ($Code -lt 400 -or $Code -eq 408 -or $Code -eq 429 -or ($Code -ge 500 -and $Code -le 599))
}

# Fetch $Url to $Dest on the schedule above; $true = fetched, $false = not. Never
# throws. Leaves the last outcome in $script:FetchStatus (the HTTP code, or 'none'
# for no answer), $script:FetchTries, $script:FetchWaited (seconds slept),
# $script:FetchUrl and $script:FetchError, so a refusal can name them.
# Honors $env:HTTPS_PROXY for the corporate-proxy segment (#172/#722). Unlike curl
# in install.sh it does not currently apply $NO_PROXY exclusions or a custom CA
# bundle -- HTTPS_PROXY covers the common case.
$script:FetchStatus = ''
$script:FetchTries = 0
$script:FetchWaited = 0
$script:FetchUrl = ''
$script:FetchError = ''
function Invoke-DownloadOnSchedule {
  param(
    [string]$Url,
    [string]$Dest
  )
  # PS 5.1's progress overlay throttles Invoke-WebRequest massively (its render
  # loop dominates the transfer) and its "Writing request stream" banner reads
  # like a hang (#468). Function-local assignment -- the preference reverts
  # automatically when this function returns.
  $ProgressPreference = 'SilentlyContinue'
  $proxyArgs = @{}
  if ($env:HTTPS_PROXY) { $proxyArgs['Proxy'] = $env:HTTPS_PROXY }
  $max = $script:DlDelays.Count + 1
  $script:FetchUrl = $Url
  $script:FetchStatus = ''
  $script:FetchTries = 0
  $script:FetchWaited = 0
  $script:FetchError = ''
  while ($true) {
    $script:FetchTries++
    try {
      Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop @proxyArgs
      $script:FetchStatus = '200'
      return $true
    } catch {
      # PS 5.1 (WebException) and 7 (HttpResponseException) both carry the
      # response's StatusCode; a network error carries no response at all.
      $script:FetchError = "$_"
      $code = 0
      try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
      if ($code -gt 0) { $script:FetchStatus = "$code" } else { $script:FetchStatus = 'none' }
      if (-not (Test-DownloadRetriable -Code $code)) { return $false }
      if ($script:FetchTries -ge $max) { return $false }
      $delay = $script:DlDelays[$script:FetchTries - 1]
      Warn "Download failed (attempt $($script:FetchTries)/$max, status $($script:FetchStatus)). Retrying in ${delay}s..."
      Start-Sleep -Seconds $delay
      $script:FetchWaited += $delay
    }
  }
}

# A sub-script the installer can't run without: fetched on the schedule, or a
# throw naming the URL, the last status and how long it waited.
function Get-WithRetry {
  param(
    [string]$Url,
    [string]$Dest
  )
  if (Invoke-DownloadOnSchedule -Url $Url -Dest $Dest) { return }
  throw "Failed to download $Url (last status: $($script:FetchStatus)) after $($script:FetchTries) attempt(s) over $($script:FetchWaited)s: $($script:FetchError)"
}

# Try a download and never throw -- used for optional assets (manifest
# fall-through, sig/cert/bundle, the cosign checksums) where the caller decides
# fail-closed vs. opt-out. A 404 is an answer (a release cut before signing, or
# before the offline bundle, has no such asset), so it returns at once. A
# timeout, a reset, a 5xx is a blip and gets the same schedule Get-WithRetry
# gives every sub-script. These fetches used to be single-shot, so one dropped
# connection on the manifest refused the whole install as "couldn't fetch the
# integrity checksums" (backend#3020; parity with install.sh's fetch_optional).
function Get-Optional {
  param(
    [string]$Url,
    [string]$Dest
  )
  return (Invoke-DownloadOnSchedule -Url $Url -Dest $Dest)
}

# The cause sentence of a refusal over an optional asset Get-Optional couldn't
# get. $IfMissing is the advice for a 404 (the release doesn't publish it); any
# other status was the network, and pinning a different tag would not have helped.
function Get-FetchRefusalCause {
  param([string]$IfMissing)
  if ($script:FetchStatus -eq '404') { return $IfMissing }
  return "Downloading $($script:FetchUrl) failed after $($script:FetchTries) attempt(s) over $($script:FetchWaited)s (last status: $($script:FetchStatus)) -- check your network or proxy and re-run."
}

# Where to fetch one sub-script from. Customer path -> the RELEASE ASSET
# addressed by basename ("$RepoRel/<name>"), and ONLY the release asset: the
# customer path never reads the source tree, so it can never fetch from
# raw.githubusercontent (backend#3998). Dev/unverified path -> the source TREE
# ("$RepoRaw/scripts/..."), DELIBERATELY tree-only: it does not prefer or fall
# back to the release asset (unlike Confirm-ManifestSignature's manifest fetch,
# which is release-first), because a privileged sub-script must come from exactly
# the one place the operator chose. Coherent only against a ref whose tree
# $RepoRaw serves; set TRACEBLOC_SOURCE_REPO to a source you control (a public
# fork). Parity with install.sh's subscript_url; a Pester test holds the two in
# lockstep.
function Get-SubscriptUrl {
  param(
    [string]$File,
    [string]$RepoRaw,
    [string]$RepoRel,
    [bool]$AllowUnverified
  )
  if ($AllowUnverified) {
    return "$RepoRaw/$File"
  }
  return "$RepoRel/" + (Split-Path -Leaf $File)
}

# Print a dim heartbeat dot every $TickSeconds while $Job runs — a quiet window
# on a multi-minute step reads as a hang and gets killed (#468; the same honest-
# progress philosophy as #449). Returns
# $true once the job has left the Running state on its own; $false if it is
# still running after $TimeoutSeconds (the job is stopped, caller owns Remove-Job).
function Wait-JobWithTicks {
  param(
    [object]$Job,
    [int]$TimeoutSeconds,
    [int]$TickSeconds = 3
  )
  $elapsed = 0
  $ticked = $false
  while (($Job.State -eq 'Running' -or $Job.State -eq 'NotStarted') -and $elapsed -lt $TimeoutSeconds) {
    Start-Sleep -Seconds $TickSeconds
    $elapsed += $TickSeconds
    if ($Job.State -ne 'Running' -and $Job.State -ne 'NotStarted') { break }
    if (-not $ticked) { Write-Host -NoNewline "  " }
    Write-Host -NoNewline "." -ForegroundColor DarkGray
    $ticked = $true
  }
  if ($ticked) { Write-Host "" }
  if ($Job.State -eq 'Running' -or $Job.State -eq 'NotStarted') {
    Stop-Job $Job -ErrorAction SilentlyContinue
    return $false
  }
  return $true
}

# Get-Optional for a LARGE asset: the same $true/$false, never-throw contract,
# but ONE attempt (a wedged transfer already waits out the timeout below, and a
# retry would wait it out again), and the fetch runs in a background job so the
# parent can tick a liveness dot.
# The job re-applies the TLS 1.2 floor (fresh powershell.exe — PS 5.1 defaults
# to TLS 1.0), silences the progress overlay (#468), and pins its cwd to a local
# directory so UNC-homed roaming profiles don't splash red noise (#409). The
# timeout only bounds a wedged transfer; a slow-but-moving download must never
# be killed — that is the exact failure mode this function exists to prevent.
function Get-OptionalWithTicks {
  param(
    [string]$Url,
    [string]$Dest,
    [int]$TimeoutMinutes = 30
  )
  $job = Start-Job -InitializationScript { if ($env:SystemRoot) { Set-Location $env:SystemRoot } } -ScriptBlock {
    param($u, $d, $proxy)
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $proxyArgs = @{}
    if ($proxy) { $proxyArgs['Proxy'] = $proxy }
    Invoke-WebRequest -Uri $u -OutFile $d -UseBasicParsing -ErrorAction Stop @proxyArgs
  } -ArgumentList $Url, $Dest, $env:HTTPS_PROXY

  if (-not (Wait-JobWithTicks -Job $job -TimeoutSeconds ($TimeoutMinutes * 60))) {
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Err "Download still running after $TimeoutMinutes minutes -- giving up: $Url"
    return $false
  }
  $ok = ($job.State -eq 'Completed')
  try { Receive-Job $job -ErrorAction Stop | Out-Null } catch { $ok = $false }
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  return ($ok -and (Test-Path -LiteralPath $Dest))
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
# the signed manifest is their list and nothing restates it. Byte-
# identical in install-wsl.ps1, which checks the same set in the tree it is given.
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

# Resolve a usable cosign into a path. Prefer one already on PATH; else fetch the
# pinned release binary for this OS/arch from the cosign GitHub release and verify
# it against its published checksums before use (a cosign we can't vouch for is no
# better than no cosign). Returns the cosign path, or $null on failure.
function Resolve-Cosign {
  param([string]$TmpDir)
  $onPath = Get-Command cosign -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }

  # BOTH architectures fetch the amd64 build, deliberately.
  #
  # Sigstore has never published a Windows arm64 cosign — not at $CosignVersion,
  # not at any release. `cosign-windows-amd64.exe` is the only Windows asset there
  # is. Asking for `cosign-windows-arm64.exe` (as this did) 404s, Resolve-Cosign
  # returns $null, and a Windows-on-ARM install fails closed reading like a network
  # blip — permanently, since retrying cannot conjure the asset.
  #
  # Running it under Windows-on-ARM's x64 emulation costs nothing that matters:
  # cosign verifies a signature over BYTES, so the instruction set it was compiled
  # for cannot change the verdict, and the binary we hand it is still the native
  # arm64 one. The bootstrapped cosign is checksum-verified below exactly as on
  # amd64, so the trust chain is identical.
  #
  # Do not "fix" this back to $arch. There is nothing on the other end.
  switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { }
    "ARM64" { }
    default { return $null }
  }
  $base  = "https://github.com/sigstore/cosign/releases/download/$CosignVersion"
  $asset = "cosign-windows-amd64.exe"
  $bin   = Join-Path $TmpDir "cosign.exe"
  $sums  = Join-Path $TmpDir "cosign_checksums.txt"

  # The checksums first (a few KB): they vouch for a handed-down cosign too.
  if (-not (Get-Optional "$base/cosign_checksums.txt" $sums)) { return $null }

  # cosign_checksums.txt lines: "<sha256>␠␠<asset>". Take the one for our asset.
  $want = $null
  foreach ($line in Get-Content -LiteralPath $sums) {
    $parts = @($line -split '\s+' | Where-Object { $_ -ne '' })
    if ($parts.Count -ge 2 -and $parts[-1] -eq $asset) { $want = $parts[0].ToLower(); break }
  }
  if (-not $want) { return $null }

  # The website shim (tracebloc.io/i.ps1) has usually just fetched and digest-checked
  # this same pinned build to verify THIS script, into its own temp folder, which
  # is not on PATH. TRACEBLOC_COSIGN hands that path down so it is not downloaded a
  # second time (~180 MB, client-dev#2848). It is used only when it IS the pinned
  # build -- the same checksum a fresh download must match -- so any other file
  # there costs one warning and the download below, never trust.
  $handed = $env:TRACEBLOC_COSIGN
  if ($handed) {
    if ((Test-Path -LiteralPath $handed -PathType Leaf) -and ((Get-Sha256 $handed) -eq $want)) {
      return $handed
    }
    Warn "TRACEBLOC_COSIGN ($handed) is not cosign $CosignVersion for Windows -- downloading it instead."
  }

  # Set expectations BEFORE the big fetch: this is the bootstrap's one large
  # download, and during v1.9.7-rc.1 FR a healthy install got killed as
  # "frozen" in exactly this window (#468). The size is cosign-windows-amd64.exe's
  # at the pin: 186,998,456 bytes (client-dev#2848; it said ~17 MB).
  Info "cosign not found -- downloading pinned cosign $CosignVersion (~180 MB) to verify the manifest."
  Info "This is the bootstrap's one big download; a few minutes on a slow network is normal."
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  if (-not (Get-OptionalWithTicks "$base/$asset" $bin)) { return $null }
  if ((Get-Sha256 $bin) -ne $want) {
    Err "Bootstrapped cosign failed its own checksum -- not using it."
    return $null
  }
  Ok "cosign $CosignVersion downloaded and checksum-verified ($([math]::Round($sw.Elapsed.TotalSeconds))s)"
  return $bin
}

# Run cosign verify-blob with the fail-closed sentinel + stderr suppression, returning
# $true iff it verified. Shared by Confirm-ManifestSignature's offline-bundle and online
# sig/cert paths so the hardening lives in ONE place:
#  - $LASTEXITCODE is seeded to a NONZERO sentinel first, so a cosign that returns
#    WITHOUT setting it (corrupt / AV-quarantined / wrong exec format) fails closed,
#    never a stale 0 read as "verified".
#  - stderr is merged to stdout and discarded: a native tool writing to stderr would
#    otherwise surface as a NativeCommandError dumping this script's source line +
#    internal identifiers into the console/transcript (#576).
# Can this cosign actually EXECUTE here? A trivial `cosign version`.
#
# Invoke-CosignVerifyBlob fails closed on a binary that won't start (the 255
# sentinel is never overwritten, or the call throws) — correct, but it reports it
# identically to a signature that did not verify. Those are different events with
# different remedies, and only one of them means "this artifact may be tampered
# with". Windows-on-ARM makes the distinction real: the amd64 cosign we fetch runs
# under x64 emulation, and where that emulation is absent the binary cannot start
# at all. Telling that user their download failed verification would be alarming
# and wrong.
#
# Same shape as Invoke-CosignVerifyBlob deliberately: the 255 preset means a
# binary that never runs cannot leave a stale 0 behind.
function Test-CosignRuns {
  param([Parameter(Mandatory)][string]$Cosign)
  $global:LASTEXITCODE = 255
  $prevEAP = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $Cosign version 2>&1 | Out-Null
  } catch {
    return $false
  } finally {
    $ErrorActionPreference = $prevEAP
  }
  return ($LASTEXITCODE -eq 0)
}

# -TufRoot: cosign keeps the TUF root it verifies with under $env:TUF_ROOT, else
# under ~/.sigstore/root (v2.4.1 and v3 alike, measured), and nothing removed that
# folder: every install left ~/.sigstore behind (client-dev#1615). TUF_ROOT is set
# for this one call to a folder inside the run's TmpDir, which goes with it, and put
# back as it was in `finally` -- this script may run in the user's own session
# (irm | iex), where a process variable would outlive it. Their own TUF_ROOT is held
# only to be restored; it never names the cache, and their ~/.sigstore is never
# written. A ~/.sigstore an earlier install left stays: it cannot be told from one
# the user's own cosign made.
function Invoke-CosignVerifyBlob {
  param([Parameter(Mandatory)][string]$Cosign, [Parameter(Mandatory)][string[]]$VerifyArgs,
        [Parameter(Mandatory)][string]$TufRoot)
  $global:LASTEXITCODE = 255
  $prevEAP = $ErrorActionPreference
  $prevTuf = [Environment]::GetEnvironmentVariable('TUF_ROOT', 'Process')
  try {
    $ErrorActionPreference = 'Continue'
    [Environment]::SetEnvironmentVariable('TUF_ROOT', $TufRoot, 'Process')
    & $Cosign @VerifyArgs 2>&1 | Out-Null
  } catch {
    return $false
  } finally {
    $ErrorActionPreference = $prevEAP
    # Unset stays unset: on .NET 9 and later (pwsh 7.5+), setting a variable to
    # $null keeps it, empty, so the restore would leave TUF_ROOT="" in the session.
    if ($null -eq $prevTuf) {
      Remove-Item Env:TUF_ROOT -ErrorAction SilentlyContinue
    } else {
      [Environment]::SetEnvironmentVariable('TUF_ROOT', $prevTuf, 'Process')
    }
  }
  return ($LASTEXITCODE -eq 0)
}

# Authenticate manifest.sha256 with cosign keyless before trusting a single digest
# in it. The signing identity is the client release workflow's OIDC certificate
# (same chain as install.sh + the CLI binary). Fail-closed unless the operator
# explicitly accepted the risk. Throws on failure.
function Confirm-ManifestSignature {
  param(
    [string]$Manifest,
    [string]$RepoRel,
    [string]$TmpDir,
    [bool]$AllowUnverified
  )
  # An explicit corporate CA can't be wired into cosign via env on Windows: cosign is
  # Go, and Go on Windows reads the certificate store and IGNORES SSL_CERT_FILE
  # (Bugbot). So there's nothing to export here — the CA must live in the Windows
  # store (Cert:\LocalMachine\Root), or use the offline installer path (#584).
  # We still validate the path so a typo fails fast with a clear message rather than
  # a later generic cosign authenticity error.
  $ca = if ($env:TRACEBLOC_CA_BUNDLE) { $env:TRACEBLOC_CA_BUNDLE } elseif ($env:CURL_CA_BUNDLE) { $env:CURL_CA_BUNDLE } else { $null }
  if ($ca) {
    if (-not (Test-Path -LiteralPath $ca -PathType Leaf)) {
      throw "A CA bundle is set (TRACEBLOC_CA_BUNDLE/CURL_CA_BUNDLE) but no such file exists at '$ca' - fix its path and re-run."
    }
    # Existence isn't enough: a present-but-unreadable file must fail here too (mirrors
    # bash's -r and Resolve-CaBundle), not as a later generic cosign error (Bugbot).
    try { [System.IO.File]::OpenRead($ca).Dispose() }
    catch { throw "A CA bundle is set (TRACEBLOC_CA_BUNDLE/CURL_CA_BUNDLE) but '$ca' can't be read ($($_.Exception.Message)) - fix its permissions and re-run." }
  }

  $cosign = Resolve-Cosign -TmpDir $TmpDir
  if (-not $cosign) {
    if ($AllowUnverified) {
      Warn "cosign unavailable -- the installer's signature NOT verified (TRACEBLOC_ALLOW_UNVERIFIED=1)."
      Warn "Proceeding on checksum-only integrity. Not for production."
      return
    }
    throw "cosign is required to verify the installer's signature and couldn't be found or bootstrapped. Refusing to fall back to an unauthenticated, same-channel checksum. Fix: install cosign (https://docs.sigstore.dev/cosign/installation/) and re-run, or for local development only set `$env:TRACEBLOC_ALLOW_UNVERIFIED = '1'`."
  }

  # We have a cosign; prove it can run before any failure it reports is read as a
  # bad signature. On Windows-on-ARM the amd64 build (the only one sigstore ships)
  # needs x64 emulation; without it the binary never starts. Still fail closed —
  # but say the true reason, because "your download may be tampered with" and "the
  # verifier won't start on this machine" call for opposite reactions.
  if (-not (Test-CosignRuns $cosign)) {
    if ($AllowUnverified) {
      Warn "cosign can't run on this machine -- the installer's signature NOT verified (TRACEBLOC_ALLOW_UNVERIFIED=1)."
      Warn "Proceeding on checksum-only integrity. Not for production."
      return
    }
    # Deliberately suggests no second cosign (Bugbot). We already HAVE a cosign
    # here -- it will not start. Another copy of the same amd64 build, the only one
    # sigstore publishes, reproduces the failure exactly. A remedy that cannot clear
    # the error is worse than none: it costs the user a round trip and teaches them
    # the message is noise.
    throw "cosign was obtained but won't run on this machine, so the installer's signature can't be checked. This is NOT a failed verification -- nothing suggests the download is bad. Two things cause it: security software may have quarantined or blocked the downloaded cosign.exe (check your antivirus / SmartScreen and allow it); or, on Windows-on-ARM, x64 emulation is unavailable -- Windows 11 on ARM includes it, Windows 10 on ARM may not, and sigstore publishes no native arm64 cosign to fall back on, so one would have to be built from source and put on PATH. For local development only you can set `$env:TRACEBLOC_ALLOW_UNVERIFIED = '1'`."
  }

  # The keyless signing identity: the release workflow's OIDC cert, from the ONE
  # declaration at the top ($SignerIdRe -- both repo names, exact workflow, tag
  # ref). SAME pins as install.sh; shared by both verification paths below.
  $idRe   = $SignerIdRe
  $issuer = 'https://token.actions.githubusercontent.com'

  # OFFLINE Sigstore bundle first (#584): the bundle carries the Rekor inclusion
  # proof, so this verifies signature + cert identity + tlog inclusion with NO live
  # Rekor call — immune to networks that block/TLS-inspect sigstore, and the only
  # path that verifies our short-lived keyless cert once it has expired (its embedded
  # timestamp proves the cert was valid at signing). Releases cut before the bundle
  # existed 404 here and fall through to the online .sig/.cert path; so does a bundle
  # that doesn't verify — the online path does the SAME full keyless check, just
  # needing live Rekor, so this is a fallback, never a downgrade.
  $tufRoot = Join-Path $TmpDir "sigstore-root"
  $bundle = Join-Path $TmpDir "manifest.sha256.bundle"
  if (Get-Optional "$RepoRel/manifest.sha256.bundle" $bundle) {
    if (Invoke-CosignVerifyBlob -TufRoot $tufRoot $cosign @(
          'verify-blob',
          '--bundle', $bundle,
          '--certificate-identity-regexp', $idRe,
          '--certificate-oidc-issuer', $issuer,
          '--offline',
          $Manifest)) {
      Ok "Download verified as published by tracebloc."
      return
    }
  }

  $sig  = Join-Path $TmpDir "manifest.sha256.sig"
  $cert = Join-Path $TmpDir "manifest.sha256.cert"
  if (-not (Get-Optional "$RepoRel/manifest.sha256.sig"  $sig) -or
      -not (Get-Optional "$RepoRel/manifest.sha256.cert" $cert)) {
    if ($AllowUnverified) {
      Warn "The installer's signature isn't published for this ref -- not verified (TRACEBLOC_ALLOW_UNVERIFIED=1)."
      return
    }
    throw ("Couldn't fetch the installer's signature for this release -- can't confirm the download is authentic. " + (Get-FetchRefusalCause "This release doesn't publish one. Pin a release tag that ships it."))
  }

  if (Invoke-CosignVerifyBlob -TufRoot $tufRoot $cosign @(
        'verify-blob',
        '--certificate-identity-regexp', $idRe,
        '--certificate-oidc-issuer', $issuer,
        '--certificate', $cert,
        '--signature', $sig,
        $Manifest)) {
    Ok "Download verified as published by tracebloc."
  } else {
    throw "Couldn't confirm the installer download is authentic, so the install stopped before changing anything on your machine."
  }
}

# Verify each fetched sub-script against the signed manifest. A missing manifest
# entry or a digest mismatch ABORTS — before any privileged sub-script runs.
function Confirm-ScriptIntegrity {
  param(
    [string]$Manifest,
    [string]$TmpDir,
    [string[]]$Files
  )
  foreach ($f in $Files) {
    $rel      = $f                                   # manifest keys are repo-relative: scripts/...
    $local    = Join-Path $TmpDir ($f -replace '^scripts/', '')
    $expected = Find-ManifestDigest -ManifestPath $Manifest -Key $rel
    if (-not $expected) {
      throw "$rel isn't in the installer's signed checksum list -- refusing to run it."
    }
    $actual = Get-Sha256 -Path $local
    if ($actual -ne $expected) {
      throw "Integrity check FAILED for $rel`n          expected: $expected`n          actual:   $actual`n        Someone may have tampered with the installer. Aborting before any privileged step runs."
    }
  }
  Ok "all installer scripts verified against the signed manifest"
}

# This machine's Windows build and name, from one registry key, or $null where
# they cannot be read (off Windows, the test suite). Below build 22000 the key's
# ProductName is the machine's own ("Windows 10 Pro", "Windows Server 2022
# Datacenter"), so a refusal can name it.
function Get-WindowsBuildInfo {
  try {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    return [pscustomobject]@{ Build = [int]$cv.CurrentBuildNumber; Name = [string]$cv.ProductName }
  } catch { return $null }
}

# Assert-WslWindowsBuild -- the install refuses Windows older than Windows 11 by
# name. A build it cannot read is refused too, saying what it could not read: one
# contract with the Mac floor, whose verdict refuses a macOS version it cannot read.
function Assert-WslWindowsBuild {
  $os = Get-WindowsBuildInfo
  if ($null -eq $os) {
    throw "This installer could not read this machine's Windows build (CurrentBuildNumber under HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion), so it cannot tell whether this is Windows 11. The tracebloc install needs Windows 11 (build $WslMinWindowsBuild or later)."
  }
  if ($os.Build -lt $WslMinWindowsBuild) {
    $name = if ($os.Name) { $os.Name } else { 'Windows' }
    throw "This machine runs $name (build $($os.Build)). The tracebloc install needs Windows 11 (build $WslMinWindowsBuild or later). Update to Windows 11, then run the install again."
  }
}

# Assert-WindowsSubstrate -- Windows sets up one runtime, $WslSubstrate in the
# tracebloc WSL distro. Any other TRACEBLOC_SUBSTRATE is refused by name, as the
# shell installer refuses a runtime it cannot set up: never read as the distro, so
# a run that asked for another runtime does not get the distro instead. Blank means
# unset, as for every TRACEBLOC_* setting.
function Assert-WindowsSubstrate {
  $asked = [string]$env:TRACEBLOC_SUBSTRATE
  if ($asked -and $asked -cne $WslSubstrate) {
    throw "TRACEBLOC_SUBSTRATE='$asked' is not a runtime this installer can set up on Windows (it supports: $WslSubstrate, in the tracebloc WSL distro). Nothing was changed. Unset it, then run the install again."
  }
}

# =============================================================================
#  Orchestration.
# =============================================================================
function Invoke-Bootstrap {
  param([object[]]$BootstrapArgs)

  # The bootstrap takes no arguments, and install-wsl.ps1 takes only the tree. One
  # it was given is refused before anything is fetched, so a -Help never installs.
  if ($BootstrapArgs -and $BootstrapArgs.Count -gt 0) {
    throw "This installer takes no arguments, and it was given: $($BootstrapArgs -join ' '). Nothing was changed. Run it again without them."
  }
  # The runtime asked for, and the Windows floor, before anything is fetched or
  # written.
  Assert-WindowsSubstrate
  Assert-WslWindowsBuild

  $allowUnverified = ($env:TRACEBLOC_ALLOW_UNVERIFIED -eq "1")
  # Settings naming (backend#3846): TRACEBLOC_REF / TRACEBLOC_BRANCH first, the
  # legacy REF / BRANCH after them (remove_by 2026-12-31); a non-empty canonical
  # wins, the bash bootstrap's rule.
  $refEnv    = if ($env:TRACEBLOC_REF) { $env:TRACEBLOC_REF } else { $env:REF }
  $branchEnv = if ($env:TRACEBLOC_BRANCH) { $env:TRACEBLOC_BRANCH } else { $env:BRANCH }
  $ref = Resolve-InstallRef -DefaultRef $DefaultRef -RefEnv $refEnv -BranchEnv $branchEnv -AllowUnverified $allowUnverified

  # Everything the customer path fetches -- the sub-scripts (attached as flat
  # release assets by basename), the signed manifest, and its cosign sig/cert --
  # is served from the RELEASE ASSETS ($repoRel). backend#3998: the public mirror
  # carries no scripts/ tree (its default branch is .github + README only, and no
  # tag exposes scripts/), so the old raw-by-tag transport 404s for every customer
  # tag; and even where a tree IS present on the mirror it tracks only the newest
  # stable publish, so raw-by-tag of an older or pre-release tag would serve
  # another release's bytes and fail the signature check. Release assets are
  # per-tag and immutable, so they are the correct transport for the sub-script
  # content. Every fetched byte is still verified against the signed manifest
  # below, so serving from the release changes the transport, not the integrity
  # guarantee. (Signing happens in CI after the tag is cut, so the manifest's
  # authenticity material was always a release asset -- the same pattern the CLI
  # uses for SHA256SUMS.)
  #
  # $repoRaw is the source TREE, a dev/unverified-only transport. It reads from
  # $TRACEBLOC_SOURCE_REPO (default tracebloc/client, which has no scripts/ tree),
  # so a maintainer iterating on an unreleased BRANCH points it at a source whose
  # raw tree is readable -- a public fork. Validate the owner/repo shape before it
  # is interpolated into a URL: exactly one '/' and shell-safe chars. The character
  # class admits '.', so a segment could be all dots ('a/..' matches) -- reject '..'
  # explicitly, the same parent-dir traversal lever $ref guards against.
  $sourceRepo = if ($env:TRACEBLOC_SOURCE_REPO) { $env:TRACEBLOC_SOURCE_REPO } else { "tracebloc/client" }
  if ($sourceRepo -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' -or $sourceRepo -match '\.\.') {
    throw "TRACEBLOC_SOURCE_REPO='$sourceRepo' is not a valid owner/repo."
  }
  $repoRaw = "https://raw.githubusercontent.com/$sourceRepo/$ref"
  $repoRel = "https://github.com/tracebloc/client/releases/download/$ref"

  # Unpredictable, per-run temp dir (a GUID, not Get-Random) that must NOT already
  # exist — defeats a local attacker pre-creating it to race a sub-script write in
  # before the integrity check (parity with install.sh's `mktemp -d`, 0700).
  $tmpDir = Join-Path $env:TEMP ("tracebloc-installer-" + [guid]::NewGuid().ToString('N'))
  if (Test-Path -LiteralPath $tmpDir) {
    throw "temp dir $tmpDir already exists -- refusing to reuse it."
  }
  New-Item -ItemType Directory -Path $tmpDir | Out-Null
  try {
    Info "Downloading tracebloc client installer (ref: $ref)..."

    # ── Fetch the sub-scripts (release assets on the customer path) ──
    $fetch = {
      param([string]$f)
      $dest = Join-Path $tmpDir ($f -replace '^scripts/', '')
      # CREATE THE PARENT FIRST. The bash core's keys include `scripts/lib/`
      # entries, and Invoke-WebRequest -OutFile does not create
      # directories: without this the very first fetch of a lib file throws
      # DirectoryNotFound and the Windows bootstrap dies before it verifies
      # anything. install.sh has always done the equivalent `mkdir -p`. This
      # weakens no integrity property — every fetched file is still checked
      # against the signed manifest below.
      $destDir = Split-Path -Parent $dest
      if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
      }
      $src = Get-SubscriptUrl -File $f -RepoRaw $repoRaw -RepoRel $repoRel -AllowUnverified $allowUnverified
      Get-WithRetry -Url $src -Dest $dest
    }
    foreach ($f in $Files) { & $fetch $f }

    # ── Fetch + authenticate the manifest, then check every sub-script ──
    $manifest = Join-Path $tmpDir "manifest.sha256"
    if (-not (Get-Optional "$repoRel/manifest.sha256" $manifest)) {
      if ($allowUnverified -and (Get-Optional "$repoRaw/scripts/manifest.sha256" $manifest)) {
        Warn "Using in-repo integrity checksums from ref '$ref' (TRACEBLOC_ALLOW_UNVERIFIED=1)."
      } elseif ($allowUnverified) {
        Warn "No integrity checksums for ref '$ref' -- skipping the integrity check (TRACEBLOC_ALLOW_UNVERIFIED=1)."
        $manifest = $null
      } else {
        throw ("Couldn't fetch the installer's integrity checksums for ref '$ref' -- refusing to run unverified installer scripts. " + (Get-FetchRefusalCause "If this ref pre-dates signed releases, pin a newer release tag."))
      }
    }

    if ($manifest) {
      Confirm-ManifestSignature -Manifest $manifest -RepoRel $repoRel -TmpDir $tmpDir -AllowUnverified $allowUnverified
      # The distro path also runs the bash core inside WSL: the authenticated
      # manifest's own list of its scripts, fetched now and checked with the rest.
      # With no manifest there is no list, and install-wsl.ps1 refuses the tree.
      $verify = @($Files)
      $core = @(Get-CoreScriptKeys -ManifestPath $manifest)
      foreach ($f in $core) { & $fetch $f }
      $verify += $core
      Confirm-ScriptIntegrity -Manifest $manifest -TmpDir $tmpDir -Files $verify
    }

    # ── Run the verified main installer ──
    # Hand the resolved ref down, exactly as install.sh:247 exports
    # TRACEBLOC_INSTALL_REF. install-wsl.ps1 runs as a CHILD process, so an
    # environment variable set here is inherited, and it hands the value to the
    # core in the distro. Without it `service.version` on
    # every Windows telemetry record was permanently "0.0.0-unknown" — the field
    # that says WHICH installer failed, on the platform this feature was added for.
    # (Found by the derived ScriptVar test, not by review.)
    $env:TRACEBLOC_INSTALL_REF = $ref

    # The distro path (RFC-0175 D2, D7; client-dev#1810). Its one input is the tree
    # verified just above: install-wsl.ps1 checks it again and refuses any other,
    # and there is no way to hand it an unverified one. Its exit code goes through
    # unchanged: 2 is the declared "restart, then re-run" handoff.
    $wsl = Join-Path $tmpDir "install-wsl.ps1"
    Info "Running tracebloc WSL setup..."
    & powershell.exe -ExecutionPolicy Bypass -File $wsl -CoreDir $tmpDir
    $childExit = $LASTEXITCODE
  } finally {
    # Before the hold, not after it (client-dev#2847): Complete-Bootstrap waits up
    # to a minute for a key, and a window closed in that minute ends this process
    # without running a `finally` still waiting below it.
    Remove-InstallerTemp -Path $tmpDir | Out-Null
  }
  Complete-Bootstrap -Code $childExit
}

# Remove this run's temp folder (~180 MB with a bootstrapped cosign.exe), and SAY
# so when it cannot be removed (client-dev#2847). One Remove-Item used to do this,
# silently: on Windows a file just written or run is often still held for a moment
# (Defender scanning a fresh .exe, the image of a process that only just exited),
# and Windows PowerShell 5.1's -Recurse deletes children asynchronously, so the
# folder itself can still read "not empty" when it is removed. Either left
# %TEMP%\tracebloc-installer-* behind with nothing said. So: retry a few times a
# second apart, and if it is still there, one warning naming the folder.
function Remove-InstallerTemp {
  param([Parameter(Mandatory)][string]$Path, [int]$Tries = 5, [int]$DelayMs = 1000)
  for ($i = 1; $i -le $Tries; $i++) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if ($i -lt $Tries) { Start-Sleep -Milliseconds $DelayMs }
  }
  Warn "The installer's temporary folder could not be removed (a file in it is still in use): $Path -- it is safe to delete it yourself."
  return $false
}

# =============================================================================
#  EXITING WITHOUT TAKING THE USER'S WINDOW WITH IT (#577, client#917)
# =============================================================================
# #577 made the installer always show a clean "what happened" instead of
# vanishing -- and it fixed that in the installer's CHILD process, where
# `exit` is harmless. THIS file is the other half, and it was
# missed: the documented entry point is `irm ... | iex`, so this script runs
# INSIDE the user's own console. A top-level `exit` there ends THEIR session --
# the window closes and takes the outcome with it.
#
# And it is not only the failure paths. `exit $LASTEXITCODE` after the child
# returns fires on EVERY run, so a perfectly successful install also slammed the
# window shut over its own summary. Reported from a real Windows machine: "it
# just closed the PowerShell".
#
# The exit CODE must still propagate untouched -- the e2e harness reads it to
# tell install-wsl.ps1's declared `exit 2` restart handoff from a real failure --
# so this does not swap `exit` for `return`, which would silently turn every
# code into 0 for `powershell.exe -Command` callers. It holds the window open
# just long enough to be read, then exits exactly as before.
#
# Can we prompt? Same predicate install-wsl.ps1 uses, deliberately: false under
# CI, a service, or piped/redirected stdin -- every context where a hold would
# be a hang and where no human is losing a window anyway. Note this predicate is
# a best-effort filter, NOT a guarantee: an interactive Windows desktop session
# satisfies both conjuncts, so the e2e journey may well take the HOLD path. That
# is safe because the hold is bounded (60s/run) and the exit code is unchanged --
# the correctness of this function must not, and does not, rest on the predicate.
function Test-BootstrapCanPrompt {
  try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) }
  catch { return $false }
}

# BOUNDED, because an unbounded hold is the bug we spent this whole ticket
# removing. 60s is long enough to read a summary or an error and short enough
# that a forgotten window closes itself. A host that cannot report keystrokes
# (ISE, a redirected console) throws on KeyAvailable -- caught, and treated as
# "nothing is waiting to be read".
function Complete-Bootstrap {
  param([int]$Code, [int]$HoldSec = 60)
  if (Test-BootstrapCanPrompt) {
    try {
      Write-Host ""
      Write-Host "  This window closes when you press a key (or in ${HoldSec}s)." -ForegroundColor DarkGray
      $deadline = (Get-Date).AddSeconds($HoldSec)
      # DRAIN FIRST. KeyAvailable reports whatever is sitting in the console input
      # buffer, not a press since the hold began -- and install-wsl.ps1 just ran as a
      # child on THIS console, with its own prompts. Any key the user tapped during
      # a 15-40 minute install (an extra Enter at a prompt, the trailing newline of
      # `irm ... | iex`, a keystroke at a spinner) is still queued, would make
      # the `while` false on its FIRST evaluation, and would close the window over the
      # summary -- reproducing the exact #577 failure this function exists to stop,
      # under a line that just promised to wait.
      while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
      while (-not [Console]::KeyAvailable -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
      if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
    } catch {}
  }
  exit $Code
}

# =============================================================================
#  Main. $env:TRACEBLOC_PESTER lets the test suite dot-source this file to load the
#  functions without tripping the platform gate (which exits off-Windows) or
#  running the bootstrap.
# =============================================================================
if (-not $env:TRACEBLOC_PESTER) {
  # ── Platform gate ──
  if ($PSVersionTable.PSEdition -eq "Core" -and -not $IsWindows) {
    Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red -NoNewline
    Write-Host " This script is for Windows. On macOS / Linux use:" -ForegroundColor Red
    Write-Host "  curl -fsSL https://github.com/tracebloc/client/releases/latest/download/install.sh | bash" -ForegroundColor Cyan
    # A BARE exit, deliberately, and the only one outside Complete-Bootstrap. This
    # branch is reachable only on macOS/Linux (`Core -and -not $IsWindows`), where
    # this script runs as a child `pwsh` and `exit` closes no window at all -- and
    # where [Environment]::UserInteractive is hardcoded $true on non-Windows .NET,
    # so Test-BootstrapCanPrompt would say "yes" and stall an instant, zero-cost
    # bail-out for 60s. There is no window to lose here; holding only wastes time.
    exit 1
  }
  # TLS 1.2 floor — Windows PowerShell 5.1 otherwise negotiates down to TLS 1.0.
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  try {
    Invoke-Bootstrap -BootstrapArgs $args
  } catch {
    # Clean, branded failure — never a raw stack (#577). "$_" stringifies to the
    # exception MESSAGE (curated at the throw sites, #576), not the source/stack.
    Write-Host ""
    Err "Installation stopped: $_"
    Write-Host "  It's safe to re-run this installer. If it keeps failing, share the output above with tracebloc support." -ForegroundColor DarkGray
    Complete-Bootstrap -Code 1
  }
}
