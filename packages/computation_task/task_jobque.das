options gen2
module task_jobque public
require ./task_builder.das public
require daslib/jobque_boost public
require daslib/rtti
require daslib/fio
require daslib/ast_boost
require daslib/templates_boost
require daslib/typemacro_boost

//! Runs work on daslang's job queue threads and returns its outcome through a ``Task``, so the thread
//! that polls the tasks does not block. ``task_jobque`` submits one function call,
//! ``task_jobque_cancellable`` one that can be asked to stop, ``task_jobque_stream`` a worker that
//! emits a series of values. A worker's panic arrives as an error value. Require it for blocking or
//! heavy work; the job queue must be running (``with_job_que``) when the tasks are polled.

//! Marker field that identifies a ``TaskJobQueue``; user code does not construct it.
struct TaskJobQueueTag {_ce_marker:uint8}
//! ``TaskJobQueue`` names the handle type that ``task_job_queue()`` returns, to declare a variable, a
//! field or a parameter.
// The state layout is repeated in task_job_queue; its declared result type keeps the two in step.
typedef TaskJobQueue = tuple<tag:TaskJobQueueTag;owner:iterator<tuple<references:uint64;closed:bool;records:array<tuple<channel:Channel?;waiting:bool;cancel:Atomic32?;pending:Atomic32?>>>?>>
//! Marker field that identifies a ``TaskJobStream``; user code does not construct it.
struct TaskJobStreamTag {_ce_marker:uint8}
//! The worker's side of a cancellable job or a stream, passed to the work function. Use it only inside
//! that function, with ``task_job_cancelled`` and ``task_job_emit``; user code does not construct it.
struct TaskJobSink {
    ch:Channel?
    cancel:Atomic32?
    pending:Atomic32?
    capacity:int
}
var private native_channels=0

//! Returns the number of native channels held for jobs: one per started job, until
//! ``task_jobque_collect`` or the queue's shutdown frees it. A check for leaks: 0 when no job is left.
def task_jobque_channels() => native_channels
def private ce_jobque_remove(var record:auto) {
    if(record.channel!=null) {unsafe(channel_remove(record.channel));native_channels--}
    unsafe {
        if(record.cancel!=null) {atomic32_remove(record.cancel)}
        if(record.pending!=null) {atomic32_remove(record.pending)}
    }
}
def private ce_jobque_request_cancel(var record:auto) {
    if(record.cancel!=null) {record.cancel |> set(1)}
}
def private ce_jobque_lease(var state:auto(SS)?;owner:bool=false) {
    return <- generator<SS?> capture(copy(state),copy(owner)) {
        while(true) {yield state}
        return false
    } finally {ce_sequence_finalize($ {unsafe {
        if(owner) {state.closed=true}
        state.references--
        if(state.references==uint64(0)) {
            // The last lease is the shutdown join boundary. Keep the queue owner
            // alive in the event loop so cancelling a waiter cannot be the last lease.
            // Ask cooperative workers to stop before joining them.
            for(record in state.records) {if(record.channel!=null) {ce_jobque_request_cancel(record)}}
            for(record in state.records) {if(record.channel!=null) {join(record.channel);ce_jobque_remove(record)}}
            delete state
        }
    }})}
}
def private ce_jobque_state(queue:tuple<tag:TaskJobQueueTag;owner:iterator<auto(SS)?>>) : SS? {
    unsafe {
        var lease=addr<iterator<SS?>?>(queue.owner);var state:SS?
        if(!next(*lease,state)) {panic("task jobque: queue was moved or deleted")}
        return state
    }
}
//! Creates a queue handle through which jobs are submitted; the caller owns it and must delete it.
//! Deleting it closes the queue, so later submissions panic. When the last handle, task and stream
//! of the queue is released, cooperative workers are asked to stop and that release blocks until
//! every worker has finished; keeping the queue handle alive longer than its tasks decides where.
def task_job_queue() : TaskJobQueue {
    var state=new tuple<references:uint64;closed:bool;records:array<tuple<channel:Channel?;waiting:bool;cancel:Atomic32?;pending:Atomic32?>>>(references=uint64(1))
    return <- (tag=TaskJobQueueTag(),owner <- ce_jobque_lease(state,true))
}
//! Frees the native channels of jobs whose worker has finished and whose task or stream no longer
//! waits for them; returns how many it freed. Call it from time to time: without it the channels
//! are kept until the queue shuts down. Panics if the queue handle was moved or deleted.
def task_jobque_collect(queue:tuple<tag:TaskJobQueueTag;owner:iterator<auto(SS)?>>) {
    var state=ce_jobque_state(queue);var removed=0
    unsafe {for(record in state.records) {
        if(record.channel!=null && !record.waiting && record.channel.isReady) {ce_jobque_remove(record);removed++}
    }}
    return removed
}
def private ce_jobque_finish(var op:auto(OO)?) {unsafe {
    if(op.index>=0) {
        // Harmless after completion; stops a cooperative worker on cancel/timeout.
        ce_jobque_request_cancel(op.state.records[op.index])
        op.state.records[op.index].waiting=false
    }
    op.state=null;sequence_close(op.lease);delete op
}}
// Allocates a channel record (and optional atomics) for one native job.
def private ce_jobque_allocate(var state:auto(SS)?;cooperative:bool) : int {unsafe {
    if(state.closed) {panic("task jobque: queue is closed")}
    if(get_total_hw_jobs()<0) {panic("task jobque: invalid pool")}
    var ch=channel_create();append(ch,1)
    var cancel:Atomic32?;var pending:Atomic32?
    if(cooperative) {cancel=atomic32_create();pending=atomic32_create()}
    var record=length(state.records)
    for(i in range(length(state.records))) {if(state.records[i].channel==null) {record=i;break}}
    if(record==length(state.records)) {state.records |> push((channel=ch,waiting=true,cancel=cancel,pending=pending))}
    else {state.records[record]=(channel=ch,waiting=true,cancel=cancel,pending=pending)}
    native_channels++
    return record
}}
def private ce_jobque_poll(var op:auto(OO)?) {unsafe {
    typedef JobValue=typedecl(invoke(op.work,op.input)) -const -&
    if(!op.started) {
        // Fails before allocating a native channel when the host has no pool.
        let record=ce_jobque_allocate(op.state,false)
        var ch=op.state.records[record].channel
        op.index=record;op.started=true
        let work=op.work
        var inscope input_owner <- (value <- op.input)
        new_job() @() {
            var inscope outcome:Result<JobValue;string>
            try {
                var inscope value_owner:tuple<value:JobValue>
                static_if(typeinfo can_copy(type<JobValue>)) {value_owner.value=invoke(work,input_owner.value)}
                else {value_owner.value <- invoke(work,input_owner.value)}
                outcome <- move_ok(value_owner.value)
            } recover {outcome <- move_error("{this_context().last_exception}",type<JobValue>)}
            var inscope packet <- (result <- outcome)
            ch |> push_clone(packet)
            ch |> notify_and_release
        }
    }
    var result:Result<JobValue;string>
    var ch=op.state.records[op.index].channel
    let ready=try_pop_clone(ch,$(packet:tuple<result:Result<JobValue;string>>#) {result := packet.result})
    if(ready) {return <- task_ready_move(result)}
    return <- task_pending(type<Result<JobValue;string>>)
}}
//! Returns a ``Task<Result<V;string>>`` that runs ``work(input)`` on a job queue thread: ok with the
//! returned value, err with the message if the worker panics. ``input`` is moved into the task. The
//! job starts on the task's first poll; the worker gets clones and ``work`` is a function
//! (``@@name``), not a closure, so nothing is shared with the calling thread. Cancelling the task
//! stops the wait, not the worker. Panics if the queue is closed.
def task_jobque_move(queue:tuple<tag:TaskJobQueueTag;owner:iterator<auto(SS)?>>;
    var input:auto(InputT);work:function<(input:InputT):auto(ValueT)>) {
    static_assert(typeinfo ce_resumable_payload(default<InputT -const -&>))
    static_assert(typeinfo ce_resumable_payload(default<ValueT -const -&>))
    var state=ce_jobque_state(queue)
    unsafe {
        if(state.closed) {panic("task jobque: queue is closed")}
        state.references++
        var lease <- ce_jobque_lease(state)
        var op=new tuple<state:SS?;lease:typedecl(lease);index:int;started:bool;input:InputT -const -&;work:typedecl(work) -const -&>(state=state,lease <- lease,index=-1,input <- input,work=work)
        return <- task_from_poll(@(){return <- ce_jobque_poll(op)},@(){ce_jobque_finish(op)})
    }
}

//! ``task_jobque_move`` with a clone of ``input`` taken at the call: the caller keeps its value, and
//! later changes to it do not reach the worker.
def task_jobque(queue:tuple<tag:TaskJobQueueTag;owner:iterator<auto(SS)?>>;
    input:auto(InputT);work:function<(input:InputT):auto(ValueT)>) {
    var inscope snapshot <- default<tuple<value:InputT -const -&>>;snapshot.value := input
    return <- task_jobque_move(queue,snapshot.value,work)
}

//! Returns another handle to the same queue; the caller owns it. It does not keep the queue open:
//! deleting the handle that ``task_job_queue`` returned closes the queue for new jobs. Panics if
//! ``queue`` was moved or deleted.
def task_job_queue_clone(queue:tuple<tag:TaskJobQueueTag;owner:iterator<auto(SS)?>>) {
    var state=ce_jobque_state(queue);unsafe {
        if(state.references==uint64(-1)) {panic("task jobque: references exhausted")}
        state.references++
        return <- (tag=TaskJobQueueTag(),owner <- ce_jobque_lease(state))
    }
}
//! ``target := source`` for queue handles: releases what ``target`` held and makes it another handle
//! to the queue of ``source``.
def clone(var target:tuple<tag:TaskJobQueueTag;owner:iterator<auto(SS)?>>;source:tuple<tag:TaskJobQueueTag;owner:iterator<SS?>>) {
    var next <- task_job_queue_clone(source);delete target;target <- next
}

// ---- Cooperative worker API -------------------------------------------------
//! Returns true once the task or stream waiting for this job was cancelled, timed out or deleted, or
//! the queue is shutting down. A long-running worker checks it and returns early.
def task_job_cancelled(sink:TaskJobSink) : bool {
    if(sink.cancel==null) {return false}
    return (sink.cancel |> get)!=0
}
//! Publishes one value from a stream worker; the reader receives a clone. While ``capacity`` values
//! of the stream are unread it waits, sleeping 1 ms between checks. Returns false, dropping the
//! value, once the stream is cancelled: the worker should then return. The value's type must be
//! exactly the stream's element type. Panics if the sink does not belong to a stream.
def task_job_emit(sink:TaskJobSink;value:auto(TT)) : bool {
    if(sink.ch==null || sink.pending==null) {panic("task_job_emit: sink is not a stream")}
    while(sink.capacity>0 && (sink.pending |> get)>=sink.capacity) {
        if(task_job_cancelled(sink)) {return false}
        sleep(1u)
    }
    if(task_job_cancelled(sink)) {return false}
    sink.pending |> inc
    var inscope packet:tuple<error:string;item:TT -const -&>
    packet.item := value
    sink.ch |> push_clone(packet)
    return true
}

// ---- Cancellable single-result job ------------------------------------------
def private ce_jobque_poll_sink(var op:auto(OO)?) {unsafe {
    typedef JobValue=typedecl(invoke(op.work,op.input,default<TaskJobSink>)) -const -&
    if(!op.started) {
        let record=ce_jobque_allocate(op.state,true)
        var ch=op.state.records[record].channel
        var cancel=op.state.records[record].cancel
        op.index=record;op.started=true
        let work=op.work
        var inscope input_owner <- (value <- op.input)
        new_job() @() {
            var inscope outcome:Result<JobValue;string>
            try {
                let sink=TaskJobSink(cancel=cancel)
                var inscope value_owner:tuple<value:JobValue>
                static_if(typeinfo can_copy(type<JobValue>)) {value_owner.value=invoke(work,input_owner.value,sink)}
                else {value_owner.value <- invoke(work,input_owner.value,sink)}
                outcome <- move_ok(value_owner.value)
            } recover {outcome <- move_error("{this_context().last_exception}",type<JobValue>)}
            var inscope packet <- (result <- outcome)
            ch |> push_clone(packet)
            ch |> notify_and_release
        }
    }
    var result:Result<JobValue;string>
    var ch=op.state.records[op.index].channel
    let ready=try_pop_clone(ch,$(packet:tuple<result:Result<JobValue;string>>#) {result := packet.result})
    if(ready) {return <- task_ready_move(result)}
    return <- task_pending(type<Result<JobValue;string>>)
}}
//! ``task_jobque`` for a worker that can be asked to stop: ``work`` also receives a ``TaskJobSink``, and
//! cancelling or timing out the task, or shutting the queue down, makes ``task_job_cancelled(sink)``
//! return true in the worker. ``input`` is cloned at the call.
def task_jobque_cancellable(queue:tuple<tag:TaskJobQueueTag;owner:iterator<auto(SS)?>>;
    input:auto(InputT);work:function<(input:InputT;sink:TaskJobSink):auto(ValueT)>) {
    static_assert(typeinfo ce_resumable_payload(default<InputT -const -&>))
    static_assert(typeinfo ce_resumable_payload(default<ValueT -const -&>))
    var state=ce_jobque_state(queue)
    unsafe {
        if(state.closed) {panic("task jobque: queue is closed")}
        state.references++
        var lease <- ce_jobque_lease(state)
        var inscope snapshot <- default<tuple<value:InputT -const -&>>;snapshot.value := input
        var op=new tuple<state:SS?;lease:typedecl(lease);index:int;started:bool;input:InputT -const -&;work:typedecl(work) -const -&>(state=state,lease <- lease,index=-1,input <- snapshot.value,work=work)
        return <- task_from_poll(@(){return <- ce_jobque_poll_sink(op)},@(){ce_jobque_finish(op)})
    }
}

// ---- Stream of values from one worker ---------------------------------------
def private ce_jobque_stream_stop(var op:auto(OO)?) {unsafe {
    if(op.stopped) {return}
    op.stopped=true
    if(op.index>=0) {
        ce_jobque_request_cancel(op.state.records[op.index])
        op.state.records[op.index].waiting=false
        op.index=-1
    }
}}
def private ce_jobque_stream_lease(var op:auto(OO)?;owner:bool=false) {
    return <- generator<OO?> capture(copy(op),copy(owner)) {
        while(true) {yield op}
        return false
    } finally {ce_sequence_finalize($ {unsafe {
        if(owner) {ce_jobque_stream_stop(op)}
        op.references--
        if(op.references==uint64(0)) {
            ce_jobque_stream_stop(op)
            op.state=null;sequence_close(op.lease);delete op
        }
    }})}
}
def private ce_jobque_stream_op(stream:tuple<tag:TaskJobStreamTag;owner:iterator<auto(OO)?>>) : OO? {
    unsafe {
        var lease=addr<iterator<OO?>?>(stream.owner);var op:OO?
        if(!next(*lease,op)) {panic("task jobque stream: handle was moved or deleted")}
        return op
    }
}
def private ce_jobque_stream_start(var op:auto(OO)?) {unsafe {
    typedef Item=typedecl(op.witness) -const -&
    let record=ce_jobque_allocate(op.state,true)
    var ch=op.state.records[record].channel
    var cancel=op.state.records[record].cancel
    var pending=op.state.records[record].pending
    op.index=record;op.started=true
    let work=op.work
    let capacity=op.capacity
    var inscope input_owner <- (value <- op.input)
    new_job() @() {
        try {
            let sink=TaskJobSink(ch=ch,cancel=cancel,pending=pending,capacity=capacity)
            invoke(work,input_owner.value,sink)
        } recover {
            var inscope packet:tuple<error:string;item:Item>
            packet.error="{this_context().last_exception}"
            if(empty(packet.error)) {packet.error="task jobque stream: worker failed"}
            ch |> push_clone(packet)
        }
        ch |> notify_and_release
    }
}}
def private ce_jobque_stream_pop(var op:auto(OO)?;var result:auto&) : bool {unsafe {
    typedef Item=typedecl(op.witness) -const -&
    var ch=op.state.records[op.index].channel
    var error="";var got=false
    var item:Item
    let ready=try_pop_clone(ch,$(packet:tuple<error:string;item:Item>#) {
        got=true
        if(empty(packet.error)) {item := packet.item} else {error=string(packet.error)}
    })
    if(!ready || !got) {return false}
    if(!empty(error)) {
        op.failure=error
        ce_jobque_stream_stop(op)
        result <- move_error(error,type<Option<Item>>)
        return true
    }
    op.state.records[op.index].pending |> dec
    var some_item <- ce_move_some(item)
    result <- move_ok(some_item)
    return true
}}
def private ce_jobque_next_poll(var op:auto(OO)?) {unsafe {
    typedef Item=typedecl(op.witness) -const -&
    var result:Result<Option<Item>;string>
    if(!empty(op.failure)) {result <- move_error(op.failure,type<Option<Item>>);return <- task_ready_move(result)}
    if(op.stopped) {var nothing=none(type<Item>);result <- move_ok(nothing);return <- task_ready_move(result)}
    if(!op.started) {ce_jobque_stream_start(op)}
    if(ce_jobque_stream_pop(op,result)) {return <- task_ready_move(result)}
    // The worker releases the channel only after its last push, so a second pop
    // after observing isReady cannot miss a value.
    if(op.state.records[op.index].channel.isReady) {
        if(ce_jobque_stream_pop(op,result)) {return <- task_ready_move(result)}
        op.done=true
        ce_jobque_stream_stop(op)
        var nothing=none(type<Item>);result <- move_ok(nothing)
        return <- task_ready_move(result)
    }
    return <- task_pending(type<Result<Option<Item>;string>>)
}}
//! Creates a stream of values of type ``T`` produced by one worker; the caller owns the handle. The
//! worker starts on the first poll of a ``task_jobque_next`` task; ``work(input, sink)`` publishes
//! values with ``task_job_emit`` and checks ``task_job_cancelled``. At most ``capacity`` values wait
//! unread (0 = unbounded). Deleting the handle asks the worker to stop. Panics if ``capacity`` is
//! negative or the queue is closed.
def task_jobque_stream(queue:tuple<tag:TaskJobQueueTag;owner:iterator<auto(SS)?>>;unused:type<auto(TT)>;
    input:auto(InputT);work:function<(input:InputT;sink:TaskJobSink):void>;capacity:int=64) {
    static_assert(typeinfo ce_resumable_payload(default<InputT -const -&>))
    static_assert(typeinfo ce_resumable_payload(default<TT -const -&>))
    if(capacity<0) {panic("task jobque stream: capacity must be non-negative")}
    var state=ce_jobque_state(queue)
    unsafe {
        if(state.closed) {panic("task jobque: queue is closed")}
        state.references++
        var lease <- ce_jobque_lease(state)
        var inscope snapshot <- default<tuple<value:InputT -const -&>>;snapshot.value := input
        var op=new tuple<state:SS?;lease:typedecl(lease);references:uint64;index:int;started:bool;stopped:bool;done:bool;failure:string;capacity:int;input:InputT -const -&;work:typedecl(work) -const -&;witness:TT -const -&>(state=state,lease <- lease,references=uint64(1),index=-1,capacity=capacity,input <- snapshot.value,work=work)
        return <- (tag=TaskJobStreamTag(),owner <- ce_jobque_stream_lease(op,true))
    }
}
//! ``TaskJobStream<T;Input>`` names the type that ``task_jobque_stream(queue, type<T>, input, @@work)``
//! returns: ``T`` is what the worker emits, ``Input`` what it is given.
// The name is the constructor's own result type, as with TaskScheduler<T>.
[typemacro_function]
def public TaskJobStream(macroArgument, passArgument : TypeDeclPtr; TT, InputT : TypeDeclPtr) : TypeDeclPtr {
    if (passArgument != null) { return null }
    var named = new TypeDecl(baseType=Type.typeDecl, at=macroArgument.at)
    named.typeMacroExpr |> push <| qmacro(task_jobque_stream(default<TaskJobQueue>, type<$t(TT)>, default<$t(InputT)>,
        default<function<(input:$t(InputT);sink:TaskJobSink):void>>))
    return named
}
//! Returns a ``Task<Result<Option<T>;string>>`` for the next value of the stream: ``some`` value,
//! ``none`` after the worker returned or the stream was cancelled, err if the worker panicked. The
//! error arrives after the values emitted before the panic, and every later call repeats it.
//! The stream handle is not consumed.
def task_jobque_next(stream:tuple<tag:TaskJobStreamTag;owner:iterator<auto(OO)?>>) {
    var op=ce_jobque_stream_op(stream)
    unsafe {
        if(op.references==uint64(-1)) {panic("task jobque stream: references exhausted")}
        op.references++
        var lease <- ce_jobque_stream_lease(op)
        var holder=new tuple<op:OO?;lease:typedecl(lease)>(op=op,lease <- lease)
        return <- task_from_poll(@(){return <- ce_jobque_next_poll(holder.op)},@(){holder.op=null;delete holder.lease;delete holder})
    }
}
//! Asks the worker to stop and ends the stream: values not yet read are dropped, and later
//! ``task_jobque_next`` tasks complete with ``none`` (with the error, if the worker had failed).
def task_jobque_stream_cancel(stream:tuple<tag:TaskJobStreamTag;owner:iterator<auto(OO)?>>) {
    var op=ce_jobque_stream_op(stream);ce_jobque_stream_stop(op)
}
//! Returns true once a ``task_jobque_next`` task has reached the normal end of the stream: the worker
//! returned and all its values were read. Stays false for a stream that was cancelled or failed.
def task_jobque_stream_done(stream:tuple<tag:TaskJobStreamTag;owner:iterator<auto(OO)?>>) : bool {
    var op=ce_jobque_stream_op(stream);return op.done
}
def ce_dispose(var stream:tuple<tag:TaskJobStreamTag;owner:iterator<auto?>>) {sequence_close(stream.owner)}
