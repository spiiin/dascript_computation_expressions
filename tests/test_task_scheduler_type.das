options gen2
expect 30341
expect 30941
// diagnostic: can only move compatible type
require ../packages/computation_task/task_scheduler.das
[export]
def main() {
    var inscope scheduler <- task_scheduler(type<int>)
    let id=task_spawn(scheduler,task_after_polls(0,"wrong payload"))
}
