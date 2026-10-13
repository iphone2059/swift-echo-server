param([ValidateSet('debug','release')][string]$Configuration = 'debug')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Find-CMakeTool {
    param([string]$Name)
    $command = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $finder = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path -LiteralPath $finder -PathType Leaf)) { throw "$Name.exe is required" }
    $installation = & $finder -latest -prerelease -products * -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installation)) { throw 'Visual Studio CMake tools were not found' }
    $relative = if ($Name -eq 'ninja') { 'Ninja/ninja.exe' } else { "CMake/bin/$Name.exe" }
    $candidate = Join-Path $installation "Common7/IDE/CommonExtensions/Microsoft/CMake/$relative"
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "$Name.exe is required" }
    return $candidate
}
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
    $cmake = Find-CMakeTool cmake
    $ctest = Find-CMakeTool ctest
    $ninja = Find-CMakeTool ninja
    $testDirectory = Join-Path $PSScriptRoot ".build/ctest-$Configuration"
    & $cmake -S $PSScriptRoot -B $testDirectory -G Ninja "-DCMAKE_MAKE_PROGRAM=$ninja" "-DSWIFT_CONFIGURATION=$Configuration" "-DSWIFT_BIN_PATH=$bin"
    if ($LASTEXITCODE -ne 0) { throw 'CTest configure failed' }
    & $ctest --test-dir $testDirectory --output-on-failure --no-tests=error
    if ($LASTEXITCODE -ne 0) { throw 'CTest verification failed' }
    $executable = Join-Path $bin 'swift-echo-server.exe'
    $manifest = [ordered]@{
        configuration = $Configuration
        optimize_mode = $(if ($Configuration -eq 'release') { '-O' } else { '-Onone' })
        toolchain = ((& swift --version) -join "`n")
        executable = $executable
        sha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($LASTEXITCODE -ne 0) { throw 'toolchain identity failed' }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testDirectory 'build-manifest.json') -Encoding utf8NoBOM
    Write-Host "PASS $Configuration build, CTest and reset storm: $executable"
} finally { Pop-Location }
