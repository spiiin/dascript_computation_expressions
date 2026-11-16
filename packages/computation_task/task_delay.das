options gen2
module task_delay public
require ./task_builder.das public

//! Time-based waits for tasks: ``task_delay_ms`` returns a task that completes after a number of
//! milliseconds of scheduler time. The clock is the ``now_ms`` a scheduler passes to ``task_tick``,
//! so a delay makes progress only while a scheduler polls it. ``task_scheduler`` requires this
//! module publicly; require it on its own to write another wait against the same clock.

//! The clock a scheduler publishes while it polls its tasks: ``owner`` identifies the scheduler,
//! ``now_ms`` is the time of the tick, and ``wake_ms`` collects the earliest deadline the polled
//! waits asked for (``uint64(-1)`` when none did).
struct TaskClockSample {owner:uint64;now_ms:int64;wake_ms:uint64=uint64(-1)}
// Value snapshots exist only across synchronous poll calls, never borrowed
// scheduler pointers. Nested schedulers restore the enclosing clock on return.
var private task_clock_samples:array<TaskClockSample>

// Returns the earliest wake deadline reported by waits polled in this scope,
// or uint64(-1) when none reported one.
def ce_task_clock_scope(owner:uint64; now_ms:int64; action:block<():void>) : uint64 {
    let depth=length(task_clock_samples)
    task_clock_samples |> push(TaskClockSample(owner=owner,now_ms=now_ms))
    invoke(action)
    let wake=task_clock_samples[depth].wake_ms
    task_clock_samples.resize(depth)
    return wake
}
// Time-based waits report when they next need a poll. Outside a tick it is a no-op.
def ce_task_clock_hint(deadline_ms:uint64) {
    if(empty(task_clock_samples)) {return}
    let top=length(task_clock_samples)-1
    if(deadline_ms<task_clock_samples[top].wake_ms) {task_clock_samples[top].wake_ms=deadline_ms}
}
def private task_delay_clock_owner() : uint64 {
    if(empty(task_clock_samples)) {panic("task_delay_ms: polling requires task_tick scheduler clock")}
    return task_clock_samples[length(task_clock_samples)-1].owner
}
def private task_delay_clock_now() : int64 {
    if(empty(task_clock_samples)) {panic("task_delay_ms: polling requires task_tick scheduler clock")}
    return task_clock_samples[length(task_clock_samples)-1].now_ms
}

//! Returns a cold ``Task<CeUnit>`` that succeeds once ``duration_ms`` of scheduler time has passed.
//! The interval starts on the task's first poll, when the bind is reached, rather than at
//! construction or when the containing task is registered. Panics on a negative duration. The task
//! fails when it is polled outside a scheduler tick, or by another scheduler than the one that started it.
def task_delay_ms(duration_ms:int64) {
    if(duration_ms<int64(0)) {panic("task_delay_ms: duration must be non-negative")}
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:CeUnit>> {
        let owner=task_delay_clock_owner()
        let deadline=uint64(task_delay_clock_now())+uint64(duration_ms)
        while(true) {
            if(task_delay_clock_owner()!=owner) {panic("task_delay_ms: scheduler changed while waiting")}
            if(uint64(task_delay_clock_now())>=deadline) {yield task_ready(CeUnit());return false}
            ce_task_clock_hint(deadline)
            yield task_pending(type<CeUnit>)
        }
        return false
    }
    return <- task_create(events)
}
def task_delay_ms(duration_ms:int) => <- task_delay_ms(int64(duration_ms))
