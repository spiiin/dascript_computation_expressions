options gen2
expect 31400
// diagnostic: ce_unwrap
require ../packages/computation/computation.das
require ../packages/computation/validation_builder.das
[export]
def main() {
    let value = computation(ValidationBuilder()) { let x = ok(1, type<string>) |> bind; return x }
    print("{value}")
}
