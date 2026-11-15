options gen2
module task_function public
require ./computation_macro.das public
require daslib/ast
require daslib/ast_boost
require daslib/templates_boost

// Function-level sugar for the Task builders, after daslib's [async].
//
//     [task]
//     def load_level(id : int) : int {
//         let chunk = read_chunk(id) |> bind
//         return chunk * 2
//     }
//
// is the same function as
//
//     def load_level(id : int) : Task<int> {
//         return <- computation(TaskBuilder(type<int>)) {
//             let chunk = read_chunk(id) |> bind
//             return chunk * 2
//         }
//     }
//
// The declared result is the value the task produces, not the task itself.
// [task_result] uses TaskResultBuilder, so `: int` there declares a function
// that returns Task<Result<int;string>>.
//
// The body is rewritten when the function is parsed, before any type is known.
// The names Task, Result and the builders are therefore looked up later, in the
// module that declares the function; task_builder.das brings them along.

[macro_interface]
class CeLastLine : AstVisitor {
    line : uint = 0u
    def override preVisitExpression(expr : ExpressionPtr) : void {
        let ending = expr.at.last_line > expr.at.line ? expr.at.last_line : expr.at.line
        if (ending > line) { line = ending }
    }
}

// `Name<first>` or `Name<first;second>`, as the parser builds it.
def private ce_template_type(name : string; at : LineInfo; var first : TypeDeclPtr; var second : TypeDeclPtr = null) : TypeDeclPtr {
    var result = new TypeDecl(baseType=Type.typeMacro, at=at)
    result.typeMacroExpr |> push <| new ExprConstString(at=at, value:=name)
    result.typeMacroExpr |> push <| new ExprTypeDecl(at=at, typeexpr=first)
    if (second != null) {
        result.typeMacroExpr |> push <| new ExprTypeDecl(at=at, typeexpr=second)
    }
    return result
}

// What an annotated function returns, and what its declared result means.
enum CeFunctionKind {
    Task                // the task's value: the function returns Task<T>
    TaskResult          // the successful value: Task<Result<T;string>>
    Sequence            // one element: iterator<T>
    AsyncSequence       // one element; the stream's type has no name, it is inferred
    Coroutine           // nothing: a coroutine produces no values
}

// Turn the body of `func` into `return <- computation(builder(...)) { body }`.
// sequence_function.das uses it for the builders that produce a stream.
def ce_function_computation(var func : FunctionPtr; annotation, builder : string; kind : CeFunctionKind;
                            var errors : das_string) : bool {
    let task = kind == CeFunctionKind.Task || kind == CeFunctionKind.TaskResult
    let owner = task ? "task" : (kind == CeFunctionKind.Coroutine ? "coroutine" : "sequence")
    let untyped = func.result == null || func.result.baseType == Type.autoinfer || func.result.baseType == Type.tVoid
    if (kind == CeFunctionKind.Coroutine) {
        if (!untyped) {
            errors := "[{annotation}] produces no value: declare def {func.name}(...) without a result"
            return false
        }
    } elif (untyped) {
        let meaning = task ? "the task value" : "one element"
        errors := "[{annotation}] needs the type of {meaning} as the declared result: def {func.name}(...) : T"
        return false
    }
    var body = func.body as ExprBlock
    if (body == null) {
        errors := "[{annotation}] needs a function with a body"
        return false
    }
    if (!empty(body.finalList)) {
        errors := "[{annotation}]: a {owner} body has no native finally; use try_finally(body, cleanup)"
        return false
    }
    var library = find_module(compiling_program(), "computation_macro")
    if (library == null) {
        errors := "[{annotation}]: module computation_macro is not loaded"
        return false
    }
    let at = func.at
    var statements : array<ExpressionPtr>
    for (statement in body.list) {
        statements |> push <| statement
    }
    // A `var` argument is the computation's to keep: the generator captures it
    // by move. A task's body also starts by taking it into a local of the same
    // name. As a local it lives in the task's own storage, which every scope
    // the body is lowered into can reach; a captured variable belongs to one
    // generator.
    var owned : array<string>
    for (argument in func.arguments) {
        if (argument._type == null) { continue }
        if (!argument._type.flags.constant) {
            owned |> push(string(argument.name))
            continue
        }
        // The task copies what it captures. Where the type alone says that a
        // copy is impossible, say what to do instead of failing in the generator.
        let base = argument._type.baseType
        if (base == Type.tArray || base == Type.tTable || base == Type.tIterator) {
            errors := "[{annotation}] cannot copy argument '{argument.name}' into the {owner}: declare it var to move it into the {owner}"
            return false
        }
    }
    var taken : array<ExpressionPtr>
    if (task) {
        for (name in owned) { taken |> push <| qmacro_expr() { var $i(name) <- $i(name) } }
    }
    for (statement in statements) { taken |> push <| statement }
    var call = new ExprCallMacro(at=at, name:="computation", macro=find_call_macro(library, "computation"))
    if (kind == CeFunctionKind.Coroutine) {
        call.arguments |> push <| qmacro($c(builder)())
    } else {
        var value = clone_type(func.result)
        call.arguments |> push <| qmacro($c(builder)(type<$t(value)>))
    }
    call.arguments |> push <| qmacro($ { $b(taken); })
    var capturing = call.arguments[1] as ExprMakeBlock
    for (name in owned) {
        let count = length(capturing._capture)
        capturing._capture |> resize(count + 1)
        capturing._capture[count].name := name
        capturing._capture[count].mode = CaptureMode.capture_by_move
    }
    // The macro reads from the block's position where the computation ends.
    // A function body records no such range, so it ends on the line after
    // the last one any of its code is on: normally the closing brace.
    var finder = new CeLastLine()
    make_visitor(*finder) $(adapter) {
        for (statement in statements) { visit(statement, adapter) }
    }
    var extent = at
    extent.last_line = finder.line + 1u
    extent.last_column = 1u
    unsafe { delete finder }
    var carried = call.arguments[1] as ExprMakeBlock
    carried.at = extent
    carried._block.at = extent
    var lowered = qmacro_block() {
        return <- $e(call)
    }
    // Generated nodes point at the function; the user's statements keep their lines.
    ce_restamp(lowered, at)
    func.body = lowered
    if (!task) {
        // A stream's type depends on what its builder does with the element,
        // and a coroutine's has no name: both are inferred from the body.
        func.result = new TypeDecl(baseType=Type.autoinfer, at=at)
        return true
    }
    // The builders store `T -const -&`. A generic's T can arrive as `string const`,
    // and the declared result must name the same tuple or AOT sees two C++ types.
    var produced = clone_type(func.result)
    produced.flags.removeConstant = true
    produced.flags.removeRef = true
    if (kind == CeFunctionKind.TaskResult) {
        produced = ce_template_type("Result", at, produced, new TypeDecl(baseType=Type.tString, at=at))
    }
    func.result = ce_template_type("Task", at, produced)
    return true
}

[function_macro(name="task")]
class TaskFunctionMacro : AstFunctionAnnotation {
    [unused_argument(group, args)] def override apply(var func : FunctionPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool {
        return ce_function_computation(func, "task", "TaskBuilder", CeFunctionKind.Task, errors)
    }
}

[function_macro(name="task_result")]
class TaskResultFunctionMacro : AstFunctionAnnotation {
    [unused_argument(group, args)] def override apply(var func : FunctionPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool {
        return ce_function_computation(func, "task_result", "TaskResultBuilder", CeFunctionKind.TaskResult, errors)
    }
}
