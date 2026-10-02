param(
    [Parameter(Mandatory)]
    [string] $ServerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ces_test_support.ps1')

if (-not (Test-Path -LiteralPath $ServerPath -PathType Leaf)) {
    throw "server executable not found: $ServerPath"
}

$script:CESPassed = 0
function Write-CESPass {
    param([Parameter(Mandatory)] [string] $Scenario)
    $script:CESPassed++
    Write-Host "PASS $Scenario"
}

# Scenario 1: switch prefixes, inline values and ASCII case-insensitive names and values.
$prefixCases = @(
    @{ Name = 'single dash and uppercase switches'; Protocol = 'tcp'; Arguments = @('-P', 'TCP', '-S', [string] (Get-CESFreeTcpPort), '-W', '1', '-THREADS', '2', '-STATS') },
    @{ Name = 'double dash with inline values'; Protocol = 'udp'; Arguments = @('--p=udp', ('--s=' + [string] (Get-CESFreeUdpPort)), '--w=1', '--stats') },
    @{ Name = 'mixed case protocol value'; Protocol = 'udp'; Arguments = @('/p', 'UdP', '/s', [string] (Get-CESFreeUdpPort), '/w', '1', '/stats') },
    @{ Name = 'repeated protocol switch with a last-wins inline value'; Protocol = 'udp'; Arguments = @('/p', 'tcp', '--p=UDP', '/s', [string] (Get-CESFreeUdpPort), '/w', '1', '/stats') }
)
foreach ($case in $prefixCases) {
    $result = Invoke-CESProcess -Path $ServerPath -TimeoutMilliseconds 15000 -Arguments $case.Arguments
    if ($result.Code -ne 0) {
        throw "valid arguments '$($case.Name)' exited with $($result.Code): stdout=$($result.Text) stderr=$($result.ErrorText)"
    }
    Assert-CESEqual '' $result.ErrorText.Trim() "valid arguments '$($case.Name)' wrote to stderr"
    $final = Get-CESFinalStatistics -Text $result.Text
    Assert-CESFinalShape -Statistics $final -Protocol $case.Protocol
}
Write-CESPass 'switch prefixes, inline values and case-insensitive spellings'

# Scenario 2: /q never changes the /stats output and never hides it.
$quietStatsPort = Get-CESFreeTcpPort
$quietStats = Invoke-CESProcess -Path $ServerPath -TimeoutMilliseconds 15000 -Arguments @(
    '/p', 'tcp', '/s', [string] $quietStatsPort, '/w', '1', '/threads', '1', '/q', '/stats')
Assert-CESEqual 0 $quietStats.Code '/q /stats exit code'
Assert-CESEqual '' $quietStats.ErrorText.Trim() '/q /stats stderr'
$quietFinal = Get-CESFinalStatistics -Text $quietStats.Text
Assert-CESFinalShape -Statistics $quietFinal -Protocol 'tcp'
$plainStatsPort = Get-CESFreeTcpPort
$plainStats = Invoke-CESProcess -Path $ServerPath -TimeoutMilliseconds 15000 -Arguments @(
    '/p', 'tcp', '/s', [string] $plainStatsPort, '/w', '1', '/threads', '1', '/stats')
Assert-CESEqual 0 $plainStats.Code '/stats exit code'
$plainFinal = Get-CESFinalStatistics -Text $plainStats.Text
Assert-CESFinalShape -Statistics $plainFinal -Protocol 'tcp'
Assert-CESEqual $plainFinal.Fields.Count $quietFinal.Fields.Count '/q must not change the /stats field set'
Assert-CESEqual ($plainStats.Text -split "\r?\n").Count ($quietStats.Text -split "\r?\n").Count '/q must not change the /stats line count'

$silentPort = Get-CESFreeTcpPort
$silent = Invoke-CESProcess -Path $ServerPath -TimeoutMilliseconds 15000 -Arguments @(
    '/p', 'tcp', '/s', [string] $silentPort, '/w', '1', '/threads', '1', '/q')
Assert-CESEqual 0 $silent.Code '/q without /stats exit code'
Assert-CESEqual '' $silent.Text.Trim() '/q without /stats must print nothing'
Assert-CESEqual '' $silent.ErrorText.Trim() '/q without /stats stderr'
$barePort = Get-CESFreeTcpPort
$bare = Invoke-CESProcess -Path $ServerPath -TimeoutMilliseconds 15000 -Arguments @(
    '/p', 'tcp', '/s', [string] $barePort, '/w', '1', '/threads', '1')
Assert-CESEqual 0 $bare.Code 'run without /stats exit code'
Assert-CESEqual '' $bare.Text.Trim() 'run without /stats must print nothing'
Assert-CESEqual '' $bare.ErrorText.Trim() 'run without /stats stderr'
Write-CESPass '/q and /stats output suppression rule'

# Scenario 3: one worker line per worker and aggregate counters equal the worker sums.
foreach ($threads in @(2, 3)) {
    $workerPort = Get-CESFreeTcpPort
    $workerOutput = New-CESTempFile
    $workerError = New-CESTempFile
    $workerServer = $null
    $workerPeers = [System.Collections.Generic.List[object]]::new()
    try {
        $workerServer = Start-CESTestServer -Path $ServerPath -OutputPath $workerOutput -ErrorPath $workerError -Arguments @(
            '/p', 'tcp', '/s', [string] $workerPort, '/w', '3', '/threads', [string] $threads, '/cq', '1024',
            '/memory', '67108864', '/stats')
        $ready = Wait-CESTcpReadyPeer -Port $workerPort -Process $workerServer -TimeoutMilliseconds 5000 -ProbeBytes 64
        $workerPeers.Add($ready.Peer)
        $expectedBytes = [long] $ready.ProbeBytes
        foreach ($index in 2..$threads) {
            $peer = New-CESTcpPeer -Port $workerPort -TimeoutMilliseconds 5000
            $workerPeers.Add($peer)
            $payload = [CESTcpPeer]::Pattern(4096, 300 + $index)
            $peer.Exchange($payload, 0, 0, 5000)
            $expectedBytes += [long] $payload.Length
        }
        $workerExit = Wait-CESProcessExit -Process $workerServer -TimeoutMilliseconds 15000 -Context "worker statistics server (/threads $threads)"
        Assert-CESEqual 0 $workerExit "worker statistics server exit code (/threads $threads)"
        $workerStdout = Read-CESOutputFile $workerOutput
        $workerStderr = Read-CESOutputFile $workerError
        Assert-CESEqual '' $workerStderr.Trim() "worker statistics server stderr (/threads $threads)"
        $final = Get-CESFinalStatistics -Text $workerStdout
        Assert-CESFinalShape -Statistics $final -Protocol 'tcp'
        $workers = Get-CESWorkerCounters -Text $workerStdout
        Assert-CESEqual $threads $workers.Count "one worker line per TCP worker (/threads $threads)"
        Assert-CESEqual $threads (@($workers | Select-Object -ExpandProperty Index -Unique).Count) "distinct worker indices (/threads $threads)"
        foreach ($worker in $workers) {
            Assert-CESEqual 0 $worker.Active "worker $($worker.Index) active"
            Assert-CESTrue ($worker.Completions -ge ($worker.Receives + $worker.Sends)) "worker $($worker.Index) completions $($worker.Completions) is below receives+sends $($worker.Receives + $worker.Sends)"
        }
        Assert-CESAccepted -Ready $ready -Additional ($threads - 1) -Observed (Get-CESCounter $final 'accepted') -Message "worker statistics server accepted (/threads $threads)"
        foreach ($counter in @('completions', 'receives', 'sends', 'bytes')) {
            $property = (Get-Culture).TextInfo.ToTitleCase($counter)
            $sum = [long] (($workers | Measure-Object -Property $property -Sum).Sum)
            Assert-CESEqual $sum (Get-CESCounter $final $counter) "aggregate $counter equals the per-worker sum (/threads $threads)"
        }
        Assert-CESEqual ($expectedBytes + [long] $ready.DiscardedSentBytes) (Get-CESCounter $final 'bytes') "worker statistics server bytes (/threads $threads)"
        Write-CESPass "per-worker statistics and aggregate sums with /threads $threads"
    } finally {
        foreach ($peer in $workerPeers) { Close-CESPeer $peer }
        Stop-CESTestProcess $workerServer
        Remove-Item -LiteralPath $workerOutput, $workerError -Force -ErrorAction SilentlyContinue
    }
}

# Scenario 4: minimum /cq, /rio-buffer and /memory values plus the MiB_per_sec formula.
$minimumPort = Get-CESFreeTcpPort
$minimumOutput = New-CESTempFile
$minimumError = New-CESTempFile
$minimumServer = $null
$minimumPeer = $null
try {
    $minimumServer = Start-CESTestServer -Path $ServerPath -OutputPath $minimumOutput -ErrorPath $minimumError -Arguments @(
        '/p', 'tcp', '/s', [string] $minimumPort, '/w', '2', '/threads', '1', '/cq', '64',
        '/rio-buffer', '512', '/memory', '1048576', '/stats')
    $ready = Wait-CESTcpReadyPeer -Port $minimumPort -Process $minimumServer -TimeoutMilliseconds 5000 -ProbeBytes 512
    $minimumPeer = $ready.Peer
    $payload = [CESTcpPeer]::Pattern(4096, 401)
    $minimumPeer.Exchange($payload, 0, 0, 10000)
    $minimumExit = Wait-CESProcessExit -Process $minimumServer -TimeoutMilliseconds 15000 -Context 'minimum capacity server'
    Assert-CESEqual 0 $minimumExit 'minimum /cq, /rio-buffer and /memory server exit code'
    $minimumStdout = Read-CESOutputFile $minimumOutput
    $minimumStderr = Read-CESOutputFile $minimumError
    Assert-CESEqual '' $minimumStderr.Trim() 'minimum capacity server stderr'
    $final = Get-CESFinalStatistics -Text $minimumStdout
    Assert-CESFinalShape -Statistics $final -Protocol 'tcp'
    Assert-CESAccepted -Ready $ready -Additional 0 -Observed (Get-CESCounter $final 'accepted') -Message 'minimum capacity server accepted'
    Assert-CESEqual ([long] $ready.ProbeBytes + [long] $payload.Length) (Get-CESCounter $final 'bytes') 'minimum capacity server bytes'
    Assert-CESTrue ($final.ElapsedMs -ge 900) "minimum capacity server reported elapsed_ms $($final.ElapsedMs) for /w 2"
    Assert-CESRate -Statistics $final
    Write-CESPass 'minimum /cq 64, /rio-buffer 512 and /memory 1048576 with MiB_per_sec arithmetic'
} finally {
    Close-CESPeer $minimumPeer
    Stop-CESTestProcess $minimumServer
    Remove-Item -LiteralPath $minimumOutput, $minimumError -Force -ErrorAction SilentlyContinue
}

# Scenario 5: one-byte fragmented writes, an abrupt reset and a connection opened afterwards.
$fragmentPort = Get-CESFreeTcpPort
$fragmentOutput = New-CESTempFile
$fragmentError = New-CESTempFile
$fragmentServer = $null
$fragmentPeers = [System.Collections.Generic.List[object]]::new()
try {
    $fragmentServer = Start-CESTestServer -Path $ServerPath -OutputPath $fragmentOutput -ErrorPath $fragmentError -Arguments @(
        '/p', 'tcp', '/s', [string] $fragmentPort, '/w', '4', '/threads', '2', '/cq', '1024',
        '/memory', '67108864', '/stats')
    $ready = Wait-CESTcpReadyPeer -Port $fragmentPort -Process $fragmentServer -TimeoutMilliseconds 5000 -ProbeBytes 64
    $oneBytePeer = $ready.Peer
    $fragmentPeers.Add($oneBytePeer)
    $oneBytePayload = [CESTcpPeer]::Pattern(1000, 501)
    $writesBefore = $oneBytePeer.Writes
    $oneBytePeer.Exchange($oneBytePayload, 1, 0, 10000)
    Assert-CESEqual 1000 ($oneBytePeer.Writes - $writesBefore) 'one-byte fragment write count'

    $resetPeer = New-CESTcpPeer -Port $fragmentPort -TimeoutMilliseconds 5000
    $fragmentPeers.Add($resetPeer)
    $resetPeer.AbortMidStream([CESTcpPeer]::Pattern(131072, 502), 2048, 1024, 5000)

    $recoveryPeer = New-CESTcpPeer -Port $fragmentPort -TimeoutMilliseconds 5000
    $fragmentPeers.Add($recoveryPeer)
    $recoveryPayload = [CESTcpPeer]::Pattern(8192, 503)
    $recoveryPeer.Exchange($recoveryPayload, 0, 0, 5000)

    $fragmentExit = Wait-CESProcessExit -Process $fragmentServer -TimeoutMilliseconds 15000 -Context 'fragmented/reset server'
    Assert-CESEqual 0 $fragmentExit 'fragmented/reset server exit code'
    $fragmentStdout = Read-CESOutputFile $fragmentOutput
    $fragmentStderr = Read-CESOutputFile $fragmentError
    Assert-CESEqual '' $fragmentStderr.Trim() 'fragmented/reset server stderr'
    $final = Get-CESFinalStatistics -Text $fragmentStdout
    Assert-CESFinalShape -Statistics $final -Protocol 'tcp'
    Assert-CESAccepted -Ready $ready -Additional 2 -Observed (Get-CESCounter $final 'accepted') -Message 'fragmented/reset server accepted'
    $minimumBytes = [long] $ready.ProbeBytes + [long] $oneBytePayload.Length + [long] $recoveryPayload.Length
    $maximumBytes = $minimumBytes + 131072
    $observedBytes = Get-CESCounter $final 'bytes'
    Assert-CESTrue ($observedBytes -ge $minimumBytes) "fragmented/reset server bytes $observedBytes is below the $minimumBytes verified bytes"
    Assert-CESTrue ($observedBytes -le $maximumBytes) "fragmented/reset server bytes $observedBytes exceeds the $maximumBytes bytes the peers sent"
    Write-CESPass 'one-byte fragmented writes, abrupt reset survival and a fresh connection'
} finally {
    foreach ($peer in $fragmentPeers) { Close-CESPeer $peer }
    Stop-CESTestProcess $fragmentServer
    Remove-Item -LiteralPath $fragmentOutput, $fragmentError -Force -ErrorAction SilentlyContinue
}

# Scenario 6: /t 1 does not close a connection that keeps receiving data.
$busyPort = Get-CESFreeTcpPort
$busyOutput = New-CESTempFile
$busyError = New-CESTempFile
$busyServer = $null
$busyPeer = $null
try {
    $busyServer = Start-CESTestServer -Path $ServerPath -OutputPath $busyOutput -ErrorPath $busyError -Arguments @(
        '/p', 'tcp', '/s', [string] $busyPort, '/t', '1', '/w', '6', '/threads', '1', '/cq', '1024',
        '/memory', '67108864', '/stats')
    $ready = Wait-CESTcpReadyPeer -Port $busyPort -Process $busyServer -TimeoutMilliseconds 5000 -ProbeBytes 64
    $busyPeer = $ready.Peer
    $chunk = [CESTcpPeer]::Pattern(256, 601)
    $roundTrips = 0
    $deadline = [DateTime]::UtcNow.AddSeconds(2.6)
    while ([DateTime]::UtcNow -lt $deadline) {
        $busyPeer.Write($chunk, 0, 0)
        $busyPeer.ReadEcho(256, 5000)
        $roundTrips++
        Start-Sleep -Milliseconds 250
    }
    Assert-CESTrue ($roundTrips -ge 8) "the continuously active connection completed only $roundTrips round-trips"
    $busyExit = Wait-CESProcessExit -Process $busyServer -TimeoutMilliseconds 20000 -Context 'tcp active-timeout server'
    Assert-CESEqual 0 $busyExit 'tcp active-timeout server exit code'
    $busyStdout = Read-CESOutputFile $busyOutput
    $busyStderr = Read-CESOutputFile $busyError
    Assert-CESEqual '' $busyStderr.Trim() 'tcp active-timeout server stderr'
    $final = Get-CESFinalStatistics -Text $busyStdout
    Assert-CESFinalShape -Statistics $final -Protocol 'tcp'
    Assert-CESEqual ([long] $ready.ProbeBytes + ([long] $chunk.Length * $roundTrips)) (Get-CESCounter $final 'bytes') 'tcp active-timeout server bytes'
    Assert-CESRate -Statistics $final
    Write-CESPass '/t 1 keeps a continuously active connection alive'
} finally {
    Close-CESPeer $busyPeer
    Stop-CESTestProcess $busyServer
    Remove-Item -LiteralPath $busyOutput, $busyError -Force -ErrorAction SilentlyContinue
}

# Scenario 7: UDP depth and rio-buffer boundaries.
$null = Assert-CESUsageError -Path $ServerPath -Arguments @('/p', 'udp', '/k', '1', '/rio-buffer', '65506')
$boundaryPort = Get-CESFreeUdpPort
$boundaryOutput = New-CESTempFile
$boundaryError = New-CESTempFile
$boundaryServer = $null
$boundaryPeer = $null
try {
    $boundaryServer = Start-CESTestServer -Path $ServerPath -OutputPath $boundaryOutput -ErrorPath $boundaryError -Arguments @(
        '/p', 'udp', '/s', [string] $boundaryPort, '/k', '1', '/rio-buffer', '65507', '/cq', '64',
        '/w', '3', '/stats')
    $ready = Wait-CESUdpReadyPeer -Port $boundaryPort -Process $boundaryServer -TimeoutMilliseconds 5000 -ProbeBytes 32
    $boundaryPeer = $ready.Peer
    $verifiedBytes = [long] $ready.ProbeBytes
    foreach ($size in @(65507, 1)) {
        $payload = [CESTcpPeer]::Pattern($size, 700 + $size)
        $boundaryPeer.Exchange($payload, 5000)
        $verifiedBytes += [long] $size
    }
    $boundaryExit = Wait-CESProcessExit -Process $boundaryServer -TimeoutMilliseconds 15000 -Context 'udp boundary server'
    Assert-CESEqual 0 $boundaryExit 'udp boundary server exit code'
    $boundaryStdout = Read-CESOutputFile $boundaryOutput
    $boundaryStderr = Read-CESOutputFile $boundaryError
    Assert-CESEqual '' $boundaryStderr.Trim() 'udp boundary server stderr'
    $final = Get-CESFinalStatistics -Text $boundaryStdout
    Assert-CESFinalShape -Statistics $final -Protocol 'udp'
    Assert-CESEqual (Get-CESCounter $final 'completions') ((Get-CESCounter $final 'receives') + (Get-CESCounter $final 'sends')) 'udp boundary completions must equal receives plus sends'
    $echoes = [long] $boundaryPeer.Echoes
    $sends = Get-CESCounter $final 'sends'
    Assert-CESTrue ($sends -ge $echoes) "udp boundary sends $sends is below the $echoes echoed datagrams"
    Assert-CESTrue ($sends -le ($echoes + [long] $ready.DiscardedDatagrams)) "udp boundary sends $sends exceeds the $echoes echoed plus $($ready.DiscardedDatagrams) discarded datagrams"
    $observedBytes = Get-CESCounter $final 'bytes'
    Assert-CESTrue ($observedBytes -ge $verifiedBytes) "udp boundary bytes $observedBytes is below the $verifiedBytes verified bytes"
    Assert-CESTrue ($observedBytes -le ($verifiedBytes + [long] $ready.DiscardedSentBytes)) "udp boundary bytes $observedBytes exceeds the verified bytes plus $($ready.DiscardedSentBytes) bytes from discarded probe datagrams"
    Assert-CESRate -Statistics $final
    Write-CESPass 'udp /k 1 and explicit /rio-buffer 65507 with 65506 rejected'
} finally {
    Close-CESPeer $boundaryPeer
    Stop-CESTestProcess $boundaryServer
    Remove-Item -LiteralPath $boundaryOutput, $boundaryError -Force -ErrorAction SilentlyContinue
}

# Scenario 8: maximum /w and /t values are accepted and the server keeps serving.
$maximumPort = Get-CESFreeTcpPort
$maximumOutput = New-CESTempFile
$maximumError = New-CESTempFile
$maximumServer = $null
$maximumPeer = $null
try {
    $maximumServer = Start-CESTestServer -Path $ServerPath -OutputPath $maximumOutput -ErrorPath $maximumError -Arguments @(
        '/p', 'tcp', '/s', [string] $maximumPort, '/w', '4294967295', '/t', '4294967295', '/threads', '1',
        '/cq', '1024', '/memory', '67108864', '/stats')
    $ready = Wait-CESTcpReadyPeer -Port $maximumPort -Process $maximumServer -TimeoutMilliseconds 5000 -ProbeBytes 64
    $maximumPeer = $ready.Peer
    $payload = [CESTcpPeer]::Pattern(1024, 801)
    $maximumPeer.Exchange($payload, 0, 0, 5000)
    Start-Sleep -Milliseconds 300
    Assert-CESTrue (-not $maximumServer.HasExited) 'server with maximum /w and /t exited early'
    Assert-CESEqual '' (Read-CESOutputFile $maximumError).Trim() 'server with maximum /w and /t wrote to stderr'
    Write-CESPass 'maximum /w and /t accepted without a usage error'
} finally {
    Close-CESPeer $maximumPeer
    Stop-CESTestProcess $maximumServer
    Remove-Item -LiteralPath $maximumOutput, $maximumError -Force -ErrorAction SilentlyContinue
}

Write-Host "SUMMARY ces_extended_process_tests.ps1: $script:CESPassed scenarios passed"
