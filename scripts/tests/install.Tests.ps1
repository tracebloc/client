# Pester tests for scripts/install.ps1 (Windows bootstrap, RFC-0001 R8).
# Dot-sources the script with $env:TB_PESTER set so the platform gate + main() are
# skipped and only the functions load. Runs on Linux pwsh AND real Windows (see
# .github/workflows/installer-tests.yaml). Run locally: Invoke-Pester scripts/tests/

BeforeAll {
  $env:TB_PESTER = "1"
  . "$PSScriptRoot/../install.ps1"
}

Describe "Resolve-InstallRef — R8 ref resolution + fail-closed" {
  It "fails closed when the installer is unstamped and not opted-in" {
    { Resolve-InstallRef -DefaultRef '__TRACEBLOC_RELEASE_REF__' -AllowUnverified:$false } |
      Should -Throw -ExpectedMessage "*wasn't stamped*"
  }
  It "falls back to 'main' when unstamped WITH the unverified opt-in" {
    Resolve-InstallRef -DefaultRef '__TRACEBLOC_RELEASE_REF__' -AllowUnverified:$true | Should -Be 'main'
  }
  It "accepts a stamped release tag (vX.Y.Z)" {
    Resolve-InstallRef -DefaultRef 'v1.8.4' -AllowUnverified:$false | Should -Be 'v1.8.4'
  }
  It "accepts a tag with a version suffix (-rc1, .4)" {
    Resolve-InstallRef -DefaultRef 'v2.0.1-rc1' -AllowUnverified:$false | Should -Be 'v2.0.1-rc1'
    Resolve-InstallRef -DefaultRef 'v2.0.1.4'   -AllowUnverified:$false | Should -Be 'v2.0.1.4'
  }
  It "honors an explicit REF pin (still shape-validated)" {
    Resolve-InstallRef -DefaultRef 'v1.8.4' -RefEnv 'v1.9.0' -AllowUnverified:$false | Should -Be 'v1.9.0'
  }
  It "fails closed on a mutable BRANCH without the opt-in" {
    { Resolve-InstallRef -DefaultRef 'v1.8.4' -BranchEnv 'develop' -AllowUnverified:$false } |
      Should -Throw -ExpectedMessage "*not an immutable release tag*"
  }
  It "allows a mutable BRANCH only under the explicit opt-in" {
    Resolve-InstallRef -DefaultRef 'v1.8.4' -BranchEnv 'develop' -AllowUnverified:$true | Should -Be 'develop'
  }
  It "fails closed on REF=main (a non-tag) without the opt-in" {
    { Resolve-InstallRef -DefaultRef 'v1.8.4' -RefEnv 'main' -AllowUnverified:$false } | Should -Throw
  }
  It "refuses a path-traversal ref (v1.2.3-../../heads/main)" {
    { Resolve-InstallRef -DefaultRef 'v1.2.3-../../heads/main' -AllowUnverified:$false } | Should -Throw
  }
  It "refuses a path-traversal ref even WITH the opt-in (belt-and-suspenders)" {
    { Resolve-InstallRef -DefaultRef 'v1.2.3/../../heads/main' -AllowUnverified:$true } |
      Should -Throw -ExpectedMessage "*path-traversal*"
  }
  It "rejects a ref carrying shell/space metacharacters" {
    { Resolve-InstallRef -DefaultRef 'v1 2 3; rm -rf /' -AllowUnverified:$false } | Should -Throw
  }
}

Describe "Find-ManifestDigest — manifest lookup (matches on the last field)" {
  BeforeAll {
    $script:mf = Join-Path $TestDrive 'manifest.sha256'
    @(
      "aaaa1111  scripts/install-k8s.sh",
      "bbbb2222   scripts/install-k8s.ps1",   # 3 spaces — must still match on last field
      "cccc3333  scripts/lib/common.sh"
    ) | Set-Content -LiteralPath $script:mf
  }
  It "matches the digest by last field, tolerating extra whitespace" {
    Find-ManifestDigest -ManifestPath $script:mf -Key 'scripts/install-k8s.ps1' | Should -Be 'bbbb2222'
  }
  It "returns null for a key that isn't listed" {
    Find-ManifestDigest -ManifestPath $script:mf -Key 'scripts/nope.ps1' | Should -BeNullOrEmpty
  }
  It "does not prefix/substring-match (.ps1 must not shadow .sh)" {
    Find-ManifestDigest -ManifestPath $script:mf -Key 'scripts/install-k8s.sh' | Should -Be 'aaaa1111'
  }
}

Describe "Wait-JobWithTicks — liveness heartbeat for background fetches (#468)" {
  It "returns true when the job finishes before the timeout" {
    $j = Start-Job { Start-Sleep -Milliseconds 200 }
    try {
      Wait-JobWithTicks -Job $j -TimeoutSeconds 30 -TickSeconds 1 | Should -BeTrue
    } finally { Remove-Job $j -Force -ErrorAction SilentlyContinue }
  }
  It "returns false and stops a job that outlives the timeout" {
    $j = Start-Job { Start-Sleep -Seconds 120 }
    try {
      Wait-JobWithTicks -Job $j -TimeoutSeconds 2 -TickSeconds 1 | Should -BeFalse
      $j.State | Should -Not -Be 'Running'
    } finally { Remove-Job $j -Force -ErrorAction SilentlyContinue }
  }
}

Describe "Download UX — PS 5.1 progress throttle + fresh-process hardening (#468)" {
  # PS 5.1's progress overlay throttles Invoke-WebRequest massively and reads
  # like a hang; these invariants keep the silencing (and the background job's
  # re-hardening) from being quietly dropped in a refactor.
  It "Get-WithRetry silences the progress overlay for the duration of the call" {
    (Get-Command Get-WithRetry).Definition | Should -Match "ProgressPreference\s*=\s*'SilentlyContinue'"
  }
  It "Get-Optional silences the progress overlay for the duration of the call" {
    (Get-Command Get-Optional).Definition | Should -Match "ProgressPreference\s*=\s*'SilentlyContinue'"
  }
  It "the large-fetch job silences progress, re-applies the TLS 1.2 floor, and pins a local cwd (#409)" {
    $def = (Get-Command Get-OptionalWithTicks).Definition
    $def | Should -Match "ProgressPreference\s*=\s*'SilentlyContinue'"
    $def | Should -Match 'SecurityProtocolType\]::Tls12'
    $def | Should -Match 'Set-Location \$env:SystemRoot'
  }
}

Describe "Source hygiene — string literals must survive a Latin-1 mis-decode (#468)" {
  # PS 5.1 decodes the release-asset bootstrap (served without a charset header)
  # as Latin-1 before iex, and reads BOM-less .ps1 files given to -File as ANSI:
  # any non-ASCII character inside a STRING literal reaches the customer as
  # mojibake ("â€¦"). Comments are exempt (never rendered); glyphs belong in
  # [char]0xNNNN form (which is pure-ASCII source), like the logging helpers.
  It "<name> has no non-ASCII characters in any string literal" -TestCases @(
    @{ name = 'install.ps1';     file = 'install.ps1' }
    @{ name = 'install-k8s.ps1'; file = 'install-k8s.ps1' }
  ) {
    param($name, $file)
    $path = (Resolve-Path "$PSScriptRoot/../$file").Path
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    $stringKinds = 'StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable'
    $bad = @($tokens | Where-Object {
      "$($_.Kind)" -in $stringKinds -and $_.Text -match '[^\x00-\x7F]'
    } | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Text)" })
    $bad -join "; " | Should -BeNullOrEmpty
  }
}

Describe "Confirm-ScriptIntegrity — integrity gate before any privileged step" {
  BeforeAll {
    $script:tmp = Join-Path $TestDrive 'dl'
    New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $script:tmp 'install-k8s.ps1') -Value 'write-host hi' -NoNewline
    $script:realHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:tmp 'install-k8s.ps1')).Hash.ToLower()
  }
  It "passes when the fetched sub-script matches the manifest digest" {
    $mf = Join-Path $TestDrive 'good.sha256'
    "$script:realHash  scripts/install-k8s.ps1" | Set-Content -LiteralPath $mf
    { Confirm-ScriptIntegrity -Manifest $mf -TmpDir $script:tmp -Files @('scripts/install-k8s.ps1') } | Should -Not -Throw
  }
  It "aborts on a digest mismatch (tamper)" {
    $mf = Join-Path $TestDrive 'bad.sha256'
    "deadbeef  scripts/install-k8s.ps1" | Set-Content -LiteralPath $mf
    { Confirm-ScriptIntegrity -Manifest $mf -TmpDir $script:tmp -Files @('scripts/install-k8s.ps1') } |
      Should -Throw -ExpectedMessage "*Integrity check FAILED*"
  }
  It "aborts when a fetched sub-script has no manifest entry" {
    $mf = Join-Path $TestDrive 'missing.sha256'
    "zzzz  scripts/other.ps1" | Set-Content -LiteralPath $mf
    { Confirm-ScriptIntegrity -Manifest $mf -TmpDir $script:tmp -Files @('scripts/install-k8s.ps1') } |
      Should -Throw -ExpectedMessage "*isn't in the installer's signed checksum list*"
  }
}

Describe "Bootstrap log hygiene: cosign output captured, no internals leaked (#576)" {
  BeforeAll { $script:BOOTSRC = Get-Content "$PSScriptRoot/../install.ps1" -Raw }

  It "captures cosign output instead of letting PowerShell dump the raw native error + source line" {
    # The capture hardening now lives in the shared Invoke-CosignVerifyBlob helper (#584);
    # the leaky discard form must be gone and the stderr-merged capture present.
    $script:BOOTSRC | Should -Not -Match '2>\$null 1>\$null'
    $script:BOOTSRC | Should -Match '& \$Cosign @VerifyArgs 2>&1 \| Out-Null'
  }
  It "the verification-failure message carries no internal identifiers (no source, no RFC/manifest codes)" {
    $script:BOOTSRC | Should -Not -Match 'cosign signature verification FAILED for manifest\.sha256'
    $script:BOOTSRC | Should -Match "Couldn't confirm the installer download is authentic"
  }
  It "still fails closed (throws, stops before changing the machine)" {
    $script:BOOTSRC | Should -Match 'install stopped before changing anything on your machine'
  }
}

Describe "Bootstrap CA handling for cosign on Windows (#583)" {
  It "validates the CA path (fail fast) but does NOT set SSL_CERT_FILE (Go ignores it on Windows)" {
    $src = Get-Content "$PSScriptRoot/../install.ps1" -Raw
    $fn  = (($src -split "function Confirm-ManifestSignature")[1] -split "`nfunction ")[0]
    $fn | Should -Match 'TRACEBLOC_CA_BUNDLE'
    $fn | Should -Match "can't be read"                     # fail fast on a bad path
    $fn | Should -Not -Match '\$env:SSL_CERT_FILE = \$ca'   # inert on Windows; not wired
  }
}

Describe "Bootstrap prefers the offline Sigstore bundle (#584)" {
  It "Confirm-ManifestSignature verifies --bundle --offline first, with a sig/cert fallback" {
    $src = Get-Content "$PSScriptRoot/../install.ps1" -Raw
    $fn  = (($src -split "function Confirm-ManifestSignature")[1] -split "`nfunction ")[0]
    $fn | Should -Match 'manifest\.sha256\.bundle'
    $fn | Should -Match "'--bundle'"
    $fn | Should -Match "'--offline'"
    $fn | Should -Match "'--signature'"   # online fallback path retained
  }
  It "Invoke-CosignVerifyBlob is fail-closed (nonzero LASTEXITCODE sentinel + stderr suppressed)" {
    $src = Get-Content "$PSScriptRoot/../install.ps1" -Raw
    $fn  = (($src -split "function Invoke-CosignVerifyBlob")[1] -split "`nfunction ")[0]
    $fn | Should -Match '\$global:LASTEXITCODE = 255'
    $fn | Should -Match '2>&1 \| Out-Null'
  }
}

Describe "Confirm-ManifestSignature: offline-bundle -> sig/cert fallback behaviour (#584, reviewer)" {
  # Behavioural (not source-text): drive the fallback + fail-closed branches directly.
  BeforeEach {
    $env:TRACEBLOC_CA_BUNDLE = $null; $env:CURL_CA_BUNDLE = $null   # skip the CA fast-fail
    Mock Resolve-Cosign { "cosign" }
    Mock Get-Optional   { $true }        # bundle + sig + cert all "published/fetched"
    Mock Ok {}; Mock Warn {}
  }

  It "falls back to the sig/cert path when the bundle verify fails, and verifies" {
    Mock Invoke-CosignVerifyBlob { if ($VerifyArgs -contains '--bundle') { $false } else { $true } }
    { Confirm-ManifestSignature -Manifest 'm' -RepoRel 'r' -TmpDir $TestDrive -AllowUnverified $false } |
      Should -Not -Throw
    Should -Invoke Invoke-CosignVerifyBlob -Times 2 -Exactly   # bundle attempt + sig/cert fallback
  }

  It "fails closed when BOTH the bundle and the sig/cert verify fail" {
    Mock Invoke-CosignVerifyBlob { $false }
    { Confirm-ManifestSignature -Manifest 'm' -RepoRel 'r' -TmpDir $TestDrive -AllowUnverified $false } |
      Should -Throw -ExpectedMessage "*Couldn't confirm the installer download is authentic*"
  }
}
