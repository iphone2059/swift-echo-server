param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$sources = Get-ChildItem -LiteralPath (Join-Path $root 'Sources') -Recurse -File -Filter '*.swift'
$expectedNames = @('contract.swift','types.swift','native.swift','internal.swift','engine.swift','server.swift','main.swift')
if ($sources.Count -ne $expectedNames.Count -or
    (@($sources.Name | Sort-Object) -join ',') -cne (@($expectedNames | Sort-Object) -join ',')) {
    throw 'Sources file mapping does not match the Rust/Zig business responsibilities'
}
if (@(Get-ChildItem -LiteralPath (Join-Path $root 'Sources') -Directory).Count -ne 0) {
    throw 'Sources must contain source files directly, without target subdirectories'
}
$all = ($sources | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
if ($all.Contains([char]0)) { throw 'NUL bytes in Swift source' }
foreach ($rule in @(
    # Raw Winsock payload APIs. Member/declaration forms ('.send(', 'func send(', 'case send(')
    # are the shared Action contract and must not be confused with a non-RIO call.
    # The remaining names are unambiguous Win32 entry points.
    '(?<![.\w])(?<!case )(?<!func )\b(?:send|recv)\s*\(',
    '\b(?:sendto|recvfrom|WSASend|WSARecv|WSASendTo|WSARecvFrom)\s*\(',
    '\bWinSDK\.(?:send|recv|sendto|recvfrom|WSASend|WSARecv)\s*\(',
    '@unchecked\s+Sendable',
    'FoundationNetworking|NWConnection|URLSession',
    'cpp-echo-client|cpp-echo-server|swift-echo-client',
    'disable-dynamic-exclusivity|enforce-exclusivity=unchecked',
    'import\s+Testing\b|@Test\b'
)) { if ($all -match $rule) { throw "source policy violation: $rule" } }
if ($sources.Name -match 'Tests?\.swift$') { throw 'test source belongs under Tests, not Sources' }
foreach ($required in @('RIOReceive','RIOSend','RIOReceiveEx','RIOSendEx','AcceptEx','GetAcceptExSockaddrs','~Copyable','CESFixedArray','MutableSpan','borrow','Atomic','cesWorkerMayExit','cesUdpMayRelease','cesRequireOutstanding')) {
    if (-not $all.Contains($required)) { throw "source policy missing: $required" }
}
$manifest = Get-Content -LiteralPath (Join-Path $root 'Package.swift') -Raw
if ($manifest -match '\.package\(' -or $manifest -match 'unsafeFlags') { throw 'external package or unchecked compiler flag' }
if ($manifest -notmatch 'swift-tools-version: 6.4' -or $manifest -notmatch 'swiftLanguageModes:\s*\[.v6\]') { throw 'Swift 6.4/v6 required' }
if ($manifest -notmatch '\.target\(\s*name:\s*"CESServerCore"') { throw 'CESServerCore library target missing' }
if ($manifest -notmatch '\.executableTarget\(\s*name:\s*"swift_echo_server",\s*dependencies:\s*\[\s*"CESServerCore"\s*\]') { throw 'executable target must depend on CESServerCore' }
if ($manifest -notmatch '\.testTarget\(\s*name:\s*"swift_echo_serverTests",\s*dependencies:\s*\[\s*"CESServerCore"\s*\]') { throw 'test target must depend on CESServerCore' }
if ($manifest -notmatch '\.linkedLibrary\("Ws2_32"\)') { throw 'CESServerCore must link Ws2_32' }
if ($manifest -notmatch 'path:\s*"Tests/CESFaultDriver"') { throw 'fault driver must be a separate target under Tests' }
if ([regex]::Matches($manifest, '\.strictMemorySafety\(\)').Count -ne 2 -or
    [regex]::Matches($manifest, '\.treatWarning\("StrictMemorySafety", as: \.error\)').Count -ne 2) {
    throw 'core and production executable require strict memory safety as errors'
}
# Exactly two reviewed safe owners abstract unsafe storage; no other source file
# may carry a safe exemption.
$ownershipFiles = @($sources | Where-Object { $_.Name -eq 'native.swift' })
if ($ownershipFiles.Count -ne 1) { throw 'native.swift must exist exactly once under Sources' }
foreach ($source in $sources) {
    $text = Get-Content -LiteralPath $source.FullName -Raw
    if ($source.Name -eq 'native.swift') {
        if ([regex]::Matches($text, '@safe\b').Count -ne 2 -or
            [regex]::Matches($text, '@safe\s+package struct CESVirtualArenaOwner').Count -ne 1 -or
            [regex]::Matches($text, '@safe\s+package struct CESFixedArray<Element>').Count -ne 1) {
            throw 'Unreviewed safe declaration'
        }
    } elseif ($text -match '@safe') {
        throw "Unreviewed @safe: $($source.Name)"
    }
}
Write-Host 'PASS standalone RIO/ownership source policy'
