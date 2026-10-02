param(
    [ValidateSet('debug', 'release')][string] $Configuration = 'debug',
    [ValidateSet('features', 'owners')][string] $Phase = 'features'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$cesRoot = Split-Path $PSScriptRoot
$cesIdentity = (Split-Path $cesRoot -Leaf).ToLowerInvariant() -replace '[^a-z0-9_]', '_'
$cesBin = (& swift build --package-path $cesRoot -c $Configuration --show-bin-path).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve Swift product directory' }
$cesScratch = Join-Path $cesRoot ".build/ownership-$Configuration"
New-Item -ItemType Directory -Path $cesScratch -Force | Out-Null
$cesCases = if ($Phase -eq 'features') {
    @(@('FeaturesPositive', $true), @('FeaturesCopyRejected', $false))
} else {
    @(@('OwnersPositive', $true), @('OwnersCopyRejected', $false),
      @('OwnersUseAfterConsumeRejected', $false), @('BorrowedOwnerDestroyedRejected', $false),
      @('SpanEscapeRejected', $false), @('ConfigurationCopyRejected', $false))
}
foreach ($cesCase in $cesCases) {
    $cesName = $cesCase[0]
    $cesFixture = Join-Path $PSScriptRoot "ownership/$cesName.swift"
    $cesLog = Join-Path $cesScratch "$cesName.log"
    & swiftc -swift-version 6 -package-name $cesIdentity -parse-as-library -c -I $cesBin $cesFixture -o (Join-Path $cesScratch "$cesName.obj") *> $cesLog
    $cesCode = $LASTEXITCODE
    $cesOutput = Get-Content -LiteralPath $cesLog -Raw
    $cesDiagnostics = (($cesOutput -split "`n") | ForEach-Object { if ($_ -match 'error:\s*(.+)') { $Matches[1] } }) -join "`n"
    if ($cesCase[1]) {
        if ($cesCode -ne 0) { throw "Positive ownership fixture failed: $cesName`n$cesOutput" }
    } elseif ($cesCode -eq 0 -or $cesDiagnostics -notmatch '(?i)noncopyable|consum|borrow|lifetime|escap') {
        throw "Expected ownership diagnostic missing: $cesName`n$cesOutput"
    }
    Write-Host "PASS ownership $cesName"
}
