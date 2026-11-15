options gen2
expect 20800
// diagnostic: needs the type of the task value
// anchor: [task]
require ../packages/computation/computation.das
require ../packages/computation_task/task_runtime.das

// The builder needs the value type before the body is known, so [task]
// rejects a function that leaves its result to inference.
[task]
def untyped(value : int) {
    return value * 2
}

[export]
def main() {
    var inscope task <- untyped(1)
}
