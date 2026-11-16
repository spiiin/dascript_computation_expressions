options gen2
expect 50503
// diagnostic: missing ce_protocol for builder MissingBuilder
require ../packages/computation/computation_macro.das
struct MissingBuilder {}
[export]
def main() { let value = computation(MissingBuilder()) { return 1 } }
