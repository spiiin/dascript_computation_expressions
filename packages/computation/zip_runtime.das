options gen2
module zip_runtime public
require ./sequence_runtime.das public
require daslib/rtti

struct CeZipReadOnly {_ce_marker:uint8}
struct CeZipMutable {_ce_marker:uint8}
// A mutable collection: its elements are writable even where each() yields
// constant references, as it does for a fixed array.
struct CeZipWritable {_ce_marker:uint8}

// Reference iterators write an address, value iterators write the value itself.
def private ce_zip_pack(var source:iterator<auto(T)>; mode:auto) {
    static_if (typeinfo is_ref_value(type<T>)) {
        var value:T -&?
        return <- (stream <- source, slot=value, mode=mode)
    } else {
        concept_assert(typeinfo can_copy(type<T>), "zip: value iterator elements must be copyable")
        var value:T
        return <- (stream <- source, slot=value, mode=mode)
    }
}
def ce_zip_cursor(var source:iterator<auto>) { return <- ce_zip_pack(source,CeZipMutable()) }
def ce_zip_cursor(source:auto ==const) {
    unsafe {
        var stream <- each(source)
        return <- ce_zip_pack(stream,CeZipReadOnly())
    }
}
def ce_zip_cursor(var source:auto ==const) {
    unsafe {
        var stream <- each(source)
        return <- ce_zip_pack(stream,CeZipWritable())
    }
}
def ce_zip_next(var cursor:tuple<stream:iterator<auto(T)>;slot:auto;mode:auto>) : bool {
    unsafe {return _builtin_iterator_iterate(cursor.stream,addr(cursor.slot))}
}
def ce_zip_close(var cursor:tuple<stream:iterator<auto>;slot:auto;mode:auto>) {
    sequence_close(cursor.stream)
}


// A loop that walks an array by index holds the lock a native `for` would
// hold, and gives it back after the loop. A fixed array has no lock.
def ce_loop_lock(source:auto ==const) {
    static_if (typeinfo is_array(source)) { __builtin_array_lock_mutable(source) }
}
def ce_loop_lock(var source:auto ==const) {
    static_if (typeinfo is_array(source)) { __builtin_array_lock(source) }
}
def ce_loop_unlock(source:auto ==const) {
    static_if (typeinfo is_array(source)) { __builtin_array_unlock_mutable(source) }
}
def ce_loop_unlock(var source:auto ==const) {
    static_if (typeinfo is_array(source)) { __builtin_array_unlock(source) }
}

// An iterator used as a nested Sequence source, preserving ref elements.
def ce_sequence_input(var source:iterator<auto(T)>) : iterator<T> {
    var cursor <- ce_zip_cursor(source)
    return <- generator<T> capture(<-cursor) {
        while (ce_zip_next(cursor)) {
            static_if (typeinfo is_ref_value(type<T>)) {
                unsafe {yield *cursor.slot}
            } else {yield cursor.slot}
        }
        return false
    } finally {ce_sequence_finalize($ {ce_zip_close(cursor)})}
}
