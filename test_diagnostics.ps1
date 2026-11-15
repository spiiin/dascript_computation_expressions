param([string]$Daslang=$env:DASLANG_EXE)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'source_paths.ps1')
. (Join-Path $PSScriptRoot 'sdk_paths.ps1')
$Daslang = Resolve-CeDaslang $Daslang
$cases=@(
    @{File='test_and_bind_unsupported.das';Message='and_bind is unsupported for builder';Marker='and_bind';ExactErrors=1},
    @{File='test_task_and_bind_unsupported.das';Message='and_bind is unsupported for builder';Marker='and_bind';ExactErrors=1},
    @{File='test_and_bind_mixed.das';Message='and_bind is unsupported for builder';Marker='and_bind';ExactErrors=1},
    @{File='test_move_copy.das';Message="value must be moved; use 'return <- value'";Marker='return items';ExactErrors=0},
    # A source of the wrong type is one error at the bind that names both types.
    @{File='test_computation_mixed.das';Message='cannot bind a source of type variant<none;some:int>';Marker='|> bind';ExactErrors=1},
    @{File='test_writer_mixed.das';Message='cannot bind a source of type variant<err:string;ok:int>';Marker='|> bind';ExactErrors=1},
    @{File='test_list_mixed.das';Message='cannot bind a source of type variant<err:string;ok:int>';Marker='|> bind';ExactErrors=1},
    @{File='test_task_wrong_source.das';Message='a task cannot bind a source of type variant<err:string;ok:int>';Marker='|> bind';ExactErrors=1},
    # A function that [task] cannot rewrite is reported once, at its annotation.
    @{File='test_task_function_untyped.das';Message='needs the type of the task value';Marker='[task]';ExactErrors=1},
    @{File='test_task_function_finally.das';Message='a task body has no native finally';Marker='[task_result]';ExactErrors=1},
    # A mistake in the body comes first, before the errors of the code wrapped around it.
    @{File='test_user_error_direct.das';Message="can't locate variable 'missing_direct'";Marker='missing_direct';ExactErrors=0;First=$true},
    @{File='test_user_error_writer.das';Message="can't locate variable 'missing_writer'";Marker='missing_writer';ExactErrors=0;First=$true},
    @{File='test_user_error_task.das';Message="can't locate variable 'missing_task'";Marker='missing_task';ExactErrors=0;First=$true},
    @{File='test_user_error_sequence.das';Message="can't locate variable 'missing_sequence'";Marker='missing_sequence';ExactErrors=0;First=$true},
    # A task's return of the wrong type is reported at the return.
    @{File='test_task_wrong_return.das';Message='ce_await_return';Marker='return "text"';ExactErrors=0;First=$true}
)
Push-Location $PSScriptRoot
try {
    foreach($case in $cases) {
        $file=Get-CeSource $case.File
        $source=@(Get-Content -LiteralPath $file)
        $line=1+(@(0..($source.Count-1) | Where-Object {$source[$_].Contains($case.Marker)})|Select-Object -Last 1)
        $lines=@(& $Daslang $file -no-module-cache 2>&1)
        $code=$LASTEXITCODE
        $text=$lines -join "`n"
        if($code -eq 0 -or -not $text.Contains($case.Message)){throw "Missing diagnostic: $($case.File)"}
        # Check the compiler's standalone source-location line, not a filename embedded in the message.
        if($text -notmatch ('(?m)^[^\r\n]*'+[regex]::Escape($case.File)+':'+$line+':\d+\s*$')){throw "Diagnostic not anchored to user line: $($case.File):$line`n$text"}
        if($case.ExactErrors -gt 0 -and [regex]::Matches($text,'(?m)^error\[').Count -ne $case.ExactErrors){throw "Cascading diagnostics: $($case.File)"}
        if($case.First -and -not "$(@($lines | Where-Object {"$_" -match '^error\['})[0])".Contains($case.Message)){throw "Not the first diagnostic: $($case.File)`n$text"}
        if($text -match 'macro caused exception|macro integration error'){throw "Internal macro failure: $($case.File)"}
        Write-Host "Diagnostic anchored: $($case.File):$line"
    }
} finally {Pop-Location}
