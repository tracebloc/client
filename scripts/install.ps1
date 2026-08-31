# =============================================================================
#  Bootstrap installer (Windows) — the R8 signed-installer trust root, Windows
#  side. This is the PowerShell peer of scripts/install.sh; the two implement
#  the SAME supply-chain guarantee (RFC-0001 R8, tracebloc/backend#889):
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
#  Usage (PowerShell as Administrator):
#    irm https://raw.githubusercontent.com/tracebloc/client/<TAG>/scripts/install.ps1 | iex
#    # or, from the signed release asset (auto-pins to the latest release):
#    irm https://github.com/tracebloc/client/releases/latest/download/install.ps1 | iex
#
#  Developer / unreleased-branch override (UNVERIFIED — not for customers):
#    $env:BRANCH = "develop"; $env:TRACEBLOC_ALLOW_UNVERIFIED = "1"
#    irm https://raw.githubusercontent.com/tracebloc/client/develop/scripts/install.ps1 | iex
#
#  macOS / Linux:
#    curl -fsSL https://raw.githubusercontent.com/tracebloc/client/<TAG>/scripts/install.sh | bash
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
  "scripts/install-k8s.ps1"
  # The outcome emitter (backend#2268). A separate file rather than 500 more
  # lines inside install-k8s.ps1, for the same reason the bash side keeps
  # lib/telemetry.sh separate: it is the one part of the installer with its own
  # unit suite (scripts/tests/telemetry.Tests.ps1), and it is verified against
  # the signed manifest exactly like every other fetched script.
  "scripts/lib/telemetry.ps1"
)

# Keep in lockstep with install.sh COSIGN_VERSION and cli release.yml's
# cosign-installer pin.
$CosignVersion = "v2.4.1"

# =============================================================================
#  Logging helpers — match install-k8s.ps1 / install.sh UX.
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

# Resolve the ref to fetch from and enforce the R8 guarantees. Precedence:
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

  # A ref that isn't a vX.Y.Z tag is a mutable branch — the exact thing R8 closes.
  # Allow it only under the explicit unverified opt-in, and say so loudly. The
  # version-suffix class is restricted to [A-Za-z0-9.] (e.g. -rc1, .4): a looser
  # trailer would admit '/' and '..', letting a ref like 'v1.2.3-../../heads/main'
  # slip past this gate and fetch off the MUTABLE 'main' branch (RFC-0001 R8).
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
  # -- it is what could escape the pinned tag onto a mutable branch (RFC-0001 R8)
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
  # The R8 property is unchanged, because it never rested on '/': a TAG still
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

# Download with retry. Honors $env:HTTPS_PROXY for the corporate-proxy segment
# (#172/#722). Unlike curl in install.sh it does not currently apply $NO_PROXY
# exclusions or a custom CA bundle — HTTPS_PROXY covers the common case.
function Get-WithRetry {
  param(
    [string]$Url,
    [string]$Dest,
    [int]$MaxAttempts = 3,
    [int]$DelaySeconds = 5
  )
  # PS 5.1's progress overlay throttles Invoke-WebRequest massively (its render
  # loop dominates the transfer) and its "Writing request stream" banner reads
  # like a hang (#468). Function-local assignment — the preference reverts
  # automatically when this function returns.
  $ProgressPreference = 'SilentlyContinue'
  $proxyArgs = @{}
  if ($env:HTTPS_PROXY) { $proxyArgs['Proxy'] = $env:HTTPS_PROXY }
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop @proxyArgs
      return
    } catch {
      if ($attempt -ge $MaxAttempts) {
        throw "Failed to download $Url after $MaxAttempts attempts: $_"
      }
      Warn "Download failed (attempt $attempt/$MaxAttempts). Retrying in ${DelaySeconds}s..."
      Start-Sleep -Seconds $DelaySeconds
    }
  }
}

# Try a download but don't retry/throw — used for optional assets (manifest
# fall-through, sig/cert) where the caller decides fail-closed vs. opt-out.
function Get-Optional {
  param([string]$Url, [string]$Dest)
  # Same PS 5.1 progress-throttle fix as Get-WithRetry (#468); local scope only.
  $ProgressPreference = 'SilentlyContinue'
  $proxyArgs = @{}
  if ($env:HTTPS_PROXY) { $proxyArgs['Proxy'] = $env:HTTPS_PROXY }
  try {
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop @proxyArgs
    return $true
  } catch {
    return $false
  }
}

# Print a dim heartbeat dot every $TickSeconds while $Job runs — a quiet window
# on a multi-minute step reads as a hang and gets killed (#468; same honest-
# progress philosophy as the Docker wait in install-k8s.ps1, #449). Returns
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

# Get-Optional for a LARGE asset: same contract ($true/$false, no retry/throw),
# but the fetch runs in a background job so the parent can tick a liveness dot.
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

  # Set expectations BEFORE the big fetch: this is the bootstrap's one large
  # download, and during v1.9.7-rc.1 FR a healthy install got killed as
  # "frozen" in exactly this window (#468).
  Info "cosign not found -- downloading pinned cosign $CosignVersion (~17 MB) to verify the manifest."
  Info "This is the bootstrap's one big download; a few minutes on a slow network is normal."
  Info "Tip: 'winget install sigstore.cosign' makes re-runs skip this download."
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  if (-not (Get-OptionalWithTicks "$base/$asset" $bin))       { return $null }
  if (-not (Get-Optional "$base/cosign_checksums.txt" $sums)) { return $null }

  # cosign_checksums.txt lines: "<sha256>␠␠<asset>". Take the one for our asset.
  $want = $null
  foreach ($line in Get-Content -LiteralPath $sums) {
    $parts = @($line -split '\s+' | Where-Object { $_ -ne '' })
    if ($parts.Count -ge 2 -and $parts[-1] -eq $asset) { $want = $parts[0].ToLower(); break }
  }
  if (-not $want) { return $null }
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

function Invoke-CosignVerifyBlob {
  param([Parameter(Mandatory)][string]$Cosign, [Parameter(Mandatory)][string[]]$VerifyArgs)
  $global:LASTEXITCODE = 255
  $prevEAP = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $Cosign @VerifyArgs 2>&1 | Out-Null
  } catch {
    return $false
  } finally {
    $ErrorActionPreference = $prevEAP
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
    # Deliberately does NOT suggest `winget install sigstore.cosign` (Bugbot).
    # We already HAVE a cosign here -- it will not start. Installing another copy
    # of the same amd64 build, which is the only one winget and sigstore publish,
    # reproduces the failure exactly. A remedy that cannot clear the error is
    # worse than none: it costs the user a round trip and teaches them the
    # message is noise.
    throw "cosign was obtained but won't run on this machine, so the installer's signature can't be checked. This is NOT a failed verification -- nothing suggests the download is bad. Two things cause it: security software may have quarantined or blocked the downloaded cosign.exe (check your antivirus / SmartScreen and allow it); or, on Windows-on-ARM, x64 emulation is unavailable -- Windows 11 on ARM includes it, Windows 10 on ARM may not, and sigstore publishes no native arm64 cosign to fall back on, so one would have to be built from source and put on PATH. For local development only you can set `$env:TRACEBLOC_ALLOW_UNVERIFIED = '1'`."
  }

  # The keyless signing identity: the release workflow's OIDC cert. SAME pins as
  # install.sh; shared by both verification paths below.
  $idRe   = 'https://github.com/tracebloc/client/\.github/workflows/.*@.*'
  $issuer = 'https://token.actions.githubusercontent.com'

  # OFFLINE Sigstore bundle first (#584): the bundle carries the Rekor inclusion
  # proof, so this verifies signature + cert identity + tlog inclusion with NO live
  # Rekor call — immune to networks that block/TLS-inspect sigstore, and the only
  # path that verifies our short-lived keyless cert once it has expired (its embedded
  # timestamp proves the cert was valid at signing). Releases cut before the bundle
  # existed 404 here and fall through to the online .sig/.cert path; so does a bundle
  # that doesn't verify — the online path does the SAME full keyless check, just
  # needing live Rekor, so this is a fallback, never a downgrade.
  $bundle = Join-Path $TmpDir "manifest.sha256.bundle"
  if (Get-Optional "$RepoRel/manifest.sha256.bundle" $bundle) {
    if (Invoke-CosignVerifyBlob $cosign @(
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
    throw "The installer's signature isn't published for this release -- can't confirm the download is authentic. Pin a release tag that ships it."
  }

  if (Invoke-CosignVerifyBlob $cosign @(
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

# =============================================================================
#  Orchestration.
# =============================================================================
function Invoke-Bootstrap {
  param([object[]]$ChildArgs)

  $allowUnverified = ($env:TRACEBLOC_ALLOW_UNVERIFIED -eq "1")
  $ref = Resolve-InstallRef -DefaultRef $DefaultRef -RefEnv $env:REF -BranchEnv $env:BRANCH -AllowUnverified $allowUnverified

  # Sub-script CONTENT is pinned to the immutable tag tree. The signed manifest +
  # its cosign sig/cert are published as RELEASE ASSETS (signing happens in CI
  # after the tag is cut), not committed into the tagged tree — same pattern the
  # CLI uses for SHA256SUMS.
  $repoRaw = "https://raw.githubusercontent.com/tracebloc/client/$ref"
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

    # ── Fetch the sub-scripts from the immutable tag tree ──
    foreach ($f in $Files) {
      $dest = Join-Path $tmpDir ($f -replace '^scripts/', '')
      # CREATE THE PARENT FIRST. `$Files` gained its first `scripts/lib/` entry
      # under backend#2268, and Invoke-WebRequest -OutFile does not create
      # directories: without this the very first fetch of a lib file throws
      # DirectoryNotFound and the Windows bootstrap dies before it verifies
      # anything. install.sh has always done the equivalent `mkdir -p`. This
      # weakens no integrity property — every fetched file is still checked
      # against the signed manifest below.
      $destDir = Split-Path -Parent $dest
      if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
      }
      Get-WithRetry -Url "$repoRaw/$f" -Dest $dest
    }

    # ── Fetch + authenticate the manifest, then check every sub-script ──
    $manifest = Join-Path $tmpDir "manifest.sha256"
    if (-not (Get-Optional "$repoRel/manifest.sha256" $manifest)) {
      if ($allowUnverified -and (Get-Optional "$repoRaw/scripts/manifest.sha256" $manifest)) {
        Warn "Using in-repo integrity checksums from ref '$ref' (TRACEBLOC_ALLOW_UNVERIFIED=1)."
      } elseif ($allowUnverified) {
        Warn "No integrity checksums for ref '$ref' -- skipping the integrity check (TRACEBLOC_ALLOW_UNVERIFIED=1)."
        $manifest = $null
      } else {
        throw "Couldn't fetch the installer's integrity checksums for ref '$ref' -- refusing to run unverified installer scripts. If this ref pre-dates signed releases, pin a newer release tag."
      }
    }

    if ($manifest) {
      Confirm-ManifestSignature -Manifest $manifest -RepoRel $repoRel -TmpDir $tmpDir -AllowUnverified $allowUnverified
      Confirm-ScriptIntegrity -Manifest $manifest -TmpDir $tmpDir -Files $Files
    }

    # ── Run the verified main installer ──
    # Hand the resolved ref down, exactly as install.sh:247 exports
    # TRACEBLOC_INSTALL_REF. install-k8s.ps1 runs as a CHILD process, so an
    # environment variable set here is inherited. Without it `service.version` on
    # every Windows telemetry record was permanently "0.0.0-unknown" — the field
    # that says WHICH installer failed, on the platform this feature was added for.
    # (backend#2268; found by the derived ScriptVar test, not by review.)
    $env:TRACEBLOC_INSTALL_REF = $ref
    $k8s = Join-Path $tmpDir "install-k8s.ps1"
    Info "Running tracebloc environment setup..."
    if ($ChildArgs -and $ChildArgs.Count -gt 0) {
      & powershell.exe -ExecutionPolicy Bypass -File $k8s @ChildArgs
    } else {
      & powershell.exe -ExecutionPolicy Bypass -File $k8s
    }
    Complete-Bootstrap -Code $LASTEXITCODE
  } finally {
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# =============================================================================
#  EXITING WITHOUT TAKING THE USER'S WINDOW WITH IT (#577, client#917)
# =============================================================================
# #577 made the installer always show a clean "what happened" instead of
# vanishing -- and it fixed that in install-k8s.ps1, which runs as a CHILD
# process where `exit` is harmless. THIS file is the other half, and it was
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
# tell install-k8s.ps1's declared `exit 2` reboot handoff from a real failure --
# so this does not swap `exit` for `return`, which would silently turn every
# code into 0 for `powershell.exe -Command` callers. It holds the window open
# just long enough to be read, then exits exactly as before.
#
# Can we prompt? Same predicate install-k8s.ps1 uses, deliberately: false under
# CI, a service, or piped/redirected stdin -- every context where a hold would
# be a hang and where no human is losing a window anyway. The e2e journey pipes
# stdin, so it takes the no-hold path.
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
      while (-not [Console]::KeyAvailable -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
      if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
    } catch {}
  }
  exit $Code
}

# =============================================================================
#  Main. $env:TB_PESTER lets the test suite dot-source this file to load the
#  functions without tripping the platform gate (which exits off-Windows) or
#  running the bootstrap.
# =============================================================================
if (-not $env:TB_PESTER) {
  # ── Platform gate ──
  if ($PSVersionTable.PSEdition -eq "Core" -and -not $IsWindows) {
    Write-Host "  " -NoNewline; Write-Host ([char]0x2716) -ForegroundColor Red -NoNewline
    Write-Host " This script is for Windows. On macOS / Linux use:" -ForegroundColor Red
    Write-Host "  curl -fsSL https://raw.githubusercontent.com/tracebloc/client/main/scripts/install.sh | bash" -ForegroundColor Cyan
    Complete-Bootstrap -Code 1
  }
  # TLS 1.2 floor — Windows PowerShell 5.1 otherwise negotiates down to TLS 1.0.
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  try {
    Invoke-Bootstrap -ChildArgs $args
  } catch {
    # Clean, branded failure — never a raw stack (#577). "$_" stringifies to the
    # exception MESSAGE (curated at the throw sites, #576), not the source/stack.
    Write-Host ""
    Err "Installation stopped: $_"
    Write-Host "  It's safe to re-run this installer. If it keeps failing, share the output above with tracebloc support." -ForegroundColor DarkGray
    Complete-Bootstrap -Code 1
  }
}
