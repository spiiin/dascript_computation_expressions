options gen2
expect 31400
// diagnostic: move-only elements require yield <- value
require ../packages/computation_task/async_sequence_builder.das
require ../packages/computation/computation_macro.das
[export]
def main() {
    var inscope stream <- computation(AsyncSequenceBuilder(type<array<int>>)) {
        var items <- [1,2]
        yield items
    }
}
