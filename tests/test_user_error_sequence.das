options gen2
expect 30165
expect 30295
expect 30838
// diagnostic: can't locate variable 'missing_sequence'
// anchor: missing_sequence
// first
require ../packages/computation/computation.das

// A mistake in a yielded value is the first error; the compiler's complaint
// about the yield itself follows it.
def numbers() {
    return <- computation(SequenceBuilder(type<int>)) {
        for (i in range(3)) {
            yield i + missing_sequence
        }
    }
}

[export]
def main() {
    var inscope sequence <- numbers()
}
