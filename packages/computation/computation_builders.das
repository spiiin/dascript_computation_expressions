options gen2
module computation_builders public
require ./builder_protocol.das public
require ./zip_runtime.das public

struct ResultBuilder {_ce_marker:uint8}
struct OptionBuilder {_ce_marker:uint8}

// [inline] splices a body into its call, so a bind costs a test and a read, as
// hand-written code does. The operations a direct bind runs are marked: these,
// ce_direct_failed and ce_return. Their source parameter is the variant spelled
// out: an instance of a generic over Result<auto(T);string> holds a type alias,
// and the splicer refuses a body with one.
[inline]
def ce_unwrap(builder : ResultBuilder; value : variant<err:string;ok:auto(TT)>) : TT => value as ok
[inline]
def ce_unwrap(builder : OptionBuilder; value : variant<none:void;some:auto(TT)>) : TT => value as some

def result_ok(value : auto(TT)) : Result<TT -const -&;string> => <- result::ok(value,type<string>)
def result_error(message : string; unused : type<auto(TT)>) : Result<TT -const -&;string> =>
    <- result::err(message,type<TT>)

[inline]
def ce_return(builder : ResultBuilder; value : auto(TT)) => result_ok(value)
[inline]
def ce_return(builder : OptionBuilder; value : auto(TT)) => some(value)

def ce_return_from(builder : ResultBuilder; value : Result<auto(TT);string>) => value
def ce_return_from(builder : OptionBuilder; value : Option<auto(TT)>) => value

def ce_bind(builder : ResultBuilder; value : Result<auto(TT);string>;
            next : block<(item : TT) : auto(RR)>) : RR {
    if (value is err) { return variant type<RR>(err=value as err) }
    return invoke(next, value as ok)
}
def ce_bind(builder : OptionBuilder; value : Option<auto(TT)>;
            next : block<(item : TT) : auto(RR)>) : RR {
    if (value is none) { return default<RR> }
    return invoke(next, value as some)
}

// Unit is a successful computation with no useful payload (not None/Error).

def ce_zero(_builder : ResultBuilder) => variant type<Result<CeUnit;string>>(ok=CeUnit())
def ce_zero(_builder : OptionBuilder) => variant type<Option<CeUnit>>(some=CeUnit())

// Synchronous builders force the thunk here; no block escapes its stack frame.

def ce_combine(builder : ResultBuilder; first : Result<CeUnit;string>;
               next : block<() : auto(RR)>) : RR {
    if (first is err) { return variant type<RR>(err=first as err) }
    return ce_delay(builder, next)
}
def ce_combine(builder : OptionBuilder; first : Option<CeUnit>;
               next : block<() : auto(RR)>) : RR {
    if (first is none) { return default<RR> }
    return ce_delay(builder, next)
}
// These signatures require each loop iteration to compute Unit.
def ce_loop_failed(builder : ResultBuilder; step : Result<CeUnit;string>) : bool => step is err
def ce_loop_failed(builder : OptionBuilder; step : Option<CeUnit>) : bool => step is none


// Fold loop effects. Result/Option keep their first failure; Writer appends logs.
def ce_loop_append(builder : ResultBuilder; first, step : Result<CeUnit;string>) {
    if (first is err) { return first }
    return step
}
def ce_loop_append(builder : OptionBuilder; first, step : Option<CeUnit>) {
    if (first is none) { return first }
    return step
}

def ce_protocol(_builder : ResultBuilder) => CeDirectProtocol()
def ce_protocol(_builder : OptionBuilder) => CeDirectProtocol()

// Direct lowering: a failed source leaves the scope as the scope's own type.
[inline]
def ce_direct_failed(builder : ResultBuilder; source : variant<err:string;ok:auto(TT)>) : bool =>
    source is err
[inline]
def ce_direct_failed(builder : OptionBuilder; source : variant<none:void;some:auto(TT)>) : bool =>
    source is none
def ce_direct_failure(builder : ResultBuilder; source : Result<auto(TT);string>; witness : auto(RR)?) : RR =>
    variant type<RR>(err=source as err)
def ce_direct_failure(builder : OptionBuilder; source : Option<auto(TT)>; witness : auto(RR)?) : RR =>
    default<RR>


def ce_merge_sources(builder : ResultBuilder; left : Result<auto;string>;
                     right : Result<auto;string>) {
    unsafe {
        if(left is err) {return typeinfo ce_canonical(variant type<Result<typedecl(ce_source_pair(left as ok,right as ok));string>>(err=left as err))}
        if(right is err) {return typeinfo ce_canonical(variant type<Result<typedecl(ce_source_pair(left as ok,right as ok));string>>(err=right as err))}
        return typeinfo ce_canonical(result_ok(ce_source_pair(left as ok,right as ok)))
    }
}
def ce_merge_sources(builder : OptionBuilder; left : Option<auto>;
                     right : Option<auto>) {
    unsafe {
        if(left is none || right is none) {return typeinfo ce_canonical(default<Option<typedecl(ce_source_pair(left as some,right as some))>>)}
        return typeinfo ce_canonical(some(ce_source_pair(left as some,right as some)))
    }
}

def ce_bind_return(builder : ResultBuilder; source : Result<auto(TT);string>;
                   mapper : block<(value:TT):auto(UU)>) : typedecl(ce_return(builder, default<UU>)) {
    if (source is err) { return variant type<typedecl(ce_return(builder, default<UU>))>(err=source as err) }
    return variant type<typedecl(ce_return(builder, default<UU>))>(ok=invoke(mapper, source as ok))
}
def ce_bind_return(builder : OptionBuilder; source : Option<auto(TT)>;
                   mapper : block<(value:TT):auto(UU)>) : typedecl(ce_return(builder, default<UU>)) {
    if (source is none) { return default<typedecl(ce_return(builder, default<UU>))> }
    return variant type<typedecl(ce_return(builder, default<UU>))>(some=invoke(mapper, source as some))
}


def ce_bind2_return(builder:ResultBuilder; left:Result<auto(AA);string>; right:Result<auto(BB);string>;
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):auto(UU)>) : typedecl(ce_return(builder,default<UU>)) {
    if (left is err) { return variant type<typedecl(ce_return(builder,default<UU>))>(err=left as err) }
    if (right is err) { return variant type<typedecl(ce_return(builder,default<UU>))>(err=right as err) }
    return variant type<typedecl(ce_return(builder,default<UU>))>(ok=invoke(mapper,ce_source_pair(left as ok,right as ok)))
}
def ce_bind2_return(builder:OptionBuilder; left:Option<auto(AA)>; right:Option<auto(BB)>;
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):auto(UU)>) : typedecl(ce_return(builder,default<UU>)) {
    if (left is none || right is none) { return default<typedecl(ce_return(builder,default<UU>))> }
    return variant type<typedecl(ce_return(builder,default<UU>))>(some=invoke(mapper,ce_source_pair(left as some,right as some)))
}

// Grouped bind: the continuation already returns an outcome.
def ce_bind2(builder:ResultBuilder; left:Result<auto(AA);string>; right:Result<auto(BB);string>;
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):auto(RR)>) : RR {
    if (left is err) { return variant type<RR>(err=left as err) }
    if (right is err) { return variant type<RR>(err=right as err) }
    return invoke(mapper,ce_source_pair(left as ok,right as ok))
}
def ce_bind2(builder:OptionBuilder; left:Option<auto(AA)>; right:Option<auto(BB)>;
                    mapper:block<(pair:tuple<first:AA -const -&;second:BB -const -&>):auto(RR)>) : RR {
    if (left is none || right is none) { return default<RR> }
    return invoke(mapper,ce_source_pair(left as some,right as some))
}

// Loops need no operations here: a direct builder's loop is native, and its
// body is lowered into the computation's own scope.

// Result with any copyable error type: ResultBuilder(type<E>). `return value`
// says nothing about the error type, so the builder carries it. ResultBuilder()
// is the same computation with string errors.
struct ResultErrorContext {_ce_marker:uint8}
def ResultBuilder(unused : type<auto(EE)>) {
    static_assert(typeinfo can_copy(type<EE>), "ResultBuilder(type<E>): the error type must be copyable")
    var marker : EE -const -&?
    return (kind=ResultErrorContext(), error=marker)
}
def ce_protocol(builder : tuple<kind:ResultErrorContext;error:auto(EE)?>) => CeDirectProtocol()
[inline]
def ce_unwrap(builder : tuple<kind:ResultErrorContext;error:auto(EE)?>; value : variant<err:EE;ok:auto(TT)>) : TT =>
    value as ok
def ce_return(builder : tuple<kind:ResultErrorContext;error:auto(EE)?>; value : auto(TT)) =>
    <- result::ok(value, type<EE>)
def ce_return_from(builder : tuple<kind:ResultErrorContext;error:auto(EE)?>; value : Result<auto(TT);EE>) =>
    value
def ce_zero(builder : tuple<kind:ResultErrorContext;error:auto(EE)?>) =>
    variant type<Result<CeUnit;EE>>(ok=CeUnit())
[inline]
def ce_direct_failed(builder : tuple<kind:ResultErrorContext;error:auto(EE)?>; source : variant<err:EE;ok:auto(TT)>) : bool =>
    source is err
def ce_direct_failure(builder : tuple<kind:ResultErrorContext;error:auto(EE)?>; source : Result<auto(TT);EE>;
                      witness : auto(RR)?) : RR => variant type<RR>(err=source as err)
def ce_loop_failed(builder : tuple<kind:ResultErrorContext;error:auto(EE)?>; step : Result<CeUnit;EE>) : bool =>
    step is err
def ce_loop_append(builder : tuple<kind:ResultErrorContext;error:auto(EE)?>; first, step : Result<CeUnit;EE>) {
    if (first is err) { return first }
    return step
}
def ce_merge_sources(builder : tuple<kind:ResultErrorContext;error:auto(EE)?>; left : Result<auto;EE>;
                     right : Result<auto;EE>) {
    unsafe {
        if(left is err) {return typeinfo ce_canonical(variant type<Result<typedecl(ce_source_pair(left as ok,right as ok));EE>>(err=left as err))}
        if(right is err) {return typeinfo ce_canonical(variant type<Result<typedecl(ce_source_pair(left as ok,right as ok));EE>>(err=right as err))}
        return typeinfo ce_canonical(result::ok(ce_source_pair(left as ok,right as ok), type<EE>))
    }
}
