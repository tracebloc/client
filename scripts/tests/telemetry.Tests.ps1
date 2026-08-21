# Pester tests for scripts/lib/telemetry.ps1 — the Windows outcome emitter
# (backend#2268).
#
# WHAT THESE ARE FOR. `install-k8s.ps1` shipped with zero telemetry while
# backend#1907 was closed claiming installer coverage, so the first thing worth
# proving is that the emitter EXISTS and produces a contract-shaped record. The
# second, and the one these tests spend most of their length on, is that it
# refuses the things telemetry.sh refuses — because the failure mode here is not
# a crash, it is a record that looks fine and carries something it should not.
#
# The emitter is a pure lib with no main(), so it dot-sources directly. It is
# re-sourced in BeforeEach: the latches and the phase timers are `$script:` state
# in the LIB's scope, which a test cannot reach to reset — assigning
# `$script:TbTelemetrySkipped` from here would set a variable in the TEST's scope
# and leave the lib's untouched, and every outcome-matrix test would then read
# whatever the previous test left behind.

# Pester 6 refuses a BeforeEach directly in the container, so the whole suite
# lives under one outer Describe. Outer setup runs before inner setup, which is
# the order this needs: the reset below lands first, then each Describe's own
# BeforeEach sets what that group cares about.
Describe "telemetry.ps1 — the Windows outcome emitter" {

BeforeAll {
  $script:LibPath = "$PSScriptRoot/../lib/telemetry.ps1"
}

BeforeEach {
  # Fresh state per test. Also clears every env var the emitter reads, so no test
  # inherits another's environment.
  foreach ($v in @('CLIENT_ENV', 'CLIENT_STATE', 'TB_VERSION', 'TB_ERR_LOC',
                   'TB_CLI_ON_FRESH_PATH', 'HOST_DATA_DIR',
                   'TRACEBLOC_NO_TELEMETRY', 'DO_NOT_TRACK')) {
    Remove-Item -Path "env:$v" -ErrorAction SilentlyContinue
  }
  . $script:LibPath
}

Describe "Test-TelemetryEnabled — opt-out, and only the 'off' spellings count" {
  It "is enabled when nothing is set" {
    Test-TelemetryEnabled | Should -BeTrue
  }
  It "stays enabled for the explicit off spellings" -ForEach @(
    @{ Value = '' }, @{ Value = '0' }, @{ Value = 'false' }, @{ Value = 'FALSE' }
  ) {
    $env:TRACEBLOC_NO_TELEMETRY = $Value
    Test-TelemetryEnabled | Should -BeTrue
  }
  It "opts out on anything else, including a word nobody planned for" -ForEach @(
    @{ Value = '1' }, @{ Value = 'true' }, @{ Value = 'yes' }, @{ Value = 'please' }
  ) {
    $env:TRACEBLOC_NO_TELEMETRY = $Value
    Test-TelemetryEnabled | Should -BeFalse
  }
  It "honours DO_NOT_TRACK as well" {
    $env:DO_NOT_TRACK = '1'
    Test-TelemetryEnabled | Should -BeFalse
  }
}

Describe "Add-TelemetryAttr — the privacy boundary" {
  It "accepts a well-shaped string" {
    Reset-TelemetryBuffer
    Add-TelemetryAttr 'a.b' 'ok-1_2'
    Get-TelemetryBufferForTest | Should -Be '"a.b":"ok-1_2"'
  }
  It "drops a malformed key" -ForEach @(
    @{ Key = 'A.b' }, @{ Key = '1a' }, @{ Key = 'a..b' }, @{ Key = 'a-b' }, @{ Key = '' }
  ) {
    Reset-TelemetryBuffer
    Add-TelemetryAttr $Key 'value'
    Get-TelemetryBufferForTest | Should -BeNullOrEmpty
  }
  It "drops an empty value rather than emitting an empty string" {
    Reset-TelemetryBuffer
    Add-TelemetryAttr 'a.b' ''
    Get-TelemetryBufferForTest | Should -BeNullOrEmpty
  }
  It "drops a value that is not the shape 'int' promises" -ForEach @(
    @{ Value = 'x' }, @{ Value = '1.5' }, @{ Value = '1e3' }, @{ Value = '12345678901234567' }
  ) {
    Reset-TelemetryBuffer
    Add-TelemetryAttr 'a.b' $Value 'int'
    Get-TelemetryBufferForTest | Should -BeNullOrEmpty
  }

  # THE PORTING TEST. telemetry.sh moved off `grep` because grep matches a LINE
  # while the check must match the whole STRING. .NET reintroduces that hole in a
  # subtler spelling: with `^...$` and no Multiline option, `$` still matches
  # immediately BEFORE a trailing newline, so "abc`n" satisfies '^[a-z]+$'. The
  # emitter anchors \A..\z for exactly this reason, and this is the test that
  # fails if someone "tidies" them back to ^..$.
  It "refuses a value with a trailing newline (the .NET \$-anchor bypass)" {
    Reset-TelemetryBuffer
    Add-TelemetryAttr 'a.b' "abc`n"
    Get-TelemetryBufferForTest | Should -BeNullOrEmpty
  }
  It "refuses a value with an embedded newline, both halves well-shaped" {
    Reset-TelemetryBuffer
    Add-TelemetryAttr 'a.b' "abc`ndef"
    Get-TelemetryBufferForTest | Should -BeNullOrEmpty
  }
  It "refuses a key with a trailing newline" {
    Reset-TelemetryBuffer
    Add-TelemetryAttr "a.b`n" 'value'
    Get-TelemetryBufferForTest | Should -BeNullOrEmpty
  }
  It "refuses a quote, which would otherwise break out of the JSON string" {
    Reset-TelemetryBuffer
    Add-TelemetryAttr 'a.b' 'ab"cd'
    Get-TelemetryBufferForTest | Should -BeNullOrEmpty
  }
  It "refuses a space — free text is exactly what must not reach the record" {
    Reset-TelemetryBuffer
    Add-TelemetryAttr 'a.b' 'hello world'
    Get-TelemetryBufferForTest | Should -BeNullOrEmpty
  }
}

Describe "Get-TelemetryEvent — the outcome matrix" {
  BeforeEach { $env:CLIENT_ENV = 'stg' }

  It "maps exit 0 to succeeded" {
    (Get-TelemetryEvent -Code 0) | Should -Match '"event\.name":"install\.run\.succeeded"'
  }
  It "maps exit 0 on a skipped run to skipped, not succeeded" {
    Set-TelemetryRunSkipped
    (Get-TelemetryEvent -Code 0) | Should -Match '"event\.name":"install\.run\.skipped"'
  }
  It "maps a DECLARED exit 2 to cancelled (the re-run handoff)" {
    Set-TelemetryRerunHandoff
    (Get-TelemetryEvent -Code 2) | Should -Match '"event\.name":"install\.run\.cancelled"'
  }
  # The direction that costs the most: an exit 2 nobody declared is an ordinary
  # tool's failure, and keying on the NUMBER removed it from the numerator.
  It "maps an UNDECLARED exit 2 to failed, with its own error.type" {
    $json = Get-TelemetryEvent -Code 2
    $json | Should -Match '"event\.name":"install\.run\.failed"'
    $json | Should -Match '"error\.type":"unexpected_exit_2"'
  }
  It "maps the signal exits to cancelled" -ForEach @(@{ Code = 130 }, @{ Code = 143 }) {
    (Get-TelemetryEvent -Code $Code) | Should -Match '"event\.name":"install\.run\.cancelled"'
  }
  # A signal on a run that installed nothing is not a cancelled install: there
  # was no install to cancel, and counting it inflates the denominator of "how
  # often do installs not complete" with runs that never attempted anything.
  It "keeps a skipped run skipped even under a signal" -ForEach @(@{ Code = 130 }, @{ Code = 143 }) {
    Set-TelemetryRunSkipped
    (Get-TelemetryEvent -Code $Code) | Should -Match '"event\.name":"install\.run\.skipped"'
  }
  # The asymmetry is the point: skipped is consulted only on the exits that mean
  # nothing was installed. A skipped run that then dies for real is a failure.
  It "does NOT let skipped win over a genuine non-zero failure" {
    Set-TelemetryRunSkipped
    (Get-TelemetryEvent -Code 1) | Should -Match '"event\.name":"install\.run\.failed"'
  }
  It "maps any other non-zero to failed" -ForEach @(@{ Code = 1 }, @{ Code = 42 }, @{ Code = 127 }) {
    (Get-TelemetryEvent -Code $Code) | Should -Match '"event\.name":"install\.run\.failed"'
  }
}

Describe "Get-TelemetryEvent — the record's shape" {
  BeforeEach { $env:CLIENT_ENV = 'stg' }

  It "drops the record entirely on an unrecognised environment (§3.2)" {
    $env:CLIENT_ENV = 'staging-2'
    Get-TelemetryEvent -Code 0 | Should -BeNullOrEmpty
  }
  It "carries every required resource field" {
    $json = Get-TelemetryEvent -Code 0
    foreach ($k in @('service.name', 'tracebloc.component', 'service.version',
                     'deployment.environment', 'os.type', 'host.arch',
                     'service.instance.id')) {
      $json | Should -Match ([regex]::Escape('"' + $k + '":'))
    }
  }
  It "names this platform, which the bash twin never can" {
    (Get-TelemetryEvent -Code 0) | Should -Match '"os\.type":"windows"'
  }
  It "renders an unknown version as a VALUE, not an omission (§4)" {
    (Get-TelemetryEvent -Code 0) | Should -Match '"service\.version":"0\.0\.0-unknown"'
  }
  It "refuses a TB_VERSION somebody set to a sentence" {
    $env:TB_VERSION = 'the latest one'
    (Get-TelemetryEvent -Code 0) | Should -Match '"service\.version":"0\.0\.0-unknown"'
  }
  It "accepts a well-shaped release tag" {
    $env:TB_VERSION = 'v1.9.55'
    (Get-TelemetryEvent -Code 0) | Should -Match '"service\.version":"v1\.9\.55"'
  }
  It "drops an unregistered CLIENT_STATE instead of passing it through" {
    $env:CLIENT_STATE = 'inventing_a_state'
    (Get-TelemetryEvent -Code 0) | Should -Not -Match 'client_state'
  }
  It "keeps a registered CLIENT_STATE" {
    $env:CLIENT_STATE = 'bad_creds'
    (Get-TelemetryEvent -Code 0) | Should -Match '"tracebloc\.install\.client_state":"bad_creds"'
  }
  It "records cli_on_path as a number so it sums" {
    $env:TB_CLI_ON_FRESH_PATH = '1'
    (Get-TelemetryEvent -Code 0) | Should -Match '"tracebloc\.install\.cli_on_path":1'
  }
  It "ignores a cli_on_path that is neither 0 nor 1" {
    $env:TB_CLI_ON_FRESH_PATH = 'maybe'
    (Get-TelemetryEvent -Code 0) | Should -Not -Match 'cli_on_path'
  }
  It "always carries error.type on a failure, or it cannot be grouped (§8.4)" {
    (Get-TelemetryEvent -Code 1) | Should -Match '"error\.type":"bootstrap_failed"'
  }
  It "produces parseable JSON" {
    { Get-TelemetryEvent -Code 0 | ConvertFrom-Json } | Should -Not -Throw
  }
  It "puts the phase durations under attributes, one per phase entered" {
    $obj = Get-TelemetryEvent -Code 0 | ConvertFrom-Json
    $obj.attributes.'tracebloc.install.phase_bootstrap_ms' | Should -Not -BeNullOrEmpty
  }
  # ONE clock read per event, so the parts cannot disagree with the whole.
  It "keeps the phase total consistent with duration_ms" {
    Start-TelemetryPhase -Letter 'a'
    $obj = Get-TelemetryEvent -Code 0 | ConvertFrom-Json
    $sum = 0
    foreach ($p in $obj.attributes.PSObject.Properties) {
      if ($p.Name -like 'tracebloc.install.phase_*_ms') { $sum += [int]$p.Value }
    }
    $sum | Should -Be ([int]$obj.attributes.'tracebloc.install.duration_ms')
  }
}

Describe "Get-TelemetryEvent — source location, one gate for both halves" {
  BeforeEach { $env:CLIENT_ENV = 'stg' }

  It "records file and line together for one of our own scripts" {
    $env:TB_ERR_LOC = 'install-k8s.ps1:4211'
    $json = Get-TelemetryEvent -Code 1
    $json | Should -Match '"tracebloc\.install\.source":"install-k8s\.ps1"'
    $json | Should -Match '"tracebloc\.install\.source_line":4211'
  }
  It "discards the directory the path came from" {
    $env:TB_ERR_LOC = 'C:\Users\someone\scripts\install-k8s.ps1:12'
    $json = Get-TelemetryEvent -Code 1
    $json | Should -Match '"tracebloc\.install\.source":"install-k8s\.ps1"'
    $json | Should -Not -Match 'someone'
  }
  # A line number with no file is not a partial answer, it is a confident wrong
  # one — it reads and groups like information while pointing at line 9 of
  # nothing. `?:118` is what the bash ERR trap produced when BASH_SOURCE was empty.
  It "emits NEITHER half when the file is not one of ours" {
    $env:TB_ERR_LOC = 'something-else.ps1:118'
    $json = Get-TelemetryEvent -Code 1
    $json | Should -Not -Match 'source_line'
    $json | Should -Not -Match '"tracebloc\.install\.source"'
  }
  It "emits neither half for a location with no file at all" {
    $env:TB_ERR_LOC = '?:118'
    $json = Get-TelemetryEvent -Code 1
    $json | Should -Not -Match 'source_line'
  }
  It "sets no source on a SUCCESS even when TB_ERR_LOC is populated" {
    $env:TB_ERR_LOC = 'install-k8s.ps1:12'
    # NOT the bare word 'source': every record contains "resource", so the
    # loose regex matched always and the test could not fail.
    (Get-TelemetryEvent -Code 0) | Should -Not -Match 'tracebloc\.install\.source'
  }
}

Describe "Send-TelemetryOutcome — the latch, and at most once" {
  BeforeEach {
    $env:CLIENT_ENV = 'stg'
    $script:Spool = Join-Path ([IO.Path]::GetTempPath()) ("tbtest-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:Spool -Force | Out-Null
    $env:HOST_DATA_DIR = $script:Spool
  }
  AfterEach {
    Remove-Item -LiteralPath $script:Spool -Recurse -Force -ErrorAction SilentlyContinue
  }

  # The `--help` case: this path also runs for a run that installed nothing, and
  # a false success is worse than a missing record.
  It "emits nothing without the run-started latch" {
    Send-TelemetryOutcome -Code 0
    @(Get-ChildItem -Path $script:Spool -Recurse -File).Count | Should -Be 0
  }
  It "emits once the latch is set" {
    Set-TelemetryRunStarted
    Send-TelemetryOutcome -Code 0
    $spoolFile = Join-Path (Join-Path $script:Spool 'telemetry') 'pending.jsonl'
    Test-Path -LiteralPath $spoolFile | Should -BeTrue
    @(Get-Content -LiteralPath $spoolFile).Count | Should -Be 1
  }
  It "emits at most once per process, however often it is called" {
    Set-TelemetryRunStarted
    Send-TelemetryOutcome -Code 0
    Send-TelemetryOutcome -Code 1
    Send-TelemetryOutcome -Code 0
    $spoolFile = Join-Path (Join-Path $script:Spool 'telemetry') 'pending.jsonl'
    @(Get-Content -LiteralPath $spoolFile).Count | Should -Be 1
  }
  It "writes nothing when the user opted out" {
    Set-TelemetryRunStarted
    $env:DO_NOT_TRACK = '1'
    Send-TelemetryOutcome -Code 0
    @(Get-ChildItem -Path $script:Spool -Recurse -File).Count | Should -Be 0
  }
  It "never throws, whatever the exit code" -ForEach @(
    @{ Code = 0 }, @{ Code = 1 }, @{ Code = 2 }, @{ Code = 130 }, @{ Code = 255 }
  ) {
    Set-TelemetryRunStarted
    { Send-TelemetryOutcome -Code $Code } | Should -Not -Throw
  }

  # TELEMETRY MUST NOT CREATE HOST_DATA_DIR. On the bash side a trap that did
  # `mkdir -p` there made the next run see a directory the NFS guard had just
  # refused, and MySQL was installed onto NFS — the exact corruption client#432
  # exists to prevent, reintroduced by the observer.
  It "does NOT create HOST_DATA_DIR when it does not exist" {
    Set-TelemetryRunStarted
    $absent = Join-Path ([IO.Path]::GetTempPath()) ("tbtest-absent-" + [guid]::NewGuid())
    $env:HOST_DATA_DIR = $absent
    Send-TelemetryOutcome -Code 1
    Test-Path -LiteralPath $absent | Should -BeFalse
  }
  # ...and the record still has to land somewhere, or the pre-log failures this
  # exists for produce nothing anywhere.
  It "falls back to a spool outside the data dir, so the record is not lost" {
    Set-TelemetryRunStarted
    $absent = Join-Path ([IO.Path]::GetTempPath()) ("tbtest-absent-" + [guid]::NewGuid())
    $env:HOST_DATA_DIR = $absent
    $fallback = Get-TelemetryFallbackSpool
    Remove-Item -LiteralPath $fallback -Force -ErrorAction SilentlyContinue
    Send-TelemetryOutcome -Code 1
    Test-Path -LiteralPath $fallback | Should -BeTrue
    Remove-Item -LiteralPath $fallback -Force -ErrorAction SilentlyContinue
  }
}

Describe "Limit-TelemetrySpool — bounded, dropping the OLDEST" {
  BeforeEach {
    $script:S = Join-Path ([IO.Path]::GetTempPath()) ("tbspool-" + [guid]::NewGuid() + ".jsonl")
  }
  AfterEach { Remove-Item -LiteralPath $script:S -Force -ErrorAction SilentlyContinue }

  It "leaves a spool under the cap alone" {
    Set-Content -LiteralPath $script:S -Value (1..10 | ForEach-Object { "line$_" })
    Limit-TelemetrySpool -Spool $script:S
    @(Get-Content -LiteralPath $script:S).Count | Should -Be 10
  }
  It "trims to the cap and keeps the NEWEST records" {
    Set-Content -LiteralPath $script:S -Value (1..80 | ForEach-Object { "line$_" })
    Limit-TelemetrySpool -Spool $script:S
    $lines = @(Get-Content -LiteralPath $script:S)
    $lines.Count | Should -Be 50
    # Newest kept, oldest dropped — the opposite of D7's amended overflow row,
    # deliberately: this spool is our own code and the newest records describe
    # the failure in progress.
    $lines[-1] | Should -Be 'line80'
    $lines[0]  | Should -Be 'line31'
  }
  It "does not throw on a spool that is not there" {
    { Limit-TelemetrySpool -Spool (Join-Path ([IO.Path]::GetTempPath()) 'nope.jsonl') } |
      Should -Not -Throw
  }
}

Describe "Vocabularies are closed" {
  It "refuses to invent a phase name for an unknown step letter" {
    Get-TelemetryPhaseName -Letter 'z' | Should -BeNullOrEmpty
  }
  It "derives the legal phase names from the letter map, plus the two with no letter" {
    $names = Get-TelemetryPhaseNames
    $names | Should -Contain 'bootstrap'
    $names | Should -Contain 'unknown'
    $names | Should -Contain 'preflight'
    $names.Count | Should -Be 8
  }
  It "classifies every phase to a REGISTERED error class" {
    foreach ($p in (Get-TelemetryPhaseNames)) {
      $c = Get-TelemetryErrorClass -Code 1 -Phase $p -State '' -RerunHandoff $false
      $c | Should -BeIn $script:TbTelemetryErrorClasses
    }
  }
  It "classifies every client state to a REGISTERED error class" {
    foreach ($s in $script:TbTelemetryClientStates) {
      $c = Get-TelemetryErrorClass -Code 1 -Phase 'helm' -State $s -RerunHandoff $false
      $c | Should -BeIn $script:TbTelemetryErrorClasses
    }
  }
}

# ── IS IT ACTUALLY CONNECTED? ────────────────────────────────────────────────
#  An emitter nothing calls is the defect this ticket is about: install-k8s.ps1
#  had no telemetry while backend#1907 was closed claiming installer coverage. So
#  these assert the WIRING, not the emitter. They read the installer's source
#  because the call sites sit in a 6,600-line script whose main body cannot be
#  invoked from a unit test — the same technique the file's sibling suites already
#  use for install-k8s.ps1's structural guarantees.
Describe "the installer actually calls the emitter" {
  BeforeAll { $script:SRC = Get-Content "$PSScriptRoot/../install-k8s.ps1" -Raw }

  It "sources the lib, and tolerates it being absent" {
    $script:SRC | Should -Match "\. \`$script:TbTelemetryLib"
    # Optional by construction: a checkout predating the lib, or a bootstrap that
    # could not fetch it, must still install.
    $script:SRC | Should -Match 'Test-Path -LiteralPath \$script:TbTelemetryLib'
  }

  It "sets the run-started latch BEFORE Confirm-Config, and after the terminal flags" {
    $script:SRC | Should -Match 'Set-TelemetryRunStarted'
    # Order is the property, not mere presence. Before Confirm-Config, because a
    # genuine config failure IS an install attempt and must be reported; after the
    # -Help/-Diagnose dispatch, because those install nothing and a `finally` that
    # emitted for them would book a success for a run that never touched the machine.
    $latch = $script:SRC.IndexOf('Set-TelemetryRunStarted')
    $confirm = $script:SRC.IndexOf("`nConfirm-Config")
    $help = $script:SRC.IndexOf('if ($Help) { $script:OutcomeReported')
    $latch | Should -BeGreaterThan 0
    $confirm | Should -BeGreaterThan 0
    $latch | Should -BeLessThan $confirm
    $latch | Should -BeLessThan $help
  }

  It "declares the re-run handoff at BOTH exit-2 sites" {
    # Keyed on the DECLARATION, not on the number 2: an exit 2 nobody claimed —
    # grep on a missing file, curl on a failed init — must book as a failure with
    # its own error.type rather than as a cancel with none.
    ([regex]::Matches($script:SRC, 'Set-TbRerunHandoff')).Count | Should -BeGreaterOrEqual 3
    # ...and every literal `exit 2` is preceded by one.
    foreach ($m in [regex]::Matches($script:SRC, '(?m)^\s*exit 2\s*$')) {
      $before = $script:SRC.Substring([Math]::Max(0, $m.Index - 400), [Math]::Min(400, $m.Index))
      $before | Should -Match 'Set-TbRerunHandoff' -Because "an undeclared exit 2 books as a cancel with no error.type"
    }
  }

  It "advances the phase from every numbered step, using the shared letters" {
    # Six steps, each declaring a phase letter from the vocabulary both twins
    # share. Without the letter the whole run is attributed to `bootstrap` and the
    # per-phase durations say nothing.
    $letters = [regex]::Matches($script:SRC, '\$script:INSTALL_STEPS\.Count "[^"]+" "([a-f])"')
    $letters.Count | Should -Be 6
    ($letters | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) |
      Should -Be @('a', 'b', 'c', 'd', 'e')
  }

  It "records a non-zero status for a failed install" {
    # PowerShell gives `finally` no access to an exit's code, so the classifying
    # sites record it. If they stop, the outcome event reports 0 for a failed
    # install — the one wrong answer that looks entirely fine.
    # `= 1;` WITH THE SEMICOLON. Plain '= 1' is a PREFIX of '= 130', so the
    # interrupted line satisfied it and the assertion survived deleting the failure
    # line entirely — caught by mutation testing, not by reading it.
    $script:SRC | Should -Match '\$script:TbExitCode = 1;'
    $script:SRC | Should -Match '\$script:TbExitCode = 130'
  }

  It "emits from the finally, which is this platform's install_cleanup" {
    $script:SRC | Should -Match 'Send-TelemetryOutcome -Code \$script:TbExitCode'
  }

  It "is fetched and hash-pinned like every other installer script" {
    $boot = Get-Content "$PSScriptRoot/../install.ps1" -Raw
    $boot | Should -Match 'scripts/lib/telemetry\.ps1'
    # A nested $Files entry needs its parent directory created: Invoke-WebRequest
    # -OutFile does not, and this was the first scripts/lib/ entry.
    $boot | Should -Match 'New-Item -ItemType Directory -Path \$destDir'
    $manifest = Get-Content "$PSScriptRoot/../manifest.sha256" -Raw
    $manifest | Should -Match 'scripts/lib/telemetry\.ps1'
  }
}

}
