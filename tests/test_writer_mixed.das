options gen2
require ../lib/computation.das
require ../examples/builders/computation_effects.das
[export]
def main() {
    let invalid = computation(WriterBuilder()) {
        result_ok(1) |> bind
    }
    print("{invalid}\n")
}
