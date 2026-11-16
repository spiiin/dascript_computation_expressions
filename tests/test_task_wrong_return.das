options gen2
expect 30341
// diagnostic: ce_await_return
// anchor: return "text"
// first
require ../packages/computation/computation.das
require ../packages/computation_task/task_runtime.das

// A value of the wrong type is reported where the task returns it, not at
// the library code that wraps the return.
[task]
def load(value : int) : int {
    let a = task_after_polls(1, value) |> bind
    return "text"
}

[export]
def main() {
    var inscope task <- load(1)
}
