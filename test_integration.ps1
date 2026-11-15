param([string]$Daslang=$env:DASLANG_EXE,[string]$OutputDirectory=(Join-Path $PSScriptRoot '.work'))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'sdk_paths.ps1')
$Daslang = Resolve-CeDaslang $Daslang
$destination=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ('integration-'+[guid]::NewGuid().ToString('N'))
& (Join-Path $PSScriptRoot 'export_library.ps1') -Destination $destination
# Each package arrives whole, with its descriptor and manifest, and nothing else does.
foreach($package in @('computation','computation_task')) {
    $expected=@(Get-ChildItem (Join-Path $PSScriptRoot "packages/$package") -Filter '*.das'|Select-Object -ExpandProperty Name)
    $actual=@(Get-ChildItem (Join-Path $destination "modules/$package") -Filter '*.das'|Select-Object -ExpandProperty Name)
    if(@(Compare-Object $expected $actual).Count){throw "Export has unexpected modules in $package"}
    foreach($file in @('.das_module','.das_package')){
        if(-not(Test-Path -LiteralPath (Join-Path $destination "modules/$package/$file"))){throw "Incomplete export: $package/$file"}
    }
}
# The repository's own descriptor, used when the whole repository is installed
# as one package, names the same modules as the two package descriptors.
$rootDescriptor=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '.das_module'))
foreach($package in @('computation','computation_task')) {
    $own=[regex]::Match([IO.File]::ReadAllText((Join-Path $PSScriptRoot "packages/$package/.das_module")),'(?s)_modules = \[(.*?)\]').Groups[1].Value -replace '\s',''
    $shared=[regex]::Match($rootDescriptor,"(?s)${package}_modules = \[(.*?)\]").Groups[1].Value -replace '\s',''
    if(-not $own -or $own -cne $shared){throw "Root .das_module disagrees with packages/$package/.das_module"}
}
foreach($file in @('README.md','INTEGRATION.md','PUBLIC_API.md','COMPUTATION.md','CE_SEMANTICS.md','BUILDER_PROTOCOL.md','RELIABILITY.md','aot_host/main.cpp','aot_host/CMakeLists.txt','aot_host/recover_064.h','main.das','identity_builder.das','manifest.json')){
    if(-not(Test-Path -LiteralPath (Join-Path $destination $file))){throw "Incomplete export: $file"}
}
foreach($document in Get-ChildItem -LiteralPath $destination -Filter '*.md' -File) {
    foreach($match in [regex]::Matches([IO.File]::ReadAllText($document.FullName),'\]\(([^)]+)\)')) {
        $target=$match.Groups[1].Value
        $file=($target -split '#',2)[0]
        if($file -and $target -notmatch '^[a-z]+:' -and -not(Test-Path -LiteralPath (Join-Path $destination $file))) {
            throw "Broken exported documentation link: $($document.Name) -> $target"
        }
    }
}
& $Daslang (Join-Path $destination 'main.das') -no-module-cache
if($LASTEXITCODE -ne 0){throw 'Minimal external builder failed'}
# The core package alone is a complete export: nothing in it needs the Task runtime.
$coreOnly=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ('integration-core-'+[guid]::NewGuid().ToString('N'))
& (Join-Path $PSScriptRoot 'export_library.ps1') -Destination $coreOnly -Packages computation
if(Test-Path -LiteralPath (Join-Path $coreOnly 'modules/computation_task')){throw 'Core export contains the Task package'}
& $Daslang (Join-Path $coreOnly 'main.das') -no-module-cache
if($LASTEXITCODE -ne 0){throw 'Core-only export failed'}
$smoke=@'
options gen2
require computation/computation
require computation/validation_builder
require computation/deferred_computation
require computation_task/task_builder
require computation_task/task_combinators
require computation_task/task_scheduler
require computation_task/task_events
require computation_task/async_sequence_builder
require computation/parser_builder
require computation/search_builder
require daslib/async_boost
[async]
def standard_value() : int {await_next_frame();yield 12}
[export]
def main() {
    var inscope parsedItems <- computation(ParserBuilder(text="1,2")) {
        var items & = parser_sep_by(parser_int(),parser_literal(",")) |> bind
        parser_eof() |> bind
        return <- items
    }
    assert(length((parsedItems as parsed).value)==2 && (parsedItems as parsed).value[1]==2)
    let parsed=computation(ParserBuilder(text="21")) {let n=parser_int() |> bind;parser_eof() |> bind;return n*2}
    assert(parsed is parsed && (parsed as parsed).value==42)
    var inscope alternatives <- computation(SearchBuilder()) {
        let n=search_choose([1,2]) |> search_append(search_choose([10,20])) |> search_take(3) |> bind
        yield n
    }
    var alternativeSum=0
    sequence_each(alternatives) $(n:int) {alternativeSum+=n}
    assert(alternativeSum==13)
    var inscope found <- computation(SearchBuilder()) {let n=search_choose([1,2]) |> bind;search_guard(n>1) |> bind;yield n}
    var foundSum=0
    sequence_each(found) $(n:int) {foundSum+=n}
    assert(foundSum==2)
    let check=computation(ValidationBuilder()) {
        let p=validation_ok(2) |> and_bind(validation_ok(3)) |> bind
        return p.first+p.second
    }
    assert(check as valid==5)
    var inscope owned <- computation(MoveResultBuilder()) {
        var items & = move_ok([1,2]) |> bind
        return <- items
    }
    assert(length(owned as ok)==2)
    var inscope task <- deferred(ListBuilder(),3) $(n) {
        for(i in range(n)){yield i}
    }
    var inscope first <- run_deferred(task)
    var inscope second <- run_deferred(task)
    assert(length(first)==3 && length(second)==3)
    var inscope asyncTask <- computation(TaskResultBuilder(type<int>)) {
        let n=task_after_polls(1,result_ok(8)) |> bind
        return n+1
    }
    verify(task_poll(asyncTask)==TaskStatus.Waiting)
    verify(task_poll(asyncTask)==TaskStatus.Succeeded)
    let outcome=task_value(asyncTask)
    verify(outcome is ok && outcome as ok==9)
    var inscope adapted <- computation(TaskBuilder(type<int>)) {
        let n=task_from_async(standard_value()) |> bind
        return n+1
    }
    verify(task_poll(adapted)==TaskStatus.Waiting)
    verify(task_poll(adapted)==TaskStatus.Succeeded && task_value(adapted)==13)
    var inscope together <- computation(TaskBuilder(type<int>)) {
        let pair=task_from_async(standard_value()) |> and_bind(task_after_polls(1,5)) |> bind
        return pair.first+pair.second
    }
    verify(task_poll(together)==TaskStatus.Waiting)
    verify(task_poll(together)==TaskStatus.Succeeded && task_value(together)==17)
    var inscope scheduler <- task_scheduler(type<int>)
    let id=task_spawn(scheduler,task_after_polls(0,42))
    verify(task_tick(scheduler,0)==0 && task_value(scheduler,id)==42)
    verify(task_prune(scheduler)==1)
    let expired=task_spawn(scheduler,task_after_polls(10,7),TaskTimeout(after_ms=5))
    verify(task_tick(scheduler,5)==0 && task_timed_out(scheduler,expired))
    verify(task_status(scheduler,expired)==TaskStatus.Cancelled)
    var inscope group <- cancellation_token()
    var inscope guarded <- task_with_cancellation(task_after_polls(10,4),group)
    verify(task_poll(guarded)==TaskStatus.Waiting)
    verify(cancellation_cancel(group))
    verify(task_poll(guarded)==TaskStatus.Cancelled)
    var delayTask <- computation(TaskBuilder(type<int>)) {task_delay_ms(5) |> bind;return 3}
    let delayed=task_spawn(scheduler,delayTask)
    verify(task_tick(scheduler,10)==1)
    verify(task_tick(scheduler,15)==0 && task_value(scheduler,delayed)==3)
    var inscope arrays <- task_scheduler(type<array<int>>)
    var jobs:array<typedecl(task_after_polls(0,0))>
    jobs |> emplace(task_after_polls(1,3))
    jobs |> emplace(task_after_polls(0,4))
    let batch=task_spawn(arrays,task_when_all(jobs))
    verify(task_tick(arrays,0)==1 && task_tick(arrays,1)==0)
    var inscope values <- task_value(arrays,batch)
    verify(values[0]==3 && values[1]==4)
    var inscope eventBus <- task_event_source(type<int>)
    var inscope eventWait <- task_wait_event(eventBus)
    verify(task_poll(eventWait)==TaskStatus.Waiting)
    verify(task_event_emit(eventBus,42)==1)
    verify(task_poll(eventWait)==TaskStatus.Succeeded && task_value(eventWait) as ok==42)
    verify(task_event_subscriber_count(eventBus)==0)
    var inscope stream <- computation(AsyncSequenceBuilder()) {
        let n=task_after_polls(1,42) |> bind
        yield n
    }
    var inscope item <- async_sequence_next(stream)
    verify(task_poll(item)==TaskStatus.Waiting)
    verify(task_poll(item)==TaskStatus.Succeeded && task_value(item) as some==42)
    var inscope end <- async_sequence_next(stream)
    verify(task_poll(end)==TaskStatus.Succeeded && task_value(end) is none)
    var inscope ownedStream <- computation(AsyncSequenceBuilder(type<array<int>>)) {yield <- [4,5]}
    var inscope ownedNext <- async_sequence_next(ownedStream)
    verify(task_poll(ownedNext)==TaskStatus.Succeeded)
    var inscope ownedItem <- task_take(ownedNext)
    async_sequence_close(ownedStream)
    verify((ownedItem as some)[1]==5)
    var savedAsync <- deferred(AsyncSequenceBuilder(type<array<int>>),[7,8]) $(snapshot) {yield <- snapshot}
    var inscope runA <- run_deferred(savedAsync)
    var inscope runB <- run_deferred(savedAsync)
    delete savedAsync
    var inscope nextA <- async_sequence_next(runA)
    var inscope nextB <- async_sequence_next(runB)
    verify(task_poll(nextA)==TaskStatus.Succeeded && task_poll(nextB)==TaskStatus.Succeeded)
    var inscope itemA <- task_take(nextA)
    var inscope itemB <- task_take(nextB)
    (itemA as some)[0]=77
    verify((itemB as some)[0]==7)
    print("Public module integration OK\n")
}
'@
$path=Join-Path $destination 'smoke.das'
[IO.File]::WriteAllText($path,$smoke)
& $Daslang $path -no-module-cache
if($LASTEXITCODE -ne 0){throw 'Public module smoke failed'}
Write-Host "Standalone export verified: $destination"

# Optional adapter is checked from the exported package, not the checkout.
$hvSmoke=@'
options gen2
require computation_task/task_hv
[export]
def main() {
    var inscope socket <- hv_websocket()
    var inscope job <- ws_connect(socket,"invalid-url")
    verify(task_poll(job)==TaskStatus.Succeeded && task_value(job) is err)
    print("Exported dasHV adapter OK\n")
}
'@
$hvPath=Join-Path $destination 'hv_smoke.das'
[IO.File]::WriteAllText($hvPath,$hvSmoke)
& $Daslang $hvPath -no-module-cache
if($LASTEXITCODE -ne 0){throw 'Exported dasHV adapter failed'}
