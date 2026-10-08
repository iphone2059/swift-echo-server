Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared black-box support for the swift-echo-server acceptance tests.
# Peers are plain .NET sockets; no other project binary is required.

if (-not ('CESTcpPeer' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;

public sealed class CESTcpPeer : IDisposable
{
    readonly TcpClient client;
    readonly NetworkStream stream;
    readonly List<byte> expected = new List<byte>();
    long sentBytes;
    long echoedBytes;
    int writes;
    int reads;
    int serverClosed;
    int aborted;
    Exception writerFailure;

    public long SentBytes { get { return Interlocked.Read(ref sentBytes); } }
    public long EchoedBytes { get { return echoedBytes; } }
    public int Writes { get { return Volatile.Read(ref writes); } }
    public int Reads { get { return reads; } }
    public bool ServerClosed { get { return Volatile.Read(ref serverClosed) != 0; } }
    public long PendingBytes { get { return expected.Count - echoedBytes; } }

    public CESTcpPeer(int port, int timeoutMilliseconds)
    {
        if (timeoutMilliseconds <= 0) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
        client = new TcpClient();
        client.NoDelay = true;
        IAsyncResult pending = client.BeginConnect(IPAddress.Loopback, port, null, null);
        if (!pending.AsyncWaitHandle.WaitOne(timeoutMilliseconds))
        {
            client.Close();
            throw new TimeoutException("tcp connect to port " + port + " timed out");
        }
        client.EndConnect(pending);
        client.ReceiveTimeout = timeoutMilliseconds;
        client.SendTimeout = timeoutMilliseconds;
        stream = client.GetStream();
    }

    public static byte[] Pattern(int length, int seed)
    {
        if (length < 0) throw new ArgumentOutOfRangeException("length");
        byte[] payload = new byte[length];
        uint state = unchecked((uint) seed * 2654435761u + 12345u);
        for (int index = 0; index < length; index++)
        {
            state = unchecked(state * 1664525u + 1013904223u);
            payload[index] = (byte) (state >> 24);
        }
        return payload;
    }

    public void Write(byte[] payload, int fragmentSize, int fragmentDelayMilliseconds)
    {
        if (payload == null) throw new ArgumentNullException("payload");
        expected.AddRange(payload);
        WriteFragments(payload, fragmentSize, fragmentDelayMilliseconds);
        if (writerFailure != null)
        {
            Exception failure = writerFailure;
            writerFailure = null;
            throw new IOException("tcp write failed: " + failure.Message, failure);
        }
    }

    public void Exchange(byte[] payload, int fragmentSize, int fragmentDelayMilliseconds, int timeoutMilliseconds)
    {
        if (payload == null) throw new ArgumentNullException("payload");
        expected.AddRange(payload);
        aborted = 0;
        writerFailure = null;
        Thread writer = new Thread(delegate() { WriteFragments(payload, fragmentSize, fragmentDelayMilliseconds); });
        writer.IsBackground = true;
        writer.Start();
        ReadEcho(payload.Length, timeoutMilliseconds);
        if (!writer.Join(timeoutMilliseconds))
        {
            throw new TimeoutException("tcp writer did not finish within " + timeoutMilliseconds + " ms");
        }
        if (writerFailure != null)
        {
            Exception failure = writerFailure;
            writerFailure = null;
            throw new IOException("tcp write failed: " + failure.Message, failure);
        }
    }

    void WriteFragments(byte[] payload, int fragmentSize, int fragmentDelayMilliseconds)
    {
        try
        {
            int offset = 0;
            while (offset < payload.Length)
            {
                int chunk = fragmentSize > 0 ? Math.Min(fragmentSize, payload.Length - offset) : payload.Length - offset;
                stream.Write(payload, offset, chunk);
                Interlocked.Add(ref sentBytes, chunk);
                Interlocked.Increment(ref writes);
                offset += chunk;
                if (fragmentDelayMilliseconds > 0 && offset < payload.Length)
                {
                    Thread.Sleep(fragmentDelayMilliseconds);
                }
            }
        }
        catch (Exception error)
        {
            if (Volatile.Read(ref aborted) == 0)
            {
                writerFailure = error;
            }
        }
    }

    public void ReadEcho(int count, int timeoutMilliseconds)
    {
        if (count < 0) throw new ArgumentOutOfRangeException("count");
        if (timeoutMilliseconds <= 0) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
        byte[] buffer = new byte[65536];
        int remaining = count;
        client.ReceiveTimeout = timeoutMilliseconds;
        while (remaining > 0)
        {
            int wanted = Math.Min(buffer.Length, remaining);
            int received;
            try
            {
                received = stream.Read(buffer, 0, wanted);
            }
            catch (IOException error)
            {
                throw new IOException("tcp read failed after " + (count - remaining) + " of " + count + " bytes: " + Describe(error), error);
            }
            if (received == 0)
            {
                throw new IOException("tcp server closed after " + (count - remaining) + " of " + count + " expected bytes");
            }
            long position = echoedBytes;
            for (int index = 0; index < received; index++)
            {
                long absolute = position + index;
                if (absolute >= expected.Count)
                {
                    throw new IOException("tcp peer received echo byte " + absolute + " but had only sent " + expected.Count + " bytes");
                }
                byte wantedByte = expected[(int) absolute];
                if (wantedByte != buffer[index])
                {
                    throw new IOException("tcp echo mismatch at byte " + absolute + ": sent " + wantedByte + ", received " + buffer[index]);
                }
            }
            echoedBytes += received;
            reads++;
            remaining -= received;
        }
    }

    public bool WaitForServerClose(int timeoutMilliseconds)
    {
        byte[] buffer = new byte[4096];
        long deadline = Environment.TickCount64 + Math.Max(1, timeoutMilliseconds);
        while (true)
        {
            client.ReceiveTimeout = 200;
            int received;
            try
            {
                received = stream.Read(buffer, 0, buffer.Length);
            }
            catch (IOException error)
            {
                SocketException socket = error.InnerException as SocketException;
                if (socket != null && socket.SocketErrorCode == SocketError.TimedOut)
                {
                    if (Environment.TickCount64 >= deadline)
                    {
                        return false;
                    }
                    continue;
                }
                if (socket != null && (socket.SocketErrorCode == SocketError.ConnectionReset ||
                                       socket.SocketErrorCode == SocketError.ConnectionAborted))
                {
                    Volatile.Write(ref serverClosed, 1);
                    return true;
                }
                throw new IOException("tcp drain failed: " + Describe(error), error);
            }
            if (received == 0)
            {
                Volatile.Write(ref serverClosed, 1);
                return true;
            }
            throw new IOException("tcp server sent " + received + " unexpected bytes while the peer was draining");
        }
    }

    public void AbortMidStream(byte[] payload, int fragmentSize, int bytesToRead, int timeoutMilliseconds)
    {
        if (payload == null) throw new ArgumentNullException("payload");
        expected.AddRange(payload);
        aborted = 0;
        writerFailure = null;
        Thread writer = new Thread(delegate() { WriteFragments(payload, fragmentSize, 0); });
        writer.IsBackground = true;
        writer.Start();
        if (bytesToRead > 0)
        {
            ReadEcho(bytesToRead, timeoutMilliseconds);
        }
        Abort();
        writer.Join(2000);
    }

    public void Abort()
    {
        Volatile.Write(ref aborted, 1);
        try
        {
            client.Client.LingerState = new LingerOption(true, 0);
        }
        catch (Exception)
        {
        }
        try
        {
            client.Close();
        }
        catch (Exception)
        {
        }
    }

    public void Dispose()
    {
        Volatile.Write(ref aborted, 1);
        try
        {
            stream.Dispose();
        }
        catch (Exception)
        {
        }
        try
        {
            client.Dispose();
        }
        catch (Exception)
        {
        }
    }

    static string Describe(IOException error)
    {
        SocketException socket = error.InnerException as SocketException;
        if (socket != null)
        {
            return socket.SocketErrorCode.ToString();
        }
        return error.Message;
    }
}

public sealed class CESUdpPeer : IDisposable
{
    readonly UdpClient socket;
    IPEndPoint remote = new IPEndPoint(IPAddress.Any, 0);
    long sentBytes;
    long echoedBytes;
    int datagrams;
    int echoes;

    public CESUdpPeer()
    {
        socket = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
    }

    public long SentBytes { get { return sentBytes; } }
    public long EchoedBytes { get { return echoedBytes; } }
    public int Datagrams { get { return datagrams; } }
    public int Echoes { get { return echoes; } }

    public void Connect(int port)
    {
        socket.Connect(IPAddress.Loopback, port);
    }

    public bool TryEcho(byte[] payload, int timeoutMilliseconds)
    {
        if (payload == null) throw new ArgumentNullException("payload");
        socket.Client.ReceiveTimeout = timeoutMilliseconds;
        try
        {
            socket.Send(payload, payload.Length);
        }
        catch (SocketException error)
        {
            if (error.SocketErrorCode == SocketError.TimedOut || error.SocketErrorCode == SocketError.ConnectionReset)
            {
                return false;
            }
            throw new IOException("udp send failed: " + error.SocketErrorCode, error);
        }
        sentBytes += payload.Length;
        datagrams++;
        byte[] echoed;
        try
        {
            echoed = socket.Receive(ref remote);
        }
        catch (SocketException error)
        {
            if (error.SocketErrorCode == SocketError.TimedOut || error.SocketErrorCode == SocketError.ConnectionReset)
            {
                return false;
            }
            throw new IOException("udp receive failed: " + error.SocketErrorCode, error);
        }
        if (echoed.Length != payload.Length)
        {
            throw new IOException("udp echo length " + echoed.Length + " does not match the sent length " + payload.Length);
        }
        for (int index = 0; index < echoed.Length; index++)
        {
            if (echoed[index] != payload[index])
            {
                throw new IOException("udp echo mismatch at byte " + index);
            }
        }
        echoedBytes += echoed.Length;
        echoes++;
        return true;
    }

    public void Exchange(byte[] payload, int timeoutMilliseconds)
    {
        if (!TryEcho(payload, timeoutMilliseconds))
        {
            throw new IOException("udp echo of " + payload.Length + " bytes timed out after " + timeoutMilliseconds + " ms");
        }
    }

    public void Dispose()
    {
        try
        {
            socket.Dispose();
        }
        catch (Exception)
        {
        }
    }
}
'@
}

if (-not ('CESConsoleLauncher' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class CESConsoleLauncher
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public bool bInheritHandle;
    }

    const uint GENERIC_READ_WRITE = 0xC0000000u;
    const uint GENERIC_WRITE = 0x40000000u;
    const uint FILE_SHARE_READ_WRITE = 3u;
    const uint FILE_SHARE_READ = 1u;
    const uint CREATE_ALWAYS = 2u;
    const uint OPEN_EXISTING = 3u;
    const uint FILE_ATTRIBUTE_NORMAL = 0x80u;
    const uint CREATE_NEW_CONSOLE = 0x00000010u;
    const uint CREATE_NEW_PROCESS_GROUP = 0x00000200u;
    const int STARTF_USESHOWWINDOW = 0x1;
    const int STARTF_USESTDHANDLES = 0x100;
    const short SW_HIDE = 0;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, ref SECURITY_ATTRIBUTES attributes,
                                     uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string application, StringBuilder commandLine, IntPtr processAttributes,
                                      IntPtr threadAttributes, bool inheritHandles, uint creationFlags,
                                      IntPtr environment, string currentDirectory, ref STARTUPINFO startupInfo,
                                      out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    static readonly System.Collections.Generic.Dictionary<int, IntPtr> ProcessHandles =
        new System.Collections.Generic.Dictionary<int, IntPtr>();

    public static bool TryGetExitCode(int processId, out int exitCode)
    {
        exitCode = -1;
        IntPtr handle;
        lock (ProcessHandles)
        {
            if (!ProcessHandles.TryGetValue(processId, out handle))
            {
                return false;
            }
        }
        uint code;
        if (!GetExitCodeProcess(handle, out code) || code == 259u)
        {
            return false;
        }
        exitCode = unchecked((int) code);
        ReleaseProcess(processId);
        return true;
    }

    public static void ReleaseProcess(int processId)
    {
        IntPtr handle;
        lock (ProcessHandles)
        {
            if (!ProcessHandles.TryGetValue(processId, out handle))
            {
                return;
            }
            ProcessHandles.Remove(processId);
        }
        CloseHandle(handle);
    }

    public static int StartInHiddenConsole(string executable, string[] arguments, string stdoutPath, string stderrPath)
    {
        SECURITY_ATTRIBUTES attributes = new SECURITY_ATTRIBUTES();
        attributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
        attributes.bInheritHandle = true;
        IntPtr input = CreateFileW("NUL", GENERIC_READ_WRITE, FILE_SHARE_READ_WRITE, ref attributes, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (input == new IntPtr(-1))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFileW(NUL) failed");
        }
        IntPtr output = CreateFileW(stdoutPath, GENERIC_WRITE, FILE_SHARE_READ, ref attributes, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        int outputError = Marshal.GetLastWin32Error();
        if (output == new IntPtr(-1))
        {
            CloseHandle(input);
            throw new Win32Exception(outputError, "CreateFileW(stdout) failed");
        }
        IntPtr error = CreateFileW(stderrPath, GENERIC_WRITE, FILE_SHARE_READ, ref attributes, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        int errorCode = Marshal.GetLastWin32Error();
        if (error == new IntPtr(-1))
        {
            CloseHandle(input);
            CloseHandle(output);
            throw new Win32Exception(errorCode, "CreateFileW(stderr) failed");
        }
        try
        {
            STARTUPINFO startup = new STARTUPINFO();
            startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            startup.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
            startup.wShowWindow = SW_HIDE;
            startup.hStdInput = input;
            startup.hStdOutput = output;
            startup.hStdError = error;
            StringBuilder commandLine = new StringBuilder(Quote(executable));
            if (arguments != null)
            {
                for (int index = 0; index < arguments.Length; index++)
                {
                    commandLine.Append(' ').Append(Quote(arguments[index]));
                }
            }
            PROCESS_INFORMATION information;
            bool started = CreateProcessW(executable, commandLine, IntPtr.Zero, IntPtr.Zero, true,
                                          CREATE_NEW_CONSOLE | CREATE_NEW_PROCESS_GROUP, IntPtr.Zero, null,
                                          ref startup, out information);
            if (!started)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessW failed");
            }
            CloseHandle(information.hThread);
            // The handle is kept so the exit code stays readable: Process.GetProcessById objects
            // created outside this process do not expose ExitCode reliably.
            lock (ProcessHandles)
            {
                ProcessHandles[information.dwProcessId] = information.hProcess;
            }
            return information.dwProcessId;
        }
        finally
        {
            CloseHandle(input);
            CloseHandle(output);
            CloseHandle(error);
        }
    }

    static string Quote(string argument)
    {
        if (argument == null)
        {
            return "\"\"";
        }
        if (argument.Length != 0 && argument.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
        {
            return argument;
        }
        StringBuilder builder = new StringBuilder("\"");
        int backslashes = 0;
        for (int index = 0; index < argument.Length; index++)
        {
            char character = argument[index];
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                builder.Append('\\', backslashes * 2 + 1).Append('"');
                backslashes = 0;
                continue;
            }
            builder.Append('\\', backslashes).Append(character);
            backslashes = 0;
        }
        builder.Append('\\', backslashes * 2).Append('"');
        return builder.ToString();
    }
}
'@
}

$script:CESConsoleMemberDefinition = 'public delegate bool CESHandlerRoutine(uint controlType); [DllImport("kernel32.dll", EntryPoint = "SetConsoleCtrlHandler", SetLastError = true)] static extern bool SetConsoleCtrlHandlerNative(CESHandlerRoutine handler, bool add); [DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole(); [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint processId); [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint controlEvent, uint processGroupId); [DllImport("kernel32.dll")] public static extern uint GetLastError(); static readonly CESHandlerRoutine IgnoreHandler = new CESHandlerRoutine(CESIgnore); static bool CESIgnore(uint controlType) { return true; } public static bool InstallIgnoreHandler() { return SetConsoleCtrlHandlerNative(IgnoreHandler, true); }'

function Get-CESFreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ([System.Net.IPEndPoint] $listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Get-CESFreeUdpPort {
    $socket = [System.Net.Sockets.UdpClient]::new(0, [System.Net.Sockets.AddressFamily]::InterNetwork)
    try {
        return ([System.Net.IPEndPoint] $socket.Client.LocalEndPoint).Port
    } finally {
        $socket.Dispose()
    }
}

function New-CESTempFile {
    return [System.IO.Path]::GetTempFileName()
}

function Read-CESOutputFile {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [string]::Empty
    }
    # Get-Content -Raw emits nothing for an empty file, so never cast its pipeline directly.
    $text = Get-Content -LiteralPath $Path -Raw
    if ($null -eq $text) {
        return [string]::Empty
    }
    return [string] $text
}

function Start-CESTestServer {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [string] $ErrorPath
    )
    return Start-Process -FilePath $Path -ArgumentList $Arguments -RedirectStandardOutput $OutputPath `
        -RedirectStandardError $ErrorPath -PassThru -NoNewWindow
}

function Stop-CESTestProcess {
    param($Process)
    if ($null -eq $Process) {
        return
    }
    try {
        if (-not $Process.HasExited) {
            $Process.Kill($true)
            [void] $Process.WaitForExit(5000)
        }
    } catch {
        # A process that already disappeared needs no cleanup.
    } finally {
        try {
            [CESConsoleLauncher]::ReleaseProcess($Process.Id)
        } catch {
        }
        try {
            $Process.Dispose()
        } catch {
        }
    }
}

function Close-CESPeer {
    param($Peer)
    if ($null -eq $Peer) {
        return
    }
    try {
        $Peer.Dispose()
    } catch {
    }
}

function Assert-CESEqual {
    param(
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] [string] $Message
    )
    if ($Expected -ne $Actual) {
        throw "$Message (expected $Expected, actual $Actual)"
    }
}

function Assert-CESTrue {
    param(
        [Parameter(Mandatory)] $Condition,
        [Parameter(Mandatory)] [string] $Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Wait-CESProcessExit {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [int] $TimeoutMilliseconds = 15000,
        [string] $Context = 'server'
    )
    if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
        throw "$Context did not exit within $TimeoutMilliseconds ms"
    }
    $code = $Process.ExitCode
    if ($null -eq $code) {
        $queried = -1
        if (-not [CESConsoleLauncher]::TryGetExitCode($Process.Id, [ref] $queried)) {
            throw "cannot read the exit code of $Context (pid $($Process.Id))"
        }
        return $queried
    }
    return $code
}

function New-CESTcpPeer {
    param(
        [Parameter(Mandatory)] [int] $Port,
        [int] $TimeoutMilliseconds = 5000
    )
    try {
        return [CESTcpPeer]::new($Port, $TimeoutMilliseconds)
    } catch {
        throw "cannot open a TCP connection to port $Port ($($_.Exception.Message))"
    }
}

function New-CESUdpPeer {
    param([Parameter(Mandatory)] [int] $Port)
    $peer = [CESUdpPeer]::new()
    try {
        $peer.Connect($Port)
    } catch {
        $peer.Dispose()
        throw "cannot open the UDP connection to port $Port ($($_.Exception.Message))"
    }
    return $peer
}

function Wait-CESTcpReadyPeer {
    param(
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [int] $TimeoutMilliseconds = 5000,
        [int] $ProbeBytes = 64
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $connects = 0
    $uncertain = 0
    $discardedSent = 0
    $attempts = 0
    $lastError = 'no attempt was made'
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Process.HasExited) {
            throw "server exited early with code $($Process.ExitCode) while waiting for TCP readiness"
        }
        $attempts++
        $peer = $null
        $connected = $false
        try {
            # The connect timeout stays long: this host drops SYNs aimed at a port that is not listening
            # yet, so a short timeout would abandon a connect that can still complete later.
            $peer = [CESTcpPeer]::new($Port, 2000)
            $connected = $true
            $payload = [CESTcpPeer]::Pattern($ProbeBytes, $attempts)
            $peer.Exchange($payload, 0, 0, 3000)
            return [pscustomobject]@{
                Peer               = $peer
                Connections        = $connects + 1
                UncertainConnects  = $uncertain
                ProbeBytes         = [long] $ProbeBytes
                Attempts           = $attempts
                DiscardedSentBytes = [long] $discardedSent
            }
        } catch {
            $lastError = $_.Exception.Message
            if ($null -ne $peer) {
                $discardedSent += [long] $peer.SentBytes
                Close-CESPeer $peer
            }
            if ($connected) {
                $connects++
            } elseif (Test-CESTimeoutError -ErrorRecord $_) {
                # The connect was abandoned while its SYN was still pending, so the server may yet accept it.
                $uncertain++
            }
        }
        Start-Sleep -Milliseconds 25
    }
    throw "server did not answer a TCP echo round-trip on port $Port within $TimeoutMilliseconds ms: $lastError"
}

function Test-CESTimeoutError {
    param([Parameter(Mandatory)] $ErrorRecord)
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [System.TimeoutException]) {
            return $true
        }
        $exception = $exception.InnerException
    }
    return $false
}

function Assert-CESAccepted {
    param(
        [Parameter(Mandatory)] $Ready,
        [Parameter(Mandatory)] [long] $Additional,
        [Parameter(Mandatory)] [long] $Observed,
        [Parameter(Mandatory)] [string] $Message
    )
    $expected = [long] $Ready.Connections + $Additional
    $tolerance = [long] $Ready.UncertainConnects
    if ($Observed -lt $expected -or $Observed -gt ($expected + $tolerance)) {
        throw "$Message (expected $expected plus at most $tolerance abandoned readiness connects, actual $Observed)"
    }
}

function Wait-CESUdpReadyPeer {
    param(
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [int] $TimeoutMilliseconds = 5000,
        [int] $ProbeBytes = 32
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $discardedSent = 0
    $discardedDatagrams = 0
    $attempts = 0
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Process.HasExited) {
            throw "server exited early with code $($Process.ExitCode) while waiting for UDP readiness"
        }
        $attempts++
        $peer = New-CESUdpPeer -Port $Port
        $usable = $false
        try {
            $payload = [CESTcpPeer]::Pattern($ProbeBytes, 500 + $attempts)
            if ($peer.TryEcho($payload, 400)) {
                $usable = $true
                return [pscustomobject]@{
                    Peer               = $peer
                    ProbeBytes         = [long] $ProbeBytes
                    Attempts           = $attempts
                    UncertainConnects  = [long] 0
                    DiscardedSentBytes = [long] $discardedSent
                    DiscardedDatagrams = [long] $discardedDatagrams
                }
            }
            $discardedSent += [long] $peer.SentBytes
            $discardedDatagrams += [long] $peer.Datagrams
        } finally {
            if (-not $usable) {
                Close-CESPeer $peer
            }
        }
        Start-Sleep -Milliseconds 25
    }
    throw "server did not answer a UDP echo datagram on port $Port within $TimeoutMilliseconds ms"
}

function Get-CESFinalStatistics {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $lines = @($Text -split "\r?\n" | Where-Object { $_ -match '^\s*final protocol=' } | ForEach-Object { $_.Trim() })
    if ($lines.Count -ne 1) {
        throw "expected exactly one 'final protocol=' line but found $($lines.Count): $Text"
    }
    $line = $lines[0]
    if ($line -notmatch '^final protocol=(tcp|udp) elapsed_ms=(\d+)\s+(.*)$') {
        throw "final statistics line does not match the contract: $line"
    }
    $protocol = $Matches[1]
    $elapsed = [long] $Matches[2]
    $fields = @{ elapsed_ms = [string] $elapsed }
    foreach ($token in ($Matches[3].Trim() -split '\s+')) {
        if ($token -notmatch '^([A-Za-z_]+)=([0-9]+(?:\.[0-9]+)?)$') {
            throw "final statistics line has an unexpected field '$token': $line"
        }
        $fields[$Matches[1]] = $Matches[2]
    }
    return [pscustomobject]@{ Line = $line; Protocol = $protocol; ElapsedMs = $elapsed; Fields = $fields }
}

function Get-CESCounter {
    param(
        [Parameter(Mandatory)] $Statistics,
        [Parameter(Mandatory)] [string] $Name
    )
    if (-not $Statistics.Fields.ContainsKey($Name)) {
        throw "final statistics line is missing '$Name': $($Statistics.Line)"
    }
    return [long] $Statistics.Fields[$Name]
}

function Get-CESRate {
    param(
        [Parameter(Mandatory)] $Statistics,
        [Parameter(Mandatory)] [string] $Name
    )
    if (-not $Statistics.Fields.ContainsKey($Name)) {
        throw "final statistics line is missing '$Name': $($Statistics.Line)"
    }
    return [double] $Statistics.Fields[$Name]
}

function Get-CESWorkerLines {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    # The unary comma keeps an empty result an array so callers can read .Count under StrictMode.
    return ,@($Text -split "\r?\n" | Where-Object { $_ -match '^\s*\[worker ' } | ForEach-Object { $_.Trim() })
}

function Get-CESWorkerCounters {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $workers = @()
    foreach ($line in (Get-CESWorkerLines -Text $Text)) {
        if ($line -notmatch '^\[worker (\d+)\] accepted=(\d+) completions=(\d+) receives=(\d+) sends=(\d+) bytes=(\d+) active=(\d+)$') {
            throw "worker statistics line does not match the contract (including no trailing fields): $line"
        }
        $workers += [pscustomobject]@{
            Index       = [int] $Matches[1]
            Accepted    = [long] $Matches[2]
            Completions = [long] $Matches[3]
            Receives    = [long] $Matches[4]
            Sends       = [long] $Matches[5]
            Bytes       = [long] $Matches[6]
            Active      = [long] $Matches[7]
            Line        = $line
        }
    }
    return ,$workers
}

function Assert-CESUsageError {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Arguments,
        [int] $TimeoutMilliseconds = 10000
    )
    $result = Invoke-CESProcess -Path $Path -Arguments $Arguments -TimeoutMilliseconds $TimeoutMilliseconds
    $rendered = ($Arguments -join ' ')
    if ($result.Code -ne 1) {
        throw "invalid arguments '$rendered' exited with $($result.Code) instead of 1: stdout=$($result.Text) stderr=$($result.ErrorText)"
    }
    if ($result.ErrorText -notmatch '(?m)^Invalid arguments: ') {
        throw "invalid arguments '$rendered' did not print an 'Invalid arguments: ' stderr line: stderr=$($result.ErrorText) stdout=$($result.Text)"
    }
    if (($result.Text + $result.ErrorText) -notmatch 'Usage:') {
        throw "invalid arguments '$rendered' did not print the usage text: stdout=$($result.Text) stderr=$($result.ErrorText)"
    }
    return $result
}

function Assert-CESUsageText {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    if ($Text -notmatch 'Usage:\s+swift-echo-server(\.exe)?\s+/p\s+tcp\|udp') {
        throw "usage text does not match 'Usage: swift-echo-server /p tcp|udp': $Text"
    }
    foreach ($switch in @('/p', '/s', '/t', '/w', '/b', '/k', '/threads', '/rio-buffer', '/cq', '/memory', '/q', '/stats')) {
        if ($Text -notmatch [regex]::Escape($switch)) {
            throw "usage text does not document the $switch switch: $Text"
        }
    }
}

function Invoke-CESProcess {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Arguments,
        [int] $TimeoutMilliseconds = 10000
    )
    $psi = [Diagnostics.ProcessStartInfo]::new($Path)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $psi.ArgumentList.Add($argument)
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill($true)
            throw "process timeout after $TimeoutMilliseconds ms: $Path $($Arguments -join ' ')"
        }
        return [pscustomobject]@{
            Code             = $process.ExitCode
            Text             = $stdout.Result
            ErrorText        = $stderr.Result
            WallMilliseconds = $timer.Elapsed.TotalMilliseconds
        }
    } finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
        }
        $process.Dispose()
    }
}

function Start-CESConsoleProcess {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $StdoutPath,
        [Parameter(Mandatory)] [string] $StderrPath
    )
    $processId = [CESConsoleLauncher]::StartInHiddenConsole($Path, [string[]] $Arguments, $StdoutPath, $StderrPath)
    return [System.Diagnostics.Process]::GetProcessById($processId)
}

function Get-CESHostExecutable {
    $path = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrEmpty($path)) {
        $path = Join-Path $PSHOME 'pwsh.exe'
    }
    return $path
}

function New-CESConsoleBreakScript {
    $lines = @(
        '$ErrorActionPreference = ''Stop''',
        '$target = [uint32] $env:CES_CONSOLE_TARGET_PID',
        ('Add-Type -Name CESConsoleSignal -Namespace CESConsole -MemberDefinition ''' + $script:CESConsoleMemberDefinition + ''''),
        '[void] [CESConsole.CESConsoleSignal]::FreeConsole()',
        'if (-not [CESConsole.CESConsoleSignal]::AttachConsole($target)) { exit 11 }',
        '[void] [CESConsole.CESConsoleSignal]::InstallIgnoreHandler()',
        '# CREATE_NEW_PROCESS_GROUP is ignored next to CREATE_NEW_CONSOLE, so first try the strict',
        '# process group and fall back to the whole console, where the server is the only other process.',
        '$sent = [CESConsole.CESConsoleSignal]::GenerateConsoleCtrlEvent(1, $target)',
        '$code = [int] [CESConsole.CESConsoleSignal]::GetLastError()',
        'if (-not $sent) {',
        '    $sent = [CESConsole.CESConsoleSignal]::GenerateConsoleCtrlEvent(1, 0)',
        '    $code = [int] [CESConsole.CESConsoleSignal]::GetLastError()',
        '}',
        '[void] [CESConsole.CESConsoleSignal]::FreeConsole()',
        'if (-not $sent) { exit (100 + $code) }',
        'exit 0'
    )
    return ($lines -join "`n")
}

function Send-CESConsoleBreak {
    param(
        [Parameter(Mandatory)] [int] $TargetProcessId,
        [int] $TimeoutMilliseconds = 30000
    )
    $helperText = New-CESConsoleBreakScript
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helperText))
    $psi = [Diagnostics.ProcessStartInfo]::new((Get-CESHostExecutable))
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)) {
        $psi.ArgumentList.Add($argument)
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $previous = $env:CES_CONSOLE_TARGET_PID
    $env:CES_CONSOLE_TARGET_PID = [string] $TargetProcessId
    $helper = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $helper.StandardOutput.ReadToEndAsync()
        $stderr = $helper.StandardError.ReadToEndAsync()
        if (-not $helper.WaitForExit($TimeoutMilliseconds)) {
            $helper.Kill($true)
            throw "console break helper timed out after $TimeoutMilliseconds ms"
        }
        if ($helper.ExitCode -ne 0) {
            throw "console break helper failed with exit code $($helper.ExitCode): $($stderr.Result) $($stdout.Result)"
        }
        return [pscustomobject]@{ Code = $helper.ExitCode; Text = $stdout.Result; ErrorText = $stderr.Result }
    } finally {
        try {
            if (-not $helper.HasExited) {
                $helper.Kill($true)
            }
        } catch {
        }
        $helper.Dispose()
        if ($null -eq $previous) {
            Remove-Item Env:\CES_CONSOLE_TARGET_PID -ErrorAction SilentlyContinue
        } else {
            $env:CES_CONSOLE_TARGET_PID = $previous
        }
    }
}

function Assert-CESFinalShape {
    param(
        [Parameter(Mandatory)] $Statistics,
        [Parameter(Mandatory)] [string] $Protocol
    )
    if ($Protocol -eq 'tcp') {
        Assert-CESEqual 'tcp' $Statistics.Protocol 'final protocol'
        Assert-CESEqual 8 $Statistics.Fields.Count "tcp final line field count ($($Statistics.Line))"
        foreach ($name in @('elapsed_ms', 'accepted', 'completions', 'receives', 'sends', 'bytes', 'MiB_per_sec', 'active')) {
            Assert-CESTrue ($Statistics.Fields.ContainsKey($name)) "tcp final line is missing the $name field: $($Statistics.Line)"
        }
        Assert-CESEqual 0 (Get-CESCounter $Statistics 'active') 'tcp final active'
    } else {
        Assert-CESEqual 'udp' $Statistics.Protocol 'final protocol'
        Assert-CESEqual 7 $Statistics.Fields.Count "udp final line field count ($($Statistics.Line))"
        foreach ($name in @('elapsed_ms', 'completions', 'receives', 'sends', 'bytes', 'MiB_per_sec', 'outstanding')) {
            Assert-CESTrue ($Statistics.Fields.ContainsKey($name)) "udp final line is missing the $name field: $($Statistics.Line)"
        }
        Assert-CESEqual 0 (Get-CESCounter $Statistics 'outstanding') 'udp final outstanding'
    }
}

function Assert-CESRate {
    param([Parameter(Mandatory)] $Statistics)
    $bytes = Get-CESCounter $Statistics 'bytes'
    $rate = Get-CESRate $Statistics 'MiB_per_sec'
    $expected = [math]::Round($bytes / 1048576.0 / ([math]::Max($Statistics.ElapsedMs, 1) / 1000.0), 2)
    if ([math]::Abs($rate - $expected) -gt 0.05) {
        throw "MiB_per_sec $rate does not match bytes=$bytes and elapsed_ms=$($Statistics.ElapsedMs) (expected $expected)"
    }
}
