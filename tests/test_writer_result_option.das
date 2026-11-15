options gen2
require ../lib/computation.das
require ../examples/builders/writer_result_builder.das
[export]
def main() {
    let bad = computation(WriterResultBuilder()) {
        some(1) |> bind
    }
    print("{bad}\n")
}
