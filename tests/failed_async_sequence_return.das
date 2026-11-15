options gen2
require ../packages/computation/computation_macro.das
require ../packages/computation_task/async_sequence_builder.das
[export]
def main() {var inscope stream <- computation(AsyncSequenceBuilder()) {return 42}}
