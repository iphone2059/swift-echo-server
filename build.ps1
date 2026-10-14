param([ValidateSet('debug','release')][string]$Configuration = 'debug')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    # The caller completes source changes and runs format.ps1 before this gate.
    $files = @(Get-Item -LiteralPath (Join-Path $PSScriptRoot 'Package.swift')) +
        @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Sources'), (Join-Path $PSScriptRoot 'Tests') -Recurse -File -Filter '*.swift')
    foreach ($file in $files) {
        & swift-format lint --strict $file.FullName
        if ($LASTEXITCODE -ne 0) { throw "Formatting check failed: $($file.FullName); run format.ps1" }
    }
    & swift build -c $Configuration --product swift-echo-server
    if ($LASTEXITCODE -ne 0) { throw 'swift build failed' }
    & swift build -c $Configuration --product swift-echo-server-fault-driver
    if ($LASTEXITCODE -ne 0) { throw 'fault driver build failed' }

    $bin = (& swift build -c $Configuration --show-bin-path).Trim()
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $bin -PathType Container)) { throw 'product path failed' }
    $testDirectory = Join-Path $PSScriptRoot ".build/verification-$Configuration"
    $verification = & (Join-Path $PSScriptRoot 'Tests/swiftpm_verification.ps1') -Component server -Configuration $Configuration -BinPath $bin
    $toolchain = ((& swift --version) -join [Environment]::NewLine)
    if ($LASTEXITCODE -ne 0) { throw 'toolchain identity failed' }
    $targetInfo = ((& swift -print-target-info) -join [Environment]::NewLine)
    if ($LASTEXITCODE -ne 0) { throw 'Swift target/SDK identity failed' }
    $sourceCommit = (& git rev-parse HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { $sourceCommit = $null }
    $sourceHashes = [ordered]@{}
    foreach ($sourceFile in @(Get-Item -LiteralPath (Join-Path $PSScriptRoot 'Package.swift')) + @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Sources') -File -Filter '*.swift' | Sort-Object Name)) {
        $sourceHashes[[IO.Path]::GetRelativePath($PSScriptRoot, $sourceFile.FullName)] = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $executable = Join-Path $bin 'swift-echo-server.exe'
    $manifest = [ordered]@{
        configuration = $Configuration
        optimize_mode = $(if ($Configuration -eq 'release') { '-O' } else { '-Onone' })
        toolchain = $toolchain
        target_info = ($targetInfo | ConvertFrom-Json)
        swift_path = (Get-Command swift -CommandType Application).Source
        windows_sdk_version_environment = $env:WindowsSDKVersion
        msvc_tools_version_environment = $env:VCToolsVersion
        source_commit = $sourceCommit
        source_dirty = $(if ($sourceCommit) { @(git status --porcelain).Count -ne 0 } else { $null })
        source_files_sha256 = $sourceHashes
        verification_directory = $verification.ArtifactDirectory
        verification_gates = $verification.GateCount
        executable = $executable
        sha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $testDirectory 'build-manifest.json') -Encoding utf8NoBOM
    Write-Host "PASS $Configuration SwiftPM build/test, PowerShell verification and reset storm: $executable"
} finally { Pop-Location }
