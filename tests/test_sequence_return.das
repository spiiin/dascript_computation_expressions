options gen2
expect 50503
// diagnostic: sequence: use yield
require ../packages/computation/computation.das
[export]
def main() {
 var inscope seq <- computation(SequenceBuilder()) { return 1 }
}
