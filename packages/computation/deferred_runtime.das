options gen2
module deferred_runtime public
require ./sequence_runtime.das public

struct DeferredComputation {_ce_marker:uint8}
struct CeDeferredValueBuilder {_ce_marker:uint8}
struct CeDeferredTypeBuilder {_ce_marker:uint8}
struct CeDeferredTaskBuilder {_ce_marker:uint8}
struct CeDeferredAsyncSequenceBuilder {_ce_marker:uint8}
def private ce_deferred_copy_builder(var target:auto; source:auto; policy:CeDeferredValueBuilder) {target := source}
// The macro checks that this built-in phantom descriptor contains only null.
def private ce_deferred_copy_builder(var target:auto; source:auto; policy:CeDeferredTypeBuilder) {target.element = null}
def private ce_deferred_copy_builder(var target:auto; source:auto; policy:CeDeferredTaskBuilder) {target.element = null}
def private ce_deferred_copy_builder(var target:auto; source:auto; policy:CeDeferredAsyncSequenceBuilder) {target.element = null}

def private ce_deferred_finish(var result:auto;var frame:auto?;policy:auto) {
    unsafe {delete frame}
    return <- result
}
def private ce_deferred_finish(var result:auto;var frame:auto?;policy:CeDeferredTaskBuilder) {
    var cleanup <- @ capture(move(frame)) {unsafe {delete frame}}
    result.source <- ce_deferred_wrap_sequence(result.source,cleanup)
    return <- result
}
def private ce_deferred_finish(var result:tuple<tag:auto;owner:iterator<auto(StateT)?>;element:auto>;var frame:auto?;policy:CeDeferredAsyncSequenceBuilder) {
    var cleanup <- @ capture(move(frame)) {unsafe {delete frame}}
    // The producer owns the frame across all next-Tasks; its finalizers run
    // before cleanup, even if the primary lease closes while next is pending.
    var state:StateT?
    if(!next(result.owner,state)) {panic("deferred: AsyncSequence owner is closed")}
    unsafe {state.source <- ce_deferred_wrap_sequence(state.source,cleanup)}
    return <- result
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

def private ce_deferred_wrap_sequence(var source:iterator<auto(TT)>; var cleanup:lambda<():void>) {
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
