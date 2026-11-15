options gen2
module sequence_function public
require ./function_computation.das public
require daslib/ast
require daslib/ast_boost

// Function-level sugar for the builders that produce a stream, like [task]
// for a task:
//
//     [sequence]
//     def evens(limit : int) : int {
//         for (value in range(limit)) {
//             if (value % 2 == 0) { yield value }
//         }
//     }
//
// is the same function as
//
//     def evens(limit : int) : iterator<int> {
//         return <- computation(SequenceBuilder(type<int>)) {
//             ...
//         }
//     }
//
// The declared result is the type of one element. [async_sequence] uses
// AsyncSequenceBuilder the same way. [coroutine] uses CoroutineBuilder, which
// produces no values, so such a function declares no result.

[function_macro(name="sequence")]
class SequenceFunctionMacro : AstFunctionAnnotation {
    [unused_argument(group, args)] def override apply(var func : FunctionPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool {
        return ce_function_computation(func, "sequence", "SequenceBuilder", CeFunctionKind.Sequence, errors)
    }
}

[function_macro(name="coroutine")]
class CoroutineFunctionMacro : AstFunctionAnnotation {
    [unused_argument(group, args)] def override apply(var func : FunctionPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool {
        return ce_function_computation(func, "coroutine", "CoroutineBuilder", CeFunctionKind.Coroutine, errors)
    }
}
