options gen2
require ../lib/computation.das
require ../examples/builders/state_result_builder.das
[export]
def main() {
    let bad = computation(StateResultBuilder(0)) {
        for (i in range(2)) { return i }
    }
    print("{bad}\n")
}
