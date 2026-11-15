options gen2
require ../packages/computation/computation.das
require ../examples/builders/writer_result_builder.das
[export]
def main() {
    let bad = computation(WriterResultBuilder()) {
        for (i in range(2)) { return i }
    }
    print("{bad}\n")
}
