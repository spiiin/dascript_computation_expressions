options gen2
expect 31400
// diagnostic: broadcast payload must be copyable
require ../packages/computation_task/task_events.das
[export]
def main() {var inscope events <- task_event_source(type<array<int>>)}
