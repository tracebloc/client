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
      Should -Throw -ExpectedMessage "*no entry in manifest*"
  }
}
