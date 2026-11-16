options gen2
module coroutine_scheduler public
require ./coroutine_builder.das public
require daslib/rtti

//! A scheduler for ``CoroutineBuilder`` coroutines: spawn any number of them, resume them all once
//! per ``coroutine_tick``, and query or cancel each one through its ``CoroutineTaskId``. Require it
//! when one loop drives several frame-stepped scripts; a panic in one script fails only that script.

//! State of a spawned coroutine. It is ``Running`` until its body ends (``Completed``), it is
//! cancelled or its scheduler is closed (``Cancelled``), or its body panics (``Failed``). The last
//! three are final.
enum CoroutineStatus {
    Running
    Completed
    Cancelled
    Failed
}

//! Handle to a coroutine spawned into a ``CoroutineScheduler``. It is valid only in the scheduler
//! that issued it and only until the task's record is forgotten or pruned: a reused slot gets a new
//! generation. A default-constructed id is never valid; check with ``coroutine_valid``.
struct CoroutineTaskId {owner:uint64; slot:int; generation:uint64}

// Context-local, single-threaded identity allocator. Never wrap and revive IDs.
var private coroutine_last_owner:uint64=0
def private coroutine_new_owner() : uint64 {
    if (coroutine_last_owner==uint64(-1)) {panic("coroutine scheduler: owner identities exhausted")}
    coroutine_last_owner++
    return coroutine_last_owner
}

//! A scheduler's record of one spawned coroutine: the coroutine itself, its status and the message
//! of the panic that failed it. Read it through ``coroutine_status`` and ``coroutine_error``; the
//! other fields link the scheduler's slots.
struct CoroutineTaskRecord {
    source:iterator<CoroutineFrame>
    status:CoroutineStatus
    error:string
    generation:uint64
    occupied:bool
    previous:int
    next:int
    next_free:int
}

def private coroutine_stop_record(var record:CoroutineTaskRecord) {
    if (!record.occupied || record.status!=CoroutineStatus.Running) {return}
    record.status=CoroutineStatus.Cancelled
    coroutine_cancel(record.source)
}
def private coroutine_dispose_records(var records:array<CoroutineTaskRecord>; head:int) {
    ce_sequence_finalize($ {
        var slot=head
        while (slot!=0) {
            coroutine_stop_record(records[slot-1])
            slot=records[slot-1].next
        }
        delete records
    })
}

//! Owns the coroutines spawned into it and resumes them in spawn order. A default-constructed value
//! is ready to use. Declare it ``var inscope`` or use ``coroutine_scope``: deleting the scheduler
//! cancels the coroutines that are still running. It is single-threaded, and the functions that
//! change it panic when called while it is ticking or cleaning up, that is from one of its own
//! coroutines.
struct CoroutineScheduler {
    tasks:array<CoroutineTaskRecord>
    owner:uint64
    busy:bool
    closed:bool
    free_head:int
    head:int
    tail:int
    count:int
    def finalize {
        busy=true
        closed=true
        coroutine_dispose_records(tasks,head)
    }
}

def private coroutine_check_idle(scheduler:CoroutineScheduler) {
    if (scheduler.busy) {panic("coroutine scheduler: mutation during tick or cleanup is unsupported")}
}
//! True if ``id`` was issued by this scheduler and its record has not been forgotten or pruned.
//! The other functions that take an id panic when this is false.
def coroutine_valid(scheduler:CoroutineScheduler; id:CoroutineTaskId) : bool {
    if (id.owner==uint64(0) || id.owner!=scheduler.owner || id.slot<=0 || id.slot>length(scheduler.tasks)) {return false}
    return scheduler.tasks[id.slot-1].occupied && scheduler.tasks[id.slot-1].generation==id.generation
}
def private coroutine_check_id(scheduler:CoroutineScheduler; id:CoroutineTaskId) {
    if (!coroutine_valid(scheduler,id)) {panic("coroutine scheduler: invalid or stale task id")}
}

//! Hands ``source`` to the scheduler and returns the task's id; the coroutine first runs on the next
//! ``coroutine_tick``. ``source`` is moved in every case: when the scheduler is closed or is
//! ticking, the source is closed and the call panics. The id means nothing to another scheduler.
def coroutine_spawn(var scheduler:CoroutineScheduler; var source:iterator<CoroutineFrame>) : CoroutineTaskId {
    if (scheduler.busy || scheduler.closed) {coroutine_cancel(source)}
    var inscope record <- CoroutineTaskRecord(source <- source,status=CoroutineStatus.Running,error="",
        generation=uint64(1),occupied=true)
    var slot=0
    coroutine_check_idle(scheduler)
    if (scheduler.closed) {panic("coroutine scheduler: scheduler is closed")}
    if (scheduler.owner==uint64(0)) {scheduler.owner=coroutine_new_owner()}
    if (scheduler.free_head!=0) {
        slot=scheduler.free_head
        scheduler.free_head=scheduler.tasks[slot-1].next_free
        record.generation=scheduler.tasks[slot-1].generation+uint64(1)
        scheduler.tasks[slot-1] <- record
    } else {
        scheduler.tasks |> emplace(record)
        slot=length(scheduler.tasks)
    }
    scheduler.tasks[slot-1].previous=scheduler.tail
    if (scheduler.tail!=0) {scheduler.tasks[scheduler.tail-1].next=slot}
    else {scheduler.head=slot}
    scheduler.tail=slot
    scheduler.count++
    return CoroutineTaskId(owner=scheduler.owner,slot=slot,generation=scheduler.tasks[slot-1].generation)
}
//! The task's current status. Panics if ``id`` is not valid in this scheduler.
def coroutine_status(scheduler:CoroutineScheduler; id:CoroutineTaskId) : CoroutineStatus {
    coroutine_check_id(scheduler,id)
    return scheduler.tasks[id.slot-1].status
}
//! The message of the panic that failed the task, or an empty string if it has not failed.
//! Panics if ``id`` is not valid in this scheduler.
def coroutine_error(scheduler:CoroutineScheduler; id:CoroutineTaskId) : string {
    coroutine_check_id(scheduler,id)
    return scheduler.tasks[id.slot-1].error
}
//! Cancels a running task and returns true: its coroutine is closed, which releases what its body
//! owned, and its status becomes ``CoroutineStatus.Cancelled``. Returns false if the task had
//! already ended. The record stays until ``coroutine_forget`` or ``coroutine_prune``. Panics if
//! ``id`` is not valid in this scheduler.
def coroutine_cancel(var scheduler:CoroutineScheduler; id:CoroutineTaskId) : bool {
    coroutine_check_idle(scheduler)
    coroutine_check_id(scheduler,id)
    if (scheduler.tasks[id.slot-1].status!=CoroutineStatus.Running) {return false}
    scheduler.busy=true
    coroutine_stop_record(scheduler.tasks[id.slot-1])
    scheduler.busy=false
    return true
}

//! Resumes every running task once, in spawn order, and returns how many are still running
//! afterwards; a closed scheduler returns 0. A panic in a coroutine's body is caught here, and
//! nowhere else: the task becomes ``CoroutineStatus.Failed`` with the message in
//! ``coroutine_error`` and is closed, which releases what its body still owned.
def coroutine_tick(var scheduler:CoroutineScheduler) : int {
    coroutine_check_idle(scheduler)
    if (scheduler.closed) {return 0}
    scheduler.busy=true
    var active=0
    var slot=scheduler.head
    while (slot!=0) {
        // busy forbids mutations that could reallocate tasks during resume.
        unsafe {
            var record & = scheduler.tasks[slot-1]
            if (record.status==CoroutineStatus.Running) {
                try {
                    if (coroutine_resume(record.source)) {active++}
                    else {record.status=CoroutineStatus.Completed}
                } recover {
                    record.error="{this_context().last_exception}"
                    record.status=CoroutineStatus.Failed
                }
                if (record.status==CoroutineStatus.Failed) {coroutine_cancel(record.source)}
            }
            slot=record.next
        }
    }
    scheduler.busy=false
    return active
}

//! Cancels every running task and makes the scheduler refuse new spawns. The records keep their
//! final status and stay queryable until they are forgotten or the scheduler is deleted. Closing
//! a closed scheduler does nothing.
def coroutine_close(var scheduler:CoroutineScheduler) {
    coroutine_check_idle(scheduler)
    if (scheduler.closed) {return}
    scheduler.closed=true
    scheduler.busy=true
    var slot=scheduler.head
    while (slot!=0) {
        coroutine_stop_record(scheduler.tasks[slot-1])
        slot=scheduler.tasks[slot-1].next
    }
    scheduler.busy=false
}

// Remove a terminal record from the registration-order list. Never cancel here.
def private coroutine_release_slot(var scheduler:CoroutineScheduler; slot:int) {
    // Only unlink fields; no allocations or callbacks can invalidate this reference.
    unsafe {
        var record & = scheduler.tasks[slot-1]
        if (record.previous!=0) {scheduler.tasks[record.previous-1].next=record.next}
        else {scheduler.head=record.next}
        if (record.next!=0) {scheduler.tasks[record.next-1].previous=record.previous}
        else {scheduler.tail=record.previous}
        record.occupied=false
        record.error=""
        record.previous=0
        record.next=0
        // Retire the slot rather than wrapping its generation and reviving old IDs.
        if (record.generation!=uint64(-1)) {
            record.next_free=scheduler.free_head
            scheduler.free_head=slot
        }
        scheduler.count--
    }
}
//! Removes the record of a task that has ended and returns true; ``id`` is not valid afterwards and
//! its slot may be given to a later spawn. Returns false and keeps the record if the task is still
//! running. Panics if ``id`` is not valid in this scheduler.
def coroutine_forget(var scheduler:CoroutineScheduler; id:CoroutineTaskId) : bool {
    coroutine_check_idle(scheduler)
    coroutine_check_id(scheduler,id)
    if (scheduler.tasks[id.slot-1].status==CoroutineStatus.Running) {return false}
    coroutine_release_slot(scheduler,id.slot)
    return true
}
//! Removes the records of all tasks that have ended, which invalidates their ids, and returns how
//! many were removed. Running tasks are not touched.
def coroutine_prune(var scheduler:CoroutineScheduler) : int {
    coroutine_check_idle(scheduler)
    var removed=0
    var slot=scheduler.head
    while (slot!=0) {
        let next=scheduler.tasks[slot-1].next
        if (scheduler.tasks[slot-1].status!=CoroutineStatus.Running) {
            coroutine_release_slot(scheduler,slot)
            removed++
        }
        slot=next
    }
    return removed
}
//! Number of records the scheduler holds: running tasks plus ended ones not yet forgotten or pruned.
def coroutine_task_count(scheduler:CoroutineScheduler) : int => scheduler.count
//! Number of slots allocated so far, including freed ones that wait for reuse; it shows how far the
//! scheduler's storage has grown.
def coroutine_slot_count(scheduler:CoroutineScheduler) : int => length(scheduler.tasks)

//! Runs ``body`` with a new scheduler and deletes the scheduler when the block returns, which
//! cancels the tasks that are still running.
def coroutine_scope(body:block<(var scheduler:CoroutineScheduler):void>) {
    var scheduler:CoroutineScheduler
    invoke(body,scheduler)
    delete scheduler
}


