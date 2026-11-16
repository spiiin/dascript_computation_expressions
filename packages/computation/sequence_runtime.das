options gen2
module sequence_runtime public
require ./builder_protocol.das public

// LambdaIterator::close saves/restores the caller's stop flags but does not
// clear them before running the finalizer (0.6.4). Enter recover to clear the
// inherited break/return flag before invoking arbitrary multi-statement code.
def ce_sequence_finalize(action : block<() : void>) {
    try { panic("__ce_sequence_finalize_entry") } recover { invoke(action) }
}

// Own a source: closing the returned iterator closes it.
def ce_sequence_protect(var source : iterator<auto(TT)>) : iterator<TT> {
    return <- generator<TT> capture(<- source) {
        var value : TT
        while (true) {
            var more = false
            more = ce_sequence_next_value(source, value)
            if (!more) { break }
            static_if(typeinfo can_copy(type<TT>)) {yield value}
            else {yield <- value}
        }
        return false
    } finally { ce_sequence_finalize($ { sequence_close(source) }) }
}

// Visit every element and close the iterator.
def sequence_each(var source : iterator<auto(TT)>; action : block<(value:auto(VV)) : void>) {
    static_if (typeinfo is_ref_value(type<TT>)) {
        var slot:TT -&?
        while (true) {
            var more=false
            unsafe {more=_builtin_iterator_iterate(source,addr(slot))}
            if (!more) {break}
            invoke(action,*slot)
        }
        sequence_close(source)
    } else {
        var value:TT
        while (ce_sequence_next_value(source,value)) {
            invoke(action,value)
            static_if (!typeinfo can_copy(type<TT>)) {delete value}
        }
        sequence_close(source)
    }
}


def ce_sequence_close_scope(var source : iterator<auto(TT)>; var cleanup : lambda<() : void>) {
    sequence_close(source)
    invoke(cleanup)
    unsafe { delete cleanup }
}

def ce_sequence_scoped(var source : iterator<auto(TT)>; var cleanup : lambda<() : void>) : iterator<TT> {
    return <- generator<TT> capture(<-source, <-cleanup) {
        var value : TT
        while (ce_sequence_next_value(source, value)) {
            static_if (typeinfo can_copy(type<TT>)) {yield value}
            else {yield <- value}
        }
        return false
    } finally {
        ce_sequence_finalize($ { ce_sequence_close_scope(source, cleanup) })
    }
}



// Detach before finalization, so the source is empty while its finalizer runs.
def sequence_close(var source : iterator<auto(TT)>) {
    var owned <- source
    unsafe { delete owned }
}

// A copyable descriptor with one mutable payload, owned by the lexical CE scope.
struct CeSequenceCellTag {_ce_marker:uint8}
def ce_sequence_new_cell(value : auto(TT)) =>
    new tuple<tag:CeSequenceCellTag;value:TT -const -&>(tag=CeSequenceCellTag(), value=value)
def ce_dispose(var cell : tuple<tag:CeSequenceCellTag;value:auto(TT)>?) {
    unsafe { delete cell }
}




// A value generator writes into our owned slot. Public iteration borrows that
// slot until next/close; native for cannot own or clean a move-only value slot.
def ce_sequence_own_elements(var source:iterator<auto(TT)>) : iterator<TT&> {
    var slot:TT
    return <- generator<TT&> capture(<-source, <-slot) {
        while (true) {
            delete slot
            var more=false
            more=ce_sequence_next_value(source,slot)
            if (!more) {break}
            yield slot
        }
        return false
    } finally {
        ce_sequence_finalize($ {
            delete slot
            sequence_close(source)
        })
    }
}
// Mutable borrow for consumers that explicitly move a yielded item elsewhere.
def sequence_each_move(var source:iterator<auto(TT)&>; action:block<(var value:auto(VV)):void>) {
    var slot:TT -&?
    while (true) {
        var more=false
        unsafe {more=_builtin_iterator_iterate(source,addr(slot))}
        if (!more) {break}
        invoke(action,*slot)
    }
    sequence_close(source)
}

// Called only with value slots; ownership is held by the caller.
def ce_sequence_next_value(var source:iterator<auto(TT)>; var slot:TT&) : bool {
    concept_assert(!typeinfo is_ref_value(type<TT>),"sequence: a value slot cannot receive a reference iterator")
    unsafe {return _builtin_iterator_iterate(source,addr(slot))}
}

// Pull one owning element. Exhaustion/error preserves the last delivered value.
// Reference iterators lend their current slot; value iterators fill a temporary.
def sequence_next_move(var source:iterator<auto(TT)>; var value:TT -&) : bool {
    static_if (typeinfo can_copy(type<TT -&>)) {
        concept_assert(false,"sequence_next_move requires a move-only element; use next for copyable values")
        return false
    } static_elif (typeinfo is_ref_value(type<TT>)) {
        var slot:TT -&?
        var more=false
        unsafe {more=_builtin_iterator_iterate(source,addr(slot))}
        if (!more) {sequence_close(source);return false}
        delete value
        unsafe {value <- *slot}
    } else {
        var inscope incoming:TT
        var more=false
        more=ce_sequence_next_value(source,incoming)
        if (!more) {sequence_close(source);return false}
        delete value
        value <- incoming
    }
    return true
}

// Releases a local that a resumable computation kept across its suspensions.
// The lowering of such a local calls it when the local's scope ends.
def ce_task_local_delete(var value:auto) {static_if(typeinfo can_delete(value)) {delete value}}
