options gen2
module task_runtime public
require ./task_scheduler.das public
require daslib/typemacro_boost

//! One scheduler for tasks of different value types. ``task_runtime()`` owns and polls the tasks
//! spawned into it; ``task_spawn(runtime, task)`` returns a typed ``TaskTicket<T>`` through which the
//! caller reads the task's status and result. Require it when one loop drives tasks of several
//! types; it also brings in everything ``task_scheduler`` provides.

//! Marker field that identifies the value ``task_runtime`` returns; user code does not construct it.
struct TaskRuntimeTag {_ce_marker:uint8}
//! Marker field that identifies a ``TaskTicket``; user code does not construct it.
struct TaskTicketTag {_ce_marker:uint8}

//! Creates an empty runtime; ``config`` sets the limits of a tick, by default those of
//! ``TaskSchedulerConfig``. The caller owns it and must delete it (``var inscope``), which cancels the
//! tasks still active. Panics if a limit in ``config`` is not valid.
def task_runtime(config:TaskSchedulerConfig) =>
    <- (kind=TaskRuntimeTag(),scheduler <- task_scheduler(type<CeUnit>,config))
def task_runtime() => <- task_runtime(TaskSchedulerConfig())
//! ``TaskRuntime`` names the type that ``task_runtime()`` returns, to declare a variable, a field or a
//! parameter.
typedef TaskRuntime = typedecl(task_runtime())

//! ``TaskTicket<T>`` names what ``task_spawn(runtime, task)`` returns for a ``Task<T>``: the caller's
//! handle to a task the runtime runs. Read it with ``task_status``, ``task_value``, ``task_error`` and
//! ``task_take``, or bind ``task_await(ticket)`` in another task. It is move-only and the caller must
//! delete it. Deleting it does not cancel a task that is still running; once the task has finished,
//! the ticket is what keeps its result.
[template_tuple(T)]
struct template TaskTicket {
    tag : TaskTicketTag
    id : TaskId
    handle : tuple<tag:TaskSharedTag;owner:iterator<tuple<references:uint64;task:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:T>>;status:TaskStatus;value:T;error:string;polling:bool>>?>>
}

def private ce_task_erased(var handle:auto) {
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:CeUnit>> capture(<-handle) {
        while(true) {
            let status=task_poll(handle)
            if(status==TaskStatus.Failed) {panic(task_error(handle))}
            if(status==TaskStatus.Cancelled) {ce_task_cancelled();yield task_pending(type<CeUnit>);return false}
            if(status==TaskStatus.Succeeded) {yield task_ready(CeUnit());return false}
            yield task_pending(type<CeUnit>)
        }
        return false
    } finally {ce_sequence_finalize($ {
        task_cancel(handle)
        delete handle
    })}
    return <- task_create(events)
}
def private ce_runtime_spawn(var runtime:auto;var source:auto;timed:bool;timeout:TaskTimeout;name:string) {
    var inscope owned <- ce_task_source(source)
    var inscope handle <- task_share(owned)
    var copy <- task_shared_clone(handle)
    var inscope erased <- ce_task_erased(copy)
    var id:TaskId
    if(timed) {id=task_spawn_named(runtime.scheduler,name,erased,timeout)}
    else {id=task_spawn_named(runtime.scheduler,name,erased)}
    return <- (tag=TaskTicketTag(),id=id,handle <- handle)
}
//! Moves ``source`` into the runtime and returns a ``TaskTicket`` for it. The runtime owns and polls
//! the task, starting with a later ``task_tick``; the caller owns the ticket. Panics during a tick,
//! on a closed runtime or if the task is being polled.
def task_spawn(var runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;var source:auto) =>
    <- ce_runtime_spawn(runtime,source,false,TaskTimeout(),"")
//! ``task_spawn`` with a deadline: a tick at or after the spawn time plus ``timeout.after_ms`` cancels
//! the task, and ``task_timed_out(runtime, ticket)`` returns true. Panics if ``after_ms`` is negative.
def task_spawn(var runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;var source:auto;timeout:TaskTimeout) =>
    <- ce_runtime_spawn(runtime,source,true,timeout,"")
//! ``task_spawn`` with a diagnostic label, reported by ``task_name``, ``task_dump`` and
//! ``task_dump_text``.
def task_spawn_named(var runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;name:string;var source:auto) =>
    <- ce_runtime_spawn(runtime,source,false,TaskTimeout(),name)
def task_spawn_named(var runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;name:string;var source:auto;timeout:TaskTimeout) =>
    <- ce_runtime_spawn(runtime,source,true,timeout,name)
//! Returns the diagnostic label of the ticket's task, "" if it has none. Panics once the runtime's
//! record of the task has been released by ``task_forget`` or ``task_prune``.
def task_name(runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;ticket:tuple<tag:TaskTicketTag;id:TaskId;handle:auto>) =>
    task_name(runtime.scheduler,ticket.id)
//! Returns the earliest runtime time at which a tick can make progress on a timeout or a
//! ``task_delay_ms`` wait, the current time when a tick is due at once, or -1 when no active task
//! has a known deadline. Waits on events, channels, sockets and job queues are not visible here.
def task_next_deadline(runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>) =>
    task_next_deadline(runtime.scheduler)
//! Returns a ``TaskInfo`` for every task record the runtime holds, active and finished, in slot order.
def task_dump(runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>) => <- task_dump(runtime.scheduler)
//! Returns ``task_dump`` as text for a log: a summary line, then one line per task.
def task_dump_text(runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>) =>
    task_dump_text(runtime.scheduler)
//! Returns a ``TaskInfo`` for every active task spawned at least ``older_than_ms`` ago in runtime time.
def task_stalled(runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;older_than_ms:int64) =>
    <- task_stalled(runtime.scheduler,older_than_ms)
def task_stalled(runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;older_than_ms:int) =>
    <- task_stalled(runtime.scheduler,int64(older_than_ms))
//! Advances the runtime to time ``now_ms`` and returns the number of tasks still active: cancels the
//! tasks whose timeout is due, then polls active tasks in turn within the configured budget. Panics
//! if ``now_ms`` is negative or less than the previous tick's, or when called by a task being polled.
def task_tick(var runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;now_ms:int64) =>
    task_tick(runtime.scheduler,now_ms)
def task_tick(var runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;now_ms:int) =>
    task_tick(runtime.scheduler,now_ms)
//! Returns the current ``TaskStatus`` of the ticket's task. The ticket stays readable after the
//! runtime has released its record or has been deleted.
def task_status(ticket:tuple<tag:TaskTicketTag;id:TaskId;handle:auto>) => task_status(ticket.handle)
//! Returns the result of a succeeded task and leaves it in the ticket: a copy, or a clone when the
//! type cannot be copied. Panics if the task has not succeeded.
def task_value(ticket:tuple<tag:TaskTicketTag;id:TaskId;handle:auto>) {
    static_if(typeinfo can_copy(type<typedecl(task_value(ticket.handle))>)) {return task_value(ticket.handle)}
    else {return <- task_value(ticket.handle)}
}
//! Returns the panic message of a task that ended as ``TaskStatus.Failed``, "" for any other task.
def task_error(ticket:tuple<tag:TaskTicketTag;id:TaskId;handle:auto>) => task_error(ticket.handle)
//! Cancels the ticket's task if it is still active: it is closed, which releases the resources it
//! holds, and the ticket reports ``TaskStatus.Cancelled``. Returns false if the task had already
//! finished. Panics during a tick or if the runtime's record of the task has been released.
def task_cancel(var runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;ticket:tuple<tag:TaskTicketTag;id:TaskId;handle:auto>) =>
    task_cancel(runtime.scheduler,ticket.id)
//! Returns true if the runtime cancelled the ticket's task because its ``TaskTimeout`` expired.
//! Panics if the runtime's record of the task has been released.
def task_timed_out(runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;ticket:tuple<tag:TaskTicketTag;id:TaskId;handle:auto>) =>
    task_timed_out(runtime.scheduler,ticket.id)
//! Releases the runtime's record of a finished task; the ticket and the result it holds are not
//! affected. Returns false and keeps the record if the task is still active. Panics during a tick
//! or if the record has already been released.
def task_forget(var runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;ticket:tuple<tag:TaskTicketTag;id:TaskId;handle:auto>) =>
    task_forget(runtime.scheduler,ticket.id)
//! Releases the runtime's records of all finished tasks and returns how many there were. Tickets
//! and the results they hold are not affected. Panics during a tick.
def task_prune(var runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>) =>
    task_prune(runtime.scheduler)
//! Returns the number of tasks in the runtime that have not finished.
def task_active_count(runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>) =>
    task_active_count(runtime.scheduler)
//! Returns the number of task records the runtime holds: active tasks and finished ones not yet
//! released.
def task_count(runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>) => task_count(runtime.scheduler)
//! Cancels every active task and closes the runtime: later spawns and ``task_configure`` panic and
//! ticks do nothing. Tickets stay readable. Panics during a tick.
def task_scheduler_close(var runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>) {task_scheduler_close(runtime.scheduler)}
//! Replaces the runtime's tick limits; the next tick uses them. Panics if a limit is not valid, if
//! the runtime is closed or during a tick.
def task_configure(var runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;config:TaskSchedulerConfig) {task_configure(runtime.scheduler,config)}
//! Runs when a runtime is deleted: cancels the tasks still active, whose tickets then report
//! ``TaskStatus.Cancelled``. Tickets of finished tasks keep their results.
def finalize(var runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>) {delete runtime.scheduler}

//! Returns a ``Task<T>`` that completes with the result of the ticket's task, to bind in another
//! computation. It only observes: polling it never runs the spawned task, and cancelling or deleting
//! it leaves that task running. It becomes Failed or Cancelled when the spawned task does. The
//! ticket is not consumed; a result that cannot be copied is cloned.
def task_await(ticket:tuple<tag:TaskTicketTag;id:TaskId;handle:auto>) {
    var handle <- task_shared_clone(ticket.handle)
    typedef Value=typedecl(task_value(handle)) -const -&
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:Value>> capture(<-handle) {
        while(true) {
            let status=task_status(handle)
            if(status==TaskStatus.Failed) {panic(task_error(handle))}
            if(status==TaskStatus.Cancelled) {ce_task_cancelled();yield <- task_pending(type<Value>);return false}
            if(status==TaskStatus.Succeeded) {
                var value <- task_value(handle)
                yield <- task_ready_move(value);return false
            }
            yield <- task_pending(type<Value>)
        }
        return false
    } finally {ce_sequence_finalize($ {delete handle})}
    return <- task_create(events)
}

//! Moves the result of a succeeded task out of the ticket without cloning; the ticket is left empty
//! and must not be read again. Panics if the task has not succeeded or while another handle shares
//! the result, such as a ``task_await`` task that has not finished.
def task_take(var ticket:tuple<tag:TaskTicketTag;id:TaskId;handle:auto>) =>
    <- task_take(ticket.handle)

//! Returns true while the runtime holds the record of the ticket's task, that is until
//! ``task_forget`` or ``task_prune`` releases it.
def task_valid(runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>;ticket:tuple<tag:TaskTicketTag;id:TaskId;handle:auto>) =>
    task_valid(runtime.scheduler,ticket.id)
//! Returns the number of record slots the runtime has allocated so far, free ones included.
def task_slot_count(runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>) =>
    task_slot_count(runtime.scheduler)
//! Returns the tick limits the runtime currently uses.
def task_scheduler_config(runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>) =>
    task_scheduler_config(runtime.scheduler)
//! Returns the runtime's time: the ``now_ms`` passed to the last ``task_tick``, 0 before the first tick.
def task_scheduler_time(runtime:tuple<kind:TaskRuntimeTag;scheduler:auto>) =>
    task_scheduler_time(runtime.scheduler)
