options gen2
expect 30341
// diagnostic: ce_loop_append
require ../packages/computation/computation_macro.das
require ../examples/builders/reader_builder.das
[export]
def main() {
    let value = computation(ReaderBuilder(1)) {
        for (i in range(3)) { return 42 }
        return 0
    }
    print("{value}")
}
