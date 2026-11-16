options gen2
module sequence_builder public
require ./builder_protocol.das public
require ./sequence_runtime.das public
require ./sequence_function.das public
struct SequenceContext {_ce_marker:uint8}
struct MoveSequenceContext {_ce_marker:uint8}
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
