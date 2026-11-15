options gen2
module state_result_builder public
require ./computation_effects.das public

struct StateResultContext {_ce_marker:uint8}
// initial is the transaction boundary, shared by all scopes of one computation.
def StateResultBuilder(initial : auto(SS)) : tuple<kind : StateResultContext; initial : SS -const; state : SS -const> {
    return (kind = StateResultContext(), initial = initial, state = initial)
}
def state_result_value(value : Result<auto(TT);string>; state : auto(SS)) {
    return (result = value, state = state)
}
def state_result_ok(value : auto(TT); state : auto(SS)) {
    return state_result_value(result_ok(value), state)
}
def state_result_error(message : string; unused : type<auto(TT)>; state : auto(SS)) {
    return state_result_value(result_error(message, type<TT>), state)
}
def private sr_failure(var builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>;
                       message : string; unused : type<auto(RR)>) : RR {
    builder.state = builder.initial
    var failed = default<RR>
    failed.result = variant type<typedecl(failed.result)>(err=message)
    failed.state = builder.initial
    return failed
}
def ce_unwrap(builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>; op : StateGet) : SS {
    return builder.state
}
def ce_unwrap(builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>;
              op : tuple<operation : StatePut; state : SS>) : CeUnit { return CeUnit() }
def ce_unwrap(builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>;
              op : Result<auto(TT);string>) : TT { return op as ok }
def ce_unwrap(builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>;
              op : tuple<result : Result<auto(TT);string>; state : SS>) : TT { return op.result as ok }

def ce_bind(var builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>; op : StateGet;
            next : block<(item : SS) : auto(RR)>) : RR {
    let snapshot = builder.state
    return invoke(next, snapshot)
}
def ce_bind(var builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>;
            op : tuple<operation : StatePut; state : SS>; next : block<(item : CeUnit) : auto(RR)>) : RR {
    builder.state = op.state
    return invoke(next, CeUnit())
}
def ce_bind(var builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>;
            op : Result<auto(TT);string>; next : block<(item : TT) : auto(RR)>) : RR {
    if (op is err) { return sr_failure(builder, op as err, type<RR>) }
    return invoke(next, op as ok)
}
def ce_bind(var builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>;
            op : tuple<result : Result<auto(TT);string>; state : SS>;
            next : block<(item : TT) : auto(RR)>) : RR {
    if (op.result is err) { return sr_failure(builder, op.result as err, type<RR>) }
    builder.state = op.state
    return invoke(next, op.result as ok)
}
def ce_return(builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>; value : auto(TT)) {
    return state_result_ok(value, builder.state)
}
def ce_zero(builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>) {
    return state_result_value(ce_zero(ResultBuilder()), builder.state)
}
def ce_return_from(var builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>;
                   value : Result<auto(TT);string>) {
    if (value is err) { builder.state = builder.initial }
    return state_result_value(value, builder.state)
}
def ce_return_from(var builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>;
                   value : tuple<result : Result<auto(TT);string>; state : SS>) {
    if (value.result is err) { builder.state = builder.initial }
    else { builder.state = value.state }
    return state_result_value(value.result, builder.state)
}
def ce_combine(var builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>;
               first : tuple<result : Result<CeUnit;string>; state : SS>;
               next : block<() : auto(RR)>) : RR {
    if (first.result is err) { return sr_failure(builder, first.result as err, type<RR>) }
    builder.state = first.state
    return ce_delay(builder, next)
}
def ce_loop_failed(builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>;
                   value : tuple<result : Result<CeUnit;string>; state : SS>) : bool {
    return value.result is err
}
def ce_loop_append(var builder : tuple<kind : StateResultContext; initial : auto(SS); state : SS>;
                   first, step : tuple<result : Result<CeUnit;string>; state : SS>) {
    if (first.result is err) { return sr_failure(builder, first.result as err, type<typedecl(first)>) }
    if (step.result is err) { return sr_failure(builder, step.result as err, type<typedecl(step)>) }
    builder.state = step.state
    return step
}

def ce_protocol(builder : tuple<kind:StateResultContext;initial:auto(SS);state:SS>) { return CeValueProtocol() }

def ce_bind_return(var builder:tuple<kind:StateResultContext;initial:auto(SS);state:SS>; op:StateGet;
                   mapper:block<(value:SS):auto(UU)>) : typedecl(ce_return(builder,default<UU>)) {
    let snapshot=builder.state
    let mapped=invoke(mapper,snapshot)
    return state_result_ok(mapped,builder.state)
}
def ce_bind_return(var builder:tuple<kind:StateResultContext;initial:auto(SS);state:SS>;
                   op:tuple<operation:StatePut;state:SS>;
                   mapper:block<(value:CeUnit):auto(UU)>) : typedecl(ce_return(builder,default<UU>)) {
    builder.state=op.state
    let mapped=invoke(mapper,CeUnit())
    return state_result_ok(mapped,builder.state)
}
def ce_bind_return(var builder:tuple<kind:StateResultContext;initial:auto(SS);state:SS>;
                   op:Result<auto(TT);string>;
                   mapper:block<(value:TT):auto(UU)>) : typedecl(ce_return(builder,default<UU>)) {
    if (op is err) { return sr_failure(builder,op as err,type<typedecl(ce_return(builder,default<UU>))>) }
    let mapped=invoke(mapper,op as ok)
    return state_result_ok(mapped,builder.state)
}
def ce_bind_return(var builder:tuple<kind:StateResultContext;initial:auto(SS);state:SS>;
                   op:tuple<result:Result<auto(TT);string>;state:SS>;
                   mapper:block<(value:TT):auto(UU)>) : typedecl(ce_return(builder,default<UU>)) {
    if (op.result is err) { return sr_failure(builder,op.result as err,type<typedecl(ce_return(builder,default<UU>))>) }
    builder.state=op.state
    let mapped=invoke(mapper,op.result as ok)
    return state_result_ok(mapped,builder.state)
}
