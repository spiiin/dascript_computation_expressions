options gen2
require ../packages/computation/computation_macro.das
require ../packages/computation/coroutine_scheduler.das
var disposed=0
struct Resource {}
def ce_dispose(var resource:Resource) {disposed++}
[coroutine]
def npc() {
    let resource=Resource() |> use_resource
    yield wait_frames(10)
}
[export]
def main() {
    coroutine_scope($(var scheduler:CoroutineScheduler) {
        let id=coroutine_spawn(scheduler,npc())
        let active=coroutine_tick(scheduler)
        assert(active==1)
        // Leaving the scope closes all owned tasks.
    })
    assert(disposed==1)
    print("coroutine scope demo OK\n")
}
