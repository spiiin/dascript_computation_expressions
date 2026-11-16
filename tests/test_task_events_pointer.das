options gen2
expect 31211
// diagnostic: payload must own its data
require ../packages/computation_task/task_events.das
[export]
def main() {var inscope events <- task_event_source(type<int?>)}
