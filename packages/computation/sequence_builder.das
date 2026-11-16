options gen2
module sequence_builder public
require ./builder_protocol.das public
require ./sequence_runtime.das public
require ./sequence_function.das public

//! ``SequenceBuilder(type<T>)``: lazy computations. The block becomes an iterator that runs up to the next
//! ``yield`` each time an element is requested. The module also brings the ``[sequence]`` function
//! annotation and the ``sequence_*`` functions that walk and close such an iterator. The ``computation``
//! facade includes this module.

//! Marker of the builder that ``SequenceBuilder(type<T>)`` returns for a copyable element type.
struct SequenceContext {_ce_marker:uint8}
//! Marker of the builder that ``SequenceBuilder(type<T>)`` returns for an element type that cannot be copied.
struct MoveSequenceContext {_ce_marker:uint8}
//! Builder of a lazy computation that yields elements of type ``T``. The result is an ``iterator<T>`` that
//! the caller owns and closes with ``sequence_each``, ``sequence_close`` or a ``var inscope`` owner; closing
//! it releases the resources that the body holds. When ``T`` cannot be copied, elements are yielded with
//! ``yield <-`` and the result is an ``iterator<T&>`` that lends each element until the next step: read it
//! with ``sequence_each_move`` or ``sequence_next_move``.
def SequenceBuilder(t : type<auto(TT)>) {
    static_if (typeinfo can_copy(type<TT>)) {
        return (kind=SequenceContext(),element=default<TT -const>)
    } else {
        var marker:TT -const -&?
        return (kind=MoveSequenceContext(),element=marker)
    }
}




def ce_protocol(builder : tuple<kind:SequenceContext;element:auto(TT)>) =>
    ce_sequence_protocol(type<TT>)
def ce_sequence_run(builder : tuple<kind:SequenceContext;element:auto(TT)>; var source : iterator<TT>) : iterator<TT> =>
    <- ce_sequence_protect(source)

def ce_protocol(builder:tuple<kind:MoveSequenceContext;element:auto(TT)?>) =>
    <- (strategy=CeSequenceProtocol(),element <- default<TT>)
def ce_sequence_run(builder:tuple<kind:MoveSequenceContext;element:auto(TT)?>; var source:iterator<TT>) =>
    <- ce_sequence_own_elements(source)
