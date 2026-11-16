options gen2
module deferred_computation public
require ./computation_macro.das public
require ./resumable_lowering.das
require ./deferred_runtime.das public
require daslib/ast
require daslib/ast_boost
require daslib/templates_boost

// Snapshots must not retain borrowed pointers or escaping executable captures.
def private ce_snapshot_safe(t:TypeDeclPtr) : bool {
    if (t==null || t.baseType==Type.tPointer || t.baseType==Type.tBlock || t.baseType==Type.tLambda
        || t.baseType==Type.tIterator || t.baseType==Type.tHandle) { return false }
    if (t.baseType==Type.tStructure) {
        for (field in t.structType.fields) { if (!ce_snapshot_safe(field._type)) { return false } }
    } elif (t.baseType==Type.tTuple || t.baseType==Type.tVariant) {
        for (field in t.argTypes) { if (!ce_snapshot_safe(field)) { return false } }
    } elif (t.baseType==Type.tArray) { return ce_snapshot_safe(t.firstType) }
    elif (t.baseType==Type.tTable) { return ce_snapshot_safe(t.firstType) && ce_snapshot_safe(t.secondType) }
    return true
}

// A builder may be a phantom descriptor: a marker structure named `kind`, then
// null pointers that only carry types, as in (kind=MoveListContext(), element=null).
// Such a descriptor owns nothing, so its pointers are allowed in a snapshot.
// Snapshot data and payload fields continue to use the ordinary recursive check.
def private ce_phantom_descriptor(t:TypeDeclPtr) : bool {
    if (t.baseType!=Type.tTuple || length(t.argTypes)<2 || length(t.argNames)!=length(t.argTypes) || t.argNames[0]!="kind") {return false}
    let tag=t.argTypes[0]
    if (tag.baseType!=Type.tStructure || length(tag.structType.fields)!=1 || tag.structType.fields[0].name!="_ce_marker") {return false}
    for (index in range(1,length(t.argTypes))) {
        if (t.argTypes[index].baseType!=Type.tPointer || !ce_snapshot_safe(t.argTypes[index].firstType)) {return false}
    }
    return true
}
def private ce_move_descriptor(t:TypeDeclPtr; moduleName,kind:string) : bool {
    if (t.baseType!=Type.tTuple || length(t.argTypes)!=2 || length(t.argNames)!=2) {return false}
    let tag=t.argTypes[0]
    return (t.argNames[0]=="kind" && t.argNames[1]=="element"
        && tag.baseType==Type.tStructure && tag.structType.name==kind && tag.structType._module.name==moduleName
        && t.argTypes[1].baseType==Type.tPointer && ce_snapshot_safe(t.argTypes[1].firstType))
}

[typeinfo_macro(name="ce_deferred_move_sequence_result")]
class DeferredMoveSequenceResult : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?; var errors:das_string) : ExpressionPtr {
        if (expr.subexpr==null || expr.subexpr._type==null || expr.subexpr._type.isAutoOrAlias) {return null}
        let t=expr.subexpr._type
        if (t.baseType!=Type.tIterator || t.flags.ref || !t.firstType.flags.ref || !ce_snapshot_safe(t.firstType)) {
            errors := "deferred: move-only Sequence must return its owning-slot reference iterator with an owning payload"
            return null
        }
        return <- new ExprConstBool(at=expr.at,value=true)
    }
}

[typeinfo_macro(name="ce_deferred_result")]
class DeferredResult : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?; var errors:das_string) : ExpressionPtr {
        if (expr.subexpr==null || expr.subexpr._type==null || expr.subexpr._type.isAutoOrAlias) { return null }
        // The expression is ce_deferred_payload(result). A result that wraps
        // its payload answers with a null pointer to the payload's type; any
        // other result is checked as it is.
        let hooked=expr.subexpr is ExprCall && length((expr.subexpr as ExprCall).arguments)==1
        if (hooked && !ce_is_protocol(expr.subexpr._type,"CeDeferredPayloadFallback")) {
            let payload=expr.subexpr._type
            if (payload.baseType!=Type.tPointer || payload.firstType==null || !ce_snapshot_safe(payload.firstType)) {
                errors:="deferred: a result must own its payload; references, pointers and iterators cannot escape a run snapshot"
                return null
            }
            return <- new ExprConstBool(at=expr.at,value=true)
        }
        let result=hooked ? (expr.subexpr as ExprCall).arguments[0]._type : expr.subexpr._type
        if (result==null || result.isAutoOrAlias) { return null }
        if (result.baseType==Type.tIterator && !result.flags.ref) {
            if (result.firstType.flags.ref || !ce_snapshot_safe(result.firstType)) {
                errors := "deferred: iterator elements must own their data; references, pointers and nested iterators cannot escape a run snapshot"
                return null
            }
        } elif (result.flags.ref || !ce_snapshot_safe(result)) {
            errors := "deferred: result must be a value, owned collection or owning iterator; borrowed references and pointers cannot escape a run snapshot"
            return null
        }
        return <- new ExprConstBool(at=expr.at,value=true)
    }
}

[call_macro(name="deferred")]
class DeferredMacro : AstCallMacro {
    def override canVisitArgument(expr:ExprCallMacro?; index:int) : bool =>
        index<length(expr.arguments)-1
    def override canFoldReturnResult(expr:ExprCallMacro?) : bool => false
    def override visit(prog:ProgramPtr; mod:Module?; var expr:ExprCallMacro?) : ExpressionPtr {   // nolint:STYLE037,STYLE038 - the macro's entry: validation, then one arm per kind of result
        let count=length(expr.arguments)
        if ((count!=2 && count!=3) || !(expr.arguments[count-1] is ExprMakeBlock)) {
            macro_error(prog,expr.at,"deferred: expected builder, optional snapshot, and a trailing CE block")
            return null
        }
        let blk=(expr.arguments[count-1] as ExprMakeBlock)._block as ExprBlock
        if (!empty(blk.finalList) || length(blk.arguments) > (count==3 ? 1 : 0)) {
            macro_error(prog,expr.at,"deferred: snapshot block takes at most one argument and no native finally")
            return null
        }
        if (!empty(blk.arguments) && !blk.arguments[0]._type.isAutoOrAlias) {
            macro_error(prog,expr.at,"deferred: use an untyped snapshot argument; its type is inferred from the supplied data")
            return null
        }
        var data=count==3 ? clone_expression(expr.arguments[1]) : qmacro(CeUnit())
        let bt=expr.arguments[0]._type
        if (bt==null || (count==3 && expr.arguments[1]._type==null)) { return null }
        var et=count==3 ? clone_type(expr.arguments[1]._type) : qmacro_type(type<CeUnit>)
        if (bt.isAutoOrAlias || et.isAutoOrAlias) { return null }
        let moveList=ce_move_descriptor(bt,"list_builder","MoveListContext")
        let moveSequence=ce_move_descriptor(bt,"sequence_builder","MoveSequenceContext")
        // Any other phantom descriptor builds a result that is moved, never
        // copied: a task, an asynchronous sequence, a builder of one's own.
        let phantom=ce_phantom_descriptor(bt)
        let moved=phantom && !moveList && !moveSequence
        if ((!ce_snapshot_safe(bt) && !phantom) || !ce_snapshot_safe(et)) {
            macro_error(prog,expr.at,"deferred: builder and snapshot must own their data; pointers, blocks, lambdas, iterators and native handles are unsupported")
            return null
        }
        var builderType=clone_type(bt)
        builderType.flags.ref=false; builderType.flags.constant=false
        et.flags.ref=false; et.flags.constant=false
        let en=empty(blk.arguments) ? ce_unique_name("__deferred_data",expr.at) : string(blk.arguments[0].name)
        var raw=clone_expression(expr.arguments[count-1])
        ((raw as ExprMakeBlock)._block as ExprBlock).arguments |> clear()
        let frame=ce_unique_name("__deferred_frame",expr.at)
        raw=ce_sequence_replace_local(raw,en,frame)
        var inner=new ExprCallMacro(at=expr.at,name:="computation",macro=find_call_macro(find_module(prog,"computation_macro"),"computation"))
        inner.arguments |> push <| qmacro($i(frame).builder)
        inner.arguments |> push <| raw
        var callback=qmacro(@@($i(frame):tuple<marker:int;builder:$t(builderType);value:$t(et)>?) {
            static_assert(typeinfo ce_deferred_result(ce_deferred_payload($e(inner))))
            static_if (typeinfo can_copy($e(inner))) { return $e(inner) }
            else { return <- $e(inner) }
        })
        if (moveSequence) {
            let payload=bt.argTypes[1].firstType
            callback=qmacro(@@($i(frame):tuple<marker:int;builder:$t(builderType);value:$t(et)>?) : iterator<$t(payload)&> {
                static_assert(typeinfo ce_deferred_move_sequence_result($e(inner)))
                return <- $e(inner)
            })
        }
        if(moved) {
            let result=ce_unique_name("__deferred_task",expr.at)
            callback=qmacro(@@($i(frame):tuple<marker:int;builder:$t(builderType);value:$t(et)>?) {
                var $i(result) <- $e(inner)
                static_assert(typeinfo ce_deferred_result(ce_deferred_payload($i(result))))
                return <- $i(result)
            })
        }
        let bsource=ce_unique_name("__deferred_source_builder",expr.at)
        let esource=ce_unique_name("__deferred_source_data",expr.at)
        var make=qmacro($($i(esource):$t(et)) { return <- ce_deferred_create($i(bsource),$i(esource),$e(callback),CeDeferredValueBuilder()) })
        if (moveList || moveSequence) {
            make=qmacro($($i(esource):$t(et)) { return <- ce_deferred_create($i(bsource),$i(esource),$e(callback),CeDeferredTypeBuilder()) })
        }
        if(moved) {make=qmacro($($i(esource):$t(et)) {return <- ce_deferred_create($i(bsource),$i(esource),$e(callback),CeDeferredMovedBuilder())})}
        var dataScope=ce_source_apply(data,make,true)
        // Borrow saved const builders while copying them into the owned frame.
        var builderInputType=clone_type(builderType)
        builderInputType.flags.constant=true
        var withBuilder=qmacro($($i(bsource):$t(builderInputType)) { return <- $e(dataScope) })
        if (phantom) {
            // Every pointer of a phantom descriptor only carries a type.
            var marked=qmacro($i(bsource).$f(string(bt.argNames[1]))!=null)
            for (index in range(2,length(bt.argNames))) {
                marked=qmacro($e(marked) || $i(bsource).$f(string(bt.argNames[index]))!=null)
            }
            withBuilder=qmacro($($i(bsource):$t(builderInputType)) {
                if ($e(marked)) {panic("deferred: move-only builder type marker must be null")}
                return <- $e(dataScope)
            })
        }
        return ce_source_apply(expr.arguments[0],withBuilder,true)
    }
}
