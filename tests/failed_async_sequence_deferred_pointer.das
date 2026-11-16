options gen2
expect 50503
// diagnostic: builder and snapshot must own their data
require ../packages/computation/deferred_computation.das
require ../packages/computation_task/async_sequence_builder.das
[export]
def main() {
    var number=1
    unsafe {
        var inscope saved <- deferred(AsyncSequenceBuilder(type<int>),addr(number)) $(snapshot) {yield 1}
    }
}
