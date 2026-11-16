options gen2
expect 30341:2
expect 30838
// diagnostic: can't locate variable 'missing_writer'
// anchor: missing_writer
// first
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
}
