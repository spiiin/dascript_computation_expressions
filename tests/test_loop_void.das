options gen2
expect 30341
expect 50503
// diagnostic: loop hook must return a builder outcome
require ../packages/computation/computation_macro.das
struct InvalidLoop {}
def ce_protocol(builder:InvalidLoop) {return CeValueProtocol()}
def ce_zero(builder:InvalidLoop) {return 0}
def ce_while(builder:InvalidLoop; condition:block<():bool>; body:block<():int>) {}
[export]
def main() {let value=computation(InvalidLoop()) {while(false) {}} }
