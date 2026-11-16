options gen2
module task_progress public
require ./task_builder.das public
require daslib/templates
require daslib/templates_boost
require daslib/typemacro_boost

//! Progress reporting between tasks: a shared cell that holds the latest reported value and a
//! version counter. The producer calls ``task_progress_report``; observers read
//! ``task_progress_value`` or await ``task_progress_wait``. Require it when a long task should
//! show its state (a loading bar, a status line) and an observer may skip intermediate values.

//! Marker field of a progress handle. The handle refers to a progress cell: the latest reported
//! value wins, readers never queue history, and a wait completes with the first report newer than
//! the version it observed.
struct TaskProgressTag {_ce_marker:uint8}
//! ``TaskProgress<T>`` names the handle that ``task_progress(type<T>)`` returns, for declaring
//! variables, fields and arguments. The handle from ``task_progress`` is the owner: deleting it
//! closes the progress. Handles from ``task_progress_clone`` only keep the cell alive.
// The state layout is repeated in task_progress; its declared result type keeps
// the two in step.
[template_tuple(TT)]
struct template TaskProgress {
    tag : TaskProgressTag
    owner : iterator<tuple<references:uint64;closed:bool;version:uint64;value:TT>?>
}

def private ce_progress_lease(var state:auto(SS)?;owner:bool=false) {
    return <- generator<SS?> capture(copy(state),copy(owner)) {
        while(true) {yield state}
        return false
    } finally {ce_sequence_finalize($ {unsafe {
        if(owner) {state.closed=true}
        state.references--
        if(state.references==uint64(0)) {delete state}
    }})}
}
def private ce_progress_state(progress:tuple<tag:TaskProgressTag;owner:iterator<auto(SS)?>>) : SS? {
    unsafe {
        var lease=addr<iterator<SS?>?>(progress.owner);var state:SS?
        if(!next(*lease,state)) {panic("task progress: handle was moved or deleted")}
        return state
    }
}
//! Creates a progress cell for copyable values of type ``T`` and returns its owning handle; the
//! cell starts with no value and version 0. Deleting this handle closes the progress. The cell
//! itself lives until every clone and every unfinished wait is gone.
def task_progress(unused:type<auto(TT)>) : TaskProgress<TT -const -&> {
    static_assert(typeinfo ce_resumable_payload(default<TT -const -&>))
    concept_assert(typeinfo can_copy(type<TT>),"task progress: payload must be copyable")
    unsafe {
        var state=new tuple<references:uint64;closed:bool;version:uint64;value:TT -const -&>(references=uint64(1))
        return <- (tag=TaskProgressTag(),owner <- ce_progress_lease(state,true))
    }
}
//! Returns another handle to the same cell, for a second holder such as a task's capture. Deleting
//! a clone does not close the progress. Like every function that takes a handle, it panics if
//! ``progress`` was moved from or deleted.
def task_progress_clone(progress:tuple<tag:TaskProgressTag;owner:iterator<auto(SS)?>>) {
    var state=ce_progress_state(progress)
    unsafe {
        if(state.references==uint64(-1)) {panic("task progress: references exhausted")}
        state.references++
        return <- (tag=TaskProgressTag(),owner <- ce_progress_lease(state))
    }
}
//! Makes ``target := source`` work for progress handles: ``target`` releases the handle it held
//! and becomes a clone of ``source``, as from ``task_progress_clone``.
def clone(var target:tuple<tag:TaskProgressTag;owner:iterator<auto(SS)?>>;source:tuple<tag:TaskProgressTag;owner:iterator<SS?>>) {
    var next <- task_progress_clone(source);delete target;target <- next
}
def ce_dispose(var progress:tuple<tag:TaskProgressTag;owner:iterator<auto?>>) {sequence_close(progress.owner)}

//! Stores ``value`` as the latest report, advances the version and returns true. A report after
//! close is ignored and returns false.
def task_progress_report(progress:tuple<tag:TaskProgressTag;owner:iterator<auto(SS)?>>;value:auto) : bool {
    var state=ce_progress_state(progress)
    unsafe {
        if(state.closed) {return false}
        if(state.version==uint64(-1)) {panic("task progress: versions exhausted")}
        state.value=value
        state.version++
    }
    return true
}
//! Closes the progress: later reports are ignored, and a wait that has no newer report to deliver
//! completes with ``none``. The last reported value stays readable.
def task_progress_close(progress:tuple<tag:TaskProgressTag;owner:iterator<auto(SS)?>>) {
    var state=ce_progress_state(progress);state.closed=true
}
//! True once the progress is closed, by ``task_progress_close`` or by deleting the owning handle.
def task_progress_closed(progress:tuple<tag:TaskProgressTag;owner:iterator<auto(SS)?>>) : bool {
    var state=ce_progress_state(progress);return state.closed
}
//! Number of reports accepted so far; zero until the first report. Pass it to
//! ``task_progress_wait_after`` to wait for anything newer.
def task_progress_version(progress:tuple<tag:TaskProgressTag;owner:iterator<auto(SS)?>>) : uint64 {
    var state=ce_progress_state(progress);return state.version
}
//! The latest reported value as ``Option<T>``: ``none`` before the first report, ``some``
//! afterwards, also once the progress is closed.
def task_progress_value(progress:tuple<tag:TaskProgressTag;owner:iterator<auto(SS)?>>) {
    var state=ce_progress_state(progress)
    unsafe {
        typedef Item=typedecl(state.value) -const -&
        if(state.version==uint64(0)) {return none(type<Item>)}
        return some(state.value)
    }
}

def private ce_progress_wait_poll(var op:auto(OO)?) {unsafe {
    var state=op.state
    typedef Item=typedecl(state.value) -const -&
    if(!op.started) {
        op.started=true
        if(!op.fixed) {op.after=state.version}
    }
    if(state.version>op.after) {var result <- move_ok(some(state.value));return <- task_ready_move(result)}
    if(state.closed) {var result <- move_ok(none(type<Item>));return <- task_ready_move(result)}
    return <- task_pending(type<Result<Option<Item>;string>>)
}}
def private ce_progress_finish(var op:auto(OO)?) {unsafe {op.state=null;delete op.lease;delete op}}
def private ce_progress_wait(progress:tuple<tag:TaskProgressTag;owner:iterator<auto(SS)?>>;fixed:bool;after:uint64) {
    var lease <- task_progress_clone(progress);var state=ce_progress_state(progress)
    unsafe {
        var op=new tuple<state:SS?;lease:typedecl(lease);started:bool;fixed:bool;after:uint64>(state=state,lease <- lease,fixed=fixed,after=after)
        return <- task_from_poll(@(){return <- ce_progress_wait_poll(op)},@(){ce_progress_finish(op)})
    }
}
//! Returns a ``Task<Result<Option<T>;string>>`` that completes with ``some(latest)`` once a report
//! arrives after the task's first poll, or with ``none`` once the progress is closed. Reports in
//! between are coalesced into the latest one, and the result is never ``err``. The task keeps the
//! cell alive on its own, so it may outlive ``progress``.
def task_progress_wait(progress:tuple<tag:TaskProgressTag;owner:iterator<auto(SS)?>>) =>
    <- ce_progress_wait(progress,false,uint64(0))
//! Like ``task_progress_wait``, but completes as soon as the version is greater than ``version``,
//! even if that report came before the first poll. Waiting after the version you last saw loses
//! no update between waits.
def task_progress_wait_after(progress:tuple<tag:TaskProgressTag;owner:iterator<auto(SS)?>>;version:uint64) =>
    <- ce_progress_wait(progress,true,version)
