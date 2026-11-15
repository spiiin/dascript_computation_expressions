options gen2
module task_function public
require ../computation/function_computation.das public
require daslib/ast
require daslib/ast_boost

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
// that returns Task<Result<int;string>>, and `: Result<int;E>` one that
// returns Task<Result<int;E>>. [async_sequence] uses AsyncSequenceBuilder:
// its declared result is the type of one element.
//
// The names Task, Result and the builders are looked up in the module that
// declares the function; task_builder.das and async_sequence_builder.das
// bring them along.

[function_macro(name="task")]
class TaskFunctionMacro : AstFunctionAnnotation {
    [unused_argument(group, args)] def override apply(var func : FunctionPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool =>
        ce_function_computation(func, "task", "TaskBuilder", CeFunctionKind.Task, errors)
}

[function_macro(name="task_result")]
class TaskResultFunctionMacro : AstFunctionAnnotation {
    [unused_argument(group, args)] def override apply(var func : FunctionPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool =>
        ce_function_computation(func, "task_result", "TaskResultBuilder", CeFunctionKind.TaskResult, errors)
}

[function_macro(name="async_sequence")]
class AsyncSequenceFunctionMacro : AstFunctionAnnotation {
    [unused_argument(group, args)] def override apply(var func : FunctionPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool =>
        ce_function_computation(func, "async_sequence", "AsyncSequenceBuilder", CeFunctionKind.AsyncSequence, errors)
}
