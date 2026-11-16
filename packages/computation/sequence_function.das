options gen2
module sequence_function public
require ./function_computation.das public
require daslib/ast
require daslib/ast_boost

//! Function annotations for the builders that produce a stream, like ``[task]`` for a task::
//!
//!     [sequence]
//!     def evens(limit : int) : int {
//!         for (value in range(limit)) {
//!             if (value % 2 == 0) { yield value }
//!         }
//!     }
//!
//! is the same function as::
//!
//!     def evens(limit : int) : iterator<int> {
//!         return <- computation(SequenceBuilder(type<int>)) {
//!             ...
//!         }
//!     }
//!
//! The declared result is the type of one element. ``[async_sequence]`` uses
//! ``AsyncSequenceBuilder`` the same way. ``[coroutine]`` uses ``CoroutineBuilder``, which
//! produces no values, so such a function declares no result.
//! ``sequence_builder`` and ``coroutine_builder`` require this module publicly, so the annotations come
//! with their builders.

//! ``[sequence]`` turns ``def f(...) : T`` into a function that returns the lazy iterator of
//! ``computation(SequenceBuilder(type<T>)) { body }``; the declared result is the type of one element.
//! An argument declared ``var`` is moved into the sequence, the others are copied. A function without a
//! declared result, or with a native ``finally``, is a compile error.
[function_macro(name="sequence")]
class SequenceFunctionMacro : AstFunctionAnnotation {
    [unused_argument(group, args)] def override apply(var func : FunctionPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool =>
        ce_function_computation(func, "sequence", "SequenceBuilder", CeFunctionKind.Sequence, errors)
}

//! ``[coroutine]`` turns ``def f(...)`` into a function that returns ``computation(CoroutineBuilder()) { body }``.
//! A coroutine produces no values, so a declared result is a compile error. An argument declared ``var``
//! is moved into the coroutine, the others are copied.
[function_macro(name="coroutine")]
class CoroutineFunctionMacro : AstFunctionAnnotation {
    [unused_argument(group, args)] def override apply(var func : FunctionPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool =>
        ce_function_computation(func, "coroutine", "CoroutineBuilder", CeFunctionKind.Coroutine, errors)
}
