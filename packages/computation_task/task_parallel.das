options gen2
module task_parallel public
require ./task_channel.das public
require ./task_delay.das public

//! Helpers for running several tasks under control: a counting semaphore, retry with a delay, the
//! first successful result, and "run them all, at most N at a time". A helper that starts or takes
//! child tasks returns a ``Task`` that owns them and cancels those still running when it ends or
//! is cancelled itself.

//! Marker field of a semaphore handle: the semaphore functions accept only what ``task_semaphore``
//! returns.
struct TaskSemaphoreTag {_ce_marker:uint8}

//! Creates a counting semaphore with ``permits`` free permits and returns the handle that owns it.
//! Tasks take a permit with ``task_semaphore_acquire`` or, for the length of a child task, with
//! ``task_with_semaphore``. Panics if ``permits`` is not positive.
def task_semaphore(permits:int) {
    var inscope channel <- task_channel(type<CeUnit>,permits)
    for(_permit in range(permits)) {verify(task_channel_try_send(channel,CeUnit()))}
    return <- (tag=TaskSemaphoreTag(),channel <- channel)
}
//! Closes the semaphore: free permits are dropped, and waiting and later ``task_semaphore_acquire``
//! tasks complete with ``err("semaphore is closed")``. A ``task_with_semaphore`` task that is still
//! waiting for a permit fails with that message.
def task_semaphore_close(semaphore:tuple<tag:TaskSemaphoreTag;channel:auto>) {task_channel_fail(semaphore.channel,"semaphore is closed")}
//! Gives back a permit taken with ``task_semaphore_acquire``; call it once per successful acquire.
//! ``task_with_semaphore`` does the acquire and the release for you. Panics if the semaphore is
//! closed or more permits are released than were taken.
def task_semaphore_release(semaphore:tuple<tag:TaskSemaphoreTag;channel:auto>) {
    if(!task_channel_try_send(semaphore.channel,CeUnit())) {panic("task semaphore: closed or released too often")}
}
//! Returns a ``Task<Result<CeUnit;string>>`` that completes with ``ok`` once it holds a permit, or
//! with ``err`` if the semaphore is closed. Waiting tasks get permits in the order of their first
//! poll. After ``ok`` the caller holds the permit and must call ``task_semaphore_release``;
//! deleting the task does not give it back.
def task_semaphore_acquire(semaphore:tuple<tag:TaskSemaphoreTag;channel:auto>) {
    var waiting <- task_channel_receive(semaphore.channel)
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:Result<CeUnit;string>>> capture(<-waiting) {
        while(true) {
            let status=task_poll(waiting)
            if(status==TaskStatus.Failed) {panic(task_error(waiting))}
            if(status==TaskStatus.Cancelled) {ce_task_cancelled();yield task_pending(type<Result<CeUnit;string>>);return false}
            if(status==TaskStatus.Succeeded) {
                if(waiting.value is err || (waiting.value as ok) is none) {yield task_ready(err("semaphore is closed",type<CeUnit>));return false}
                yield task_ready(ok(CeUnit(), type<string>));return false
            }
            yield task_pending(type<Result<CeUnit;string>>)
        }
        return false
    } finally {ce_sequence_finalize($ {ce_task_parallel_close(waiting)})}
    return <- task_create(events)
}
//! Returns a task that waits for a permit, then calls ``factory`` to create the child task, awaits
//! it and completes with its value. The permit is given back when this task ends for any reason,
//! and a child still running is cancelled. ``factory`` is moved in and is not called if no permit
//! is obtained. The task fails if the child fails or the semaphore is closed while it waits.
def task_with_semaphore(semaphore:tuple<tag:TaskSemaphoreTag;channel:auto>;var factory:lambda<():auto(ChildT)>) {
    var lease <- task_channel_clone(semaphore.channel)
    var waiting <- task_channel_receive(lease)
    var child:ChildT -const -&
    typedef Value=typedecl(child.value) -const -&
    var claimed=false
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:Value>> capture(<-lease,<-waiting,<-child,<-factory,copy(claimed)) {
        while(task_poll(waiting)!=TaskStatus.Succeeded) {
            if(waiting.status==TaskStatus.Failed) {panic(task_error(waiting))}
            if(waiting.status==TaskStatus.Cancelled) {ce_task_cancelled();yield <- task_pending(type<Value>);return false}
            yield <- task_pending(type<Value>)
        }
        if(waiting.value is err || (waiting.value as ok) is none) {panic("semaphore is closed")}
        claimed=true
        child <- invoke(factory)
        while(true) {
            let status=task_poll(child)
            if(status==TaskStatus.Failed) {panic(task_error(child))}
            if(status==TaskStatus.Cancelled) {ce_task_cancelled();yield <- task_pending(type<Value>);return false}
            if(status==TaskStatus.Succeeded) {yield <- task_ready_move(child.value);return false}
            yield <- task_pending(type<Value>)
        }
        return false
    } finally {ce_sequence_finalize($ {
        ce_task_parallel_close(child);ce_task_parallel_close(waiting)
        if(claimed) {task_channel_try_send(lease,CeUnit())}
        delete lease;unsafe {delete factory}
    })}
    return <- task_create(events)
}

//! Returns a task that calls ``factory(attempt)``, numbering attempts from 1, and awaits the
//! ``Result`` task it creates until one completes with ``ok`` or ``max_attempts`` is reached; it
//! completes with the last outcome. Between attempts it waits ``delay_ms`` of scheduler time, or one
//! poll when that is 0. Only ``err`` is retried: a child that fails or is cancelled fails or cancels
//! this task. Panics if ``max_attempts`` is not positive or ``delay_ms`` is negative.
def task_retry(var factory:lambda<(attempt:int):auto(ChildT)>;max_attempts:int;delay_ms:int64=0l) {
    if(max_attempts<=0 || delay_ms<0l) {panic("task_retry: attempts must be positive and delay non-negative")}
    typedef Outcome=typedecl(invoke(factory,1).value) -const -&
    var child:ChildT -const -&
    var pause:typedecl(task_delay_ms(delay_ms))
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:Outcome>> capture(<-factory,<-child,<-pause,copy(max_attempts),copy(delay_ms)) {
        for(index in range(max_attempts)) {
            let attempt=index+1
            child <- invoke(factory,attempt)
            while(true) {
                let status=task_poll(child)
                if(status==TaskStatus.Failed) {panic(task_error(child))}
                if(status==TaskStatus.Cancelled) {ce_task_cancelled();yield <- task_pending(type<Outcome>);return false}
                if(status==TaskStatus.Succeeded) {break}
                yield <- task_pending(type<Outcome>)
            }
            if(child.value is ok || attempt==max_attempts) {yield <- task_ready_move(child.value);return false}
            delete child
            if(delay_ms>0l) {
                pause <- task_delay_ms(delay_ms)
                while(true) {
                    let status=task_poll(pause)
                    if(status==TaskStatus.Failed) {panic(task_error(pause))}
                    if(status==TaskStatus.Cancelled) {ce_task_cancelled();yield <- task_pending(type<Outcome>);return false}
                    if(status==TaskStatus.Succeeded) {break}
                    yield <- task_pending(type<Outcome>)
                }
                delete pause
            } else {yield <- task_pending(type<Outcome>)}
        }
        return false
    } finally {ce_sequence_finalize($ {ce_task_parallel_close(child);ce_task_parallel_close(pause);unsafe {delete factory}})}
    return <- task_create(events)
}

//! Takes over ``children``, tasks with a ``Result`` value, polls them together and completes with
//! the first ``ok``. If all end with ``err`` it completes with the error of the one that ended
//! last; an empty array gives ``err("task_first_success: no candidates")``. Children still running
//! at the end are cancelled. A child that fails or is cancelled fails or cancels the whole task.
def task_first_success(var children:array<auto(ChildT)>) {
    typedef Outcome=typedecl(children[0].value) -const -&
    typedef Item=typedecl(children[0].value as ok) -const -&
    var done:array<bool>;done.resize(length(children))
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:Outcome>> capture(<-children,<-done) {
        var remaining=length(children)
        var last_error="task_first_success: no candidates"
        while(remaining>0) {
            for(i in range(length(children))) {
                if(done[i]) {continue}
                let status=task_poll(children[i])
                if(status==TaskStatus.Failed) {panic(task_error(children[i]))}
                if(status==TaskStatus.Cancelled) {ce_task_cancelled();yield <- task_pending(type<Outcome>);return false}
                if(status==TaskStatus.Succeeded) {
                    if(children[i].value is ok) {yield <- task_ready_move(children[i].value);return false}
                    last_error=children[i].value as err
                    done[i]=true;remaining--;delete children[i]
                }
            }
            if(remaining>0) {yield <- task_pending(type<Outcome>)}
        }
        var error <- move_error(last_error,type<Item>);yield <- task_ready_move(error)
        return false
    } finally {ce_sequence_finalize($ {ce_task_parallel_release(children);delete done})}
    return <- task_create(events)
}

def private ce_task_parallel_release(var children:array<auto>) {
    for(child in children) {ce_task_parallel_close(child)}
    delete children
}

//! Returns a task that calls ``factory(input)`` for every input with at most ``limit`` children
//! running at a time, and completes with their values in input order. A queued input does not
//! create its task until a slot is free. ``inputs`` and ``factory`` are moved in. A child that fails
//! or is cancelled ends the whole task the same way. Panics if ``limit`` is not positive.
def task_when_all_limited(var inputs:array<auto(InputT)>;limit:int;var factory:lambda<(input:InputT):auto(ChildT)>) {
    if(limit<=0) {panic("task_when_all_limited: limit must be positive")}
    typedef Item=typedecl(invoke(factory,inputs[0]).value) -const -&
    var values:array<Item>;values.resize(length(inputs))
    var children:array<ChildT -const -&>;children.resize(length(inputs))
    var states:array<int>;states.resize(length(inputs))
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:array<Item>>> capture(<-inputs,<-factory,<-children,<-states,<-values,copy(limit)) {
        var next_index=0;var active=0;var completed=0
        while(completed<length(inputs)) {
            while(active<limit && next_index<length(inputs)) {
                children[next_index] <- invoke(factory,inputs[next_index]);states[next_index]=1
                active++;next_index++
            }
            for(i in range(next_index)) {
                if(states[i]!=1) {continue}
                let status=task_poll(children[i])
                if(status==TaskStatus.Failed) {panic(task_error(children[i]))}
                if(status==TaskStatus.Cancelled) {ce_task_cancelled();yield <- task_pending(type<array<Item>>);return false}
                if(status==TaskStatus.Succeeded) {
                    values[i] <- children[i].value
                    delete children[i];states[i]=2;active--;completed++
                }
            }
            if(completed<length(inputs)) {yield <- task_pending(type<array<Item>>)}
        }
        yield <- task_ready_move(values)
        return false
    } finally {ce_sequence_finalize($ {ce_task_parallel_release(children);delete inputs;delete states;delete values;unsafe {delete factory}})}
    return <- task_create(events)
}

//! Like ``task_when_all_limited`` for children with a ``Result`` value: completes with ``ok`` of
//! the unwrapped values in input order, or with the first ``err`` a child returns. On that ``err``
//! the children still running are cancelled and the queued inputs never create a task.
def task_result_when_all_limited(var inputs:array<auto(InputT)>;limit:int;var factory:lambda<(input:InputT):auto(ChildT)>) {
    if(limit<=0) {panic("task_result_when_all_limited: limit must be positive")}
    typedef Item=typedecl(invoke(factory,inputs[0]).value as ok) -const -&
    var values:array<Item>;values.resize(length(inputs))
    var children:array<ChildT -const -&>;children.resize(length(inputs))
    var states:array<int>;states.resize(length(inputs))
    var events <- generator<tuple<tag:TaskEventTag;ready:bool;value:Result<array<Item>;string>>> capture(<-inputs,<-factory,<-children,<-states,<-values,copy(limit)) {
        var next_index=0;var active=0;var completed=0
        while(completed<length(inputs)) {
            while(active<limit && next_index<length(inputs)) {
                children[next_index] <- invoke(factory,inputs[next_index]);states[next_index]=1
                active++;next_index++
            }
            for(i in range(next_index)) {
                if(states[i]!=1) {continue}
                let status=task_poll(children[i])
                if(status==TaskStatus.Failed) {panic(task_error(children[i]))}
                if(status==TaskStatus.Cancelled) {ce_task_cancelled();yield <- task_pending(type<Result<array<Item>;string>>);return false}
                if(status==TaskStatus.Succeeded) {
                    if(children[i].value is err) {
                        var error <- move_error(children[i].value as err,type<array<Item>>)
                        yield <- task_ready_move(error);return false
                    }
                    values[i] <- children[i].value as ok
                    delete children[i];states[i]=2;active--;completed++
                }
            }
            if(completed<length(inputs)) {yield <- task_pending(type<Result<array<Item>;string>>)}
        }
        var result <- move_ok(values);yield <- task_ready_move(result)
        return false
    } finally {ce_sequence_finalize($ {ce_task_parallel_release(children);delete inputs;delete states;delete values;unsafe {delete factory}})}
    return <- task_create(events)
}

def private ce_task_parallel_close(var child:auto) {
    task_cancel(child)
    delete child
}
