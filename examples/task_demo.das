options gen2
require ../packages/computation/computation_macro.das
require ../packages/computation_task/task_builder.das

// The host can keep rendering/processing events between task_poll calls.
[task_result]
def load_player(accepted:bool) : string {
    let name=task_after_polls(2,ok("Alice", type<string>)) |> bind
    let health=task_after_polls(1,accepted ? ok(85, type<string>) : err("access denied",type<int>)) |> bind
    return "{name}: health={health}"
}
[export]
def main() {
    var inscope good <- load_player(true)
    var inscope bad <- load_player(false)
    var active=true
    var frame=0
    while(active) {
        frame++
        let first=task_poll(good)
        let second=task_poll(bad)
        active=first==TaskStatus.Waiting || second==TaskStatus.Waiting
        print("Frame {frame}: other host work can run here\n")
    }
    let player=task_value(good)
    let rejected=task_value(bad)
    verify(player is ok && player as ok=="Alice: health=85")
    verify(rejected is err && rejected as err=="access denied")
    print("{player as ok}\n{rejected as err}\nTask demo OK\n")
}
