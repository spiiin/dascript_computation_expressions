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
    // qmacro stamps the hook call, and the root of the source it substitutes,
    // with this file's position; an error in either belongs to the user's source.
    var hook=(result as ExprTypeInfo).subexpr as ExprCall
    hook.at=source.at
    hook.arguments[1].at=source.at
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

// ---- Source positions --------------------------------------------------------
// qmacro gives a generated node its position in this file, so a type error in
// generated code would point here. Every node that is not from the user's file
// gets the position of the statement being lowered; user code keeps its own.
// A typedecl(expr) keeps its expression inside the type, out of the visitor's
// reach, so declared types are walked explicitly.
//
// The compiler prints errors in source order. A call that carries the rest of
// a scope as a block cannot be typed while anything inside that block is
// wrong, and neither can the declarations a scope needs in front of its
// statements. Their errors only repeat that something else failed, so they
// are placed at the end of the computation, after the errors that matter.
//
// The compiler also prints one error per line and counts the rest. On that
// last line an inner carrier therefore stands a column to the left of the one
// around it: when a carrier itself is what does not fit its builder, such as
// a try_with handler of the wrong type, it is the innermost one that fails,
// and that is the error shown.
var private ce_scope_tail = LineInfo()
def private ce_scope_end(at : LineInfo) : LineInfo {
    return ce_scope_tail.fileInfo != null && ce_scope_tail.fileInfo == at.fileInfo ? ce_scope_tail : at
}
def private ce_scope_carrier(expr : ExpressionPtr) : bool {
    if (expr is ExprCall) {
        let call = expr as ExprCall
        let count = length(call.arguments)
        return count > 0 && call.arguments[count-1] is ExprMakeBlock
    }
    if (expr is ExprInvoke) {
        let call = expr as ExprInvoke
        return length(call.arguments) > 0 && call.arguments[0] is ExprMakeBlock
    }
    return false
}
[macro_interface]
class CeRestamp : AstVisitor {
    @safe_when_uninitialized at : LineInfo
    @safe_when_uninitialized tail : LineInfo
    ended : bool            // `tail` is the end of a computation, not `at` again
    outer : bool            // what wraps the whole computation stays at its very end
    carriers : array<Expression?>
    def inward() : LineInfo {
        var position = tail
        let column = int(tail.column) - (outer ? 0 : 1 + length(carriers))
        position.column = uint(column < 1 ? 1 : column)
        position.last_column = position.column
        return position
    }
    def declared(var variable : VariablePtr) {
        if (variable.at.fileInfo != at.fileInfo) { variable.at = at }
        if (variable._type == null) { return }
        if (variable._type.at.fileInfo != at.fileInfo) { variable._type.at = at }
        for (inner in variable._type.typeMacroExpr) { ce_restamp(inner, at) }
    }
    def override preVisitExpression(var expr : ExpressionPtr) : void {
        if (ended && expr is ExprCallMacro && (expr as ExprCallMacro).name == "__ce_stage") {
            // What this stage emits later lies inside the carriers around it.
            (expr as ExprCallMacro).arguments[1].at = self->inward()
        }
        if (expr.at.fileInfo == at.fileInfo) { return }
        if (ended && ce_scope_carrier(expr)) {
            expr.at = self->inward()
            carriers |> push(expr)
        } else {
            expr.at = at
        }
    }
    def override visitExpression(var expr : ExpressionPtr) : ExpressionPtr {
        let count = length(carriers)
        if (count > 0 && carriers[count-1] == expr) { carriers |> pop() }
        return expr
    }
    def override preVisitExprBlockArgument(blk : ExprBlock?; var arg : VariablePtr; lastArg : bool) : void {
        self.declared(arg)
    }
    def override preVisitExprLetVariable(expr : ExprLet?; var arg : VariablePtr; lastArg : bool) : void {
        self.declared(arg)
    }
}
def ce_restamp(var expr : ExpressionPtr; at : LineInfo; outer : bool = false) {
    if (expr == null || at.fileInfo == null) { return }
    let ended = ce_scope_tail.fileInfo != null && ce_scope_tail.fileInfo == at.fileInfo
    var visitor = new CeRestamp(at=at, tail=ce_scope_end(at), ended=ended, outer=outer)
    make_visitor(*visitor) $(adapter) { visit(expr, adapter) }
    unsafe { delete visitor }
}

// A scope lowered into a generator is restamped more carefully. The compiler
// names what it hoists out of a generator after positions: a generator's
// yield argument after the line of its block, a local after its own line and
// column. Those nodes keep the positions they have. Generated calls move:
// that is where a builder operation that does not fit is reported. A call
// takes the position of the first user code inside it, or of the user code
// just before it. Yields move too. While anything in the generator is wrong,
// the compiler complains about every yield in it, and those complaints
// should follow the real error: a generated yield goes to the end of the
// computation, a yield the user wrote goes just past its value.
[macro_interface]
class CeRestampCalls : AstVisitor {
    @safe_when_uninitialized latest : LineInfo
    @safe_when_uninitialized tail : LineInfo
    waiting : array<Expression?>
    def override preVisitExpression(var expr : ExpressionPtr) : void {
        if (expr.at.fileInfo != latest.fileInfo) {
            if (expr is ExprCall) { waiting |> push(expr) }
            elif (expr is ExprYield) { expr.at = tail }
            return
        }
        latest = expr.at
        for (call in waiting) { call.at = expr.at }
        waiting |> clear()
    }
    def override visitExpression(var expr : ExpressionPtr) : ExpressionPtr {
        let count = length(waiting)
        if (count > 0 && waiting[count-1] == expr) {
            expr.at = latest
            waiting |> pop()
        } elif (expr is ExprYield && expr.at.fileInfo == latest.fileInfo
                && !(expr.at.line == tail.line && expr.at.column == tail.column)) {
            // Just past the last piece of the value the user yields.
            let column = latest.last_column > latest.column ? latest.last_column : latest.column + 1u
            expr.at = latest
            expr.at.column = column
            expr.at.last_column = column
        }
        return expr
    }
}
def ce_restamp_calls(var expr : ExpressionPtr; at : LineInfo) {
    if (expr == null || at.fileInfo == null) { return }
    var visitor = new CeRestampCalls(latest=at, tail=ce_scope_end(at))
    make_visitor(*visitor) $(adapter) { visit(expr, adapter) }
    unsafe { delete visitor }
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
    // The slot count carries the end of the computation to the stage's visit.
    stage.arguments |> push <| new ExprConstInt(at=ce_scope_end(at), value=length(slots))
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
    // A bind's last probe unwraps what the ce_source hook returns. It is a call
    // on a call and is typed a pass late, so it is awaited only when the builder
    // has a hook for this source; without one it is never read.
    var optional = -1
    if ((expr.arguments[0] as ExprConstString).value == "bind" && ce_stage_probe_slots(expr) == 6) {
        let hook = expr.arguments[3]
        if (hook._type != null && ce_is_protocol(hook._type, "CeSourceFallback")) { optional = 4 }
    }
    for (index in range(ce_stage_probe_slots(expr))) {
        let probe = expr.arguments[2 + index]
        if (probe is ExprConstBool || index == optional) { continue }
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
// A source the builder cannot bind is reported once, at the bind, and the rest
// of the scope is not emitted: everything in it depends on the value.
def private ce_bind_invalid(var expr : ExprCallMacro?; source, unwrapped : ExpressionPtr) : ExpressionPtr {
    let at = ce_stage_at(expr)
    var builderType = clone_type((unwrapped as ExprCall).arguments[0]._type)
    var sourceType = clone_type(source._type)
    builderType.flags.ref = false; builderType.flags.constant = false
    sourceType.flags.ref = false; sourceType.flags.constant = false
    let message = "computation: {describe(builderType)} cannot bind a source of type {describe(sourceType)}: no ce_unwrap(builder, source) accepts it"
    var invalid = qmacro(invoke($ { static_assert(false, $v(message)); return CeNotBindable() }))
    // A collecting scope returns its collection by move; Zero has that type.
    if (ce_stage_flag(expr, 4)) {
        invalid = qmacro(invoke($ { static_assert(false, $v(message)); return <- ce_zero($i(ce_stage_text(expr, 3))) }))
    }
    // qmacro stamped both with the template position; the error belongs to the user.
    invalid.at = at
    (((invalid as ExprInvoke).arguments[0] as ExprMakeBlock)._block as ExprBlock).list[0].at = at
    return invalid
}
def private ce_stage_bind(var expr : ExprCallMacro?; var error : string&) : ExpressionPtr {
    let source = ce_stage_probe(expr, 0, error)
    if (source == null) { return null }
    // Slot 3 is the source's hook call, or a constant when it has none.
    let hooked = !(expr.arguments[3] is ExprConstBool) && !ce_is_protocol(expr.arguments[3]._type, "CeSourceFallback")
    let unwrapped = ce_stage_probe(expr, hooked ? 2 : 1, error)
    if (ce_is_protocol(unwrapped._type, "CeNotBindable")) { return ce_bind_invalid(expr, source, unwrapped) }
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
    // The probe is the call the continuation's argument is declared with, and
    // it is typed already: the argument gets that type now instead of a pass
    // later. A borrowing bind is probed with ce_unwrap_borrow, which a fused
    // mapper does not use.
    ce_stage_retype_argument(ordinary, unwrapped._type)
    if (mapper != null && !(borrow_bind && !owned)) { ce_stage_retype_argument(mapper, unwrapped._type) }
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
// `inlined`: the body is a direct scope's own statements, not a computation to
// hand to a hook. Only a for needs the stage then, to type its sources.
// One array or fixed array, walked by index with the body inline. A native
// `for` would hold the array's lock itself and keep it if the body panics.
def private ce_loop_indexed(original : ExprFor?; source, body : ExpressionPtr; at : LineInfo) : ExpressionPtr {
    let name = ce_unique_name("__ce_loop_array", at)
    let index = ce_unique_name("__ce_loop_index", at)
    let message = ce_unique_name("__ce_loop_error", at)
    var element = qmacro($i(name)[$i(index)])
    element.genFlags.alwaysSafe = true
    var alias = qmacro_expr() { var $i(string(original.iterators[0])) & = $e(element) } as ExprLet
    alias.variables[0]._type.flags.removeConstant = false
    alias.variables[0]._type.flags.constant = false
    var statements : array<ExpressionPtr>
    statements |> push <| alias
    for (statement in (body as ExprBlock).list) { statements |> push <| clone_expression(statement) }
    var next : ExpressionPtr
    if (source._type.isConst) {
        next = qmacro($($i(name) : typedecl($e(source))) {
            var $i(message) = ""
            ce_loop_lock($i(name))
            try {
                for ($i(index) in range(length($i(name)))) { $b(statements); }
            } recover { $i(message) = ce_zip_exception() }
            ce_loop_unlock($i(name))
            if (!empty($i(message))) { panic($i(message)) }
            return true
        })
    } else {
        next = qmacro($(var $i(name) : typedecl($e(source))) {
            var $i(message) = ""
            ce_loop_lock($i(name))
            try {
                for ($i(index) in range(length($i(name)))) { $b(statements); }
            } recover { $i(message) = ce_zip_exception() }
            ce_loop_unlock($i(name))
            if (!empty($i(message))) { panic($i(message)) }
            return true
        })
    }
    ce_stage_retype_argument(next, source._type)
    return ce_stage_apply_emit(source, next, false, at)
}
def ce_loop_stage(stmt, body : ExpressionPtr; builder : string; collect_mode, owned : bool; inlined : bool = false) : ExpressionPtr {
    var skeleton = clone_expression(stmt)
    if (skeleton is ExprFor) { (skeleton as ExprFor).body = qmacro_block() {} }
    else { (skeleton as ExprWhile).body = qmacro_block() {} }
    var payload : array<ExpressionPtr>
    payload |> push <| qmacro($ { $e(skeleton); })
    payload |> push <| qmacro($ { $e(body); })
    payload |> push <| new ExprConstString(at=stmt.at, value:=builder)
    payload |> push <| new ExprConstBool(at=stmt.at, value=collect_mode)
    payload |> push <| new ExprConstBool(at=stmt.at, value=owned)
    payload |> push <| new ExprConstBool(at=stmt.at, value=inlined)
    var probes : array<ExpressionPtr>
    if (stmt is ExprWhile) {
        let iteration = ce_loop_iteration(builder, ce_loop_zero_body(builder, collect_mode), collect_mode)
        probes |> push <| qmacro(ce_while($i(builder), $ { return true }, $e(iteration)))
        return ce_stage("while", stmt.at, probes, payload)
    }
    let original = stmt as ExprFor
    let arity = length(original.sources)
    for (source in original.sources) { probes |> push <| clone_expression(source) }
    if (arity > 1 && !inlined) {
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
    if (ce_stage_flag(expr, 5)) {
        var ranges = true
        for (source in sources) {
            if (!source._type.isRange) { ranges = false }
        }
        if (ranges) {
            // A range owns nothing, so a panic leaves nothing behind: the loop
            // is the user's own `for` with the lowered body.
            var plain = clone_expression(original) as ExprFor
            for (index in range(arity)) { plain.sources[index] = clone_expression(sources[index]) }
            plain.body = ce_stage_statement(expr, 1)
            return plain
        }
        let only = sources[0]._type
        if (arity == 1 && (only.isGoodArrayType || only.baseType == Type.tFixedArray)) {
            return ce_loop_indexed(original, sources[0], ce_stage_statement(expr, 1), ce_stage_at(expr))
        }
        // The traversal itself is the loop: its cursors still close when a
        // source or the body panics, and the body runs in the enclosing scope.
        var names : array<string>
        for (index in range(arity)) {
            names |> push(ce_unique_name("__ce_loop_source_{index}", ce_stage_at(expr)))
        }
        var loop = ce_zip_traversal(original, names, null, "", ce_stage_statement(expr, 1))
        return ce_loop_source_scopes(sources, loop, names, ce_stage_at(expr))
    }
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
        if (mode.structType.name=="CeZipWritable" && mode.structType._module.name=="zip_runtime"
                && element.flags.ref && element.flags.constant) {
            var writableAccess=qmacro(reinterpret<typedecl($e(access)) -const &>($e(access)))
            writableAccess.genFlags.alwaysSafe=true
            return writableAccess
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

def private ce_lower_try_with(call : ExprCall?; builder : string; collect_mode, owned, direct : bool; var error : string&;
                              escape : string = "") : ExpressionPtr {
    if (!ce_validate_try_with(call, error)) { return null }
    var protected_body = ce_scope((call.arguments[0] as ExprMakeBlock)._block, builder, collect_mode, error, owned, direct, escape)
    var handler = clone_expression(call.arguments[1]) as ExprMakeBlock
    var handler_body = handler._block as ExprBlock
    var lowered = ce_scope(handler_body, builder, collect_mode, error, owned, direct, escape) as ExprBlock
    handler_body.list |> clear()
    for (entry in lowered.list) { handler_body.list |> push <| clone_expression(entry) }
    return qmacro(ce_try_with($i(builder), $ { $e(protected_body); }, $e(handler)))
}
def private ce_lower_try_finally(call : ExprCall?; builder : string; collect_mode, owned, direct : bool; var error : string&;
                                 escape : string = "") : ExpressionPtr {
    if (length(call.arguments) != 2 || !(call.arguments[0] is ExprMakeBlock)
            || !(call.arguments[1] is ExprMakeBlock)) {
        error = "computation: try_finally expects two blocks (body, cleanup)"
        return null
    }
    let source = (call.arguments[0] as ExprMakeBlock)._block as ExprBlock
    let cleanup_source = (call.arguments[1] as ExprMakeBlock)._block as ExprBlock
    if (!empty(source.arguments) || !empty(cleanup_source.arguments)) {
        error = "computation: try_finally blocks must have no arguments"
        return null
    }
    var protected_body = ce_scope(source, builder, collect_mode, error, owned, direct, escape)
    var cleanup = clone_expression(call.arguments[1])
    return qmacro(ce_try_finally($i(builder), $ { $e(protected_body); }, $e(cleanup)))
}
def private ce_validate_use_resource(stmt : ExpressionPtr; call : ExprCall?; var error : string&) : bool {
    if (!(stmt is ExprLet) || length(call.arguments) != 1) {
        error = "computation: expected 'let resource = expression |> use_resource'"
        return false
    }
    let variable=(stmt as ExprLet).variables[0]
    if (variable.flags.init_via_move || variable.flags.init_via_clone || variable.flags.inScope) {
        error="use_resource: borrow ownership with 'var resource & = source |> use_resource'"
        return false
    }
    return true
}
// `rest` is the lowered remainder of the scope: it becomes the continuation.
def private ce_lower_use_resource(stmt : ExpressionPtr; call : ExprCall?; var rest : array<ExpressionPtr>; builder : string) : ExpressionPtr {
    let variable=(stmt as ExprLet).variables[0]
    let moveResource=variable._type.flags.ref && !variable._type.flags.constant
    let argument = ce_unique_name("__ce_resource", stmt.at)
    var declaration = clone_expression(stmt)
    (declaration as ExprLet).variables[0].init = qmacro($i(argument))
    if (moveResource) {(declaration as ExprLet).variables[0].init.genFlags.alwaysSafe=true}
    rest |> emplace(declaration, 0)
    if (moveResource) {
        var owner=qmacro($(var $i(argument):typedecl($e(call.arguments[0]))) {$b(rest);})
        return qmacro(ce_using_move($i(builder),$e(call.arguments[0]),$e(owner),
            $(var $i(argument):typedecl($e(call.arguments[0]))) {ce_dispose($i(argument))}))
    }
    var continuation = qmacro($($i(argument) : typedecl($e(call.arguments[0]))) { $b(rest); })
    return qmacro(ce_using($i(builder), $e(call.arguments[0]), $e(continuation),
        $(var $i(argument) : typedecl($e(call.arguments[0])) ) { ce_dispose($i(argument)) }))
}

// ---- Direct lowering ---------------------------------------------------------
// A builder that only short-circuits (CeDirectProtocol) needs no continuations.
// Its scope stays one block: a bind evaluates the source, returns the failure
// converted to the scope's result type, or declares the value. `if`, nested
// blocks and loops stay native, so a branch may return early and a loop may
// break or continue. try_with, try_finally and use_resource still go through
// the builder's operations.
//
// A `for` keeps the traversal that owns its cursors, so a panic in a source or
// in the body still closes them; its body is the scope's own statements. A
// return there would skip that cleanup, and a return inside try/recover is not
// reliable under JIT, so inside a loop the scope's result is parked in an
// outcome slot and the loop is left with break.
//
// The result type is not known where a failure returns: it is the type of the
// scope's last statement. `witness` is a null pointer to that type; it is typed
// by a replica of the scope's declarations and is never dereferenced.

// Type-only companion of ce_checked_merge: an unsupported group is reported
// once, where it is evaluated, so the replica silently takes the left source.
[typeinfo_macro(name="ce_quiet_merge")]
class CeQuietMerge : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?; var errors:das_string) : ExpressionPtr {
        if (expr.subexpr==null || expr.subexpr._type==null) {errors:="computation: and_bind source types must be inferred";return null}
        if (ce_is_protocol(expr.subexpr._type, "CeMergeSourcesFallback")) {
            return clone_expression((expr.subexpr as ExprCall).arguments[1])
        }
        return clone_expression(expr.subexpr)
    }
}
def private ce_direct_block(node : ExpressionPtr) : ExprBlock? {
    if (node is ExprBlock) { return clone_expression(node) as ExprBlock }
    var blk = (qmacro_block() {}) as ExprBlock
    blk.list |> push <| clone_expression(node)
    return blk
}
// Does control never fall out of the end of this statement?
def private ce_direct_returns(node : ExpressionPtr) : bool {
    if (node == null) { return false }
    if (node is ExprReturn) { return true }
    if (node is ExprIfThenElse) {
        let branch = node as ExprIfThenElse
        return branch.if_false != null && ce_direct_returns(branch.if_true) && ce_direct_returns(branch.if_false)
    }
    if (node is ExprBlock) {
        let blk = node as ExprBlock
        return !empty(blk.list) && ce_direct_returns(blk.list[length(blk.list)-1])
    }
    return false
}
// Evaluate a source into a local and return its name. A single source goes
// through the optional ce_source hook: the local holds the hook's result, or
// the source itself when the builder has no hook for it. That choice is made
// by rewriting a typeinfo after inference, so the local is typed a pass late.
// A bound value must not wait for it, or every bind would cost a pass: `raw`
// names the unresolved source, and the value is typed from it by
// ce_direct_typed. A group merges into one local and leaves `raw` empty.
// `quiet` is for the replica: it is only typed, so it resolves the hook by
// overload and does not report an unsupported group a second time.
def private ce_direct_evaluate(node : ExpressionPtr; builder : string; at : LineInfo; quiet : bool;
                               var output : array<ExpressionPtr>; var raw : string&; var error : string&) : string {
    raw = ""
    if (ce_is_group(node)) {
        let call = node as ExprCall
        if (length(call.arguments) != 2) {
            error = "computation: expected 'left |> and_bind(right) |> bind'"
            return ""
        }
        var unused : string
        let left = ce_direct_evaluate(call.arguments[0], builder, at, quiet, output, unused, error)
        let right = ce_direct_evaluate(call.arguments[1], builder, at, quiet, output, unused, error)
        if (!empty(error)) { return "" }
        let merged = ce_unique_name("__ce_merged", node.at)
        var declaration : ExpressionPtr
        if (quiet) {
            declaration = qmacro_expr() {
                let $i(merged) = typeinfo ce_quiet_merge(ce_merge_sources($i(builder), $i(left), $i(right)))
            }
        } else {
            let location="{node.at.fileInfo.name}:{int(node.at.line)}:{int(node.at.column)}"
            ce_merge_locations |> insert(location,new ExprConstBool(at=node.at,value=true))
            declaration = qmacro_expr() {
                let $i(merged) = typeinfo ce_checked_merge(ce_merge_origin(ce_merge_sources($i(builder), $i(left), $i(right)), $i(builder), $v(location)))
            }
        }
        output |> push <| declaration
        return merged
    }
    raw = ce_unique_name("__ce_raw", node.at)
    let source = ce_unique_name("__ce_source", node.at)
    var evaluated = qmacro_expr() { let $i(raw) = $e(node) }
    var resolved : ExpressionPtr
    if (quiet) {
        resolved = qmacro_expr() { let $i(source) = ce_direct_resolved($i(builder), $i(raw)) }
    } else {
        resolved = qmacro_expr() { let $i(source) = typeinfo ce_resolved_source(ce_source($i(builder), $i(raw))) }
    }
    output |> push <| evaluated
    output |> push <| resolved
    return source
}
def private ce_direct_replica_declaration(stmt : ExpressionPtr; builder : string; var output : array<ExpressionPtr>) {
    var declaration = clone_expression(stmt)
    var variable = (declaration as ExprLet).variables[0]
    // Only the type matters here: nothing in the replica is owned or run.
    variable.flags.inScope = false
    (declaration as ExprLet).letFlags.inScope = false
    if (variable.init != null && variable.init is ExprCall && length((variable.init as ExprCall).arguments) == 1) {
        let call = variable.init as ExprCall
        if (call.name == "bind") {
            var raw, ignored : string
            let source = ce_direct_evaluate(call.arguments[0], builder, stmt.at, true, output, raw, ignored)
            if (empty(source)) { return }
            // As in the scope itself, the value is typed from the unresolved source.
            if (empty(raw)) { variable.init = qmacro(ce_unwrap($i(builder), $i(source))) }
            else { variable.init = qmacro(ce_direct_typed($i(builder), $i(raw))) }
        } elif (call.name == "use_resource") {
            variable.init = clone_expression(call.arguments[0])
            variable._type.flags.ref = false
        }
    }
    output |> push <| declaration
}
// Statements whose block has the result type of the scope starting at `start`.
def private ce_direct_replica(blk : ExprBlock?; start : int; builder : string) : array<ExpressionPtr> {
    var output : array<ExpressionPtr>
    let count = length(blk.list)
    var terminal : ExpressionPtr
    if (count > start) {
        let last = blk.list[count-1]
        if (last is ExprReturn && (last as ExprReturn).subexpr != null) {
            let value = (last as ExprReturn).subexpr
            if (value is ExprCall && (value as ExprCall).name == "return_from" && length((value as ExprCall).arguments) == 1) {
                var forwarded : array<ExpressionPtr>
                var ignored : string
                var raw : string
                let source = ce_direct_evaluate((value as ExprCall).arguments[0], builder, last.at, true, forwarded, raw, ignored)
                forwarded |> push <| qmacro_expr() { return ce_return_from($i(builder), $i(source)) }
                terminal = qmacro_block() { $b(forwarded); }
            } else {
                terminal = qmacro_expr() { return ce_return($i(builder), $e(value)) }
                // The same position as in the scope itself: an error in the
                // value is then reported once, not once per copy.
                (((terminal as ExprReturn).subexpr as ExprCall).arguments[1]).at = value.at
            }
        } elif (ce_direct_returns(last)) {
            // Every branch has the scope's type; the first one is enough.
            var inner <- ce_direct_replica(ce_direct_block(last is ExprIfThenElse ? (last as ExprIfThenElse).if_true : last), 0, builder)
            terminal = qmacro_block() { $b(inner); }
        } elif (last is ExprCall && ((last as ExprCall).name == "try_with" || (last as ExprCall).name == "try_finally")
                && length((last as ExprCall).arguments) == 2 && (last as ExprCall).arguments[0] is ExprMakeBlock) {
            var inner <- ce_direct_replica(((last as ExprCall).arguments[0] as ExprMakeBlock)._block as ExprBlock, 0, builder)
            terminal = qmacro_block() { $b(inner); }
        }
    }
    if (terminal == null) {
        // Loops and plain statements leave a Unit; no declaration matters.
        output |> push <| qmacro_expr() { return ce_zero($i(builder)) }
        return <- output
    }
    for (index in range(start, count-1)) {
        if (blk.list[index] is ExprLet && length((blk.list[index] as ExprLet).variables) == 1) {
            ce_direct_replica_declaration(blk.list[index], builder, output)
        }
    }
    output |> push <| terminal
    return <- output
}
// What a scope needs declared in front of its statements.
struct private CeDirectState {
    witness : bool      // a failure is converted to the result type
    loops : bool        // a loop may park the result and leave
    escapes : bool      // a scope nested in a loop body may break or continue the loop
}
// try_with, try_finally and the scope after use_resource are blocks handed to
// the builder, so a break or continue inside them cannot reach the loop around
// them. It says which way to go in this variable of the loop's scope, 1 to
// continue and 2 to break, and ends its own scope with Unit. Every scope on
// the way out ends the same way, and the loop body acts on it.
def private ce_direct_escape(witness : string) : string { return "{witness}_escape" }
def private ce_direct_escaped(builder, witness, inherited : string; looped : bool;
                              var output : array<ExpressionPtr>; var state : CeDirectState&) {
    if (looped) {
        let escape = ce_direct_escape(witness)
        output |> push <| qmacro_expr() { if ($i(escape) == 2) { $i(escape) = 0; break } }
        output |> push <| qmacro_expr() { if ($i(escape) == 1) { $i(escape) = 0; continue } }
        state.escapes = true
    } elif (!empty(inherited)) {
        output |> push <| qmacro_expr() { if ($i(inherited) != 0) { return ce_zero($i(builder)) } }
    }
}
def private ce_direct_outcome(witness : string) : string { return "{witness}_outcome" }
def private ce_direct_left(witness : string) : string { return "{witness}_left" }
// Leave the scope with `value`: return it, or inside a loop park it and break.
def private ce_direct_leave(var value : ExpressionPtr; witness : string; looped : bool) : ExpressionPtr {
    if (!looped) { return qmacro_expr() { return $e(value) } }
    return qmacro_block() {
        $i(ce_direct_outcome(witness)) <- $e(value)
        $i(ce_direct_left(witness)) = true
        break
    }
}
// After a loop: keep leaving if its body parked the result.
def private ce_direct_resume(witness : string; looped : bool) : ExpressionPtr {
    if (looped) { return qmacro_expr() { if ($i(ce_direct_left(witness))) { break } } }
    return qmacro_expr() { if ($i(ce_direct_left(witness))) { return <- $i(ce_direct_outcome(witness)) } }
}
// Leave the scope with the failure of `name`, converted to the result type.
// A step between statements (`unit`) must produce Unit, as Combine requires.
def private ce_direct_check(builder, name, witness : string; unit, looped : bool) : ExpressionPtr {
    var leave = ce_direct_leave(qmacro(ce_direct_failure($i(builder), $i(name), $i(witness))), witness, looped)
    if (unit) {
        return qmacro_expr() {
            if (ce_loop_failed($i(builder), $i(name))) { $e(leave) }
        }
    }
    return qmacro_expr() {
        if (ce_direct_failed($i(builder), $i(name))) { $e(leave) }
    }
}
// The user's declaration, initialized with the value of the checked source.
def private ce_direct_declaration(stmt : ExpressionPtr; builder, source, raw : string) : ExpressionPtr {
    var declaration = clone_expression(stmt)
    var variable = (declaration as ExprLet).variables[0]
    var value = qmacro(ce_unwrap($i(builder), $i(source)))
    variable.init = value
    if (!empty(raw) && (variable._type == null || variable._type.baseType == Type.autoinfer)) {
        // Typed from the unresolved source; see ce_direct_evaluate.
        var typed = qmacro_expr() { let typed_local : typedecl(ce_direct_typed($i(builder), $i(raw))) = 0 }
        var declared = clone_type((typed as ExprLet).variables[0]._type)
        if (variable._type != null) { declared.flags = variable._type.flags }
        variable._type = declared
    }
    return declaration
}
// `top` scopes are the body of their own block and end in Zero when control can
// fall out; `tail` is true while the last statement is also the block's last.
// One statement of a direct scope. True when it ends the scope: it returned,
// the rest became a resource's continuation, or an error was reported.
def private ce_direct_statement(blk : ExprBlock?; index : int; builder, witness, inherited : string; tail, looped : bool;
                                var output : array<ExpressionPtr>; var state : CeDirectState&; var error : string&) : bool {
    // What a scope nested at this statement says to break or continue.
    let nested = looped ? ce_direct_escape(witness) : inherited
    let count = length(blk.list)
    var stmt = clone_expression(blk.list[index])
    let last = index == count-1
    if (stmt is ExprFor) {stmt=ce_normalize_for(builder,stmt)}
    if (stmt is ExprReturn) {
        let ret = stmt as ExprReturn
        if (!last || ret.subexpr == null) {
            error = "computation: return must be the final statement of its scope and have a value"
            return true
        }
        var returned : ExpressionPtr
        if (ret.subexpr is ExprCall && (ret.subexpr as ExprCall).name == "return_from") {
            let call = ret.subexpr as ExprCall
            if (length(call.arguments) != 1) {
                error = "computation: expected 'return expression |> return_from'"
                return true
            }
            var raw : string
            let forwarded = ce_direct_evaluate(call.arguments[0], builder, stmt.at, false, output, raw, error)
            if (!empty(error)) { return true }
            returned = ce_direct_leave(qmacro(ce_return_from($i(builder), $i(forwarded))), witness, looped)
        } else {
            var value = qmacro(ce_return($i(builder), $e(ret.subexpr)))
            (value as ExprCall).arguments[1].at = ret.subexpr.at
            returned = ce_direct_leave(value, witness, looped)
        }
        returned.at = stmt.at
        output |> push <| returned
        return true
    }
    if (stmt is ExprBreak || stmt is ExprContinue) {
        if (looped) {
            output |> push <| stmt
            return false
        }
        if (empty(inherited)) {
            error = "computation: break and continue need a loop around them"
            return true
        }
        let way = stmt is ExprBreak ? 2 : 1
        output |> push <| qmacro_expr() { $i(inherited) = $v(way) }
        output |> push <| qmacro_expr() { return ce_zero($i(builder)) }
        return true
    }
    var binding : ExpressionPtr
    if (stmt is ExprLet) {
        if (length((stmt as ExprLet).variables) != 1) {
            error = "computation: declare one variable per statement"
            return true
        }
        binding = (stmt as ExprLet).variables[0].init
    } elif (stmt is ExprCall) {
        binding = stmt
    }
    if (binding != null && binding is ExprCall && (binding as ExprCall).name == "bind") {
        let call = binding as ExprCall
        if (length(call.arguments) != 1) {
            error = "computation: expected 'expression |> bind'"
            return true
        }
        var raw : string
        let source = ce_direct_evaluate(call.arguments[0], builder, stmt.at, false, output, raw, error)
        if (!empty(error)) { return true }
        output |> push <| ce_direct_check(builder, source, witness, false, looped)
        if (stmt is ExprLet) { output |> push <| ce_direct_declaration(stmt, builder, source, raw) }
        state.witness = true
        return false
    }
    // A scoped resource is acquired only when this declaration is reached.
    if (binding != null && binding is ExprCall && (binding as ExprCall).name == "use_resource") {
        let call = binding as ExprCall
        if (!ce_validate_use_resource(stmt, call, error)) { return true }
        // The rest of this scope is the resource's continuation, so nothing
        // is left to lower here. In a branch that is not the block's tail the
        // continuation is a step, and control goes on after the branch.
        var rest <- ce_lower(blk, index+1, builder, false, error, false, true, nested)
        if (!empty(error)) { return true }
        let scoped = ce_lower_use_resource(stmt, call, rest, builder)
        if (tail) {
            output |> push <| qmacro_expr() { return $e(scoped) }
        } else {
            let step = ce_unique_name("__ce_step", stmt.at)
            output |> push <| qmacro_expr() { let $i(step) = $e(scoped) }
            output |> push <| ce_direct_check(builder, step, witness, true, looped)
            ce_direct_escaped(builder, witness, inherited, looped, output, state)
            state.witness = true
        }
        return true
    }
    if (stmt is ExprIfThenElse) {
        let original = stmt as ExprIfThenElse
        var branch = clone_expression(stmt)
        (branch as ExprIfThenElse).if_true = ce_direct_inline(original.if_true, builder, witness, inherited, tail && last, looped, state, error)
        if (original.if_false != null) {
            (branch as ExprIfThenElse).if_false = ce_direct_inline(original.if_false, builder, witness, inherited, tail && last, looped, state, error)
        }
        if (!empty(error)) { return true }
        output |> push <| branch
        return false
    }
    if (stmt is ExprBlock) {
        output |> push <| ce_direct_inline(stmt, builder, witness, inherited, tail && last, looped, state, error)
        if (!empty(error)) { return true }
        return false
    }
    // A loop runs its body in this scope. Control goes on after it, so nothing
    // in the body is the block's tail.
    if (stmt is ExprFor || stmt is ExprWhile) {
        let original_body = stmt is ExprFor ? (stmt as ExprFor).body : (stmt as ExprWhile).body
        var body = ce_direct_inline(original_body, builder, witness, inherited, false, true, state, error)
        if (!empty(error)) { return true }
        if (stmt is ExprWhile) {
            (stmt as ExprWhile).body = body
            output |> push <| stmt
        } else {
            output |> push <| ce_loop_stage(stmt, body, builder, false, false, true)
        }
        output |> push <| ce_direct_resume(witness, looped)
        state.loops = true
        return false
    }
    var computation : ExpressionPtr
    if (stmt is ExprCall && (stmt as ExprCall).name == "try_with") {
        computation = ce_lower_try_with(stmt as ExprCall, builder, false, false, true, error, nested)
    } elif (stmt is ExprCall && (stmt as ExprCall).name == "try_finally") {
        computation = ce_lower_try_finally(stmt as ExprCall, builder, false, false, true, error, nested)
    }
    if (!empty(error)) { return true }
    if (computation != null) {
        if (tail && last) {
            output |> push <| qmacro_expr() { return $e(computation) }
            return true
        }
        let step = ce_unique_name("__ce_step", stmt.at)
        output |> push <| qmacro_expr() { let $i(step) = $e(computation) }
        output |> push <| ce_direct_check(builder, step, witness, true, looped)
        ce_direct_escaped(builder, witness, inherited, looped, output, state)
        state.witness = true
        return false
    }
    if (!(stmt is ExprLet) && !(stmt is ExprCall) && !(stmt is ExprCallMacro)
            && !(stmt is ExprCopy) && !(stmt is ExprMove)
            && !(stmt is ExprOp1) && !(stmt is ExprOp2) && !(stmt is ExprAssert)) {
        error = "computation: unsupported statement {stmt.__rtti}"
        return true
    }
    output |> push <| stmt
    return false
}
def private ce_direct_lower(blk : ExprBlock?; start : int; builder, witness, inherited : string; top, tail, looped : bool;
                            var state : CeDirectState&; var error : string&) : array<ExpressionPtr> {
    var output : array<ExpressionPtr>
    for (index in range(start, length(blk.list))) {
        let first = length(output)
        let done = ce_direct_statement(blk, index, builder, witness, inherited, tail, looped, output, state, error)
        for (emitted in range(first, length(output))) { ce_restamp(output[emitted], blk.list[index].at) }
        if (done) { return <- output }
    }
    if (top && (empty(output) || !ce_direct_returns(output[length(output)-1]))) {
        var zero = qmacro_expr() { return ce_zero($i(builder)) }
        ce_restamp(zero, ce_scope_end(blk.at))
        output |> push <| zero
    }
    return <- output
}
def private ce_direct_inline(node : ExpressionPtr; builder, witness, inherited : string; tail, looped : bool;
                             var state : CeDirectState&; var error : string&) : ExpressionPtr {
    var source = ce_direct_block(node)
    if (!empty(source.finalList)) {
        error = "computation: use try_finally(body, cleanup) instead of a native finally on a CE scope"
    }
    var body <- ce_direct_lower(source, 0, builder, witness, inherited, false, tail, looped, state, error)
    return qmacro_block() { $b(body); }
}
def private ce_direct_scope(blk : ExprBlock?; start : int; builder : string; var error : string&;
                            inherited : string = "") : array<ExpressionPtr> {
    let witness = ce_unique_name("__ce_result", blk.at)
    var state : CeDirectState
    var output <- ce_direct_lower(blk, start, builder, witness, inherited, true, true, false, state, error)
    if (state.escapes && empty(error)) {
        var escape = qmacro_expr() { var $i(ce_direct_escape(witness)) = 0 }
        ce_restamp(escape, ce_scope_end(blk.at), true)
        output |> emplace(escape, 0)
    }
    if ((state.witness || state.loops) && empty(error)) {
        if (state.loops) {
            var flag = qmacro_expr() { var $i(ce_direct_left(witness)) = false }
            var slot = qmacro_expr() { var $i(ce_direct_outcome(witness)) : typedecl(*$i(witness)) }
            ce_restamp(flag, ce_scope_end(blk.at), true)
            ce_restamp(slot, ce_scope_end(blk.at), true)
            output |> emplace(flag, 0)
            output |> emplace(slot, 0)
        }
        var replica <- ce_direct_replica(blk, start, builder)
        var declared = qmacro_expr() {
            var $i(witness) : typedecl(invoke($ { $b(replica); }))?
        }
        ce_restamp(declared, ce_scope_end(blk.at), true)
        output |> emplace(declared, 0)
    }
    return <- output
}

// Lower every CE scope independently. Empty scopes end in Zero; only Bind and
// Combine decide whether to enter their continuation. For fallback owns its cursors.
def ce_scope(node : ExpressionPtr; builder : string; collect_mode : bool; var error : string&; owned:bool=false; direct:bool=false;
             escape:string="") : ExpressionPtr {
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
    var body <- ce_lower(source, 0, builder, collect_mode, error, owned, direct, escape)
    return qmacro_block() { $b(body); }
}

def ce_lower(blk : ExprBlock?; start : int; builder : string; collect_mode : bool;
             var error : string&; owned:bool=false; direct:bool=false; escape:string="") : array<ExpressionPtr> {
    if (direct) { return <- ce_direct_scope(blk, start, builder, error, escape) }
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
// One statement of a continuation-passing scope. True when it ends the scope:
// the rest was lowered into its continuation, or an error was reported.
def private ce_lower_statement(blk : ExprBlock?; index : int; builder : string; collect_mode : bool;
                               var output : array<ExpressionPtr>; var error : string&; owned : bool) : bool {
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
                return true
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
        return true
    }
    if (stmt is ExprReturn) {
        let ret = stmt as ExprReturn
        if (index != length(blk.list)-1 || ret.subexpr == null) {
            error = "computation: return must be the final statement of its scope and have a value"
            return true
        }
        if (ret.subexpr is ExprCall && (ret.subexpr as ExprCall).name == "return_from") {
            let call = ret.subexpr as ExprCall
            if (length(call.arguments) != 1) {
                error = "computation: expected 'return expression |> return_from'"
                return true
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
        return true
    }
    var binding : ExpressionPtr
    if (stmt is ExprLet) {
        let decl = stmt as ExprLet
        if (length(decl.variables) != 1) {
            error = "computation: declare one variable per statement"
            return true
        }
        binding = clone_expression(decl.variables[0].init)
    } elif (stmt is ExprCall) {
        binding = clone_expression(stmt)
    }
    if (binding != null && binding is ExprCall && (binding as ExprCall).name == "bind") {
        let call = binding as ExprCall
        if (length(call.arguments) != 1) {
            error = "computation: expected 'expression |> bind'"
            return true
        }
        // Explicit mutable-reference bind can consume move-only inputs even
        // when the collection's output element is copyable.
        let borrow_bind=collect_mode && stmt is ExprLet && (stmt as ExprLet).variables[0]._type.flags.ref && !(stmt as ExprLet).variables[0]._type.flags.constant
        let mutable_bind=owned || borrow_bind
        if (owned && stmt is ExprLet) {
            let variable=(stmt as ExprLet).variables[0]
            if (variable.flags.init_via_move || variable.flags.init_via_clone || variable.flags.inScope) {
                error="owned CE: bind borrows its payload; use 'var value & = source |> bind'"
                return true
            }
        }
        var rest <- ce_lower(blk, index+1, builder, collect_mode, error, owned)
        if (!empty(error)) { return true }
        var source = ce_merge_source(call.arguments[0], builder, error)
        if (!empty(error)) { return true }
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
            if (!empty(error)) { return true }
        } else {
            // What the builder unwraps from this source: from the source as
            // written, and from what its ce_source hook makes of it. Both are
            // plain calls, typed in the pass that types the source, and the
            // stage reads the one the hook selects.
            // A borrowing bind unwraps with ce_unwrap_borrow, as its
            // continuation does; the other operation may not even compile.
            let unwrap = borrow_bind && !owned ? "ce_unwrap_borrow" : "ce_unwrap"
            var probes : array<ExpressionPtr>
            probes |> push <| source
            if (source is ExprTypeInfo && (source as ExprTypeInfo).trait == "ce_resolved_source") {
                let hook = (source as ExprTypeInfo).subexpr as ExprCall
                probes |> push <| qmacro($c(unwrap)($i(builder), $e(hook.arguments[1])))
                probes |> push <| qmacro($c(unwrap)($i(builder), $e(hook)))
            } else {
                probes |> push <| qmacro($c(unwrap)($i(builder), $e(source)))
            }
            staged = ce_stage("bind", stmt.at, probes, payload)
        }
        output |> push <| qmacro_expr() { return $e(staged) }
        return true
    }
    // A scoped resource is acquired only when this declaration is reached.
    if (binding != null && binding is ExprCall && (binding as ExprCall).name == "use_resource") {
        let call = binding as ExprCall
        if (!ce_validate_use_resource(stmt, call, error)) { return true }
        var rest <- ce_lower(blk, index+1, builder, collect_mode, error, owned)
        if (!empty(error)) { return true }
        let scoped = ce_lower_use_resource(stmt, call, rest, builder)
        output |> push <| qmacro_expr() { return $e(scoped) }
        return true
    }
    var computation : ExpressionPtr
    if (stmt is ExprCall && (stmt as ExprCall).name == "try_with") {
        computation = ce_lower_try_with(stmt as ExprCall, builder, collect_mode, owned, false, error)
        if (!empty(error)) { return true }
    }
    if (stmt is ExprCall && (stmt as ExprCall).name == "try_finally") {
        computation = ce_lower_try_finally(stmt as ExprCall, builder, collect_mode, owned, false, error)
        if (!empty(error)) { return true }
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
        if (!empty(error)) { return true }
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
        return true
    }
    if (!(stmt is ExprLet) && !(stmt is ExprCall) && !(stmt is ExprCallMacro)
            && !(stmt is ExprCopy) && !(stmt is ExprMove)
            && !(stmt is ExprOp1) && !(stmt is ExprOp2) && !(stmt is ExprAssert)) {
        error = "computation: unsupported statement {stmt.__rtti}"
        return true
    }
    output |> push <| clone_expression(stmt)
    return false
}
def ce_lower_impl(blk : ExprBlock?; start : int; builder : string; collect_mode : bool;
             var error : string&; owned:bool=false) : array<ExpressionPtr> {
    var output : array<ExpressionPtr>
    for (index in range(start, length(blk.list))) {
        let first = length(output)
        let done = ce_lower_statement(blk, index, builder, collect_mode, output, error, owned)
        for (emitted in range(first, length(output))) { ce_restamp(output[emitted], blk.list[index].at) }
        if (done) { return <- output }
    }
    var zero = qmacro_expr() { return ce_zero($i(builder)) }
    ce_restamp(zero, ce_scope_end(blk.at))
    output |> push <| zero
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
        let nowhere = LineInfo()
        ce_scope_tail = nowhere
        if (expr.name=="__ce_stage") {
            if (!ce_stage_ready(expr)) { return null }
            ce_scope_tail = expr.arguments[1].at
            var stage_error : string
            var staged = ce_stage_visit(expr, stage_error)
            if (!empty(stage_error)) {
                ce_scope_tail = nowhere
                macro_error(prog, expr.arguments[0].at, stage_error)
                return null
            }
            ce_restamp(staged, expr.arguments[0].at)
            ce_scope_tail = nowhere
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
        // Where this computation ends: the closing brace of its block.
        ce_scope_tail = blk.at
        ce_scope_tail.line = blk.at.last_line
        ce_scope_tail.column = blk.at.last_column
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
                    // A source that cannot be awaited is reported at this call,
                    // so the call and the hook around the source point at it.
                    var awaited=qmacro(ce_await_source($i(name),$e(normalized)))
                    ce_restamp(awaited,source.at)
                    return awaited
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
            ce_restamp_calls(body, expr.at)
            var element = clone_type(protocol.argTypes[1])
            var builder_type = clone_type(bt)
            var run=ce_run_scope(name,qmacro(ce_sequence_run($i(name), source)),true,expr.at)
            ce_scope_tail = nowhere
            var lowered = qmacro(invoke($($i(name) : $t(builder_type)) {
                var source <- generator<$t(element)> {
                    $e(body)
                    return false
                }
                $e(run);
            }, $e(expr.arguments[0])))
            // What the block was told to capture, the generator it becomes captures:
            // this is how a [task] function moves its `var` arguments into the task.
            var holder = ((lowered as ExprInvoke).arguments[0] as ExprMakeBlock)._block as ExprBlock
            var generated = (holder.list[0] as ExprLet).variables[0].init as ExprMakeGenerator
            for (entry in (expr.arguments[2] as ExprMakeBlock)._capture) {
                let count = length(generated._capture)
                generated._capture |> resize(count + 1)
                generated._capture[count].name := entry.name
                generated._capture[count].mode = entry.mode
            }
            return lowered
        }
        let owned=ce_is_protocol(protocol,"CeOwnedProtocol")
        let collect_mode = ce_is_protocol(protocol, "CeCollectProtocol") || owned
        let direct = ce_is_protocol(protocol, "CeDirectProtocol")
        if (!collect_mode && !direct && !ce_is_protocol(protocol, "CeValueProtocol")) {
            macro_error(prog, expr.at, "computation: ce_protocol must return a builder_protocol descriptor; builder {describe(bt)} returned {describe(protocol)}; expected CeValueProtocol, CeDirectProtocol, CeCollectProtocol, CeOwnedProtocol, ce_sequence_protocol(type<T>) or ce_resumable_protocol(type<Event>)")
            return null
        }
        var error : string
        var body <- ce_lower(blk, 0, name, collect_mode, error, owned, direct)
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
        ce_restamp(result, ce_scope_end(expr.at), true)
        result.at = expr.at
        ce_scope_tail = nowhere
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
        } elif (ce_is_match_statement(stmt)) {
            var matched=clone_expression(stmt)
            let arms=ce_match_arms(matched,error)
            if(!empty(error)) {return blk}
            for(arm in (arms as ExprBlock).list) {
                var branch=arm as ExprIfThenElse
                branch.if_true=ce_sequence_scope(branch.if_true,0,element,share,error,builder)
                if(!empty(error)) {return blk}
            }
            output |> push <| matched
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
    def override preVisitExprIfThenElse(expr:ExprIfThenElse?) {
        self.save()
        if(ce_match_binds(expr.cond,original)) {hidden=true}
    }
    def override visitExprIfThenElse(var expr:ExprIfThenElse?) : ExpressionPtr {self.restore();return expr}
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














