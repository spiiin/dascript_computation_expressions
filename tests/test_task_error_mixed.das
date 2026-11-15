options gen2
require ../lib/computation.das
require ../lib/task_runtime.das

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
