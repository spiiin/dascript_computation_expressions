options gen2
require ../packages/computation/computation_macro.das
require ../packages/computation_task/task_combinators.das
[export]
def main() {
    var inscope task <- computation(TaskBuilder(type<int>)) {
        let p=task_after_polls(0,1) |> and_bind(2) |> bind
        return 0
    }
}
