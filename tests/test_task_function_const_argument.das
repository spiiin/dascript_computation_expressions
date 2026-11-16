options gen2
expect 20800
// diagnostic: declare it var to move it into the task
// anchor: [task]
require ../packages/computation/computation.das
require ../packages/computation_task/task_runtime.das

// A task keeps its arguments after the function returns. An array cannot be
// copied into it, and one that is not `var` cannot be moved either.
[task]
def total(values : array<int>) : int {
    var sum = 0
    for (value in values) {
        sum += value
    }
    return sum
}

[export]
def main() {
    var data <- [1, 2, 3]
    var inscope task <- total(data)
}
