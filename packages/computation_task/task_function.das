options gen2
module task_function public
require ../computation/function_computation.das public
require daslib/ast
require daslib/ast_boost

//! Function-level sugar for the task builders, after daslib's ``[async]``: ``[task]``,
//! ``[task_result]`` and ``[async_sequence]`` turn the body of a function into a computation, so the
//! function reads as straight-line code and returns the task or the stream. The names ``Task``,
//! ``Result``, ``AsyncSequence`` and the builders are looked up in the module that declares the
//! function; ``task_builder`` and ``async_sequence_builder`` bring them and this module along.

//! ``[task]`` makes a function return a task: its body becomes the block of
//! ``computation(TaskBuilder(type<T>))``. The declared result is the value the task produces, not
//! the task itself, and it cannot be left out. This function::
//!
//!     [task]
//!     def load_level(id : int) : int {
//!         let chunk = read_chunk(id) |> bind
//!         return chunk * 2
//!     }
//!
//! is the same function as::
//!
//!     def load_level(id : int) : Task<int> {
//!         return <- computation(TaskBuilder(type<int>)) {
//!             let chunk = read_chunk(id) |> bind
//!             return chunk * 2
//!         }
//!     }
//!
//! A ``var`` argument is moved into the task and the other arguments are copied, so an array, a
//! table or an iterator argument has to be declared ``var``.
[function_macro(name="task")]
class TaskFunctionMacro : AstFunctionAnnotation {
    [unused_argument(group, args)] def override apply(var func : FunctionPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool =>
        ce_function_computation(func, "task", "TaskBuilder", CeFunctionKind.Task, errors)
}

//! ``[task_result]`` does the same with ``TaskResultBuilder``: a function declared ``: T`` returns a
//! ``Task<Result<T;string>>``, and one declared ``: Result<T;E>`` returns a ``Task<Result<T;E>>``.
//! Binding a task whose result is ``err`` ends the function's task with that error.
[function_macro(name="task_result")]
class TaskResultFunctionMacro : AstFunctionAnnotation {
    [unused_argument(group, args)] def override apply(var func : FunctionPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool =>
        ce_function_computation(func, "task_result", "TaskResultBuilder", CeFunctionKind.TaskResult, errors)
}

//! ``[async_sequence]`` does the same with ``AsyncSequenceBuilder``: the declared result is the type
//! of one element, the function returns an ``AsyncSequence<T>``, and its body yields the elements.
[function_macro(name="async_sequence")]
class AsyncSequenceFunctionMacro : AstFunctionAnnotation {
    [unused_argument(group, args)] def override apply(var func : FunctionPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool =>
        ce_function_computation(func, "async_sequence", "AsyncSequenceBuilder", CeFunctionKind.AsyncSequence, errors)
}
