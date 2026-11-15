options gen2
expect 30915
expect 31009
expect 31211
// diagnostic: task: payload must own its data
require ../packages/computation_task/task_builder.das
[export]
def main() {var pointer:int?;var inscope task <- task_after_polls(0,pointer)}
