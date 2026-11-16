options gen2
expect 31400
// diagnostic: emit elements with yield
require ../packages/computation/computation_macro.das
require ../packages/computation_task/async_sequence_builder.das
[export]
def main() {var inscope stream <- computation(AsyncSequenceBuilder(type<int>)) {return 42}}
