options gen2
require ../packages/computation/computation.das

// A mistake in a yielded value is the first error; the compiler's complaint
// about the yield itself follows it.
def numbers() {
    return <- computation(SequenceBuilder()) {
        for (i in range(3)) {
            yield i + missing_sequence
        }
    }
}

[export]
def main() {
    var inscope sequence <- numbers()
}
