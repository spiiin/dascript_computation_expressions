options gen2
expect 50503
// diagnostic: builder and snapshot must own their data
require ../packages/computation/computation.das
require ../packages/computation/deferred_computation.das
struct Borrowed { pointer:int? }
[export]
def main() {
    var value=7
    var data=Borrowed(pointer=unsafe(addr(value)))
    var inscope task <- deferred(ResultBuilder(),data) $(snapshot) { return 1 }
}
