options gen2
module deferred_runtime public
require ./sequence_runtime.das public

//! Runtime of deferred computations: ``run_deferred`` and the value that ``deferred`` returns.
//! ``deferred_computation`` requires it publicly; require that module, not this one.

//! Marker of the value that ``deferred`` returns: a tuple ``(kind, owner)`` that owns the saved builder,
//! data and body. The value is move-only; deleting it, or the end of its ``var inscope``, releases them.
struct DeferredComputation {_ce_marker:uint8}
struct CeDeferredValueBuilder {_ce_marker:uint8}
struct CeDeferredTypeBuilder {_ce_marker:uint8}
struct CeDeferredMovedBuilder {_ce_marker:uint8}
def private ce_deferred_copy_builder(var target:auto; source:auto; policy:CeDeferredValueBuilder) {target := source}
// The macro checks that this built-in phantom descriptor contains only null.
def private ce_deferred_copy_builder(var target:auto; source:auto; policy:CeDeferredTypeBuilder) {target.element = null}
// Any other phantom descriptor: its pointers are null, as a fresh target's are.
def private ce_deferred_copy_builder(var target:auto; source:auto; policy:CeDeferredMovedBuilder) {}

def private ce_deferred_finish(var result:auto;var frame:auto?;policy:auto) {
    unsafe {delete frame}
    return <- result
}
// A moved result may go on running after this call returns, as a task does.
// ce_deferred_keep(result, cleanup) is its hook: it makes the result the owner
// of `cleanup`, which deletes the frame, and runs it when the result is done.
def private ce_deferred_finish(var result:auto;var frame:auto?;policy:CeDeferredMovedBuilder) {
    var cleanup <- @ capture(move(frame)) {unsafe {delete frame}}
    // `_::` looks the hook up where the computation is written: the module of
    // the result is visible there, and is not from here.
    _::ce_deferred_keep(result,cleanup)
    return <- result
}
// Without the hook the result is complete, and the frame goes at once.
def ce_deferred_keep(var result:auto; var cleanup:lambda<():void>) {
    invoke(cleanup)
    unsafe {delete cleanup}
}


def private ce_deferred_delete(var value:auto) {
    static_if (typeinfo can_delete(value)) { delete value }
}

def private ce_deferred_hold(var body:lambda<():auto(RR)>) {
    var owner <- generator<lambda<():RR>> capture(<-body) {
        while (true) { yield body }
        return false
    } finally { ce_sequence_finalize($ { unsafe { delete body } }) }
    return <- (kind=DeferredComputation(),owner <- owner)
}

def ce_deferred_create(builder:auto(BB); data:auto(EE); body:function<(frame:tuple<marker:int;builder:BB -const -&;value:EE -const -&>?):auto(RR)>; policy:auto(PP)) {
    var savedBuilder=default<BB -const -&>
    var savedData=default<EE -const -&>
    ce_deferred_copy_builder(savedBuilder,builder,policy); savedData := data
    var thunk <- @ capture(move(savedBuilder),move(savedData),copy(body)) : RR { {
        var frame = new tuple<marker:int;builder:BB -const -&;value:EE -const -&>()
        static_if (typeinfo is_iterator(type<RR>)) {
            var source:RR
            ce_deferred_copy_builder(frame.builder,savedBuilder,default<PP>)
            frame.value := savedData
            source <- invoke(body,frame)
            // The child closes before cleanup so its resource finalizers can
            // still access the snapshot. The pointer is moved into its owner.
            var cleanup <- @ capture(move(frame)) { unsafe { delete frame } }
            return <- ce_deferred_wrap_sequence(source,cleanup)
        } static_elif (typeinfo can_copy(type<RR>)) {
            var result=default<RR>
            ce_deferred_copy_builder(frame.builder,savedBuilder,default<PP>); frame.value := savedData; result=invoke(body,frame)
            unsafe { delete frame }
            return result
        } else {
            var inscope result:RR
            ce_deferred_copy_builder(frame.builder,savedBuilder,default<PP>); frame.value := savedData; result <- invoke(body,frame)
            return <- ce_deferred_finish(result,frame,policy)
        }
    } } finally { ce_deferred_delete(savedData); ce_deferred_delete(savedBuilder) }
    return <- ce_deferred_hold(thunk)
}

//! Runs a deferred computation once and returns its outcome. Every run works on a fresh copy of the
//! saved builder and data, so ``task`` stays valid and can be run again. An iterator outcome owns its
//! copy until it is closed. Panics if ``task`` has been moved from or deleted.
def run_deferred(var task:tuple<kind:DeferredComputation;owner:iterator<lambda<():auto(RR)>>>) : RR {
    var body:lambda<():RR>
    if (!next(task.owner,body)) { panic("deferred: computation has been moved or disposed") }
    static_if (typeinfo can_copy(type<RR>)) { return invoke(body) }
    else { return <- invoke(body) }
}

// Keep the run snapshot alive behind a reference-yielding owning-slot iterator.
// Close the child (including its current element) before deleting the frame.
def private ce_deferred_reference_close(var state:tuple<source:iterator<auto(TT)>;cleanup:lambda<():void>;closed:bool>) {
    if (state.closed) {return}
    state.closed=true
    ce_sequence_close_scope(state.source,state.cleanup)
}
def ce_deferred_reference_scope(var source:iterator<auto(TT)&>; var cleanup:lambda<():void>) : iterator<TT&> {
    var state <- (source <- source,cleanup <- cleanup,closed=false)
    return <- generator<TT&> capture(<-state) {
        var slot:TT -&?
        while (true) {
            var more=false
            unsafe {more=_builtin_iterator_iterate(state.source,addr(slot))}
            if (!more) {ce_deferred_reference_close(state);break}
            yield *slot
        }
        return false
    } finally {ce_sequence_finalize($ {ce_deferred_reference_close(state)})}
}

// A source that owns `cleanup`: it runs once the source is closed or exhausted.
def ce_deferred_wrap_sequence(var source:iterator<auto(TT)>; var cleanup:lambda<():void>) {
    static_if (typeinfo is_ref_value(type<TT>)) {
        return <- ce_deferred_reference_scope(source,cleanup)
    } else {
        var scoped <- ce_sequence_scoped(source,cleanup)
        return <- ce_sequence_protect(scoped)
    }
}

// Preserve the existing low-level entry point for ordinary value builders.
def ce_deferred_create(builder:auto; data:auto; body:auto) =>
    <- ce_deferred_create(builder,data,body,CeDeferredValueBuilder())
