options gen2
expect 50503
// diagnostic: ce_protocol must return a builder_protocol descriptor
require ../packages/computation/computation_macro.das
struct InvalidBuilder {}
def ce_protocol(builder : InvalidBuilder) { return 123 }
[export]
def main() { let value = computation(InvalidBuilder()) { return 1 } }
