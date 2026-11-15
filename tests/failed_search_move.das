options gen2
expect 31403
// diagnostic: SearchBuilder requires copyable solutions
require ../packages/computation/computation_macro.das
require ../packages/computation/search_builder.das
[export]
def main() {var builder=SearchBuilder(type<array<int>>)}
