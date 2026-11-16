options gen2
expect 30295
expect 30838
// diagnostic: can't locate variable 'missing_task'
// anchor: missing_task
// first
require ../packages/computation/computation.das
require ../packages/computation_task/task_runtime.das

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
