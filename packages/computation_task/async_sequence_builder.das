options gen2
module async_sequence_builder public
require ./task_combinators.das public
require ../computation/sequence_function.das public
require daslib/rtti
require daslib/typemacro_boost

struct AsyncSequenceContext {_ce_marker:uint8}
struct AsyncSequenceTag {_ce_marker:uint8}

// `AsyncSequence<T>` names the stream that computation(AsyncSequenceBuilder(type<T>))
// returns. ce_sequence_run declares it as its result, so the layout written
// here and the value built there cannot drift apart. Option<T> is spelled as
// its variant: a template type inside the layout would keep the name from
// matching an argument.
[template_tuple(TT)]
struct template AsyncSequence {
    tag : AsyncSequenceTag
    owner : iterator<tuple<source:iterator<tuple<tag:TaskEventTag;ready:bool;value:variant<none:void;some:TT>>>;references:int;closed:bool;cancelled:bool;busy:bool;polling:bool;error:string>?>
    element : iterator<TT>
}

// Task grouping has TaskBuilder semantics: Result/Option payloads remain data.
// Reuse its owning combinator for cooperative polling, cancellation and cleanup.
def ce_merge_sources(builder:tuple<kind:AsyncSequenceContext;element:auto>;
    var left:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(LL)>>;status:TaskStatus;value:LL;error:string;polling:bool>;
    var right:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(RR)>>;status:TaskStatus;value:RR;error:string;polling:bool>) =>
        <- task_when_all(left,right)

def AsyncSequenceBuilder(unused:type<auto(TT)>) {
    static_assert(typeinfo ce_resumable_payload(default<TT>))
    var marker:TT -const -&?
    return (kind=AsyncSequenceContext(),element=marker)
}

def ce_protocol(builder:tuple<kind:AsyncSequenceContext;element:auto(TT)?>) =>
    ce_resumable_protocol(type<tuple<tag:TaskEventTag;ready:bool;value:Option<TT>>>)
def ce_await_pending(builder:tuple<kind:AsyncSequenceContext;element:auto(TT)?>) =>
    task_pending(type<Option<TT>>)
def ce_await_yield(builder:tuple<kind:AsyncSequenceContext;element:auto(TT)?>; value:TT) {
    static_if(typeinfo can_copy(type<TT>)) {return task_ready(some(value))}
    else {
        concept_assert(false,"async sequence: move-only elements require yield <- value")
        return <- ce_await_pending(builder)
    }
}
def ce_await_yield_move(builder:tuple<kind:AsyncSequenceContext;element:auto(TT)?>; var value:TT) {
    // Use the standard Option layout without the SDK AOT tuple initializer copy.
    var item:Option<TT>
    item <- ce_move_some(value)
    return <- task_ready_move(item)
}
def private ce_async_sequence_done(unused:type<auto(TT)>) {
    var item <- move_none(type<TT>)
    return <- task_ready_move(item)
}
def ce_await_zero(builder:tuple<kind:AsyncSequenceContext;element:auto(TT)?>) =>
    <- ce_async_sequence_done(type<TT>)
def ce_await_return(builder:tuple<kind:AsyncSequenceContext;element:auto(TT)?>; value:CeUnit) =>
    <- ce_await_zero(builder)
def ce_await_return(builder:tuple<kind:AsyncSequenceContext;element:auto(TT)?>; value:auto) {
    concept_assert(false,"async sequence: emit elements with yield; only bare return is supported")
    return <- ce_await_zero(builder)
}
def ce_await_value(builder:tuple<kind:AsyncSequenceContext;element:auto>; event:tuple<tag:TaskEventTag;ready:bool;value:auto(UU)>) {
    concept_assert(typeinfo can_copy(type<UU>),"async sequence: move-only bind needs 'var value & = source |> bind'")
    return event.value
}
def ce_await_borrow_value(builder:tuple<kind:AsyncSequenceContext;element:auto>; var event:tuple<tag:TaskEventTag;ready:bool;value:auto(UU)>) : UU& {unsafe {return event.value}}
def ce_await_failed(builder:tuple<kind:AsyncSequenceContext;element:auto>; event:auto) => false
def ce_await_failure(builder:tuple<kind:AsyncSequenceContext;element:auto(TT)?>; event:auto) =>
    <- ce_await_pending(builder)

// One iterator owns both the Task and its event slot. The yielded reference
// stays valid across the entire continuation, including subsequent suspension.
def ce_await_input(builder:tuple<kind:AsyncSequenceContext;element:auto>;
    var task:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(TT)>>;status:TaskStatus;value:TT;error:string;polling:bool>) : iterator<tuple<tag:TaskEventTag;ready:bool;value:TT>&> {
    return <- generator<tuple<tag:TaskEventTag;ready:bool;value:TT>&> capture(<-task) {
        var event:tuple<tag:TaskEventTag;ready:bool;value:TT>
        while(true) {
            let status=task_poll(task)
            // A failed task fails the stream that awaits it.
            if(status==TaskStatus.Failed) {panic(task_error(task))}
            if(status==TaskStatus.Cancelled || ce_task_cancellation_requested()) {
                ce_task_cancelled()
                yield event
                return false
            }
            if(status==TaskStatus.Succeeded) {
                event.ready=true
                static_if(typeinfo can_copy(type<TT>)) {event.value=task_value(task)}
                else {event.value <- task.value}
                yield event
                break
            }
            yield event
        }
        return false
    } finally {ce_sequence_finalize($ {
        static_if(typeinfo can_delete(event)) {delete event}
        task_cancel(task)
        delete task
    })}
}

// Delegation transfers the child stream into the forwarding iterator. Never
// forward its terminal None: the enclosing producer may have more elements.
def ce_await_yield_from(builder:tuple<kind:AsyncSequenceContext;element:auto(TT)?>;
    var stream:tuple<tag:AsyncSequenceTag;owner:iterator<auto>;element:iterator<TT>>) {
    return <- generator<tuple<tag:TaskEventTag;ready:bool;value:Option<TT>>> capture(<-stream) {
        while(true) {
            var inscope request <- async_sequence_next(stream)
            while(task_poll(request)==TaskStatus.Waiting) {
                yield <- task_pending(type<Option<TT>>)
            }
            if(request.status==TaskStatus.Cancelled) {
                ce_task_cancelled()
                yield <- task_pending(type<Option<TT>>)
                return false
            }
            if(request.status==TaskStatus.Failed) {panic(request.error)}
            var inscope item <- task_take(request)
            if(item is none) {break}
            yield <- ce_await_yield_move(builder,item as some)
        }
        return false
    } finally {ce_sequence_finalize($ {ce_dispose(stream)})}
}

// The lowerer moves the payload into an iteration owner, safe to capture across
// nested awaits/resources. A signalled break never polls another next.
def ce_await_for_source(builder:tuple<kind:AsyncSequenceContext;element:auto?>;
    var stream:tuple<tag:AsyncSequenceTag;owner:iterator<auto>;element:iterator<auto(TT)>>;
    control:CeTaskLoopControl?) {
    var events <- ce_await_yield_from(AsyncSequenceBuilder(type<TT>),stream)
    return <- generator<tuple<tag:TaskEventTag;ready:bool;value:Option<TT>>> capture(<-events,copy(control)) {
        var event:tuple<tag:TaskEventTag;ready:bool;value:Option<TT>>
        while(ce_task_loop_not_broken(control)) {
            if(!ce_sequence_next_value(events,event)) {break}
            yield <- event
        }
        return false
    } finally {ce_sequence_finalize($ {
        delete event
        sequence_close(events)
    })}
}

def ce_await_for_value(builder:tuple<kind:AsyncSequenceContext;element:auto?>;
    var event:tuple<tag:TaskEventTag;ready:bool;value:Option<auto(TT)>>) : TT& {
    unsafe {return event.value as some}
}

def private ce_async_sequence_zip_check(request:auto) : bool {
    if(request.status==TaskStatus.Failed) {panic(request.error)}
    if(request.status==TaskStatus.Cancelled || ce_task_cancellation_requested()) {
        ce_task_cancelled()
        return false
    }
    return true
}

// A binary zip composes to any arity. Each round keeps one next per child,
// polls left-to-right, and stops immediately when either child reports None.
def ce_await_for_merge(builder:tuple<kind:AsyncSequenceContext;element:auto?>;
    var left:tuple<tag:AsyncSequenceTag;owner:iterator<auto>;element:iterator<auto(LL)>>;
    var right:tuple<tag:AsyncSequenceTag;owner:iterator<auto>;element:iterator<auto(RR)>>) {
    unsafe {
        if(reinterpret<void?>(ce_async_sequence_state(left))==reinterpret<void?>(ce_async_sequence_state(right))) {
            panic("async For: the same stream cannot be used twice")
        }
    }
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:Option<tuple<first:LL;second:RR>>>> capture(<-left,<-right) {
        while(true) {
            var inscope first <- async_sequence_next(left)
            var inscope second <- async_sequence_next(right)
            while(true) {
                task_poll(first)
                if(!ce_async_sequence_zip_check(first)) {
                    yield <- task_pending(type<Option<tuple<first:LL;second:RR>>>)
                    return false
                }
                if(first.status==TaskStatus.Succeeded && first.value is none) {return false}
                task_poll(second)
                if(!ce_async_sequence_zip_check(second)) {
                    yield <- task_pending(type<Option<tuple<first:LL;second:RR>>>)
                    return false
                }
                if(second.status==TaskStatus.Succeeded && second.value is none) {return false}
                if(first.status==TaskStatus.Succeeded && second.status==TaskStatus.Succeeded) {
                    var pair:tuple<first:LL;second:RR>
                    pair.first <- first.value as some
                    pair.second <- second.value as some
                    yield <- ce_await_yield_move(AsyncSequenceBuilder(type<tuple<first:LL;second:RR>>),pair)
                    break
                }
                yield <- task_pending(type<Option<tuple<first:LL;second:RR>>>)
            }
        }
        return false
    } finally {ce_sequence_finalize($ {
        ce_dispose(left)
        ce_dispose(right)
    })}
    return <- ce_sequence_run(AsyncSequenceBuilder(type<tuple<first:LL;second:RR>>),events)
}

// A next-Task owns a separate lease, never a reference into the caller's stack.
// The sequence's primary lease closes the producer even with a pending next.
def private ce_async_sequence_close(var state:auto(StateT)?; cancelled:bool) {
    if(state.closed) {return}
    state.closed=true
    state.cancelled=cancelled
    sequence_close(state.source)
}
def private ce_async_sequence_release(var state:auto(StateT)?) {
    unsafe {
        state.references--
        if(state.references==0) {delete state}
    }
}
def private ce_async_sequence_lease(var state:auto(StateT)?; primary:bool) {
    return <- generator<StateT?> capture(copy(state),copy(primary)) {
        while(true) {yield state}
        return false
    } finally {ce_sequence_finalize($ {
        if(primary) {ce_async_sequence_close(state,true)}
        ce_async_sequence_release(state)
    })}
}
// Explicit owner/Task types let nested CE bind infer their outputs immediately,
// instead of spending inference passes expanding the implementation generators.
def ce_sequence_run(builder:tuple<kind:AsyncSequenceContext;element:auto(TT)?>;
    var source:iterator<tuple<tag:TaskEventTag;ready:bool;value:Option<TT>>>) : AsyncSequence<TT> {
    unsafe {
        var state=new tuple<source:iterator<tuple<tag:TaskEventTag;ready:bool;value:Option<TT>>>;references:int;closed:bool;cancelled:bool;busy:bool;polling:bool;error:string>(source <- source,references=1)
        // Empty iterator carries T without constructing or finalizing a dummy T.
        return <- (tag=AsyncSequenceTag(),owner <- ce_async_sequence_lease(state,true),element <- default<iterator<TT>>)
    }
}
def private ce_async_sequence_state(stream:tuple<tag:AsyncSequenceTag;owner:iterator<auto(StateT)?>;element:auto>) : StateT? {
    unsafe {
        var state:StateT?
        var owner=addr<iterator<StateT?>?>(stream.owner)
        if(!next(*owner,state)) {panic("async sequence: owner has been moved or deleted")}
        return state
    }
}
def async_sequence_close(stream:tuple<tag:AsyncSequenceTag;owner:iterator<auto(StateT)?>;element:auto>) {
    var state=ce_async_sequence_state(stream)
    if(state.polling) {panic("async sequence: cannot close during producer poll")}
    ce_async_sequence_close(state,true)
}
def ce_dispose(var stream:tuple<tag:AsyncSequenceTag;owner:iterator<auto(StateT)?>;element:auto>) {
    // For/yield_from may consume a stream already registered with use_resource.
    if(!empty(stream.owner)) {async_sequence_close(stream)}
    delete stream
}
def async_sequence_next(stream:tuple<tag:AsyncSequenceTag;owner:iterator<auto(StateT)?>;element:iterator<auto(TT)>>) : tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:Option<TT>>>;status:TaskStatus;value:Option<TT>;error:string;polling:bool> {
    var state=ce_async_sequence_state(stream)
    unsafe {
        if(state.busy) {panic("async sequence: only one next may be active")}
        state.busy=true
        state.references++
        // The request generator itself owns the counted reference. Its finally
        // also runs when unopened, so a second lease iterator is unnecessary.
        var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:Option<TT>>> capture(copy(state)) {
            var delivered=false
            var event:tuple<tag:TaskEventTag;ready:bool;value:Option<TT>>
            while(true) {
                if(state.closed) {
                    if(!empty(state.error)) {panic(state.error)}
                    if(state.cancelled) {
                        ce_task_cancelled()
                        yield <- event
                        return false
                    }
                    static_if(typeinfo can_delete(event)) {delete event}
                    event <- ce_async_sequence_done(type<TT>)
                    delivered=true
                    yield <- event
                    return false
                }
                var more=false
                var message=""
                state.polling=true
                // Part of the task boundary: a producer that panics leaves a closed
                // stream with its error, so later next-Tasks have something defined to report.
                try {more=ce_sequence_next_value(state.source,event)} recover {message="{this_context().last_exception}"}
                state.polling=false
                if(!empty(message)) {
                    state.error=message
                    ce_async_sequence_close(state,false)
                    panic(message)
                }
                if(!more) {
                    static_if(typeinfo can_delete(event)) {delete event}
                    event <- ce_async_sequence_done(type<TT>)
                }
                if(event.ready) {
                    if(event.value is none) {ce_async_sequence_close(state,false)}
                    delivered=true
                    yield <- event
                    return false
                }
                yield <- event
            }
            return false
        } finally {ce_sequence_finalize($ {
            if(!delivered || ce_task_cancellation_requested()) {ce_async_sequence_close(state,true)}
            state.busy=false
            static_if(typeinfo can_delete(event)) {delete event}
            ce_async_sequence_release(state)
        })}
        return <- task_create(events)
    }
}
