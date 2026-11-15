options gen2
module reader_result_builder public
require ../../packages/computation/computation_builders.das public
require ./reader_builder.das public

struct ReaderResultContext {_ce_marker:uint8}

// Eager reader: copyable environment and ordinary Result outcomes.
def ReaderResultBuilder(environment:auto(ReaderEnvironment)) {
    return (kind=ReaderResultContext(), environment=environment)
}

def ce_protocol(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>) { return CeValueProtocol() }

def ce_unwrap(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; source:ReaderAsk) : ReaderEnvironment {
    return builder.environment
}
def ce_unwrap(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; source:Result<auto(TT);string>) : TT {
    return source as ok
}
def ce_bind(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; source:ReaderAsk;
            next:block<(item:ReaderEnvironment):auto(RR)>) : RR {
    return invoke(next,builder.environment)
}
def ce_bind(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; source:Result<auto(TT);string>;
            next:block<(item:TT):auto(RR)>) : RR {
    return ce_bind(ResultBuilder(),source,next)
}
def ce_return(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; value:auto(TT)) {
    return result_ok(value)
}
def ce_return_from(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; value:Result<auto(TT);string>) {
    return value
}
def ce_zero(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>) { return ce_zero(ResultBuilder()) }
def ce_combine(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; first:Result<CeUnit;string>;
               next:block<():auto(RR)>) : RR {
    return ce_combine(ResultBuilder(),first,next)
}
// Default For/While lowering supplies traversal and resource protection.
def ce_loop_failed(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; step:Result<CeUnit;string>) : bool {
    return step is err
}
def ce_loop_append(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; first,step:Result<CeUnit;string>) {
    return ce_loop_append(ResultBuilder(),first,step)
}
def ce_bind_return(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; source:ReaderAsk;
                   mapper:block<(value:ReaderEnvironment):auto(UU)>) {
    return result_ok(invoke(mapper,builder.environment))
}
def ce_bind_return(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; source:Result<auto(TT);string>;
                   mapper:block<(value:TT):auto(UU)>) : typedecl(ce_return(builder,default<UU>)) {
    return ce_bind_return(ResultBuilder(),source,mapper)
}

def private rr_source(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; source:ReaderAsk) {
    return result_ok(builder.environment)
}
def private rr_source(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; source:Result<auto(TT);string>) {
    return source
}
def ce_merge_sources(builder:tuple<kind:ReaderResultContext;environment:auto(ReaderEnvironment)>; left,right:auto) {
    return ce_merge_sources(ResultBuilder(),rr_source(builder,left),rr_source(builder,right))
}

