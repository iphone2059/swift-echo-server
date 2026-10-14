param(
    [Parameter(Mandatory)][ValidateSet('client','server')][string]$Component,
    [Parameter(Mandatory)][ValidateSet('debug','release')][string]$Configuration,
    [Parameter(Mandatory)][string]$BinPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$prefix = if ($Component -eq 'client') { 'cec' } else { 'ces' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$runDirectory = Join-Path $projectRoot ('.build/verification-' + $Configuration + '/run-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff') + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$gates = [Collections.Generic.List[object]]::new()
function Add-SwiftGate {
    param([string]$Name, [string]$Script, [string[]]$Arguments = @())
    $gates.Add([pscustomobject]@{ Name=$Name; Script=$Script; Arguments=$Arguments })
}
Add-SwiftGate unit "$($prefix)_unit_tests.ps1" @('-Configuration', $Configuration)
Add-SwiftGate source-policy "$($prefix)_source_policy.ps1"
Add-SwiftGate ownership-features "$($prefix)_ownership_compile_tests.ps1" @('-Configuration', $Configuration, '-Phase', 'features')
Add-SwiftGate ownership-owners "$($prefix)_ownership_compile_tests.ps1" @('-Configuration', $Configuration, '-Phase', 'owners')
Add-SwiftGate memory-safety "$($prefix)_memory_safety_checks.ps1" @('-BinPath', $BinPath, '-Configuration', $Configuration)
Add-SwiftGate gate-regressions "$($prefix)_verification_gate_tests.ps1" @('-Configuration', $Configuration)
Add-SwiftGate fault-processes "$($prefix)_fault_process_tests.ps1" @('-DriverPath', (Join-Path $BinPath "swift-echo-$Component-fault-driver.exe"))
if ($Component -eq 'client') {
    $client = Join-Path $BinPath 'swift-echo-client.exe'
    Add-SwiftGate process-contract cec_process_tests.ps1 @('-ClientPath', $client)
    Add-SwiftGate extended-process-contract cec_extended_process_tests.ps1 @('-ClientPath', $client, '-DriverPath', (Join-Path $BinPath 'swift-echo-client-fault-driver.exe'))
    Add-SwiftGate reset-storm cec_reset_storm_tests.ps1 @('-ClientPath', $client)
    if ($Configuration -eq 'release') { Add-SwiftGate optimized-hot-path cec_optimization_gate.ps1 @('-BinPath', $BinPath) }
} else {
    $server = Join-Path $BinPath 'swift-echo-server.exe'
    Add-SwiftGate process-contract ces_process_tests.ps1 @('-ServerPath', $server)
    Add-SwiftGate extended-process-contract ces_extended_process_tests.ps1 @('-ServerPath', $server)
    Add-SwiftGate cross-implementation ces_interop_tests.ps1 @('-ServerPath', $server, '-Configuration', $Configuration)
    Add-SwiftGate reset-storm ces_reset_storm_tests.ps1 @('-ServerPath', $server, '-Label', 'swift-echo-server')
}
if ($gates.Count -eq 0) { throw 'Empty SwiftPM verification suite' }
$results = [Collections.Generic.List[object]]::new()
foreach ($gate in $gates) {
    Write-Host "RUN $Configuration SwiftPM verification: $($gate.Name)"
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application).Source)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.WorkingDirectory=$projectRoot
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach ($argument in @('-NoProfile','-File',(Join-Path $PSScriptRoot $gate.Script)) + $gate.Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
    $timedOut = $false; $code = -1; $outputText = ''; $errorText = ''
    try {
        $timedOut = -not $process.WaitForExit(300000)
        if ($timedOut) { $process.Kill($true); if (-not $process.WaitForExit(5000)) { throw "$($gate.Name) cleanup timeout" } }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr), 5000)) { throw "$($gate.Name) output collection timeout" }
        $outputText=$stdout.GetAwaiter().GetResult(); $errorText=$stderr.GetAwaiter().GetResult()
        $code=$process.ExitCode
    } finally {
        $clock.Stop()
        try {
            if (-not $process.HasExited) { $process.Kill($true); if (-not $process.WaitForExit(5000)) { throw "$($gate.Name) cleanup timeout" } }
            if ($stdout.IsCompletedSuccessfully) { $outputText=$stdout.GetAwaiter().GetResult() }
            if ($stderr.IsCompletedSuccessfully) { $errorText=$stderr.GetAwaiter().GetResult() }
            [IO.File]::WriteAllText((Join-Path $runDirectory "$($gate.Name).stdout.log"), $outputText, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $runDirectory "$($gate.Name).stderr.log"), $errorText, [Text.UTF8Encoding]::new($false))
            $results.Add([pscustomobject]@{ name=$gate.Name; exit_code=$code; timed_out=$timedOut; duration_ms=$clock.ElapsedMilliseconds })
            $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runDirectory 'gate-results.json') -Encoding utf8NoBOM
        } finally { $process.Dispose() }
    }
    if ($timedOut -or $code -ne 0) {
        Write-Host $outputText
        if ($errorText) { [Console]::Error.WriteLine($errorText) }
        throw "SwiftPM verification $($gate.Name) failed: exit=$code timeout=$timedOut logs=$runDirectory"
    }
    Write-Host "PASS $Configuration $($gate.Name)"
}
[pscustomobject]@{ ArtifactDirectory=$runDirectory; GateCount=$gates.Count }
