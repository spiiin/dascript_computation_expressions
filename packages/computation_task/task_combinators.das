options gen2
module task_combinators public
require ./task_builder.das public
require daslib/rtti

//! Combinators that wait for several tasks at once: ``task_when_all`` and ``task_result_when_all``
//! complete when every task has, ``task_race`` and ``task_result_race`` when the first one has, and
//! ``task_map_error`` changes the error type of a task. They take ownership of their tasks and poll
//! them cooperatively inside the parent's poll. The module also makes
//! ``left |> and_bind(right) |> bind`` await two tasks together.

//! Selects the plain behaviour of the pair combinator: ``task_when_all`` waits for both values,
//! whatever they hold.
struct TaskAllPolicy {_ce_marker:uint8}
//! Selects the ``Result`` behaviour of the pair combinator: ``task_result_when_all`` stops at the
//! first ``err``.
struct TaskResultAllPolicy {_ce_marker:uint8}

// Resumable CE uses the same source grouping protocol as eager builders.
// The pair combinators consume owners and poll left-to-right cooperatively.
def ce_merge_sources(builder:tuple<kind:TaskContext;element:auto>;
    var left:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(CeTaskMergeLeft)>>;status:TaskStatus;value:CeTaskMergeLeft;error:string;polling:bool>;
    var right:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(CeTaskMergeRight)>>;status:TaskStatus;value:CeTaskMergeRight;error:string;polling:bool>) =>
        <- task_when_all(left,right)

// Match the whole payload, rather than a nested variant pattern: the 0.6.4
// compiler crashes on that pattern when a Result contains a grouped pair.
def ce_merge_sources(builder:tuple<kind:TaskResultContext;element:auto>;
    var left:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(CeTaskMergeLeft)>>;status:TaskStatus;value:CeTaskMergeLeft;error:string;polling:bool>;
    var right:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(CeTaskMergeRight)>>;status:TaskStatus;value:CeTaskMergeRight;error:string;polling:bool>) =>
        <- task_result_when_all(left,right)
def ce_merge_sources(builder:tuple<kind:TaskResultErrorContext;element:auto;error:auto(EE)?>;
    var left:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(CeTaskMergeLeft)>>;status:TaskStatus;value:CeTaskMergeLeft;error:string;polling:bool>;
    var right:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:auto(CeTaskMergeRight)>>;status:TaskStatus;value:CeTaskMergeRight;error:string;polling:bool>) =>
        <- task_result_when_all(left,right)

// Owning array results use the same Task representation as any other payload.
def private task_array_store(var target:auto(TargetT)&; var child:auto) {
    static_if(typeinfo can_copy(target)) {target=task_value(child)}
    else {target <- child.value}
}

//! Moves an array of tasks into one ``Task<array<T>>`` whose value keeps the order of the tasks.
//! Each poll of the parent polls every unfinished child once, in order. A child that fails fails the
//! parent with its error, and a cancelled child cancels it. When the parent ends, the children that
//! are still running are cancelled and all of them are released. Panics if a child is being polled.
def task_when_all(var children:array<auto(CC)>) {
    typedef ArrayValue=typedecl(children[0].value) -const -&
    static_assert(typeinfo ce_resumable_payload(default<ArrayValue>))
    for(i in range(length(children))) {if(ce_task_is_polling(children[i])) {panic("task_when_all array: cannot move a task being polled")}}
    var values:array<ArrayValue>
    values.resize(length(children))
    for(i in range(length(children))) {
        if(task_status(children[i])==TaskStatus.Succeeded) {task_array_store(values[i],children[i])}
    }
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:array<ArrayValue>>> capture(<-children,<-values) {
        while(true) {
            var complete=true
            for(i in range(length(children))) {
                if(task_status(children[i])==TaskStatus.Succeeded) {continue}
                let status=task_poll(children[i])
                if(!task_check_child(status,task_error(children[i]))) {
                    yield <- task_pending(type<array<ArrayValue>>)
                    return false
                }
                if(status==TaskStatus.Succeeded) {task_array_store(values[i],children[i])}
                else {complete=false}
            }
            if(complete) {yield <- task_ready_move(values);return false}
            yield <- task_pending(type<array<ArrayValue>>)
        }
        return false
    } finally {ce_sequence_finalize($ {task_release_array(children);delete values})}
    return <- task_create(events)
}

def private task_release_array(var children:array<auto>) {
    for(child in children) {task_release_child(child)}
    delete children
}

def private task_pair_shape(policy:TaskAllPolicy; left:auto(AA);right:auto(BB)) =>
    <- (first <- default<AA -const -&>,second <- default<BB -const -&>)
// The Result policy holds for any error type; both tasks fail with the same one.
def private task_pair_shape(policy:TaskResultAllPolicy;
    left:variant<err:auto(EE);ok:auto(AA)>;right:variant<err:auto(FF);ok:auto(BB)>) {
    static_if (typeinfo stripped_typename(type<EE>) != typeinfo stripped_typename(type<FF>)) {
        concept_assert(false, "task_result_when_all: the tasks fail with {typeinfo stripped_typename(type<EE>)} and {typeinfo stripped_typename(type<FF>)}; give them one error type with task_map_error(task, @@convert)")
    }
    var pair <- (first <- default<AA -const -&>,second <- default<BB -const -&>)
    return <- ce_move_ok(pair,type<EE>)
}

def private task_pair_value(policy:TaskAllPolicy; var left:auto; var right:auto) =>
    <- (first <- left,second <- right)
def private task_pair_value(policy:TaskResultAllPolicy;
    var left:variant<err:auto(EE);ok:auto(AA)>; var right:variant<err:auto(FF);ok:auto(BB)>) {
    var pair <- (first <- left as ok,second <- right as ok)
    return <- ce_move_ok(pair,type<EE>)
}

def private task_pair_stops(policy:TaskAllPolicy; value:auto) => false
def private task_pair_stops(policy:TaskResultAllPolicy; value:variant<err:auto(EE);ok:auto(TT)>) =>
    value is err
def private task_pair_error(policy:TaskAllPolicy; value:auto; unused:type<auto(TT)>) {var result:TT -const -&;return <- result}
def private task_pair_error(policy:TaskResultAllPolicy; value:variant<err:auto(EE);ok:auto(TT)>; unused:type<auto(RR)>) {
    var result:RR -const -& = variant type<RR -const -&>(err=value as err)
    return <- result
}

// Both arguments are consuming owners. Aliases must be rejected before moving.
def private task_check_distinct(var left:auto; var right:auto) {
    unsafe {
        if(addr<void?>(left)==addr<void?>(right)) {
            panic("task composition: the same owner cannot be passed twice")
        }
    }
}
def private task_check_child(status:TaskStatus; error:string) : bool {
    if(status==TaskStatus.Failed) {panic(error)}
    if(status==TaskStatus.Cancelled || ce_task_cancellation_requested()) {ce_task_cancelled();return false}
    return true
}
def private task_release_child(var task:auto) {
    task_cancel(task)
    delete task
}
def private task_release_pair(var left:auto; var right:auto) {
    task_release_child(left)
    task_release_child(right)
}

def private task_pair_pending(policy:auto; left:auto; right:auto) =>
    <- task_pending(type<typedecl(task_pair_shape(policy,left,right)) -const -&>)
def private task_pair(var left:auto(LL); var right:auto(RR); policy:auto(PP)) {
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:typedecl(task_pair_shape(policy,left.value,right.value)) -const -&>> capture(<-left,<-right) {
        while(true) {
            let first=task_poll(left)
            if(!task_check_child(first,task_error(left))) {yield <- task_pair_pending(policy,left.value,right.value);return false}
            if(first==TaskStatus.Succeeded && task_pair_stops(policy,left.value)) {
                var error <- task_pair_error(policy,left.value,type<typedecl(task_pair_shape(policy,left.value,right.value)) -const -&>);yield <- task_ready_move(error)
                return false
            }
            let second=task_poll(right)
            if(!task_check_child(second,task_error(right))) {yield <- task_pair_pending(policy,left.value,right.value);return false}
            if(second==TaskStatus.Succeeded && task_pair_stops(policy,right.value)) {
                var error <- task_pair_error(policy,right.value,type<typedecl(task_pair_shape(policy,left.value,right.value)) -const -&>);yield <- task_ready_move(error)
                return false
            }
            if(first==TaskStatus.Succeeded && second==TaskStatus.Succeeded) {
                var value <- task_pair_value(policy,left.value,right.value);yield <- task_ready_move(value)
                return false
            }
            yield <- task_pair_pending(policy,left.value,right.value)
        }
        return false
    } finally {ce_sequence_finalize($ {task_release_pair(left,right)})}
    return <- task_create(events)
}

//! Waits for two tasks of any types and returns a ``Task<tuple<first:A;second:B>>``. Each poll of
//! the parent polls each unfinished child at most once, left to right. A ``Task`` argument is moved
//! in; a ``TaskShared`` handle is cloned and stays with the caller. Failure, cancellation and release
//! of the children are as in the array form. Panics when the same owner is passed twice.
def task_when_all(var left:auto(LL); var right:auto(RR)) {
    task_check_distinct(left,right)
    var inscope first <- ce_task_source(left)
    var inscope second <- ce_task_source(right)
    return <- task_pair(first,second,TaskAllPolicy())
}
//! ``task_when_all`` for two tasks that produce a ``Result``: returns a
//! ``Task<Result<tuple<first:A;second:B>;E>>``. The first child to finish with ``err`` completes the
//! parent with that error, and the other child is cancelled. A ``Task<CeUnit>`` child counts as ``ok``.
//! Both tasks must fail with the same type; ``task_map_error`` converts one that does not.
def task_result_when_all(var left:auto(LL); var right:auto(RR)) {
    task_check_distinct(left,right)
    var inscope first <- ce_task_source(left)
    var inscope second <- ce_task_source(right)
    var fault:typedecl(ce_task_fault(first.value,second.value))
    var inscope a <- ce_task_result_source(first,fault)
    var inscope b <- ce_task_result_source(second,fault)
    return <- task_pair(a,b,TaskResultAllPolicy())
}

// The error type of a group of tasks, as a null marker: a task without a
// result of its own (Task<CeUnit>) fails with whatever its neighbour does.
def private ce_task_fault(value:variant<err:auto(EE);ok:auto(TT)>) : EE -const -&? => null
def private ce_task_fault(_value:CeUnit) : string? => null
def private ce_task_fault(left:variant<err:auto(EE);ok:auto(TT)>; right:auto) : EE -const -&? => null
def private ce_task_fault(left:CeUnit; right:auto) : typedecl(ce_task_fault(right)) => null

def private ce_task_result_source(var source:auto; fault:auto) => <- source
def private ce_task_result_source(var source:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:CeUnit>>;status:TaskStatus;value:CeUnit;error:string;polling:bool>; fault:auto(EE)?) {
    var stream <- ce_await_source(TaskBuilder(type<CeUnit>),source)
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:Result<CeUnit;EE>>> capture(<-stream) {
        for(event in stream) {
            if(event.ready) {yield task_ready(result::ok(CeUnit(),type<EE>));return false}
            yield task_pending(type<Result<CeUnit;EE>>)
        }
        return false
    } finally {ce_sequence_finalize($ {sequence_close(stream)})}
    return <- task_create(events)
}

//! The array form: moves an array of tasks, or of ``TaskShared`` handles, into a
//! ``Task<Result<array<T>;E>>``. Its value is ``ok`` with the values in the order of the tasks, or the
//! first ``err`` that a child finishes with. Panics if a child is being polled.
def task_result_when_all(var children:array<auto(CC)>) {
    for(i in range(length(children))) {if(ce_task_is_polling(children[i])) {panic("task_result_when_all: cannot move a task being polled")}}
    var fault:typedecl(ce_task_fault(ce_task_source(children[0]).value))
    var inscope sources:array<typedecl(ce_task_result_source(ce_task_source(children[0]),fault))>
    for(i in range(length(children))) {
        var task <- ce_task_source(children[i])
        sources |> emplace(ce_task_result_source(task,fault))
    }
    delete children
    return <- ce_task_result_array(sources)
}

def private ce_task_result_array(var children:array<auto(CC)>) {
    typedef ResultItem=typedecl(children[0].value as ok) -const -&
    typedef Fault=typedecl(children[0].value as err) -const -&
    var values:array<ResultItem>
    var done:array<bool>
    values.resize(length(children));done.resize(length(children))
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:Result<array<ResultItem>;Fault>>> capture(<-children,<-values,<-done) {
        while(true) {
            var complete=true
            for(i in range(length(children))) {
                if(done[i]) {continue}
                let status=task_poll(children[i])
                if(!task_check_child(status,task_error(children[i]))) {
                    yield <- task_pending(type<Result<array<ResultItem>;Fault>>);return false
                }
                if(status==TaskStatus.Succeeded) {
                    if(children[i].value is err) {
                        var error <- result::err(children[i].value as err,type<array<ResultItem>>)
                        yield <- task_ready_move(error);return false
                    }
                    values[i] <- children[i].value as ok
                    done[i]=true
                } else {complete=false}
            }
            if(complete) {var result <- ce_move_ok(values,type<Fault>);yield <- task_ready_move(result);return false}
            yield <- task_pending(type<Result<array<ResultItem>;Fault>>)
        }
        return false
    } finally {ce_sequence_finalize($ {task_release_array(children);delete values;delete done})}
    return <- task_create(events)
}

//! The same as ``task_when_all`` of an array of tasks for an array of ``TaskShared<T>`` handles: the
//! array is consumed, and each shared task stays with its other holders.
def task_when_all(var children:array<tuple<tag:TaskSharedTag;owner:iterator<auto(ShareStateT)?>>>) {
    var inscope sources:array<typedecl(ce_task_source(children[0]))>
    for(i in range(length(children))) {sources |> emplace(ce_task_source(children[i]))}
    delete children
    return <- task_when_all(sources)
}

//! ``task_race`` for two tasks that produce a ``Result``: returns a
//! ``Task<Result<tuple<index:int;value:T>;E>>``. The first child to finish decides: its ``ok`` value
//! comes with its ``index`` (0 for ``left``, 1 for ``right``), and its ``err`` becomes the error of
//! the race. The other child is cancelled.
def task_result_race(var left:auto;var right:auto) {
    task_check_distinct(left,right)
    var inscope first <- ce_task_source(left)
    var inscope second <- ce_task_source(right)
    var fault:typedecl(ce_task_fault(first.value,second.value))
    var inscope a <- ce_task_result_source(first,fault)
    var inscope b <- ce_task_result_source(second,fault)
    typedef RaceValue=typedecl(a.value as ok) -const -&
    typedef RaceFault=typedecl(a.value as err) -const -&
    typedef RacePayload=tuple<index:int;value:RaceValue>
    var raced <- task_race(a,b)
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:Result<RacePayload;RaceFault>>> capture(<-raced) {
        while(true) {
            let status=task_poll(raced)
            if(!task_check_child(status,task_error(raced))) {
                yield <- task_pending(type<Result<RacePayload;RaceFault>>);return false
            }
            if(status==TaskStatus.Succeeded) {
                if(raced.value.value is err) {
                    var error <- result::err(raced.value.value as err,type<RacePayload>)
                    yield <- task_ready_move(error);return false
                }
                var pair <- (index=raced.value.index,value <- raced.value.value as ok)
                var result <- ce_move_ok(pair,type<RaceFault>)
                yield <- task_ready_move(result);return false
            }
            yield <- task_pending(type<Result<RacePayload;RaceFault>>)
        }
        return false
    } finally {ce_sequence_finalize($ {task_release_child(raced)})}
    return <- task_create(events)
}

//! Gives a task's error another type: returns a ``Task<Result<T;E>>`` that awaits ``task``, which is
//! moved in, and passes its ``err`` through ``convert``. A task that fails with a string, as the
//! library's own sources do, can then be bound in a computation that fails with ``E``:
//! ``task_map_error(fetch(id), @@classify) |> bind``.
[task]
def task_map_error(var task:tuple<tag:TaskTag;source:iterator<tuple<tag:TaskEventTag;ready:bool;value:variant<err:auto(FF);ok:auto(TT)>>>;status:TaskStatus;value:variant<err:FF;ok:TT>;error:string;polling:bool>;
                   convert:function<(FF):auto(EE)>) : Result<TT;EE> {
    let outcome = task |> bind
    if (outcome is err) {
        return result::err(invoke(convert, outcome as err), type<TT>)
    }
    return result::ok(outcome as ok, type<EE>)
}

// First terminal child wins. A tie is won by the left child without polling right.
// Native faults fail the parent; cancelled children cancel it. Losers are closed.
def private task_race_impl(var left,right:auto(TT)) {
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:tuple<index:int;value:typedecl(left.value) -const -&>>> capture(<-left,<-right) {
        while(true) {
            let first=task_poll(left)
            if(!task_check_child(first,task_error(left))) {
                yield <- task_pending(type<tuple<index:int;value:typedecl(left.value) -const -&>>)
                return false
            }
            if(first==TaskStatus.Succeeded) {var value <- (index=0,value <- left.value);yield <- task_ready_move(value);return false}
            let second=task_poll(right)
            if(!task_check_child(second,task_error(right))) {
                yield <- task_pending(type<tuple<index:int;value:typedecl(left.value) -const -&>>)
                return false
            }
            if(second==TaskStatus.Succeeded) {var value <- (index=1,value <- right.value);yield <- task_ready_move(value);return false}
            yield <- task_pending(type<tuple<index:int;value:typedecl(left.value) -const -&>>)
        }
        return false
    } finally {ce_sequence_finalize($ {task_release_pair(left,right)})}
    return <- task_create(events)
}
//! Returns a ``Task<tuple<index:int;value:T>>`` that completes with the first of two tasks of the
//! same type to succeed; ``index`` is 0 for ``left`` and 1 for ``right``, and ``left`` wins a tie.
//! A child that fails fails the race, and a cancelled child cancels it. The loser is cancelled and
//! released. Arguments are taken as in ``task_when_all``; panics when the same owner is passed twice.
def task_race(var left,right:auto(TT)) {
    task_check_distinct(left,right)
    var inscope first <- ce_task_source(left)
    var inscope second <- ce_task_source(right)
    return <- task_race_impl(first,second)
}
