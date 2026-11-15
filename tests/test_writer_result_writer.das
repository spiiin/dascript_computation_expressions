options gen2
require ../lib/computation.das
require ../examples/builders/writer_result_builder.das
[export]
def main() {
    let bad = computation(WriterResultBuilder()) {
        writer_value(1, "explicit conversion required") |> bind
    }
    print("{bad}\n")
}
