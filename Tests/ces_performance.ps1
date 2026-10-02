param(
    [Parameter(Mandatory)][string] $ServerPath,
    [string] $ReferenceServerPath,
    [string] $ClientPath,
    [string] $CppClientPath,
    [ValidateSet('debug','release')][string] $Configuration = 'release',
    [int] $Repetitions = 3,
    [int] $ServerSeconds = 8
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Loopback comparison matrix: {swift,cpp} server x {swift,cpp} client x {tcp,udp}.
# Both clients verify every echoed byte, so a zero exit means the payload path was exact.
if (-not (Test-Path -LiteralPath $ServerPath -PathType Leaf)) { throw "server executable not found: $ServerPath" }
function Find-CESWorkspace {
    $candidate = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    for ($level = 0; $level -lt 4; $level++) {
        foreach ($sibling in @('swift-echo-client', 'cpp-echo-client')) {
            if (Test-Path -LiteralPath (Join-Path $candidate $sibling) -PathType Container) { return $candidate }
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
    $candidate = Join-Path $cesWorkspace "swift-echo-client/.build/out/Products/$cesFlavor-windows-x86_64/swift-echo-client.exe"
    if (Test-Path -LiteralPath $candidate) { $ClientPath = $candidate }
}
if (-not $ReferenceServerPath) {
    $candidate = Join-Path $cesWorkspace "cpp-echo-server/build/$Configuration/cpp-echo-server.exe"
    if (Test-Path -LiteralPath $candidate) { $ReferenceServerPath = $candidate }
}
if (-not $CppClientPath) {
    $candidate = Join-Path $cesWorkspace "cpp-echo-client/build/$Configuration/cpp-echo-client.exe"
    if (Test-Path -LiteralPath $candidate) { $CppClientPath = $candidate }
}
if (-not ('CESPerfMemory' -as [type])) {
    # PeakWorkingSet64 on a Process object needs query rights this host does not grant;
    # K32GetProcessMemoryInfo reports the same counters through a plain handle.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CESPerfMemory {
    [StructLayout(LayoutKind.Sequential)] struct Counters {
        public uint Size, Faults;
        public UIntPtr PeakWorkingSet, WorkingSet, PeakPagedQuota, PagedQuota, PeakNonPagedQuota, NonPagedQuota, Pagefile, PeakPagefile;
    }
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool K32GetProcessMemoryInfo(IntPtr process, out Counters counters, uint size);
    public static ulong Peak(IntPtr process) {
        Counters counters;
        if (!K32GetProcessMemoryInfo(process, out counters, (uint)Marshal.SizeOf<Counters>())) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        return counters.PeakWorkingSet.ToUInt64();
    }
}
'@
}
function Get-PeakWorkingSet {
    param([System.Diagnostics.Process] $Process)
    try { return [CESPerfMemory]::Peak($Process.Handle) } catch { return 0 }
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
function Invoke-Process {
    param([string]$Path, [string[]]$Arguments, [int]$TimeoutMilliseconds = 180000)
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
        $cpu = $process.TotalProcessorTime.TotalMilliseconds
        $peak = Get-PeakWorkingSet -Process $process
        [pscustomobject]@{
            Code = $process.ExitCode; Text = $stdout.Result; ErrorText = $stderr.Result
            CpuMilliseconds = [math]::Round($cpu, 1); PeakWorkingSetBytes = $peak
        }
    } finally {
        if (-not $process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
}
function Wait-TcpReady {
    param([int]$Port)
    $deadline = [Environment]::TickCount64 + 10000
    while ([Environment]::TickCount64 -lt $deadline) {
        $client = $null
        try { $client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $Port); return $true }
        catch { Start-Sleep -Milliseconds 50 } finally { if ($client) { $client.Dispose() } }
    }
    return $false
}
function Wait-UdpEcho {
    param([int]$Port)
    $socket = [System.Net.Sockets.UdpClient]::new(0)
    try {
        $socket.Client.ReceiveTimeout = 200
        $target = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, $Port)
        $probe = [byte[]]@(0x5A)
        $deadline = [Environment]::TickCount64 + 10000
        while ([Environment]::TickCount64 -lt $deadline) {
            [void]$socket.Send($probe, $probe.Length, $target)
            try {
                $source = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                $reply = $socket.Receive([ref]$source)
                if ($reply.Length -eq 1) { return $true }
            } catch { }
        }
        return $false
    } finally { $socket.Dispose() }
}
function Get-FinalLine { param([string]$Text) return (@($Text -split "\r?\n" | Where-Object { $_ -match '^final ' }) | Select-Object -Last 1) }
function Get-Counter { param([string]$Line, [string]$Name) return [regex]::Match($Line, "$Name=(\d+)").Groups[1].Value }
$scenarios = @(
    [pscustomobject]@{
        Label = 'tcp-8sessions'
        Name = 'tcp'
        ServerArguments = @('/threads', '8', '/cq', '65536', '/memory', '2147483648')
        ClientArguments = @('127.0.0.1', '/p', 'tcp', '/r', '{port}', '/n', '400000', '/k', '8', '/z', '4096', '/c', '8', '/threads', '8', '/q', '/stats')
    },
    [pscustomobject]@{
        Label = 'udp-8sessions'
        Name = 'udp'
        ServerArguments = @('/k', '4096', '/cq', '8192', '/memory', '1073741824')
        ClientArguments = @('127.0.0.1', '/p', 'udp', '/r', '{port}', '/n', '200000', '/z', '1200', '/c', '8', '/threads', '8', '/q', '/stats')
    },
    [pscustomobject]@{
        # Many sessions per worker: 250 connections each, so the per-connection idle
        # timer heap and the accept handoff path carry most of the bookkeeping.
        Label = 'tcp-1000sessions'
        Name = 'tcp'
        ServerArguments = @('/threads', '4', '/cq', '65536', '/memory', '2147483648')
        ClientArguments = @('127.0.0.1', '/p', 'tcp', '/r', '{port}', '/n', '400000', '/k', '8', '/z', '1024', '/c', '1000', '/threads', '4', '/q', '/stats')
    }
)
$servers = [System.Collections.Generic.List[object]]::new()
$servers.Add([pscustomobject]@{ Label = 'swift-echo-server'; Path = $ServerPath })
if ($ReferenceServerPath -and (Test-Path -LiteralPath $ReferenceServerPath -PathType Leaf)) {
    $servers.Add([pscustomobject]@{ Label = 'cpp-echo-server'; Path = $ReferenceServerPath })
}
$clients = [System.Collections.Generic.List[object]]::new()
if ($ClientPath -and (Test-Path -LiteralPath $ClientPath -PathType Leaf)) {
    $clients.Add([pscustomobject]@{ Label = 'swift-echo-client'; Path = $ClientPath })
}
if ($CppClientPath -and (Test-Path -LiteralPath $CppClientPath -PathType Leaf)) {
    $clients.Add([pscustomobject]@{ Label = 'cpp-echo-client'; Path = $CppClientPath })
}
if ($clients.Count -eq 0) { throw 'no client executable was found' }
$records = [System.Collections.Generic.List[object]]::new()
foreach ($server in $servers) {
    foreach ($client in $clients) {
        foreach ($scenario in $scenarios) {
            foreach ($repetition in 1..$Repetitions) {
                $port = if ($scenario.Name -eq 'tcp') { Get-FreeTcpPort } else { Get-FreeUdpPort }
                $stamp = [Guid]::NewGuid().ToString('N')
                $serverOut = Join-Path $env:TEMP "ces_perf_$stamp.out"
                $serverErr = Join-Path $env:TEMP "ces_perf_$stamp.err"
                $arguments = @('/p', $scenario.Name, '/s', "$port", '/w', "$ServerSeconds", '/stats') + $scenario.ServerArguments
                $process = Start-Process -FilePath $server.Path -ArgumentList $arguments -PassThru -NoNewWindow -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
                try {
                    $ready = if ($scenario.Name -eq 'tcp') { Wait-TcpReady -Port $port } else { Wait-UdpEcho -Port $port }
                    if (-not $ready) { throw "$($server.Label)/$($client.Label) $($scenario.Name) server never became ready" }
                    $clientArguments = @($scenario.ClientArguments | ForEach-Object { $_ -replace '\{port\}', "$port" })
                    $clientResult = Invoke-Process -Path $client.Path -Arguments $clientArguments
                    if ($clientResult.Code -ne 0) {
                        throw "$($server.Label)/$($client.Label) $($scenario.Name) client exit $($clientResult.Code): $($clientResult.Text) $($clientResult.ErrorText)"
                    }
                    if (-not $process.WaitForExit(($ServerSeconds + 25) * 1000)) { throw 'server did not stop' }
                    $serverCpu = [math]::Round($process.TotalProcessorTime.TotalMilliseconds, 1)
                    $serverPeak = Get-PeakWorkingSet -Process $process
                    $clientFinal = Get-FinalLine -Text $clientResult.Text
                    $serverFinal = Get-FinalLine -Text (Get-Content -LiteralPath $serverOut -Raw)
                    $clientElapsed = [double](Get-Counter -Line $clientFinal -Name 'elapsed_ms')
                    $serverBytes = [double](Get-Counter -Line $serverFinal -Name 'bytes')
                    $serverMebibytesPerSecond = if ($clientElapsed -gt 0) { $serverBytes / 1048576 / ($clientElapsed / 1000) } else { 0 }
                    $serverCpuPercent = if ($clientElapsed -gt 0) { $serverCpu / $clientElapsed * 100 } else { 0 }
                    $record = [pscustomobject]@{
                        server = $server.Label
                        client = $client.Label
                        protocol = $scenario.Label
                        repetition = $repetition
                        server_exit = $process.ExitCode
                        echoed = [int64](Get-Counter -Line $clientFinal -Name 'echoed')
                        client_bytes = [int64](Get-Counter -Line $clientFinal -Name 'bytes')
                        client_elapsed_ms = [int64]$clientElapsed
                        client_echo_per_sec = [math]::Round([double]([regex]::Match($clientFinal, 'echo_per_sec=([0-9.]+)').Groups[1].Value), 2)
                        client_mib_per_sec = [math]::Round([double]([regex]::Match($clientFinal, 'MiB_per_sec=([0-9.]+)').Groups[1].Value), 2)
                        client_p50_us = [int64]([regex]::Match($clientFinal, 'p50_us~(\d+)').Groups[1].Value)
                        client_p99_us = [int64]([regex]::Match($clientFinal, 'p99_us~(\d+)').Groups[1].Value)
                        client_p999_us = [int64]([regex]::Match($clientFinal, 'p999_us~(\d+)').Groups[1].Value)
                        client_cpu_ms = $clientResult.CpuMilliseconds
                        client_peak_ws_mib = [math]::Round($clientResult.PeakWorkingSetBytes / 1MB, 2)
                        server_bytes = [int64]$serverBytes
                        server_mib_per_sec = [math]::Round($serverMebibytesPerSecond, 2)
                        server_accepted = [int64](Get-Counter -Line $serverFinal -Name 'accepted')
                        server_completions = [int64](Get-Counter -Line $serverFinal -Name 'completions')
                        server_receives = [int64](Get-Counter -Line $serverFinal -Name 'receives')
                        server_sends = [int64](Get-Counter -Line $serverFinal -Name 'sends')
                        server_cpu_ms = $serverCpu
                        server_cpu_percent_of_client_window = [math]::Round($serverCpuPercent, 1)
                        server_peak_ws_mib = [math]::Round($serverPeak / 1MB, 2)
                    }
                    $records.Add($record)
                    Write-Host ("{0,-18} {1,-18} {2,-18} run{3} echo={4} cli_MiB/s={5} srv_MiB/s={6} p50={7} p99={8} cliCPU={9}ms srvCPU={10}ms srvPeakWS={11}MiB" -f $server.Label, $client.Label, $scenario.Name, $repetition, $record.echoed, $record.client_mib_per_sec, $record.server_mib_per_sec, $record.client_p50_us, $record.client_p99_us, $record.client_cpu_ms, $record.server_cpu_ms, $record.server_peak_ws_mib)
                } finally {
                    if (-not $process.HasExited) { $process.Kill($true) }
                    $process.Dispose()
                    Remove-Item -LiteralPath $serverOut, $serverErr -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}
$groups = $records | Group-Object server, client, protocol
$summary = foreach ($group in $groups) {
    $best = $group.Group | Sort-Object client_mib_per_sec -Descending | Select-Object -First 1
    $mean = $group.Group | Measure-Object -Property client_mib_per_sec -Average
    $cpuMean = $group.Group | Measure-Object -Property server_cpu_percent_of_client_window -Average
    [pscustomobject]@{
        server = $best.server
        client = $best.client
        protocol = $best.protocol
        runs = $group.Count
        best_client_mib_per_sec = $best.client_mib_per_sec
        mean_client_mib_per_sec = [math]::Round($mean.Average, 2)
        best_server_mib_per_sec = $best.server_mib_per_sec
        best_echo_per_sec = $best.client_echo_per_sec
        p50_us = $best.client_p50_us
        p99_us = $best.client_p99_us
        p999_us = $best.client_p999_us
        server_cpu_percent_mean = [math]::Round($cpuMean.Average, 1)
        server_peak_ws_mib = $best.server_peak_ws_mib
        client_peak_ws_mib = $best.client_peak_ws_mib
    }
}
$markdown = [System.Collections.Generic.List[string]]::new()
$markdown.Add('# 逐次测量记录')
$markdown.Add('')
$markdown.Add('| 服务端 | 客户端 | 场景 | 运行 | 回显次数 | 字节 | 客户端 ms | 客户端 MiB/s | 回显/秒 | p50 µs | p99 µs | p999 µs | 服务端 bytes | 服务端 MiB/s | 客户端 CPU ms | 服务端 CPU ms | 服务端 CPU% | 客户端峰值 WS MiB | 服务端峰值 WS MiB |')
$markdown.Add('|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
foreach ($record in $records) {
    $markdown.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} | {13} | {14} | {15} | {16} | {17} | {18} |" -f $record.server, $record.client, $record.protocol, $record.repetition, $record.echoed, $record.client_bytes, $record.client_elapsed_ms, $record.client_mib_per_sec, $record.client_echo_per_sec, $record.client_p50_us, $record.client_p99_us, $record.client_p999_us, $record.server_bytes, $record.server_mib_per_sec, $record.client_cpu_ms, $record.server_cpu_ms, $record.server_cpu_percent_of_client_window, $record.client_peak_ws_mib, $record.server_peak_ws_mib))
}
$markdown.Add('')
$markdown.Add('## 汇总（按 服务端/客户端/场景 分组，取最好一次）')
$markdown.Add('')
$markdown.Add('| 服务端 | 客户端 | 协议 | 运行数 | 最好客户端 MiB/s | 平均客户端 MiB/s | 最好服务端 MiB/s | 回显/秒 | p50 µs | p99 µs | p999 µs | 服务端 CPU% 平均 | 服务端峰值 WS MiB |')
$markdown.Add('|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
foreach ($row in $summary) {
    $markdown.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} |" -f $row.server, $row.client, $row.protocol, $row.runs, $row.best_client_mib_per_sec, $row.mean_client_mib_per_sec, $row.best_server_mib_per_sec, $row.best_echo_per_sec, $row.p50_us, $row.p99_us, $row.p999_us, $row.server_cpu_percent_mean, $row.server_peak_ws_mib))
}
$outputBase = Join-Path (Split-Path -Parent $PSScriptRoot) ('docs/performance-' + (Get-Date -Format 'yyyy-MM-dd'))
$document = [pscustomobject]@{
    captured_at = (Get-Date).ToString('s')
    configuration = $Configuration
    repetitions = $Repetitions
    server_seconds = $ServerSeconds
    swift_server = $ServerPath
    reference_server = $ReferenceServerPath
    swift_client = $ClientPath
    cpp_client = $CppClientPath
    records = $records
    summary = $summary
}
$document | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ($outputBase + '.json') -Encoding utf8
$markdown | Set-Content -LiteralPath ($outputBase + '-runs.md') -Encoding utf8
Write-Host ''
$summary | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
Write-Host "PASS performance matrix: $outputBase.json and $outputBase-runs.md"
