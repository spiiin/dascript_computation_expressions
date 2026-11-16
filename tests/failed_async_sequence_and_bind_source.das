options gen2
expect 31403
// diagnostic: and_bind is unsupported for builder
require ../packages/computation/computation_macro.das
require ../packages/computation_task/async_sequence_builder.das
[export]
def main() {
    var inscope source <- computation(AsyncSequenceBuilder(type<int>)) {
        let pair=task_after_polls(0,1) |> and_bind(2) |> bind
        yield 0
    }
}
