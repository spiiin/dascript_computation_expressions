options gen2
expect 31400
// diagnostic: a task cannot bind a source of type variant<err:string;ok:int>
// anchor: |> bind
require ../packages/computation/computation.das
require ../packages/computation_task/task_runtime.das

// A task awaits tasks. A plain Result is not one, and the bind says so once,
// at the source, instead of listing every overload that did not match.
[task_result]
def doubled(value : int) : int {
    let checked = ok(value, type<string>) |> bind
    return checked
}

[export]
def main() {
    var inscope task <- doubled(1)
}
