param([string]$Daslang = $env:DASLANG_EXE, [switch]$Test)
. (Join-Path $PSScriptRoot 'source_paths.ps1')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sdk_paths.ps1')
$Daslang = Resolve-CeDaslang $Daslang
function Check([string]$File, [bool]$Pass, [string]$Expected) {
    $lines = & $Daslang $File -no-module-cache 2>&1
    $code = $LASTEXITCODE
    $lines | ForEach-Object { Write-Host $_ }
    if (($code -eq 0) -ne $Pass -or ($lines -join "`n") -notmatch [regex]::Escape($Expected)) {
        throw "Unexpected result for $File (exit $code)."
    }
}
Push-Location $PSScriptRoot
try {
    Check 'examples/task_toolkit_demo.das' $true 'Task toolkit demo OK'
    Check 'examples/task_runtime_channel_demo.das' $true 'Task runtime channel demo OK'
    Check 'examples/task_parallel_jobque_demo.das' $true 'Task parallel jobque demo OK'
    Check 'examples/parser_combinators_demo.das' $true 'Parser combinators demo OK'
    Check 'examples/parser_demo.das' $true 'Parser demo OK'
    Check 'examples/search_alternatives_demo.das' $true 'Search alternatives demo OK'
    Check 'examples/search_demo.das' $true 'Search demo OK'
    Check 'examples/query_full_demo.das' $true 'Query full demo OK'
    Check 'examples/query_operators_demo.das' $true 'Query operators demo OK'
    Check 'examples/query_demo.das' $true 'Query demo OK'
    Check 'examples/async_sequence_and_bind_demo.das' $true 'Async sequence and_bind demo OK'
    Check 'examples/async_sequence_zip_demo.das' $true 'Async sequence zip demo OK'
    Check 'examples/async_sequence_for_demo.das' $true 'Async sequence For demo OK'
    Check 'examples/async_sequence_yield_from_demo.das' $true 'Async sequence yield_from demo OK'
    Check 'examples/deferred_async_sequence_demo.das' $true 'Deferred async sequence demo OK'
    Check 'examples/async_sequence_move_demo.das' $true 'Async sequence move demo OK'
    Check 'examples/async_sequence_demo.das' $true 'Async sequence demo OK'
    Check 'examples/task_events_demo.das' $true 'Task event demo OK'
    Check 'examples/task_array_demo.das' $true 'Task array demo OK'
    Check 'examples/task_and_bind_demo.das' $true 'Task and_bind demo OK'
    Check 'examples/task_extended_demo.das' $true 'Task extended demo OK'
    Check 'examples/task_delay_demo.das' $true 'Task delay demo OK'
    Check 'examples/task_cancellation_demo.das' $true 'Task cancellation demo OK'
    Check 'examples/task_timeout_demo.das' $true 'Task timeout demo OK'
    Check 'examples/task_scheduler_demo.das' $true 'Task scheduler demo OK'
    Check 'examples/task_combinators_demo.das' $true 'Task composition demo OK'
    Check 'examples/task_async_demo.das' $true 'Task async demo OK'
    Check 'examples/task_async_resources_demo.das' $true 'Task async resources demo OK'
    Check 'examples/task_demo.das' $true 'Task demo OK'
    Check 'examples/task_external_demo.das' $true 'External task demo OK'
    Check 'examples/move_resources_demo.das' $true 'move-only resources demo OK'
    Check 'examples/sequence_next_move_demo.das' $true 'sequence_next_move demo OK'
    Check 'examples/deferred_move_collections_demo.das' $true 'deferred move-only collections demo OK'
    Check 'examples/move_collections_demo.das' $true 'move-only collections demo OK'
    Check 'examples/move_ce_demo.das' $true 'move-only CE demo OK'
    Check 'examples/computation_demo.das' $true 'computation demo OK'
    Check 'examples/computation_control_demo.das' $true 'control flow demo OK'
    Check 'examples/state_demo.das' $true 'state demo OK'
    Check 'examples/writer_demo.das' $true 'writer demo OK'
    Check 'examples/writer_result_demo.das' $true 'writer/result demo OK'
    Check 'examples/state_writer_result_demo.das' $true 'state/writer/result demo OK'
    Check 'examples/state_result_demo.das' $true 'state/result demo OK'
    Check 'examples/resources_demo.das' $true 'resources demo OK'
    Check 'examples/list_demo.das' $true 'list demo OK'
    Check 'examples/coroutine_scope_demo.das' $true 'coroutine scope demo OK'
    Check 'examples/coroutine_slots_demo.das' $true 'coroutine slots demo OK'
    Check 'examples/coroutine_scheduler_demo.das' $true 'coroutine scheduler demo OK'
    Check 'examples/coroutine_demo.das' $true 'coroutine demo OK'
    Check 'examples/sequence_demo.das' $true 'sequence demo OK'
    Check 'examples/sequence_resources_demo.das' $true 'sequence resources demo OK'
    Check 'examples/sequence_shared_demo.das' $true 'sequence shared capture demo OK'
    Check 'examples/reader_result_demo.das' $true 'reader/result demo OK'
    Check 'examples/reader_demo.das' $true 'reader demo OK'
    Check 'examples/validation_demo.das' $true 'validation demo OK'
    Check 'examples/and_bind_demo.das' $true 'and_bind demo OK'
    Check 'examples/bind_return_demo.das' $true 'bind_return demo OK'
    Check 'examples/effect_bind_return_demo.das' $true 'effect bind_return demo OK'
    Check 'examples/bind2_return_demo.das' $true 'bind2_return demo OK'
    Check 'examples/bind2_demo.das' $true 'bind2 demo OK'
    Check 'examples/run_demo.das' $true 'run demo OK'
    Check 'examples/deferred_demo.das' $true 'deferred demo OK'
    Check 'examples/deferred_sequence_demo.das' $true 'deferred sequence demo OK'
    Check 'examples/loop_protocol_demo.das' $true 'loop protocol demo OK'
    Check 'examples/zip_for_demo.das' $true 'zip for demo OK'
    Check 'examples/source_demo.das' $true 'source protocol demo OK'
    if ($Test) {
        & (Join-Path $PSScriptRoot 'test_task_keyboard.ps1') -Daslang $Daslang
        & (Join-Path $PSScriptRoot 'test_task_glfw_keyboard.ps1') -Daslang $Daslang
        & (Join-Path $PSScriptRoot 'test_task_tcp.ps1') -Daslang $Daslang
        & (Join-Path $PSScriptRoot 'test_task_tcp.ps1') -Daslang $Daslang -Example
        & (Join-Path $PSScriptRoot 'test_task_hv.ps1') -Daslang $Daslang
        & (Join-Path $PSScriptRoot 'test_task_hv.ps1') -Daslang $Daslang -Example
        & (Join-Path $PSScriptRoot 'test_task_hv.ps1') -Daslang $Daslang -AndBind
        & (Join-Path $PSScriptRoot 'test_task_hv.ps1') -Daslang $Daslang -AndBind -Example
        # Every file of tests/ under dastest; see run_tests.ps1.
        & (Join-Path $PSScriptRoot 'run_tests.ps1') -Daslang $Daslang -Quiet
        & (Join-Path $PSScriptRoot 'test_integration.ps1') -Daslang $Daslang
        $bindReturnExpansion = (& $Daslang 'examples/bind_return_demo.das' -no-module-cache -log 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $bindReturnExpansion -notmatch '// from generic list_builder::ce_list_map\(') {
            throw 'Expected fused List map in BindReturn compiler output.'
        }
        Write-Host 'BindReturn expansion verified: fused List map.'
        $stateExpansion = (& $Daslang 'examples/state_expansion_demo.das' -no-module-cache -log 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $stateExpansion -notmatch 'for \( .* in range\(' -or
            $stateExpansion -match 'from generic zip_runtime::ce_zip_cursor|from generic computation_effects::ce_loop_append|from generic computation_effects::ce_loop_failed') {
            throw 'Expected a native State range loop without protected cursor or generic loop folding.'
        }
        Write-Host 'State expansion verified: native range loop.'
        $listExpansion = (& $Daslang 'examples/list_fusion_demo.das' -no-module-cache -log 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $listExpansion -notmatch 'from generic list_builder::ce_collect_into\(' -or
            $listExpansion -match 'from generic list_builder::ce_bind\(|from generic list_builder::ce_list_map\(|from generic list_builder::ce_return\(') {
            throw 'Expected one List output buffer without intermediate bind/map arrays.'
        }
        Write-Host 'List expansion verified: one output buffer.'


        Write-Host 'All computation checks passed.'
    }
} finally { Pop-Location }

























