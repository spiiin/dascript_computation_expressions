options gen2
require ../packages/computation/deferred_computation.das
require ../packages/computation_task/async_sequence_builder.das
[export]
def main() {
    var number=1
    unsafe {
        var inscope saved <- deferred(AsyncSequenceBuilder(),addr(number)) $(snapshot) {yield 1}
    }
}
