options gen2
require ../lib/computation.das
var active=0
struct EnemyFeed {}
def open_feed() {active++;return EnemyFeed()}
def ce_dispose(var feed:EnemyFeed) {active--}
[sequence]
def enemies() : int {
    let feed=open_feed() |> use_resource
    yield 10
    yield 20
    panic("enemy feed disconnected")
}
[sequence]
def rewards() : int {
    let enemy=enemies() |> bind
    yield enemy*2
}
[export]
def main() {
    {
        var inscope stream <- rewards()
        for(reward in stream) {
            print("First reward: {reward}\n")
            break
        }
        assert(active==0)
    }
    var inscope recovered <- computation(SequenceBuilder()) {
        try_with($ {rewards() |> yield_from}, $(message:string) {
            assert(active==0)
            print("Recovered after closing feed: {message}\n")
            yield -1
        })
    }
    var count=0
    sequence_each(recovered) $(reward:int) {print("Reward: {reward}\n");count++}
    assert(count==3 && active==0)
    print("nested Sequence cleanup demo OK\n")
}
