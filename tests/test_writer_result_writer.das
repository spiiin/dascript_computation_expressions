options gen2
expect 31403
// diagnostic: ce_unwrap
require ../packages/computation/computation.das
require ../examples/builders/writer_result_builder.das
[export]
def main() {
    let bad = computation(WriterResultBuilder()) {
        writer_value(1, "explicit conversion required") |> bind
    }
    print("{bad}\n")
}
