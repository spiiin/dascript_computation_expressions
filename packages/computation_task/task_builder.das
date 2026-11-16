options gen2
module task_builder public
require ../computation/computation_builders.das public
require ../computation/sequence_runtime.das public
require ../computation/resumable_lowering.das public
require ./cancellation_token.das public
require ../computation/move_builders.das public
require ../computation/deferred_runtime.das public
require ./task_function.das public
require daslib/rtti
require daslib/templates
require daslib/templates_boost
require daslib/typemacro_boost

//! The task types and their builders. ``computation(TaskBuilder(type<T>)) { ... }`` returns a cold
//! ``Task<T>`` that the caller drives with ``task_poll``; inside the block ``source |> bind`` awaits
//! another task. ``TaskResultBuilder`` adds ``Result`` short-circuiting, ``task_share`` lets several
//! holders await one task, and ``task_from_poll`` / ``task_from_async`` adapt external operations.
//! Brings the ``[task]`` / ``[task_result]`` annotations and ``CancellationToken`` along.

//! Where a task is in its life. ``Created`` has never been polled and ``Waiting`` is suspended; the
//! other three are final: ``Succeeded`` holds a value, ``Failed`` holds the message of the panic
//! that stopped the body, and ``Cancelled`` holds neither.
enum TaskStatus {
    Created
    Waiting
    Succeeded
    Cancelled
    Failed
}
//! Marker field that makes a tuple a ``Task<T>``; it carries no data.
struct TaskTag {_ce_marker:uint8}
//! Marker field that makes a tuple a ``TaskEvent<T>``; it carries no data.
struct TaskEventTag {_ce_marker:uint8}

//! One step of a task's source: ``ready == false`` says the task is still waiting, and
//! ``ready == true`` carries the result in ``value``. Build one with ``task_pending``,
//! ``task_ready`` or ``task_ready_move``. ``TaskEvent<T>`` is a named tuple, so a value built
//! field by field has the same type.
[template_tuple(TT)]
struct template TaskEvent {
    tag : TaskEventTag
    ready : bool
    value : TT
}
//! The cold single-shot task that ``computation(TaskBuilder(type<T>))`` returns. Nothing runs until
//! ``task_poll``; each poll runs the body to its next suspension or to its result. The task owns its
//! source and its result and is moved, never copied: hand it to a bind, a combinator or a scheduler,
//! or drive it yourself and read it with ``task_status``, ``task_value``, ``task_take`` and
//! ``task_error``. ``Task<T>`` is a named tuple, so a value built field by field has the same type.
[template_tuple(TT)]
struct template Task {
    tag : TaskTag
    source : iterator<tuple<tag:TaskEventTag;ready:bool;value:TT>>
    status : TaskStatus
    value : TT
    error : string
    polling : bool
}
//! Marker of the builder that ``TaskBuilder(type<T>)`` returns.
struct TaskContext {_ce_marker:uint8}
//! Marker of the builder that ``TaskResultBuilder(type<T>)`` returns.
struct TaskResultContext {_ce_marker:uint8}
// A deferred task runs on a frame of its own. The task's source keeps the
// frame until the task is done.
def ce_deferred_keep(var task:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(TT)>>;status:TaskStatus;value:TT;error:string;polling:bool>;
                     var cleanup:lambda<():void>) {
    task.source <- ce_deferred_wrap_sequence(task.source,cleanup)
}
// What a deferred run must own in a task: its value.
def ce_deferred_payload(task:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(TT)>>;status:TaskStatus;value:TT;error:string;polling:bool>) : TT -const -&? => null

// Control is handle by nested await/resource generators, scoped to one loop.
struct CeTaskLoopControl {signal:int}
def ce_task_loop_scope() {
    var state=new CeTaskLoopControl()
    return <- generator<CeTaskLoopControl?> capture(copy(state)) {
        yield state
        return false
    } finally {ce_sequence_finalize($ {unsafe {delete state}})}
}
def ce_task_loop_signal(var state:CeTaskLoopControl?; signal:int) {state.signal=signal}
def ce_task_loop_active(state:CeTaskLoopControl?) : bool => state.signal==0
def ce_task_loop_not_broken(state:CeTaskLoopControl?) : bool => state.signal!=1

def private ce_task_loop_input(var source:iterator<auto(TT)>; state:CeTaskLoopControl?) : iterator<TT> {
    var cursor <- ce_zip_cursor(source)
    return <- generator<TT> capture(<-cursor,copy(state)) {
        while(ce_task_loop_not_broken(state)) {
            if(!ce_zip_next(cursor)) {break}
            static_if(typeinfo is_ref_value(type<TT>)) {yield *cursor.slot}
            else {yield cursor.slot}
        }
        return false
    } finally {ce_sequence_finalize($ {ce_zip_close(cursor)})}
}
def ce_task_loop_source(var source:iterator<auto>;state:CeTaskLoopControl?) =>
    <- ce_task_loop_input(source,state)
def ce_task_loop_source_owned(var source:iterator<auto>;state:CeTaskLoopControl?) =>
    <- ce_task_loop_input(source,state)
def ce_task_loop_source_owned(var source:array<auto(ItemT)>;state:CeTaskLoopControl?) {
    var stream <- generator<ItemT&> capture(<-source) {
        var index=0
        while(index<length(source)) {yield source[index];index++}
        return false
    } finally {ce_sequence_finalize($ {delete source})}
    return <- ce_task_loop_input(stream,state)
}
def ce_task_loop_source(source:auto ==const;state:CeTaskLoopControl?) {
    unsafe {var stream <- each(source);return <- ce_task_loop_input(stream,state)}
}
def ce_task_loop_source(var source:auto ==const;state:CeTaskLoopControl?) {
    unsafe {var stream <- each(source);return <- ce_task_loop_input(stream,state)}
}
def ce_task_is_polling(task:auto) : bool => task.polling
def ce_await_borrow_value(builder:auto; source:auto) {
    concept_assert(false,"task: reference binding requires an owning array Task")
}

//! The scope that one ``task_poll`` or ``task_cancel`` call opens; ``cancelled`` records that a task
//! nested in the call reported cancellation. The runtime keeps these: user code does not create one.
// Task is single-threaded. Each poll or cancel opens a scope that a nested
// task uses to signal cancellation to it.
struct TaskPollScope {cancelled:bool}
var private task_cleanup_scopes:array<TaskPollScope>
def private task_cleanup_begin() {task_cleanup_scopes |> push(TaskPollScope())}
// A resource scope inside a task: the event it holds may own its payload.
def ce_sequence_scoped(var source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(ScopedTaskValueT)>>;
    var cleanup:lambda<():void>) : iterator<tuple<tag:TaskEventTag;ready:bool;value:ScopedTaskValueT>> {
    return <- generator<tuple<tag:TaskEventTag;ready:bool;value:ScopedTaskValueT>> capture(<-source,<-cleanup) {
        var event:tuple<tag:TaskEventTag;ready:bool;value:ScopedTaskValueT>
        while(ce_sequence_next_value(source,event)) {
            static_if(typeinfo can_copy(type<ScopedTaskValueT>)) {yield event}
            else {yield <- event}
        }
        return false
    } finally {ce_sequence_finalize($ {
        sequence_close(source)
        invoke(cleanup)
        unsafe {delete cleanup}
        static_if(typeinfo can_delete(event)) {delete event}
    })}
}

// Cancellation is a scoped control signal, never a panic.
def ce_task_cancelled() {
    let count=length(task_cleanup_scopes)
    if(count>0) {task_cleanup_scopes[count-1].cancelled=true}
}
def private task_cleanup_cancelled() : bool {
    let count=length(task_cleanup_scopes)
    return count>0 && task_cleanup_scopes[count-1].cancelled
}
def private task_cleanup_end() {
    task_cleanup_scopes.resize(length(task_cleanup_scopes)-1)
}

//! Returns the event of a task that has no result yet: ``ready`` is false and ``value`` is the
//! default ``T``. A poll callback returns it to leave its task ``TaskStatus.Waiting``.
def task_pending(unused:type<auto(TT)>) {
    static_if(typeinfo can_copy(type<TT -const -&>)) {
        return (tag=TaskEventTag(),ready=false,value=default<TT -const -&>)
    } else {return <- (tag=TaskEventTag(),ready=false,value <- default<TT -const -&>)}
}
//! Returns the event that completes a task with a copy of ``value``. A value that cannot be copied
//! is a compile error here: use ``task_ready_move``.
def task_ready(value:auto(TT)) {
    concept_assert(typeinfo can_copy(type<TT>),"task: move-only return needs 'return <- value' or task_ready_move")
    return tuple<tag:TaskEventTag;ready:bool;value:TT -const -&>(tag=TaskEventTag(),ready=true,value=value)
}

//! Returns the event that completes a task with ``value``, which is moved into the event.
def task_ready_move(var value:auto(TT)) {
    static_assert(typeinfo ce_resumable_payload(default<TT -const -&>))
    return <- (tag=TaskEventTag(),ready=true,value <- value)
}
//! Makes a ``Task<T>`` in status ``TaskStatus.Created`` from an iterator of events, which is moved
//! into the task. Each ``task_poll`` takes one event: the task succeeds on the first ready one, and
//! fails if the iterator ends before that.
def task_create(var source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(TT)>>) {
    static_assert(typeinfo ce_resumable_payload(default<TT>))
    return <- (tag=TaskTag(),source <- source,status=TaskStatus.Created,value <- default<TT>,error="",polling=false)
}
//! The builder of ``computation(TaskBuilder(type<T>)) { ... }``, which returns a ``Task<T>``. In the
//! block ``source |> bind`` awaits a task and gives its value, and ``return value`` completes the task.
//! A bound task that fails or is cancelled fails or cancels this one; a ``Result`` or ``Option`` value
//! is plain data.
def TaskBuilder(unused:type<auto(TT)>) {var marker:TT -const -&?;return (kind=TaskContext(),element=marker)}
//! The builder of a task that can fail with a message: the computation returns a
//! ``Task<Result<T;string>>``. ``return value`` completes it with ``ok``; binding a task whose result
//! is ``err`` skips the rest of the block and completes this task with that error. A ``Task<CeUnit>``
//! such as ``task_delay_ms`` can be bound as well.
def TaskResultBuilder(unused:type<auto(TT)>) {var marker:TT -const -&?;return (kind=TaskResultContext(),element=marker)}

// Resumable streams may emit values; single-result Task builders may not.
def ce_await_yield(builder:auto; value:auto) {
    concept_assert(false,"task: use source |> bind to await; yield is not supported")
    return <- ce_await_pending(builder)
}
def ce_await_yield_move(builder:auto; var value:auto) {
    concept_assert(false,"task: use source |> bind to await; yield is not supported")
    return <- ce_await_pending(builder)
}

def ce_protocol(builder:tuple<kind:TaskContext;element:auto(TT)?>) =>
    ce_resumable_protocol(type<tuple<tag:TaskEventTag;ready:bool;value:TT>>)
def ce_protocol(builder:tuple<kind:TaskResultContext;element:auto(TT)?>) =>
    ce_resumable_protocol(type<tuple<tag:TaskEventTag;ready:bool;value:Result<TT;string>>>)
def ce_await_pending(builder:tuple<kind:TaskContext;element:auto(TT)?>) => task_pending(type<TT>)
def ce_await_pending(builder:tuple<kind:TaskResultContext;element:auto(TT)?>) =>
    task_pending(type<Result<TT;string>>)
def ce_await_return(builder:tuple<kind:TaskContext;element:auto(TT)?>; value:TT) => task_ready(value)
def ce_await_return(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; value:TT) =>
    task_ready(ok(value, type<string>))

def ce_await_return_move(builder:tuple<kind:TaskContext;element:auto(TT)?>; var value:TT) =>
    <- task_ready_move(value)
def ce_await_return_move(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; var value:TT) {
    var result <- move_ok(value)
    return <- task_ready_move(result)
}
def ce_await_zero(_builder:tuple<kind:TaskContext;element:CeUnit?>) => task_ready(CeUnit())
def ce_await_zero(_builder:tuple<kind:TaskResultContext;element:CeUnit?>) =>
    task_ready(ok(CeUnit(), type<string>))

def ce_await_borrow_value(builder:tuple<kind:TaskContext;element:auto>; var event:tuple<tag:TaskEventTag;ready:bool;value:auto(TT)>) : TT& {
    unsafe {return event.value}
}
def ce_await_borrow_value(builder:tuple<kind:TaskResultContext;element:auto>; var event:tuple<tag:TaskEventTag;ready:bool;value:Result<auto(TT);string>>) : TT& {
    unsafe {return event.value as ok}
}
def ce_await_borrow_value(builder:tuple<kind:TaskResultContext;element:auto>; var event:tuple<tag:TaskEventTag;ready:bool;value:CeUnit>) : CeUnit& =>
    event.value
def ce_await_borrow_value(builder:tuple<kind:TaskResultContext;element:auto>; var event:tuple<tag:TaskEventTag;ready:bool;value:array<auto(TT)>>) : array<TT>& {unsafe {return event.value}}
def ce_await_failed(builder:tuple<kind:TaskResultContext;element:auto>; event:tuple<tag:TaskEventTag;ready:bool;value:array<auto>>) =>
    false
def ce_await_failure(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; event:tuple<tag:TaskEventTag;ready:bool;value:array<auto>>) =>
    <- task_pending(type<Result<TT;string>>)
def ce_await_value(builder:tuple<kind:TaskContext;element:auto(TT)?>; event:tuple<tag:TaskEventTag;ready:bool;value:auto(UU)>) {
    concept_assert(typeinfo can_copy(type<UU>),"task: move-only bind needs 'var value & = source |> bind'")
    return event.value
}
def ce_await_value(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; event:tuple<tag:TaskEventTag;ready:bool;value:Result<auto(UU);string>>) {
    concept_assert(typeinfo can_copy(type<UU>),"task: move-only bind needs 'var value & = source |> bind'")
    return event.value as ok
}
def ce_await_failed(builder:tuple<kind:TaskContext;element:auto(TT)?>; event:auto) => false
def ce_await_failed(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; event:tuple<tag:TaskEventTag;ready:bool;value:Result<auto(UU);string>>) =>
    event.value is err
def ce_await_failure(builder:tuple<kind:TaskContext;element:auto(TT)?>; event:auto) =>
    task_pending(type<TT>)
def ce_await_failure(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; event:tuple<tag:TaskEventTag;ready:bool;value:Result<auto(UU);string>>) {
    var result <- move_error(event.value as err,type<TT>)
    return <- task_ready_move(result)
}

// Unit operations have no domain Error; native failure/cancellation still
// propagate through ce_await_source. This also permits delay |> bind in TaskResult.
def ce_await_value(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; event:tuple<tag:TaskEventTag;ready:bool;value:CeUnit>) =>
    CeUnit()
def ce_await_failed(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; event:tuple<tag:TaskEventTag;ready:bool;value:CeUnit>) =>
    false
def ce_await_failure(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; event:tuple<tag:TaskEventTag;ready:bool;value:CeUnit>) =>
    task_pending(type<Result<TT;string>>)

def ce_sequence_run(builder:tuple<kind:TaskContext;element:auto(TT)?>; var source:iterator<tuple<tag:TaskEventTag;ready:bool;value:TT>>) =>
    <- task_create(source)
def ce_sequence_run(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; var source:iterator<tuple<tag:TaskEventTag;ready:bool;value:Result<TT;string>>>) =>
    <- task_create(source)

//! Marker of the builder that ``TaskResultBuilder(type<T>, type<E>)`` returns.
struct TaskResultErrorContext {_ce_marker:uint8}
//! The same builder with an error type of your own: the computation returns a ``Task<Result<T;E>>``.
//! ``return value`` says nothing about the error type, so the builder carries it. ``E`` must be
//! copyable, and a bound task must fail with the same ``E``: ``task_map_error`` converts one that
//! fails with another type.
def TaskResultBuilder(unused:type<auto(TT)>; failure:type<auto(EE)>) {
    static_assert(typeinfo can_copy(type<EE -const -&>), "TaskResultBuilder(type<T>, type<E>): the error type must be copyable")
    var marker:TT -const -&?
    var fault:EE -const -&?
    return (kind=TaskResultErrorContext(),element=marker,error=fault)
}
def ce_protocol(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>) =>
    ce_resumable_protocol(type<tuple<tag:TaskEventTag;ready:bool;value:Result<TT;EE>>>)
def ce_await_pending(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>) =>
    task_pending(type<Result<TT;EE>>)
def ce_await_return(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; value:TT) =>
    task_ready(result::ok(value,type<EE>))
def ce_await_return_move(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; var value:TT) {
    var result <- ce_move_ok(value,type<EE>)
    return <- task_ready_move(result)
}
def ce_await_zero(builder:tuple<kind:TaskResultErrorContext;element:CeUnit?;error:auto(EE)?>) =>
    task_ready(result::ok(CeUnit(),type<EE>))
def ce_await_borrow_value(builder:tuple<kind:TaskResultErrorContext;element:auto;error:auto(EE)?>; var event:tuple<tag:TaskEventTag;ready:bool;value:variant<err:auto(FF);ok:auto(TT)>>) : TT& {
    unsafe {return event.value as ok}
}
def ce_await_borrow_value(builder:tuple<kind:TaskResultErrorContext;element:auto;error:auto(EE)?>; var event:tuple<tag:TaskEventTag;ready:bool;value:CeUnit>) : CeUnit& =>
    event.value
def ce_await_borrow_value(builder:tuple<kind:TaskResultErrorContext;element:auto;error:auto(EE)?>; var event:tuple<tag:TaskEventTag;ready:bool;value:array<auto(TT)>>) : array<TT>& {unsafe {return event.value}}
def ce_await_value(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; event:tuple<tag:TaskEventTag;ready:bool;value:variant<err:auto(FF);ok:auto(UU)>>) {
    concept_assert(typeinfo can_copy(type<UU>),"task: move-only bind needs 'var value & = source |> bind'")
    return event.value as ok
}
// The bound task's error type is checked here, in the test every bind makes
// first, so a task that fails with another type is reported once and by name.
// An overload for the exact type next to a general one would be ambiguous.
def ce_await_failed(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; event:tuple<tag:TaskEventTag;ready:bool;value:variant<err:auto(FF);ok:auto(UU)>>) : bool {
    static_if (typeinfo stripped_typename(type<FF>) != typeinfo stripped_typename(type<EE>)) {
        concept_assert(false, "computation: this task fails with {typeinfo stripped_typename(type<FF>)}, and the computation with {typeinfo stripped_typename(type<EE>)}; convert its error with task_map_error(task, @@convert)")
        return false
    } else {
        return event.value is err
    }
}
def ce_await_failure(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; event:tuple<tag:TaskEventTag;ready:bool;value:variant<err:auto(FF);ok:auto(UU)>>) {
    static_if (typeinfo stripped_typename(type<FF>) != typeinfo stripped_typename(type<EE>)) {
        return task_pending(type<Result<TT;EE>>)
    } else {
        var fault = event.value as err
        var result <- result::move_err(fault,type<TT>)
        return <- task_ready_move(result)
    }
}
def ce_await_value(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; event:tuple<tag:TaskEventTag;ready:bool;value:CeUnit>) =>
    CeUnit()
def ce_await_failed(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; event:tuple<tag:TaskEventTag;ready:bool;value:CeUnit>) =>
    false
def ce_await_failure(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; event:tuple<tag:TaskEventTag;ready:bool;value:CeUnit>) =>
    task_pending(type<Result<TT;EE>>)
def ce_await_failed(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; event:tuple<tag:TaskEventTag;ready:bool;value:array<auto>>) =>
    false
def ce_await_failure(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; event:tuple<tag:TaskEventTag;ready:bool;value:array<auto>>) =>
    <- task_pending(type<Result<TT;EE>>)
def ce_sequence_run(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; var source:iterator<tuple<tag:TaskEventTag;ready:bool;value:Result<TT;EE>>>) =>
    <- task_create(source)

//! Returns the task's current status without polling it.
def task_status(task:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(TT)>>;status:TaskStatus;value:TT;error:string;polling:bool>) =>
    task.status
//! Returns the result of a succeeded task and leaves it in the task: a copy, or a clone when ``T``
//! cannot be copied. Panics unless the status is ``TaskStatus.Succeeded``.
def task_value(task:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(TT)>>;status:TaskStatus;value:TT;error:string;polling:bool>) : TT {
    if(task.status!=TaskStatus.Succeeded) {panic("task_value: task has not succeeded")}
    static_if(typeinfo can_copy(type<TT>)) {return task.value}
    else {return <- clone(task.value)}
}

//! Moves the result out of a succeeded task and deletes the task. Panics if the task has not
//! succeeded or is being polled.
def task_take(var task:auto) {
    if(ce_task_is_polling(task)) {panic("task_take: task is being polled")}
    if(task_status(task)!=TaskStatus.Succeeded) {panic("task_take: task has not succeeded")}
    var result <- task.value
    delete task
    return <- result
}
//! Returns the message of the panic that made the task ``TaskStatus.Failed``, or an empty string
//! for a task in any other status.
def task_error(task:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(TT)>>;status:TaskStatus;value:TT;error:string;polling:bool>) =>
    task.error

//! Stops a task that has not finished: its status becomes ``TaskStatus.Cancelled`` and its source is
//! closed, which runs the body's cleanup and cancels the task it was awaiting. Returns false, and
//! changes nothing, for a task that has already finished. Panics when called while the task is being polled.
def task_cancel(var task:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(TT)>>;status:TaskStatus;value:TT;error:string;polling:bool>) : bool {
    if(task.polling) {panic("task_cancel: task is being polled")}
    if(task.status!=TaskStatus.Created && task.status!=TaskStatus.Waiting) {return false}
    task_cleanup_begin()
    task.status=TaskStatus.Cancelled
    sequence_close(task.source)
    task_cleanup_end()
    return true
}

//! Runs the task to its next suspension or to its result and returns the new status. A finished task
//! returns its cached status; nothing here waits or uses another thread. A panic in the task's body is
//! caught here, and nowhere else: the task becomes ``TaskStatus.Failed`` and is closed, which releases
//! what its body still owned. A requested ``CancellationToken`` in scope cancels the task instead.
//! Panics on a reentrant poll of the same task.
def task_poll(var task:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(TT)>>;status:TaskStatus;value:TT;error:string;polling:bool>) : TaskStatus {
    if(task.polling) {panic("task_poll: reentrant polling is unsupported")}
    if(task.status!=TaskStatus.Created && task.status!=TaskStatus.Waiting) {return task.status}
    if(ce_task_cancellation_requested()) {task_cancel(task);return task.status}
    task.polling=true
    task_cleanup_begin()
    var event <- task_pending(type<TT>)
    try {
        let more=ce_sequence_next_value(task.source,event)
        if(task_cleanup_cancelled() || ce_task_cancellation_requested()) {
            task.status=TaskStatus.Cancelled
            sequence_close(task.source)
        } elif(!more) {panic("task: computation ended without return")}
        elif(event.ready) {
            static_if(typeinfo can_copy(type<TT>)) {task.value=event.value}
            else {task.value <- event.value}
            task.status=TaskStatus.Succeeded
            sequence_close(task.source)
        } else {task.status=TaskStatus.Waiting}
    } recover {
        task.error="{this_context().last_exception}"
        task.status=TaskStatus.Failed
    }
    if(task.status==TaskStatus.Failed) {sequence_close(task.source)}
    task_cleanup_end()
    task.polling=false
    static_if(typeinfo can_delete(event)) {delete event}
    if(task.status==TaskStatus.Failed || task.status==TaskStatus.Cancelled) {
        static_if(typeinfo can_delete(task.value)) {delete task.value}
    }
    return task.status
}

// A source a task cannot await. One error at the bind replaces the list of
// every ce_await_source; the value it would have produced is a marker, so
// nothing else fails after the report.
def ce_await_source(builder:auto; source:auto) : iterator<tuple<tag:TaskEventTag;ready:bool;value:CeNotBindable>> {
    concept_assert(false, "computation: a task cannot bind a source of type {typeinfo stripped_typename(source)}: no ce_await_source(builder, source) accepts it")
    var events : iterator<tuple<tag:TaskEventTag;ready:bool;value:CeNotBindable>>
    return <- events
}
def ce_await_value(builder:tuple<kind:TaskContext;element:auto(TT)?>; event:tuple<tag:TaskEventTag;ready:bool;value:CeNotBindable>) =>
    CeNotBindable()
def ce_await_value(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; event:tuple<tag:TaskEventTag;ready:bool;value:CeNotBindable>) =>
    CeNotBindable()
def ce_await_failed(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; event:tuple<tag:TaskEventTag;ready:bool;value:CeNotBindable>) =>
    false
def ce_await_failure(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; event:tuple<tag:TaskEventTag;ready:bool;value:CeNotBindable>) =>
    task_pending(type<Result<TT;string>>)
def ce_await_return(builder:tuple<kind:TaskContext;element:auto(TT)?>; value:CeNotBindable) =>
    task_pending(type<TT>)
def ce_await_return(builder:tuple<kind:TaskResultContext;element:auto(TT)?>; value:CeNotBindable) =>
    task_pending(type<Result<TT;string>>)
def ce_await_value(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; event:tuple<tag:TaskEventTag;ready:bool;value:CeNotBindable>) =>
    CeNotBindable()
def ce_await_failed(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; event:tuple<tag:TaskEventTag;ready:bool;value:CeNotBindable>) =>
    false
def ce_await_failure(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; event:tuple<tag:TaskEventTag;ready:bool;value:CeNotBindable>) =>
    task_pending(type<Result<TT;EE>>)
def ce_await_return(builder:tuple<kind:TaskResultErrorContext;element:auto(TT)?;error:auto(EE)?>; value:CeNotBindable) =>
    task_pending(type<Result<TT;EE>>)

// Move an awaited child into the parent; closing the parent cancels the child.
def ce_await_source(builder:auto; var task:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(TT)>>;status:TaskStatus;value:TT;error:string;polling:bool>) : iterator<tuple<tag:TaskEventTag;ready:bool;value:TT>> {
    return <- generator<tuple<tag:TaskEventTag;ready:bool;value:TT>> capture(<-task) {
        while(true) {
            let status=task_poll(task)
            if(status==TaskStatus.Failed) {panic(task_error(task))}
            if(status==TaskStatus.Cancelled || ce_task_cancellation_requested()) {
                ce_task_cancelled()
                yield <- task_pending(type<TT>)
                return false
            }
            if(status==TaskStatus.Succeeded) {
                static_if(typeinfo can_copy(type<TT>)) {yield task_ready(task_value(task))}
                else {yield <- task_ready_move(task.value)}
                break
            }
            yield <- task_pending(type<TT>)
        }
        return false
    } finally {ce_sequence_finalize($ {
        task_cancel(task)
        delete task
    })}
}

//! Moves ``task`` into a new task of the same type that is polled under ``token``: once the token is
//! requested, the new task and what it awaits become ``TaskStatus.Cancelled`` at their next poll. The
//! new task keeps a handle of its own to the token, so the caller's handle stays theirs to cancel and
//! delete. Panics if ``task`` is being polled.
// Own both a child and a lease on the handle token. The dynamic scope lasts
// only for task_poll, so nested binds observe the token without stack captures.
def task_with_cancellation(var task:auto; token:CancellationToken) {
    if(task.polling) {panic("task cancellation: cannot move a task being polled")}
    var lease <- cancellation_clone(token)
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:typedecl(task.value) -const -&>> capture(<-task,<-lease) {
        while(true) {
            var status=TaskStatus.Created
            ce_cancellation_scope(lease,$ {status=task_poll(task)})
            if(status==TaskStatus.Failed) {panic(task_error(task))}
            if(status==TaskStatus.Cancelled || cancellation_requested(lease)) {
                ce_task_cancelled()
                yield <- task_pending(type<typedecl(task.value) -const -&>)
                return false
            }
            if(status==TaskStatus.Succeeded) {yield <- task_ready_move(task.value);return false}
            yield <- task_pending(type<typedecl(task.value) -const -&>)
        }
        return false
    } finally {ce_sequence_finalize($ {
        task_cancel(task)
        delete task
        delete lease
    })}
    return <- task_create(events)
}

// Adapter for a nonblocking operation's poll callback. The lambda owns captures.
// Each poll returns Pending or Ready; close runs when the task ends, however it ends.
def private task_close_callbacks(var poll:lambda<():auto(TT)>; var close:lambda<():void>) {
    invoke(close)
    unsafe {delete poll;delete close}
}

//! Makes a task from the poll callback of a non-blocking operation. Each ``task_poll`` invokes ``poll``
//! once: it returns ``task_pending(type<T>)`` to keep waiting, or a ready event to finish. ``close``
//! runs once when the task ends, however it ends. The task owns both lambdas and what they capture.
def task_from_poll(var poll:lambda<():tuple<tag:TaskEventTag;ready:bool;value:auto(TT)>>; var close:lambda<():void>) {
    var source <- generator<tuple<tag:TaskEventTag;ready:bool;value:TT>> capture(<-poll,<-close) {
        while(true) {
            var event <- invoke(poll)
            let ready=event.ready
            static_if(typeinfo can_copy(type<TT>)) {yield event}
            else {yield <- event}
            if(ready) {break}
        }
        return false
    } finally {ce_sequence_finalize($ {task_close_callbacks(poll,close)})}
    return <- task_create(source)
}

//! Returns a task that stays ``TaskStatus.Waiting`` for ``count`` polls and succeeds with a copy of
//! ``value`` on the next one: a stand-in for an operation that takes a known number of polls.
//! Panics on a negative ``count``.
def task_after_polls(count:int; value:auto(TT)) {
    if(count<0) {panic("task_after_polls: count must be non-negative")}
    var source <- generator<tuple<tag:TaskEventTag;ready:bool;value:TT -const -&>> {
        for(i in range(count)) {yield task_pending(type<TT>)}
        yield task_ready(value)
        return false
    }
    return <- task_create(source)
}

//! The same as ``task_after_polls`` for a value that cannot be copied: ``value`` is moved into the task.
def task_after_polls_move(count:int;var value:auto(OwnedValueT)) {
    if(count<0) {panic("task_after_polls_move: count must be non-negative")}
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:OwnedValueT -const -&>> capture(<-value) {
        for(i in range(count)) {yield <- task_pending(type<OwnedValueT -const -&>)}
        yield <- task_ready_move(value)
        return false
    } finally {ce_sequence_finalize($ {static_if(typeinfo can_delete(value)) {delete value}})}
    return <- task_create(events)
}

//! Makes a task from the iterator of a daslib ``[async]`` function; the iterator is moved into the
//! task. A ``wait`` event suspends the task. As a native ``await`` does, the task runs the producer to
//! its end, so the side effects after its last value happen, and succeeds with the last ``res`` it
//! produced. The task fails if the producer ends without a result.
def task_from_async(var source:iterator<variant<res:auto(TT);wait:bool>>) {
    static_assert(typeinfo ce_resumable_payload(default<TT>))
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:TT -const -&>> capture(<-source) {
        var event:variant<res:TT;wait:bool>
        var value:TT -const -&
        var received=false
        while(ce_sequence_next_value(source,event)) {
            if(event is res) {
                static_if(typeinfo can_copy(type<TT>)) {value=event as res}
                else {delete value;value <- event as res}
                received=true
            }
            else {yield <- task_pending(type<TT>)}
        }
        sequence_close(source)
        if(!received) {panic("task_from_async: async completed without a result")}
        yield <- task_ready_move(value)
        return false
    } finally {ce_sequence_finalize($ {
        sequence_close(source)
        static_if(typeinfo can_delete(value)) {delete value}
        static_if(typeinfo can_delete(event)) {delete event}
    })}
    return <- task_create(events)
}

//! The same for a void ``[async]`` function, whose iterator yields ``bool``: every element suspends
//! the task, and the task succeeds with ``CeUnit`` when the iterator ends.
def task_from_async(var source:iterator<bool>) {
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:CeUnit>> capture(<-source) {
        var waiting=false
        while(ce_sequence_next_value(source,waiting)) {yield task_pending(type<CeUnit>)}
        sequence_close(source)
        yield task_ready(CeUnit())
        return false
    } finally {ce_sequence_finalize($ {sequence_close(source)})}
    return <- task_create(events)
}

//! The same with a cleanup that the task owns: ``close`` runs once when the source is closed, also
//! when the task was never polled, and is then deleted. Use it to release the external operation or
//! resource behind ``source``.
def task_from_async(var source:iterator<auto(TT)>; var close:lambda<():void>) {
    var owner <- @ capture(move(close)) {
        invoke(close)
        unsafe {delete close}
    }
    var scoped <- ce_sequence_scoped(source,owner)
    return <- task_from_async(scoped)
}

//! Owns a task for the length of a block: ``task`` is moved in and passed to ``body``; when the block
//! returns, the task is cancelled, if it is still running, and deleted.
def task_scope(var task:auto(TT); body:block<(var owned:TT):void>) {
    var owned <- task
    invoke(body,owned)
    task_cancel(owned)
    delete owned
}

//! Marker field that makes a tuple a ``TaskShared<T>``; it carries no data.
struct TaskSharedTag {_ce_marker:uint8}
//! The handle that ``task_share`` returns for a ``Task<T>``: a counted reference to one task that
//! several holders can poll, read and bind. ``task_shared_clone`` or ``:=`` makes another handle;
//! deleting the last one cancels the task, if it is still running, and releases it.
[template_tuple(TT)]
struct template TaskShared {
    tag : TaskSharedTag
    owner : iterator<tuple<references:uint64;task:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:TT>>;status:TaskStatus;value:TT;error:string;polling:bool>>?>
}

def private ce_task_shared_lease(var state:auto(SharedStateT)?) {
    var owner <- generator<SharedStateT?> capture(copy(state)) {
        while(true) {yield state}
        return false
    } finally {ce_sequence_finalize($ {
        unsafe {
            state.references--
            if(state.references==uint64(0)) {
                task_cancel(state.task)
                delete state
            }
        }
    })}
    return <- (tag=TaskSharedTag(),owner <- owner)
}
//! Moves a task into shared storage and returns the first ``TaskShared<T>`` handle to it. Panics if
//! the task is being polled.
def task_share(var task:auto(SharedOwnerT)) {
    if(ce_task_is_polling(task)) {panic("task_share: cannot move a task being polled")}
    unsafe {
        var state=new tuple<references:uint64;task:SharedOwnerT>(references=uint64(1),task <- task)
        return <- ce_task_shared_lease(state)
    }
}
def private ce_task_shared_state(handle:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>) : SharedStateT? {
    var state:SharedStateT?
    unsafe {
        var lease=addr<iterator<SharedStateT?>?>(handle.owner)
        if(!next(*lease,state)) {panic("shared Task: handle has been moved or deleted")}
        return state
    }
}
//! Returns another handle to the same shared task. Panics on a handle that was moved from or deleted.
def task_shared_clone(handle:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>) {
    var state=ce_task_shared_state(handle)
    unsafe {
        if(state.references==uint64(-1)) {panic("shared Task: reference count exhausted")}
        state.references++
        return <- ce_task_shared_lease(state)
    }
}
//! Makes ``target := source`` share the task of ``source``; the handle that ``target`` held is released.
def clone(var target:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>; source:tuple<tag:TaskSharedTag;owner:iterator<SharedStateT?>>) {
    var next <- task_shared_clone(source)
    delete target
    target <- next
}
def task_status(handle:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>) {
    var state=ce_task_shared_state(handle)
    unsafe {return task_status(state.task)}
}
def task_error(handle:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>) {
    var state=ce_task_shared_state(handle)
    unsafe {return task_error(state.task)}
}
def task_value(handle:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>) {
    var state=ce_task_shared_state(handle)
    unsafe {
        static_if(typeinfo can_copy(state.task.value)) {return task_value(state.task)}
        else {return <- task_value(state.task)}
    }
}
def ce_task_is_polling(handle:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>) : bool {
    var state=ce_task_shared_state(handle)
    return state.task.polling
}
//! Polls the shared task once and returns its status. The poll does not see the caller's
//! cancellation tokens: cancelling one waiter never cancels the task that the others share.
def task_poll(var handle:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>) {
    var state=ce_task_shared_state(handle)
    var status=TaskStatus.Created
    unsafe {ce_cancellation_isolate($ {status=task_poll(state.task)})}
    return status
}
//! Cancels the shared task itself, for every handle. Returns false if it had already finished.
def task_cancel(var handle:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>) {
    var state=ce_task_shared_state(handle)
    unsafe {return task_cancel(state.task)}
}
//! Consumes a handle and returns a ``Task<T>`` that follows the shared task: it succeeds with a copy
//! of the shared value (a clone when ``T`` cannot be copied), fails with its error and is cancelled
//! with it. Cancelling or deleting the returned task only releases the handle. Binding a handle in a
//! computation does the same with a clone, so the handle itself stays with the caller.
def task_from_shared(var handle:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>) {
    typedef SharedValue=typedecl(task_value(handle)) -const -&
    var source <- generator<tuple<tag:TaskEventTag;ready:bool;value:SharedValue>> capture(<-handle) {
        while(true) {
            let status=task_poll(handle)
            if(status==TaskStatus.Failed) {panic(task_error(handle))}
            if(status==TaskStatus.Cancelled || ce_task_cancellation_requested()) {
                ce_task_cancelled();yield <- task_pending(type<SharedValue>);return false
            }
            if(status==TaskStatus.Succeeded) {
                var value:SharedValue
                static_if(typeinfo can_copy(type<SharedValue>)) {value=task_value(handle)}
                else {value <- task_value(handle)}
                yield <- task_ready_move(value)
                return false
            }
            yield <- task_pending(type<SharedValue>)
        }
        return false
    } finally {ce_sequence_finalize($ {delete handle})}
    return <- task_create(source)
}
def ce_task_source(var task:auto) => <- task
def ce_task_source(handle:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>) {
    var lease <- task_shared_clone(handle)
    return <- task_from_shared(lease)
}
def ce_source(builder:auto; handle:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>) =>
    <- ce_task_source(handle)
def ce_await_source(builder:auto; handle:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>) {
    var source <- ce_task_source(handle)
    return <- ce_await_source(builder,source)
}

//! Moves the result out of a shared task and deletes the handle, which must be the last one:
//! observers release their handles first. Panics while another handle exists, if the task has not
//! succeeded, or if it is being polled.
def task_take(var handle:tuple<tag:TaskSharedTag;owner:iterator<auto(SharedStateT)?>>) {
    var state=ce_task_shared_state(handle)
    unsafe {
        if(state.references!=uint64(1)) {panic("shared Task take: other observers still own the result")}
        var result <- task_take(state.task)
        delete handle
        return <- result
    }
}
