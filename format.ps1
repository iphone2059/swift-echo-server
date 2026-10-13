Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$formatter = (Get-Command swift-format.exe -ErrorAction Stop).Source
$files = @(Get-Item -LiteralPath (Join-Path $PSScriptRoot 'Package.swift')) +
    @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Sources'), (Join-Path $PSScriptRoot 'Tests') -Recurse -File -Filter '*.swift')
foreach ($file in $files) {
    & $formatter format --in-place $file.FullName
    if ($LASTEXITCODE -ne 0) { throw "Swift formatting failed: $($file.FullName)" }
}
