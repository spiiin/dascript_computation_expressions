options gen2
expect 30341
// diagnostic: ce_loop_append
require ../packages/computation/computation.das
require ../examples/builders/computation_effects.das
[export]
def main() {
    let invalid = computation(WriterBuilder()) {
        for (i in range(3)) { return i }
    }
    print("{invalid}\n")
}
