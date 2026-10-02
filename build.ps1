param([ValidateSet('debug','release')][string]$Configuration = 'debug')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    & swift build -c $Configuration --product swift-echo-server
    if ($LASTEXITCODE -ne 0) { throw 'swift build failed' }
    # Swift Build's optimized Windows test runner omits the test DLL import.
    # Native SwiftPM links test objects directly; both configurations execute the same suites.
    & swift test -c $Configuration --build-system native 2>&1 | Tee-Object -Variable cesTestOutput
    if ($LASTEXITCODE -ne 0) { throw 'swift test failed' }
    $cesSummary = [regex]::Matches(($cesTestOutput -join "`n"), 'Test run with ([0-9]+) tests?\b[^\r\n]* passed')
    if ($cesSummary.Count -eq 0 -or [int]$cesSummary[$cesSummary.Count - 1].Groups[1].Value -eq 0) {
        throw 'Swift Testing did not execute any tests; verification failed'
    }
    $bin = (& swift build -c $Configuration --show-bin-path).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'product path failed' }
    foreach ($phase in @('features','owners')) {
        & pwsh -NoProfile -File tests/ces_ownership_compile_tests.ps1 -Configuration $Configuration -Phase $phase
        if ($LASTEXITCODE -ne 0) { throw "ownership $phase failed" }
    }
    & pwsh -NoProfile -File tests/ces_source_policy.ps1
    if ($LASTEXITCODE -ne 0) { throw 'source policy failed' }
    & pwsh -NoProfile -File tests/ces_memory_safety_checks.ps1 -BinPath $bin -Configuration $Configuration
    if ($LASTEXITCODE -ne 0) { throw 'memory safety gate failed' }
    & pwsh -NoProfile -File tests/ces_verification_gate_tests.ps1 -Configuration $Configuration
    if ($LASTEXITCODE -ne 0) { throw 'verification gate regressions failed' }
    $server = Join-Path $bin 'swift-echo-server.exe'
    & pwsh -NoProfile -File tests/ces_process_tests.ps1 -ServerPath $server
    if ($LASTEXITCODE -ne 0) { throw 'baseline process acceptance failed' }
    & pwsh -NoProfile -File tests/ces_extended_process_tests.ps1 -ServerPath $server
    if ($LASTEXITCODE -ne 0) { throw 'extended process acceptance failed' }
    & pwsh -NoProfile -File tests/ces_interop_tests.ps1 -ServerPath $server -Configuration $Configuration
    if ($LASTEXITCODE -ne 0) { throw 'cross-implementation interop failed' }
    & pwsh -NoProfile -File tests/ces_reset_storm_tests.ps1 -ServerPath $server -Label 'swift-echo-server'
    if ($LASTEXITCODE -ne 0) { throw 'pre-accept reset recovery failed' }
    Write-Host "PASS $Configuration build and all checks: $server"
} finally { Pop-Location }
