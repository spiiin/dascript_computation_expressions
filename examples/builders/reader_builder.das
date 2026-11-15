options gen2
module reader_builder public
require ../../packages/computation/builder_protocol.das public

struct ReaderContext {_ce_marker:uint8}
struct ReaderAsk {_ce_marker:uint8}
def ReaderBuilder(environment : auto(EE)) { return (kind=ReaderContext(), environment=environment) }
def reader_ask() { return ReaderAsk() }
def reader_value(value : auto(TT)) { return (value=value) }
def ce_protocol(builder : tuple<kind:ReaderContext;environment:auto(EE)>) { return CeValueProtocol() }
def ce_unwrap(builder : tuple<kind:ReaderContext;environment:auto(EE)>; source : ReaderAsk) : EE { return builder.environment }
def ce_unwrap(builder : tuple<kind:ReaderContext;environment:auto(EE)>; source : tuple<value:auto(TT)>) : TT { return source.value }
def ce_bind(builder : tuple<kind:ReaderContext;environment:auto(EE)>; source : ReaderAsk;
            next : block<(item:EE):auto(RR)>) : RR { return invoke(next, builder.environment) }
def ce_bind(builder : tuple<kind:ReaderContext;environment:auto(EE)>; source : tuple<value:auto(TT)>;
            next : block<(item:TT):auto(RR)>) : RR { return invoke(next, source.value) }
def ce_return(builder : tuple<kind:ReaderContext;environment:auto(EE)>; value : auto(TT)) { return reader_value(value) }
def ce_return_from(builder : tuple<kind:ReaderContext;environment:auto(EE)>; value : tuple<value:auto(TT)>) { return value }
def ce_zero(builder : tuple<kind:ReaderContext;environment:auto(EE)>) { return reader_value(CeUnit()) }
def ce_combine(builder : tuple<kind:ReaderContext;environment:auto(EE)>; first : tuple<value:CeUnit>;
               next : block<():auto(RR)>) : RR { return invoke(next) }
def ce_loop_failed(builder : tuple<kind:ReaderContext;environment:auto(EE)>; step : tuple<value:CeUnit>) : bool { return false }
def ce_loop_append(builder : tuple<kind:ReaderContext;environment:auto(EE)>; first, step : tuple<value:CeUnit>) { return step }

def ce_bind_return(builder : tuple<kind:ReaderContext;environment:auto(EE)>; source : ReaderAsk;
                   mapper : block<(value:EE):auto(UU)>) { return reader_value(invoke(mapper, builder.environment)) }
def ce_bind_return(builder : tuple<kind:ReaderContext;environment:auto(EE)>; source : tuple<value:auto(TT)>;
                   mapper : block<(value:TT):auto(UU)>) { return reader_value(invoke(mapper, source.value)) }
