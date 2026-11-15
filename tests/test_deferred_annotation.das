options gen2
require ../packages/computation/computation.das
require ../packages/computation/deferred_computation.das
[export]
def main() {
    var inscope task <- deferred(ResultBuilder(),7) $(snapshot:string) { return snapshot }
}
