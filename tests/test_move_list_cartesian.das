options gen2
expect 30949:2
expect 31400:2
// diagnostic: Cartesian product requires copyable input elements
require ../support/move_collection_support.das
[export]
def main() {
 var inscope values <- computation(ListBuilder(type<Loot>)) {
    var pair & = loot_list() |> and_bind(loot_list()) |> bind
    return <- pair.first
 }
}
