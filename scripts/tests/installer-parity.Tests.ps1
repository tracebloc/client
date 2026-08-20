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
    }

    if ($failures.Count -gt 0) {
      $msg = "installer parity failures (PowerShell side):`n" + ($failures -join "`n") +
             "`nThe bash twin is asserted against the SAME fixture — if only one side" +
             "`nfails, the twins have diverged, which is what this file exists to catch."
      throw $msg
    }
  }
}
