Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-RioFaultProcess {
    param([string]$DriverPath, [string]$Mode, [int]$Port = 0, [int]$TimeoutMilliseconds = 15000)
    $start = [Diagnostics.ProcessStartInfo]::new($DriverPath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.ArgumentList.Add($Mode)
    if ($Port -ne 0) { $start.ArgumentList.Add([string]$Port) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) { throw "fault $Mode timeout ($TimeoutMilliseconds ms)" }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 5000)) { throw "fault $Mode output collection timeout" }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout.GetAwaiter().GetResult(); StdErr = $stderr.GetAwaiter().GetResult() }
    } finally {
        try {
            if (-not $process.HasExited) {
                $process.Kill($true)
                if (-not $process.WaitForExit(5000)) { throw "fault $Mode cleanup timeout" }
            }
        } finally { $process.Dispose() }
    }
}

function Assert-RioFaultCase {
    param([string]$DriverPath, [hashtable]$Case, [int]$Port = 0)
    $result = Invoke-RioFaultProcess -DriverPath $DriverPath -Mode $Case.Mode -Port $Port
    if ($result.ExitCode -ne $Case.Exit) { throw "fault $($Case.Mode) exit=$($result.ExitCode), expected=$($Case.Exit); stdout=$($result.StdOut); stderr=$($result.StdErr)" }
    if ($Case.ContainsKey('Stage')) {
        $signature = '(?m)^' + [regex]::Escape($Case.Stage) + ' failed: native_error=' + $Case.Error + '\r?$'
        if ($result.StdErr -notmatch $signature) { throw "fault $($Case.Mode) missing exact boundary '$($Case.Stage)' native_error=$($Case.Error); stderr=$($result.StdErr)" }
    } elseif (-not [string]::IsNullOrWhiteSpace($result.StdErr)) { throw "fault $($Case.Mode) unexpected stderr: $($result.StdErr)" }
    if ($Case.ContainsKey('Output') -and $result.StdOut -notmatch $Case.Output) { throw "fault $($Case.Mode) missing positive evidence '$($Case.Output)': $($result.StdOut)" }
    if ($Case.ContainsKey('Evidence') -and $result.StdErr -notmatch $Case.Evidence) { throw "fault $($Case.Mode) missing native observation '$($Case.Evidence)': $($result.StdErr)" }
    if ($Case.ContainsKey('JoinMarkers') -and [regex]::Matches($result.StdOut, '(?m)^join marker worker=0\r?$').Count -ne $Case.JoinMarkers) { throw "fault $($Case.Mode) failed all-thread Join evidence: $($result.StdOut)" }
    Write-Host "PASS fault $($Case.Mode) exit=$($result.ExitCode)"
    return $result
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
public sealed class RioFaultPeer : IDisposable {
    private readonly CancellationTokenSource stop = new CancellationTokenSource();
    private readonly TcpListener listener;
    private readonly Task loop;
    private TcpClient client;
    private int connected;
    private long received;
    public int Port { get; }
    public bool Connected => Volatile.Read(ref connected) != 0;
    public long ReceivedBytes => Interlocked.Read(ref received);
    private RioFaultPeer(bool listening, int port) {
        if (listening) {
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        } else { Port = port; }
        loop = Run(listening);
    }
    public static RioFaultPeer Listen() => new RioFaultPeer(true, 0);
    public static RioFaultPeer ConnectTo(int port) => new RioFaultPeer(false, port);
    public static int ReservePort() {
        var reservation = new TcpListener(IPAddress.Loopback, 0);
        reservation.Start();
        int port = ((IPEndPoint)reservation.LocalEndpoint).Port;
        reservation.Stop();
        return port;
    }
    private async Task Run(bool listening) {
        try {
            if (listening) { client = await listener.AcceptTcpClientAsync(stop.Token); }
            else {
                var deadline = DateTime.UtcNow.AddSeconds(5);
                while (client == null) {
                    stop.Token.ThrowIfCancellationRequested();
                    var candidate = new TcpClient();
                    try { await candidate.ConnectAsync(IPAddress.Loopback, Port, stop.Token); client = candidate; }
                    catch (SocketException) {
                        candidate.Dispose();
                        if (DateTime.UtcNow >= deadline) { throw; }
                        await Task.Delay(25, stop.Token);
                    } catch { candidate.Dispose(); throw; }
                }
            }
            Interlocked.Exchange(ref connected, 1);
            var bytes = new byte[8192];
            while (true) {
                int count = await client.GetStream().ReadAsync(bytes.AsMemory(), stop.Token);
                if (count == 0) { return; }
                Interlocked.Add(ref received, count);
                // Never echo or send: the real RIO receive remains pending.
            }
        } catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
          catch (ObjectDisposedException) when (stop.IsCancellationRequested) { }
          catch (IOException) when (Connected) { /* Driver exits can reset the peer. */ }
    }
    public void Dispose() {
        stop.Cancel(); listener?.Stop(); client?.Dispose();
        try {
            if (!loop.Wait(5000)) { throw new TimeoutException("fault peer cleanup timeout"); }
            loop.GetAwaiter().GetResult();
        } finally { client?.Dispose(); stop.Dispose(); }
    }
}
'@
