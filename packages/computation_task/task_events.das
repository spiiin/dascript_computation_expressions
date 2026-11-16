options gen2
module task_events public
require ./task_builder.das public
require daslib/templates
require daslib/templates_boost
require daslib/typemacro_boost

//! Broadcast events for tasks. ``task_event_source(type<T>)`` returns a source, and
//! ``task_wait_event`` returns a task that completes with the next value that ``task_event_emit``
//! broadcasts. Require it to let tasks wait for something the host reports from outside, such as
//! input or a native callback.

//! Marker field that makes a tuple a ``TaskEventSource<T>``; it carries no data.
struct TaskEventSourceTag {_ce_marker:uint8}
//! The handle that ``task_event_source(type<T>)`` returns. It owns the source: deleting it closes
//! the source, and the waits that are still pending then complete with an error.
// The state layout is repeated in task_event_source; its declared result
// type keeps the two in step.
[template_tuple(TT)]
struct template TaskEventSource {
    tag : TaskEventSourceTag
    owner : iterator<tuple<references:uint64;closed:bool;serial:uint64;slots:array<tuple<id:uint64;ready:bool;value:TT>>>?>
}
var private event_sources_created=0
var private event_sources_released=0
var private event_waits_created=0
var private event_waits_released=0
var private event_subscribed=0
var private event_unsubscribed=0

//! Returns counters over all event sources, for leak checks: the ``sources`` and ``waits`` that are
//! alive, the ``subscriptions`` that are registered, and the totals ``subscribed`` and ``unsubscribed``.
def task_event_stats() {
    return (sources=event_sources_created-event_sources_released,
        waits=event_waits_created-event_waits_released,
        subscriptions=event_subscribed-event_unsubscribed,
        subscribed=event_subscribed,unsubscribed=event_unsubscribed)
}

// Only the owner's lease closes the source; waiter leases retain its storage.
// Generator cleanup also runs when a lease is deleted before its first yield.
def private ce_event_lease(var state:auto(SS)?;close_source:bool=false) {
    return <- generator<SS?> capture(copy(state),copy(close_source)) {
        while(true) {yield state}
        return false
    } finally {ce_sequence_finalize($ {
        unsafe {
            if(close_source) {state.closed=true}
            state.references--
            if(state.references==uint64(0)) {delete state;event_sources_released++}
        }
    })}
}

def private ce_event_state(source:tuple<tag:TaskEventSourceTag;owner:iterator<auto(SS)?>>) : SS? {
    unsafe {
        var lease=addr<iterator<SS?>?>(source.owner)
        var state:SS?
        if(!next(*lease,state)) {panic("task event source: handle was moved or deleted")}
        return state
    }
}

//! Creates an event source for values of ``T``, which must be copyable: every waiting task gets its
//! own copy. The caller owns the returned handle, and deleting it closes the source.
def task_event_source(unused:type<auto(TT)>) : TaskEventSource<TT -const -&> {
    static_assert(typeinfo ce_resumable_payload(default<TT -const -&>))
    concept_assert(typeinfo can_copy(type<TT -const -&>),"task events: broadcast payload must be copyable")
    unsafe {
        var state=new tuple<references:uint64;closed:bool;serial:uint64;slots:array<tuple<id:uint64;ready:bool;value:TT -const -&>>>(references=uint64(1))
        event_sources_created++
        return <- (tag=TaskEventSourceTag(),owner <- ce_event_lease(state,true))
    }
}

//! Closes the source: later emits deliver nothing, and the waits that have not received an event
//! complete with ``err``. Returns false if the source was already closed.
def task_event_close(source:tuple<tag:TaskEventSourceTag;owner:iterator<auto(SS)?>>) : bool {
    var state=ce_event_state(source)
    if(state.closed) {return false}
    state.closed=true
    return true
}

def ce_dispose(var source:tuple<tag:TaskEventSourceTag;owner:auto>) {
    sequence_close(source.owner)
}

//! Returns the number of waits registered on the source: those that were polled at least once and
//! are not released yet.
def task_event_subscriber_count(source:tuple<tag:TaskEventSourceTag;owner:iterator<auto(SS)?>>) : int {
    let state=ce_event_state(source)
    unsafe {return length(state.slots)}
}

//! Broadcasts a copy of ``value`` to the waits that are registered at this moment and returns how
//! many took it. Each wait keeps the first event it gets, and a wait that subscribes later does not
//! see this one. No task runs inside the call: a wait picks its value up at its next poll.
//! Returns 0 on a closed source.
def task_event_emit(source:tuple<tag:TaskEventSourceTag;owner:iterator<auto(SS)?>>;value:auto(TT)) : int {
    var state=ce_event_state(source)
    unsafe {
        if(state.closed) {return 0}
        var delivered=0
        for(slot in state.slots) {
            if(!slot.ready) {
                // Native callbacks may supply a borrowed string# buffer.
                static_if(typeinfo is_string(type<TT>)) {slot.value=string(value)}
                else {slot.value=value}
                slot.ready=true;delivered++
            }
        }
        return delivered
    }
}

def private ce_event_poll(var op:auto(OO)?) {
    unsafe {
        var state=op.state
        if(op.id==uint64(0) && !state.closed) {
            if(state.serial==uint64(-1)) {panic("task events: subscription IDs exhausted")}
            state.serial++;op.id=state.serial
            var slot:typedecl(state.slots[0]) -& -const
            slot.id=op.id
            state.slots |> push(slot)
            event_subscribed++
        }
        for(slot in state.slots) {
            if(slot.id==op.id && slot.ready) {return task_ready(ok(slot.value, type<string>))}
        }
        if(state.closed) {return task_ready(err("task event source is closed",type<typedecl(state.slots[0].value) -const -&>))}
        return task_pending(type<Result<typedecl(state.slots[0].value) -const -&;string>>)
    }
}

def private ce_event_finish(var op:auto(OO)?) {
    unsafe {
        var state=op.state
        for(i in range(length(state.slots))) {
            if(state.slots[i].id==op.id) {
                state.slots |> erase(i)
                event_unsubscribed++
                break
            }
        }
        // The lease owns the reference. Never let the alias auto-delete it.
        op.state=null
        sequence_close(op.lease)
        delete op
        event_waits_released++
    }
}

//! Returns a ``Task<Result<T;string>>`` that completes with the first value emitted after its first
//! poll, which is when it subscribes. It completes with ``err`` when the source is closed before an
//! event arrives. Releasing the task unsubscribes it.
def task_wait_event(source:tuple<tag:TaskEventSourceTag;owner:iterator<auto(SS)?>>) {
    var state=ce_event_state(source)
    unsafe {
        if(state.references==uint64(-1)) {panic("task events: reference count exhausted")}
        state.references++
        var op=new tuple<state:SS?;lease:iterator<SS?>;id:uint64>(state=state,lease <- ce_event_lease(state))
        event_waits_created++
        return <- task_from_poll(@(){return ce_event_poll(op)},@(){ce_event_finish(op)})
    }
}
