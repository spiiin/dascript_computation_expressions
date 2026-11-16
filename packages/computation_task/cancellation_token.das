options gen2
module cancellation_token public
require ../computation/sequence_runtime.das public

//! Cooperative cancellation shared between tasks. A ``CancellationToken`` is a counted handle to one
//! request flag: ``cancellation_cancel`` sets it, and a task polled under the token
//! (``task_with_cancellation``) becomes cancelled at its next poll. A child token cancels a part of
//! the work, and a view observes a token without being able to cancel it. ``task_builder`` requires
//! this module publicly.

// parent is a counted lease: a child keeps its ancestors alive and observes them.
struct CeCancellationState {references:uint64;requested:bool;reason:string;parent:CeCancellationState?}
//! A handle to shared cancellation state. Handles are counted: ``cancellation_clone`` or ``:=`` adds
//! one, deleting a handle releases it, and the state is freed with the last one. A ``read_only``
//! handle observes the token but cannot request cancellation. Using a handle that was moved from
//! or deleted panics.
struct CancellationToken {owners:array<CeCancellationState?>;read_only:bool}

def private cancellation_check(token:CancellationToken) {
    if(length(token.owners)!=1) {panic("cancellation token: handle was moved or deleted")}
}
//! Returns a new token that has not been cancelled. The caller owns the handle and deletes it when
//! it is no longer needed.
def cancellation_token() : CancellationToken {
    var inscope token:CancellationToken
    token.owners |> push(new CeCancellationState(references=uint64(1)))
    return <- token
}
def private cancellation_lease(var state:CeCancellationState?) {
    if(state.references==uint64(-1)) {panic("cancellation token: reference count exhausted")}
    state.references++
}
def private cancellation_release(var state:CeCancellationState?) {
    var current=state
    while(current!=null) {
        current.references--
        if(current.references!=uint64(0)) {break}
        var parent=current.parent
        current.parent=null
        delete current
        current=parent
    }
}
//! Returns another handle to the same state, read-only if ``token`` is. A request made through one
//! handle is seen through all of them.
def cancellation_clone(token:CancellationToken) : CancellationToken {
    cancellation_check(token)
    var inscope result:CancellationToken
    var state=unsafe(reinterpret<CeCancellationState?>(token.owners[0]))
    cancellation_lease(state)
    result.owners |> push(state)
    result.read_only=token.read_only
    return <- result
}
//! Returns a child token: it is cancelled by its own request or by a request on any ancestor.
//! Cancelling a child never cancels its parent. The child keeps the state of its ancestors alive.
def cancellation_child(parent:CancellationToken) : CancellationToken {
    cancellation_check(parent)
    var inscope result:CancellationToken
    var parent_state=unsafe(reinterpret<CeCancellationState?>(parent.owners[0]))
    cancellation_lease(parent_state)
    result.owners |> push(new CeCancellationState(references=uint64(1),parent=parent_state))
    return <- result
}
//! Returns an observer handle to the same state: ``cancellation_requested`` and
//! ``cancellation_reason`` work on it, ``cancellation_cancel`` panics.
def cancellation_view(token:CancellationToken) : CancellationToken {
    var inscope result <- cancellation_clone(token)
    result.read_only=true
    return <- result
}
//! Returns true for a handle made by ``cancellation_view``, or cloned from one.
def cancellation_is_read_only(token:CancellationToken) : bool {
    cancellation_check(token)
    return token.read_only
}
def private cancellation_requested_state(state:CeCancellationState?) : CeCancellationState const? {
    var current:CeCancellationState const?=state
    while(current!=null) {
        if(current.requested) {return current}
        current=current.parent
    }
    return null
}
//! Returns true once this token or one of its ancestors has been cancelled.
def cancellation_requested(token:CancellationToken) : bool {
    cancellation_check(token)
    return cancellation_requested_state(token.owners[0])!=null
}
//! Returns the reason of the nearest cancelled state, the token's own first and then its ancestors',
//! or an empty string while none of them is cancelled.
def cancellation_reason(token:CancellationToken) : string {
    cancellation_check(token)
    let state=cancellation_requested_state(token.owners[0])
    return state!=null ? state.reason : ""
}
//! Requests cancellation with a reason: tasks polled under the token or under its children observe
//! it at their next poll. Returns false when this token itself was already cancelled, and keeps the
//! first reason. A request that came only from an ancestor still lets the child record its own reason.
//! Panics on a read-only view. Without ``reason`` the reason is ``"cancelled"``.
def cancellation_cancel(token:CancellationToken;reason:string) : bool {
    cancellation_check(token)
    if(token.read_only) {panic("cancellation token: read-only view cannot cancel")}
    var state=unsafe(reinterpret<CeCancellationState?>(token.owners[0]))
    if(state.requested) {return false}
    state.requested=true
    state.reason=reason
    return true
}
def cancellation_cancel(token:CancellationToken) : bool => cancellation_cancel(token,"cancelled")
//! Makes ``destination := source`` share the state of ``source``; the handle that ``destination``
//! held is released.
def clone(var destination:CancellationToken; source:CancellationToken) {
    var inscope next <- cancellation_clone(source)
    delete destination
    destination <- next
}
//! Releases the handle when it is deleted. The shared state is freed once its last handle and its
//! last child token are gone.
def finalize(var token:CancellationToken) {
    ce_sequence_finalize($ {
        unsafe {
            if(!empty(token.owners)) {
                cancellation_release(token.owners[0])
                // delete array<pointer> also deletes its non-null elements.
                // This array owns a lease, not the shared state exclusively.
                token.owners[0]=null
            }
            delete token.owners
        }
    })
}

// Borrowed only across a synchronous poll call, never across a yield.
var private cancellation_scopes:array<CancellationToken const?>

// Cancelling one shared waiter must not cancel the shared producer. A producer
// can still install its own explicit token inside this isolated synchronous poll.
def ce_cancellation_isolate(action:block<():void>) {
    var saved <- cancellation_scopes
    invoke(action)
    // The scopes are borrowed const tokens, so the array cannot be deleted:
    // its storage is freed by hand before the saved scopes move back.
    cancellation_scopes.resize(0)
    __builtin_array_free(cancellation_scopes,typeinfo sizeof(cancellation_scopes[0]))
    cancellation_scopes <- saved   // nolint:PERF030 - the old storage is freed on the line above
}
def ce_task_cancellation_requested() : bool {
    for(token in cancellation_scopes) {if(cancellation_requested(*token)) {return true}}
    return false
}
def ce_cancellation_scope(token:CancellationToken; action:block<():void>) {
    let depth=length(cancellation_scopes)
    cancellation_scopes |> push(unsafe(addr(token)))
    invoke(action)
    cancellation_scopes.resize(depth)
}
