options gen2
options stack=262144
module computation_macro public
require ./builder_protocol.das public
require ./sequence_runtime.das public
require ./zip_runtime.das public
require ./resumable_lowering.das
require daslib/ast
require daslib/ast_boost
require daslib/templates_boost

// Preserve expression reference-ness; standard is_ref includes all ref types.
[typeinfo_macro(name="ce_source_is_borrowed")]
class CeSourceBorrowed : AstTypeInfoMacro {
    def override getAstChange(expr : ExprTypeInfo?; var errors : das_string) : ExpressionPtr {
        if (expr.subexpr == null || expr.subexpr._type == null) {
            errors := "computation: source type must be inferred"
            return null
        }
        // Const array parameters can be ExprVar without the explicit ref flag.
        // A named variable still belongs to its caller; only temporaries move here.
        return <- new ExprConstBool(at=expr.at, value=expr.subexpr._type.flags.ref || (expr.subexpr is ExprVar))
    }
}

// Resolve the optional Source hook without an identity function copying/moving input.
[typeinfo_macro(name="ce_resolved_source")]
class CeResolvedSource : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?; var errors:das_string) : ExpressionPtr {
        if (expr.subexpr==null || expr.subexpr._type==null || !(expr.subexpr is ExprCall)) {
            errors := "computation: source hook must be inferred"
            return null
        }
        let call=expr.subexpr as ExprCall
        let t=call._type
        if (t.baseType==Type.tVoid) {
            errors := "computation: ce_source must return a source, not void"
            return null
        }
        if (t.baseType==Type.tStructure && t.structType.name=="CeSourceFallback"
                && t.structType._module.name=="builder_protocol") {
            return clone_expression(call.arguments[1])
        }
        return clone_expression(call)
    }
}
def ce_normalize_source(builder:string; source:ExpressionPtr) : ExpressionPtr {
    if(source is ExprCall) {
        let call=source as ExprCall
        if((call.name=="state_modify" || call.name=="state_gets") && length(call.arguments)==1) {
            var applied=qmacro(ce_state_modify($i(builder),$e(call.arguments[0])))
            if(call.name=="state_gets") {applied=qmacro(ce_state_gets($i(builder),$e(call.arguments[0])))}
            applied.at=source.at
            return applied
        }
    }
    var result=qmacro(typeinfo ce_resolved_source(ce_source($i(builder),$e(source))))
    result.at=source.at
    return result
}
def ce_return_from_source(builder:string; source:ExpressionPtr; collect:bool; owned:bool=false) : ExpressionPtr {
    let normalized=ce_normalize_source(builder,source)
    let name=ce_unique_name("__ce_return_source",source.at)
    var next=qmacro($($i(name):typedecl($e(normalized))) {
        return ce_return_from($i(builder),$i(name))
    })
    if (collect) {
        next=qmacro($($i(name):typedecl($e(normalized))) {
            return <- ce_return_from($i(builder),$i(name))
        })
    }
    if (owned) {((next as ExprMakeBlock)._block as ExprBlock).arguments[0]._type.flags.constant=false}
    return ce_source_apply(normalized,next,true,collect)
}
def ce_normalize_for(builder:string; statement:ExpressionPtr) : ExpressionPtr {
    var result=clone_expression(statement) as ExprFor
    for (source in result.sources) {source=ce_normalize_source(builder,source)}
    return result
}

// and_bind is a source-tree marker, consumed only immediately under bind.
var private ce_merge_locations : table<string;ExpressionPtr>
[typeinfo_macro(name="ce_checked_merge")]
class CeCheckedMerge : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?; var errors:das_string) : ExpressionPtr {
        if(expr.subexpr==null || expr.subexpr._type==null) {errors:="computation: and_bind source types must be inferred";return null}
        let envelope=expr.subexpr as ExprCall
        let merged=envelope.arguments[0]
        let t=merged._type
        if(t.baseType==Type.tStructure && t.structType.name=="CeMergeSourcesFallback"
                && t.structType._module.name=="builder_protocol") {
            let location=string((envelope.arguments[2] as ExprConstString).value)
            errors:="computation: and_bind is unsupported for builder {describe(envelope.arguments[1]._type)} and these sources at {location}; define ce_merge_sources(builder, left, right) or use sequential bind"
            if(key_exists(ce_merge_locations,location)) {
                let message=string(errors)
                var failure=qmacro(static_assert(false,$v(message)))
                failure.at=ce_merge_locations[location].at
                var left=clone_expression(merged)
                if(length(envelope.arguments)==4) {left=clone_expression(envelope.arguments[3])}
                elif(merged is ExprCall) {left=clone_expression((merged as ExprCall).arguments[1])}
                var invalid=qmacro(invoke($ {
                    $e(failure);
                    static_if(typeinfo can_copy($e(left))) {return $e(left)}
                    else {return <- $e(left)}
                }))
                invalid.at=ce_merge_locations[location].at
                let originBody=((invalid as ExprInvoke).arguments[0] as ExprMakeBlock)._block as ExprBlock
                var assertion=clone_expression(originBody.list[0])
                assertion.at=ce_merge_locations[location].at
                (((invalid as ExprInvoke).arguments[0] as ExprMakeBlock)._block as ExprBlock).list[0]=assertion
                errors := ""
                return invalid
            }
            return null
        }
        return clone_expression(merged)
    }
}
def ce_merge_source(node : ExpressionPtr; builder : string; var error : string&) : ExpressionPtr {
    if (node is ExprCall && (node as ExprCall).name == "and_bind") {
        let call = node as ExprCall
        if (length(call.arguments) != 2) {
            error = "computation: expected 'left |> and_bind(right) |> bind'"
            return null
        }
        var left = ce_merge_source(call.arguments[0], builder, error)
        if (!empty(error)) { return null }
        var right = ce_merge_source(call.arguments[1], builder, error)
        if (!empty(error)) { return null }
        let location="{node.at.fileInfo.name}:{int(node.at.line)}:{int(node.at.column)}"
        ce_merge_locations |> insert(location,new ExprConstBool(at=node.at,value=true))
        var merged = qmacro(typeinfo ce_checked_merge(ce_merge_origin(ce_merge_sources($i(builder), $e(left), $e(right)), $i(builder), $v(location))))
        merged.at = node.at
        return merged
    }
    return ce_normalize_source(builder,node)
}

// Resumable sources transfer ownership before suspension. Materialize each
// product once. Save exceptions before running any source finalizer, outside
// recover, so a close callback cannot replace the original factory error.
def ce_resumable_merge_source(node:ExpressionPtr; builder:string; var error:string&) : ExpressionPtr {
    if(!(node is ExprCall) || (node as ExprCall).name!="and_bind") {return ce_normalize_source(builder,node)}
    let call=node as ExprCall
    if(length(call.arguments)!=2) {error="computation: expected 'left |> and_bind(right) |> bind'";return null}
    let left=ce_resumable_merge_source(call.arguments[0],builder,error)
    let right=ce_resumable_merge_source(call.arguments[1],builder,error)
    if(!empty(error)) {return null}
    let ln=ce_unique_name("__await_left",node.at)
    let rn=ce_unique_name("__await_right",node.at)
    let result=ce_unique_name("__await_product",node.at)
    let failure=result+"_error"
    let failed=result+"_failed"
    let location="{node.at.fileInfo.name}:{int(node.at.line)}:{int(node.at.column)}"
    ce_merge_locations |> insert(location,new ExprConstBool(at=node.at,value=true))
    let merged=qmacro(ce_merge_sources($i(builder),$i(ln),$i(rn)))
    let checked=qmacro(typeinfo ce_checked_merge(ce_merge_origin($i(result),$i(builder),$v(location),$i(ln))))
    let closeLeft=qmacro_expr() {static_if(typeinfo can_delete($i(ln))) {delete $i(ln)}}
    let closeRight=qmacro_expr() {static_if(typeinfo can_delete($i(rn))) {delete $i(rn)}}
    let closeResult=qmacro_expr() {static_if(typeinfo can_delete($i(result))) {delete $i(result)}}
    // These are explicit owners, not inscope: cleanup must run after the primary
    // exception is saved, and a returned product already owns both children.
    return qmacro(invoke($ {
        var $i(ln):typedecl($e(left))
        static_if(typeinfo can_copy($e(left))) {$i(ln)=$e(left)}
        else {$i(ln) <- $e(left)}
        var $i(rn):typedecl($e(right))
        var $i(failure)=""
        var $i(failed)=false
        try {
            static_if(typeinfo can_copy($e(right))) {$i(rn)=$e(right)}
            else {$i(rn) <- $e(right)}
        } recover {$i(failed)=true;$i(failure)=ce_exception_message()}
        if($i(failed)) {$e(closeLeft);$e(closeRight);panic($i(failure))}
        var $i(result):typedecl($e(merged))
        try {
            static_if(typeinfo can_copy($e(merged))) {$i(result)=$e(merged)}
            else {$i(result) <- $e(merged)}
        } recover {$i(failed)=true;$i(failure)=ce_exception_message()}
        $e(closeLeft);$e(closeRight)
        if($i(failed)) {$e(closeResult);panic($i(failure))}
        return <- $e(checked)
    }))
}

// ---- Deferred stages ---------------------------------------------------------
// A stage is this same call macro under another name. It waits until its probe
// arguments are typed and then emits exactly one variant, so a continuation is
// never cloned into alternatives that a static_if would discard afterwards.
// Arguments: operation name, probe slot count, probe slots (inferred in place),
// then payload (not inferred until the stage has emitted it).
// A probe takes two slots. A source normalized by ce_normalize_source is split
// into the raw expression and its ce_source hook call: both are plain calls,
// typed in the pass that first sees them, so resolving the hook costs no pass.
def private ce_stage_push_probe(var slots : array<ExpressionPtr>; probe : ExpressionPtr) {
    if (probe is ExprTypeInfo) {
        let info = probe as ExprTypeInfo
        if (info.trait == "ce_resolved_source" && info.subexpr != null && info.subexpr is ExprCall) {
            slots |> push <| clone_expression((info.subexpr as ExprCall).arguments[1])
            slots |> push <| clone_expression(info.subexpr)
            return
        }
    }
    slots |> push <| clone_expression(probe)
    slots |> push <| new ExprConstBool(at=probe.at, value=false)
}

def ce_stage(op : string; at : LineInfo; probes : array<ExpressionPtr>; payload : array<ExpressionPtr>) : ExpressionPtr {
    // Other call macros lower sources too, so the node is built from the
    // registered macro instead of a clone of whatever is being visited.
    var stage = new ExprCallMacro(at=at, name:="__ce_stage",
        macro=find_call_macro(find_module(compiling_program(), "computation_macro"), "computation"))
    var slots : array<ExpressionPtr>
    for (probe in probes) { ce_stage_push_probe(slots, probe) }
    stage.arguments |> push <| new ExprConstString(at=at, value:=op)
    stage.arguments |> push <| new ExprConstInt(at=at, value=length(slots))
    for (slot in slots) { stage.arguments |> push <| slot }
    for (item in payload) { stage.arguments |> push <| clone_expression(item) }
    return stage
}

// qmacro restamps the node it substitutes with the template position; the
// arguments below it keep the position of the statement being lowered.
def private ce_stage_at(expr : ExprCallMacro?) : LineInfo {
    return expr.arguments[0].at
}
def private ce_stage_probe_slots(expr : ExprCallMacro?) : int {
    return (expr.arguments[1] as ExprConstInt).value
}
def private ce_stage_payload(var expr : ExprCallMacro?; index : int) : ExpressionPtr {
    return expr.arguments[2 + ce_stage_probe_slots(expr) + index]
}
def private ce_stage_flag(var expr : ExprCallMacro?; index : int) : bool {
    return (ce_stage_payload(expr, index) as ExprConstBool).value
}
def private ce_stage_text(var expr : ExprCallMacro?; index : int) : string {
    return string((ce_stage_payload(expr, index) as ExprConstString).value)
}
def private ce_stage_ready(expr : ExprCallMacro?) : bool {
    // An unsupported and_bind group is reported at once: its hook probes
    // cannot be typed, because there is no merged value to unwrap.
    if ((expr.arguments[0] as ExprConstString).value == "bind2") {
        let merged = expr.arguments[2]
        if (merged._type != null && ce_is_protocol(merged._type, "CeMergeSourcesFallback")) { return true }
        // Not having a Zero is an answer too; the hook probe that needs it never types.
        if (merged._type != null && !merged._type.isAutoOrAlias
                && ce_stage_unresolved_call(expr.arguments[8])) { return true }
    }
    for (index in range(ce_stage_probe_slots(expr))) {
        let probe = expr.arguments[2 + index]
        if (probe is ExprConstBool) { continue }
        if (probe._type == null || probe._type.isAutoOrAlias) { return false }
    }
    return true
}
// The inferred probe is returned as is; the emitted code holds a clone of it.
def private ce_stage_probe(var expr : ExprCallMacro?; index : int; var error : string&) : ExpressionPtr {
    var raw = expr.arguments[2 + index * 2]
    var hook = expr.arguments[2 + index * 2 + 1]
    if (hook is ExprConstBool) { return raw }
    if (hook._type.baseType == Type.tVoid) {
        error = "computation: ce_source must return a source, not void"
        return null
    }
    return ce_is_protocol(hook._type, "CeSourceFallback") ? raw : hook
}
// Same rule as typeinfo ce_source_is_borrowed, applied to an inferred probe.
def private ce_stage_borrowed(source : ExpressionPtr) : bool {
    return source._type.flags.ref || (source is ExprVar)
}
// What `name : typedecl(source)` resolves to, without keeping the source
// expression inside the type: a clone of it there doubles every nested scope.
def private ce_stage_retype_argument(var next : ExpressionPtr; source : TypeDeclPtr) {
    var argument = ((next as ExprMakeBlock)._block as ExprBlock).arguments[0]
    let declared = argument._type
    if (declared.baseType != Type.typeDecl) { return }
    var resolved = clone_type(source)
    resolved.flags.ref = declared.flags.ref && !declared.flags.removeRef
    resolved.flags.constant = (resolved.flags.constant || declared.flags.constant) && !declared.flags.removeConstant
    resolved.flags.temporary = (resolved.flags.temporary || declared.flags.temporary) && !declared.flags.removeTemporary
    argument._type = resolved
}

// Run a continuation while keeping an owned temporary alive. Borrowed arrays
// remain borrowed; factories and intermediate products are released on panic too.
// `retype` is false when the continuation's argument is not typedecl(source).
def ce_source_apply(source, next : ExpressionPtr; collect : bool; move_result:bool=true; retype:bool=true) : ExpressionPtr {
    if (!collect) { return qmacro(invoke($e(next), $e(source))) }
    var probes : array<ExpressionPtr>
    probes |> push <| clone_expression(source)
    var payload : array<ExpressionPtr>
    payload |> push <| clone_expression(next)
    payload |> push <| new ExprConstBool(at=source.at, value=move_result)
    payload |> push <| new ExprConstBool(at=source.at, value=retype)
    return ce_stage("apply", source.at, probes, payload)
}
// Copyable and borrowed sources go straight to the continuation; an owned
// temporary is scoped here and released if the continuation throws.
def private ce_stage_apply_emit(source, next : ExpressionPtr; move_result : bool; at : LineInfo) : ExpressionPtr {
    if (source._type.canCopy || ce_stage_borrowed(source)) {
        return qmacro(invoke($e(next), $e(source)))
    }
    let ownedName = ce_unique_name("__ce_owned_source", at)
    if (move_result) {
        return qmacro(invoke($ {
            var inscope $i(ownedName) <- $e(source)
            return <- ce_owned_apply_move($i(ownedName), $e(next))
        }))
    }
    return qmacro(invoke($ {
        var inscope $i(ownedName) <- $e(source)
        return ce_owned_apply_copy($i(ownedName), $e(next))
    }))
}
def private ce_stage_apply(var expr : ExprCallMacro?; var error : string&) : ExpressionPtr {
    let source = ce_stage_probe(expr, 0, error)
    if (source == null) { return null }
    var next = clone_expression(ce_stage_payload(expr, 0))
    if (ce_stage_flag(expr, 2)) { ce_stage_retype_argument(next, source._type) }
    return ce_stage_apply_emit(source, next, ce_stage_flag(expr, 1), ce_stage_at(expr))
}
def private ce_stage_statements(blk : ExpressionPtr) : array<ExpressionPtr> {
    var list : array<ExpressionPtr>
    for (entry in ((blk as ExprMakeBlock)._block as ExprBlock).list) { list |> push <| clone_expression(entry) }
    return <- list
}
// Payload of a bind: 0 rest of the scope, 1 the fused `bind; return` body or
// false, 2 argument name, 3 builder name, 4 collect, 5 owned, 6 borrowing bind.
def private ce_bind_continuation(builder, argument : string; source : ExpressionPtr;
                                 var rest : array<ExpressionPtr>; owned, borrow_bind : bool) : ExpressionPtr {
    if (borrow_bind && !owned) {
        return qmacro($(var $i(argument):typedecl(ce_unwrap_borrow($i(builder),$e(source)))&) {$b(rest);})
    }
    if (owned || borrow_bind) {
        return qmacro($(var $i(argument):typedecl(ce_unwrap($i(builder),$e(source)))&) {$b(rest);})
    }
    return qmacro($($i(argument) : typedecl(ce_unwrap($i(builder), $e(source)))) { $b(rest); })
}
def private ce_bind_mapper(builder, argument : string; source : ExpressionPtr; var mapped : array<ExpressionPtr>) : ExpressionPtr {
    return qmacro($($i(argument) : typedecl(ce_unwrap($i(builder), $e(source)))) { $b(mapped); })
}
// Bind an inferred source to its continuation. Every use of the source is a
// clone of the probe, so the bound variable is typed in the following pass.
def private ce_bind_emit(builder : string; source, mapper, ordinary : ExpressionPtr;
                         collect_mode, mutable_bind : bool; at : LineInfo) : ExpressionPtr {
    let sourceName = ce_unique_name("__ce_group_source", at)
    var application = ce_bind_application(builder, qmacro($i(sourceName)), mapper, ordinary, mapper != null, collect_mode)
    var next : ExpressionPtr
    if (collect_mode) {
        next = qmacro($($i(sourceName):typedecl($e(source))) { return <- $e(application) })
    } else {
        next = qmacro($($i(sourceName):typedecl($e(source))) { return $e(application) })
    }
    if (mutable_bind) {((next as ExprMakeBlock)._block as ExprBlock).arguments[0]._type.flags.constant=false}
    ce_stage_retype_argument(next, source._type)
    return ce_stage_apply_emit(source, next, collect_mode, at)
}
def private ce_stage_bind(var expr : ExprCallMacro?; var error : string&) : ExpressionPtr {
    let source = ce_stage_probe(expr, 0, error)
    if (source == null) { return null }
    var rest <- ce_stage_statements(ce_stage_payload(expr, 0))
    let argument = ce_stage_text(expr, 2)
    let builder = ce_stage_text(expr, 3)
    let owned = ce_stage_flag(expr, 5)
    let borrow_bind = ce_stage_flag(expr, 6)
    var mapper : ExpressionPtr
    if (!(ce_stage_payload(expr, 1) is ExprConstBool)) {
        var mapped <- ce_stage_statements(ce_stage_payload(expr, 1))
        mapper = ce_bind_mapper(builder, argument, source, mapped)
    }
    var ordinary = ce_bind_continuation(builder, argument, source, rest, owned, borrow_bind)
    return ce_bind_emit(builder, source, mapper, ordinary, ce_stage_flag(expr, 4), owned || borrow_bind, ce_stage_at(expr))
}
// Bind of an and_bind group. The grouped hooks are optional. A fused
// `bind; return` is small, so its hooks are probed with the real blocks. A
// longer continuation is probed with one that only produces Zero, and the real
// one is emitted once. Probes: 0 the merged pair, 1 ce_bind2, 2 ce_bind2_return
// (fused only), 3 ce_zero (unfused only: a builder may have no Zero).
def private ce_bind2_stage(builder, leftName, rightName : string; pieces : array<ExpressionPtr>; at : LineInfo) : ExpressionPtr {
    let argument = string((pieces[2] as ExprConstString).value)
    let collect_mode = (pieces[4] as ExprConstBool).value
    let owned = (pieces[5] as ExprConstBool).value
    let borrow_bind = (pieces[6] as ExprConstBool).value
    let merged = qmacro(ce_merge_sources($i(builder), $i(leftName), $i(rightName)))
    var payload : array<ExpressionPtr>
    for (piece in pieces) { payload |> push <| clone_expression(piece) }
    payload |> push <| new ExprConstString(at=at, value:=leftName)
    payload |> push <| new ExprConstString(at=at, value:=rightName)
    var probes : array<ExpressionPtr>
    probes |> push <| clone_expression(merged)
    if (pieces[1] is ExprConstBool) {
        var zero : array<ExpressionPtr>
        if (collect_mode) { zero |> push <| qmacro_expr() { return <- ce_zero($i(builder)) } }
        else { zero |> push <| qmacro_expr() { return ce_zero($i(builder)) } }
        let trivial = ce_bind_continuation(builder, argument, merged, zero, owned, borrow_bind)
        probes |> push <| qmacro(ce_bind2($i(builder), $i(leftName), $i(rightName), $e(trivial)))
        probes |> push <| new ExprConstBool(at=at, value=false)
        probes |> push <| qmacro(ce_zero($i(builder)))
        return ce_stage("bind2", at, probes, payload)
    }
    var rest <- ce_stage_statements(pieces[0])
    let ordinary = ce_bind_continuation(builder, argument, merged, rest, owned, borrow_bind)
    probes |> push <| qmacro(ce_bind2($i(builder), $i(leftName), $i(rightName), $e(ordinary)))
    var mapped <- ce_stage_statements(pieces[1])
    let mapper = ce_bind_mapper(builder, argument, merged, mapped)
    probes |> push <| qmacro(ce_bind2_return($i(builder), $i(leftName), $i(rightName), $e(mapper)))
    probes |> push <| new ExprConstBool(at=at, value=false)
    return ce_stage("bind2", at, probes, payload)
}
def private ce_bind2_unsupported(var expr : ExprCallMacro?; merged : ExpressionPtr) : string {
    let builderType = (merged as ExprCall).arguments[0]._type
    return "computation: and_bind is unsupported for builder {describe(builderType)} and these sources at {ce_stage_at(expr).fileInfo.name}:{int(ce_stage_at(expr).line)}:{int(ce_stage_at(expr).column)}; define ce_merge_sources(builder, left, right) or use sequential bind"
}
// An unsupported group reports one error, at the and_bind itself, and then binds
// the left source alone: the rest of the scope stays typed, so the report is
// not followed by errors about everything that depended on the pair.
def private ce_bind2_invalid(var expr : ExprCallMacro?; merged : ExpressionPtr) : ExpressionPtr {
    let at = ce_stage_at(expr)
    let message = ce_bind2_unsupported(expr, merged)
    let left = (merged as ExprCall).arguments[1]
    let argument = ce_stage_text(expr, 2)
    let builder = ce_stage_text(expr, 3)
    let collect_mode = ce_stage_flag(expr, 4)
    let owned = ce_stage_flag(expr, 5)
    let borrow_bind = ce_stage_flag(expr, 6)
    var mapper : ExpressionPtr
    if (!(ce_stage_payload(expr, 1) is ExprConstBool)) {
        var mapped <- ce_stage_statements(ce_stage_payload(expr, 1))
        mapper = ce_bind_mapper(builder, argument, left, mapped)
    }
    var rest <- ce_stage_statements(ce_stage_payload(expr, 0))
    var ordinary = ce_bind_continuation(builder, argument, left, rest, owned, borrow_bind)
    let bound = ce_bind_emit(builder, left, mapper, ordinary, collect_mode, owned || borrow_bind, at)
    var invalid : ExpressionPtr
    if (collect_mode) {
        invalid = qmacro(invoke($ { static_assert(false, $v(message)); return <- $e(bound) }))
    } else {
        invalid = qmacro(invoke($ { static_assert(false, $v(message)); return $e(bound) }))
    }
    // qmacro stamped both with the template position; the error belongs to the user.
    invalid.at = at
    (((invalid as ExprInvoke).arguments[0] as ExprMakeBlock)._block as ExprBlock).list[0].at = at
    return invalid
}
// A call whose arguments are typed either resolves in the pass that sees it
// or never does: an unresolved one has no function.
def private ce_stage_unresolved_call(probe : ExpressionPtr) : bool {
    if (!(probe is ExprCall) || (probe as ExprCall).func != null) { return false }
    for (argument in (probe as ExprCall).arguments) {
        if (argument._type == null || argument._type.isAutoOrAlias) { return false }
    }
    return true
}
def private ce_stage_bind2(var expr : ExprCallMacro?; var error : string&) : ExpressionPtr {
    let merged = ce_stage_probe(expr, 0, error)
    if (ce_is_protocol(merged._type, "CeMergeSourcesFallback")) { return ce_bind2_invalid(expr, merged) }
    let argument = ce_stage_text(expr, 2)
    let builder = ce_stage_text(expr, 3)
    let owned = ce_stage_flag(expr, 5)
    let borrow_bind = ce_stage_flag(expr, 6)
    let leftName = ce_stage_text(expr, 7)
    let rightName = ce_stage_text(expr, 8)
    var mapper : ExpressionPtr
    if (!(ce_stage_payload(expr, 1) is ExprConstBool)) {
        var mapped <- ce_stage_statements(ce_stage_payload(expr, 1))
        mapper = ce_bind_mapper(builder, argument, merged, mapped)
        if (!ce_is_protocol(ce_stage_probe(expr, 2, error)._type, "CeBindReturnFallback")) {
            return qmacro(ce_bind2_return($i(builder), $i(leftName), $i(rightName), $e(mapper)))
        }
    }
    var rest <- ce_stage_statements(ce_stage_payload(expr, 0))
    var ordinary = ce_bind_continuation(builder, argument, merged, rest, owned, borrow_bind)
    let collect_mode = ce_stage_flag(expr, 4)
    if (ce_stage_unresolved_call(ce_stage_probe(expr, 3, error))) {
        // A builder without Zero: the hook is probed with the continuation itself.
        let fallback = ce_bind_emit(builder, merged, null, ordinary, collect_mode, owned || borrow_bind, ce_stage_at(expr))
        if (collect_mode) {
            return qmacro(invoke($ {
                static_if (typeinfo ce_has_bind_return(ce_bind2($i(builder), $i(leftName), $i(rightName), $e(ordinary)))) {
                    return <- ce_bind2($i(builder), $i(leftName), $i(rightName), $e(ordinary))
                } else { return <- $e(fallback) }
            }))
        }
        return qmacro(invoke($ {
            static_if (typeinfo ce_has_bind_return(ce_bind2($i(builder), $i(leftName), $i(rightName), $e(ordinary)))) {
                return ce_bind2($i(builder), $i(leftName), $i(rightName), $e(ordinary))
            } else { return $e(fallback) }
        }))
    }
    if (!ce_is_protocol(ce_stage_probe(expr, 1, error)._type, "CeBindReturnFallback")) {
        return qmacro(ce_bind2($i(builder), $i(leftName), $i(rightName), $e(ordinary)))
    }
    // No grouped hook: merge the sources and bind the pair.
    return ce_bind_emit(builder, merged, mapper, ordinary, collect_mode, owned || borrow_bind, ce_stage_at(expr))
}
// ---- Loops -------------------------------------------------------------------
// A loop is lowered once its sources and the builder's optional hook are typed.
// The hook is probed with a body that only produces Zero: it has the type of a
// real iteration, so the lowered body is emitted once, into the chosen variant.
def private ce_loop_zero_body(builder : string; collect_mode : bool) : ExpressionPtr {
    if (collect_mode) { return qmacro_block() { return <- ce_zero($i(builder)) } }
    return qmacro_block() { return ce_zero($i(builder)) }
}
def private ce_loop_callback(builder : string; source : ExpressionPtr; item : string; body : ExpressionPtr;
                             mutable_source, collect_mode : bool) : ExpressionPtr {
    if (mutable_source) {
        if (collect_mode) {
            return qmacro($(var $i(item):typedecl(ce_for_element($e(source)))&) {
                return <- ce_delay($i(builder), $ { $e(body); })
            })
        }
        return qmacro($(var $i(item):typedecl(ce_for_element($e(source)))&) {
            return ce_delay($i(builder), $ { $e(body); })
        })
    }
    if (collect_mode) {
        return qmacro($($i(item):typedecl(ce_for_element($e(source)))) {
            return <- ce_delay($i(builder), $ { $e(body); })
        })
    }
    return qmacro($($i(item):typedecl(ce_for_element($e(source)))) {
        return ce_delay($i(builder), $ { $e(body); })
    })
}
def private ce_loop_iteration(builder : string; body : ExpressionPtr; collect_mode : bool) : ExpressionPtr {
    if (collect_mode) { return qmacro($ { return <- ce_delay($i(builder), $ { $e(body); }) }) }
    return qmacro($ { return ce_delay($i(builder), $ { $e(body); }) })
}
def private ce_loop_hook(probe : ExpressionPtr; var error : string&) : bool {
    if (probe._type.baseType == Type.tVoid) {
        error = "computation: loop hook must return a builder outcome"
        return false
    }
    return !ce_is_protocol(probe._type, "CeLoopFallback")
}
// One iteration of the hook-free loop. `breaking` leaves a zip traversal so its
// cursors are closed; a native while returns the accumulated failure directly.
def private ce_loop_step(builder, step, accumulated : string; body : ExpressionPtr;
                         collect_mode, owned, breaking : bool) : ExpressionPtr {
    if (owned) {
        if (breaking) {
            return qmacro_block() {
                var inscope $i(step) <- ce_delay($i(builder), $ {$e(body);})
                ce_collect_append($i(builder),$i(accumulated),$i(step))
                if (ce_loop_failed($i(builder),$i(accumulated))) {break}
            }
        }
        return qmacro_block() {
            var inscope $i(step) <- ce_delay($i(builder), $ {$e(body);})
            ce_collect_append($i(builder),$i(accumulated),$i(step))
            if (ce_loop_failed($i(builder),$i(accumulated))) {return <- $i(accumulated)}
        }
    }
    if (collect_mode) {
        return qmacro_block() {
            var inscope $i(step) <- ce_delay($i(builder), $ { $e(body); })
            ce_collect_append($i(builder), $i(accumulated), $i(step))
        }
    }
    if (breaking) {
        return qmacro_block() {
            let $i(step)=ce_delay($i(builder), $ {$e(body);})
            $i(accumulated)=ce_loop_append($i(builder),$i(accumulated),$i(step))
            if (ce_loop_failed($i(builder),$i(accumulated))) {break}
        }
    }
    return qmacro_block() {
        let $i(step) = ce_delay($i(builder), $ { $e(body); })
        $i(accumulated) = ce_loop_append($i(builder), $i(accumulated), $i(step))
        if (ce_loop_failed($i(builder), $i(accumulated))) { return $i(accumulated) }
    }
}
def private ce_loop_fallback(builder, accumulated : string; loop : ExpressionPtr; collect_mode : bool) : ExpressionPtr {
    if (collect_mode) {
        return qmacro(ce_delay($i(builder), $ {
            var inscope $i(accumulated) <- ce_zero($i(builder))
            try { $e(loop); } recover {
                ce_collect_rethrow($i(builder), $i(accumulated))
            }
            return <- $i(accumulated)
        }))
    }
    return qmacro(ce_delay($i(builder), $ {
        var $i(accumulated) = ce_zero($i(builder))
        $e(loop)
        return $i(accumulated)
    }))
}
// Evaluate sources left-to-right in nested scopes. Borrowed sources keep their
// references; temporary collections stay alive until all zip iterators close.
def private ce_loop_source_scopes(sources : array<ExpressionPtr>; body : ExpressionPtr;
                                  names : array<string>; at : LineInfo) : ExpressionPtr {
    var result = clone_expression(body)
    let count = length(sources)
    for (offset in range(count)) {
        let index = count - 1 - offset
        var next : ExpressionPtr
        if (sources[index]._type.isConst) {
            next = qmacro($($i(names[index]):typedecl($e(sources[index]))) { return $e(result) })
        } else {
            next = qmacro($(var $i(names[index]):typedecl($e(sources[index]))) { return $e(result) })
        }
        ce_stage_retype_argument(next, sources[index]._type)
        result = ce_stage_apply_emit(sources[index], next, false, at)
    }
    return result
}
def private ce_loop_for_fallback(original : ExprFor?; sources : array<ExpressionPtr>; body : ExpressionPtr;
                                 builder : string; collect_mode, owned : bool; at : LineInfo) : ExpressionPtr {
    let step = ce_unique_name("__ce_iteration", at)
    let accumulated = ce_unique_name("__ce_accumulated", at)
    var names : array<string>
    for (index in range(length(sources))) {
        names |> push(ce_unique_name("__ce_fallback_source_{index}", at))
    }
    var consume = ce_loop_step(builder, step, accumulated, body, collect_mode, owned, true)
    var loop = ce_zip_traversal(original, names, null, "", consume)
    loop = ce_loop_source_scopes(sources, loop, names, at)
    return ce_loop_fallback(builder, accumulated, loop, collect_mode)
}
def ce_loop_stage(stmt, body : ExpressionPtr; builder : string; collect_mode, owned : bool) : ExpressionPtr {
    var skeleton = clone_expression(stmt)
    if (skeleton is ExprFor) { (skeleton as ExprFor).body = qmacro_block() {} }
    else { (skeleton as ExprWhile).body = qmacro_block() {} }
    var payload : array<ExpressionPtr>
    payload |> push <| qmacro($ { $e(skeleton); })
    payload |> push <| qmacro($ { $e(body); })
    payload |> push <| new ExprConstString(at=stmt.at, value:=builder)
    payload |> push <| new ExprConstBool(at=stmt.at, value=collect_mode)
    payload |> push <| new ExprConstBool(at=stmt.at, value=owned)
    var probes : array<ExpressionPtr>
    if (stmt is ExprWhile) {
        let iteration = ce_loop_iteration(builder, ce_loop_zero_body(builder, collect_mode), collect_mode)
        probes |> push <| qmacro(ce_while($i(builder), $ { return true }, $e(iteration)))
        return ce_stage("while", stmt.at, probes, payload)
    }
    let original = stmt as ExprFor
    let arity = length(original.sources)
    for (source in original.sources) { probes |> push <| clone_expression(source) }
    if (arity > 1) {
        let visitor = ce_unique_name("__ce_zip_probe", stmt.at)
        probes |> push <| qmacro(ce_for_zip($i(builder), $v(arity),
            $($i(visitor):block<(body:block<():typedecl(ce_zero($i(builder)))>):bool>) { return; }))
    }
    return ce_stage("for", stmt.at, probes, payload)
}
def private ce_stage_statement(var expr : ExprCallMacro?; index : int) : ExpressionPtr {
    return clone_expression(((ce_stage_payload(expr, index) as ExprMakeBlock)._block as ExprBlock).list[0])
}
def private ce_stage_while(var expr : ExprCallMacro?; var error : string&) : ExpressionPtr {
    let hook = ce_loop_hook(ce_stage_probe(expr, 0, error), error)
    if (!empty(error)) { return null }
    var skeleton = ce_stage_statement(expr, 0)
    var body = ce_stage_statement(expr, 1)
    let builder = ce_stage_text(expr, 2)
    let collect_mode = ce_stage_flag(expr, 3)
    if (hook) {
        let iteration = ce_loop_iteration(builder, body, collect_mode)
        return qmacro(ce_while($i(builder), $ { return $e((skeleton as ExprWhile).cond) }, $e(iteration)))
    }
    let step = ce_unique_name("__ce_iteration", ce_stage_at(expr))
    let accumulated = ce_unique_name("__ce_accumulated", ce_stage_at(expr))
    (skeleton as ExprWhile).body = ce_loop_step(builder, step, accumulated, body, collect_mode, ce_stage_flag(expr, 4), false)
    return ce_loop_fallback(builder, accumulated, skeleton, collect_mode)
}
def private ce_stage_for(var expr : ExprCallMacro?; var error : string&) : ExpressionPtr {
    var skeleton = ce_stage_statement(expr, 0)
    var original = skeleton as ExprFor
    let arity = length(original.sources)
    var sources : array<ExpressionPtr>
    for (index in range(arity)) {
        var source = ce_stage_probe(expr, index, error)
        if (source == null) { return null }
        sources |> push <| source
    }
    let builder = ce_stage_text(expr, 2)
    let collect_mode = ce_stage_flag(expr, 3)
    if (arity == 1) {
        // The hook is probed with the callback shape this source selects, so a
        // second stage follows; it carries the same payload.
        let t = sources[0]._type
        let mutable_source = (((t.isGoodArrayType || t.baseType==Type.tFixedArray) && !t.isConst)
            || (t.baseType==Type.tIterator && t.firstType.flags.ref && !t.firstType.flags.constant))
        let callback = ce_loop_callback(builder, sources[0], string(original.iterators[0]),
            ce_loop_zero_body(builder, collect_mode), mutable_source, collect_mode)
        var probes : array<ExpressionPtr>
        probes |> push <| clone_expression(sources[0])
        probes |> push <| qmacro(ce_for($i(builder), $e(sources[0]), $e(callback)))
        var payload : array<ExpressionPtr>
        for (index in range(5)) { payload |> push <| clone_expression(ce_stage_payload(expr, index)) }
        payload |> push <| new ExprConstBool(at=ce_stage_at(expr), value=mutable_source)
        return ce_stage("for1", ce_stage_at(expr), probes, payload)
    }
    let hook = ce_loop_hook(ce_stage_probe(expr, arity, error), error)
    if (!empty(error)) { return null }
    var body = ce_stage_statement(expr, 1)
    if (!hook) {
        return ce_loop_for_fallback(original, sources, body, builder, collect_mode, ce_stage_flag(expr, 4), ce_stage_at(expr))
    }
    // Preserve native zip ordering with explicitly owned cursors so
    // producer and consumer panics cannot strand hidden iterators.
    let visitor = ce_unique_name("__ce_zip_visit", ce_stage_at(expr))
    var sourceNames : array<string>
    for (index in range(arity)) {
        sourceNames |> push(ce_unique_name("__ce_zip_source_{index}", ce_stage_at(expr)))
    }
    var traversal = ce_zip_traversal(original, sourceNames, ce_loop_iteration(builder, body, collect_mode), visitor, null)
    traversal = ce_loop_source_scopes(sources, traversal, sourceNames, ce_stage_at(expr))
    var driver = qmacro($($i(visitor):block<(body:block<():typedecl(ce_zero($i(builder)))>):bool>) {
        $e(traversal)
    })
    return qmacro(ce_for_zip($i(builder), $v(arity), $e(driver)))
}
def private ce_stage_for1(var expr : ExprCallMacro?; var error : string&) : ExpressionPtr {
    var source = ce_stage_probe(expr, 0, error)
    let hook = ce_loop_hook(ce_stage_probe(expr, 1, error), error)
    if (!empty(error)) { return null }
    var skeleton = ce_stage_statement(expr, 0)
    var original = skeleton as ExprFor
    var body = ce_stage_statement(expr, 1)
    let builder = ce_stage_text(expr, 2)
    let collect_mode = ce_stage_flag(expr, 3)
    if (!hook) {
        var sources : array<ExpressionPtr>
        sources |> push <| source
        return ce_loop_for_fallback(original, sources, body, builder, collect_mode, ce_stage_flag(expr, 4), ce_stage_at(expr))
    }
    let mutable_source = ce_stage_flag(expr, 5)
    var callback = ce_loop_callback(builder, source, string(original.iterators[0]), body, mutable_source, collect_mode)
    // Iterators are consumed by the hook; ordinary source temporaries
    // are scoped here, while source variables stay borrowed.
    if (source._type.isGoodIteratorType) {
        return qmacro(ce_for($i(builder), $e(source), $e(callback)))
    }
    let sourceName = ce_unique_name("__ce_for_source", ce_stage_at(expr))
    var apply : ExpressionPtr
    if (mutable_source) {
        if (collect_mode) {
            apply = qmacro($(var $i(sourceName):typedecl($e(source))) {
                return <- ce_for($i(builder),$i(sourceName),$e(callback))
            })
        } else {
            apply = qmacro($(var $i(sourceName):typedecl($e(source))) {
                return ce_for($i(builder),$i(sourceName),$e(callback))
            })
        }
    } elif (collect_mode) {
        apply = qmacro($($i(sourceName):typedecl($e(source))) {
            return <- ce_for($i(builder),$i(sourceName),$e(callback))
        })
    } else {
        apply = qmacro($($i(sourceName):typedecl($e(source))) {
            return ce_for($i(builder),$i(sourceName),$e(callback))
        })
    }
    ce_stage_retype_argument(apply, source._type)
    return ce_stage_apply_emit(source, apply, collect_mode, ce_stage_at(expr))
}
def private ce_stage_visit(var expr : ExprCallMacro?; var error : string&) : ExpressionPtr {
    let op = string((expr.arguments[0] as ExprConstString).value)
    if (op == "apply") { return ce_stage_apply(expr, error) }
    if (op == "bind") { return ce_stage_bind(expr, error) }
    if (op == "bind2") { return ce_stage_bind2(expr, error) }
    if (op == "apply2") { return ce_stage_apply2(expr, error) }
    if (op == "while") { return ce_stage_while(expr, error) }
    if (op == "for") { return ce_stage_for(expr, error) }
    if (op == "for1") { return ce_stage_for1(expr, error) }
    error = "computation: unknown lowering stage '{op}'"
    return null
}

def private ce_is_group(node : ExpressionPtr) : bool {
    return node is ExprCall && (node as ExprCall).name == "and_bind"
}
// The two sources of a group, left first; each is scoped like a single source.
def private ce_stage_apply2(var expr : ExprCallMacro?; var error : string&) : ExpressionPtr {
    let left = ce_stage_probe(expr, 0, error)
    if (left == null) { return null }
    let right = ce_stage_probe(expr, 1, error)
    if (right == null) { return null }
    let mergeBody = ce_stage_payload(expr, 0)
    let leftName = ce_stage_text(expr, 1)
    let rightName = ce_stage_text(expr, 2)
    let collect = ce_stage_flag(expr, 3)
    let owned = ce_stage_flag(expr, 4)
    let at = ce_stage_at(expr)
    var rightNext = qmacro($($i(rightName):typedecl($e(right))) { return $e(mergeBody) })
    if (collect) { rightNext = qmacro($($i(rightName):typedecl($e(right))) { return <- $e(mergeBody) }) }
    if (owned) {((rightNext as ExprMakeBlock)._block as ExprBlock).arguments[0]._type.flags.constant=false}
    ce_stage_retype_argument(rightNext, right._type)
    let rightBody = ce_stage_apply_emit(right, rightNext, collect, at)
    var leftNext = qmacro($($i(leftName):typedecl($e(left))) { return $e(rightBody) })
    if (collect) { leftNext = qmacro($($i(leftName):typedecl($e(left))) { return <- $e(rightBody) }) }
    if (owned) {((leftNext as ExprMakeBlock)._block as ExprBlock).arguments[0]._type.flags.constant=false}
    ce_stage_retype_argument(leftNext, left._type)
    return ce_stage_apply_emit(left, leftNext, collect, at)
}
// Evaluate a group left to right, each source once. `pieces` is the payload of
// the bind that consumes the outermost group; inner groups only merge.
def ce_merge_apply(node : ExpressionPtr; builder : string; next : ExpressionPtr;
                   collect : bool; var error : string&; pieces : array<ExpressionPtr>; owned:bool=false) : ExpressionPtr {
    if (node is ExprCall && (node as ExprCall).name == "and_bind") {
        let call = node as ExprCall
        if (length(call.arguments)!=2) {
            error = "computation: expected 'left |> and_bind(right) |> bind'"
            return null
        }
        var leftType = ce_merge_source(call.arguments[0], builder, error)
        var rightType = ce_merge_source(call.arguments[1], builder, error)
        if (!empty(error)) { return null }
        let leftName = ce_unique_name("__ce_merge_left", node.at)
        let rightName = ce_unique_name("__ce_merge_right", node.at)
        var mergeBody : ExpressionPtr
        if (empty(pieces)) {
            let location="{node.at.fileInfo.name}:{int(node.at.line)}:{int(node.at.column)}"
            ce_merge_locations |> insert(location,new ExprConstBool(at=node.at,value=true))
            var merged = qmacro(typeinfo ce_checked_merge(ce_merge_origin(ce_merge_sources($i(builder), $i(leftName), $i(rightName)), $i(builder), $v(location))))
            merged.at = node.at
            // `next` is typed from the group expression, not from this named merge.
            mergeBody = ce_source_apply(merged, next, true, collect, false)
        } else {
            mergeBody = ce_bind2_stage(builder, leftName, rightName, pieces, node.at)
        }
        if (!ce_is_group(call.arguments[0]) && !ce_is_group(call.arguments[1])) {
            // Neither source depends on the other's name, so one stage types both.
            var probes : array<ExpressionPtr>
            probes |> push <| leftType
            probes |> push <| rightType
            var payload : array<ExpressionPtr>
            payload |> push <| mergeBody
            payload |> push <| new ExprConstString(at=node.at, value:=leftName)
            payload |> push <| new ExprConstString(at=node.at, value:=rightName)
            payload |> push <| new ExprConstBool(at=node.at, value=collect)
            payload |> push <| new ExprConstBool(at=node.at, value=owned)
            return ce_stage("apply2", node.at, probes, payload)
        }
        var inner : array<ExpressionPtr>
        var rightNext = qmacro($($i(rightName):typedecl($e(rightType))) { return $e(mergeBody) })
        if (collect) { rightNext = qmacro($($i(rightName):typedecl($e(rightType))) { return <- $e(mergeBody) }) }
        if (owned) {((rightNext as ExprMakeBlock)._block as ExprBlock).arguments[0]._type.flags.constant=false}
        var rightBody = ce_merge_apply(call.arguments[1], builder, rightNext, collect, error, inner, owned)
        var leftNext = qmacro($($i(leftName):typedecl($e(leftType))) { return $e(rightBody) })
        if (collect) { leftNext = qmacro($($i(leftName):typedecl($e(leftType))) { return <- $e(rightBody) }) }
        if (owned) {((leftNext as ExprMakeBlock)._block as ExprBlock).arguments[0]._type.flags.constant=false}
        return ce_merge_apply(call.arguments[0], builder, leftNext, collect, error, inner, owned)
    }
    return ce_source_apply(ce_normalize_source(builder,node), next, true, collect)
}

[typeinfo_macro(name="ce_has_bind_return")]
class CeHasBindReturn : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?; var errors:das_string) : ExpressionPtr {
        if (expr.subexpr==null || expr.subexpr._type==null) { errors := "computation: BindReturn type must be inferred"; return null }
        let t=expr.subexpr._type
        let fallback=(t.baseType==Type.tStructure && t.structType.name=="CeBindReturnFallback"
                      && t.structType._module.name=="builder_protocol")
        return <- new ExprConstBool(at=expr.at,value=!fallback)
    }
}

def ce_bind_application(builder:string; source, mapper, ordinary:ExpressionPtr; fused, collect:bool) : ExpressionPtr {
    if (!fused) { return qmacro(ce_bind($i(builder), $e(source), $e(ordinary))) }
    if (collect) {
        return qmacro(invoke($ {
            static_if (typeinfo ce_has_bind_return(ce_bind_return($i(builder), $e(source), $e(mapper)))) {
                return <- ce_bind_return($i(builder), $e(source), $e(mapper))
            } else {
                return <- ce_bind($i(builder), $e(source), $e(ordinary))
            }
        }))
    }
    return qmacro(invoke($ {
        static_if (typeinfo ce_has_bind_return(ce_bind_return($i(builder), $e(source), $e(mapper)))) {
            return ce_bind_return($i(builder), $e(source), $e(mapper))
        } else {
            return ce_bind($i(builder), $e(source), $e(ordinary))
        }
    }))
}

[typeinfo_macro(name="ce_zip_value")]
class CeZipValue : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?; var errors:das_string) : ExpressionPtr {
        if (expr.subexpr==null || expr.subexpr._type==null) { errors := "zip: cursor type must be inferred"; return null }
        let cursor=expr.subexpr
        let element=cursor._type.argTypes[0].firstType
        var access=qmacro($e(cursor).slot)
        if (element.flags.ref) {access=qmacro(*$e(cursor).slot); access.genFlags.alwaysSafe=true}
        let mode=cursor._type.argTypes[2]
        if (mode.structType.name=="CeZipReadOnly" && mode.structType._module.name=="zip_runtime") {
            var constantAccess=qmacro(reinterpret<typedecl($e(access)) const&>($e(access)))
            constantAccess.genFlags.alwaysSafe=true
            return constantAccess
        }
        return access
    }
}

// Explicit cursor storage remains accessible when next() or the consumer panics.
def ce_zip_traversal(original:ExprFor?; names:array<string>; iteration:ExpressionPtr; visitor:string; directBody:ExpressionPtr) : ExpressionPtr {
    var declarations:array<ExpressionPtr>
    var initialize:array<ExpressionPtr>
    var advance:array<ExpressionPtr>
    var aliases:array<ExpressionPtr>
    var cleanup:array<ExpressionPtr>
    let first=ce_unique_name("__ce_zip_first",original.at)
    let more=ce_unique_name("__ce_zip_more",original.at)
    let message=ce_unique_name("__ce_zip_error",original.at)
    for (index in range(length(names))) {
        let source=names[index]
        let cursor=ce_unique_name("__ce_zip_cursor_{index}",original.at)
        let item=string(original.iterators[index])
        declarations |> push <| qmacro_expr() {var $i(cursor):typedecl(ce_zip_cursor($i(source)))}
        initialize |> push <| qmacro_expr() {$i(cursor) <- ce_zip_cursor($i(source))}
        advance |> push <| qmacro_expr() {
            if (!ce_zip_next($i(cursor))) {
                $i(more)=false
                if (!$i(first)) {break}
            }
        }
        var binding=qmacro_expr() {var $i(item) & = typeinfo ce_zip_value($i(cursor))} as ExprLet
        binding.variables[0]._type.flags.removeConstant=false
        binding.variables[0]._type.flags.constant=false
        aliases |> push <| binding
        cleanup |> push <| qmacro_expr() {ce_zip_close($i(cursor),$i(message))}
    }
    var consume:ExprBlock?
    if (directBody!=null) {consume=clone_expression(directBody) as ExprBlock}
    else {consume=qmacro_block() {if (!invoke($i(visitor),$e(iteration))) {break}} as ExprBlock}
    for (statement in consume.list) {aliases |> push <| clone_expression(statement)}
    consume.list |> clear()
    for (statement in aliases) {consume.list |> push <| clone_expression(statement)}
    var execute=qmacro($ {
        var $i(message)=""
        try {
            $b(initialize)
            var $i(first)=true
            while (true) {
                var $i(more)=true
                $b(advance)
                $i(first)=false
                if (!$i(more)) {break}
                $e(consume)
            }
        } recover { $i(message)=ce_zip_exception() }
        $b(cleanup)
        if (!empty($i(message))) {panic($i(message))}
        return true
    })
    var executeBlock=(execute as ExprMakeBlock)._block as ExprBlock
    for (statement in executeBlock.list) {declarations |> push <| clone_expression(statement)}
    executeBlock.list |> clear()
    for (statement in declarations) {executeBlock.list |> push <| clone_expression(statement)}
    return qmacro(invoke($e(execute)))
}



// Removing moved-from temporary slots is observable for user finalizers.
// Keep the old path for such element types, including nested fields/containers.
def ce_sink_safe_element(t:TypeDeclPtr; depth:int=0) : bool {
    if(t==null || depth>32) {return false}
    if(t.baseType==Type.tHandle || t.baseType==Type.tPointer || t.baseType==Type.tIterator || t.baseType==Type.tLambda) {return false}
    if(t.baseType==Type.tStructure) {
        if(t.structType.flags.isClass) {return false}
        var userFinalizer=false
        for_each_module_no_order(compiling_program().get_ptr(),$(mod) {
            for_each_function(mod,"finalize") $(fn) {
                if(!fn.flags.generated && length(fn.arguments)==1 && fn.arguments[0]._type.baseType==Type.tStructure && fn.arguments[0]._type.structType==t.structType) {userFinalizer=true}
            }
            if(mod.name!="builtin") {
                for_each_generic(mod,"finalize") $(fn) {if(!fn.flags.generated) {userFinalizer=true}}
            }
        })
        if(userFinalizer) {return false}
        for(field in t.structType.fields) {if(!ce_sink_safe_element(field._type,depth+1)) {return false}}
    }
    if(t.firstType!=null && !ce_sink_safe_element(t.firstType,depth+1)) {return false}
    if(t.secondType!=null && !ce_sink_safe_element(t.secondType,depth+1)) {return false}
    for(arg in t.argTypes) {if(!ce_sink_safe_element(arg,depth+1)) {return false}}
    return true
}

[typeinfo_macro(name="ce_has_collect_sink")]
class CeHasCollectSink : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?; var errors:das_string) : ExpressionPtr {
        if (expr.subexpr==null || expr.subexpr._type==null) {errors := "computation: collect sink descriptor must be inferred";return null}
        let t=expr.subexpr._type
        let enabled=t.baseType==Type.tTuple && length(t.argTypes)==2 && ce_is_protocol(t.argTypes[0],"CeCollectSink")
        var arrayFinalizer=false
        if(enabled) {
            for_each_module_no_order(compiling_program().get_ptr(),$(mod) {
                if(mod.name!="builtin") {
                    for_each_function(mod,"finalize") $(fn) {
                        if(!fn.flags.generated && length(fn.arguments)==1 && fn.arguments[0]._type.baseType==Type.tArray) {arrayFinalizer=true}
                    }
                    for_each_generic(mod,"finalize") $(fn) {if(!fn.flags.generated) {arrayFinalizer=true}}
                }
            })
        }
        return <- new ExprConstBool(at=expr.at,value=enabled && !arrayFinalizer && ce_sink_safe_element(t.argTypes[1].firstType))
    }
}
// Only adjacent binds followed by return: no resource/exception scopes are
// merged, and grouped sources keep their existing snapshot semantics.
def ce_can_collect_fuse(blk:ExprBlock?; start:int; owned:bool) : bool {
    let count=length(blk.list)-start-1
    if(count<1 || !(blk.list[length(blk.list)-1] is ExprReturn)) {return false}
    let ret=blk.list[length(blk.list)-1] as ExprReturn
    if(ret.subexpr==null || ret.returnFlags.returnReference || (owned && !ret.returnFlags.moveSemantics)) {return false}
    if(ret.subexpr is ExprCall && (ret.subexpr as ExprCall).name=="return_from") {return false}
    var consuming=owned
    for(i in range(start,length(blk.list)-1)) {
        let stmt=blk.list[i]
        var binding:ExpressionPtr
        if(stmt is ExprLet) {
            let decl=stmt as ExprLet
            if(length(decl.variables)!=1) {return false}
            binding=clone_expression(decl.variables[0].init)
            consuming=consuming || (decl.variables[0]._type.flags.ref && !decl.variables[0]._type.flags.constant)
        } elif(stmt is ExprCall) {binding=clone_expression(stmt)}
        if(binding==null || !(binding is ExprCall)) {return false}
        let call=binding as ExprCall
        if(call.name!="bind" || length(call.arguments)!=1) {return false}
        if(call.arguments[0] is ExprCall && (call.arguments[0] as ExprCall).name=="and_bind") {return false}
    }
    // Keep consuming scope boundaries (including destruction order). A single
    // consuming map still eliminates every singleton result allocation.
    return consuming ? count==1 : count>=2
}
def ce_collect_emit_scope(blk:ExprBlock?; start:int; builder,sink:string; owned:bool) : ExpressionPtr {
    let stmt=blk.list[start]
    if(stmt is ExprReturn) {
        let ret=stmt as ExprReturn
        if(owned) {return qmacro_block(){ce_collect_emit_move($i(builder),$i(sink),$e(ret.subexpr));return CeUnit()}}
        return qmacro_block(){ce_collect_emit($i(builder),$i(sink),$e(ret.subexpr));return CeUnit()}
    }
    var binding:ExpressionPtr
    if(stmt is ExprLet) {binding=clone_expression((stmt as ExprLet).variables[0].init)} else {binding=clone_expression(stmt)}
    let source=ce_normalize_source(builder,(binding as ExprCall).arguments[0])
    let argument=ce_unique_name("__ce_sink_item",stmt.at)
    let sourceName=ce_unique_name("__ce_sink_source",stmt.at)
    let borrow=stmt is ExprLet && (stmt as ExprLet).variables[0]._type.flags.ref && !(stmt as ExprLet).variables[0]._type.flags.constant
    var rest=(ce_collect_emit_scope(blk,start+1,builder,sink,owned) as ExprBlock)
    if(stmt is ExprLet) {
        var declaration=clone_expression(stmt)
        (declaration as ExprLet).variables[0].init=qmacro($i(argument))
        if(owned || borrow) {(declaration as ExprLet).variables[0].init.genFlags.alwaysSafe=true}
        rest.list |> emplace(declaration,0)
    }
    var next=qmacro($($i(argument):typedecl(ce_unwrap($i(builder),$e(source)))) {$e(rest);})
    if(owned) {next=qmacro($(var $i(argument):typedecl(ce_unwrap($i(builder),$e(source)))&) {$e(rest);})}
    elif(borrow) {next=qmacro($(var $i(argument):typedecl(ce_unwrap_borrow($i(builder),$e(source)))&) {$e(rest);})}
    var apply=qmacro($($i(sourceName):typedecl($e(source))) {
        return ce_collect_each($i(builder),$i(sink),$i(sourceName),$e(next))
    })
    if(owned || borrow) {
        apply=qmacro($(var $i(sourceName):typedecl($e(source))) {
            return ce_collect_each_move($i(builder),$i(sink),$i(sourceName),$e(next))
        })
    }
    let execution=ce_source_apply(source,apply,true,false)
    return qmacro_block(){return $e(execution)}
}

// Lower every CE scope independently. Empty scopes end in Zero; only Bind and
// Combine decide whether to enter their continuation. For fallback owns its cursors.
def ce_scope(node : ExpressionPtr; builder : string; collect_mode : bool; var error : string&; owned:bool=false) : ExpressionPtr {
    var source = (qmacro_block() {}) as ExprBlock
    if (node != null) {
        if (node is ExprBlock) {
            source = clone_expression(node) as ExprBlock
        } else {
            source.list |> push <| clone_expression(node)
        }
    }
    if (!empty(source.finalList)) {
        error = "computation: use try_finally(body, cleanup) instead of a native finally on a CE scope"
    }
    var body <- ce_lower(source, 0, builder, collect_mode, error, owned)
    return qmacro_block() { $b(body); }
}

def ce_lower(blk : ExprBlock?; start : int; builder : string; collect_mode : bool;
             var error : string&; owned:bool=false) : array<ExpressionPtr> {
    var output <- ce_lower_impl(blk, start, builder, collect_mode, error, owned)
    if(collect_mode && empty(error) && ce_can_collect_fuse(blk,start,owned)) {
        let sink=ce_unique_name("__ce_sink",blk.at)
        let emitted=ce_collect_emit_scope(blk,start,builder,sink,owned)
        let fused=qmacro(ce_collect_into($i(builder),$(var $i(sink):typedecl(ce_zero($i(builder)))) {$e(emitted);}))
        let fallback=qmacro(invoke($ {$b(output);}))
        output |> clear()
        output |> push <| qmacro_expr() {
            return <- invoke($ {
                static_if(typeinfo ce_has_collect_sink(ce_collect_sink($i(builder)))) {return <- $e(fused)}
                else {return <- $e(fallback)}
            })
        }
    }

    if (collect_mode) {
        for (stmt in output) {
            if (stmt is ExprReturn) { (stmt as ExprReturn).returnFlags.moveSemantics = true }
        }
    }
    return <- output
}
def ce_lower_impl(blk : ExprBlock?; start : int; builder : string; collect_mode : bool;
             var error : string&; owned:bool=false) : array<ExpressionPtr> {
    var output : array<ExpressionPtr>
    for (index in range(start, length(blk.list))) {
        var stmt = clone_expression(blk.list[index])
        if (stmt is ExprFor) {stmt=ce_normalize_for(builder,stmt)}
        if (collect_mode && (stmt is ExprYield || (stmt is ExprCall && (stmt as ExprCall).name == "yield_from"))) {
            var value : ExpressionPtr
            if (stmt is ExprYield) {
                if ((stmt as ExprYield).returnFlags.moveSemantics) {
                    value=qmacro(ce_return_move($i(builder),$e((stmt as ExprYield).subexpr)))
                } else {value = qmacro(ce_return($i(builder), $e((stmt as ExprYield).subexpr)))}
            } else {
                let call = stmt as ExprCall
                if (length(call.arguments)!=1) {
                    error = "computation: expected expression |> yield_from"
                    return <- output
                }
                value = ce_return_from_source(builder,call.arguments[0],true,owned)
            }
            var rest <- ce_lower(blk, index+1, builder, collect_mode, error, owned)
            let first=ce_unique_name("__ce_yield_result",stmt.at)
            var append=qmacro($(var $i(first):typedecl($e(value))) {
                return <- ce_combine($i(builder),$i(first),$ { $b(rest); })
            })
            value.at=stmt.at
            var combined=ce_source_apply(value,append,true)
            output |> push <| qmacro_expr() { return $e(combined) }
            return <- output
        }
        if (stmt is ExprReturn) {
            let ret = stmt as ExprReturn
            if (index != length(blk.list)-1 || ret.subexpr == null) {
                error = "computation: return must be the final statement of its scope and have a value"
                return <- output
            }
            if (ret.subexpr is ExprCall && (ret.subexpr as ExprCall).name == "return_from") {
                let call = ret.subexpr as ExprCall
                if (length(call.arguments) != 1) {
                    error = "computation: expected 'return expression |> return_from'"
                    return <- output
                }
                let forwarded=ce_return_from_source(builder,call.arguments[0],collect_mode,owned)
                output |> push <| qmacro_expr() {return $e(forwarded)}
            } elif (owned && ret.returnFlags.moveSemantics) {
                output |> push <| qmacro_expr() {return ce_return_move($i(builder),$e(ret.subexpr))}
            } else {
                if(owned) {
                    var check=qmacro(static_assert(typeinfo can_copy($e(ret.subexpr)),"owned CE: value must be moved; use 'return <- value'"))
                    check.at=stmt.at
                    output |> push <| check
                }
                output |> push <| qmacro_expr() {
                    return ce_return($i(builder), $e(ret.subexpr))
                }
            }
            return <- output
        }
        var binding : ExpressionPtr
        if (stmt is ExprLet) {
            let decl = stmt as ExprLet
            if (length(decl.variables) != 1) {
                error = "computation: declare one variable per statement"
                return <- output
            }
            binding = clone_expression(decl.variables[0].init)
        } elif (stmt is ExprCall) {
            binding = clone_expression(stmt)
        }
        if (binding != null && binding is ExprCall && (binding as ExprCall).name == "bind") {
            let call = binding as ExprCall
            if (length(call.arguments) != 1) {
                error = "computation: expected 'expression |> bind'"
                return <- output
            }
            // Explicit mutable-reference bind can consume move-only inputs even
            // when the collection's output element is copyable.
            let borrow_bind=collect_mode && stmt is ExprLet && (stmt as ExprLet).variables[0]._type.flags.ref && !(stmt as ExprLet).variables[0]._type.flags.constant
            let mutable_bind=owned || borrow_bind
            if (owned && stmt is ExprLet) {
                let variable=(stmt as ExprLet).variables[0]
                if (variable.flags.init_via_move || variable.flags.init_via_clone || variable.flags.inScope) {
                    error="owned CE: bind borrows its payload; use 'var value & = source |> bind'"
                    return <- output
                }
            }
            var rest <- ce_lower(blk, index+1, builder, collect_mode, error, owned)
            if (!empty(error)) { return <- output }
            var source = ce_merge_source(call.arguments[0], builder, error)
            if (!empty(error)) { return <- output }
            let argument = ce_unique_name("__ce_value", stmt.at)
            if (stmt is ExprLet) {
                var declaration = clone_expression(stmt)
                (declaration as ExprLet).variables[0].init = qmacro($i(argument))
                if (mutable_bind) {(declaration as ExprLet).variables[0].init.genFlags.alwaysSafe=true}
                rest |> emplace(declaration, 0)
            }
            // Only adjacent bind + final ordinary return. Preserve the original
            // declaration (including its annotation) inside the mapping block.
            var fused = false
            if (!mutable_bind && index+2 == length(blk.list) && blk.list[index+1] is ExprReturn) {
                let ret = blk.list[index+1] as ExprReturn
                if (ret.subexpr != null && !ret.returnFlags.moveSemantics && !ret.returnFlags.returnReference) {
                    fused = !(ret.subexpr is ExprCall && (ret.subexpr as ExprCall).name == "return_from")
                }
            }
            // The source is lowered once its type is known: the rest of the scope
            // travels as payload and is emitted exactly once.
            var payload : array<ExpressionPtr>
            payload |> push <| qmacro($ { $b(rest); })
            if (fused) {
                var mapped : array<ExpressionPtr>
                if (stmt is ExprLet) {
                    var declaration = clone_expression(stmt)
                    (declaration as ExprLet).variables[0].init = qmacro($i(argument))
                    mapped |> push <| declaration
                }
                mapped |> push <| clone_expression(blk.list[index+1])
                payload |> push <| qmacro($ { $b(mapped); })
            } else {
                payload |> push <| new ExprConstBool(at=stmt.at, value=false)
            }
            payload |> push <| new ExprConstString(at=stmt.at, value:=argument)
            payload |> push <| new ExprConstString(at=stmt.at, value:=builder)
            payload |> push <| new ExprConstBool(at=stmt.at, value=collect_mode)
            payload |> push <| new ExprConstBool(at=stmt.at, value=owned)
            payload |> push <| new ExprConstBool(at=stmt.at, value=borrow_bind)
            var staged : ExpressionPtr
            if (call.arguments[0] is ExprCall && (call.arguments[0] as ExprCall).name == "and_bind") {
                staged = ce_merge_apply(call.arguments[0], builder, null, collect_mode, error, payload, mutable_bind)
                if (!empty(error)) { return <- output }
            } else {
                var probes : array<ExpressionPtr>
                probes |> push <| source
                staged = ce_stage("bind", stmt.at, probes, payload)
            }
            output |> push <| qmacro_expr() { return $e(staged) }
            return <- output
        }
        // A scoped resource is acquired only when this declaration is reached.
        if (binding != null && binding is ExprCall && (binding as ExprCall).name == "use_resource") {
            let call = binding as ExprCall
            if (!(stmt is ExprLet) || length(call.arguments) != 1) {
                error = "computation: expected 'let resource = expression |> use_resource'"
                return <- output
            }
            let variable=(stmt as ExprLet).variables[0]
            let moveResource=variable._type.flags.ref && !variable._type.flags.constant
            if (variable.flags.init_via_move || variable.flags.init_via_clone || variable.flags.inScope) {
                error="use_resource: borrow ownership with 'var resource & = source |> use_resource'"
                return <- output
            }
            var rest <- ce_lower(blk, index+1, builder, collect_mode, error, owned)
            if (!empty(error)) { return <- output }
            let argument = ce_unique_name("__ce_resource", stmt.at)
            var declaration = clone_expression(stmt)
            (declaration as ExprLet).variables[0].init = qmacro($i(argument))
            if (moveResource) {(declaration as ExprLet).variables[0].init.genFlags.alwaysSafe=true}
            rest |> emplace(declaration, 0)
            var continuation = qmacro($($i(argument) : typedecl($e(call.arguments[0]))) { $b(rest); })
            if (moveResource) {
                continuation=qmacro($(var $i(argument):typedecl($e(call.arguments[0]))) {$b(rest);})
                output |> push <| qmacro_expr() {
                    return ce_using_move($i(builder),$e(call.arguments[0]),$e(continuation),
                        $(var $i(argument):typedecl($e(call.arguments[0]))) {ce_dispose($i(argument))})
                }
                return <- output
            }
            output |> push <| qmacro_expr() {
                return ce_using($i(builder), $e(call.arguments[0]), $e(continuation),
                    $(var $i(argument) : typedecl($e(call.arguments[0])) ) { ce_dispose($i(argument)) })
            }
            return <- output
        }
        var computation : ExpressionPtr
        if (stmt is ExprCall && (stmt as ExprCall).name == "try_with") {
            let call = stmt as ExprCall
            if (!ce_validate_try_with(call, error)) { return <- output }
            var protected_body = ce_scope((call.arguments[0] as ExprMakeBlock)._block, builder, collect_mode, error, owned)
            var handler = clone_expression(call.arguments[1]) as ExprMakeBlock
            var handler_body = handler._block as ExprBlock
            var lowered = ce_scope(handler_body, builder, collect_mode, error, owned) as ExprBlock
            handler_body.list |> clear()
            for (entry in lowered.list) { handler_body.list |> push <| clone_expression(entry) }
            computation = qmacro(ce_try_with($i(builder), $ { $e(protected_body); }, $e(handler)))
        }
        if (stmt is ExprCall && (stmt as ExprCall).name == "try_finally") {
            let call = stmt as ExprCall
            if (length(call.arguments) != 2 || !(call.arguments[0] is ExprMakeBlock)
                    || !(call.arguments[1] is ExprMakeBlock)) {
                error = "computation: try_finally expects two blocks (body, cleanup)"
                return <- output
            }
            let source = (call.arguments[0] as ExprMakeBlock)._block as ExprBlock
            let cleanup_source = (call.arguments[1] as ExprMakeBlock)._block as ExprBlock
            if (!empty(source.arguments) || !empty(cleanup_source.arguments)) {
                error = "computation: try_finally blocks must have no arguments"
                return <- output
            }
            var protected_body = ce_scope(source, builder, collect_mode, error, owned)
            var cleanup = clone_expression(call.arguments[1])
            computation = qmacro(ce_try_finally($i(builder), $ { $e(protected_body); }, $e(cleanup)))
        }
        if (stmt is ExprIfThenElse) {
            var branch = clone_expression(stmt)
            let original = stmt as ExprIfThenElse
            (branch as ExprIfThenElse).if_true = ce_scope(original.if_true, builder, collect_mode, error, owned)
            (branch as ExprIfThenElse).if_false = ce_scope(original.if_false, builder, collect_mode, error, owned)
            computation = qmacro(ce_delay($i(builder), $ { $e(branch); }))
        } elif (stmt is ExprFor || stmt is ExprWhile) {
            let original_body = stmt is ExprFor ? (stmt as ExprFor).body : (stmt as ExprWhile).body
            var body = ce_scope(original_body, builder, collect_mode, error, owned)
            computation = ce_loop_stage(stmt, body, builder, collect_mode, owned)
        } elif (stmt is ExprBlock) {
            var scope = ce_scope(stmt, builder, collect_mode, error, owned)
            computation = qmacro(ce_delay($i(builder), $ { $e(scope); }))
        }
        if (computation != null) {
            if (!empty(error)) { return <- output }
            if (index == length(blk.list)-1) {
                output |> push <| qmacro_expr() { return $e(computation) }
            } else {
                var rest <- ce_lower(blk, index+1, builder, collect_mode, error, owned)
                var combined=qmacro(ce_combine($i(builder), $e(computation), $ { $b(rest); }))
                if (collect_mode) {
                    let first=ce_unique_name("__ce_scope_result",stmt.at)
                    var append=qmacro($(var $i(first):typedecl($e(computation))) {
                        return <- ce_combine($i(builder),$i(first),$ { $b(rest); })
                    })
                    computation.at=stmt.at
                    combined=ce_source_apply(computation,append,true)
                }
                output |> push <| qmacro_expr() { return $e(combined) }
            }
            return <- output
        }
        if (!(stmt is ExprLet) && !(stmt is ExprCall) && !(stmt is ExprCallMacro)
                && !(stmt is ExprCopy) && !(stmt is ExprMove)
                && !(stmt is ExprOp1) && !(stmt is ExprOp2) && !(stmt is ExprAssert)) {
            error = "computation: unsupported statement {stmt.__rtti}"
            return <- output
        }
        output |> push <| clone_expression(stmt)
    }
    output |> push <| qmacro_expr() { return ce_zero($i(builder)) }
    return <- output
}

// Run is applied only to the outer outcome, after Delay and resource cleanup.
[typeinfo_macro(name="ce_has_run")]
class CeHasRun : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?; var errors:das_string) : ExpressionPtr {
        if (expr.subexpr==null || expr.subexpr._type==null) { errors := "computation: ce_run result type must be inferred"; return null }
        let t=expr.subexpr._type
        if (t.baseType==Type.tVoid) { errors := "computation: ce_run must return a value, not void"; return null }
        return <- new ExprConstBool(at=expr.at,value=!ce_is_protocol(t,"CeRunFallback"))
    }
}

def ce_run_scope(builder:string; outcome:ExpressionPtr; owned:bool; at:LineInfo) : ExpressionPtr {
    let input=ce_unique_name("__ce_run_outcome",at)
    var supported=qmacro(typeinfo ce_has_run(ce_run($i(builder),$i(input))))
    supported.at=at
    var finish=qmacro_block() {
        static_if ($e(supported)) {
            static_if (typeinfo can_copy(ce_run($i(builder),$i(input)))) {
                return ce_run($i(builder),$i(input))
            } else { return <- ce_run($i(builder),$i(input)) }
        } else { return $i(input) }
    }
    if (owned) {
        let result=ce_unique_name("__ce_run_result",at)
        return qmacro_block() {
            var inscope $i(input) <- $e(outcome)
            static_if ($e(supported)) {
                static_if (typeinfo can_copy(ce_run($i(builder),$i(input)))) {
                    var $i(result)=default<typedecl(ce_run($i(builder),$i(input)))>
                    try { $i(result)=ce_run($i(builder),$i(input)) } recover { ce_owned_source_rethrow($i(input)) }
                    return $i(result)
                } else {
                    var inscope $i(result):typedecl(ce_run($i(builder),$i(input)))
                    try { $i(result) <- ce_run($i(builder),$i(input)) } recover { ce_owned_source_rethrow($i(input)) }
                    return <- $i(result)
                }
            } else { return <- $i(input) }
        }
    }
    return qmacro_block() { var $i(input)=$e(outcome); $e(finish); }
}

[call_macro(name="computation")]
class ComputationMacro : AstCallMacro {
    serial : int = 0
    def override canVisitArgument(expr : ExprCallMacro?; index : int) : bool {
        if (expr.name=="__ce_stage") { return index < 2 + (expr.arguments[1] as ExprConstInt).value }
        return index == 0 || (index == 1 && expr.name=="__ce_lower_protocol")
    }
    def override canFoldReturnResult(expr : ExprCallMacro?) : bool { return false }
    def override visit(prog : ProgramPtr; mod : Module?; var expr : ExprCallMacro?) : ExpressionPtr {
        if (expr.name=="__ce_stage") {
            if (!ce_stage_ready(expr)) { return null }
            var stage_error : string
            var staged = ce_stage_visit(expr, stage_error)
            if (!empty(stage_error)) {
                macro_error(prog, expr.arguments[0].at, stage_error)
                return null
            }
            return staged
        }
        if (length(expr.arguments)==2 && expr.name=="computation" && expr.arguments[1] is ExprMakeBlock) {
            // A saved local may still be auto on the first inference pass.
            // Do not freeze default<auto> into the protocol probe.
            if (expr.arguments[0]._type==null || expr.arguments[0]._type.isAutoOrAlias) {return null}
            // Keep the same macro object for a second inference pass. The descriptor
            // call is inferred with a type-only default and removed before execution.
            // The original builder expression survives only in the final invoke.
            var builder_type=clone_type(expr.arguments[0]._type)
            builder_type.flags.ref=false
            builder_type.flags.constant=false
            var expanded=clone_expression(expr) as ExprCallMacro
            expanded.name := "__ce_lower_protocol"
            var body=clone_expression(expr.arguments[1])
            expanded.arguments[1]=qmacro(ce_protocol(default<$t(builder_type)>))
            expanded.arguments |> push <| body
            return expanded
        }
        if (length(expr.arguments) != 3 || expr.name!="__ce_lower_protocol" || !(expr.arguments[2] is ExprMakeBlock)) {
            macro_error(prog, expr.at, "computation expects a builder and a trailing block")
            return null
        }
        let blk = (expr.arguments[2] as ExprMakeBlock)._block as ExprBlock
        if (!empty(blk.arguments) || !empty(blk.finalList)) {
            macro_error(prog, expr.at, "computation: block arguments are unsupported; use try_finally(body, cleanup) for cleanup")
            return null
        }
        if (expr.arguments[0]._type == null) { return null }
        serial++
        let name = ce_unique_name("__ce_builder_{serial}", expr.at)
        let protocol = expr.arguments[1]._type
        if (protocol == null) { return null }
        let bt = expr.arguments[0]._type
        if (ce_is_protocol(protocol,"CeMissingProtocol")) {
            macro_error(prog,expr.at,"computation: missing ce_protocol for builder {describe(bt)}; define ce_protocol(builder) returning CeValueProtocol, CeCollectProtocol, ce_sequence_protocol(type<T>) or ce_resumable_protocol(type<Event>)")
            return null
        }
        let resumable_mode = protocol.baseType==Type.tTuple && length(protocol.argTypes)==2 && ce_is_protocol(protocol.argTypes[0],"CeResumableProtocol")
        let sequence_mode = ce_is_sequence_protocol(protocol) || resumable_mode
        if (sequence_mode) {
            var error : string
            var raw=clone_expression(blk)
            if(resumable_mode) {
                raw=ce_resumable_scope(raw,name,error,$(source:ExpressionPtr;isAwait:bool) {
                    if(!isAwait) {return ce_normalize_source(name,source)}
                    if(source is ExprCall && (source as ExprCall).name=="and_bind") {
                        let merged=ce_resumable_merge_source(source,name,error)
                        if(!empty(error)) {return null}
                        return qmacro(ce_await_source($i(name),$e(merged)))
                    }
                    let normalized=ce_normalize_source(name,source)
                    return qmacro(ce_await_source($i(name),$e(normalized)))
                })
                let zero=qmacro_expr() {
                    static_if(typeinfo ce_has_resumable_zero(ce_await_zero($i(name)))) {
                        yield <- ce_await_zero($i(name))
                    }
                }
                (raw as ExprBlock).list |> push <| zero
            }
            if(!empty(error)) {macro_error(prog,expr.at,error);return null}
            var body = ce_sequence_scope(raw, 0, protocol.argTypes[1], ce_sequence_has_resources(raw), error, name)
            if (!empty(error)) {
                macro_error(prog, expr.at, error)
                return null
            }
            var element = clone_type(protocol.argTypes[1])
            var builder_type = clone_type(bt)
            var run=ce_run_scope(name,qmacro(ce_sequence_run($i(name), source)),true,expr.at)
            return qmacro(invoke($($i(name) : $t(builder_type)) {
                var source <- generator<$t(element)> {
                    $e(body)
                    return false
                }
                $e(run);
            }, $e(expr.arguments[0])))
        }
        let owned=ce_is_protocol(protocol,"CeOwnedProtocol")
        let collect_mode = ce_is_protocol(protocol, "CeCollectProtocol") || owned
        if (!collect_mode && !ce_is_protocol(protocol, "CeValueProtocol")) {
            macro_error(prog, expr.at, "computation: ce_protocol must return a builder_protocol descriptor; builder {describe(bt)} returned {describe(protocol)}; expected CeValueProtocol, CeCollectProtocol, CeOwnedProtocol, ce_sequence_protocol(type<T>) or ce_resumable_protocol(type<Event>)")
            return null
        }
        var error : string
        var body <- ce_lower(blk, 0, name, collect_mode, error, owned)
        if (!empty(error)) {
            macro_error(prog, expr.at, error)
            return null
        }
        var builder_type = clone_type(expr.arguments[0]._type)
        let input = ce_unique_name("__ce_input_{serial}", expr.at)
        var run=ce_run_scope(name,qmacro(ce_delay($i(name), $ { $b(body); })),collect_mode,expr.at)
        var scope = qmacro($($i(input) : $t(builder_type)) {
            var $i(name) = $i(input)
            $e(run);
        })
        var result = qmacro(invoke($e(scope), $e(expr.arguments[0])))
        result.at = expr.at
        return result
    }
}














// Sequence bodies lower directly into a native generator: no eager array and
// no escaping stack continuations. Bind becomes a nested loop over the tail.
// Protect only iterator sources; native array/range ownership stays in the generator.
[typeinfo_macro(name="ce_sequence_source")]
class CeSequenceSource : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?; var errors:das_string) : ExpressionPtr {
        if (expr.subexpr==null || expr.subexpr._type==null) {
            errors := "sequence: source type must be inferred"
            return null
        }
        let source=expr.subexpr
        // Fuse protected await adaptation after source normalization/inference.
        if(source is ExprCall && length((source as ExprCall).arguments)==2) {
            let call=source as ExprCall
            var origin=call.func
            while(origin!=null && origin.fromGeneric!=null) {origin=origin.fromGeneric}
            let descriptor=call.arguments[0]._type
            if(origin!=null && origin.name=="ce_await_source" && origin._module.name=="task_builder"
                && descriptor!=null && descriptor.baseType==Type.tTuple && !empty(descriptor.argTypes)
                && descriptor.argTypes[0].baseType==Type.tStructure
                && descriptor.argTypes[0].structType.name=="AsyncSequenceContext"
                && descriptor.argTypes[0].structType._module.name=="async_sequence_builder") {
                return qmacro(ce_await_input($e(call.arguments[0]),$e(call.arguments[1])))
            }
        }
        if (source._type.baseType==Type.tIterator) {
            return qmacro(invoke($ {
                static_if (typeinfo is_ref_value(type<$t(source._type.firstType)>)) {
                    return <- ce_sequence_input($e(source))
                } static_elif (typeinfo can_copy(type<$t(source._type.firstType)>)) {
                    return <- ce_sequence_input($e(source))
                } else {return <- ce_sequence_own_elements($e(source))}
            }))
        }
        return clone_expression(source)
    }
}
def ce_sequence_protect_loop(loop:ExpressionPtr) : ExpressionPtr {
    var result=clone_expression(loop) as ExprFor
    for (source in result.sources) {source=qmacro(typeinfo ce_sequence_source($e(source)))}
    return result
}

def ce_sequence_scope(node : ExpressionPtr; start : int; element : TypeDeclPtr; share : bool; var error : string&; builder:string) : ExpressionPtr {
    var blk = (qmacro_block() {}) as ExprBlock
    if (node == null) { return blk }
    if (node is ExprBlock) { blk = clone_expression(node) as ExprBlock }
    else { blk.list |> push <| clone_expression(node) }
    if (!empty(blk.finalList)) {
        error = "sequence: native finally is unsupported; keep resource ownership outside the iterator"
    }
    var output : array<ExpressionPtr>
    for (index in range(start, length(blk.list))) {
        var stmt = clone_expression(blk.list[index])
        if (stmt is ExprFor) {stmt=ce_normalize_for(builder,stmt)}
        var binding : ExpressionPtr
        if (share && stmt is ExprLet && length((stmt as ExprLet).variables)>1) {
            var expanded : array<ExpressionPtr>
            for (i in range(length((stmt as ExprLet).variables))) {
                var declaration = clone_expression(stmt) as ExprLet
                var variable = declaration.variables[i]
                declaration.variables.resize(1)
                declaration.variables[0] = variable
                expanded |> push <| declaration
            }
            for (i in range(index+1, length(blk.list))) { expanded |> push <| clone_expression(blk.list[i]) }
            var scope = qmacro_block() { $b(expanded); }
            var lowered = ce_sequence_scope(scope, 0, element, share, error, builder)
            for (entry in (lowered as ExprBlock).list) { output |> push <| clone_expression(entry) }
            return qmacro_block() { $b(output); }
        }
        if (stmt is ExprLet && length((stmt as ExprLet).variables)==1) {
            binding = (stmt as ExprLet).variables[0].init
        } elif (stmt is ExprCall) { binding = clone_expression(stmt) }
        if (share && stmt is ExprLet && length((stmt as ExprLet).variables)==1) {
            let variable = (stmt as ExprLet).variables[0]
            // A lowered await borrow is held by the enclosing source loop. It
            // must not be virtualized as an ordinary mutable shared local.
            let marker = (binding != null && binding is ExprCall
                && ((binding as ExprCall).name=="bind" || (binding as ExprCall).name=="use_resource" || (binding as ExprCall).name=="use_task_local"
                    || (binding as ExprCall).name=="ce_await_borrow_value"))
            if (!variable._type.flags.constant && !marker) {
                if (variable._type.flags.ref || variable.flags.inScope || (stmt as ExprLet).letFlags.inScope
                        || variable.flags.init_via_move || variable.flags.init_via_clone) {
                    error = "sequence: shared locals require copyable values, without explicit reference, inscope, move or clone"
                    return blk
                }
                let cell = ce_unique_name("__seq_cell_{variable.name}", stmt.at)
                let original_name = "{variable.name}"
                let initial_name = ce_unique_name("__seq_initial_{variable.name}", stmt.at)
                var declaration = clone_expression(stmt)
                (declaration as ExprLet).variables[0].name := initial_name
                var initialization = qmacro(invoke($ {
                    $e(declaration)
                    return $i(initial_name)
                }))
                var tail : array<ExpressionPtr>
                var cell_declaration = qmacro_expr() {
                    let $i(cell) = ce_sequence_new_cell($e(initialization)) |> use_resource
                }
                cell_declaration.at = stmt.at
                // Native generator loop labels use source coordinates. Keep
                // the synthetic cell loop distinct from its enclosing bind.
                cell_declaration.at.column += 1
                for (i in range(index+1, length(blk.list))) { tail |> push <| clone_expression(blk.list[i]) }
                var scope = qmacro_block() { $b(tail); }
                scope = ce_sequence_replace_local(scope, original_name, cell)
                var complete : array<ExpressionPtr>
                complete |> push <| cell_declaration
                for (entry in (scope as ExprBlock).list) { complete |> push <| clone_expression(entry) }
                scope = qmacro_block() { $b(complete); }
                var lowered = ce_sequence_scope(scope, 0, element, share, error, builder)
                for (entry in (lowered as ExprBlock).list) { output |> push <| clone_expression(entry) }
                return qmacro_block() { $b(output); }
            }
        }
        if (binding != null && binding is ExprCall) {
            let call = binding as ExprCall
            if (call.name == "use_resource" || call.name=="use_task_local") {
                if (!(stmt is ExprLet) || length(call.arguments)!=1) {
                    error = "sequence: expected 'let resource = expression |> use_resource'"
                    return blk
                }
                let identity = "{(stmt as ExprLet).variables[0].name}"
                let owned = ce_unique_name("__seq_owned_{identity}", stmt.at)
                let variable=(stmt as ExprLet).variables[0]
                if (variable.flags.init_via_move || variable.flags.init_via_clone || variable.flags.inScope) {
                    error="use_resource: borrow ownership with 'var resource & = source |> use_resource'"
                    return blk
                }
                if (variable._type.flags.ref) {
                    let cell=ce_unique_name("__seq_resource_cell_{identity}",stmt.at)
                    var raw_tail=qmacro_block() {} as ExprBlock
                    for(i in range(index+1,length(blk.list))) {raw_tail.list |> push <| clone_expression(blk.list[i])}
                    let replaced=ce_sequence_replace_local(raw_tail,identity,cell)
                    var body=ce_sequence_scope(replaced,0,element,share,error,builder)
                    var decl=clone_expression(stmt)
                    (decl as ExprLet).variables[0].init=qmacro($i(cell).value)
                    (decl as ExprLet).variables[0].init.genFlags.alwaysSafe=true
                    (body as ExprBlock).list |> emplace(decl,0)
                    var setup <- qmacro_block_to_array() {var $i(cell)=ce_resource_cell_move($e(call.arguments[0]));}
                    var cleanup=qmacro($ {ce_resource_cell_close($i(cell),$(var $i(owned):typedecl($i(cell).value)) {ce_dispose($i(owned))})})
                    if(call.name=="use_task_local") {cleanup=qmacro($ {ce_resource_cell_close($i(cell),$(var $i(owned):typedecl($i(cell).value)) {ce_task_local_delete($i(owned))})})}
                    output |> push <| ce_sequence_guard(body,setup,cleanup,element,stmt.at,identity)
                    return qmacro_block() {$b(output);}
                }
                var rest = ce_sequence_scope(blk, index+1, element, share, error, builder)
                var decl = clone_expression(stmt)
                (decl as ExprLet).variables[0].init = qmacro($i(owned))
                var tail : array<ExpressionPtr>
                tail |> push <| decl
                for (entry in (rest as ExprBlock).list) { tail |> push <| clone_expression(entry) }
                rest = qmacro_block() { $b(tail); }
                var setup <- qmacro_block_to_array() { var $i(owned) = $e(call.arguments[0]); }
                var cleanup = qmacro($ { ce_dispose($i(owned)) })
                output |> push <| ce_sequence_guard(rest, setup, cleanup, element, stmt.at, identity)
                return qmacro_block() { $b(output); }
            }
            if (call.name == "try_finally") {
                if (!(stmt is ExprCall) || length(call.arguments)!=2
                        || !(call.arguments[0] is ExprMakeBlock) || !(call.arguments[1] is ExprMakeBlock)) {
                    error = "sequence: try_finally expects two blocks (body, cleanup)"
                    return blk
                }
                let body = (call.arguments[0] as ExprMakeBlock)._block as ExprBlock
                let cleanup = (call.arguments[1] as ExprMakeBlock)._block as ExprBlock
                if (!empty(body.arguments) || !empty(cleanup.arguments)) {
                    error = "sequence: try_finally blocks must have no arguments"
                    return blk
                }
                var lowered = ce_sequence_scope(body, 0, element, share, error, builder)
                var setup : array<ExpressionPtr>
                output |> push <| ce_sequence_guard(lowered, setup, call.arguments[1], element, stmt.at, "finally")
                continue
            }
            if (call.name == "try_with") {
                if (!ce_validate_try_with(call, error)) { return blk }
                var body = ce_sequence_scope((call.arguments[0] as ExprMakeBlock)._block, 0, element, share, error, builder)
                var handler = clone_expression(call.arguments[1]) as ExprMakeBlock
                var handler_body = handler._block as ExprBlock
                var fallback = ce_sequence_scope(handler_body, 0, element, share, error, builder)
                var generated = qmacro_expr() {
                    return <- generator<$t(element)> { $e(fallback); return false }
                }
                handler_body.list |> clear()
                handler_body.list |> push <| generated
                handler.mmFlags.isLambda = true
                handler_body.blockFlags.isLambdaBlock = true
                let item = ce_unique_name("__seq_recovered", stmt.at)
                let input = ce_unique_name("__seq_try_source", stmt.at)
                let recovery = ce_unique_name("__seq_try_handler", stmt.at)
                var source = qmacro(invoke($ {
                    var $i(input) <- generator<$t(element)> { $e(body); return false }
                    var $i(recovery) <- $e(handler)
                    return <- ce_sequence_recover($i(input), $i(recovery))
                }))
                var loop = qmacro_expr() { for ($i(item) in $e(source)) {} }
                (loop as ExprFor).body = qmacro_block() {
                    static_if (typeinfo can_copy(type<$t(element)>)) {yield $i(item)}
                    else {yield <- $i(item)}
                }
                loop.at=stmt.at
                (loop as ExprFor).body.at=stmt.at
                output |> push <| ce_sequence_protect_loop(loop)
                continue
            }
            if (call.name == "bind") {
                if (length(call.arguments)!=1) {
                    error = "sequence: expected expression |> bind"
                    return blk
                }
                let name = ce_unique_name("__seq_item", stmt.at)
                var declarations : array<ExpressionPtr>
                if (stmt is ExprLet) {
                    var decl = clone_expression(stmt)
                    (decl as ExprLet).variables[0].init = qmacro($i(name))
                    declarations |> push <| decl
                }
                for (i in range(index+1, length(blk.list))) { declarations |> push <| clone_expression(blk.list[i]) }
                var raw_tail = qmacro_block() { $b(declarations); }
                var rest = ce_sequence_scope(raw_tail, 0, element, share, error, builder)
                let normalized=ce_normalize_source(builder,call.arguments[0])
                var loop = qmacro_expr() { for ($i(name) in $e(normalized)) {} }
                (loop as ExprFor).body = rest
                loop.at = stmt.at
                (loop as ExprFor).body.at = stmt.at
                output |> push <| ce_sequence_protect_loop(loop)
                return qmacro_block() { $b(output); }
            }
        }
        if (stmt is ExprReturn) {
            error = "sequence: use yield or expression |> yield_from, not return"
            return blk
        } elif (stmt is ExprCall && (stmt as ExprCall).name == "yield_value") {
            let call = stmt as ExprCall
            if (length(call.arguments)!=1) { error = "sequence: expected expression |> yield_value"; return blk }
            output |> push <| qmacro_expr() { yield $e(call.arguments[0]) }
        } elif (stmt is ExprCall && (stmt as ExprCall).name == "yield_from") {
            let call = stmt as ExprCall
            if (length(call.arguments)!=1) {
                error = "sequence: expected expression |> yield_from"
                return blk
            }
            let name = ce_unique_name("__seq_yield", stmt.at)
            let normalized=ce_normalize_source(builder,call.arguments[0])
            var loop = qmacro_expr() {
                for ($i(name) in $e(normalized)) {
                    static_if (typeinfo can_copy(type<$t(element)>)) {yield $i(name)}
                    else {yield <- $i(name)}
                }
            }
            loop.at = stmt.at
            (loop as ExprFor).body.at = stmt.at
            output |> push <| ce_sequence_protect_loop(loop)
        } elif (stmt is ExprIfThenElse) {
            var branch = clone_expression(stmt) as ExprIfThenElse
            branch.if_true = ce_sequence_scope(branch.if_true, 0, element, share, error, builder)
            branch.if_false = ce_sequence_scope(branch.if_false, 0, element, share, error, builder)
            output |> push <| branch
        } elif (stmt is ExprFor) {
            var loop = clone_expression(stmt) as ExprFor
            loop.body = ce_sequence_scope(loop.body, 0, element, share, error, builder)
            output |> push <| ce_sequence_protect_loop(loop)
        } elif (stmt is ExprWhile) {
            var loop = clone_expression(stmt) as ExprWhile
            loop.body = ce_sequence_scope(loop.body, 0, element, share, error, builder)
            output |> push <| loop
        } elif (stmt is ExprBlock) {
            output |> push <| ce_sequence_scope(stmt, 0, element, share, error, builder)
        } elif (stmt is ExprYield || stmt is ExprLet || stmt is ExprCall
                || stmt is ExprCallMacro || stmt is ExprCopy || stmt is ExprMove
                || stmt is ExprOp1 || stmt is ExprOp2 || stmt is ExprAssert) {
            output |> push <| clone_expression(stmt)
        } else {
            error = "sequence: unsupported statement {stmt.__rtti}"
            return blk
        }
    }
    return qmacro_block() { $b(output); }
}



// Body and finalizer are owned by one scope iterator; its child is closed first.
def ce_sequence_guard(body : ExpressionPtr; var setup : array<ExpressionPtr>;
                      cleanup : ExpressionPtr; element : TypeDeclPtr; at : LineInfo; identity : string) : ExpressionPtr {
    let item = ce_unique_name("__seq_scoped_{identity}", at)
    let child = ce_unique_name("__seq_child_{identity}", at)
    let finish = ce_unique_name("__seq_finish_{identity}", at)
    var cleanup_lambda = clone_expression(cleanup) as ExprMakeBlock
    cleanup_lambda.mmFlags.isLambda = true
    (cleanup_lambda._block as ExprBlock).blockFlags.isLambdaBlock = true
    var factory_expr = qmacro($ {
        var $i(child) <- generator<$t(element)> { $e(body); return false }
        var $i(finish) <- $e(cleanup_lambda)
        return <- ce_sequence_scoped($i(child), $i(finish))
    })
    var factory = (factory_expr as ExprMakeBlock)._block as ExprBlock
    var entries : array<ExpressionPtr>
    for (entry in setup) { entries |> push <| clone_expression(entry) }
    for (entry in factory.list) { entries |> push <| clone_expression(entry) }
    factory.list |> clear()
    for (entry in entries) { factory.list |> push <| clone_expression(entry) }
    var source = qmacro(invoke($e(factory_expr)))
    var loop = qmacro_expr() { for ($i(item) in $e(source)) {} }
    (loop as ExprFor).body = qmacro_block() {
                    static_if (typeinfo can_copy(type<$t(element)>)) {yield $i(item)}
                    else {yield <- $i(item)}
                }
    loop.at = at
    (loop as ExprFor).body.at = at
    return ce_sequence_protect_loop(loop)
}




[macro_interface]
class SequenceResourceFinder : AstVisitor {
    found : bool = false
    def override preVisitExprCall(expr : ExprCall?) {
        if (expr.name=="use_resource" || expr.name=="use_task_local" || expr.name=="try_finally" || expr.name=="try_with") { found=true }
    }
}
def ce_sequence_has_resources(body : ExpressionPtr) : bool {
    var finder = new SequenceResourceFinder()
    make_visitor(*finder) $(adapter) { visit(body, adapter) }
    let result = finder.found
    unsafe { delete finder }
    return result
}




// Substitute only references to this declaration. Nested locals, block
// arguments and for iterators with the same name retain their own bindings.
[macro_interface]
class SequenceLocalReferences : AstVisitor {
    original : string
    cell : string
    hidden : bool = false
    scopes : array<bool>
    def save() { scopes |> push(hidden) }
    def restore() { hidden=scopes[length(scopes)-1]; scopes |> pop() }
    def override preVisitExprBlock(blk : ExprBlock?) {
        self.save()
        for (arg in blk.arguments) { if (arg.name==original) {hidden=true} }
    }
    def override visitExprBlock(var blk : ExprBlock?) : ExpressionPtr { self.restore(); return blk }
    def override visitExprLetVariable(expr : ExprLet?; var arg : VariablePtr; lastArg : bool) : VariablePtr {
        if (arg.name==original) {hidden=true}
        return arg
    }
    def override preVisitExprFor(expr : ExprFor?) { self.save() }
    def override preVisitExprForStack(expr : ExprFor?) {
        for (name in expr.iterators) { if (name==original) {hidden=true} }
    }
    def override visitExprFor(var expr : ExprFor?) : ExpressionPtr { self.restore(); return expr }
    def override visitExprVar(var expr : ExprVar?) : ExpressionPtr {
        if (!hidden && expr.name==original) {
            var result = qmacro($i(cell).value)
            result.at=expr.at
            return result
        }
        return expr
    }
}
def ce_sequence_replace_local(body : ExpressionPtr; original, cell : string) : ExpressionPtr {
    var visitor = new SequenceLocalReferences(original=original,cell=cell)
    var result : ExpressionPtr
    make_visitor(*visitor) $(adapter) { result=visit(body,adapter) }
    unsafe {delete visitor}
    return result
}





def ce_validate_try_with(call : ExprCall?; var error : string&) : bool {
    if (length(call.arguments)!=2 || !(call.arguments[0] is ExprMakeBlock)
            || !(call.arguments[1] is ExprMakeBlock)) {
        error="computation: try_with expects a body block and a handler block"
        return false
    }
    let body=(call.arguments[0] as ExprMakeBlock)._block as ExprBlock
    let handler=(call.arguments[1] as ExprMakeBlock)._block as ExprBlock
    if (!empty(body.arguments) || length(handler.arguments)!=1) {
        error="computation: try_with body takes no arguments; handler takes one string message"
        return false
    }
    return true
}


// Only descriptors are recognized here, never concrete builder types/modules.
def ce_is_protocol(t : TypeDeclPtr; name : string) : bool {
    return (t != null && t.baseType==Type.tStructure && t.structType.name==name
        && t.structType._module.name=="builder_protocol")
}
def ce_is_sequence_protocol(t : TypeDeclPtr) : bool {
    return (t != null && t.baseType==Type.tTuple && length(t.argTypes)==2
        && ce_is_protocol(t.argTypes[0], "CeSequenceProtocol"))
}














