options gen2
module state_writer_result_builder public
require ./computation_effects.das public

struct StateWriterResultContext {_ce_marker:uint8}
// initial is the transaction boundary, shared by all scopes of one computation.
def StateWriterResultBuilder(initial : auto(TransactionState)) : tuple<kind : StateWriterResultContext; initial : TransactionState -const; state : TransactionState -const> {
    return (kind = StateWriterResultContext(), initial = initial, state = initial)
}
def state_writer_result_value(value : Result<auto(TT);string>; state : auto(TransactionState); log : string = "") {
    return (result = value, state = state, log = log)
}
def state_writer_result_ok(value : auto(TT); state : auto(TransactionState); log : string = "") {
    return state_writer_result_value(ok(value, type<string>), state, log)
}
def state_writer_result_error(message : string; unused : type<auto(TT)>; state : auto(TransactionState); log : string = "") {
    return state_writer_result_value(err(message, type<TT>), state, log)
}
def private swr_failure(var builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>;
                       message, log : string; unused : type<auto(RR)>) : RR {
    builder.state = builder.initial
    var failed = default<RR>
    failed.result = variant type<typedecl(failed.result)>(err=message)
    failed.state = builder.initial
    failed.log = log
    return failed
}
def ce_unwrap(builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>; op : StateGet) : TransactionState {
    return builder.state
}
def ce_unwrap(builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>;
              op : tuple<operation : StatePut; state : TransactionState>) : CeUnit { return CeUnit() }
def ce_unwrap(builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>;
              op : Result<auto(TT);string>) : TT { return op as ok }
def ce_unwrap(builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>;
              op : tuple<result : Result<auto(TT);string>; state : TransactionState; log : string>) : TT { return op.result as ok }

def ce_bind(var builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>; op : StateGet;
            next : block<(item : TransactionState) : auto(RR)>) : RR {
    let snapshot = builder.state
    return invoke(next, snapshot)
}
def ce_bind(var builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>;
            op : tuple<operation : StatePut; state : TransactionState>; next : block<(item : CeUnit) : auto(RR)>) : RR {
    builder.state = op.state
    return invoke(next, CeUnit())
}
def ce_bind(var builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>;
            op : Result<auto(TT);string>; next : block<(item : TT) : auto(RR)>) : RR {
    if (op is err) { return swr_failure(builder, op as err, "", type<RR>) }
    return invoke(next, op as ok)
}
def ce_bind(var builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>;
            op : tuple<result : Result<auto(TT);string>; state : TransactionState; log : string>;
            next : block<(item : TT) : auto(RR)>) : RR {
    if (op.result is err) { return swr_failure(builder, op.result as err, op.log, type<RR>) }
    builder.state = op.state
    var rest = invoke(next, op.result as ok)
    rest.log = op.log + rest.log
    return rest
}
def ce_return(builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>; value : auto(TT)) {
    return state_writer_result_ok(value, builder.state)
}
def ce_zero(builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>) {
    return state_writer_result_value(ce_zero(ResultBuilder()), builder.state)
}
def ce_return_from(var builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>;
                   value : Result<auto(TT);string>) {
    if (value is err) { builder.state = builder.initial }
    return state_writer_result_value(value, builder.state)
}
def ce_return_from(var builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>;
                   value : tuple<result : Result<auto(TT);string>; state : TransactionState; log : string>) {
    if (value.result is err) { builder.state = builder.initial }
    else { builder.state = value.state }
    return state_writer_result_value(value.result, builder.state, value.log)
}
def ce_combine(var builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>;
               first : tuple<result : Result<CeUnit;string>; state : TransactionState; log : string>;
               next : block<() : auto(RR)>) : RR {
    if (first.result is err) { return swr_failure(builder, first.result as err, first.log, type<RR>) }
    builder.state = first.state
    var rest = ce_delay(builder, next)
    rest.log = first.log + rest.log
    return rest
}
def ce_loop_failed(builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>;
                   value : tuple<result : Result<CeUnit;string>; state : TransactionState; log : string>) : bool {
    return value.result is err
}
def ce_loop_append(var builder : tuple<kind : StateWriterResultContext; initial : auto(TransactionState); state : TransactionState>;
                   first, step : tuple<result : Result<CeUnit;string>; state : TransactionState; log : string>) {
    if (first.result is err) { return swr_failure(builder, first.result as err, first.log, type<typedecl(first)>) }
    if (step.result is err) { return swr_failure(builder, step.result as err, first.log + step.log, type<typedecl(step)>) }
    builder.state = step.state
    return state_writer_result_value(step.result, builder.state, first.log + step.log)
}

def ce_protocol(builder : tuple<kind:StateWriterResultContext;initial:auto(TransactionState);state:TransactionState>) { return CeValueProtocol() }


// Lift Writer<Unit> (tell) without changing state.
def ce_unwrap(builder:tuple<kind:StateWriterResultContext;initial:auto(TransactionState);state:TransactionState>;
              op:tuple<value:CeUnit;log:string>) : CeUnit {return CeUnit()}
def ce_bind(var builder:tuple<kind:StateWriterResultContext;initial:auto(TransactionState);state:TransactionState>;
            op:tuple<value:CeUnit;log:string>; next:block<(item:CeUnit):auto(RR)>) : RR {
    var rest=invoke(next,CeUnit())
    rest.log=op.log+rest.log
    return rest
}
def ce_return_from(builder:tuple<kind:StateWriterResultContext;initial:auto(TransactionState);state:TransactionState>;
                   op:tuple<value:CeUnit;log:string>) {
    return state_writer_result_ok(CeUnit(),builder.state,op.log)
}

