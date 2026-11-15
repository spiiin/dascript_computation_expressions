options gen2
require ../packages/computation/computation.das
require ../examples/builders/computation_effects.das

// As test_user_error_direct, for a builder lowered with continuations: every
// bind around the mistake fails to type as well, and comes after it.
[export]
def main() {
    let result = computation(WriterBuilder()) {
        let a = writer_value(1, "one;") |> bind
        let b = writer_value(a + 1, "two;") |> bind
        return a + b + missing_writer
    }
    print("{result}\n")
}
