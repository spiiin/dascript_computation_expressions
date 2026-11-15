options gen2
require ../packages/computation_task/task_builder.das
[export]
def main() {var pointer:int?;var inscope task <- task_after_polls(0,pointer)}
