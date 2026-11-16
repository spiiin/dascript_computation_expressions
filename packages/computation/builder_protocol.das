options gen2
module builder_protocol public
require daslib/result public
require daslib/ast_boost
require daslib/templates_boost
require ./computation_resources.das public
require daslib/rtti

// Nominal, compile-time protocol descriptors. ce_protocol is only type-inferred.
struct CeValueProtocol {_ce_marker:uint8}
struct CeCollectProtocol {_ce_marker:uint8}
struct CeSequenceProtocol {_ce_marker:uint8}
struct CeResumableProtocol {_ce_marker:uint8}
struct CeUnit {_ce_marker:uint8}

// Standard Option representation, with a separate field move for the SDK AOT
// tuple-in-variant initializer bug. Arrays and tuple/struct payloads stay owned.
def ce_move_some(var value:auto(TT)) : Option<TT -const -&> {
    var vacant=default<TT -const -&>
    var result <- option::move_some(vacant)
    result as some <- value
    return <- result
}
struct CeResumableNoZero {_ce_marker:uint8}
def ce_await_zero(builder:auto) => CeResumableNoZero()

// Optional asynchronous For source. The fallback is inspected only by type.
struct CeResumableForFallback {_ce_marker:uint8}
def ce_await_for_source(builder:auto; source:auto; control:auto) => CeResumableForFallback()
def ce_await_for_merge(builder:auto; left,right:auto) => CeResumableForFallback()
// A sequence builder that awaits its sources may walk an awaited source itself:
// ce_await_input(builder, source) then replaces the walk over
// ce_await_source(builder, source). A builder without the hook keeps that walk.
struct CeAwaitInputFallback {_ce_marker:uint8}
def ce_await_input(builder:auto; source:auto) => CeAwaitInputFallback()
// What a deferred run must own in a result that wraps its payload, as a Task
// wraps its value: ce_deferred_payload(result) has the payload's type. It is
// only typed, never called. Without the hook the result itself is checked.
struct CeDeferredPayloadFallback {_ce_marker:uint8}
def ce_deferred_payload(result:auto) => CeDeferredPayloadFallback()
def ce_await_for_incompatible(builder:auto) {
    concept_assert(false,"async For: all sources must support ce_await_for_merge; cannot mix AsyncSequence and native sources")
}

def ce_sequence_protocol(unused : type<auto(TT)>) =>
    (strategy=CeSequenceProtocol(), element=default<TT -const -&>)

def ce_resumable_protocol(unused:type<auto(TT)>) =>
    (strategy=CeResumableProtocol(),element=default<TT -const -&>)

// Default for copyable eager outcomes. Move-only builders override this.
def ce_delay(builder : auto; body : block<() : auto(RR)>) : RR => invoke(body)

// Do not export generic deduction aliases into nested standard templates.
def private ce_canonical_type(t:TypeDeclPtr) : TypeDeclPtr {
    var result=clone_type(t)
    result.alias:=""
    if(result.firstType!=null) {result.firstType=ce_canonical_type(result.firstType)}
    if(result.secondType!=null) {result.secondType=ce_canonical_type(result.secondType)}
    for(field in result.argTypes) {field=ce_canonical_type(field)}
    return result
}
[typeinfo_macro(name="ce_canonical")]
class CeCanonical : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?;var errors:das_string) : ExpressionPtr {
        if(expr.subexpr==null || expr.subexpr._type==null || expr.subexpr._type.isAutoOrAlias) {return null}
        let clean=ce_canonical_type(expr.subexpr._type)
        return qmacro_expr() {reinterpret<$t(clean)>($e(expr.subexpr))}
    }
}
def ce_source_pair(first:auto;second:auto) => typeinfo ce_canonical((first=first,second=second))

// Run a continuation over an owned temporary source, which is released when
// the continuation returns. The continuation arrives as an argument,
// so generated code names it once instead of once for its type and once to run.
def ce_owned_apply_move(var source : auto; next : auto) {
    var inscope result : typedecl(invoke(next, source))
    result <- invoke(next, source)
    return <- result
}
def ce_owned_apply_copy(var source : auto; next : auto) {
    var result : typedecl(invoke(next, source))
    result = invoke(next, source)
    return result
}




// Type-only fallback marker. The macro emits the original Bind/Return when
// no more specific overload exists; this function never runs in generated CE.
struct CeBindReturnFallback {_ce_marker:uint8}
def ce_bind_return(builder:auto; source:auto; mapper:auto) => CeBindReturnFallback()

def ce_bind2_return(builder:auto; left:auto; right:auto; mapper:auto) => CeBindReturnFallback()

// Optional grouped bind with a continuation returning the builder outcome.
def ce_bind2(builder:auto; left:auto; right:auto; next:auto) => CeBindReturnFallback()

// Compile-time defaults, removed by the macro before runtime.
struct CeMissingProtocol {_ce_marker:uint8}
struct CeMergeSourcesFallback {_ce_marker:uint8}
def ce_merge_sources(builder:auto; left,right:auto) => CeMergeSourcesFallback()
// Type-only diagnostic envelope, always removed by ce_checked_merge.
def ce_merge_origin(source:auto; builder:auto; location:string) {}
// A materialized resumable merge keeps its left type for diagnostic recovery.
def ce_merge_origin(source:auto; builder:auto; location:string; left:auto) {}
def ce_protocol(builder:auto) => CeMissingProtocol()
struct CeRunFallback {_ce_marker:uint8}
def ce_run(builder:auto; outcome:auto) => CeRunFallback()

// Optional eager loops. Marker overloads are only inspected at compile time.
struct CeLoopFallback {_ce_marker:uint8}
def ce_for(builder:auto; source:auto; body:auto) => CeLoopFallback()
def ce_while(builder:auto; condition:auto; body:auto) => CeLoopFallback()

// Used only under typedecl; never traverses the source at runtime.
def ce_for_element(source:auto) {
    for (value in source) { var item : typedecl(value) -const -&; return <- item }
}

def ce_for_element(var source:iterator<auto(TT)>) {
    var item : TT -const -&
    return <- item
}

// Preserve native for references when iterating arrays (type-only calls).
def ce_for_element(var source:array<auto(TT)> ==const) : TT& { unsafe { return source[0] } }
def ce_for_element(source:array<auto(TT)> ==const) : TT const& { unsafe { return source[0] } }
def ce_for_element(var source:auto(TT)[] ==const) : TT& { unsafe { return source[0] } }
def ce_for_element(source:auto(TT)[] ==const) : TT const& { unsafe { return source[0] } }

// Optional simultaneous For of any arity. traverse(visitor) retains native source
// evaluation and element references; visitor(body) returns whether to continue.
def ce_for_zip(builder:auto; arity:int; traverse:auto) => CeLoopFallback()

// Optional source conversion. The marker is erased without evaluating this call.
struct CeSourceFallback {_ce_marker:uint8}
def ce_source(builder:auto; source:auto) => CeSourceFallback()

// A source the builder cannot bind. ce_unwrap answers with a marker, so the
// compiler does not list every ce_unwrap of every builder; the operation that
// consumes the source then reports one error, at the user's statement. Each
// of them returns a value of the type the lowering expects, so that nothing
// else fails after the report.
struct CeNotBindable {_ce_marker:uint8}
def ce_unwrap(builder:auto; source:auto) => CeNotBindable()
def ce_unwrap_borrow(builder:auto; source:auto) => CeNotBindable()
def ce_bind(builder:auto; source:auto; next:block<(value:CeNotBindable):auto(RR)>) : RR -const -& {
    concept_assert(false, "computation: {typeinfo stripped_typename(builder)} cannot bind a source of type {typeinfo stripped_typename(source)}: no ce_unwrap(builder, source) accepts it")
    var result : RR -const -&
    return <- result
}
def ce_bind(builder:auto; source:auto; next:block<(var value:CeNotBindable&):auto(RR)>) : RR -const -& {
    concept_assert(false, "computation: {typeinfo stripped_typename(builder)} cannot bind a source of type {typeinfo stripped_typename(source)}: no ce_unwrap(builder, source) accepts it")
    var result : RR -const -&
    return <- result
}
def ce_direct_failed(builder:auto; source:auto) : bool {
    concept_assert(false, "computation: {typeinfo stripped_typename(builder)} cannot bind a source of type {typeinfo stripped_typename(source)}: no ce_unwrap(builder, source) accepts it")
    return false
}
// ce_direct_failed has already reported a source that cannot be bound at all.
def ce_direct_failure(builder:auto; source:auto; witness:auto(RR)?) : RR -const -& {
    static_if (typeinfo stripped_typename(_::ce_unwrap(builder, source)) != "builder_protocol::CeNotBindable") {
        concept_assert(false, "computation: {typeinfo stripped_typename(builder)} has no ce_direct_failure for a source of type {typeinfo stripped_typename(source)}")
    }
    var result : RR -const -&
    return <- result
}

// Eager outcomes with explicit ownership and consuming bind.
struct CeOwnedProtocol {_ce_marker:uint8}

// A Value builder whose bind and Combine only short-circuit. Its scope is
// lowered without continuations: besides the Value operations it defines
// ce_direct_failed(builder, source) : bool and ce_direct_failure(builder,
// source, witness : auto(R)?) : R, and its ce_unwrap really extracts the value.
struct CeDirectProtocol {_ce_marker:uint8}

// Type-only helpers for direct lowering: what the optional ce_source hook makes
// of a source, and what a bind of that source produces. They pick the hook's
// result by overload, so the type is known without rewriting the call.
// `_::` looks the builder's own operations up where the scope is compiled.
def ce_direct_picked(source:auto(SS); hook:CeSourceFallback) : SS -const -& => source
def ce_direct_picked(source:auto; hook:auto(HH)) : HH -const -& => hook
def ce_direct_resolved(builder:auto; source:auto) =>
    ce_direct_picked(source,_::ce_source(builder,source))
def ce_direct_typed(builder:auto; source:auto) =>
    _::ce_unwrap(builder,ce_direct_resolved(builder,source))

// Opt-in linear bind/return collection fusion. Descriptor calls are type-only.
struct CeCollectSink {_ce_marker:uint8}
struct CeCollectSinkFallback {_ce_marker:uint8}
def ce_collect_sink(builder:auto) => CeCollectSinkFallback()

def ce_collect_sink_protocol(unused:type<auto(TT)>) {
    var marker:TT -const -&?
    return (kind=CeCollectSink(),element=marker)
}
