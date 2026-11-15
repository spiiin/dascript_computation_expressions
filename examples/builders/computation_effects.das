options gen2
module computation_effects public
require ../../packages/computation/computation_builders.das public

// Eager, scoped state: the macro copies the initial state into a mutable local.
struct StateContext {_ce_marker:uint8}
struct StateGet {_ce_marker:uint8}
struct StatePut {_ce_marker:uint8}

def StateBuilder(initial : auto(SS)) : tuple<kind : StateContext; state : SS -const> {
    return (kind = StateContext(), state = initial)
}
def state_get() { return StateGet() }
def state_put(value : auto(SS)) : tuple<operation : StatePut; state : SS -const> {
    return (operation = StatePut(), state = value)
}
def state_result(value : auto(TT); state : auto(SS)) : tuple<value : TT -const; state : SS -const> {
    return (value = value, state = state)
}
def ce_unwrap(builder : tuple<kind : StateContext; state : auto(SS)>; op : StateGet) : SS {
    return builder.state
}
def ce_unwrap(builder : tuple<kind : StateContext; state : auto(SS)>;
              op : tuple<operation : StatePut; state : SS>) : CeUnit {
    return CeUnit()
}
def ce_unwrap(builder : tuple<kind : StateContext; state : auto(SS)>;
              op : tuple<value : auto(TT); state : SS>) : TT {
    return op.value
}
def ce_bind(var builder : tuple<kind : StateContext; state : auto(SS)>; op : StateGet;
            next : block<(value : SS) : auto(RR)>) : RR {
    // Snapshot before invoking the continuation; it may replace the state.
    let snapshot = builder.state
    return invoke(next, snapshot)
}
def ce_bind(var builder : tuple<kind : StateContext; state : auto(SS)>;
            op : tuple<operation : StatePut; state : SS>;
            next : block<(value : CeUnit) : auto(RR)>) : RR {
    builder.state = op.state
    return invoke(next, CeUnit())
}
def ce_bind(var builder : tuple<kind : StateContext; state : auto(SS)>;
            op : tuple<value : auto(TT); state : SS>;
            next : block<(value : TT) : auto(RR)>) : RR {
    builder.state = op.state
    return invoke(next, op.value)
}
def ce_return(builder : tuple<kind : StateContext; state : auto(SS)>; value : auto(TT)) {
    return state_result(value, builder.state)
}
def ce_zero(builder : tuple<kind : StateContext; state : auto(SS)>) {
    return state_result(CeUnit(), builder.state)
}
def ce_return_from(var builder : tuple<kind : StateContext; state : auto(SS)>;
                   value : tuple<value : auto(TT); state : SS>) {
    builder.state = value.state
    return value
}
def ce_combine(var builder : tuple<kind : StateContext; state : auto(SS)>;
               first : tuple<value : CeUnit; state : SS>; next : block<() : auto(RR)>) : RR {
    builder.state = first.state
    return ce_delay(builder, next)
}
def ce_loop_failed(builder : tuple<kind : StateContext; state : auto(SS)>;
                   value : tuple<value : CeUnit; state : SS>) : bool {
    return false
}
def ce_loop_append(var builder : tuple<kind : StateContext; state : auto(SS)>;
                   first, step : tuple<value : CeUnit; state : SS>) {
    builder.state = step.state
    return step
}

// A Writer carries a copyable value plus a string log. No global log/sink.
struct WriterBuilder {_ce_marker:uint8}
def writer_value(value : auto(TT); log : string = "") : tuple<value : TT -const; log : string> {
    return (value = value, log = log)
}
def tell(message : string) { return writer_value(CeUnit(), message) }
def ce_unwrap(builder : WriterBuilder; value : tuple<value : auto(TT); log : string>) : TT {
    return value.value
}
def ce_bind(builder : WriterBuilder; value : tuple<value : auto(TT); log : string>;
            next : block<(item : TT) : auto(RR)>) : RR {
    let rest = invoke(next, value.value)
    return writer_value(rest.value, value.log + rest.log)
}
def ce_return(builder : WriterBuilder; value : auto(TT)) { return writer_value(value) }
def ce_zero(builder : WriterBuilder) { return tell("") }
def ce_return_from(builder : WriterBuilder; value : tuple<value : auto(TT); log : string>) {
    return value
}
def ce_combine(builder : WriterBuilder; first : tuple<value : CeUnit; log : string>;
               next : block<() : auto(RR)>) : RR {
    let rest = ce_delay(builder, next)
    return writer_value(rest.value, first.log + rest.log)
}
def ce_loop_failed(builder : WriterBuilder; step : tuple<value : CeUnit; log : string>) : bool {
    return false
}
def ce_loop_append(builder : WriterBuilder; first, step : tuple<value : CeUnit; log : string>) {
    return tell(first.log + step.log)
}



def ce_protocol(builder : tuple<kind:StateContext;state:auto(SS)>) { return CeValueProtocol() }
def ce_protocol(builder : WriterBuilder) { return CeValueProtocol() }

def ce_bind_return(builder : WriterBuilder; source : tuple<value:auto(TT);log:string>;
                   mapper : block<(value:TT):auto(UU)>) { return writer_value(invoke(mapper, source.value), source.log) }

// Snapshot/update before mapping; read the final state only after the mapper.
def ce_bind_return(var builder:tuple<kind:StateContext;state:auto(SS)>; op:StateGet;
                   mapper:block<(value:SS):auto(UU)>) : typedecl(ce_return(builder,default<UU>)) {
    let snapshot=builder.state
    let mapped=invoke(mapper,snapshot)
    return state_result(mapped,builder.state)
}
def ce_bind_return(var builder:tuple<kind:StateContext;state:auto(SS)>;
                   op:tuple<operation:StatePut;state:SS>;
                   mapper:block<(value:CeUnit):auto(UU)>) : typedecl(ce_return(builder,default<UU>)) {
    builder.state=op.state
    let mapped=invoke(mapper,CeUnit())
    return state_result(mapped,builder.state)
}
def ce_bind_return(var builder:tuple<kind:StateContext;state:auto(SS)>;
                   op:tuple<value:auto(TT);state:SS>;
                   mapper:block<(value:TT):auto(UU)>) : typedecl(ce_return(builder,default<UU>)) {
    builder.state=op.state
    let mapped=invoke(mapper,op.value)
    return state_result(mapped,builder.state)
}
// State never short-circuits. A numeric range owns no resource: use a native
// loop instead of allocating the generic protected iterator/cursor. Keep the
// body outcome authoritative, just as ce_loop_append does in the fallback.
def ce_for(var builder:tuple<kind:StateContext;state:auto(SS)>; source:range;
           body:block<(item:int):tuple<value:CeUnit;state:SS>>) {
    for (item in source) {
        let step=invoke(body,item)
        builder.state=step.state
    }
    return ce_zero(builder)
}
