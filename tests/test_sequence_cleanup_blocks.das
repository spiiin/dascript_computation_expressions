options gen2
expect 50503
// diagnostic: try_finally expects two blocks
require ../packages/computation/computation.das
[export]
def main() {
 var inscope seq <- computation(SequenceBuilder()) {
  try_finally($ {yield 1}, 42)
 }
}
