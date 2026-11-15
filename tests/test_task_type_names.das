options gen2
require ../packages/computation/computation.das
require ../packages/computation_task/task_runtime.das
require ../packages/computation_task/task_channel.das
require ../packages/computation_task/task_progress.das
require ../packages/computation_task/task_events.das
require ../packages/computation_task/task_jobque.das
require ../packages/computation_task/async_sequence_builder.das

// The task types have names, so a global, a field or a parameter can be
// declared without typedecl(some_call()). A name is the same structural type
// as the value a constructor returns.

var pending : Task<int>
var inbox : TaskChannel<string>
var loading : TaskProgress<int>
var clicks : TaskEventSource<int>
var workers : TaskJobQueue
var runtime : TaskRuntime
var scheduler : TaskScheduler<int>
var readings : AsyncSequence<int>
var handle : TaskShared<int>
var ticket : TaskTicket<int>
var squares : TaskJobStream<int;int>

struct Game {
    runtime : TaskRuntime
    jobs : TaskScheduler<int>
}

[async_sequence]
def measured(count : int) : int {
    for (i in range(count)) {
        task_after_polls(1, CeUnit()) |> bind
        yield 10 + i
    }
}
def square_worker(count : int; sink : TaskJobSink) {
    for (i in range(count)) { task_job_emit(sink, i * i) }
}
def first_reading(var source : AsyncSequence<int>) : Task<Option<int>> {
    return <- async_sequence_next(source)
}

struct Level {
    title : string
    load : Task<Result<int;string>>
}

def doubled(value : int) : Task<int> {
    return <- computation(TaskBuilder(type<int>)) {
        return value * 2
    }
}
def finish(var task : Task<auto(T)>) : T {
    while (task_poll(task) == TaskStatus.Waiting) {}
    return task_value(task)
}
def total(var tasks : array<Task<int>>) : int {
    var sum = 0
    for (task in tasks) { sum += finish(task) }
    return sum
}
// A task body owns what it captures, so it reads the handle from the global.
def first_message() : Task<Result<string;string>> {
    return <- computation(TaskResultBuilder(type<string>)) {
        let message = task_channel_receive(inbox) |> bind
        return message ?? "closed"
    }
}
def waiting(channel : TaskChannel<string>) : int {
    return task_channel_count(channel)
}

[export]
def main() {
    pending <- doubled(21)
    verify(finish(pending) == 42)
    delete pending

    var batch : array<Task<int>>
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
        squares <- task_jobque_stream(workers, type<int>, 3, @@square_worker)
        static_assert(typeinfo typename(type<TaskJobStream<int;int>>) == typeinfo typename(task_jobque_stream(workers, type<int>, 3, @@square_worker)))
        delete squares
        delete workers
    }

    runtime <- task_runtime()
    scheduler <- task_scheduler(type<int>)
    readings <- measured(2)
    static_assert(typeinfo typename(type<AsyncSequence<int>>) == typeinfo typename(measured(1)))
    var inscope next <- first_reading(readings)
    let reading = finish(next)
    verify(reading is some && (reading as some) == 10)
    var shared_source <- doubled(4)
    handle <- task_share(shared_source)
    var spawned <- doubled(5)
    ticket <- task_spawn(runtime, spawned)
    var game : Game
    game.runtime <- task_runtime()
    game.jobs <- task_scheduler(type<int>)
    delete game
    delete ticket
    delete handle
    delete readings
    delete scheduler
    delete runtime
    print("Task type name checks OK\n")
}
