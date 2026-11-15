options gen2
expect 31400
// diagnostic: ce_unwrap
require ../packages/computation/computation.das
require ../packages/computation/validation_builder.das
[export]
def main() {
    let value = computation(ValidationBuilder()) { let x = result_ok(1) |> bind; return x }
    print("{value}")
}
