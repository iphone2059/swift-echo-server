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

# Scenario 1: two simultaneous TCP connections, fragmented writes and a 256 KiB payload.
$tcpPort = Get-CESFreeTcpPort
$tcpOutput = New-CESTempFile
$tcpError = New-CESTempFile
$tcpServer = $null
$tcpPeers = [System.Collections.Generic.List[object]]::new()
try {
    $tcpServer = Start-CESTestServer -Path $ServerPath -OutputPath $tcpOutput -ErrorPath $tcpError -Arguments @(
        '/p', 'tcp', '/s', [string] $tcpPort, '/w', '4', '/threads', '2', '/cq', '1024',
        '/memory', '67108864', '/stats')
    $ready = Wait-CESTcpReadyPeer -Port $tcpPort -Process $tcpServer -TimeoutMilliseconds 5000 -ProbeBytes 64
    $fragmentedPeer = $ready.Peer
    $tcpPeers.Add($fragmentedPeer)
    $largePeer = New-CESTcpPeer -Port $tcpPort -TimeoutMilliseconds 5000
    $tcpPeers.Add($largePeer)

    $fragmented = [CESTcpPeer]::Pattern(65536, 11)
    $large = [CESTcpPeer]::Pattern(262144, 22)
    $fragmentedPeer.Write($fragmented, 997, 1)
    $largePeer.Exchange($large, 0, 0, 15000)
    $fragmentedPeer.ReadEcho(65536, 15000)

    Assert-CESTrue ($fragmentedPeer.Writes -gt 60) "fragmented payload used only $($fragmentedPeer.Writes) writes"
    Assert-CESEqual ([long] $ready.ProbeBytes + 65536) $fragmentedPeer.EchoedBytes 'fragmented payload echoed bytes'
    Assert-CESEqual 262144 $largePeer.EchoedBytes 'large payload echoed bytes'

    $expectedBytes = [long] $ready.ProbeBytes + [long] $fragmented.Length + [long] $large.Length

    $tcpExit = Wait-CESProcessExit -Process $tcpServer -TimeoutMilliseconds 20000 -Context 'tcp multi-connection server'
    Assert-CESEqual 0 $tcpExit 'tcp multi-connection server exit code'
    $tcpStdout = Read-CESOutputFile $tcpOutput
    $tcpStderr = Read-CESOutputFile $tcpError
    Assert-CESEqual '' $tcpStderr.Trim() 'tcp multi-connection server stderr'
    $final = Get-CESFinalStatistics -Text $tcpStdout
    Assert-CESFinalShape -Statistics $final -Protocol 'tcp'
    Assert-CESAccepted -Ready $ready -Additional 1 -Observed (Get-CESCounter $final 'accepted') -Message 'tcp final accepted'
    Assert-CESEqual ($expectedBytes + [long] $ready.DiscardedSentBytes) (Get-CESCounter $final 'bytes') 'tcp final bytes'
    $completions = Get-CESCounter $final 'completions'
    $receives = Get-CESCounter $final 'receives'
    $sends = Get-CESCounter $final 'sends'
    Assert-CESTrue ($completions -ge ($receives + $sends)) "tcp completions $completions is below receives+sends $($receives + $sends)"
    Assert-CESTrue ($receives -ge 1) 'tcp receives must not be zero'
    Assert-CESTrue ($sends -ge 2) "tcp sends $sends does not cover both connections"
    $workers = Get-CESWorkerCounters -Text $tcpStdout
    Assert-CESEqual 2 $workers.Count 'worker statistics line count for /threads 2'
    foreach ($worker in $workers) {
        Assert-CESEqual 0 $worker.Active "worker $($worker.Index) active"
    }
    Assert-CESEqual $completions ([long] (($workers | Measure-Object -Property Completions -Sum).Sum)) 'aggregate completions equals the worker sum'
    Assert-CESEqual (Get-CESCounter $final 'bytes') ([long] (($workers | Measure-Object -Property Bytes -Sum).Sum)) 'aggregate bytes equals the worker sum'
    Assert-CESRate -Statistics $final
    Write-CESPass 'tcp two simultaneous connections, fragmented writes and a 256 KiB byte-exact payload'
} finally {
    foreach ($peer in $tcpPeers) { Close-CESPeer $peer }
    Stop-CESTestProcess $tcpServer
    Remove-Item -LiteralPath $tcpOutput, $tcpError -Force -ErrorAction SilentlyContinue
}

# Scenario 2: one connection closed mid-stream, one held open while the server stops.
$resetPort = Get-CESFreeTcpPort
$resetOutput = New-CESTempFile
$resetError = New-CESTempFile
$resetServer = $null
$resetPeers = [System.Collections.Generic.List[object]]::new()
try {
    $resetServer = Start-CESTestServer -Path $ServerPath -OutputPath $resetOutput -ErrorPath $resetError -Arguments @(
        '/p', 'tcp', '/s', [string] $resetPort, '/w', '3', '/threads', '2', '/cq', '1024',
        '/memory', '67108864', '/stats')
    $ready = Wait-CESTcpReadyPeer -Port $resetPort -Process $resetServer -TimeoutMilliseconds 5000 -ProbeBytes 64
    $heldPeer = $ready.Peer
    $resetPeers.Add($heldPeer)

    $abortingPeer = New-CESTcpPeer -Port $resetPort -TimeoutMilliseconds 5000
    $resetPeers.Add($abortingPeer)
    $aborting = [CESTcpPeer]::Pattern(262144, 33)
    $abortingPeer.AbortMidStream($aborting, 4096, 2048, 5000)

    $followPeer = New-CESTcpPeer -Port $resetPort -TimeoutMilliseconds 5000
    $resetPeers.Add($followPeer)
    $follow = [CESTcpPeer]::Pattern(1024, 44)
    $followPeer.Exchange($follow, 0, 0, 5000)

    $drained = $heldPeer.WaitForServerClose(10000)
    Assert-CESTrue $drained 'the held TCP connection was not closed while the server drained'
    $resetExit = Wait-CESProcessExit -Process $resetServer -TimeoutMilliseconds 15000 -Context 'tcp reset/drain server'
    Assert-CESEqual 0 $resetExit 'tcp reset/drain server exit code'
    $resetStdout = Read-CESOutputFile $resetOutput
    $resetStderr = Read-CESOutputFile $resetError
    Assert-CESEqual '' $resetStderr.Trim() 'tcp reset/drain server stderr'
    $final = Get-CESFinalStatistics -Text $resetStdout
    Assert-CESFinalShape -Statistics $final -Protocol 'tcp'
    Assert-CESAccepted -Ready $ready -Additional 2 -Observed (Get-CESCounter $final 'accepted') -Message 'tcp reset/drain final accepted'
    $minimumBytes = [long] $ready.ProbeBytes + [long] $follow.Length
    $maximumBytes = $minimumBytes + [long] $aborting.Length
    $observedBytes = Get-CESCounter $final 'bytes'
    Assert-CESTrue ($observedBytes -ge $minimumBytes) "tcp bytes $observedBytes is below the $minimumBytes bytes the peers verified"
    Assert-CESTrue ($observedBytes -le $maximumBytes) "tcp bytes $observedBytes exceeds the $maximumBytes bytes the peers sent"
    Assert-CESRate -Statistics $final
    Write-CESPass 'tcp mid-stream reset, held connection drained at stop and clean exit'
} finally {
    foreach ($peer in $resetPeers) { Close-CESPeer $peer }
    Stop-CESTestProcess $resetServer
    Remove-Item -LiteralPath $resetOutput, $resetError -Force -ErrorAction SilentlyContinue
}

# Scenario 3: /t 1 closes an idle connection while other connections keep echoing.
$idlePort = Get-CESFreeTcpPort
$idleOutput = New-CESTempFile
$idleError = New-CESTempFile
$idleServer = $null
$idlePeers = [System.Collections.Generic.List[object]]::new()
try {
    $idleServer = Start-CESTestServer -Path $ServerPath -OutputPath $idleOutput -ErrorPath $idleError -Arguments @(
        '/p', 'tcp', '/s', [string] $idlePort, '/t', '1', '/w', '6', '/threads', '2', '/cq', '1024',
        '/memory', '67108864', '/stats')
    $ready = Wait-CESTcpReadyPeer -Port $idlePort -Process $idleServer -TimeoutMilliseconds 5000 -ProbeBytes 64
    $idlePeer = $ready.Peer
    $idlePeers.Add($idlePeer)
    $busyPeer = New-CESTcpPeer -Port $idlePort -TimeoutMilliseconds 5000
    $idlePeers.Add($busyPeer)

    $chunk = [CESTcpPeer]::Pattern(512, 77)
    $roundTrips = 0
    $idleClosed = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(2.5)
    while (-not $idleClosed -and [DateTime]::UtcNow -lt $deadline) {
        $busyPeer.Write($chunk, 0, 0)
        $busyPeer.ReadEcho(512, 5000)
        $roundTrips++
        if ($idlePeer.WaitForServerClose(200)) {
            $idleClosed = $true
        }
    }
    Assert-CESTrue $idleClosed 'the idle TCP connection was not closed by /t 1'
    Assert-CESTrue ($roundTrips -ge 3) "the busy connection completed only $roundTrips round-trips"
    $busyPeer.Write($chunk, 0, 0)
    $busyPeer.ReadEcho(512, 5000)
    $roundTrips++

    $idleExit = Wait-CESProcessExit -Process $idleServer -TimeoutMilliseconds 20000 -Context 'tcp idle-timeout server'
    Assert-CESEqual 0 $idleExit 'tcp idle-timeout server exit code'
    $idleStdout = Read-CESOutputFile $idleOutput
    $idleStderr = Read-CESOutputFile $idleError
    Assert-CESEqual '' $idleStderr.Trim() 'tcp idle-timeout server stderr'
    $final = Get-CESFinalStatistics -Text $idleStdout
    Assert-CESFinalShape -Statistics $final -Protocol 'tcp'
    Assert-CESAccepted -Ready $ready -Additional 1 -Observed (Get-CESCounter $final 'accepted') -Message 'tcp idle-timeout final accepted'
    $expectedBytes = [long] $ready.ProbeBytes + ([long] $chunk.Length * $roundTrips)
    Assert-CESEqual $expectedBytes (Get-CESCounter $final 'bytes') 'tcp idle-timeout final bytes'
    Assert-CESRate -Statistics $final
    Write-CESPass 'tcp /t 1 idle timeout with a concurrently served connection'
} finally {
    foreach ($peer in $idlePeers) { Close-CESPeer $peer }
    Stop-CESTestProcess $idleServer
    Remove-Item -LiteralPath $idleOutput, $idleError -Force -ErrorAction SilentlyContinue
}

# Scenario 4: UDP datagrams including a 65507-byte payload.
$udpPort = Get-CESFreeUdpPort
$udpOutput = New-CESTempFile
$udpError = New-CESTempFile
$udpServer = $null
$udpPeer = $null
try {
    $udpServer = Start-CESTestServer -Path $ServerPath -OutputPath $udpOutput -ErrorPath $udpError -Arguments @(
        '/p', 'udp', '/s', [string] $udpPort, '/w', '3', '/stats')
    $ready = Wait-CESUdpReadyPeer -Port $udpPort -Process $udpServer -TimeoutMilliseconds 5000 -ProbeBytes 32
    $udpPeer = $ready.Peer
    $verifiedBytes = [long] $ready.ProbeBytes
    foreach ($size in @(1, 137, 4096, 65507)) {
        $payload = [CESTcpPeer]::Pattern($size, 100 + $size)
        $udpPeer.Exchange($payload, 5000)
        $verifiedBytes += [long] $size
    }
    Assert-CESEqual 5 $udpPeer.Echoes 'udp datagrams echoed'
    Assert-CESEqual $verifiedBytes $udpPeer.EchoedBytes 'udp bytes verified by the peer'

    $udpExit = Wait-CESProcessExit -Process $udpServer -TimeoutMilliseconds 15000 -Context 'udp server'
    Assert-CESEqual 0 $udpExit 'udp server exit code'
    $udpStdout = Read-CESOutputFile $udpOutput
    $udpStderr = Read-CESOutputFile $udpError
    Assert-CESEqual '' $udpStderr.Trim() 'udp server stderr'
    $final = Get-CESFinalStatistics -Text $udpStdout
    Assert-CESFinalShape -Statistics $final -Protocol 'udp'
    $completions = Get-CESCounter $final 'completions'
    $receives = Get-CESCounter $final 'receives'
    $sends = Get-CESCounter $final 'sends'
    Assert-CESEqual $completions ($receives + $sends) 'udp completions must equal receives plus sends'
    $echoes = [long] $udpPeer.Echoes
    Assert-CESTrue ($sends -ge $echoes) "udp sends $sends is below the $echoes echoed datagrams"
    Assert-CESTrue ($sends -le ($echoes + [long] $ready.DiscardedDatagrams)) "udp sends $sends exceeds the $echoes echoed plus $($ready.DiscardedDatagrams) discarded datagrams"
    $observedBytes = Get-CESCounter $final 'bytes'
    Assert-CESTrue ($observedBytes -ge $verifiedBytes) "udp bytes $observedBytes is below the $verifiedBytes verified bytes"
    Assert-CESTrue ($observedBytes -le ($verifiedBytes + [long] $ready.DiscardedSentBytes)) "udp bytes $observedBytes exceeds the verified bytes plus $($ready.DiscardedSentBytes) bytes from discarded probe datagrams"
    Assert-CESEqual 0 (Get-CESWorkerLines -Text $udpStdout).Count 'udp statistics must not print worker lines'
    Assert-CESRate -Statistics $final
    Write-CESPass 'udp datagram echo including 65507 bytes and outstanding=0'
} finally {
    Close-CESPeer $udpPeer
    Stop-CESTestProcess $udpServer
    Remove-Item -LiteralPath $udpOutput, $udpError -Force -ErrorAction SilentlyContinue
}

# Scenario 5: /w self-termination and the /stats-only output rule.
$stopwatchPort = Get-CESFreeTcpPort
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$statsRun = Invoke-CESProcess -Path $ServerPath -TimeoutMilliseconds 15000 -Arguments @(
    '/p', 'tcp', '/s', [string] $stopwatchPort, '/w', '1', '/threads', '1', '/stats')
$stopwatch.Stop()
Assert-CESEqual 0 $statsRun.Code '/w 1 server exit code'
Assert-CESEqual '' $statsRun.ErrorText.Trim() '/w 1 server stderr'
$final = Get-CESFinalStatistics -Text $statsRun.Text
Assert-CESFinalShape -Statistics $final -Protocol 'tcp'
Assert-CESEqual 0 (Get-CESCounter $final 'accepted') 'idle /w server accepted'
Assert-CESEqual 0 (Get-CESCounter $final 'bytes') 'idle /w server bytes'
Assert-CESEqual 1 (Get-CESWorkerCounters -Text $statsRun.Text).Count 'single worker line for /threads 1'
Assert-CESTrue ($final.ElapsedMs -ge 900 -and $final.ElapsedMs -le 8000) "elapsed_ms $($final.ElapsedMs) is outside the expected /w 1 window"
Assert-CESTrue ($stopwatch.Elapsed.TotalMilliseconds -ge 900 -and $stopwatch.Elapsed.TotalMilliseconds -le 9000) "wall time $([math]::Round($stopwatch.Elapsed.TotalMilliseconds)) ms is outside the expected /w 1 window"

$quietPort = Get-CESFreeTcpPort
$quietRun = Invoke-CESProcess -Path $ServerPath -TimeoutMilliseconds 15000 -Arguments @(
    '/p', 'tcp', '/s', [string] $quietPort, '/w', '1', '/threads', '1', '/q')
Assert-CESEqual 0 $quietRun.Code '/w 1 /q server exit code'
Assert-CESEqual '' $quietRun.Text.Trim() '/w 1 /q server stdout'
Assert-CESEqual '' $quietRun.ErrorText.Trim() '/w 1 /q server stderr'

$plainPort = Get-CESFreeTcpPort
$plainRun = Invoke-CESProcess -Path $ServerPath -TimeoutMilliseconds 15000 -Arguments @(
    '/p', 'tcp', '/s', [string] $plainPort, '/w', '1', '/threads', '1')
Assert-CESEqual 0 $plainRun.Code '/w 1 server exit code without /stats'
Assert-CESEqual '' $plainRun.Text.Trim() '/w 1 server stdout without /stats'
Assert-CESEqual '' $plainRun.ErrorText.Trim() '/w 1 server stderr without /stats'
Write-CESPass '/w bounded self-termination and stdout only with /stats'

# Scenario 6: strict argument parsing matrix.
$invalidCases = @(
    @{ Name = 'port zero'; Arguments = @('/p', 'tcp', '/s', '0') },
    @{ Name = 'port above 65535'; Arguments = @('/p', 'tcp', '/s', '65536') },
    @{ Name = 'missing /p value'; Arguments = @('/p') },
    @{ Name = 'empty /p value'; Arguments = @('/p', '') },
    @{ Name = 'empty inline value'; Arguments = @('/p=') },
    @{ Name = 'inline value on a flag'; Arguments = @('/p', 'tcp', '/stats=1') },
    @{ Name = 'inline value on /q'; Arguments = @('/p', 'tcp', '/q=') },
    @{ Name = 'inline value on /h'; Arguments = @('/h=1') },
    @{ Name = 'unknown switch'; Arguments = @('/p', 'tcp', '/zz', '1') },
    @{ Name = 'unknown single dash switch'; Arguments = @('-zz') },
    @{ Name = 'unknown long switch'; Arguments = @('/p', 'tcp', '--nope', '1') },
    @{ Name = 'protocol sctp'; Arguments = @('/p', 'sctp') },
    @{ Name = 'switch as a value'; Arguments = @('/p', '/s', '7') },
    @{ Name = 'positional argument'; Arguments = @('/p', 'tcp', 'extra') },
    @{ Name = 'leading positional argument'; Arguments = @('tcp', '/p', 'tcp') },
    @{ Name = 'missing numeric value'; Arguments = @('/p', 'tcp', '/s') },
    @{ Name = 'non numeric value'; Arguments = @('/p', 'tcp', '/s', 'abc') },
    @{ Name = 'fractional value'; Arguments = @('/p', 'tcp', '/s', '12.5') },
    @{ Name = 'numeric overflow'; Arguments = @('/p', 'tcp', '/b', '99999999999999999999') },
    @{ Name = '/k with tcp'; Arguments = @('/p', 'tcp', '/k', '1') },
    @{ Name = '/k zero'; Arguments = @('/p', 'udp', '/k', '0') },
    @{ Name = '/k above 65536'; Arguments = @('/p', 'udp', '/k', '65537') },
    @{ Name = '/t with udp'; Arguments = @('/p', 'udp', '/t', '1') },
    @{ Name = '/t zero'; Arguments = @('/p', 'tcp', '/t', '0') },
    @{ Name = '/w zero'; Arguments = @('/p', 'tcp', '/w', '0') },
    @{ Name = 'negative /b'; Arguments = @('/p', 'tcp', '/b', '-1') },
    @{ Name = '/b above INT32_MAX'; Arguments = @('/p', 'tcp', '/b', '2147483648') },
    @{ Name = '/threads zero'; Arguments = @('/p', 'tcp', '/threads', '0') },
    @{ Name = '/threads above 64'; Arguments = @('/p', 'tcp', '/threads', '65') },
    @{ Name = '/rio-buffer below 512'; Arguments = @('/p', 'tcp', '/rio-buffer', '511') },
    @{ Name = '/rio-buffer above 1048576'; Arguments = @('/p', 'tcp', '/rio-buffer', '1048577') },
    @{ Name = 'udp /rio-buffer below 65507'; Arguments = @('/p', 'udp', '/rio-buffer', '65000') },
    @{ Name = '/cq below 64'; Arguments = @('/p', 'tcp', '/cq', '63') },
    @{ Name = '/cq above 1048576'; Arguments = @('/p', 'tcp', '/cq', '1048577') },
    @{ Name = '/memory below 1048576'; Arguments = @('/p', 'tcp', '/memory', '1048575') },
    @{ Name = '/h with an unknown switch'; Arguments = @('/h', '/zz') },
    @{ Name = '/h with a positional argument'; Arguments = @('/h', 'extra') },
    @{ Name = '/h with an out-of-range value'; Arguments = @('/h', '/p', 'tcp', '/s', '0') },
    @{ Name = '/h with an invalid protocol'; Arguments = @('/h', '/p', 'sctp') }
)
foreach ($case in $invalidCases) {
    $null = Assert-CESUsageError -Path $ServerPath -Arguments $case.Arguments
}

$helpRun = Invoke-CESProcess -Path $ServerPath -TimeoutMilliseconds 10000 -Arguments @('/h')
Assert-CESEqual 0 $helpRun.Code '/h exit code'
Assert-CESEqual '' $helpRun.ErrorText.Trim() '/h stderr'
Assert-CESUsageText -Text $helpRun.Text
$helpLongRun = Invoke-CESProcess -Path $ServerPath -TimeoutMilliseconds 10000 -Arguments @('/help')
Assert-CESEqual 0 $helpLongRun.Code '/help exit code'
Assert-CESUsageText -Text $helpLongRun.Text

$positiveCases = @(
    @{ Name = 'default switch spelling'; Protocol = 'tcp'; Arguments = @('/p', 'tcp', '/s', [string] (Get-CESFreeTcpPort), '/w', '1', '/threads', '1', '/stats') },
    @{ Name = 'single dash and uppercase switches'; Protocol = 'tcp'; Arguments = @('-P', 'TCP', '-S', [string] (Get-CESFreeTcpPort), '-W', '1', '-THREADS', '1', '-STATS') },
    @{ Name = 'double dash with inline values'; Protocol = 'udp'; Arguments = @('--p=udp', ('--s=' + [string] (Get-CESFreeUdpPort)), '--w=1', '--stats') },
    @{ Name = 'repeated /p with an uppercase inline value'; Protocol = 'udp'; Arguments = @('/p', 'udp', '--p=UDP', '/s', [string] (Get-CESFreeUdpPort), '/w', '1', '/stats') },
    @{ Name = '/q alongside /stats'; Protocol = 'tcp'; Arguments = @('/p', 'tcp', '/s', [string] (Get-CESFreeTcpPort), '/w', '1', '/threads', '1', '/q', '/stats') }
)
foreach ($case in $positiveCases) {
    $result = Invoke-CESProcess -Path $ServerPath -TimeoutMilliseconds 15000 -Arguments $case.Arguments
    if ($result.Code -ne 0) {
        throw "valid arguments '$($case.Name)' exited with $($result.Code): stdout=$($result.Text) stderr=$($result.ErrorText)"
    }
    Assert-CESEqual '' $result.ErrorText.Trim() "valid arguments '$($case.Name)' wrote to stderr"
    $final = Get-CESFinalStatistics -Text $result.Text
    Assert-CESFinalShape -Statistics $final -Protocol $case.Protocol
}
Write-CESPass 'strict argument matrix, usage text and switch spelling variants'

# Scenario 7: a second server on a bound port fails with exit code 2.
$conflictPort = Get-CESFreeTcpPort
$conflictOutput = New-CESTempFile
$conflictError = New-CESTempFile
$conflictServer = $null
$conflictPeers = [System.Collections.Generic.List[object]]::new()
try {
    $conflictServer = Start-CESTestServer -Path $ServerPath -OutputPath $conflictOutput -ErrorPath $conflictError -Arguments @(
        '/p', 'tcp', '/s', [string] $conflictPort, '/w', '6', '/threads', '1', '/cq', '1024',
        '/memory', '67108864', '/stats')
    $ready = Wait-CESTcpReadyPeer -Port $conflictPort -Process $conflictServer -TimeoutMilliseconds 5000 -ProbeBytes 64
    $conflictPeers.Add($ready.Peer)

    $second = Invoke-CESProcess -Path $ServerPath -TimeoutMilliseconds 15000 -Arguments @(
        '/p', 'tcp', '/s', [string] $conflictPort, '/w', '1', '/threads', '1', '/stats')
    Assert-CESEqual 2 $second.Code 'second server on a bound port exit code'
    Assert-CESTrue ($second.ErrorText.Trim().Length -gt 0) 'second server printed no failure line on stderr'
    Assert-CESTrue ($second.ErrorText -match '(?i)fail|error') "second server stderr does not describe a failure: $($second.ErrorText)"
    Assert-CESTrue ($second.Text -notmatch 'Usage:') "second server printed the usage text: $($second.Text)"

    $afterPeer = New-CESTcpPeer -Port $conflictPort -TimeoutMilliseconds 5000
    $conflictPeers.Add($afterPeer)
    $after = [CESTcpPeer]::Pattern(2048, 88)
    $afterPeer.Exchange($after, 0, 0, 5000)

    $conflictExit = Wait-CESProcessExit -Process $conflictServer -TimeoutMilliseconds 20000 -Context 'port conflict survivor server'
    Assert-CESEqual 0 $conflictExit 'port conflict survivor server exit code'
    $conflictStdout = Read-CESOutputFile $conflictOutput
    $conflictStderr = Read-CESOutputFile $conflictError
    Assert-CESEqual '' $conflictStderr.Trim() 'port conflict survivor server stderr'
    $final = Get-CESFinalStatistics -Text $conflictStdout
    Assert-CESFinalShape -Statistics $final -Protocol 'tcp'
    Assert-CESAccepted -Ready $ready -Additional 1 -Observed (Get-CESCounter $final 'accepted') -Message 'port conflict survivor accepted'
    Assert-CESEqual ([long] $ready.ProbeBytes + [long] $after.Length) (Get-CESCounter $final 'bytes') 'port conflict survivor bytes'
    Write-CESPass 'port conflict exit code 2 with the first server still echoing'
} finally {
    foreach ($peer in $conflictPeers) { Close-CESPeer $peer }
    Stop-CESTestProcess $conflictServer
    Remove-Item -LiteralPath $conflictOutput, $conflictError -Force -ErrorAction SilentlyContinue
}

# Scenario 8: Ctrl+Break delivered to the server's own console process group.
$breakPort = Get-CESFreeTcpPort
$breakOutput = New-CESTempFile
$breakError = New-CESTempFile
$breakServer = $null
$breakPeer = $null
try {
    $breakServer = Start-CESConsoleProcess -Path $ServerPath -StdoutPath $breakOutput -StderrPath $breakError -Arguments @(
        '/p', 'tcp', '/s', [string] $breakPort, '/w', '60', '/threads', '1', '/cq', '1024',
        '/memory', '67108864', '/q', '/stats')
    $ready = Wait-CESTcpReadyPeer -Port $breakPort -Process $breakServer -TimeoutMilliseconds 5000 -ProbeBytes 64
    $breakPeer = $ready.Peer

    $null = Send-CESConsoleBreak -TargetProcessId $breakServer.Id -TimeoutMilliseconds 30000
    $drained = $breakPeer.WaitForServerClose(15000)
    Assert-CESTrue $drained 'the connection open at Ctrl+Break was not drained'
    $breakExit = Wait-CESProcessExit -Process $breakServer -TimeoutMilliseconds 20000 -Context 'ctrl+break server'
    Assert-CESEqual 0 $breakExit 'ctrl+break server exit code'
    $breakStdout = Read-CESOutputFile $breakOutput
    $breakStderr = Read-CESOutputFile $breakError
    Assert-CESEqual '' $breakStderr.Trim() 'ctrl+break server stderr'
    $final = Get-CESFinalStatistics -Text $breakStdout
    Assert-CESFinalShape -Statistics $final -Protocol 'tcp'
    Assert-CESAccepted -Ready $ready -Additional 0 -Observed (Get-CESCounter $final 'accepted') -Message 'ctrl+break final accepted'
    Assert-CESEqual ([long] $ready.ProbeBytes) (Get-CESCounter $final 'bytes') 'ctrl+break final bytes'
    Assert-CESTrue ($final.ElapsedMs -lt 55000) "ctrl+break server ran $($final.ElapsedMs) ms, so /w 60 elapsed instead of a controlled stop"
    Write-CESPass 'ctrl+break controlled stop with active=0 and a drained connection'
} finally {
    Close-CESPeer $breakPeer
    Stop-CESTestProcess $breakServer
    Remove-Item -LiteralPath $breakOutput, $breakError -Force -ErrorAction SilentlyContinue
}

Write-Host "SUMMARY ces_process_tests.ps1: $script:CESPassed scenarios passed"
