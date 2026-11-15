options gen2
require ../packages/computation/computation.das
require ../examples/builders/computation_effects.das
[export]
def main() {
    let invalid = computation(WriterBuilder()) {
        for (i in range(3)) { return i }
    }
    print("{invalid}\n")
}
