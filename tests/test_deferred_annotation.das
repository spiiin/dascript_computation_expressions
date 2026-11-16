options gen2
expect 50503
// diagnostic: use an untyped snapshot argument
require ../packages/computation/computation.das
require ../packages/computation/deferred_computation.das
[export]
def main() {
    var inscope task <- deferred(ResultBuilder(),7) $(snapshot:string) { return snapshot }
}
