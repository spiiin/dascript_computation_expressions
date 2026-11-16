options gen2
expect 30341
expect 50503
// diagnostic: loop hook must return a builder outcome
require ../packages/computation/computation_macro.das
struct InvalidZip {}
def ce_protocol(builder:InvalidZip) {return CeValueProtocol()}
def ce_zero(builder:InvalidZip) {return 0}
def ce_for_zip(builder:InvalidZip; arity:int; traverse:auto) {}
[export]
def main() {let value=computation(InvalidZip()) {for (a,b in range(2),range(3)) {}} }
