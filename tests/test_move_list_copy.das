options gen2
expect 31400
// diagnostic: move-only List: use return <- or yield <-
require ../support/move_collection_support.das
[export]
def main() {var inscope values <- computation(ListBuilder(type<Loot>)) {yield loot(1)}}
