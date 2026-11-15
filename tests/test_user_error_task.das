options gen2
require ../lib/computation.das
require ../lib/task_runtime.das

// A mistake in a task body is the first error, on its own line.
[task]
def load(value : int) : int {
    let a = task_after_polls(1, value) |> bind
    let b = task_after_polls(1, a + 1) |> bind
    return a + b + missing_task
}

[export]
def main() {
    var inscope task <- load(1)
}
