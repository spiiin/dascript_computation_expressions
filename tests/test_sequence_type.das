options gen2
require ../packages/computation/computation.das
[export]
def main() {
 var inscope seq <- computation(SequenceBuilder()) { yield "wrong" }
 for (value in seq) { print("{value}") }
}
