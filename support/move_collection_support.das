options gen2
module move_collection_support public
require ../lib/computation.das public
struct Loot {items:array<int>}
def loot(n:int) {
    var inscope value:Loot
    value.items |> push(n)
    return <- value
}
def loot_list() {
    return <- computation(ListBuilder(type<Loot>)) {yield <- loot(10);yield <- loot(20);yield <- loot(30)}
}
var feeds_opened=0
var feeds_closed=0
struct LootFeed {}
def open_loot_feed() {feeds_opened++;return LootFeed()}
def ce_dispose(var feed:LootFeed) {feeds_closed++}
[sequence]
def loot_sequence(fail:bool=false) : Loot {
    let feed=open_loot_feed() |> use_resource
    yield <- loot(10)
    if(fail) {panic("loot source failed")}
    yield <- loot(20)
    yield <- loot(30)
}
[sequence]
def upgraded_loot(fail:bool=false) : Loot {
    var value & = loot_sequence(fail) |> bind
    value.items |> push(99)
    yield <- value
}
