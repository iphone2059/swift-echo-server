& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'build.ps1') -Configuration debug
exit $LASTEXITCODE
