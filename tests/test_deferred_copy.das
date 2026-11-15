options gen2
require ../packages/computation/computation.das
require ../packages/computation/deferred_computation.das
[export]
def main() {
    var inscope task <- deferred(ResultBuilder()) { return 1 }
    var copy=task
}
