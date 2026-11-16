options gen2
expect 30341:2
// diagnostic: ce_return
require ../packages/computation/computation_macro.das
struct IncompleteBuilder {}
def ce_protocol(builder : IncompleteBuilder) { return CeValueProtocol() }
[export]
def main() { let value = computation(IncompleteBuilder()) { return 1 } }
