options gen2
require ../packages/computation/computation.das
require ../packages/computation_task/task_runtime.das

// A native finally would run when the function returns the cold task, not
// when the task ends, so [task_result] rejects it like computation does.
[task_result]
def guarded(value : int) : int {
    return value
} finally {
    print("released\n")
}

[export]
def main() {
    var inscope task <- guarded(1)
}
