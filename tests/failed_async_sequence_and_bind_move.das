options gen2
expect 30222
expect 30941
expect 31400
// diagnostic: move-only bind needs 'var value & = source |> bind'
require ../packages/computation/computation_macro.das
require ../packages/computation_task/async_sequence_builder.das
[export]
def main() {
    var inscope source <- computation(AsyncSequenceBuilder(type<int>)) {
        let pair=task_after_polls_move(0,[1]) |> and_bind(task_after_polls_move(0,[2])) |> bind
        yield pair.first[0]
    }
}
