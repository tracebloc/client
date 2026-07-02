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
      Warn "relaxed. This is for tracebloc development only — never for a customer or"
      Warn "production box. A moved ref here can run arbitrary privileged code."
      Warn "============================================================================"
    } else {
      throw "'$ref' is not an immutable release tag (expected vX.Y.Z). The bootstrap only trusts content-addressable release tags so a moved branch ref can't change what runs as Administrator on your box (RFC-0001 R8). Use a release tag, or for local dev set `$env:TRACEBLOC_ALLOW_UNVERIFIED = '1'`."
    }
  }

  # Belt-and-suspenders: even after the shape checks above, refuse a ref carrying
  # a path separator or a parent-dir token before it is interpolated into a URL.
  # A '/' or '..' here is a path-traversal lever (it could escape the pinned tag
  # onto a mutable branch) — independent of which branch above let it through.
  if ($ref -match '/' -or $ref -match '\.\.') {
    throw "Ref '$ref' contains a path separator or '..' — refusing to build a fetch URL from it (path-traversal guard, RFC-0001 R8)."
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
  $proxyArgs = @{}
  if ($env:HTTPS_PROXY) { $proxyArgs['Proxy'] = $env:HTTPS_PROXY }
  try {
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop @proxyArgs
    return $true
  } catch {
    return $false
  }
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

  switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { $arch = "amd64" }
    "ARM64" { $arch = "arm64" }
    default { return $null }
  }
  $base  = "https://github.com/sigstore/cosign/releases/download/$CosignVersion"
  $asset = "cosign-windows-$arch.exe"
  $bin   = Join-Path $TmpDir "cosign.exe"
  $sums  = Join-Path $TmpDir "cosign_checksums.txt"

  Info "cosign not found — bootstrapping pinned $CosignVersion to verify the manifest…"
  if (-not (Get-Optional "$base/$asset" $bin))               { return $null }
  if (-not (Get-Optional "$base/cosign_checksums.txt" $sums)) { return $null }

  # cosign_checksums.txt lines: "<sha256>␠␠<asset>". Take the one for our asset.
  $want = $null
  foreach ($line in Get-Content -LiteralPath $sums) {
    $parts = @($line -split '\s+' | Where-Object { $_ -ne '' })
    if ($parts.Count -ge 2 -and $parts[-1] -eq $asset) { $want = $parts[0].ToLower(); break }
  }
  if (-not $want) { return $null }
  if ((Get-Sha256 $bin) -ne $want) {
    Err "Bootstrapped cosign failed its own checksum — not using it."
    return $null
  }
  return $bin
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
  $cosign = Resolve-Cosign -TmpDir $TmpDir
  if (-not $cosign) {
    if ($AllowUnverified) {
      Warn "cosign unavailable — manifest signature NOT verified (TRACEBLOC_ALLOW_UNVERIFIED=1)."
      Warn "Proceeding on checksum-only integrity. Not for production."
      return
    }
    throw "cosign is required to verify the installer's signed manifest and couldn't be found or bootstrapped. Refusing to fall back to an unauthenticated, same-channel checksum (RFC-0001 R8). Fix: install cosign (https://docs.sigstore.dev/cosign/installation/) and re-run, or for local development only set `$env:TRACEBLOC_ALLOW_UNVERIFIED = '1'`."
  }

  $sig  = Join-Path $TmpDir "manifest.sha256.sig"
  $cert = Join-Path $TmpDir "manifest.sha256.cert"
  if (-not (Get-Optional "$RepoRel/manifest.sha256.sig"  $sig) -or
      -not (Get-Optional "$RepoRel/manifest.sha256.cert" $cert)) {
    if ($AllowUnverified) {
      Warn "manifest signature/cert not published for this ref — not verified (TRACEBLOC_ALLOW_UNVERIFIED=1)."
      return
    }
    throw "manifest.sha256.sig / .cert not published for this release — can't authenticate the manifest. Pin a release tag that ships them (RFC-0001 R8)."
  }

  # The identity is the client release workflow (release-helm-chart.yaml) — the
  # keyless signer that produced the manifest. SAME pins as install.sh.
  $cosignArgs = @(
    'verify-blob',
    '--certificate-identity-regexp', 'https://github.com/tracebloc/client/\.github/workflows/.*@.*',
    '--certificate-oidc-issuer', 'https://token.actions.githubusercontent.com',
    '--certificate', $cert,
    '--signature', $sig,
    $Manifest
  )
  # Reset to a NONZERO sentinel first: a cosign that exists but can't launch
  # (corrupt, AV-quarantined, wrong exec format) can return WITHOUT setting
  # $LASTEXITCODE, leaving a stale prior value — a stale 0 would read as "verified"
  # (fail-open). The sentinel + the catch below make BOTH the won't-launch and the
  # returns-nonzero cases fail closed (parity with install.sh's `if cosign; else`).
  $global:LASTEXITCODE = 255
  try {
    & $cosign @cosignArgs 2>$null 1>$null
  } catch {
    throw "cosign could not be executed to verify manifest.sha256 — refusing to install (RFC-0001 R8): $_"
  }
  if ($LASTEXITCODE -ne 0) {
    throw "cosign signature verification FAILED for manifest.sha256 — refusing to install (RFC-0001 R8)."
  }
  Ok "manifest signature verified (cosign keyless)"
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
      throw "$rel has no entry in manifest.sha256 — refusing to run it (RFC-0001 R8)."
    }
    $actual = Get-Sha256 -Path $local
    if ($actual -ne $expected) {
      throw "Integrity check FAILED for $rel`n          expected: $expected`n          actual:   $actual`n        Someone may have tampered with the installer. Aborting before any privileged step runs (RFC-0001 R8)."
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
    throw "temp dir $tmpDir already exists — refusing to reuse it (RFC-0001 R8)."
  }
  New-Item -ItemType Directory -Path $tmpDir | Out-Null
  try {
    Info "Downloading Tracebloc client installer (ref: $ref)..."

    # ── Fetch the sub-scripts from the immutable tag tree ──
    foreach ($f in $Files) {
      $dest = Join-Path $tmpDir ($f -replace '^scripts/', '')
      Get-WithRetry -Url "$repoRaw/$f" -Dest $dest
    }

    # ── Fetch + authenticate the manifest, then check every sub-script ──
    $manifest = Join-Path $tmpDir "manifest.sha256"
    if (-not (Get-Optional "$repoRel/manifest.sha256" $manifest)) {
      if ($allowUnverified -and (Get-Optional "$repoRaw/scripts/manifest.sha256" $manifest)) {
        Warn "Using in-repo manifest.sha256 from ref '$ref' (TRACEBLOC_ALLOW_UNVERIFIED=1)."
      } elseif ($allowUnverified) {
        Warn "No manifest.sha256 for ref '$ref' — skipping integrity check (TRACEBLOC_ALLOW_UNVERIFIED=1)."
        $manifest = $null
      } else {
        throw "Couldn't fetch manifest.sha256 for ref '$ref' — refusing to run unverified installer scripts (RFC-0001 R8). If this ref pre-dates signed manifests, pin a newer release tag."
      }
    }

    if ($manifest) {
      Confirm-ManifestSignature -Manifest $manifest -RepoRel $repoRel -TmpDir $tmpDir -AllowUnverified $allowUnverified
      Confirm-ScriptIntegrity -Manifest $manifest -TmpDir $tmpDir -Files $Files
    }

    # ── Run the verified main installer ──
    $k8s = Join-Path $tmpDir "install-k8s.ps1"
    Info "Running Tracebloc environment setup..."
    if ($ChildArgs -and $ChildArgs.Count -gt 0) {
      & powershell.exe -ExecutionPolicy Bypass -File $k8s @ChildArgs
    } else {
      & powershell.exe -ExecutionPolicy Bypass -File $k8s
    }
    exit $LASTEXITCODE
  } finally {
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }
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
    exit 1
  }
  # TLS 1.2 floor — Windows PowerShell 5.1 otherwise negotiates down to TLS 1.0.
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  try {
    Invoke-Bootstrap -ChildArgs $args
  } catch {
    Err "$_"
    exit 1
  }
}
