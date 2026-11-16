options gen2
module resumable_lowering public
require daslib/ast_boost
require daslib/templates_boost
require strings

//! Macro internals: the lowering of a resumable computation, such as a task or an asynchronous sequence,
//! into a generator of the builder's events, and helpers that the lowering modules share.
//! ``computation_macro`` requires it; there is nothing here for a user of the library to call.

// A source position does not identify a generated name: nested pipes share one
// position, and one lowered statement can nest inside another built from it.
// The serial follows expansion order, so names stay stable between compiles.
var private ce_unique_serial : int = 0
def ce_unique_name(prefix : string; at : LineInfo) : string {
    ce_unique_serial++
    return "{make_unique_private_name(prefix, at)}_{ce_unique_serial}"
}

// Add copies of the statements of `blk` from `start` on: what follows a
// statement in its block, or the whole of a lowered block.
def ce_append_clones(var into : array<ExpressionPtr>; blk : ExprBlock?; start : int = 0) {
    into |> reserve(length(into) + length(blk.list) - start)
    for (i in range(start, length(blk.list))) { into |> push <| clone_expression(blk.list[i]) }
}

[macro_interface]
class CeMatchBindingFinder : AstVisitor {
    name:string
    found:bool
    def override preVisitExprTag(expr:ExprTag?) {
        if(expr.name=="v" && expr.subexpr is ExprVar
            && (expr.subexpr as ExprVar).name==name) {found=true}
    }
}

// A $v(name) pattern is a lexical binding for its guard and arm body, not a
// reference to an outer CE local. Keep it intact during both ownership passes.
def ce_match_binds(pattern:ExpressionPtr; name:string) : bool {
    var finder=new CeMatchBindingFinder(name=name)
    make_visitor(*finder) $(adapter) {visit(pattern,adapter)}
    let found=finder.found
    unsafe {delete finder}
    return found
}

// Native AOT generator fields must have unique names even for locals declared
// in different lexical loops. Respect shadowing when rewriting their tail.
[macro_interface]
class CeTaskLocalRename : AstVisitor {
    original:string
    replacement:string
    replacementValue:ExpressionPtr
    hidden:bool
    scopes:array<bool>
    def save() {scopes |> push(hidden)}
    def restore() {hidden=scopes[length(scopes)-1];scopes |> pop()}
    def override preVisitExprBlock(blk:ExprBlock?) {
        self.save()
        for(arg in blk.arguments) {if(arg.name==original) {hidden=true}}
    }
    def override visitExprBlock(var blk:ExprBlock?) : ExpressionPtr {self.restore();return blk}
    def override preVisitExprIfThenElse(expr:ExprIfThenElse?) {
        self.save()
        if(ce_match_binds(expr.cond,original)) {hidden=true}
    }
    def override visitExprIfThenElse(var expr:ExprIfThenElse?) : ExpressionPtr {self.restore();return expr}
    def override visitExprLetVariable(expr:ExprLet?;var arg:VariablePtr;lastArg:bool) : VariablePtr {
        if(arg.name==original) {hidden=true}
        return arg
    }
    def override preVisitExprFor(expr:ExprFor?) {self.save()}
    def override preVisitExprForStack(expr:ExprFor?) {
        for(name in expr.iterators) {if(name==original) {hidden=true}}
    }
    def override visitExprFor(var expr:ExprFor?) : ExpressionPtr {self.restore();return expr}
    def override visitExprVar(var expr:ExprVar?) : ExpressionPtr {
        if(!hidden && expr.name==original) {
            if(replacementValue!=null) {
                var replaced=clone_expression(replacementValue);replaced.at=expr.at;return replaced
            }
            var renamed=qmacro($i(replacement));renamed.at=expr.at;return renamed
        }
        return expr
    }
}
def private ce_task_rename_tail(body:ExpressionPtr;original,replacement:string) : ExpressionPtr {
    var visitor=new CeTaskLocalRename(original=original,replacement=replacement)
    var result:ExpressionPtr
    make_visitor(*visitor) $(adapter) {result=visit(body,adapter)}
    unsafe {delete visitor}
    return result
}

def private ce_task_replace_tail(body:ExpressionPtr;original:string;value:ExpressionPtr) : ExpressionPtr {
    var visitor=new CeTaskLocalRename(original=original,replacementValue=clone_expression(value))
    var result:ExpressionPtr
    make_visitor(*visitor) $(adapter) {result=visit(body,adapter)}
    unsafe {delete visitor}
    return result
}

def private ce_task_wrap_loop(loop:ExpressionPtr;control:string) : ExpressionPtr {
    var outer=qmacro_expr() {for($i(control) in ce_task_loop_scope()) {}}
    outer.at=loop.at
    outer.at.column++
    var body=qmacro_block() {} as ExprBlock
    body.at=outer.at
    body.list |> push <| clone_expression(loop)
    (outer as ExprFor).body=body
    return outer
}

[typeinfo_macro(name="ce_has_resumable_zero")]
class CeHasResumableZero : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?; var errors:das_string) : ExpressionPtr {
        if(expr.subexpr==null || expr.subexpr._type==null) {return null}
        let t=expr.subexpr._type
        return <- new ExprConstBool(at=expr.at,value=!(t.baseType==Type.tStructure && t.structType.name=="CeResumableNoZero" && t.structType._module.name=="builder_protocol"))
    }
}

[typeinfo_macro(name="ce_has_resumable_for")]
class CeHasResumableFor : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?; var errors:das_string) : ExpressionPtr {
        if(expr.subexpr==null || expr.subexpr._type==null || expr.subexpr._type.isAutoOrAlias) {return null}
        let t=expr.subexpr._type
        return <- new ExprConstBool(at=expr.at,value=!(t.baseType==Type.tStructure && t.structType.name=="CeResumableForFallback" && t.structType._module.name=="builder_protocol"))
    }
}

def private ce_resumable_owns_type(t:TypeDeclPtr) : bool {
    if(t==null || t.flags.ref || t.baseType==Type.tPointer || t.baseType==Type.tBlock
        || t.baseType==Type.tLambda || t.baseType==Type.tIterator || t.baseType==Type.tHandle) {return false}
    if(t.baseType==Type.tStructure) {
        for(field in t.structType.fields) {if(!ce_resumable_owns_type(field._type)) {return false}}
    } elif(t.baseType==Type.tTuple || t.baseType==Type.tVariant) {
        for(field in t.argTypes) {if(!ce_resumable_owns_type(field)) {return false}}
    } elif(t.baseType==Type.tArray) {return ce_resumable_owns_type(t.firstType)}
    elif(t.baseType==Type.tTable) {return ce_resumable_owns_type(t.firstType) && ce_resumable_owns_type(t.secondType)}
    return true
}

[typeinfo_macro(name="ce_resumable_payload")]
class ResumablePayload : AstTypeInfoMacro {
    def override getAstChange(expr:ExprTypeInfo?; var errors:das_string) : ExpressionPtr {
        if(expr.subexpr==null || expr.subexpr._type==null || expr.subexpr._type.isAutoOrAlias) {return null}
        if(!ce_resumable_owns_type(expr.subexpr._type)) {
            errors:="task: payload must own its data; pointers, references, executable captures and iterators are unsupported"
            return null
        }
        return <- new ExprConstBool(at=expr.at,value=true)
    }
}

// Keep pattern matching in daslib: only arm bodies are CE scopes. Expanding
// match here would require inferred subject types and duplicate pattern rules.
def ce_is_match_statement(node:ExpressionPtr) : bool {
    if(!(node is ExprCallMacro)) {return false}
    let name=string((node as ExprCallMacro).name)
    return name=="match" || name=="match::match"
}

def ce_match_arms(node:ExpressionPtr; var error:string&) : ExpressionPtr {
    let call=node as ExprCallMacro
    if(length(call.arguments)!=2 || !(call.arguments[1] is ExprMakeBlock)) {
        error="computation: match expects a subject and an immediate arm block"
        return null
    }
    var arms=(call.arguments[1] as ExprMakeBlock)._block as ExprBlock
    if(!empty(arms.arguments) || !empty(arms.finalList)) {
        error="computation: match arm block cannot have arguments or native finally"
        return null
    }
    for(arm in arms.list) {
        if(!(arm is ExprIfThenElse) || (arm as ExprIfThenElse).if_false!=null) {
            error="computation: match expects pattern arms without else"
            return null
        }
    }
    return arms
}

// A resumable builder supplies events, await adapters and return conversion.
// The sequence lowering subsequently adds protected source/resource ownership.
def ce_resumable_scope(node:ExpressionPtr; builder:string; var error:string&;   // nolint:STYLE037,STYLE038 - one arm per statement kind of a resumable scope
    await_source:block<(source:ExpressionPtr;isAwait:bool):ExpressionPtr>; control:string="") : ExpressionPtr {
    if (node==null) {return qmacro_block() {}}
    var blk=qmacro_block() {} as ExprBlock
    if (node is ExprBlock) {blk=clone_expression(node) as ExprBlock}
    else {blk.list |> push <| clone_expression(node)}
    if(!empty(blk.finalList)) {error="task: native finally is unsupported; use try_finally";return blk}
    var output:array<ExpressionPtr>
    var index=0
    while(index<length(blk.list)) {
        var stmt=clone_expression(blk.list[index])
        if(stmt is ExprLet && length((stmt as ExprLet).variables)==1) {
            var local=(stmt as ExprLet).variables[0]
            let original=string(local.name)
            if(!starts_with(original,"__task_local_")) {
                let replacement=ce_unique_name("__task_local_{original}",stmt.at)
                local.name := replacement
                if(index+1<length(blk.list)) {
                    var tail:array<ExpressionPtr>
                    ce_append_clones(tail,blk,index+1)
                    let renamed=ce_task_rename_tail(qmacro_block() {$b(tail);},original,replacement)
                    blk.list.resize(index+1)
                    blk.list |> push <| renamed
                }
            }
        }
        var binding:ExpressionPtr
        if(stmt is ExprLet && length((stmt as ExprLet).variables)==1) {binding=(stmt as ExprLet).variables[0].init}
        elif(stmt is ExprCall) {binding=stmt}
        if(stmt is ExprLet && binding!=null) {
            var decl=stmt as ExprLet
            var local=decl.variables[0]
            if(local.flags.inScope || decl.letFlags.inScope || local.flags.init_via_move || local.flags.init_via_clone) {
                local.flags.inScope=false;decl.letFlags.inScope=false
                local.flags.init_via_move=false;local.flags.init_via_clone=false
                local._type.flags.ref=true
                local.init=qmacro(use_task_local($e(binding)))
                binding=local.init
            }
        }
        if(binding!=null && binding is ExprCall && (binding as ExprCall).name=="bind") {
            let call=binding as ExprCall
            if(length(call.arguments)!=1) {error="task: expected source |> bind";return blk}
            let source=invoke(await_source,call.arguments[0],true)
            if(!empty(error)) {return blk}
            let event=ce_unique_name("__await_event",stmt.at)
            var tail:array<ExpressionPtr>
            if(stmt is ExprLet) {
                var declaration=clone_expression(stmt) as ExprLet
                if(declaration.variables[0]._type.flags.ref) {
                    declaration.variables[0].init=qmacro(ce_await_borrow_value($i(builder),$i(event)))
                } else {declaration.variables[0].init=qmacro(ce_await_value($i(builder),$i(event)))}
                declaration.variables[0].init.at=stmt.at
                tail |> push <| declaration
            }
            ce_append_clones(tail,blk,index+1)
            let rest=ce_resumable_scope(qmacro_block() {$b(tail);},builder,error,await_source,control)
            var loop=qmacro_expr() {
                for($i(event) in $e(source)) {
                    if(!$i(event).ready) {yield <- ce_await_pending($i(builder))}
                    elif(ce_await_failed($i(builder),$i(event))) {yield <- ce_await_failure($i(builder),$i(event))}
                    else {$e(rest)}
                }
            }
            loop.at=stmt.at
            (loop as ExprFor).body.at=stmt.at
            // qmacro stamped the awaited source with this file's position.
            (loop as ExprFor).sources[0].at=call.arguments[0].at
            output |> push <| loop
            return qmacro_block() {$b(output);}
        }
        if(stmt is ExprReturn) {
            let ret=stmt as ExprReturn
            if(ret.subexpr!=null && ret.subexpr is ExprCall && (ret.subexpr as ExprCall).name=="return_from") {
                let source=ret.subexpr as ExprCall
                if(length(source.arguments)!=1) {error="task: expected 'return source |> return_from'";return blk}
                let name=ce_unique_name("__await_return_from",stmt.at)
                let forwarded=qmacro_block() {
                    var $i(name) & = $e(source.arguments[0]) |> bind
                    return <- $i(name)
                }
                let lowered=ce_resumable_scope(forwarded,builder,error,await_source,control) as ExprBlock
                for(entry in lowered.list) {output |> push <| clone_expression(entry)}
            } elif(ret.subexpr==null) {
                output |> push <| qmacro_expr() {yield <- ce_await_return($i(builder),CeUnit())}
            } else {
                var returned=qmacro_expr() {yield <- ce_await_return($i(builder),$e(ret.subexpr))}
                if(ret.returnFlags.moveSemantics) {
                    returned=qmacro_expr() {yield <- ce_await_return_move($i(builder),$e(ret.subexpr))}
                }
                // qmacro stamped the returned value with this file's position.
                ((returned as ExprYield).subexpr as ExprCall).arguments[1].at=ret.subexpr.at
                output |> push <| returned
            }
        } elif(ce_is_match_statement(stmt)) {
            let arms=ce_match_arms(stmt,error)
            if(!empty(error)) {return blk}
            for(arm in (arms as ExprBlock).list) {
                var branch=arm as ExprIfThenElse
                branch.if_true=ce_resumable_scope(branch.if_true,builder,error,await_source,control)
                if(!empty(error)) {return blk}
            }
            output |> push <| stmt
        } elif(stmt is ExprIfThenElse) {
            var branch=stmt as ExprIfThenElse
            branch.if_true=ce_resumable_scope(branch.if_true,builder,error,await_source,control)
            branch.if_false=ce_resumable_scope(branch.if_false,builder,error,await_source,control)
            output |> push <| branch
        } elif(stmt is ExprFor) {
            var loop=stmt as ExprFor
            let nested=ce_unique_name("__task_for_control",stmt.at)
            let body=ce_resumable_scope(loop.body,builder,error,await_source,nested)
            loop.body=qmacro_block() {ce_task_loop_signal($i(nested),0);$e(body)}
            let originals <- [for(source in loop.sources); invoke(await_source,clone_expression(source),false)]
            for(source in loop.sources) {
                let original=invoke(await_source,clone_expression(source),false)
                source=qmacro(invoke($ {
                    static_if((typeinfo can_copy($e(original))) || (typeinfo ce_source_is_borrowed($e(original)))) {
                        return <- ce_task_loop_source($e(original),$i(nested))
                    } else {return <- ce_task_loop_source_owned($e(original),$i(nested))}
                }))
            }
            if(!empty(originals)) {
                let event=ce_unique_name("__await_for_event",stmt.at)
                let arity=length(originals)
                var input=clone_expression(originals[0])
                var probe=clone_expression(originals[0])
                var anyAsync=qmacro(false)
                var setup:array<ExpressionPtr>
                for(i in range(arity)) {
                    let original=originals[i]
                    anyAsync=qmacro($e(anyAsync) || (typeinfo ce_has_resumable_for(ce_await_for_source($i(builder),$e(original),$i(nested)))))
                    if(arity>1) {
                        let source=ce_unique_name("__await_for_source_{i}",stmt.at)
                        var declaration=qmacro_expr() {var $i(source) & = use_task_local($e(original))}
                        declaration.at=stmt.at
                        declaration.at.column+=uint(2+arity+i)
                        (declaration as ExprLet).variables[0].init.at=declaration.at
                        setup |> push <| declaration
                        if(i==0) {input=qmacro($i(source))}
                        else {
                            input=qmacro(ce_await_for_merge($i(builder),$e(input),$i(source)))
                            probe=qmacro(ce_await_for_merge($i(builder),$e(probe),$e(original)))
                        }
                    }
                }
                let row=arity==1 ? string(loop.iterators[0]) : ce_unique_name("__await_for_row",stmt.at)
                var iteration=clone_expression(body)
                if(arity>1) {
                    for(i in range(arity)) {
                        var value=qmacro($i(row))
                        var level=arity-1
                        while(level>0) {
                            if(i==level) {value=qmacro($e(value).second);break}
                            value=qmacro($e(value).first)
                            level--
                        }
                        iteration=ce_task_replace_tail(iteration,string(loop.iterators[i]),value)
                    }
                }
                var asynchronous=qmacro_expr() {
                    for($i(event) in ce_await_for_source($i(builder),$e(input),$i(nested))) {
                        if(!$i(event).ready) {yield <- ce_await_pending($i(builder))}
                        else {
                            ce_task_loop_signal($i(nested),0)
                            $e(iteration)
                        }
                    }
                }
                asynchronous.at=stmt.at
                (asynchronous as ExprFor).body.at=stmt.at
                var ready=(((asynchronous as ExprFor).body as ExprBlock).list[0] as ExprIfThenElse).if_false as ExprBlock
                var owned=qmacro_expr() {var $i(row) & = use_task_local(ce_await_for_value($i(builder),$i(event)))}
                owned.at=stmt.at
                owned.at.column+=2
                (owned as ExprLet).variables[0].init.at=owned.at
                ready.list |> emplace(owned,1)
                var selected=qmacro_expr() {
                    static_if(typeinfo ce_has_resumable_for(ce_await_for_source($i(builder),$e(probe),$i(nested)))) {
                    } else {}
                }
                // Interpolation rewrites a loop's source coordinates to the
                // macro line. Preserve them: native generator fields use them
                // as identities, including for nested asynchronous loops.
                for(declaration in setup) {((selected as ExprIfThenElse).if_true as ExprBlock).list |> push <| clone_expression(declaration)}
                ((selected as ExprIfThenElse).if_true as ExprBlock).list |> push <| asynchronous
                var native=qmacro_expr() {
                    static_if($e(anyAsync)) {
                        ce_await_for_incompatible($i(builder))
                    } else {}
                }
                ((native as ExprIfThenElse).if_true as ExprBlock).list[0].at=stmt.at
                ((native as ExprIfThenElse).if_false as ExprBlock).list |> push <| clone_expression(loop)
                ((selected as ExprIfThenElse).if_false as ExprBlock).list |> push <| native
                selected.at=stmt.at
                output |> push <| ce_task_wrap_loop(selected,nested)
            } else {output |> push <| ce_task_wrap_loop(loop,nested)}
        } elif(stmt is ExprWhile) {
            var loop=stmt as ExprWhile
            let nested=ce_unique_name("__task_while_control",stmt.at)
            let body=ce_resumable_scope(loop.body,builder,error,await_source,nested)
            loop.body=qmacro_block() {ce_task_loop_signal($i(nested),0);$e(body)}
            loop.cond=qmacro(ce_task_loop_not_broken($i(nested)) && $e(loop.cond))
            output |> push <| ce_task_wrap_loop(loop,nested)
        } elif(stmt is ExprBlock) {
            output |> push <| ce_resumable_scope(stmt,builder,error,await_source,control)
        } elif(stmt is ExprCall && (stmt as ExprCall).name=="try_finally") {
            var call=stmt as ExprCall
            // The body is another CE scope; cleanup is ordinary code.
            for(i in range(length(call.arguments))) {
                if(i==1) {continue}
                if(call.arguments[i] is ExprMakeBlock) {
                    var mb=call.arguments[i] as ExprMakeBlock
                    var original=mb._block as ExprBlock
                    var lowered=ce_resumable_scope(mb._block,builder,error,await_source,control) as ExprBlock
                    original.list |> clear()
                    for(entry in lowered.list) {original.list |> push <| clone_expression(entry)}
                }
            }
            output |> push <| call
        } elif(stmt is ExprBreak || stmt is ExprContinue) {
            if(empty(control)) {error="task: break/continue requires a surrounding CE loop";return blk}
            let signal=stmt is ExprBreak ? 1 : 2
            output |> push <| qmacro(ce_task_loop_signal($i(control),$v(signal)))
            return qmacro_block() {$b(output);}
        } elif(stmt is ExprCall && (stmt as ExprCall).name=="yield_from") {
            let call=stmt as ExprCall
            if(length(call.arguments)!=1) {error="async sequence: expected source |> yield_from";return blk}
            let event=ce_unique_name("__await_yield_from",stmt.at)
            var loop=qmacro_expr() {
                for($i(event) in ce_await_yield_from($i(builder),$e(call.arguments[0]))) {
                    yield <- $i(event)
                }
            }
            loop.at=stmt.at
            (loop as ExprFor).body.at=stmt.at
            output |> push <| loop
        } elif(stmt is ExprYield) {
            let item=stmt as ExprYield
            var emitted:ExpressionPtr
            if(item.returnFlags.moveSemantics) {
                emitted=qmacro_expr() {yield <- ce_await_yield_move($i(builder),$e(item.subexpr))}
            } else {emitted=qmacro_expr() {yield <- ce_await_yield($i(builder),$e(item.subexpr))}}
            emitted.at=stmt.at
            (emitted as ExprYield).subexpr.at=stmt.at
            output |> push <| emitted
        } else {output |> push <| stmt}
        // A structured statement may have signalled break/continue in a nested
        // await/resource generator. Keep lexical declarations in the same scope
        // and guard the whole remaining continuation, including source factories.
        if(!empty(control) && index+1<length(blk.list) && (ce_is_match_statement(stmt) || stmt is ExprIfThenElse || stmt is ExprBlock || stmt is ExprFor || stmt is ExprWhile
            || (stmt is ExprCall && (stmt as ExprCall).name=="try_finally"))) {
            var tail:array<ExpressionPtr>
            ce_append_clones(tail,blk,index+1)
            let rest=ce_resumable_scope(qmacro_block() {$b(tail);},builder,error,await_source,control)
            output |> push <| qmacro_expr() {if(ce_task_loop_active($i(control))) {$e(rest)}}
            return qmacro_block() {$b(output);}
        }
        index++
    }
    return qmacro_block() {$b(output);}
}
