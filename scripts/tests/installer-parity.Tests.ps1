# Installer parity — the PowerShell half (client#772).
#
# Reads scripts/tests/fixtures/installer_parity.json DIRECTLY (PowerShell has
# ConvertFrom-Json; bats does not, which is why the bash half reads a generated
# table from the same file) and drives Get-TrainingResources /
# Get-TrainingProvenance through every cluster state, asserting the four verdicts
# the fixture declares.
#
# installer-parity.bats asserts the SAME fixture against _resolve_training_size.
# One table, two readers. A row added to the JSON forces both languages to answer
# it — the property that was missing while five twin divergences were found one
# at a time across backend#2220, including one (the [math]::Max Int32 overload)
# that had silently disabled machine sizing on Windows with nothing failing.

BeforeAll {
  $env:TB_PESTER = "1"
  . "$PSScriptRoot/../install-k8s.ps1"
  function kubectl { $global:LASTEXITCODE = 0 }
  function helm { }

  $script:ParityPath = Join-Path $PSScriptRoot "fixtures/installer_parity.json"
  $script:Parity = Get-Content $script:ParityPath -Raw | ConvertFrom-Json
}

Describe "Installer parity (client#772)" {

  BeforeEach {
    $script:TB_NAMESPACE = "tracebloc"
    $env:TRACEBLOC_TRAINING_RESOURCES = $null
    # Get-TrainingResources SETS these, so they must be cleared between rows or a
    # previous undersized state leaks a $true into the next verdict.
    $script:TbTrainingUndersized    = $false
    $script:TbTrainingUnschedulable = $false
  }
  AfterEach { $env:TRACEBLOC_TRAINING_RESOURCES = $null }

  It "the fixture is readable and carries rows" {
    # An empty fixture would make the parity assertion below vacuous — the
    # disconnected-guard shape gen-manifest.sh warns about for its own surface.
    $script:Parity.schema_version | Should -BeGreaterOrEqual 1
    @($script:Parity.rows).Count   | Should -BeGreaterThan 9
  }

  It "documents anything it deliberately does not compare" {
    # Parity that quietly skips the awkward states is worse than no parity: it
    # reads as coverage. Exclusions must be listed WITH a reason.
    foreach ($x in @($script:Parity.excluded_from_parity)) {
      $x.case | Should -Not -BeNullOrEmpty
      $x.why  | Should -Not -BeNullOrEmpty
    }
  }

  It "every cluster state produces the declared verdict" {
    $failures = @()

    foreach ($row in $script:Parity.rows) {
      # --- arrange the scenario at the SAME boundary the bats half stubs: the
      # --- two external commands, never the installer's own helpers.
      $script:TbTrainingUndersized    = $false
      $script:TbTrainingUnschedulable = $false
      $env:TRACEBLOC_TRAINING_RESOURCES = if ($row.override) { $row.override } else { $null }

      $nodeLines = @($row.nodes -split ';')

      switch ($row.carried) {
        'none'       { Mock helm { $global:LASTEXITCODE = 1; "" } }
        'read-fails' { Mock helm { $global:LASTEXITCODE = 1; "" } }
        'read-empty' { Mock helm { $global:LASTEXITCODE = 0; "" } }
        default {
          # Get-CarriedTrainingValues asks for -o json, so the mock speaks JSON
          # where the bash twin's `helm get values` speaks YAML. Same release
          # state, two client-side encodings.
          $envMap = @{ RESOURCE_LIMITS = $row.carried }
          if ($row.carried_provenance) { $envMap['RESOURCE_PROVENANCE'] = $row.carried_provenance }
          $json = (@{ env = $envMap } | ConvertTo-Json -Compress -Depth 5)
          Mock helm { $global:LASTEXITCODE = 0; $json }.GetNewClosure()
        }
      }

      Mock kubectl {
        if ($args -contains "--request-timeout=10s") { $global:LASTEXITCODE = 0; $nodeLines }
        else { $global:LASTEXITCODE = 0; "" }
      }.GetNewClosure()

      # --- act: one carried lookup, handed to both, exactly as the values
      # --- generation does it.
      $carried    = Get-CarriedTrainingValues
      $gotSize    = Get-TrainingResources  -Carried $carried -CarriedResolved
      $gotProv    = Get-TrainingProvenance -Carried $carried -CarriedResolved
      $gotUnder   = [bool]$script:TbTrainingUndersized
      $gotUnsched = [bool]$script:TbTrainingUnschedulable

      # --- assert
      if ($gotSize -ne $row.expect.size) {
        $failures += "  $($row.label): size want '$($row.expect.size)' got '$gotSize'"
      }
      if ($gotProv -ne $row.expect.provenance) {
        $failures += "  $($row.label): provenance want '$($row.expect.provenance)' got '$gotProv'"
      }
      if ($gotUnder -ne [bool]$row.expect.undersized) {
        $failures += "  $($row.label): undersized want '$($row.expect.undersized)' got '$gotUnder'"
      }
      if ($gotUnsched -ne [bool]$row.expect.unschedulable) {
        $failures += "  $($row.label): unschedulable want '$($row.expect.unschedulable)' got '$gotUnsched'"
      }
      # schema_version 2 (backend#2418): the limits half is a SECOND shared
      # contract, and the twins already diverged on it once -- bash matched
      # `cpu=*` WITHOUT trimming, so `cpu=7, memory=29Gi` kept the cpu limit
      # there while this side's .Trim() dropped it. Asserting it per-row against
      # the same fixture is what makes that class fail instead of shipping.
      $gotLimits = Get-TrainingLimits $gotSize
      if ($gotLimits -ne $row.expect.limits) {
        $failures += "  $($row.label): limits want '$($row.expect.limits)' got '$gotLimits'"
      }
    }

    if ($failures.Count -gt 0) {
      $msg = "installer parity failures (PowerShell side):`n" + ($failures -join "`n") +
             "`nThe bash twin is asserted against the SAME fixture — if only one side" +
             "`nfails, the twins have diverged, which is what this file exists to catch."
      throw $msg
    }
  }
}

Describe "Installer parity: the kubelet drop-in's reservation shape (backend#2460)" {
  # The PowerShell half of the bats block of the same name: Write-KubeletConfig is
  # driven with the platform overridden -- once as the first platform in THIS
  # twin's own measured list, once as the fixture's unmeasured probe -- and the
  # keys it must / must not emit come from the shared fixture. The values are
  # not asserted here: they are generated into both twins and held equal by
  # scripts/tests/kubelet-config-agreement.sh in the required drift job.
  BeforeAll {
    $script:KR = $script:Parity.kubelet_reservation
    $script:Measured = @()
    $listVar = Get-Variable -Name $script:KR.measured_platforms_variable -ValueOnly -ErrorAction SilentlyContinue
    if ($listVar) { $script:Measured = @("$listVar".Trim() -split '\s+' | Where-Object { $_ }) }
  }

  It "the fixture declares the reservation shape" {
    $script:KR | Should -Not -BeNullOrEmpty
    $script:KR.measured_platforms_variable | Should -Be 'TB_KUBELET_RESERVATION_PLATFORMS'
    @($script:KR.emitted_for_a_measured_platform).Count | Should -BeGreaterOrEqual 4
    @($script:KR.never_emitted_for_an_unmeasured_platform).Count | Should -BeGreaterOrEqual 4
    @($script:KR.never_restated_from_k3s).Count | Should -BeGreaterOrEqual 2
    @($script:KR.always_emitted).Count | Should -BeGreaterOrEqual 3
  }

  It "a measured platform's drop-in carries every key the fixture names, and none it forbids" {
    if ($script:Measured.Count -eq 0) { Set-ItResult -Skipped -Because "no platform has a measured record in this tree"; return }
    $path = Join-Path $TestDrive "measured/kubelet.yaml"
    $null = Write-KubeletConfig -Path $path -Platform $script:Measured[0]
    $yaml = Get-Content -LiteralPath $path -Raw
    foreach ($k in @($script:KR.emitted_for_a_measured_platform) + @($script:KR.always_emitted)) {
      $yaml | Should -Match ([regex]::Escape($k)) -Because "a measured platform must emit '$k'"
    }
    foreach ($k in @($script:KR.never_restated_from_k3s)) {
      $yaml | Should -Not -Match ([regex]::Escape($k)) -Because "k3s's '$k' must not be restated"
    }
  }

  It "an unmeasured platform's drop-in carries none of the reservation keys, and all of the always-keys" {
    $path = Join-Path $TestDrive "unmeasured/kubelet.yaml"
    $null = Write-KubeletConfig -Path $path -Platform $script:KR.unmeasured_probe_platform
    $yaml = Get-Content -LiteralPath $path -Raw
    foreach ($k in @($script:KR.never_emitted_for_an_unmeasured_platform)) {
      $yaml | Should -Not -Match ([regex]::Escape($k)) -Because "an unmeasured platform must not emit '$k'"
    }
    foreach ($k in @($script:KR.always_emitted)) {
      $yaml | Should -Match ([regex]::Escape($k)) -Because "the image-GC half must survive on an unmeasured platform"
    }
  }
}
