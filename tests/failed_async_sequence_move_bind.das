options gen2
expect 30222
expect 30941
expect 31400
// diagnostic: move-only bind needs 'var value & = source |> bind'
require ../packages/computation/computation_macro.das
require ../packages/computation_task/async_sequence_builder.das
def batches() {return <- computation(AsyncSequenceBuilder(type<array<int>>)) {yield <- [1,2]}}
[export]
def main() {
    var inscope consumer <- computation(TaskBuilder(type<int>)) {
        var stream & = batches() |> use_resource
        let item=async_sequence_next(stream) |> bind
        return 0
    }
}
