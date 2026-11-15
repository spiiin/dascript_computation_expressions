options gen2
require ../packages/computation/computation_macro.das
require ../packages/computation_task/task_builder.das
[export]
def main() {var inscope task <- computation(TaskBuilder(type<int>)) {yield 42;return 0}}
