options gen2
require ../packages/computation/computation.das
require ../packages/computation_task/task_runtime.das

// A task awaits tasks. A plain Result is not one, and the bind says so once,
// at the source, instead of listing every overload that did not match.
[task_result]
def doubled(value : int) : int {
    let checked = result_ok(value) |> bind
    return checked
}

[export]
def main() {
    var inscope task <- doubled(1)
}
