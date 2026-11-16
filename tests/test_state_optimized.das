options gen2
require dastest/testing_boost public
require ../packages/computation/computation.das
require ../examples/builders/computation_effects.das
require ../packages/computation/deferred_computation.das
require daslib/rtti

struct Game {hp:int; mana:int}
var sources=0
var conditions=0
def turns(n:int) {sources++; return range(n)}
def more(i,n:int) {conditions++; return i<n}

[export]
def main() {
    let saved=StateBuilder(Game(hp=10,mana=5))
    let baseline=heap_bytes_allocated()
    for (count in fixed_array(0,1,2,9)) {
        sources=0; conditions=0
        let result=computation(saved) {
            for (i in turns(count)) {
                let previous=state_get() |> bind
                state_put(Game(hp=previous.hp+1,mana=previous.mana+2)) |> bind
                assert(previous.hp==10+i && previous.mana==5+2*i)
            }
            var i=0
            while (more(i,count)) {
                let previous=state_get() |> bind
                // Import a completed State result from another computation.
                let value=state_result(7,Game(hp=previous.hp+3,mana=previous.mana)) |> bind
                assert(value==7)
                i++
            }
            let final=state_get() |> bind
            return final.hp
        }
        assert(result.value==10+count*4 && result.state.hp==result.value)
        assert(result.state.mana==5+count*2 && sources==1 && conditions==count+1)
        assert(saved.state.hp==10 && saved.state.mana==5)
    }
    let nested=computation(StateBuilder(0)) {
        for (i in range(3)) {
            var j=0
            while (j<4) {
                let n=state_get() |> bind
                state_put(n+1) |> bind
                j++
            }
        }
    }
    assert(nested.state==12)
    {
        var inscope task <- deferred(StateBuilder(2),5) $(count) {
            for (i in range(count)) {
                let n=state_get() |> bind
                state_put(n+1) |> bind
            }
            let n=state_get() |> bind
            return n
        }
        let first=run_deferred(task)
        let second=run_deferred(task)
        assert(first.value==7 && second.value==7 && first.state==second.state)
    }
    let current=heap_bytes_allocated()
    assert(current==baseline)
    print("State optimized loops checks OK\n")
}

[test]
def test_state_optimized() {
    main()
}
