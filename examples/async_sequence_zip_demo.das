options gen2
options max_infer_passes=512
require ../packages/computation/deferred_computation.das
require ../packages/computation_task/async_sequence_builder.das
require ../packages/computation_task/task_scheduler.das

[async_sequence]
def pages(first:int) : array<int> {
    for(i in range(3)) {
        task_delay_ms(5) |> bind
        yield <- [first+i]
    }
}
[async_sequence]
def offsets() : int {
    for(i in range(2)) {
        task_delay_ms(7) |> bind
        yield 100+i
    }
}
def combined() {
    return <- deferred(AsyncSequenceBuilder(type<int>),10) $(first) {
        // The two next operations wait concurrently. Stop at the shorter input.
        for(row,offset in pages(first),offsets()) {
            task_delay_ms(2) |> bind
            yield row[0]+offset
        }
    }
}
def sum_stream(var stream:auto) {
    var inscope scheduler <- task_scheduler(type<Option<int>>)
    var now:int64=0
    var sum=0
    while(true) {
        let id=task_spawn(scheduler,async_sequence_next(stream))
        while(task_status(scheduler,id)==TaskStatus.Created || task_status(scheduler,id)==TaskStatus.Waiting) {
            task_tick(scheduler,now)
            now++
        }
        verify(task_status(scheduler,id)==TaskStatus.Succeeded)
        let item=task_take(scheduler,id)
        if(item is none) {break}
        sum+=item as some
    }
    return sum
}
[export]
def main() {
    var saved <- combined()
    var inscope first <- run_deferred(saved)
    var inscope second <- run_deferred(saved)
    delete saved
    verify(sum_stream(first)==222 && sum_stream(second)==222)
    print("Async sequence zip demo OK\n")
}
