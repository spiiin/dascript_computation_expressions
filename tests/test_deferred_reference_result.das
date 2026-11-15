options gen2
require ../packages/computation/computation.das
require ../packages/computation/deferred_computation.das
var external=42
def ce_run(builder:ResultBuilder; value:Result<int;string>) {
    return <- generator<int&> {yield external;return false}
}
[export]
def main() {
    var inscope task <- deferred(ResultBuilder()) {return 1}
}
