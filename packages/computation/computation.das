options gen2
module computation public
// Backwards-compatible convenience imports. The extensible core is independent.
require ./computation_macro.das public
require ./computation_builders.das public
require ./list_builder.das public
require ./sequence_builder.das public
require ./move_builders.das public

//! The facade of the library: the ``computation(builder) { ... }`` macro together with the Result, Option,
//! List and Sequence builders and the move-only Result and Option builders. Require it for ordinary use.
//! Validation, Search, Parser, Coroutine and ``deferred`` are separate modules; ``computation_macro`` alone
//! is the core for a builder of your own.
