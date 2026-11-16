options gen2
module builder_protocol public
require daslib/result public
require daslib/ast_boost
require daslib/templates_boost
require ./computation_resources.das public
require daslib/rtti

//! The protocol between the ``computation`` macro and a builder: the strategy descriptors that a builder's
//! ``ce_protocol`` returns, the unit value ``CeUnit``, and the default of every optional hook.
//! Require it in a module that defines a builder of its own. A builder is a value of any type plus ``ce_*``
//! overloads for that type; a more specific overload always wins over a default declared here.

//! Strategy descriptor of an eager builder with copyable outcomes: ``ce_protocol(builder)`` returns it.
//! The scope is lowered into ``ce_bind`` and ``ce_combine`` calls that receive the rest of the scope as a
//! block and decide whether, and how many times, to run it. ``ce_protocol`` is only typed, never called.
struct CeValueProtocol {_ce_marker:uint8}
//! Strategy descriptor of an eager builder that accumulates an owned result, such as an array. It adds
//! ``yield`` and ``yield_from`` to the Value operations. Outcomes are moved, so the builder's operations
//! return with ``return <-`` and the result type must support ``inscope``.
struct CeCollectProtocol {_ce_marker:uint8}
//! Strategy marker of a lazy builder: the scope becomes a native generator of elements.
//! ``ce_protocol`` returns it paired with the element type, see ``ce_sequence_protocol``.
struct CeSequenceProtocol {_ce_marker:uint8}
//! Strategy marker of a builder whose computation can suspend, such as a task: the scope becomes a
//! generator of the builder's events. ``ce_protocol`` returns it paired with the event type, see
//! ``ce_resumable_protocol``.
struct CeResumableProtocol {_ce_marker:uint8}
//! The value of a step that produces nothing useful: a ``bind`` without a variable, a loop iteration,
//! a scope that ends without ``return``. It is a success, not a failure such as ``none`` or ``err``.
struct CeUnit {_ce_marker:uint8}

//! Moves ``value`` into the ``some`` of a standard ``Option``; the source is left empty. Use it for a
//! payload that cannot be copied, such as an array or a tuple that holds one.
// Standard Option representation, with a separate field move for the SDK AOT
// tuple-in-variant initializer bug. Arrays and tuple/struct payloads stay owned.
def ce_move_some(var value:auto(TT)) : Option<TT -const -&> {
    var vacant=default<TT -const -&>
    var result <- option::move_some(vacant)
    result as some <- value
    return <- result
}
//! What the default ``ce_await_zero`` returns: nothing is yielded when the body ends without ``return``.
struct CeResumableNoZero {_ce_marker:uint8}
//! Optional hook of a resumable builder: the final event of a computation whose body ends without
//! ``return``. The default returns ``CeResumableNoZero``, and no event is yielded.
def ce_await_zero(builder:auto) => CeResumableNoZero()

//! What the default ``ce_await_for_source`` and ``ce_await_for_merge`` return: the ``for`` source is not
//! asynchronous, and the loop stays a native ``for``. Only the type is inspected; the calls never run.
struct CeResumableForFallback {_ce_marker:uint8}
//! Optional hook of a resumable builder: turns a ``for`` source that has to be awaited into an iterator
//! of events with a ``ready`` field. A pending event makes the computation yield ``ce_await_pending(builder)``;
//! a ready one runs the loop body with ``ce_await_for_value(builder, event)``. The iterator owns ``source``,
//! closes it when it is closed itself, and stops once ``control`` reports a ``break``.
def ce_await_for_source(builder:auto; source:auto; control:auto) => CeResumableForFallback()
//! Optional hook of a resumable builder: joins two asynchronous ``for`` sources into one whose element is
//! the pair ``(first, second)``. A ``for`` over several sources folds them with it from left to right.
def ce_await_for_merge(builder:auto; left,right:auto) => CeResumableForFallback()
//! What the default ``ce_await_input`` returns: the builder does not walk awaited sources itself.
struct CeAwaitInputFallback {_ce_marker:uint8}
//! Optional hook of a sequence builder that awaits its sources: ``ce_await_input(builder, source)`` returns
//! the iterator that a ``bind`` walks in place of ``ce_await_source(builder, source)``. That iterator owns
//! ``source`` and closes it. A builder without the hook keeps the walk over ``ce_await_source``.
def ce_await_input(builder:auto; source:auto) => CeAwaitInputFallback()
//! What the default ``ce_deferred_payload`` returns: the result of a deferred run is checked as it is.
struct CeDeferredPayloadFallback {_ce_marker:uint8}
//! Optional hook for a result that wraps its payload, as a task wraps its value: returns a null pointer
//! to the payload's type, so that ``deferred`` checks that the payload, not the wrapper, owns its data.
//! It is only typed, never called.
def ce_deferred_payload(result:auto) => CeDeferredPayloadFallback()
//! Reports, at compile time, a resumable ``for`` that mixes asynchronous sources with native ones.
//! Generated code calls it for such a loop.
def ce_await_for_incompatible(builder:auto) {
    concept_assert(false,"async For: all sources must support ce_await_for_merge; cannot mix AsyncSequence and native sources")
}

//! The descriptor that a lazy builder's ``ce_protocol`` returns: the computation becomes a generator of
//! ``TT``, handed once to ``ce_sequence_run(builder, source)`` when the computation is created.
def ce_sequence_protocol(unused : type<auto(TT)>) =>
    (strategy=CeSequenceProtocol(), element=default<TT -const -&>)

//! The descriptor that a resumable builder's ``ce_protocol`` returns: the computation becomes a generator
//! of events of type ``TT``, built with the builder's ``ce_await_*`` hooks and handed to ``ce_sequence_run``.
def ce_resumable_protocol(unused:type<auto(TT)>) =>
    (strategy=CeResumableProtocol(),element=default<TT -const -&>)

//! Runs ``body``, the delayed body of a computation, and returns its outcome. This default invokes it at
//! once and copies the outcome; a builder with move-only outcomes overloads it with ``return <-``.
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
//! ``typeinfo ce_canonical(value)`` is ``value`` with the generic aliases removed from its type. A generic
//! operation that returns a standard template, such as a ``Result`` of a pair, wraps its result in it, so
//! that the names of its own ``auto(TT)`` parameters do not leak into the result type.
[typeinfo_macro(name="ce_canonical")]
class CeCanonical : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?;var errors:das_string) : ExpressionPtr {
        if(expr.subexpr==null || expr.subexpr._type==null || expr.subexpr._type.isAutoOrAlias) {return null}
        let clean=ce_canonical_type(expr.subexpr._type)
        return qmacro_expr() {reinterpret<$t(clean)>($e(expr.subexpr))}
    }
}
//! The pair ``(first, second)`` that an ``and_bind`` group binds, with a canonical type. Overloads of
//! ``ce_merge_sources``, ``ce_bind2`` and ``ce_bind2_return`` build their payload with it.
def ce_source_pair(first:auto;second:auto) => typeinfo ce_canonical((first=first,second=second))

//! Runs the continuation ``next`` over ``source``, an owned temporary that generated code releases when
//! this call returns, and moves the result out. Generated code calls it; a builder does not.
// The continuation arrives as an argument, so generated code names it once
// instead of once for its type and once to run.
def ce_owned_apply_move(var source : auto; next : auto) {
    var inscope result : typedecl(invoke(next, source))
    result <- invoke(next, source)
    return <- result
}
//! The same for a continuation whose result is copied.
def ce_owned_apply_copy(var source : auto; next : auto) {
    var result : typedecl(invoke(next, source))
    result = invoke(next, source)
    return result
}




//! What the default ``ce_bind_return``, ``ce_bind2_return`` and ``ce_bind2`` return: the builder has no such
//! operation, and the macro keeps the ordinary ``ce_bind`` and ``ce_return``. Only the type is inspected;
//! the defaults never run.
struct CeBindReturnFallback {_ce_marker:uint8}
//! Optional operation: a ``bind`` followed at once by the final ``return``, in one call. ``mapper`` turns
//! the bound value into the returned one; the result is what ``ce_return`` of that value would produce.
def ce_bind_return(builder:auto; source:auto; mapper:auto) => CeBindReturnFallback()

//! Optional operation: an ``and_bind`` group followed at once by the final ``return``. ``mapper`` receives
//! the pair ``(first, second)`` of the two bound values.
def ce_bind2_return(builder:auto; left:auto; right:auto; mapper:auto) => CeBindReturnFallback()

//! Optional operation: an ``and_bind`` group with a continuation. ``next`` receives the pair
//! ``(first, second)`` and returns an outcome of the builder. Without it the group goes through
//! ``ce_merge_sources`` and ``ce_bind``.
def ce_bind2(builder:auto; left:auto; right:auto; next:auto) => CeBindReturnFallback()

//! What the default ``ce_protocol`` returns: the builder declares no strategy, which ``computation``
//! reports as a compile error.
struct CeMissingProtocol {_ce_marker:uint8}
//! What the default ``ce_merge_sources`` returns: the builder cannot group these sources with
//! ``and_bind``, which is reported as a compile error at the group.
struct CeMergeSourcesFallback {_ce_marker:uint8}
//! The operation behind ``left |> and_bind(right) |> bind``: combines two computed sources into one
//! source whose payload is the pair ``(first, second)``. A builder overloads it for the sources it can group.
def ce_merge_sources(builder:auto; left,right:auto) => CeMergeSourcesFallback()
//! The envelope that the macro puts around a ``ce_merge_sources`` call to carry the builder and the
//! source position into the error about an unsupported ``and_bind``. It is only typed and never runs.
def ce_merge_origin(source:auto; builder:auto; location:string) {}
// A materialized resumable merge keeps its left type for diagnostic recovery.
def ce_merge_origin(source:auto; builder:auto; location:string; left:auto) {}
//! Selects how a computation over ``builder`` is lowered. A builder overloads it to return
//! ``CeValueProtocol``, ``CeDirectProtocol``, ``CeOwnedProtocol``, ``CeCollectProtocol``,
//! ``ce_sequence_protocol(type<T>)`` or ``ce_resumable_protocol(type<Event>)``. The call is typed with a
//! default value of the builder's type and never runs.
def ce_protocol(builder:auto) => CeMissingProtocol()
//! What the default ``ce_run`` returns: the outcome of the computation is its result, unchanged.
struct CeRunFallback {_ce_marker:uint8}
//! Optional final step: receives the outcome of the whole computation, after its cleanup, and returns
//! the value that ``computation(builder) { ... }`` evaluates to, which may have another type.
def ce_run(builder:auto; outcome:auto) => CeRunFallback()

//! What the default ``ce_for``, ``ce_while`` and ``ce_for_zip`` return: the builder does not take over the
//! loop, which is then lowered with ``ce_loop_append`` and ``ce_loop_failed``, or ``ce_collect_append``.
//! Only the type is inspected.
struct CeLoopFallback {_ce_marker:uint8}
//! Optional hook for a ``for`` over one source in an eager builder. The hook walks ``source`` and invokes
//! ``body`` with each element; ``body`` returns the outcome of one iteration. The hook decides when to
//! stop and returns the outcome of the loop.
def ce_for(builder:auto; source:auto; body:auto) => CeLoopFallback()
//! Optional hook for a ``while`` in an eager builder. ``condition`` and ``body`` arrive as blocks; the hook
//! runs them and returns the outcome of the loop.
def ce_while(builder:auto; condition:auto; body:auto) => CeLoopFallback()

//! The element that a native ``for`` over ``source`` binds. The macro uses it under ``typedecl`` to type
//! the loop variable; it never walks the source at run time.
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

//! Optional hook for a ``for`` over ``arity`` sources at once in an eager builder. ``traverse(visit)`` walks
//! the sources as a native ``for`` does, keeping its element references, and calls ``visit(body)`` for every
//! step. The hook's ``visit`` invokes ``body`` for the outcome of the iteration and returns whether to
//! continue. The hook returns the outcome of the loop.
def ce_for_zip(builder:auto; arity:int; traverse:auto) => CeLoopFallback()

//! What the default ``ce_source`` returns: the source is used as it is written.
struct CeSourceFallback {_ce_marker:uint8}
//! Optional hook: converts what is written as the source of a ``bind``, ``for``, ``return_from`` or
//! ``yield_from`` into a source that the builder's other operations accept. It runs once per source.
def ce_source(builder:auto; source:auto) => CeSourceFallback()

//! What the default ``ce_unwrap`` returns: the builder cannot bind a source of this type. The operation
//! that consumes the source then reports one compile error at the user's statement. A builder must not
//! define a ``ce_unwrap`` with ``source : auto``, which would accept every source.
// The marker keeps the compiler from listing every ce_unwrap of every builder.
// Each operation that reports the error returns a value of the type the
// lowering expects, so that nothing else fails after the report.
struct CeNotBindable {_ce_marker:uint8}
//! Names the type of the variable that a ``bind`` of ``source`` declares; a builder overloads it for every
//! source it binds. It is only typed, except in a ``CeDirectProtocol`` builder, where it runs and extracts
//! the value of a successful source.
def ce_unwrap(builder:auto; source:auto) => CeNotBindable()
//! The same for a borrowing ``var item & = source |> bind`` in a builder that is not ``CeOwnedProtocol``:
//! names the reference that the continuation receives while ``ce_bind`` owns the source.
def ce_unwrap_borrow(builder:auto; source:auto) => CeNotBindable()
//! Fallback of the bind operation: reports, at compile time, a source that no ``ce_unwrap`` of the builder
//! accepts. A builder's own ``ce_bind(builder, source, next)`` invokes ``next`` with each bound value, or
//! skips it, and returns the outcome.
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
//! Operation of a ``CeDirectProtocol`` builder: whether ``source`` failed, which ends the scope with
//! that failure. This fallback reports a source that the builder cannot bind.
def ce_direct_failed(builder:auto; source:auto) : bool {
    concept_assert(false, "computation: {typeinfo stripped_typename(builder)} cannot bind a source of type {typeinfo stripped_typename(source)}: no ce_unwrap(builder, source) accepts it")
    return false
}
//! Operation of a ``CeDirectProtocol`` builder: the failure of ``source`` as a value of the scope's
//! result type ``RR``. ``witness`` is a null pointer that only carries that type. This fallback reports
//! a builder that has no overload for the source.
// ce_direct_failed has already reported a source that cannot be bound at all.
def ce_direct_failure(builder:auto; source:auto; witness:auto(RR)?) : RR -const -& {
    static_if (typeinfo stripped_typename(_::ce_unwrap(builder, source)) != "builder_protocol::CeNotBindable") {
        concept_assert(false, "computation: {typeinfo stripped_typename(builder)} has no ce_direct_failure for a source of type {typeinfo stripped_typename(source)}")
    }
    var result : RR -const -&
    return <- result
}

//! Strategy descriptor of an eager builder whose outcomes are moved, never copied. ``ce_bind`` takes
//! ownership of its source and lends the payload to the continuation by reference; ``return <- value``
//! goes to ``ce_return_move``.
struct CeOwnedProtocol {_ce_marker:uint8}

//! Strategy descriptor of a Value builder whose bind and Combine only short-circuit, such as Result.
//! Its scope is lowered without continuations, so ``if``, loops, ``break``, ``continue`` and an early
//! ``return`` stay native. Besides the Value operations the builder defines
//! ``ce_direct_failed(builder, source) : bool`` and ``ce_direct_failure(builder, source, witness : auto(RR)?) : RR``,
//! and its ``ce_unwrap`` really extracts the value.
struct CeDirectProtocol {_ce_marker:uint8}

//! Type-only helper of the direct lowering: the source itself when the ``ce_source`` hook is the default
//! one, otherwise what the hook made of it. Generated code uses it to name a type; a builder does not
//! overload it.
// The helpers pick the hook's result by overload, so the type is known
// without rewriting the call.
// `_::` looks the builder's own operations up where the scope is compiled.
def ce_direct_picked(source:auto(SS); hook:CeSourceFallback) : SS -const -& => source
def ce_direct_picked(source:auto; hook:auto(HH)) : HH -const -& => hook
//! Type-only helper of the direct lowering: the source of a ``bind`` after the builder's optional
//! ``ce_source`` hook.
def ce_direct_resolved(builder:auto; source:auto) =>
    ce_direct_picked(source,_::ce_source(builder,source))
//! Type-only helper of the direct lowering: the value that a ``bind`` of ``source`` declares, which is
//! ``ce_unwrap`` of the resolved source.
def ce_direct_typed(builder:auto; source:auto) =>
    _::ce_unwrap(builder,ce_direct_resolved(builder,source))

//! Marker of the descriptor that opts a Collect builder into a single output, see ``ce_collect_sink_protocol``.
struct CeCollectSink {_ce_marker:uint8}
//! What the default ``ce_collect_sink`` returns: the builder accumulates with its ordinary operations.
struct CeCollectSinkFallback {_ce_marker:uint8}
//! Optional opt-in of a Collect builder: return ``ce_collect_sink_protocol(type<T>)`` to let a linear chain
//! of ``bind`` ... ``return`` write into one output with ``ce_collect_into``, ``ce_collect_each`` and
//! ``ce_collect_emit``, instead of building a collection for every element. It is only typed, never called.
def ce_collect_sink(builder:auto) => CeCollectSinkFallback()

//! The descriptor that ``ce_collect_sink`` returns for a builder that collects elements of type ``TT``.
def ce_collect_sink_protocol(unused:type<auto(TT)>) {
    var marker:TT -const -&?
    return (kind=CeCollectSink(),element=marker)
}
