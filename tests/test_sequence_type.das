options gen2
expect 30915
// diagnostic: can only copy compatible type
require ../packages/computation/computation.das
[export]
def main() {
 var inscope seq <- computation(SequenceBuilder()) { yield "wrong" }
 for (value in seq) { print("{value}") }
}
