options gen2
expect 31403
// diagnostic: QueryBuilder requires copyable rows
require ../packages/computation/computation_macro.das
require ../examples/builders/query_builder.das
[export]
def main() {var builder=QueryBuilder(type<array<int>>)}
