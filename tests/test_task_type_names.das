options gen2
require ../lib/computation.das
require ../lib/task_runtime.das
require ../lib/task_channel.das
require ../lib/task_progress.das
require ../lib/task_events.das
require ../lib/task_jobque.das

// The task types have names, so a global, a field or a parameter can be
// declared without typedecl(some_call()). A name is the same structural type
// as the value a constructor returns.

var pending : $Task<int>
var inbox : $TaskChannel<string>
var loading : $TaskProgress<int>
var clicks : $TaskEventSource<int>
var workers : TaskJobQueue

struct Level {
    title : string
    load : $Task<$Result<int;string>>
}

def doubled(value : int) : $Task<int> {
    return <- computation(TaskBuilder(type<int>)) {
        return value * 2
    }
}
def finish(var task : $Task<auto(T)>) : T {
    while (task_poll(task) == TaskStatus.Waiting) {}
    return task_value(task)
}
def total(var tasks : array<$Task<int>>) : int {
    var sum = 0
    for (task in tasks) { sum += finish(task) }
    return sum
}
// A task body owns what it captures, so it reads the handle from the global.
def first_message() : $Task<$Result<string;string>> {
    return <- computation(TaskResultBuilder(type<string>)) {
        let message = task_channel_receive(inbox) |> bind
        return message ?? "closed"
    }
}
def waiting(channel : $TaskChannel<string>) : int {
    return task_channel_count(channel)
}

[export]
def main() {
    pending <- doubled(21)
    verify(finish(pending) == 42)
    delete pending

    var batch : array<$Task<int>>
    batch |> emplace(doubled(1))
    batch |> emplace(doubled(2))
    verify(total(batch) == 6)
    delete batch

    var level = Level(title="cave")
    level.load <- computation(TaskResultBuilder(type<int>)) {
        return 7
    }
    let loaded = finish(level.load)
    verify(loaded is ok && (loaded as ok) == 7)
    delete level

    inbox <- task_channel(type<string>, 2)
    verify(task_channel_try_send(inbox, "hello") && waiting(inbox) == 1)
    var inscope reader <- first_message()
    let received = finish(reader)
    verify(received is ok && (received as ok) == "hello")
    delete inbox

    loading <- task_progress(type<int>)
    task_progress_report(loading, 50)
    task_progress_close(loading)
    delete loading

    clicks <- task_event_source(type<int>)
    verify(task_event_emit(clicks, 1) == 0)
    delete clicks

    with_job_que() {
        workers <- task_job_queue()
        delete workers
    }
    print("Task type name checks OK\n")
}
