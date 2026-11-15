options gen2
require ../lib/computation.das
require ../lib/task_runtime.das

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
