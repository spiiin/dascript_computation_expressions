options gen2
expect 30197
// diagnostic: can only be move-initialized
require ../packages/computation/computation.das
require ../packages/computation/deferred_computation.das
[export]
def main() {
    var inscope task <- deferred(ResultBuilder()) { return 1 }
    var copy=task
}
