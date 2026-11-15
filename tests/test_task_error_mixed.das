options gen2
expect 31400
// diagnostic: this task fails with string, and the computation with LoadError
// anchor: fetch(id) |> bind
require ../packages/computation/computation.das
require ../packages/computation_task/task_runtime.das

enum LoadError {
    NotFound
}

[task_result]
def fetch(id : int) : int {
    let value = task_after_polls(1, result_ok(id)) |> bind
    return value
}

// fetch fails with a string and load with LoadError. The error is not
// converted silently: the bind is rejected, and says how to convert it.
[task_result]
def load(id : int) : Result<int;LoadError> {
    let value = fetch(id) |> bind
    return value
}

[export]
def main() {
    var inscope task <- load(1)
}
