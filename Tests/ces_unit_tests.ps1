param([ValidateSet('debug','release')][string]$Configuration = 'debug')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    & swift test -c $Configuration --build-system native 2>&1 | Tee-Object -Variable testOutput
    if ($LASTEXITCODE -ne 0) { throw 'swift test failed' }
    $summaries = [regex]::Matches(($testOutput -join "`n"), 'Test run with ([0-9]+) tests?\b[^\r\n]* passed')
    if ($summaries.Count -eq 0 -or [int]$summaries[$summaries.Count - 1].Groups[1].Value -eq 0) {
        throw 'Swift Testing did not execute any tests; verification failed'
    }
} finally { Pop-Location }
