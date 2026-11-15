options gen2
require ../packages/computation/computation.das
var closed=0
struct LootFeed {}
def ce_dispose(var feed:LootFeed) {closed++}
[sequence]
def loot_feed() : int {
    let feed=LootFeed() |> use_resource
    yield 10
    yield 20
    panic("loot feed disconnected")
}
[export]
def main() {
    var inscope rewards <- computation(ListBuilder()) {
        try_with($ {
            for (loot,multiplier in loot_feed(),fixed_array(2,3,4)) {
                let bonus=fixed_array(0,5) |> bind
                yield loot*multiplier+bonus
            }
        }, $(message:string) {
            assert(closed==1)
            print("Closed loot feed: {message}\n")
            yield 1
        })
    }
    // Partial rewards were discarded; recovery grants one consolation reward.
    assert(length(rewards)==1 && rewards[0]==1)
    print("fallback cleanup demo OK\n")
}
