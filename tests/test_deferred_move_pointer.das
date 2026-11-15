options gen2
expect 50503
// diagnostic: builder and snapshot must own their data
require ../packages/computation/computation.das
require ../packages/computation/deferred_computation.das
struct UnsafeLoot {items:array<int>;pointer:int?}
[export]
def main() {
    var inscope task <- deferred(SequenceBuilder(type<UnsafeLoot>)) {yield <- UnsafeLoot()}
}
