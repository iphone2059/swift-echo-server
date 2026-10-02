param(
    [Parameter(Mandatory)][string] $ServerPath,
    [ValidateSet('debug','release')][string] $Configuration = 'debug',
    [string] $ClientPath,
    [string] $CppClientPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Cross-implementation acceptance: the Swift server is driven by the already
# verified RIO clients. Each client verifies every echoed byte itself and exits 0
# only when no echo was corrupted or lost, so a zero exit plus byte accounting
# between client and server is independent evidence for the server engine.
if (-not (Test-Path -LiteralPath $ServerPath -PathType Leaf)) {
    throw "server executable not found: $ServerPath"
}
function Find-CESWorkspace {
    # The package may run from a standalone copy below its own .build directory;
    # walk up until the directory that holds the sibling client projects is found.
    $candidate = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    for ($level = 0; $level -lt 4; $level++) {
        foreach ($sibling in @('swift-echo-client', 'cpp-echo-client')) {
            if (Test-Path -LiteralPath (Join-Path $candidate $sibling) -PathType Container) {
                return $candidate
            }
        }
        $parent = Split-Path -Parent $candidate
        if (-not $parent -or $parent -eq $candidate) { break }
        $candidate = $parent
    }
    return Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$cesWorkspace = Find-CESWorkspace
$cesFlavor = if ($Configuration -eq 'release') { 'Release' } else { 'Debug' }
if (-not $ClientPath) {
    $cesCandidate = Join-Path $cesWorkspace "swift-echo-client/.build/out/Products/$cesFlavor-windows-x86_64/swift-echo-client.exe"
    if (Test-Path -LiteralPath $cesCandidate) { $ClientPath = $cesCandidate }
}
if (-not $CppClientPath) {
    $cesCandidate = Join-Path $cesWorkspace "cpp-echo-client/build/$Configuration/cpp-echo-client.exe"
    if (Test-Path -LiteralPath $cesCandidate) { $CppClientPath = $cesCandidate }
}
function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([System.Net.IPEndPoint] $listener.LocalEndpoint).Port } finally { $listener.Stop() }
}
function Get-FreeUdpPort {
    $socket = [System.Net.Sockets.UdpClient]::new(0)
    try { return ([System.Net.IPEndPoint] $socket.Client.LocalEndPoint).Port } finally { $socket.Dispose() }
}
function Invoke-CESProcess {
    param([string]$Path, [string[]]$Arguments, [int]$TimeoutMilliseconds = 60000)
    $psi = [Diagnostics.ProcessStartInfo]::new($Path)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $psi.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill($true)
            throw "process timeout: $Path $Arguments"
        }
        [pscustomobject]@{ Code = $process.ExitCode; Text = $stdout.Result; ErrorText = $stderr.Result }
    } finally {
        if (-not $process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
}
function Wait-TcpReady {
    param([int]$Port, [int]$TimeoutMilliseconds = 10000)
    $deadline = [Environment]::TickCount64 + $TimeoutMilliseconds
    while ([Environment]::TickCount64 -lt $deadline) {
        $client = $null
        try {
            $client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $Port)
            return $true
        } catch { Start-Sleep -Milliseconds 100 } finally { if ($client) { $client.Dispose() } }
    }
    return $false
}
function Wait-UdpEcho {
    param([int]$Port, [int]$TimeoutMilliseconds = 10000)
    $socket = [System.Net.Sockets.UdpClient]::new(0)
    try {
        $socket.Client.ReceiveTimeout = 300
        $target = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, $Port)
        $probe = [byte[]]@(0x5A)
        $deadline = [Environment]::TickCount64 + $TimeoutMilliseconds
        while ([Environment]::TickCount64 -lt $deadline) {
            [void]$socket.Send($probe, $probe.Length, $target)
            try {
                $source = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                $reply = $socket.Receive([ref]$source)
                if ($reply.Length -eq 1 -and $reply[0] -eq 0x5A) { return $true }
            } catch { }
        }
        return $false
    } finally { $socket.Dispose() }
}
function Invoke-InteropScenario {
    param(
        [string] $Name,
        [ValidateSet('tcp','udp')][string] $Protocol,
        [string] $ClientExe,
        [string[]] $ClientArguments,
        [string[]] $Patterns,
        [int] $ServerSeconds = 5,
        [bool] $ExactByteAccounting = $true
    )
    if (-not (Test-Path -LiteralPath $ClientExe -PathType Leaf)) {
        Write-Host "SKIP $Name (client binary missing: $ClientExe)"
        return
    }
    $port = if ($Protocol -eq 'tcp') { Get-FreeTcpPort } else { Get-FreeUdpPort }
    $stamp = [Guid]::NewGuid().ToString('N')
    $serverOut = Join-Path $env:TEMP "ces_interop_$stamp.out"
    $serverErr = Join-Path $env:TEMP "ces_interop_$stamp.err"
    $serverArguments = @('/p', $Protocol, '/s', "$port", '/w', "$ServerSeconds", '/stats')
    if ($Protocol -eq 'tcp') {
        $serverArguments += @('/threads', '4', '/cq', '8192', '/memory', '268435456')
    } else {
        $serverArguments += @('/k', '256', '/cq', '8192', '/memory', '268435456')
    }
    $server = Start-Process -FilePath $ServerPath -ArgumentList $serverArguments -PassThru -NoNewWindow ` -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
    try {
        $ready = if ($Protocol -eq 'tcp') { Wait-TcpReady -Port $port } else { Wait-UdpEcho -Port $port }
        if (-not $ready) { throw "$Name server never became ready" }
        $arguments = @($ClientArguments | ForEach-Object { $_ -replace '{port}', "$port" })
        $result = Invoke-CESProcess -Path $ClientExe -Arguments $arguments
        if ($result.Code -ne 0) {
            throw "$Name client exit $($result.Code): $($result.Text) $($result.ErrorText)"
        }
        foreach ($pattern in $Patterns) {
            if ($result.Text -notmatch $pattern) {
                throw "$Name client output missing $($pattern): $($result.Text)"
            }
        }
        if (-not $server.WaitForExit(($ServerSeconds + 20) * 1000)) {
            throw "$Name server did not stop within the configured run limit"
        }
        if ($server.ExitCode -ne 0) { throw "$Name server exit $($server.ExitCode)" }
        $serverText = Get-Content -LiteralPath $serverOut -Raw
        $serverError = Get-Content -LiteralPath $serverErr -Raw
        if ($serverError) { throw "$Name server stderr: $serverError" }
        $terminal = if ($Protocol -eq 'tcp') { 'final protocol=tcp .* active=0' } else { 'final protocol=udp .* outstanding=0' }
        if ($serverText -notmatch $terminal) { throw "$Name server terminal line missing: $serverText" }
        if ($ExactByteAccounting) {
            $clientFinal = @($result.Text -split "\r?\n" | Where-Object { $_ -match '^final ' }) | Select-Object -Last 1
            $serverFinal = @($serverText -split "\r?\n" | Where-Object { $_ -match '^final ' }) | Select-Object -Last 1
            if (-not $clientFinal -or -not $serverFinal) { throw "$Name final statistics line missing" }
            $clientBytes = [regex]::Match($clientFinal, 'bytes=(\d+) ').Groups[1].Value
            $serverBytes = [regex]::Match($serverFinal, 'bytes=(\d+) ').Groups[1].Value
            if (-not $clientBytes -or -not $serverBytes) { throw "$Name byte accounting missing" }
            if ([UInt64]$clientBytes -ne [UInt64]$serverBytes) {
                throw "$Name byte mismatch client=$clientBytes server=$serverBytes"
            }
        }
        Write-Host "PASS $Name (port $port, $([regex]::Match($serverText, 'bytes=\d+').Value)) (final line)"
    } finally {
        if (-not $server.HasExited) { $server.Kill($true) }
        $server.Dispose()
        Remove-Item -LiteralPath $serverOut, $serverErr -Force -ErrorAction SilentlyContinue
    }
}
if (-not $ClientPath) {
    throw 'swift-echo-client.exe was not found; interop acceptance requires the verified client'
}
Invoke-InteropScenario -Name 'swift client TCP' -Protocol tcp -ClientExe $ClientPath ` -ClientArguments @('127.0.0.1', '/p', 'tcp', '/r', '{port}', '/n', '500', '/k', '8', '/z', '4096', ` '/c', '8', '/threads', '4', '/q', '/stats') ` -Patterns @('echoed=500 ', 'corrupted=0 ', 'lost=0 ', 'network_errors=0 ')
Invoke-InteropScenario -Name 'swift client UDP' -Protocol udp -ClientExe $ClientPath ` -ClientArguments @('127.0.0.1', '/p', 'udp', '/r', '{port}', '/n', '200', '/z', '1200', ` '/c', '4', '/threads', '2', '/q', '/stats') ` -Patterns @('echoed=200 ', 'corrupted=0 ', 'lost=0 ', 'network_errors=0 ') -ExactByteAccounting $false
if ($CppClientPath -and (Test-Path -LiteralPath $CppClientPath -PathType Leaf)) {
    Invoke-InteropScenario -Name 'cpp client TCP' -Protocol tcp -ClientExe $CppClientPath ` -ClientArguments @('127.0.0.1', '/p', 'tcp', '/r', '{port}', '/n', '500', '/k', '8', '/z', '4096', ` '/c', '8', '/threads', '4', '/q', '/stats') ` -Patterns @('echoed=500 ', 'corrupted=0 ', 'lost=0 ', 'network_errors=0 ')
    Invoke-InteropScenario -Name 'cpp client UDP' -Protocol udp -ClientExe $CppClientPath ` -ClientArguments @('127.0.0.1', '/p', 'udp', '/r', '{port}', '/n', '200', '/z', '1200', ` '/c', '4', '/threads', '2', '/q', '/stats') ` -Patterns @('echoed=200 ', 'corrupted=0 ', 'lost=0 ', 'network_errors=0 ') -ExactByteAccounting $false
} else {
    Write-Host 'SKIP cpp client scenarios (cpp-echo-client.exe not built)'
}
Write-Host 'PASS cross-implementation echo acceptance'
