options gen2
expect 50503
// diagnostic: missing ce_protocol
require ../packages/computation/computation_macro.das
struct UnknownBuilder {}
[export]
def main() {
    let builder=UnknownBuilder()
    let result=computation(builder) {return 1}
}
