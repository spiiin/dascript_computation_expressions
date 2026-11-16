options gen2
expect 31211
// diagnostic: ce_run must return a value, not void
require ../packages/computation/computation_macro.das
struct VoidRun {}
def ce_protocol(builder:VoidRun) { return CeValueProtocol() }
def ce_return(builder:VoidRun; value:int) { return value }
def ce_run(builder:VoidRun; value:int) { print("{value}") }
[export]
def main() { computation(VoidRun()) { return 1 } }
