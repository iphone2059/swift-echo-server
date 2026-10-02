param([ValidateSet('debug','release')][string]$Configuration = 'release')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$copy = Join-Path $root ('.build/standalone-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $copy | Out-Null
foreach ($entry in Get-ChildItem -LiteralPath $root -Force) {
    if ($entry.Name -in @('.build','.swiftpm','.git')) { continue }
    Copy-Item -LiteralPath $entry.FullName -Destination $copy -Recurse
}
$buildScript = Join-Path $copy 'build.ps1'
if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) { throw 'standalone copy has no build.ps1' }
& pwsh -NoProfile -File $buildScript -Configuration $Configuration
if ($LASTEXITCODE -ne 0) { throw 'independent copy build failed' }
Write-Host "PASS standalone copy: $copy"
