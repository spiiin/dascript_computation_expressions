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
def ce_unwrap(builder : ResultBuilder; value : variant<err:string;ok:auto(T)>) : T => value as ok
[inline]
def ce_unwrap(builder : OptionBuilder; value : variant<none:void;some:auto(T)>) : T => value as some

def result_ok(value : auto(T)) : Result<T -const -&;string> => <- result::ok(value,type<string>)
def result_error(message : string; unused : type<auto(T)>) : Result<T -const -&;string> =>
    <- result::err(message,type<T>)

[inline]
def ce_return(builder : ResultBuilder; value : auto(T)) => result_ok(value)
[inline]
def ce_return(builder : OptionBuilder; value : auto(T)) => some(value)

def ce_return_from(builder : ResultBuilder; value : Result<auto(T);string>) => value
def ce_return_from(builder : OptionBuilder; value : Option<auto(T)>) => value

def ce_bind(builder : ResultBuilder; value : Result<auto(T);string>;
            next : block<(item : T) : auto(R)>) : R {
    if (value is err) { return variant type<R>(err=value as err) }
    return invoke(next, value as ok)
}
def ce_bind(builder : OptionBuilder; value : Option<auto(T)>;
            next : block<(item : T) : auto(R)>) : R {
    if (value is none) { return default<R> }
    return invoke(next, value as some)
}

// Unit is a successful computation with no useful payload (not None/Error).

def ce_zero(_builder : ResultBuilder) => variant type<Result<CeUnit;string>>(ok=CeUnit())
def ce_zero(_builder : OptionBuilder) => variant type<Option<CeUnit>>(some=CeUnit())

// Synchronous builders force the thunk here; no block escapes its stack frame.

def ce_combine(builder : ResultBuilder; first : Result<CeUnit;string>;
               next : block<() : auto(R)>) : R {
    if (first is err) { return variant type<R>(err=first as err) }
    return ce_delay(builder, next)
}
def ce_combine(builder : OptionBuilder; first : Option<CeUnit>;
               next : block<() : auto(R)>) : R {
    if (first is none) { return default<R> }
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
def ce_direct_failed(builder : ResultBuilder; source : variant<err:string;ok:auto(T)>) : bool =>
    source is err
[inline]
def ce_direct_failed(builder : OptionBuilder; source : variant<none:void;some:auto(T)>) : bool =>
    source is none
def ce_direct_failure(builder : ResultBuilder; source : Result<auto(T);string>; witness : auto(R)?) : R =>
    variant type<R>(err=source as err)
def ce_direct_failure(builder : OptionBuilder; source : Option<auto(T)>; witness : auto(R)?) : R =>
    default<R>


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

def ce_bind_return(builder : ResultBuilder; source : Result<auto(T);string>;
                   mapper : block<(value:T):auto(U)>) : typedecl(ce_return(builder, default<U>)) {
    if (source is err) { return variant type<typedecl(ce_return(builder, default<U>))>(err=source as err) }
    return variant type<typedecl(ce_return(builder, default<U>))>(ok=invoke(mapper, source as ok))
}
def ce_bind_return(builder : OptionBuilder; source : Option<auto(T)>;
                   mapper : block<(value:T):auto(U)>) : typedecl(ce_return(builder, default<U>)) {
    if (source is none) { return default<typedecl(ce_return(builder, default<U>))> }
    return variant type<typedecl(ce_return(builder, default<U>))>(some=invoke(mapper, source as some))
}


def ce_bind2_return(builder:ResultBuilder; left:Result<auto(A);string>; right:Result<auto(B);string>;
                    mapper:block<(pair:tuple<first:A -const -&;second:B -const -&>):auto(U)>) : typedecl(ce_return(builder,default<U>)) {
    if (left is err) { return variant type<typedecl(ce_return(builder,default<U>))>(err=left as err) }
    if (right is err) { return variant type<typedecl(ce_return(builder,default<U>))>(err=right as err) }
    return variant type<typedecl(ce_return(builder,default<U>))>(ok=invoke(mapper,ce_source_pair(left as ok,right as ok)))
}
def ce_bind2_return(builder:OptionBuilder; left:Option<auto(A)>; right:Option<auto(B)>;
                    mapper:block<(pair:tuple<first:A -const -&;second:B -const -&>):auto(U)>) : typedecl(ce_return(builder,default<U>)) {
    if (left is none || right is none) { return default<typedecl(ce_return(builder,default<U>))> }
    return variant type<typedecl(ce_return(builder,default<U>))>(some=invoke(mapper,ce_source_pair(left as some,right as some)))
}

// Grouped bind: the continuation already returns an outcome.
def ce_bind2(builder:ResultBuilder; left:Result<auto(A);string>; right:Result<auto(B);string>;
                    mapper:block<(pair:tuple<first:A -const -&;second:B -const -&>):auto(R)>) : R {
    if (left is err) { return variant type<R>(err=left as err) }
    if (right is err) { return variant type<R>(err=right as err) }
    return invoke(mapper,ce_source_pair(left as ok,right as ok))
}
def ce_bind2(builder:OptionBuilder; left:Option<auto(A)>; right:Option<auto(B)>;
                    mapper:block<(pair:tuple<first:A -const -&;second:B -const -&>):auto(R)>) : R {
    if (left is none || right is none) { return default<R> }
    return invoke(mapper,ce_source_pair(left as some,right as some))
}

// Loops need no operations here: a direct builder's loop is native, and its
// body is lowered into the computation's own scope.

// Result with any copyable error type: ResultBuilder(type<E>). `return value`
// says nothing about the error type, so the builder carries it. ResultBuilder()
// is the same computation with string errors.
struct ResultErrorContext {_ce_marker:uint8}
def ResultBuilder(unused : type<auto(E)>) {
    static_assert(typeinfo can_copy(type<E>), "ResultBuilder(type<E>): the error type must be copyable")
    var marker : E -const -&?
    return (kind=ResultErrorContext(), error=marker)
}
def ce_protocol(builder : tuple<kind:ResultErrorContext;error:auto(E)?>) => CeDirectProtocol()
[inline]
def ce_unwrap(builder : tuple<kind:ResultErrorContext;error:auto(E)?>; value : variant<err:E;ok:auto(T)>) : T =>
    value as ok
def ce_return(builder : tuple<kind:ResultErrorContext;error:auto(E)?>; value : auto(T)) =>
    <- result::ok(value, type<E>)
def ce_return_from(builder : tuple<kind:ResultErrorContext;error:auto(E)?>; value : Result<auto(T);E>) =>
    value
def ce_zero(builder : tuple<kind:ResultErrorContext;error:auto(E)?>) =>
    variant type<Result<CeUnit;E>>(ok=CeUnit())
[inline]
def ce_direct_failed(builder : tuple<kind:ResultErrorContext;error:auto(E)?>; source : variant<err:E;ok:auto(T)>) : bool =>
    source is err
def ce_direct_failure(builder : tuple<kind:ResultErrorContext;error:auto(E)?>; source : Result<auto(T);E>;
                      witness : auto(R)?) : R => variant type<R>(err=source as err)
def ce_loop_failed(builder : tuple<kind:ResultErrorContext;error:auto(E)?>; step : Result<CeUnit;E>) : bool =>
    step is err
def ce_loop_append(builder : tuple<kind:ResultErrorContext;error:auto(E)?>; first, step : Result<CeUnit;E>) {
    if (first is err) { return first }
    return step
}
def ce_merge_sources(builder : tuple<kind:ResultErrorContext;error:auto(E)?>; left : Result<auto;E>;
                     right : Result<auto;E>) {
    unsafe {
        if(left is err) {return typeinfo ce_canonical(variant type<Result<typedecl(ce_source_pair(left as ok,right as ok));E>>(err=left as err))}
        if(right is err) {return typeinfo ce_canonical(variant type<Result<typedecl(ce_source_pair(left as ok,right as ok));E>>(err=right as err))}
        return typeinfo ce_canonical(result::ok(ce_source_pair(left as ok,right as ok), type<E>))
    }
}
