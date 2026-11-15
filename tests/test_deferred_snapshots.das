options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das
require ../examples/builders/computation_effects.das
require ../packages/computation/deferred_computation.das
struct Config {
    name:string
    amounts:array<int>
}
struct Game { gold:int }
var cloned=0
struct Fragile { amounts:array<int> }
def clone(var dest:Fragile; src:Fragile) {
    cloned++
    dest.amounts := src.amounts
}
[export]
def main() {
    let baseline=heap_bytes_allocated()
    for (i in range(10)) {
        {
            var inscope config:Config
            config.name="reward"
            config.amounts <- [2,4]
            var inscope task <- deferred(StateBuilder(Game(gold=10)),config) $(snapshot) {
                var game=state_get() |> bind
                game.gold+=snapshot.amounts[0]+snapshot.amounts[1]
                state_put(game) |> bind
                snapshot.amounts[0]=999
                return snapshot.name
            }
            config.amounts[0]=500
            delete config
            let a=run_deferred(task)
            let b=run_deferred(task)
            assert(a.value=="reward" && a.state.gold==16 && b.state.gold==16)
        }
        {
            var inscope value:Fragile
            value.amounts <- [1,2,3]
            var inscope task <- deferred(ResultBuilder(),value) $(snapshot) { return length(snapshot.amounts) }
            let after=run_deferred(task)
            assert(after as ok==3)
        }
        let after=heap_bytes_allocated()
        assert(after==baseline)
    }
    assert(cloned==20)
    print("deferred snapshot checks OK\n")
}

[test]
def test_deferred_snapshots() {
    main()
}
