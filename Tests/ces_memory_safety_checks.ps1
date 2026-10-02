param([Parameter(Mandatory)][string]$BinPath, [string]$Configuration = 'debug')
$ErrorActionPreference = 'Stop'
$cesRoot = Split-Path -Parent $PSScriptRoot
$cesIdentity = (Split-Path $cesRoot -Leaf).ToLowerInvariant() -replace '[^a-z0-9_]', '_'
$cesScratch = Join-Path $cesRoot ".build/safety-$Configuration"
New-Item -ItemType Directory -Path $cesScratch -Force | Out-Null
$cesCases = @(
  @('UnsafeReadPositive', $true, ''),
  @('ArenaScopedPositive', $true, ''),
  @('UnsafeReadRejected', $false, 'StrictMemorySafety'),
  @('UnsafeStorageRejected', $false, 'StrictMemorySafety'),
  @('ArenaEscapeRejected', $false, "requires that 'Span<UInt8>' conform to 'Escapable'"),
  @('ArenaMutationWhileBorrowedRejected', $false, 'overlapping accesses|exclusive access'))
foreach ($cesCase in $cesCases) {
  $cesName = $cesCase[0]
  $cesLog = Join-Path $cesScratch "$cesName.log"
  & swiftc -swift-version 6 -strict-memory-safety -warnings-as-errors -package-name $cesIdentity -parse-as-library -c -I $BinPath (Join-Path $PSScriptRoot "safety/$cesName.swift") -o (Join-Path $cesScratch "$cesName.obj") *> $cesLog
  $cesCode = $LASTEXITCODE
  $cesOutput = Get-Content -LiteralPath $cesLog -Raw
  $cesDiagnostics = (($cesOutput -split "`n") | ForEach-Object {
      if ($_ -match 'error:\s*(.+)') { $Matches[1] }
  }) -join "`n"
  if ($cesCase[1]) {
    if ($cesCode -ne 0) { throw "Positive safety fixture failed: $cesName`n$cesOutput" }
  } elseif ($cesCode -eq 0 -or $cesDiagnostics -notmatch $cesCase[2]) {
    throw "Safety rejection not enforced: $cesName`n$cesOutput"
  }
  Write-Host "PASS memory safety $cesName"
}
