param([string]$Configuration = 'debug')
$ErrorActionPreference = 'Stop'
$cesRoot = Split-Path -Parent $PSScriptRoot
$cesScratch = Join-Path $cesRoot ('.build/gate-regression-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $cesScratch -Force | Out-Null
$cesFailures = [Collections.Generic.List[string]]::new()

# Deliberately return an unrelated error whose filename contains "Escape".
# The safety gate must inspect the diagnostic message, not the path.
function swiftc {
    $cesFixture = @($args | Where-Object { $_ -like '*.swift' })[0]
    $cesName = [IO.Path]::GetFileNameWithoutExtension($cesFixture)
    $global:LASTEXITCODE = 1
    switch ($cesName) {
        'UnsafeReadPositive' { $global:LASTEXITCODE = 0 }
        'ArenaScopedPositive' { $global:LASTEXITCODE = 0 }
        'UnsafeReadRejected' { "$($cesFixture):1:1: error: unmarked unsafe expression [#StrictMemorySafety]" }
        'UnsafeStorageRejected' { "$($cesFixture):1:1: error: unmarked unsafe storage [#StrictMemorySafety]" }
        'ArenaEscapeRejected' { "$($cesFixture):1:1: error: unrelated syntax failure" }
        'ArenaMutationWhileBorrowedRejected' { "$($cesFixture):1:1: error: overlapping accesses to 'arena'" }
        default { throw "unexpected fixture: $cesName" }
    }
}
$cesRejectedDiagnostic = $false
try {
    # Keep synthetic diagnostics separate from the real compiler evidence.
    $cesFakeConfiguration = 'gate-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    & (Join-Path $PSScriptRoot 'ces_memory_safety_checks.ps1') -BinPath $cesScratch -Configuration $cesFakeConfiguration
} catch {
    if ($_.Exception.Message -notmatch 'Safety rejection not enforced: ArenaEscapeRejected') { throw }
    $cesRejectedDiagnostic = $true
}
if (-not $cesRejectedDiagnostic) { $cesFailures.Add('safety gate accepted an unrelated error through its filename') }
else { Write-Host 'PASS gate rejects unrelated diagnostic containing Escape in filename' }

Copy-Item -LiteralPath (Join-Path $cesRoot 'Sources') -Destination $cesScratch -Recurse
Copy-Item -LiteralPath (Join-Path $cesRoot 'Package.swift') -Destination $cesScratch
$cesOwnerPath = Join-Path $cesScratch 'Sources/CESServerCore/CESOwnership.swift'
if (-not (Test-Path -LiteralPath $cesOwnerPath -PathType Leaf)) { throw 'reviewed owner source missing from Sources/CESServerCore' }
[IO.File]::AppendAllText($cesOwnerPath, "`n@safe`nprivate struct UnreviewedSafeStorage { var address: UnsafePointer<Int>? }`n", [Text.UTF8Encoding]::new($false))
$cesRejectedAnnotation = $false
try { & (Join-Path $PSScriptRoot 'ces_source_policy.ps1') -ProjectRoot $cesScratch }
catch {
    if ($_.Exception.Message -notmatch 'Unreviewed safe declaration') { throw }
    $cesRejectedAnnotation = $true
}
if (-not $cesRejectedAnnotation) { $cesFailures.Add('source policy accepted an extra @safe in the reviewed owner file') }
else { Write-Host 'PASS gate rejects extra @safe in the reviewed owner file' }
# Restore the reviewed owner, then audit that no other source may declare @safe.
Copy-Item -LiteralPath (Join-Path $cesRoot 'Sources/CESServerCore/CESOwnership.swift') -Destination $cesOwnerPath -Force
$cesControlPath = Join-Path $cesScratch 'Sources/CESServerCore/CESControl.swift'
if (-not (Test-Path -LiteralPath $cesControlPath -PathType Leaf)) {
    $cesControlPath = (Get-ChildItem -LiteralPath (Join-Path $cesScratch 'Sources') -Recurse -File -Filter '*.swift' |
        Where-Object { $_.Name -ne 'CESOwnership.swift' } | Select-Object -First 1).FullName
}
if (-not $cesControlPath) { throw 'source policy regression found no second source file under Sources' }
[IO.File]::AppendAllText($cesControlPath, "`n@safe`nprivate struct UnreviewedSafeControl { var address: UnsafePointer<Int>? }`n", [Text.UTF8Encoding]::new($false))
$cesRejectedControl = $false
try { & (Join-Path $PSScriptRoot 'ces_source_policy.ps1') -ProjectRoot $cesScratch }
catch {
    if ($_.Exception.Message -notmatch 'Unreviewed @safe') { throw }
    $cesRejectedControl = $true
}
if (-not $cesRejectedControl) { $cesFailures.Add('source policy accepted an extra @safe outside the reviewed owner file') }
else { Write-Host 'PASS gate rejects extra @safe outside the reviewed owner file' }
if ($cesFailures.Count -ne 0) { throw ($cesFailures -join '; ') }
