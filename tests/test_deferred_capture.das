options gen2
expect 30838
// diagnostic: can't locate variable 'local'
require ../packages/computation/computation.das
require ../packages/computation/deferred_computation.das
[export]
def main() {
    let local=7
    var inscope task <- deferred(ResultBuilder()) { return local }
}
