param([Parameter(Mandatory)][string]$DriverPath)
. (Join-Path $PSScriptRoot 'rio_fault_process_support.ps1')
$cases = @(
    @{ Mode='normal'; Exit=0; Output='(?m)^normal guards accepted\r?$' },
    @{ Mode='notify_failure'; Exit=4; Stage='fault notify'; Error=5 },
    @{ Mode='notify_duplicate'; Exit=4; Stage='RIONotify duplicate arm'; Error=10037 },
    @{ Mode='corrupt_cq'; Exit=4; Stage='fault CQ'; Error=13 },
    @{ Mode='outstanding_underflow'; Exit=4; Stage='fault outstanding'; Error=13 },
    @{ Mode='control_post_failure'; Exit=4; Stage='fault control post'; Error=5 },
    @{ Mode='completion_positive'; Exit=0; Output='(?m)^completion normalized\r?$' },
    @{ Mode='completion_range'; Exit=4; Stage='server RIO RequestContext range'; Error=13 },
    @{ Mode='completion_forged'; Exit=4; Stage='server RIO RequestContext range'; Error=13 },
  @{ Mode='completion_token'; Exit=4; Stage='worker completion identity'; Error=13 },
  @{ Mode='completion_generation'; Exit=4; Stage='worker completion generation'; Error=13 },
  @{ Mode='completion_socket_context'; Exit=4; Stage='worker RIO SocketContext identity'; Error=13 },
    @{ Mode='completion_identity'; Exit=4; Stage='server RIO request metadata'; Error=13 },
    @{ Mode='completion_length'; Exit=4; Stage='worker completion exceeds posted range'; Error=13 },
    @{ Mode='completion_owner'; Exit=4; Stage='worker completion without provider ownership'; Error=13 },
    @{ Mode='accept_completion_positive'; Exit=0; Output='(?m)^accept completion extent accepted\r?$' },
    @{ Mode='accept_completion_length'; Exit=4; Stage='AcceptEx completion exceeds posted range'; Error=13 },
    @{ Mode='handoff_positive'; Exit=0; Output='(?m)^accept handoff socket accepted\r?$' },
    @{ Mode='handoff_invalid_socket'; Exit=4; Stage='AcceptEx handoff invariant'; Error=10038 },
    @{ Mode='worker_release_positive'; Exit=0; Output='(?m)^worker released\r?$' },
    @{ Mode='worker_release'; Exit=4; Stage='worker RIO cleanup with outstanding operations'; Error=996 },
    @{ Mode='worker_release_order'; Exit=4; Stage='worker RIO cleanup with outstanding operations'; Error=996 },
    @{ Mode='slot_release_positive'; Exit=0; Output='(?m)^worker released\r?$' },
    @{ Mode='slot_release'; Exit=4; Stage='TCP connection release precondition'; Error=996 },
    @{ Mode='acceptor_release_positive'; Exit=0; Output='(?m)^acceptor released\r?$' },
    @{ Mode='acceptor_release_order'; Exit=4; Stage='server acceptor release precondition'; Error=996 },
    @{ Mode='arena_release_positive'; Exit=0; Output='(?m)^arena released\r?$' },
    @{ Mode='arena_release'; Exit=4; Stage='RIO arena provider ownership'; Error=996 },
    @{ Mode='arena_deinit'; Exit=4; Stage='RIO arena provider ownership'; Error=996 },
    @{ Mode='worker_cancel_positive'; Exit=0; Output='(?m)^native worker drained\r?$' },
    @{ Mode='worker_missing_completion'; Exit=4; Stage='server connection drain'; Error=1460; Evidence='(?m)^fault real cancellation completion withheld failed: native_error=995\r?$' },
    @{ Mode='partial_startup'; Exit=2; Output='(?m)^partial startup drained workers=1\r?$' }
)
foreach ($case in $cases) { $null = Assert-RioFaultCase -DriverPath $DriverPath -Case $case }
foreach ($hide in @($false, $true)) {
    $port = [RioFaultPeer]::ReservePort()
    $peer = [RioFaultPeer]::ConnectTo($port)
    try {
        $case = if ($hide) {
            @{ Mode='e2e_missing_completion'; Exit=4; Stage='server connection drain'; Error=1460; Evidence='(?m)^fault real cancellation completion withheld failed: native_error=995\r?$' }
        } else {
            @{ Mode='e2e_cancel_positive'; Exit=0; Output='(?m)^e2e cancellation drained\r?$' }
        }
        $null = Assert-RioFaultCase -DriverPath $DriverPath -Case $case -Port $port
        if (-not $peer.Connected) { throw 'Server fault peer never connected to the real acceptor' }
    } finally { $peer.Dispose() }
}
