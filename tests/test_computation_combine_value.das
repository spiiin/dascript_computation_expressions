options gen2
require ../lib/computation.das
require ../examples/builders/computation_effects.das
[export]
def main() {
    // A builder with continuations: Combine takes a Unit step, so a branch that
    // produces a value cannot be followed by more statements. Result and Option
    // are lowered directly; there such a branch returns early.
    let bad = computation(WriterBuilder()) {
        if (true) { return 1 } else { return 2 }
        return 3
    }
    print("{bad}\n")
}
